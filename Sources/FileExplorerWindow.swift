import AppKit
import CoreServices

private func resolveRealPath(_ path: String) -> String {
    guard let ptr = realpath(path, nil) else { return path }
    let resolved = String(cString: ptr)
    free(ptr)
    return resolved
}

class FileExplorerWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let mainVC: MainViewController
    let sidebarVC: SidebarViewController
    let contentVC: FileTableViewController

    var currentDirectory: URL
    var backStack: [URL] = []
    var forwardStack: [URL] = []

    // File system watcher (FSEvents)
    private var eventStream: FSEventStreamRef?
    private var reloadWorkItem: DispatchWorkItem?
    private var folderSizeTimer: Timer?

    init(directory: URL) {
        currentDirectory = directory
        sidebarVC = SidebarViewController()
        contentVC = FileTableViewController()
        mainVC = MainViewController(sidebarVC: sidebarVC, contentVC: contentVC)

        window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )

        super.init()

        window.delegate = self
        // `let window` already owns a strong reference; letting AppKit also release on
        // close would over-release under ARC.
        window.isReleasedWhenClosed = false
        window.title = "File Explorer"
        window.contentViewController = mainVC

        // Set size AFTER contentViewController (it can resize the window)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let w = screen.width * 0.85
        let h = screen.height * 0.85
        // Cascade instead of stacking every window on the exact same rect, where ⌘N looks
        // like it did nothing. The new window is not in `windows` yet — appended by the caller.
        let openCount = (NSApp.delegate as? AppDelegate)?.windows.count ?? 0
        let offset = CGFloat(openCount % 8) * 22
        let x = min(screen.midX - w / 2 + offset, screen.maxX - w)
        let y = max(screen.midY - h / 2 - offset, screen.minY)
        window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)

        // Callbacks
        sidebarVC.onSelect = { [weak self] url in self?.navigateTo(url) }
        contentVC.onNavigate = { [weak self] url in self?.navigateTo(url) }
        contentVC.onSelectionChanged = { [weak self] in self?.updateStatus() }
        contentVC.onGoUp = { [weak self] in self?.goUp() }
        contentVC.onRefresh = { [weak self] in
            guard let self else { return }
            IconCache.clear()
            self.contentVC.loadDirectory(self.currentDirectory)
            // loadDirectory now keeps folder sizes when the directory is unchanged, so an
            // explicit refresh has to ask for the recompute that used to come for free.
            // retryTruncated: true because the user asked for this one — the periodic
            // timer below deliberately leaves truncated scans alone.
            self.contentVC.refreshFolderSizes(retryTruncated: true)
            self.updateStatus()
        }
        mainVC.onNavigate = { [weak self] url in self?.navigateTo(url) }
        mainVC.onBack = { [weak self] in self?.goBack() }
        mainVC.onForward = { [weak self] in self?.goForward() }
        mainVC.onUp = { [weak self] in self?.goUp() }
        mainVC.onSearch = { [weak self] text in
            self?.contentVC.filterBySearch(text)
            self?.updateStatus()
        }

        // Load
        navigateTo(directory, addToHistory: false)
    }

    // MARK: - Navigation

    func navigateTo(_ url: URL, addToHistory: Bool = true) {
        // Only directories are navigable. Pointing the list at a file would leave it
        // empty with no explanation, since contentsOfDirectory just fails.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue
        else { return }
        if addToHistory {
            // Going where we already are is a no-op, not a history entry. Catches the
            // sidebar and breadcrumb echoing back the directory we just moved to.
            // init() performs the first load with addToHistory: false, so this never
            // blocks it even though currentDirectory is already set.
            guard url.standardizedFileURL.path != currentDirectory.standardizedFileURL.path
            else { return }
            backStack.append(currentDirectory)
            forwardStack.removeAll()
        }
        currentDirectory = url
        contentVC.currentDirectoryURL = url
        // A search is scoped to the folder it was typed in. Carrying it across made the
        // new folder look almost empty, and the "Search <name>" placeholder set below
        // stayed hidden behind the stale text.
        mainVC.searchField.stringValue = ""
        contentVC.clearSearch()
        contentVC.loadDirectory(url)
        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        window.title = "File Explorer \u{2014} " + url.path
        mainVC.updateAddress(url)
        mainVC.updateSearchPlaceholder(name)
        mainVC.backBtn.isEnabled = !backStack.isEmpty
        mainVC.forwardBtn.isEnabled = !forwardStack.isEmpty
        mainVC.upBtn.isEnabled = url.path != "/"
        sidebarVC.selectItem(for: url)
        updateStatus()
        watchDirectory(url)
    }

    // MARK: - File System Watcher (FSEvents)

    private func watchDirectory(_ url: URL) {
        stopWatching()
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var ctx = FSEventStreamContext(
            version: 0, info: selfPtr, retain: nil, release: nil, copyDescription: nil
        )
        // WatchRoot is what makes kFSEventStreamEventFlagRootChanged arrive at all —
        // measured: without it, deleting the watched directory reports only
        // "ItemRemoved|IsDir" on the directory's own path, which the direct-child filter
        // below then discards because that path's parent isn't the directory. So renaming
        // or deleting the folder you were looking at went completely unnoticed and the
        // list sat there showing files that no longer existed.
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot
        )
        let dirPath = resolveRealPath(url.path)
        guard let stream = FSEventStreamCreate(
            nil,
            { _, info, numEvents, eventPaths, eventFlags, _ in
                guard let info else { return }
                let win = Unmanaged<FileExplorerWindow>.fromOpaque(info).takeUnretainedValue()
                let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
                    as! [String]
                let dir = resolveRealPath(win.currentDirectory.path)

                // Coalesced/dropped events name the *watched* directory itself, not a
                // child, so the direct-child filter below misses them — exactly when a
                // reload matters most (copying thousands of files overflows the kernel
                // buffer). Check them first, before any path matching.
                let forceScan = UInt32(
                    kFSEventStreamEventFlagMustScanSubDirs |
                    kFSEventStreamEventFlagUserDropped |
                    kFSEventStreamEventFlagKernelDropped |
                    kFSEventStreamEventFlagRootChanged
                )
                for i in 0..<numEvents where eventFlags[i] & forceScan != 0 {
                    win.scheduleReload()
                    return
                }

                // Metadata-only flags (InodeMetaMod / FinderInfoMod / ChangeOwner /
                // XattrMod) are deliberately absent: Spotlight, Time Machine and
                // QuickLook fire them constantly and none of them change what the list
                // displays — name, size, date modified, kind.
                let relevant = UInt32(
                    kFSEventStreamEventFlagItemCreated |
                    kFSEventStreamEventFlagItemRemoved |
                    kFSEventStreamEventFlagItemRenamed |
                    kFSEventStreamEventFlagItemModified |
                    kFSEventStreamEventFlagItemCloned
                )
                for i in 0..<numEvents {
                    let path = paths[i] as NSString
                    guard path.deletingLastPathComponent == dir,
                          eventFlags[i] & relevant != 0 else { continue }
                    // A dot-file the list is filtering out can't change anything on screen,
                    // but the reload it triggers still reads the whole directory. Finder
                    // rewrites .DS_Store on its own schedule, and .zsh_history, .viminfo and
                    // editor .swp files churn in exactly the directories people keep open.
                    if !win.contentVC.showHidden, path.lastPathComponent.hasPrefix(".") { continue }
                    win.scheduleReload()
                    return
                }
            },
            &ctx,
            [dirPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        eventStream = stream

        // Recalculate folder sizes every 5 minutes — but only while someone can see the
        // result. A refresh walks the whole subtree of every visible folder row with no
        // depth or entry limit, so left unguarded a window parked on `~` keeps three
        // background threads re-scanning forever, in the background, on battery, and it
        // blocks App Nap while doing it.
        folderSizeTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self, NSApp.isActive,
                  self.window.occlusionState.contains(.visible) else { return }
            self.contentVC.refreshFolderSizes()
        }
    }

    /// Throttle, not debounce. Cancel-and-reschedule starved: a directory written to
    /// more often than every 0.5s (a large download, an unzip, `npm install`) pushed
    /// the reload back forever and the list sat frozen until the writing stopped.
    /// Letting the pending reload run caps us at 2 reloads/sec instead.
    private func scheduleReload() {
        guard reloadWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reloadWorkItem = nil
            // The directory being watched can itself be renamed or deleted. Re-reading a
            // path that is gone only empties the list and leaves the window standing on
            // nothing, so move to the nearest surviving ancestor the way Explorer does.
            // Checked here rather than in the stream callback because navigateTo tears the
            // stream down and rebuilds it, which is not a thing to do from inside its own
            // callback; this work item is already one turn removed, and stopWatching()
            // cancels it, so a closing window never runs it.
            let surviving = Self.nearestExistingDirectory(from: self.currentDirectory)
            guard surviving.standardizedFileURL.path
                    == self.currentDirectory.standardizedFileURL.path else {
                self.navigateTo(surviving, addToHistory: false)
                return
            }
            self.contentVC.reloadInPlace()
            self.updateStatus()
        }
        reloadWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// `url` itself if it is still a directory, otherwise the closest ancestor that is.
    private static func nearestExistingDirectory(from url: URL) -> URL {
        let fm = FileManager.default
        var dir = url
        while dir.path != "/" {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return dir
    }

    // The FSEvent stream holds `self` unretained, so an instance that goes away without
    // windowShouldClose running would leave the callback dereferencing freed memory. No
    // current path does that; this makes it not depend on that staying true.
    deinit { stopWatching() }

    private func stopWatching() {
        reloadWorkItem?.cancel()
        reloadWorkItem = nil
        folderSizeTimer?.invalidate()
        folderSizeTimer = nil
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    func goBack() {
        guard let prev = backStack.popLast() else { return }
        forwardStack.append(currentDirectory)
        navigateTo(prev, addToHistory: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentDirectory)
        navigateTo(next, addToHistory: false)
    }

    func goUp() {
        let parent = currentDirectory.deletingLastPathComponent()
        if parent.path != currentDirectory.path {
            navigateTo(parent)
        }
    }

    func toggleHiddenFiles() {
        contentVC.showHidden.toggle()
        contentVC.loadDirectory(currentDirectory)
        updateStatus()
    }

    // MARK: - Status

    private func updateStatus() {
        let items = contentVC.entries
        // One pass, no intermediate arrays: this runs on every arrow key as well as on
        // every reload, and `filter` twice over a 100k-entry directory is all copying.
        var folders = 0
        var totalSize: Int64 = 0
        for item in items {
            if item.isDirectory { folders += 1 } else { totalSize += item.size }
        }
        let files = items.count - folders
        let sizeStr = ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)

        let selected = contentVC.selectedCount
        if let error = contentVC.readErrorMessage {
            mainVC.statusLeft.stringValue = "Couldn't read this folder: \(error)"
        } else if selected > 0 {
            mainVC.statusLeft.stringValue = "\(selected) of \(items.count) selected"
        } else {
            mainVC.statusLeft.stringValue =
                "\(items.count) items (\(folders) folders, \(files) files)"
        }
        mainVC.statusRight.stringValue = sizeStr
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        (NSApp.delegate as? AppDelegate)?.noteActiveExplorer(window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // A copy or move started from this window keeps it open until it is done.
        // AppKit already refuses to close a window while a sheet is attached, which is
        // most of a batch's life; this covers the half second before the progress sheet
        // appears. Closing in that gap ordered the window out from under the operation,
        // so the sheet attached to an invisible window: the copy ran on with no progress
        // and no Cancel, and when it was the last window the app vanished from the screen
        // while the process stayed alive, unreachable, until the copy finished.
        // The beep matches what AppKit itself does for a sheeted window.
        if FileOperation.isBusy(for: window) {
            NSSound.beep()
            return false
        }
        // Don't let AppKit run window.close() — its internal
        // _NSWindowTransformAnimation crashes on freed layer objects.
        stopWatching()
        contentVC.prepareForClose()
        window.orderOut(nil)
        window.delegate = nil
        window.contentViewController = nil
        let appDelegate = NSApp.delegate as? AppDelegate
        appDelegate?.removeWindow(window)
        // A floating Properties panel outlives its explorer window; quitting here would
        // yank it off the screen. PropertiesPanel exits once the last panel closes.
        if appDelegate?.windows.isEmpty == true, !PropertiesPanel.hasOpenPanels {
            FileOperation.exitWhenIdle()
        }
        return false
    }
}

// MARK: - Main View Controller

class MainViewController: NSViewController, NSTextFieldDelegate {
    let sidebarVC: SidebarViewController
    let contentVC: FileTableViewController
    let splitVC = NSSplitViewController()

    // Toolbar controls — all on one row
    let backBtn = NSButton()
    let forwardBtn = NSButton()
    let upBtn = NSButton()
    let viewModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let pathControl = NSPathControl()
    let addressField = NSTextField()
    let searchField = NSSearchField()
    private var isEditingAddress = false

    // Status bar
    let statusLeft = NSTextField(labelWithString: "")
    let statusRight = NSTextField(labelWithString: "")

    // Callbacks
    var onNavigate: ((URL) -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onUp: (() -> Void)?
    var onSearch: ((String) -> Void)?

    init(sidebarVC: SidebarViewController, contentVC: FileTableViewController) {
        self.sidebarVC = sidebarVC
        self.contentVC = contentVC
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()

        // ── Toolbar (single row) ──
        let toolbar = buildToolbar()

        let toolbarSep = NSBox()
        toolbarSep.boxType = .separator
        toolbarSep.translatesAutoresizingMaskIntoConstraints = false

        // ── Split view ──
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 300
        let contentItem = NSSplitViewItem(viewController: contentVC)
        contentItem.minimumThickness = 400
        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(contentItem)

        addChild(splitVC)
        splitVC.view.translatesAutoresizingMaskIntoConstraints = false

        // ── Status bar ──
        let statusBar = buildStatusBar()

        // ── Assembly ──
        view.addSubview(toolbar)
        view.addSubview(toolbarSep)
        view.addSubview(splitVC.view)
        view.addSubview(statusBar)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            toolbarSep.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            toolbarSep.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbarSep.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            splitVC.view.topAnchor.constraint(equalTo: toolbarSep.bottomAnchor),
            splitVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitVC.view.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Toolbar

    private func buildToolbar() -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false

        // Nav buttons
        configButton(backBtn, symbol: "chevron.left", tooltip: "Back (Cmd+[)")
        configButton(forwardBtn, symbol: "chevron.right", tooltip: "Forward (Cmd+])")
        configButton(upBtn, symbol: "arrow.up", tooltip: "Enclosing Folder")
        backBtn.action = #selector(backClicked)
        backBtn.target = self
        backBtn.isEnabled = false
        forwardBtn.action = #selector(forwardClicked)
        forwardBtn.target = self
        forwardBtn.isEnabled = false
        upBtn.action = #selector(upClicked)
        upBtn.target = self

        // View mode popup (icons only)
        let viewModes: [(String, String)] = [
            ("Details", "list.bullet"),
            ("Icons",   "square.grid.2x2"),
            ("List",    "list.bullet.indent"),
        ]
        for (tooltip, symbol) in viewModes {
            let mi = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            mi.image?.size = NSSize(width: 16, height: 16)
            mi.toolTip = tooltip
            viewModePopup.menu?.addItem(mi)
        }
        viewModePopup.selectItem(at: 0)
        viewModePopup.target = self
        viewModePopup.action = #selector(viewModeChanged(_:))
        viewModePopup.translatesAutoresizingMaskIntoConstraints = false
        viewModePopup.controlSize = .regular
        (viewModePopup.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom

        // Path control (breadcrumb)
        pathControl.pathStyle = .standard
        pathControl.controlSize = .regular
        pathControl.font = .systemFont(ofSize: 13)
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.target = self
        pathControl.action = #selector(pathClicked(_:))

        // Address field (hidden, shows on double-click or Cmd+L)
        addressField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.isHidden = true
        addressField.delegate = self
        addressField.placeholderString = "Enter path..."
        addressField.focusRingType = .none
        addressField.bezelStyle = .roundedBezel

        // Search field
        searchField.placeholderString = "Search"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.controlSize = .regular
        searchField.font = .systemFont(ofSize: 13)
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))

        bar.addSubview(backBtn)
        bar.addSubview(forwardBtn)
        bar.addSubview(upBtn)
        bar.addSubview(pathControl)
        bar.addSubview(addressField)
        bar.addSubview(viewModePopup)
        bar.addSubview(searchField)

        let h: CGFloat = 36
        let pad: CGFloat = 8
        let btnW: CGFloat = 28
        let searchW: CGFloat = 180

        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: h),

            backBtn.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: pad),
            backBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            backBtn.widthAnchor.constraint(equalToConstant: btnW),
            backBtn.heightAnchor.constraint(equalToConstant: btnW),

            forwardBtn.leadingAnchor.constraint(equalTo: backBtn.trailingAnchor, constant: 2),
            forwardBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            forwardBtn.widthAnchor.constraint(equalToConstant: btnW),
            forwardBtn.heightAnchor.constraint(equalToConstant: btnW),

            upBtn.leadingAnchor.constraint(equalTo: forwardBtn.trailingAnchor, constant: 2),
            upBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            upBtn.widthAnchor.constraint(equalToConstant: btnW),
            upBtn.heightAnchor.constraint(equalToConstant: btnW),

            // Address bar fills space between nav buttons and view mode popup
            pathControl.leadingAnchor.constraint(equalTo: upBtn.trailingAnchor, constant: pad),
            pathControl.trailingAnchor.constraint(equalTo: viewModePopup.leadingAnchor, constant: -pad),
            pathControl.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            addressField.leadingAnchor.constraint(equalTo: upBtn.trailingAnchor, constant: pad),
            addressField.trailingAnchor.constraint(equalTo: viewModePopup.leadingAnchor, constant: -pad),
            addressField.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            // View mode popup between address bar and search
            viewModePopup.trailingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: -pad),
            viewModePopup.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            viewModePopup.widthAnchor.constraint(equalToConstant: 42),

            searchField.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -pad),
            searchField.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: searchW),
        ])

        return bar
    }

    private func configButton(_ btn: NSButton, symbol: String, tooltip: String) {
        btn.bezelStyle = .recessed
        btn.isBordered = true
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        btn.imagePosition = .imageOnly
        btn.toolTip = tooltip
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setButtonType(.momentaryPushIn)
    }

    // MARK: - Status bar

    private func buildStatusBar() -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        statusLeft.font = .systemFont(ofSize: 11)
        statusLeft.textColor = .secondaryLabelColor
        statusLeft.lineBreakMode = .byTruncatingTail
        statusLeft.translatesAutoresizingMaskIntoConstraints = false

        statusRight.font = .systemFont(ofSize: 11)
        statusRight.textColor = .secondaryLabelColor
        statusRight.alignment = .right
        statusRight.translatesAutoresizingMaskIntoConstraints = false

        bar.addSubview(sep)
        bar.addSubview(statusLeft)
        bar.addSubview(statusRight)

        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: 24),

            sep.topAnchor.constraint(equalTo: bar.topAnchor),
            sep.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: bar.trailingAnchor),

            statusLeft.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            statusLeft.centerYAnchor.constraint(equalTo: bar.centerYAnchor, constant: 2),
            statusLeft.trailingAnchor.constraint(lessThanOrEqualTo: statusRight.leadingAnchor,
                                                  constant: -8),

            statusRight.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            statusRight.centerYAnchor.constraint(equalTo: bar.centerYAnchor, constant: 2),
            statusRight.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])

        return bar
    }

    // MARK: - Address bar

    func updateAddress(_ url: URL) {
        pathControl.url = url
        addressField.stringValue = url.path
        if isEditingAddress { stopEditAddress() }
    }

    func updateSearchPlaceholder(_ name: String) {
        searchField.placeholderString = "Search \(name)"
    }

    @objc func startEditAddress() {
        isEditingAddress = true
        pathControl.isHidden = true
        addressField.isHidden = false
        addressField.selectText(nil)
        // Defer focus to avoid conflict with path control's click handling
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.window?.makeFirstResponder(self.addressField)
        }
    }

    private func stopEditAddress() {
        isEditingAddress = false
        addressField.isHidden = true
        pathControl.isHidden = false
        // Hiding a field's first responder drops it to the window, not to whatever was
        // focused before — the file list's arrow keys, Enter and F2 went dead until the
        // user clicked back into it.
        view.window?.makeFirstResponder(
            contentVC.viewMode == 0 ? contentVC.tableView : contentVC.collectionView)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            let path = addressField.stringValue.trimmingCharacters(in: .whitespaces)
            let expanded = NSString(string: path).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                // A directory navigates; a file opens in its default app, like Explorer.
                if isDir.boolValue {
                    onNavigate?(url)
                } else {
                    NSWorkspace.shared.open(url)
                }
            } else {
                NSSound.beep()
            }
            stopEditAddress()
            return true
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            stopEditAddress()
            return true
        }
        return false
    }

    // MARK: - Actions

    @objc func backClicked() { onBack?() }
    @objc func forwardClicked() { onForward?() }
    @objc func upClicked() { onUp?() }

    @objc func viewModeChanged(_ sender: NSPopUpButton) {
        contentVC.switchViewMode(sender.indexOfSelectedItem)
    }

    @objc func searchChanged(_ sender: NSSearchField) {
        onSearch?(sender.stringValue)
    }

    @objc func pathClicked(_ sender: NSPathControl) {
        if let url = sender.clickedPathItem?.url {
            onNavigate?(url)
        } else {
            startEditAddress()
        }
    }
}
