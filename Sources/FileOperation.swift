import AppKit

/// A batch copy / move / trash that runs off the main thread behind a progress sheet.
///
/// `FileManager.copyItem` is synchronous and unbounded: pasting a 10 GB folder used to
/// run inside a `for` loop on the main thread, so the whole process stopped redrawing
/// until it finished, with no way to cancel. The only reason a second *instance* stayed
/// usable was that it happened to be a separate process — architecture by accident.
///
/// The sheet appears only once the batch has been running for `sheetDelay`; the common
/// case (a handful of small files) finishes first and never flashes a dialog.
final class FileOperation: NSObject, FileManagerDelegate {

    enum Kind {
        case copy, move, trash

        var title: String {
            switch self {
            case .copy: return "Copying…"
            case .move: return "Moving…"
            case .trash: return "Moving to Trash…"
            }
        }
    }

    struct Outcome {
        /// Where the items ended up — what the caller should select after reloading.
        var resulting: Set<URL> = []
        /// Source URLs that completed. Anything in the batch but not in here was either
        /// rejected with an error or never reached because the user cancelled.
        var processed: Set<URL> = []
        var errors: [(URL, Error)] = []
        var cancelled = false
    }

    /// Long enough that a normal paste never puts a sheet on screen, short enough that
    /// anything a user would call "slow" is covered.
    private static let sheetDelay: TimeInterval = 0.5

    // MARK: - Quitting while a copy is in flight
    //
    // Closing the last window calls `exit(0)` outright, which was safe only as long as
    // every file operation ran to completion on the main thread. Now that they don't,
    // the process could be torn down mid-`copyItem` and leave a half-written file on
    // disk. Both quit paths route through here instead. Main-thread only.

    private static var running: [FileOperation] = []
    private static var quitPending = false

    static var isBusy: Bool { !running.isEmpty }

    /// Whether `window` is hosting an operation right now.
    ///
    /// AppKit already refuses to close a window while a sheet is attached, which covers
    /// most of a batch's life. It does not cover the `sheetDelay` before the sheet goes
    /// up. Closing in that gap used to order the window out from under the operation:
    /// the sheet then attached to an invisible window, so the copy ran on with no
    /// progress and no Cancel — and if it was the last window, with nothing on screen at
    /// all. `windowShouldClose` asks this to extend AppKit's rule over the whole batch.
    static func isBusy(for window: NSWindow?) -> Bool {
        guard let window else { return false }
        return running.contains { $0.window === window }
    }

    /// Called when a pending quit becomes possible; `AppDelegate` uses it to answer a
    /// deferred `applicationShouldTerminate`.
    static var onIdle: (() -> Void)?

    /// Quits now if nothing is running, otherwise once the last operation finishes.
    /// The copy is what the user asked for — a window closing isn't a reason to
    /// abandon it halfway.
    static func exitWhenIdle() {
        guard isBusy else { exit(0) }
        quitPending = true
    }

    private let kind: Kind
    private let sources: [URL]
    private let destination: URL?
    private weak var window: NSWindow?
    private let completion: (Outcome) -> Void

    private let queue = DispatchQueue(label: "com.fileexplorer.file-operation",
                                      qos: .userInitiated)
    /// Guards the two flags the worker thread and the main thread both touch.
    private let lock = NSLock()
    private var _cancelled = false
    private var _finished = false

    private var alert: NSAlert?
    private var progressBar: NSProgressIndicator?
    private var detailLabel: NSTextField?

    /// Runs `sources` and calls `completion` on the main thread exactly once.
    ///
    /// - Parameters:
    ///   - destination: the directory to copy or move into; ignored for `.trash`.
    ///   - window: the window to hang the progress sheet on. `nil` runs without a sheet
    ///     (and therefore without a Cancel button), which is still off the main thread.
    static func run(kind: Kind, sources: [URL], destination: URL?,
                    in window: NSWindow?, completion: @escaping (Outcome) -> Void) {
        FileOperation(kind: kind, sources: sources, destination: destination,
                      window: window, completion: completion).start()
    }

    private init(kind: Kind, sources: [URL], destination: URL?,
                 window: NSWindow?, completion: @escaping (Outcome) -> Void) {
        self.kind = kind
        self.sources = sources
        self.destination = destination
        self.window = window
        self.completion = completion
    }

    // MARK: - Running

    private func start() {
        guard !sources.isEmpty else {
            // Still asynchronous, so callers see one consistent ordering.
            DispatchQueue.main.async { self.completion(Outcome()) }
            return
        }
        Self.running.append(self)
        scheduleSheet()
        // The work block holds the only strong reference to self until it finishes.
        queue.async {
            let outcome = self.perform()
            DispatchQueue.main.async { self.finish(outcome) }
        }
    }

    private func perform() -> Outcome {
        var outcome = Outcome()
        // A private FileManager: `default` is shared process-wide and must not be given
        // a delegate, and a delegate's callbacks arrive on whichever thread is copying.
        let fm = FileManager()
        fm.delegate = self

        for (index, src) in sources.enumerated() {
            if isCancelled { outcome.cancelled = true; break }
            report(index: index, name: src.lastPathComponent)
            do {
                switch kind {
                case .trash:
                    try fm.trashItem(at: src, resultingItemURL: nil)
                    outcome.processed.insert(src)
                case .move:
                    guard let destDir = destination else { continue }
                    // No uniqueURL here: a move onto an existing name should report the
                    // collision, not silently land as "name 2.txt".
                    let dst = destDir.appendingPathComponent(src.lastPathComponent)
                    try fm.moveItem(at: src, to: dst)
                    outcome.resulting.insert(dst)
                    outcome.processed.insert(src)
                case .copy:
                    guard let destDir = destination else { continue }
                    let dst = uniqueURL(destDir.appendingPathComponent(src.lastPathComponent),
                                        fm: fm)
                    try fm.copyItem(at: src, to: dst)
                    // A delegate that answers "don't copy this" makes `copyItem` return
                    // *normally* with a half-written tree (measured: 4 of 155 entries),
                    // so cancellation has to be noticed here and the partial copy taken
                    // back out. `dst` is a name that did not exist a moment ago, so
                    // there is nothing of the user's to destroy.
                    if isCancelled {
                        try? fm.removeItem(at: dst)
                        outcome.cancelled = true
                    } else {
                        outcome.resulting.insert(dst)
                        outcome.processed.insert(src)
                    }
                }
            } catch {
                outcome.errors.append((src, error))
            }
        }
        if isCancelled { outcome.cancelled = true }
        return outcome
    }

    /// "name.txt" → "name 2.txt" when the destination is taken, the way Finder numbers a
    /// duplicate. Deliberately resolved here on the worker thread rather than up front:
    /// two items in the same batch can share a basename, and the second one has to see
    /// the name the first one just took.
    private func uniqueURL(_ url: URL, fm: FileManager) -> URL {
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 2
        while true {
            let candidate = ext.isEmpty
                ? dir.appendingPathComponent("\(name) \(i)")
                : dir.appendingPathComponent("\(name) \(i).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    // MARK: - FileManagerDelegate

    /// Cancellation *inside* one item's tree, so cancelling a big folder copy doesn't
    /// wait for the whole thing. Returning false skips the entry and everything under it.
    ///
    /// There is deliberately no `shouldMoveItemAt` counterpart: a same-volume move is a
    /// single `rename(2)` (measured: one callback for an entire tree), and aborting a
    /// *cross*-volume move partway would leave the tree split across both volumes.
    /// Moves are therefore only interruptible between items.
    func fileManager(_ fm: FileManager, shouldCopyItemAt src: URL, to dst: URL) -> Bool {
        !isCancelled
    }

    // MARK: - Progress sheet

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    private var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return _finished
    }

    private func scheduleSheet() {
        guard let window else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sheetDelay) { [weak window] in
            self.presentSheet(on: window)
        }
    }

    private func presentSheet(on window: NSWindow?) {
        guard let window, !isFinished else { return }
        // Only one sheet can be attached at a time. Waiting for the other one, rather
        // than giving up on ours: a batch that skipped its sheet ran to the end with no
        // progress and no Cancel, and now that `windowShouldClose` keeps the window open
        // while an operation owns it, that would also be a window nobody can close.
        // The retry stops on its own — `isFinished` ends the chain.
        guard window.attachedSheet == nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak window] in
                self.presentSheet(on: window)
            }
            return
        }

        let alert = NSAlert()
        alert.messageText = kind.title
        alert.informativeText = ""
        alert.addButton(withTitle: "Cancel")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        let bar = NSProgressIndicator(frame: NSRect(x: 0, y: 20, width: 300, height: 20))
        bar.style = .bar
        // One item gives the bar nothing to divide up; a barber pole is honest about
        // not knowing how far along a single large copy is.
        if sources.count > 1 {
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = Double(sources.count)
        } else {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 0, y: 0, width: 300, height: 16)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        accessory.addSubview(bar)
        accessory.addSubview(label)
        alert.accessoryView = accessory

        self.alert = alert
        progressBar = bar
        detailLabel = label

        alert.beginSheetModal(for: window) { response in
            // `finish` dismisses with .stop; anything else is the Cancel button.
            if response != .stop { self.cancel() }
        }
    }

    private func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
        detailLabel?.stringValue = "Cancelling…"
    }

    /// When the last progress block was handed to the main queue. Only ever touched from
    /// the worker thread, which is serial, so it needs no lock.
    private var lastReportAt: TimeInterval = 0

    /// Called from the worker thread before each item.
    ///
    /// Throttled: one block per item meant 50,000 main-queue blocks — each one a label
    /// assignment and the redraw that follows — for a paste of 50,000 files, to render
    /// names nobody can read at that rate. 20 updates a second is past what anyone reads
    /// and costs nothing.
    private func report(index: Int, name: String) {
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastReportAt >= 0.05 else { return }
        lastReportAt = now
        DispatchQueue.main.async {
            guard !self.isCancelled else { return }
            if let bar = self.progressBar, !bar.isIndeterminate {
                bar.doubleValue = Double(index)
            }
            self.detailLabel?.stringValue = name
        }
    }

    private func finish(_ outcome: Outcome) {
        lock.lock(); _finished = true; lock.unlock()
        Self.running.removeAll { $0 === self }
        if !Self.isBusy {
            if Self.quitPending { exit(0) }
            Self.onIdle?()
        }
        if let alert, let window = alert.window.sheetParent {
            window.endSheet(alert.window, returnCode: .stop)
        }
        alert = nil
        progressBar = nil
        detailLabel = nil
        // One turn later: dismissing a sheet and opening the next one (the error alert
        // most callers put up) in the same turn leaves the second one wedged.
        DispatchQueue.main.async { self.completion(outcome) }
    }
}
