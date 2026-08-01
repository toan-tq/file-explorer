import AppKit
import QuickLookThumbnailing
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Key-handling subclasses

class KeyTableView: NSTableView {
    var onKey: ((UInt16, NSEvent.ModifierFlags) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if onKey?(event.keyCode, event.modifierFlags) == true { return }
        super.keyDown(with: event)
    }
}

class KeyCollectionView: NSCollectionView {
    var onKey: ((UInt16, NSEvent.ModifierFlags) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if onKey?(event.keyCode, event.modifierFlags) == true { return }
        super.keyDown(with: event)
    }
}

// MARK: - Icon cache

/// `NSWorkspace.icon(forFile:)` measures ~48 µs a call, and all three view modes asked
/// for one on every cell redraw — ~1.5 ms per reload with 30 rows visible, repeated for
/// each scroll and each FSEvent.
///
/// Keyed by side length as well as path: callers used to mutate `.size` on what they got
/// back, so one shared image can't serve both the 16 pt rows and the 48 pt grid. The size
/// is applied once, on the way in, and nobody mutates the result afterwards.
enum IconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 512
        return c
    }()

    static func icon(for url: URL, size: CGFloat) -> NSImage {
        let key = "\(Int(size))|\(url.path)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: size, height: size)
        cache.setObject(icon, forKey: key)
        return icon
    }

    /// Icons are keyed by path, so a rename gets a fresh one for free — but a folder
    /// that gains a custom icon in place keeps the old one until something drops it.
    /// An explicit refresh (F5/⌘R) is the user saying "what's on screen is stale".
    static func clear() { cache.removeAllObjects() }
}

// MARK: - File Table View Controller

class FileTableViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate,
    NSCollectionViewDataSource, NSCollectionViewDelegate,
    NSMenuDelegate {

    // Details view
    let tableView = KeyTableView()
    let scrollView = NSScrollView()

    // Icons + List view (shared NSCollectionView, different layouts)
    let collectionView = KeyCollectionView()
    let collectionScroll = NSScrollView()

    private var allEntries: [FileItem] = []  // hidden-filtered; before search + sort
    var entries: [FileItem] = []             // filtered + sorted for display
    var showHidden = false
    var searchText = ""
    var viewMode = 0  // 0=Details, 1=Icons, 2=List
    var onNavigate: ((URL) -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onGoUp: (() -> Void)?
    var onRefresh: (() -> Void)?
    private var draggedURLs: [URL] = []  // track dragged files for move

    // Folder size calculation
    private var folderSizeCache: [URL: FolderSize] = [:]
    private var calculatingFolderSizes: Set<URL> = []
    // Oldest-first record of scans not yet completed (queued or running), so a folder
    // full of subfolders can't pile up an unbounded backlog: every row scrolled into
    // view without a cached size starts one more 5-second scan, and nothing used to
    // remove it when the row scrolled back out. Scrolling through a few thousand
    // subfolders once queued a few thousand scans — three at a time, that is over an
    // hour of background disk activity for a directory nobody is even looking at
    // anymore. Capped by cancelling the oldest entries first, which are the ones most
    // likely to already be off-screen.
    private var pendingSizeOps: [(url: URL, op: Operation)] = []
    private static let maxQueuedFolderScans = 64
    private var sizeResortPending = false
    private var loadGeneration = 0
    /// Which directory `folderSizeCache` belongs to — see `loadDirectory`.
    private var loadedDirectoryURL: URL?
    /// Set when the last directory read failed instead of genuinely finding nothing —
    /// permission denied (a folder gated behind Full Disk Access/TCC) used to come back
    /// indistinguishable from an empty folder, both showing "0 items" with no way to
    /// tell them apart. `nil` once a read succeeds.
    private(set) var readErrorMessage: String?

    // Reading a directory is the single most expensive thing this controller does, and it
    // used to do it on the main thread — see `read(_:skippingIfEqualTo:then:)`.
    private let readQueue = DispatchQueue(label: "com.fileexplorer.directory-read",
                                          qos: .userInitiated)

    // Recursive folder-size scans are unbounded work: one directory row can mean
    // hundreds of thousands of files. Cap the parallelism so scrolling a folder full
    // of subfolders can't explode GCD's thread pool, and keep the operations around
    // so navigating away can actually cancel them mid-enumeration.
    private let folderSizeQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .userInitiated
        return q
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    override func loadView() {
        view = NSView()
        setupTableView()
        setupCollectionView()
    }

    // MARK: - Table View (Details mode)

    private func setupTableView() {
        let columns: [(String, String, CGFloat)] = [
            ("Name", "Name", 300),
            ("Size", "Size", 80),
            ("Date", "Date Modified", 160),
            ("Kind", "Kind", 120),
        ]
        for (id, title, width) in columns {
            let col = NSTableColumn(identifier: .init(id))
            col.title = title
            col.width = width
            col.minWidth = 60
            if id == "Name" { col.resizingMask = .autoresizingMask }
            tableView.addTableColumn(col)
        }

        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowSizeStyle = .default
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.doubleAction = #selector(tableDoubleClicked(_:))
        tableView.target = self
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.style = .inset
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        tableView.registerForDraggedTypes([.fileURL])

        // Sort descriptors for column header click
        for col in tableView.tableColumns {
            switch col.identifier.rawValue {
            case "Name":
                col.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true,
                    selector: #selector(NSString.localizedStandardCompare(_:)))
            case "Size":
                col.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)
            case "Date":
                col.sortDescriptorPrototype = NSSortDescriptor(key: "date", ascending: true)
            case "Kind":
                col.sortDescriptorPrototype = NSSortDescriptor(key: "kind", ascending: true,
                    selector: #selector(NSString.localizedStandardCompare(_:)))
            default: break
            }
        }

        // Key handling: Enter, Backspace, F2, F5, Delete
        tableView.onKey = { [weak self] keyCode, mods in
            self?.handleKey(keyCode, mods) ?? false
        }

        // Context menu
        let tableMenu = NSMenu()
        tableMenu.delegate = self
        tableView.menu = tableMenu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    // MARK: - Collection View (Icons + List modes)

    private func setupCollectionView() {
        // Must set layout before registering items — NSCollectionView's internal
        // _NSCollectionViewCore is not initialized until a layout is assigned,
        // so register() calls are lost without it.
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 96, height: 84)
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        collectionView.collectionViewLayout = layout

        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.controlBackgroundColor]
        collectionView.register(IconCell.self, forItemWithIdentifier: .init("IconCell"))
        collectionView.register(ListCell.self, forItemWithIdentifier: .init("ListCell"))
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        collectionView.registerForDraggedTypes([.fileURL])

        // Key handling
        collectionView.onKey = { [weak self] keyCode, mods in
            self?.handleKey(keyCode, mods) ?? false
        }

        // Double-click gesture for collection view
        let dblClick = NSClickGestureRecognizer(target: self, action: #selector(collectionDoubleClicked(_:)))
        dblClick.numberOfClicksRequired = 2
        dblClick.delaysPrimaryMouseButtonEvents = false
        collectionView.addGestureRecognizer(dblClick)

        // Context menu
        let cvMenu = NSMenu()
        cvMenu.delegate = self
        collectionView.menu = cvMenu

        collectionScroll.documentView = collectionView
        collectionScroll.hasVerticalScroller = true
        collectionScroll.hasHorizontalScroller = true
        collectionScroll.translatesAutoresizingMaskIntoConstraints = false
        collectionScroll.isHidden = true

        view.addSubview(collectionScroll)
        NSLayoutConstraint.activate([
            collectionScroll.topAnchor.constraint(equalTo: view.topAnchor),
            collectionScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    // MARK: - View Mode Switching

    func switchViewMode(_ mode: Int) {
        let urlsToSelect = selectedURLs
        viewMode = mode
        if mode == 0 {
            scrollView.isHidden = false
            collectionScroll.isHidden = true
            tableView.reloadData()
            // numberOfItemsInSection reports 0 in Details mode, but nothing asks unless
            // the collection view is told to reload — left alone, it kept the previous
            // directory's item views (and their thumbnails) around until the next mode
            // switch.
            collectionView.reloadData()
        } else {
            scrollView.isHidden = true
            collectionScroll.isHidden = false
            if mode == 1 {
                let layout = NSCollectionViewFlowLayout()
                layout.itemSize = NSSize(width: 96, height: 84)
                layout.minimumInteritemSpacing = 4
                layout.minimumLineSpacing = 4
                layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
                layout.scrollDirection = .vertical
                collectionView.collectionViewLayout = layout
            } else {
                let layout = NSCollectionViewFlowLayout()
                layout.itemSize = NSSize(width: 200, height: 22)
                layout.minimumInteritemSpacing = 0
                layout.minimumLineSpacing = 2
                layout.sectionInset = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
                layout.scrollDirection = .horizontal
                collectionView.collectionViewLayout = layout
            }
            collectionView.reloadData()
        }
        restoreSelection(urlsToSelect)
        onSelectionChanged?()
    }

    // MARK: - Cleanup

    func prepareForClose() {
        // Invalidate pending folder size calculations. Clearing loadedDirectoryURL below
        // does the same for a directory read still in flight, whose completion would
        // otherwise repopulate the list we are tearing down.
        loadGeneration += 1
        folderSizeQueue.cancelAllOperations()
        calculatingFolderSizes.removeAll()
        pendingSizeOps.removeAll()
        folderSizeCache.removeAll()
        loadedDirectoryURL = nil
        // Clear entries and detach data sources so pending
        // QLThumbnailGenerator callbacks find nil weak refs
        allEntries = []
        entries = []
        tableView.dataSource = nil
        tableView.delegate = nil
        collectionView.dataSource = nil
        collectionView.delegate = nil
        collectionView.reloadData()
        tableView.reloadData()
    }

    // MARK: - Load

    /// Full load — re-reads the directory from disk.
    ///
    /// Folder sizes survive when the directory is the same one already on screen. Every
    /// paste, delete, rename, new folder and drop ends by calling this with the current
    /// directory, and wiping the cache there meant creating one empty folder restarted the
    /// recursive scan of every other subfolder in view. Only a real directory change
    /// invalidates all of them; F5 asks for the recompute explicitly.
    func loadDirectory(_ url: URL, selecting selectedURLs: Set<URL>? = nil) {
        let urlsToSelect = selectedURLs ?? self.selectedURLs
        // Invalidate in-flight folder size calculations from the previous load.
        loadGeneration += 1
        folderSizeQueue.cancelAllOperations()
        calculatingFolderSizes.removeAll()
        pendingSizeOps.removeAll()
        let sameDirectory = loadedDirectoryURL?.standardizedFileURL.path
            == url.standardizedFileURL.path
        loadedDirectoryURL = url
        read(url) { [weak self] items, error in
            guard let self else { return }
            self.readErrorMessage = error?.localizedDescription
            self.allEntries = items
            if sameDirectory {
                // Forget only the folders that are gone, exactly as reloadInPlace does.
                self.pruneFolderSizeCache(keeping: items)
            } else {
                self.folderSizeCache.removeAll()
            }
            self.applyFilterAndSort(selecting: urlsToSelect)
        }
    }

    /// In-place refresh — use for file system events on the directory already shown.
    ///
    /// Deliberately *not* `loadDirectory(currentDirectoryURL)`: that wipes
    /// `folderSizeCache`, so every FSEvent in an active folder (a download landing,
    /// a build writing output) restarted the recursive scan of every visible
    /// subfolder. The Size column flickered and the disk never went idle.
    func reloadInPlace() {
        guard let url = currentDirectoryURL else { return }
        read(url, skippingIfEqualTo: allEntries) { [weak self] items, error in
            guard let self else { return }
            self.readErrorMessage = error?.localizedDescription
            self.allEntries = items
            // Keep the sizes we already computed; only forget folders that are gone.
            self.pruneFolderSizeCache(keeping: items)
            self.applyFilterAndSort(selecting: self.selectedURLs)
        }
    }

    /// Drops cached sizes for folders that are no longer in the directory.
    ///
    /// The early return is not just tidiness: building the `Set` costs 13 ms across 20.000
    /// entries, and it was being paid on the main thread after every single reload — even
    /// in a directory of nothing but files, where there is never anything to prune.
    private func pruneFolderSizeCache(keeping items: [FileItem]) {
        guard !folderSizeCache.isEmpty else { return }
        let alive = Set(items.map(\.url))
        folderSizeCache = folderSizeCache.filter { alive.contains($0.key) }
    }

    /// Reads `url` off the main thread, then applies the result on the main thread.
    ///
    /// Measured on this machine, one read of a 50.000-entry directory costs 618 ms — 119 ms
    /// listing, 108 ms fetching resource values, and 317 ms sorting, so the sort is the
    /// largest single piece — plus 86 ms for the equality check below. All of that used to
    /// run on the main thread. Auto-reload cannot be pushed back (that would be the
    /// starvation `scheduleReload` was rewritten to avoid), so a directory being written
    /// to spent well over half of every second frozen, in blocks long enough to see.
    ///
    /// Serial on purpose: two reads of the same directory in flight buy nothing, and the
    /// ordering means results land in the order they were asked for, so the last one to
    /// land is always the newest. That leaves one thing to check on arrival — whether the
    /// directory it describes is still the one on screen. `prepareForClose` clears
    /// `loadedDirectoryURL`, so a read outstanding at teardown fails that check too.
    ///
    /// - Parameter baseline: return without applying if the directory reads back equal to
    ///   this. The backstop against pointless reloads, now paid for off the main thread.
    private func read(_ url: URL, skippingIfEqualTo baseline: [FileItem]? = nil,
                      then apply: @escaping ([FileItem], Error?) -> Void) {
        let wantsHidden = showHidden
        readQueue.async { [weak self] in
            do {
                let items = try FileItem.loadDirectory(url)
                let visible = wantsHidden ? items : items.filter { !$0.isHidden }
                if let baseline, visible == baseline { return }
                DispatchQueue.main.async {
                    guard let self, self.loadedDirectoryURL?.standardizedFileURL.path
                            == url.standardizedFileURL.path else { return }
                    apply(visible, nil)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.loadedDirectoryURL?.standardizedFileURL.path
                            == url.standardizedFileURL.path else { return }
                    apply([], error)
                }
            }
        }
    }

    /// Drop the active search filter without running a reload — `loadDirectory` does
    /// that right after, and filtering twice would just flash the list.
    func clearSearch() {
        searchText = ""
    }

    func filterBySearch(_ text: String) {
        let urlsToSelect = selectedURLs
        searchText = text
        applyFilterAndSort(selecting: urlsToSelect)
    }

    private func applyFilterAndSort(selecting selectedURLs: Set<URL>? = nil) {
        if searchText.isEmpty {
            entries = allEntries
        } else {
            entries = allEntries.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
        }
        sortEntries()
        if viewMode == 0 {
            tableView.reloadData()
        } else {
            collectionView.reloadData()
        }
        restoreSelection(selectedURLs)
        onSelectionChanged?()
    }

    private var selectedURLs: Set<URL> {
        Set(selectedItems.map(\.url))
    }

    private func restoreSelection(_ urls: Set<URL>?) {
        guard let urls, !urls.isEmpty else {
            if viewMode == 0 {
                tableView.deselectAll(nil)
            } else {
                collectionView.selectionIndexPaths = []
            }
            return
        }

        // Match on paths, not URLs: callers build targets with appendingPathComponent
        // before the item exists, so a new directory's URL lacks the trailing slash
        // that contentsOfDirectory puts on the one we list back.
        let targets = Set(urls.map(\.standardizedFileURL.path))

        if viewMode == 0 {
            let indexes = IndexSet(entries.enumerated().compactMap { index, item in
                targets.contains(item.url.standardizedFileURL.path) ? index : nil
            })
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            if let first = indexes.first { tableView.scrollRowToVisible(first) }
        } else {
            let indexPaths = Set(entries.enumerated().compactMap { index, item in
                targets.contains(item.url.standardizedFileURL.path)
                    ? IndexPath(item: index, section: 0) : nil
            })
            collectionView.selectionIndexPaths = indexPaths
            if let first = indexPaths.min() {
                collectionView.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge)
            }
        }
    }

    /// Folders stay as a block above files under every sort, in both directions — the
    /// column only orders within each block. `FileItem.<` already does this for the
    /// initial listing, but clicking any header used to sort on the bare field and
    /// shuffle folders in among the files.
    private func sortEntries() {
        guard let descriptor = tableView.sortDescriptors.first else { return }
        let asc = descriptor.ascending

        func sortGrouped(_ compare: (FileItem, FileItem) -> ComparisonResult) {
            entries.sort { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                var r = compare(a, b)
                // Kind ties every folder against every other ("Folder"), and Date/Size
                // tie freely too. Without a tiebreak the direction toggle did nothing
                // inside a tied block — Kind ascending and descending listed the folders
                // in identical order. Names are unique within a directory and
                // localizedStandardCompare separates even NFC/NFD spellings of the same
                // name, so this also makes the comparator a total order, which is what
                // takes sort stability out of the picture entirely.
                if r == .orderedSame { r = a.name.localizedStandardCompare(b.name) }
                return asc ? r == .orderedAscending : r == .orderedDescending
            }
        }

        switch descriptor.key {
        case "name":
            sortGrouped { $0.name.localizedStandardCompare($1.name) }
        case "size":
            // The Size column renders folderSizeCache for directories, but FileItem.size
            // is 0 for every one of them (.fileSizeKey is nil on directories), so sorting
            // the raw field ranked a folder showing "1.2 GB" as zero. Snapshot the cache
            // so the comparator can't see it mutate mid-sort.
            let cache = folderSizeCache
            func sortKey(_ item: FileItem) -> Int64 {
                item.isDirectory ? (cache[item.url]?.bytes ?? 0) : item.size
            }
            sortGrouped { Self.order(sortKey($0), sortKey($1)) }
        case "date":
            sortGrouped { Self.order($0.modifiedDate, $1.modifiedDate) }
        case "kind":
            sortGrouped { $0.kind.localizedStandardCompare($1.kind) }
        default: break
        }
    }

    private static func order<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (b < a ? .orderedDescending : .orderedSame)
    }

    // MARK: - Column Sort

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        applyFilterAndSort(selecting: selectedURLs)
    }

    // MARK: - Key Handling (Enter, Backspace, F2, F5, Delete)

    private func handleKey(_ keyCode: UInt16, _ mods: NSEvent.ModifierFlags) -> Bool {
        let cmd = mods.contains(.command)
        switch keyCode {
        case 36: // Return/Enter → open selected
            contextOpen(nil)
            return true
        case 51: // Backspace
            if cmd {
                contextDelete(nil) // Cmd+Backspace = delete
            } else {
                onGoUp?() // Backspace = go up
            }
            return true
        case 117: // Forward Delete
            contextDelete(nil)
            return true
        case 120: // F2 → rename
            contextRename(nil)
            return true
        case 96: // F5 → refresh
            onRefresh?()
            return true
        default:
            return false
        }
    }

    // MARK: - Responder chain (Cmd+C/X/V/A from Edit menu)

    @objc func copy(_ sender: Any?) {
        contextCopy(sender)
    }

    @objc func cut(_ sender: Any?) {
        contextCut(sender)
    }

    @objc func paste(_ sender: Any?) {
        contextPaste(sender)
    }

    @objc override func selectAll(_ sender: Any?) {
        if viewMode == 0 {
            tableView.selectAll(sender)
        } else {
            let all = Set((0..<entries.count).map { IndexPath(item: $0, section: 0) })
            collectionView.selectionIndexPaths = all
        }
        onSelectionChanged?()
    }

    var selectedItems: [FileItem] {
        if viewMode == 0 {
            return tableView.selectedRowIndexes.compactMap {
                $0 < entries.count ? entries[$0] : nil
            }
        } else {
            return collectionView.selectionIndexPaths.compactMap {
                let i = $0.item
                return i < entries.count ? entries[i] : nil
            }
        }
    }

    /// Same count as `selectedItems.count`, without copying a `FileItem` (a URL plus two
    /// Strings) per selected row. `validateMenuItem` calls this for every menu item on
    /// every menu opening, and `updateStatus` on every arrow key — measured at 3.1 ms for
    /// 50.000 selected rows through the array, almost all of it retain traffic that
    /// nobody was going to look at.
    var selectedCount: Int {
        viewMode == 0 ? tableView.numberOfSelectedRows : collectionView.selectionIndexPaths.count
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard row < entries.count else { return nil }
        return entries[row].url as NSURL
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                    willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        draggedURLs = rowIndexes.compactMap { $0 < entries.count ? entries[$0].url : nil }
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                    endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation == .move, !draggedURLs.isEmpty {
            // Source files were moved by the destination — refresh
            draggedURLs = []
            if let dir = currentDirectoryURL { loadDirectory(dir) }
        }
        draggedURLs = []
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                    proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard currentDirectoryURL != nil else { return [] }
        // Drops always land in the current directory, never on a particular row. Retarget
        // whatever AppKit proposes to the table as a whole — rejecting .on outright meant
        // a drop over the middle of a row silently did nothing.
        tableView.setDropRow(-1, dropOperation: .above)
        return resolvedDragOperation(info, source: tableView)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                    row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        return acceptFileDrop(info: info, source: tableView)
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        let item = entries[row]
        let colID = tableColumn?.identifier.rawValue ?? ""
        return colID == "Name"
            ? makeNameCell(for: item, in: tableView)
            : makeTextCell(for: item, column: colID, in: tableView)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChanged?()
    }

    @objc func tableDoubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < entries.count else { return }
        openItem(entries[row])
    }

    // MARK: - NSCollectionViewDataSource

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        viewMode == 0 ? 0 : entries.count
    }

    func collectionView(_ cv: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let identifier = NSUserInterfaceItemIdentifier(viewMode == 1 ? "IconCell" : "ListCell")
        // AppKit can ask for an index that entries no longer covers when a reload lands
        // between its item count snapshot and this call. Hand back a blank registered item
        // instead of trapping; the pending reload replaces it.
        guard indexPath.item < entries.count else {
            return cv.makeItem(withIdentifier: identifier, for: indexPath)
        }
        let entry = entries[indexPath.item]
        if viewMode == 1 {
            let cell = cv.makeItem(withIdentifier: identifier, for: indexPath) as! IconCell
            cell.configure(with: entry)
            return cell
        } else {
            let cell = cv.makeItem(withIdentifier: identifier, for: indexPath) as! ListCell
            cell.configure(with: entry)
            return cell
        }
    }

    func collectionView(_ cv: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        let i = indexPath.item
        guard i < entries.count else { return nil }
        return entries[i].url as NSURL
    }

    func collectionView(_ cv: NSCollectionView, draggingSession session: NSDraggingSession,
                         willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        draggedURLs = indexPaths.compactMap {
            $0.item < entries.count ? entries[$0.item].url : nil
        }
    }

    func collectionView(_ cv: NSCollectionView, draggingSession session: NSDraggingSession,
                         endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        if operation == .move, !draggedURLs.isEmpty {
            draggedURLs = []
            if let dir = currentDirectoryURL { loadDirectory(dir) }
        }
        draggedURLs = []
    }

    func collectionView(_ cv: NSCollectionView, validateDrop draggingInfo: any NSDraggingInfo,
                         proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                         dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard currentDirectoryURL != nil else { return [] }
        return resolvedDragOperation(draggingInfo, source: cv)
    }

    func collectionView(_ cv: NSCollectionView, acceptDrop draggingInfo: any NSDraggingInfo,
                         indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        return acceptFileDrop(info: draggingInfo, source: cv)
    }

    // MARK: - NSCollectionViewDelegate

    func collectionView(_ cv: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        onSelectionChanged?()
    }

    func collectionView(_ cv: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        onSelectionChanged?()
    }

    @objc func collectionDoubleClicked(_ sender: NSClickGestureRecognizer) {
        let loc = sender.location(in: collectionView)
        if let indexPath = collectionView.indexPathForItem(at: loc),
           indexPath.item < entries.count {
            openItem(entries[indexPath.item])
        }
    }

    // MARK: - Clipboard state

    // The cut intent rides *on* the pasteboard rather than in process memory, the same way
    // Windows carries `Preferred DropEffect` as a clipboard format. A `static` changeCount
    // only exists in the process that did the cut, so cutting in one instance and pasting
    // in another silently degraded to a copy — and so did cut, quit, paste.
    //
    // This keeps the protection that the changeCount check was there for: anything else
    // taking ownership of the pasteboard — another app copying a file — calls
    // clearContents(), which wipes this marker along with the data, so paste falls back to
    // copy instead of moving that app's files out from under it.
    private static let opType = NSPasteboard.PasteboardType("com.fileexplorer.operation")
    var currentDirectoryURL: URL?     // set by FileExplorerWindow on navigate

    // MARK: - Context Menu (NSMenuDelegate)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Select clicked row if not already selected (table view). Right-clicking empty
        // space clears instead: leaving the old selection armed meant the menu offered
        // Delete/Rename for files that were often scrolled out of sight, so a user
        // right-clicking blank space for New Folder could delete something else.
        if menu === tableView.menu {
            let clicked = tableView.clickedRow
            if clicked < 0 {
                tableView.deselectAll(nil)
            } else if !tableView.selectedRowIndexes.contains(clicked) {
                tableView.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
            }
        } else if menu === collectionView.menu {
            selectCollectionItemForContextMenu()
        }

        let items = selectedItems
        let hasSelection = !items.isEmpty
        // fileURLsOnly, or copying a link in a browser lights up Paste and then fails with
        // "couldn't be saved" — NSURL reads a web URL off the pasteboard just fine.
        let hasPasteboard = NSPasteboard.general.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        )

        // Open  ⌘↩
        let openMI = NSMenuItem(title: "Open", action: hasSelection ? #selector(contextOpen(_:)) : nil, keyEquivalent: "\r")
        openMI.keyEquivalentModifierMask = [.command]
        openMI.target = self
        menu.addItem(openMI)

        menu.addItem(.separator())

        // Copy  ⌘C
        let copyMI = NSMenuItem(title: "Copy", action: hasSelection ? #selector(contextCopy(_:)) : nil, keyEquivalent: "c")
        copyMI.target = self
        menu.addItem(copyMI)

        // Copy Path  ⌘⌥C
        let cpathMI = NSMenuItem(title: "Copy Path", action: hasSelection ? #selector(contextCopyPath(_:)) : nil, keyEquivalent: "c")
        cpathMI.keyEquivalentModifierMask = [.command, .option]
        cpathMI.target = self
        menu.addItem(cpathMI)

        // Cut  ⌘X
        let cutMI = NSMenuItem(title: "Cut", action: hasSelection ? #selector(contextCut(_:)) : nil, keyEquivalent: "x")
        cutMI.target = self
        menu.addItem(cutMI)

        // Paste  ⌘V
        let pasteMI = NSMenuItem(title: "Paste", action: hasPasteboard ? #selector(contextPaste(_:)) : nil, keyEquivalent: "v")
        pasteMI.target = self
        menu.addItem(pasteMI)

        menu.addItem(.separator())

        // Rename  F2 (no modifier — use empty keyEquivalent, show "F2" hint)
        let renameMI = NSMenuItem(title: "Rename", action: hasSelection && items.count == 1 ? #selector(contextRename(_:)) : nil, keyEquivalent: "")
        renameMI.target = self
        menu.addItem(renameMI)

        // Delete  ⌘⌫
        let deleteMI = NSMenuItem(title: "Delete", action: hasSelection ? #selector(contextDelete(_:)) : nil, keyEquivalent: "\u{08}")
        deleteMI.keyEquivalentModifierMask = [.command]
        deleteMI.target = self
        menu.addItem(deleteMI)

        menu.addItem(.separator())

        // New Folder  ⌘⇧N
        let newFolderMI = NSMenuItem(title: "New Folder", action: #selector(contextNewFolder(_:)), keyEquivalent: "n")
        newFolderMI.keyEquivalentModifierMask = [.command, .shift]
        newFolderMI.target = self
        menu.addItem(newFolderMI)

        // Properties  ⌘I  (single selection only)
        if hasSelection && items.count == 1 {
            menu.addItem(.separator())
            let propMI = NSMenuItem(title: "Properties", action: #selector(contextProperties(_:)), keyEquivalent: "i")
            propMI.keyEquivalentModifierMask = [.command]
            propMI.target = self
            menu.addItem(propMI)
        }
    }

    // MARK: - Context Menu Actions

    @objc func contextOpen(_ sender: Any?) {
        // Selecting several folders and hitting Enter used to navigate once per folder —
        // each call tore down and rebuilt the FSEvent stream, piled onto backStack, and
        // left the window on whichever folder happened to be last in selection order.
        // Every file still opens; navigation only makes sense for exactly one folder.
        let items = selectedItems
        for item in items where !item.isDirectory { NSWorkspace.shared.open(item.url) }
        let directories = items.filter(\.isDirectory)
        if directories.count == 1 { onNavigate?(directories[0].url) }
    }

    @objc func contextCopy(_ sender: Any?) {
        let urls = selectedItems.map(\.url) as [NSURL]
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()   // drops any stale "move" marker along with the old data
        pb.writeObjects(urls)
    }

    @objc func contextCopyPath(_ sender: Any?) {
        let items = selectedItems
        // With nothing selected this used to write an empty string over the clipboard —
        // wiping a pending cut, or whatever another app had just put there — instead of
        // doing nothing. Reachable from ⌘⌥C, which the menu bar left enabled.
        guard !items.isEmpty else { return }
        let paths = items.map(\.url.path).joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(paths, forType: .string)
    }

    @objc func contextCut(_ sender: Any?) {
        let urls = selectedItems.map(\.url) as [NSURL]
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls)
        pb.setString("move", forType: Self.opType)
    }

    @objc func contextPaste(_ sender: Any?) {
        guard let destDir = currentDirectoryURL else { return }
        let pb = NSPasteboard.general
        guard let urls = pb.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
              ) as? [URL],
              !urls.isEmpty else { return }
        let isCut = pb.string(forType: Self.opType) == "move"
        // Another instance can overwrite the clipboard while the copy runs (it can take
        // minutes); only clean up afterwards if it's still ours.
        let changeCountAtStart = pb.changeCount

        // Everything that can be decided without touching the disk is decided here, so
        // the background pass is nothing but copy/move calls.
        var sources: [URL] = []
        var unchanged: Set<URL> = []
        var rejected: [(URL, Error)] = []
        for src in urls {
            // Cutting and pasting into the file's own directory is a no-op, not a rename.
            if isCut, src.deletingLastPathComponent().standardizedFileURL.path
                        == destDir.standardizedFileURL.path {
                unchanged.insert(src)
                continue
            }
            if let error = containmentError(src: src, destDir: destDir, isMove: isCut) {
                rejected.append((src, error))
                continue
            }
            sources.append(src)
        }

        FileOperation.run(kind: isCut ? .move : .copy, sources: sources,
                          destination: destDir, in: view.window) { [weak self] outcome in
            let errors = rejected + outcome.errors
            if isCut, pb.changeCount == changeCountAtStart {
                // Whatever actually moved is spent; what failed — or never ran because
                // the user cancelled — stays on the clipboard, ready to paste again.
                pb.clearContents()
                // `unchanged` belongs here too: cut three files, paste into the folder
                // they're already in, and nothing moved — the user still means to paste
                // them somewhere else, so the cut must survive.
                let leftover = sources.filter { !outcome.processed.contains($0) }
                    + rejected.map(\.0) + unchanged
                if !leftover.isEmpty {
                    pb.writeObjects(leftover as [NSURL])
                    pb.setString("move", forType: Self.opType)
                }
            }
            guard let self else { return }
            self.loadDirectory(destDir, selecting: outcome.resulting.union(unchanged))
            self.showFileOperationError(title: "Paste Failed", errors: errors)
        }
    }

    @objc func contextRename(_ sender: Any?) {
        guard let item = selectedItems.first else { return }
        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.informativeText = "Enter new name:"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = item.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        presentAlert(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let newName = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !newName.isEmpty, newName != item.name, Self.isValidFileName(newName) else {
                NSSound.beep(); return
            }
            let newURL = item.url.deletingLastPathComponent().appendingPathComponent(newName)
            do {
                try FileManager.default.moveItem(at: item.url, to: newURL)
                if let dir = self.currentDirectoryURL {
                    self.loadDirectory(dir, selecting: [newURL])
                }
            } catch {
                self.showFileOperationError(title: "Rename Failed",
                                            errors: [(item.url, error)])
            }
        }
    }

    @objc func contextDelete(_ sender: Any?) {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        FileOperation.run(kind: .trash, sources: urls, destination: nil,
                          in: view.window) { [weak self] outcome in
            guard let self else { return }
            if let dir = self.currentDirectoryURL {
                self.loadDirectory(dir, selecting: Set(outcome.errors.map(\.0)))
            }
            self.showFileOperationError(title: "Delete Failed", errors: outcome.errors)
        }
    }

    @objc func contextProperties(_ sender: Any?) {
        guard let item = selectedItems.first else { return }
        PropertiesPanel.show(for: item)
    }

    @objc func contextNewFolder(_ sender: Any?) {
        guard let destDir = currentDirectoryURL else { return }
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Enter folder name:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = "untitled folder"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        presentAlert(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, Self.isValidFileName(name) else { NSSound.beep(); return }
            let newURL = destDir.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: newURL,
                                                        withIntermediateDirectories: false)
                self.loadDirectory(destDir, selecting: [newURL])
            } catch {
                self.showFileOperationError(title: "New Folder Failed",
                                            errors: [(newURL, error)])
            }
        }
    }

    /// Rejects a name containing a path separator, so Rename/New Folder can't silently
    /// relocate a file — `appendingPathComponent("a/b")` walks into (or creates) a
    /// subdirectory `a` instead of naming the item `a/b`, and the user has no way to
    /// tell that happened from the dialog alone. `:` is included because HFS+ paths
    /// once used it as the separator and some APIs still choke on it in a filename.
    private static func isValidFileName(_ name: String) -> Bool {
        !name.contains("/") && !name.contains(":") && name != "." && name != ".."
    }

    /// Rejects copying or moving a folder into itself or into one of its own descendants.
    ///
    /// Without this, `copyItem` walks into the copy it is making: it recurses until the
    /// path hits the system limit, ~0.09s later, leaving a few hundred nested junk
    /// directories behind and reporting "the file name is invalid" — an error nobody can
    /// act on. Finder refuses the operation up front instead, and so do we.
    ///
    /// - Returns: `nil` if the operation is allowed, otherwise the error to report.
    private func containmentError(src: URL, destDir: URL, isMove: Bool) -> Error? {
        let srcPath = src.standardizedFileURL.path
        let destPath = destDir.standardizedFileURL.path
        guard destPath == srcPath || destPath.hasPrefix(srcPath + "/") else { return nil }
        let verb = isMove ? "move" : "copy"
        let message = destPath == srcPath
            ? "You can't \(verb) \"\(src.lastPathComponent)\" into itself."
            : "You can't \(verb) \"\(src.lastPathComponent)\" into a folder inside itself."
        return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInvalidFileNameError,
                       userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - Drop Target

    /// Single source of truth for "copy or move?", shared by validate and accept so the
    /// badge under the cursor always matches what actually happens.
    ///
    /// `draggingSourceOperationMask` is what the *source* permits, not what we chose, so
    /// it can't answer this question — Finder always permits move, which is how every
    /// drag in from Finder used to delete the original. Copy is the safe default;
    /// Command opts into move.
    private func resolvedDragOperation(_ info: any NSDraggingInfo, source: NSView) -> NSDragOperation {
        if info.draggingSource as AnyObject? === source { return [] }  // drop onto itself
        let op: NSDragOperation = NSEvent.modifierFlags.contains(.command) ? .move : .copy
        validatedDragOperation = op
        return op
    }

    /// What the last `validateDrop` decided — the badge the user is looking at when they
    /// let go. `NSEvent.modifierFlags` is live state, so asking it a second time in
    /// `acceptDrop` could answer "move" for a drag that showed the copy badge (or the
    /// reverse) if Command changed in between. The badge wins.
    private var validatedDragOperation: NSDragOperation?

    private func acceptFileDrop(info: any NSDraggingInfo, source: NSView) -> Bool {
        guard let destDir = currentDirectoryURL else { return false }
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        // Falls back to a fresh read only if accept somehow arrives without a validate.
        let isMove = (validatedDragOperation
                      ?? resolvedDragOperation(info, source: source)) == .move
        validatedDragOperation = nil
        var sources: [URL] = []
        var unchanged: Set<URL> = []
        var rejected: [(URL, Error)] = []
        for src in urls {
            // Dropping onto the directory an item already sits in is a no-op, for copy
            // as much as for move — Finder does nothing in either case. Reachable by
            // dragging between two windows showing the same directory, where the copy
            // branch would otherwise silently produce "file 2.txt".
            if src.deletingLastPathComponent().standardizedFileURL.path
                == destDir.standardizedFileURL.path {
                unchanged.insert(src)
                continue
            }
            if let error = containmentError(src: src, destDir: destDir, isMove: isMove) {
                rejected.append((src, error))
                continue
            }
            sources.append(src)
        }
        FileOperation.run(kind: isMove ? .move : .copy, sources: sources,
                          destination: destDir, in: view.window) { [weak self] outcome in
            guard let self else { return }
            self.loadDirectory(destDir, selecting: outcome.resulting.union(unchanged))
            self.showFileOperationError(title: "Drop Failed",
                                        errors: rejected + outcome.errors)
        }
        // The copy hasn't happened yet, so there is no success/failure to report back to
        // the drag session — accepting means "these files are mine to deal with", and
        // anything that goes wrong surfaces in the sheet above.
        return true
    }

    // MARK: - Folder Size Calculation

    /// Re-scan the rows the user can actually see, in Details mode only — the Size
    /// column doesn't exist in the other two, so any work done for them is thrown away.
    ///
    /// - Parameter retryTruncated: also re-run scans that hit their budget last time.
    ///   The periodic timer leaves those alone (retrying "> 1.2 GB" every five minutes
    ///   would spend the same budget again for the same answer), but an explicit
    ///   F5 / Cmd+R is the user asking for a real recompute, and the folder may have
    ///   shrunk since the scan that got truncated.
    func refreshFolderSizes(retryTruncated: Bool = false) {
        guard viewMode == 0 else { return }
        let rows = tableView.rows(in: tableView.visibleRect)
        guard rows.location != NSNotFound else { return }
        for row in rows.location..<(rows.location + rows.length) where row < entries.count {
            let item = entries[row]
            if item.isDirectory {
                startFolderSizeCalc(for: item, force: true, retryTruncated: retryTruncated)
            }
        }
    }

    /// How long one row's size scan may run before it settles for a lower bound.
    /// Three of these can be in flight at once (`folderSizeQueue`), so this is the cap
    /// on how long opening a folder of huge subfolders keeps cores busy — not per app.
    private static let folderSizeDeadline: TimeInterval = 5

    /// - Parameter force: recompute even if a size is already cached (periodic refresh).
    ///   The cached value stays on screen until the new one arrives, so nothing flickers.
    /// - Parameter retryTruncated: see `refreshFolderSizes`.
    private func startFolderSizeCalc(for item: FileItem, force: Bool = false,
                                     retryTruncated: Bool = false) {
        let url = item.url
        guard !calculatingFolderSizes.contains(url) else { return }
        if let cached = folderSizeCache[url] {
            guard force, (retryTruncated || !cached.truncated) else { return }
        }
        calculatingFolderSizes.insert(url)
        let gen = loadGeneration
        let op = BlockOperation()
        op.addExecutionBlock { [weak self, weak op] in
            // Started here, not at enqueue time: the queue runs 3 at a time, so a row
            // near the bottom can wait seconds for a slot and would arrive expired.
            let deadline = Date().addingTimeInterval(Self.folderSizeDeadline)
            let size = calculateDirectorySize(url, deadline: deadline) {
                op?.isCancelled ?? true
            }
            if op?.isCancelled ?? true { return }
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == gen else { return }
                self.calculatingFolderSizes.remove(url)
                self.pendingSizeOps.removeAll { $0.url == url }
                self.folderSizeCache[url] = size
                if self.tableView.sortDescriptors.first?.key == "size" {
                    // A row's position, not just its text, depends on this value when
                    // sorted by Size. Coalesced so 20 rows finishing around the same
                    // moment cause one re-sort instead of 20.
                    self.scheduleSizeResort()
                } else if let row = self.entries.firstIndex(where: { $0.url == url }),
                          self.viewMode == 0 {
                    // Reload only the Size cell for this row — avoids full table reload.
                    let colIdx = self.tableView.column(withIdentifier: .init("Size"))
                    if colIdx >= 0 {
                        self.tableView.reloadData(
                            forRowIndexes: IndexSet(integer: row),
                            columnIndexes: IndexSet(integer: colIdx)
                        )
                    }
                }
            }
        }
        pendingSizeOps.append((url: url, op: op))
        if pendingSizeOps.count > Self.maxQueuedFolderScans {
            // Evict the oldest first — they were queued behind the rows the user has
            // most likely already scrolled past. A cancelled scan bails out at the
            // first entry of its enumerator (see calculateDirectorySize's isCancelled
            // check), so this frees a concurrency slot almost immediately rather than
            // waiting out its 5-second budget.
            let overflow = pendingSizeOps.count - Self.maxQueuedFolderScans
            for stale in pendingSizeOps.prefix(overflow) {
                stale.op.cancel()
                calculatingFolderSizes.remove(stale.url)
            }
            pendingSizeOps.removeFirst(overflow)
        }
        folderSizeQueue.addOperation(op)
    }

    private func scheduleSizeResort() {
        guard !sizeResortPending else { return }
        sizeResortPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sizeResortPending = false
            self.applyFilterAndSort(selecting: self.selectedURLs)
        }
    }

    // MARK: - Helpers

    private func openItem(_ item: FileItem) {
        if item.isDirectory {
            onNavigate?(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    /// Assigning `selectionIndexPaths` never invokes the did-select/did-deselect delegate
    /// methods, so the status bar has to be nudged by hand here.
    private func selectCollectionItemForContextMenu() {
        guard let window = collectionView.window else { return }
        let location = collectionView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard let indexPath = collectionView.indexPathForItem(at: location) else {
            // Empty space — see the table branch in menuNeedsUpdate for why this clears.
            guard !collectionView.selectionIndexPaths.isEmpty else { return }
            collectionView.selectionIndexPaths = []
            onSelectionChanged?()
            return
        }
        if !collectionView.selectionIndexPaths.contains(indexPath) {
            collectionView.selectionIndexPaths = [indexPath]
            onSelectionChanged?()
        }
    }

    private func showFileOperationError(title: String, errors: [(URL, Error)]) {
        guard !errors.isEmpty else { return }
        let details = errors.prefix(3).map { url, error in
            "\(url.lastPathComponent): \(error.localizedDescription)"
        }.joined(separator: "\n")
        let extra = errors.count > 3 ? "\n…and \(errors.count - 3) more." : ""
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = details + extra
        presentAlert(alert)
    }

    /// Puts `alert` up as a sheet on this controller's window instead of app-modally.
    ///
    /// `NSAlert.runModal()` blocks the event loop of the whole *process*, so typing a
    /// name into New Folder in window 1 froze window 2 — it wouldn't scroll, click or
    /// close. (Two separate instances were unaffected, which made "open a second
    /// instance" genuinely smoother than "open a second window".)
    ///
    /// Falls back to app-modal when there is no window to attach to, and hands the
    /// response over one turn later so a completion that opens another sheet — the
    /// error alert after a failed rename — doesn't collide with this one closing.
    private func presentAlert(_ alert: NSAlert,
                              completion: ((NSApplication.ModalResponse) -> Void)? = nil) {
        // `view.window` goes nil the moment windowShouldClose detaches the content view,
        // and a file operation now outlives its window. A paste that failed after its
        // window was closed reported the failure through runModal(), freezing every
        // *other* window with exactly the app-modal dialog that sheets were adopted to
        // get rid of. Any live explorer window is a better host than that.
        let host = view.window ?? (NSApp.delegate as? AppDelegate)?.sheetHostWindow
        guard let host else {
            // No window left at all, so app-modal blocks nobody.
            let response = alert.runModal()
            completion?(response)
            return
        }
        alert.beginSheetModal(for: host) { response in
            DispatchQueue.main.async { completion?(response) }
        }
    }

    // MARK: - Table Cell Factories

    private func makeNameCell(for item: FileItem, in tableView: NSTableView) -> NSTableCellView {
        let cellID = NSUserInterfaceItemIdentifier("NameCell")
        let cell = (tableView.makeView(withIdentifier: cellID, owner: self)
                    as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = cellID
            let iv = NSImageView()
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingTail
            iv.translatesAutoresizingMaskIntoConstraints = false
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(iv)
            c.addSubview(tf)
            c.imageView = iv
            c.textField = tf
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16),
                iv.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = item.name
        cell.textField?.font = item.isDirectory
            ? .systemFont(ofSize: 13, weight: .medium) : .systemFont(ofSize: 13)
        cell.textField?.textColor = item.isHidden ? .tertiaryLabelColor : .labelColor
        cell.imageView?.image = IconCache.icon(for: item.url, size: 16)
        return cell
    }

    private func makeTextCell(for item: FileItem, column: String,
                              in tableView: NSTableView) -> NSTableCellView {
        let cellID = NSUserInterfaceItemIdentifier("Cell_\(column)")
        let cell = (tableView.makeView(withIdentifier: cellID, owner: self)
                    as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = cellID
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()

        let text: String
        switch column {
        case "Size":
            if item.isDirectory {
                if let cached = folderSizeCache[item.url] {
                    text = folderSizeStr(cached)
                } else {
                    text = calculatingFolderSizes.contains(item.url) ? "\u{2026}" : "\u{2014}"
                    startFolderSizeCalc(for: item)
                }
            } else {
                text = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
            }
        case "Date":
            text = Self.dateFormatter.string(from: item.modifiedDate)
        case "Kind":
            text = item.kind
        default:
            text = ""
        }
        cell.textField?.stringValue = text
        cell.textField?.font = .systemFont(ofSize: 13)
        cell.textField?.textColor = item.isHidden ? .tertiaryLabelColor : .secondaryLabelColor
        return cell
    }
}

// MARK: - Menu validation

/// The Edit menu reaches these three through the responder chain, and AppKit enables an
/// item as soon as *some* responder implements its selector. So Cut, Copy and Paste sat
/// enabled with nothing selected and with a clipboard holding no files, and picking them
/// did nothing at all — while the context menu, which computes the same two conditions in
/// `menuNeedsUpdate`, greyed them out correctly. The conditions below are deliberately the
/// same expressions, so the two menus can't drift apart again.
extension FileTableViewController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)):
            return selectedCount > 0
        case #selector(paste(_:)):
            return NSPasteboard.general.canReadObject(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        default:
            return true
        }
    }
}

// MARK: - Icon Cell (grid view — 48px icon + name below)

class IconCell: NSCollectionViewItem {
    private var currentURL: URL?  // tracks which file this cell is showing
    private var pendingThumb: QLThumbnailGenerator.Request?

    // QuickLook caches internally, but every request is still an IPC round-trip, and
    // configure() runs on each scroll and each reloadData(). Keying on modification date
    // and size means a file rewritten on disk misses the cache instead of showing stale
    // pixels, so nothing has to invalidate this by hand.
    private static let thumbCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 512
        // 512 thumbnails is ~18 MB at @2x but ~40 MB at @3x, doubled again with a second
        // instance open. Cost the entries in bytes so the ceiling is the memory, not a
        // count that means something different on every display.
        cache.totalCostLimit = 32 << 20
        return cache
    }()

    private static func cost(of image: NSImage) -> Int {
        image.representations.reduce(0) { $0 + $1.pixelsWide * $1.pixelsHigh * 4 }
    }

    private static func thumbKey(_ item: FileItem) -> NSString {
        "\(item.url.path)|\(item.modifiedDate.timeIntervalSinceReferenceDate)|\(item.size)"
            as NSString
    }

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 96, height: 84))
        v.wantsLayer = true
        v.layer?.cornerRadius = 6

        let iv = NSImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.imageScaling = .scaleProportionallyUpOrDown
        v.addSubview(iv)

        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.alignment = .center
        tf.lineBreakMode = .byTruncatingMiddle
        tf.maximumNumberOfLines = 2
        tf.font = .systemFont(ofSize: 11)
        v.addSubview(tf)

        self.view = v
        self.imageView = iv
        self.textField = tf

        NSLayoutConstraint.activate([
            iv.topAnchor.constraint(equalTo: v.topAnchor, constant: 6),
            iv.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            iv.widthAnchor.constraint(equalToConstant: 48),
            iv.heightAnchor.constraint(equalToConstant: 48),
            tf.topAnchor.constraint(equalTo: iv.bottomAnchor, constant: 2),
            tf.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            tf.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -2),
        ])
    }

    /// Every request is an IPC round-trip to ThumbnailsAgent plus an image decode, and a
    /// cell that has scrolled away — or been pointed at another file by a reload — has no
    /// use for the answer. Without this, flicking through a folder of a few thousand images
    /// leaves that many requests queued against a system-wide agent, all still billed to
    /// this app, and doubled when a second instance is open.
    private func cancelPendingThumb() {
        if let request = pendingThumb { QLThumbnailGenerator.shared.cancel(request) }
        pendingThumb = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelPendingThumb()
        currentURL = nil
        // An index past the end of `entries` (a reload landing mid-layout) hands this
        // cell back via makeItem without a configure() call — without clearing here, it
        // keeps showing the previous file's name and icon until scrolled again.
        textField?.stringValue = ""
        imageView?.image = nil
    }

    func configure(with item: FileItem) {
        cancelPendingThumb()
        currentURL = item.url
        textField?.stringValue = item.name
        textField?.textColor = item.isHidden ? .tertiaryLabelColor : .labelColor
        textField?.font = item.isDirectory ? .systemFont(ofSize: 11, weight: .medium)
            : .systemFont(ofSize: 11)

        let key = Self.thumbKey(item)
        let cached = item.isDirectory ? nil : Self.thumbCache.object(forKey: key)

        if let cached {
            imageView?.image = cached
        } else {
            // Generic icon stands in until the thumbnail arrives
            imageView?.image = IconCache.icon(for: item.url, size: 48)
        }

        // Request QuickLook thumbnail for files (not directories)
        if !item.isDirectory, cached == nil {
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            let request = QLThumbnailGenerator.Request(
                fileAt: item.url,
                size: CGSize(width: 48, height: 48),
                scale: scale,
                representationTypes: .thumbnail
            )
            let url = item.url
            pendingThumb = request
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
                // This runs off the main thread; currentURL belongs to the main thread, so
                // the recycled-cell check happens only after the hop below.
                guard let rep else { return }
                DispatchQueue.main.async {
                    let image = rep.nsImage
                    // Cache first: the result is worth keeping even if this cell has been
                    // recycled onto a different file while the thumbnail was in flight.
                    Self.thumbCache.setObject(image, forKey: key, cost: Self.cost(of: image))
                    guard let self, self.currentURL == url else { return }
                    self.pendingThumb = nil
                    self.imageView?.image = image
                }
            }
        }
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
                : nil
        }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet {
            if !isSelected {
                view.layer?.backgroundColor = highlightState == .forSelection
                    ? NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
                    : nil
            }
        }
    }
}

// MARK: - List Cell (compact — 16px icon + name)

class ListCell: NSCollectionViewItem {
    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        v.wantsLayer = true
        v.layer?.cornerRadius = 3

        let iv = NSImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.imageScaling = .scaleProportionallyUpOrDown
        v.addSubview(iv)

        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingTail
        tf.font = .systemFont(ofSize: 12)
        v.addSubview(tf)

        self.view = v
        self.imageView = iv
        self.textField = tf

        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
            iv.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 16),
            iv.heightAnchor.constraint(equalToConstant: 16),
            tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
    }

    func configure(with item: FileItem) {
        textField?.stringValue = item.name
        textField?.textColor = item.isHidden ? .tertiaryLabelColor : .labelColor
        textField?.font = item.isDirectory ? .systemFont(ofSize: 12, weight: .medium)
            : .systemFont(ofSize: 12)
        imageView?.image = IconCache.icon(for: item.url, size: 16)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // See IconCell.prepareForReuse: an out-of-bounds index hands this cell back
        // without a configure() call, so it would otherwise keep showing the last file
        // it displayed.
        textField?.stringValue = ""
        imageView?.image = nil
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
                : nil
        }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet {
            if !isSelected {
                view.layer?.backgroundColor = highlightState == .forSelection
                    ? NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
                    : nil
            }
        }
    }
}

// MARK: - Properties Panel

final class PropertiesPanel: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    // Retain open panels so they stay alive without a parent controller.
    private static var openPanels: [PropertiesPanel] = []

    /// The size the user asked for by name, so it gets a longer leash than a table row
    /// that merely scrolled into view — but a leash all the same. Measured: a full home
    /// directory is ~1.1 M entries / ~28 s, so these two land just wide enough to answer
    /// ⌘I on `~` exactly instead of shrugging with a lower bound.
    static let sizeDeadline: TimeInterval = 30
    static let sizeLimit = 2_000_000

    fileprivate static let sizeQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    /// Held so `windowWillClose` can cancel a scan still walking the subtree.
    fileprivate var sizeOp: Operation?
    /// Held so `windowWillClose` can cancel the image-metadata read (`buildImageSection`).
    fileprivate var imageOp: Operation?
    /// Held so `windowWillClose` can cancel the AVAsset property loads (`buildAVSection`).
    fileprivate var avTask: Task<Void, Never>?

    static var hasOpenPanels: Bool { !openPanels.isEmpty }

    static func show(for item: FileItem) {
        let p = PropertiesPanel(for: item)
        openPanels.append(p)
        p.panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        sizeOp?.cancel()
        sizeOp = nil
        imageOp?.cancel()
        imageOp = nil
        avTask?.cancel()
        avTask = nil
        PropertiesPanel.openPanels.removeAll { $0 === self }
        // The last explorer window may have closed while this panel was up; that path
        // deliberately skips exit(0) so the panel survives, so close the app out here.
        if PropertiesPanel.openPanels.isEmpty,
           (NSApp.delegate as? AppDelegate)?.windows.isEmpty == true {
            FileOperation.exitWhenIdle()
        }
    }

    private init(for item: FileItem) {
        panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable],
                        backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.title = "\(item.name) — Properties"
        panel.isFloatingPanel = true
        panel.level = .floating
        buildContent(for: item)
        panel.center()
    }

    private let panelW: CGFloat = 340
    private let pad: CGFloat    = 16
    private let keyW: CGFloat   = 96
    private let rowH: CGFloat   = 20
    private var innerW: CGFloat { panelW - pad * 2 }

    // MARK: - Content

    private func buildContent(for item: FileItem) {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment   = .left
        root.spacing     = 6
        root.translatesAutoresizingMaskIntoConstraints = false
        root.widthAnchor.constraint(equalToConstant: innerW).isActive = true

        addHeader(item: item, to: root)
        addSep(to: root)

        // ── General ─────────────────────────────────────────────────────
        addSectionTitle("General", to: root)
        let sizeL = addRow("Size", to: root,
                           value: item.isDirectory ? "Calculating…" : propSizeStr(item.size))
        addRow("Location", to: root, value: item.url.deletingLastPathComponent().path)
        if let cd = try? item.url.resourceValues(forKeys: [.creationDateKey]).creationDate {
            addRow("Created",  to: root, value: propDateStr(cd))
        }
        addRow("Modified", to: root, value: propDateStr(item.modifiedDate))
        if let attrs = try? FileManager.default.attributesOfItem(atPath: item.url.path),
           let posix = attrs[.posixPermissions] as? Int {
            addRow("Permissions", to: root, value: propPosixStr(posix))
        }

        // Folder size (async). Kept in an operation rather than a bare global-queue
        // block so closing the panel actually stops the scan — ⌘I on `/` otherwise
        // walks the whole volume with no way to call it off.
        if item.isDirectory {
            let url = item.url
            let op = BlockOperation()
            op.addExecutionBlock { [weak op, weak sizeL] in
                let deadline = Date().addingTimeInterval(PropertiesPanel.sizeDeadline)
                let sz = calculateDirectorySize(
                    url,
                    limit: PropertiesPanel.sizeLimit,
                    deadline: deadline) { op?.isCancelled ?? true }
                if op?.isCancelled ?? true { return }
                DispatchQueue.main.async { sizeL?.stringValue = propSizeStr(sz) }
            }
            sizeOp = op
            PropertiesPanel.sizeQueue.addOperation(op)
        }

        // ── Media section ────────────────────────────────────────────────
        if !item.isDirectory {
            // A UTType guessed from the extension misses extension-less files and any
            // extension LaunchServices doesn't recognize by name alone; the resource
            // value resolves the type the same way Finder and FileItem.kind do.
            let uti = try? item.url.resourceValues(forKeys: [.contentTypeKey]).contentType
            if uti?.conforms(to: .image) == true {
                addSep(to: root)
                buildImageSection(item: item, in: root)
            } else if uti?.conforms(to: .audiovisualContent) == true
                        || uti?.conforms(to: .audio) == true {
                addSep(to: root)
                buildAVSection(item: item, in: root)
            }
        }

        // Wrap with padding
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor,        constant: pad),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
        ])
        root.widthAnchor.constraint(equalToConstant: innerW).isActive = true
        panel.contentView = content
        content.widthAnchor.constraint(equalToConstant: panelW).isActive = true
        root.layoutSubtreeIfNeeded()
        let h = root.fittingSize.height + pad * 2
        panel.setContentSize(NSSize(width: panelW, height: max(h, 120)))
    }

    // MARK: - Section builders

    private func addHeader(item: FileItem, to stack: NSStackView) {
        let iv = NSImageView(image: IconCache.icon(for: item.url, size: 48))
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.widthAnchor.constraint(equalToConstant:  48).isActive = true
        iv.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let nameL = NSTextField(labelWithString: item.name)
        nameL.font = .systemFont(ofSize: 13, weight: .semibold)
        nameL.lineBreakMode = .byTruncatingMiddle

        let kindL = NSTextField(labelWithString: item.kind)
        kindL.font = .systemFont(ofSize: 12)
        kindL.textColor = .secondaryLabelColor

        let vStack = NSStackView(views: [nameL, kindL])
        vStack.orientation = .vertical
        vStack.alignment   = .leading
        vStack.spacing     = 2

        let hStack = NSStackView(views: [iv, vStack])
        hStack.orientation = .horizontal
        hStack.spacing     = 12
        hStack.alignment   = .centerY
        hStack.translatesAutoresizingMaskIntoConstraints = false
        hStack.widthAnchor.constraint(equalToConstant: innerW).isActive = true

        stack.addArrangedSubview(hStack)
        stack.setCustomSpacing(10, after: hStack)
    }

    private func buildImageSection(item: FileItem, in stack: NSStackView) {
        addSectionTitle("Image", to: stack)
        let dimL    = addRow("Dimensions",   to: stack, value: "Loading…")
        let dpiL    = addRow("Resolution",   to: stack, value: "—")
        let depthL  = addRow("Color depth",  to: stack, value: "—")
        let colorL  = addRow("Color model",  to: stack, value: "—")
        let cameraL = addRow("Camera",       to: stack, value: "—")
        let apL     = addRow("Aperture",     to: stack, value: "—")
        let shutL   = addRow("Exposure",     to: stack, value: "—")
        let isoL    = addRow("ISO",          to: stack, value: "—")
        let focalL  = addRow("Focal length", to: stack, value: "—")

        let url = item.url
        let op = BlockOperation()
        op.addExecutionBlock { [weak op] in
            let opts = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let src = CGImageSourceCreateWithURL(url as CFURL, opts),
                  let raw = CGImageSourceCopyPropertiesAtIndex(src, 0, opts) as? [CFString: Any]
            else {
                if op?.isCancelled ?? true { return }
                DispatchQueue.main.async { dimL.stringValue = "—" }
                return
            }
            if op?.isCancelled ?? true { return }

            let tiff  = raw[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            let exif  = raw[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let pw    = raw[kCGImagePropertyPixelWidth]   as? Int
            let ph    = raw[kCGImagePropertyPixelHeight]  as? Int
            let dpiW  = raw[kCGImagePropertyDPIWidth]     as? Double
            let dpiH  = raw[kCGImagePropertyDPIHeight]    as? Double
            let depth = raw[kCGImagePropertyDepth]        as? Int
            let color = raw[kCGImagePropertyColorModel]   as? String
            let make  = tiff?[kCGImagePropertyTIFFMake]   as? String
            let model = tiff?[kCGImagePropertyTIFFModel]  as? String
            let fnum  = exif?[kCGImagePropertyExifFNumber]            as? Double
            let exp   = exif?[kCGImagePropertyExifExposureTime]       as? Double
            let isoV  = (exif?[kCGImagePropertyExifISOSpeedRatings]   as? [Int])?.first
            let focal = exif?[kCGImagePropertyExifFocalLength]        as? Double

            if op?.isCancelled ?? true { return }
            DispatchQueue.main.async {
                dimL.stringValue   = pw != nil && ph != nil ? "\(pw!) × \(ph!) px" : "—"
                dpiL.stringValue   = dpiW != nil ? "\(Int(dpiW!)) × \(Int(dpiH ?? dpiW!)) DPI" : "—"
                depthL.stringValue = depth != nil ? "\(depth!)-bit" : "—"
                colorL.stringValue = color ?? "—"

                let cam: String
                switch (make, model) {
                case let (mk?, md?) where !(md.hasPrefix(mk)): cam = "\(mk) \(md)"
                case let (_, md?): cam = md
                case let (mk?, _): cam = mk
                default:           cam = "—"
                }
                cameraL.stringValue = cam
                apL.stringValue     = fnum != nil ? "ƒ/\(String(format: "%.1f", fnum!))" : "—"
                if let e = exp {
                    shutL.stringValue = e < 1
                        ? "1/\(Int((1.0 / e).rounded())) s"
                        : String(format: "%.2f s", e)
                }
                isoL.stringValue   = isoV  != nil ? "ISO \(isoV!)" : "—"
                focalL.stringValue = focal != nil ? "\(Int(focal!)) mm" : "—"
            }
        }
        imageOp = op
        PropertiesPanel.sizeQueue.addOperation(op)
    }

    private func buildAVSection(item: FileItem, in stack: NSStackView) {
        let uti = try? item.url.resourceValues(forKeys: [.contentTypeKey]).contentType
        // Audio types conform to .audiovisualContent too (public.mp3 does), so that test
        // labelled every sound file as video and left the video rows showing "—".
        let isVideo = uti?.conforms(to: .movie) == true

        addSectionTitle(isVideo ? "Video" : "Audio", to: stack)
        let durL   = addRow("Duration",    to: stack, value: "Loading…")
        let dimL   = isVideo ? addRow("Dimensions",  to: stack, value: "—") : nil
        let fpsL   = isVideo ? addRow("Frame rate",  to: stack, value: "—") : nil
        let vCodeL = isVideo ? addRow("Video codec", to: stack, value: "—") : nil
        let vRateL = isVideo ? addRow("Video rate",  to: stack, value: "—") : nil
        let aCodeL = addRow("Audio codec",  to: stack, value: "—")
        let aChanL = addRow("Channels",     to: stack, value: "—")
        let aSrL   = addRow("Sample rate",  to: stack, value: "—")
        let aBrL   = addRow("Audio rate",   to: stack, value: "—")

        let url = item.url
        avTask = Task { @MainActor in
            let asset = AVAsset(url: url)
            guard let duration = try? await asset.load(.duration) else {
                if !Task.isCancelled { durL.stringValue = "—" }
                return
            }
            if Task.isCancelled { return }
            durL.stringValue = propDurationStr(CMTimeGetSeconds(duration))

            if Task.isCancelled { return }
            if isVideo, let vt = try? await asset.loadTracks(withMediaType: .video).first {
                if let sz  = try? await vt.load(.naturalSize) {
                    dimL?.stringValue = "\(Int(abs(sz.width))) × \(Int(abs(sz.height)))"
                }
                if let fps = try? await vt.load(.nominalFrameRate) {
                    fpsL?.stringValue = String(format: "%.3g fps", fps)
                }
                if let br  = try? await vt.load(.estimatedDataRate) {
                    vRateL?.stringValue = propBitrateStr(Double(br))
                }
                if let desc = try? await vt.load(.formatDescriptions).first {
                    vCodeL?.stringValue = propCodecName(CMFormatDescriptionGetMediaSubType(desc))
                }
            }

            if Task.isCancelled { return }
            if let at = try? await asset.loadTracks(withMediaType: .audio).first {
                if let desc = try? await at.load(.formatDescriptions).first {
                    aCodeL.stringValue = propCodecName(CMFormatDescriptionGetMediaSubType(desc))
                    if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
                        let ch = Int(asbd.pointee.mChannelsPerFrame)
                        aChanL.stringValue = ch == 1 ? "Mono" : ch == 2 ? "Stereo" : "\(ch) ch"
                        let sr  = asbd.pointee.mSampleRate / 1000
                        let bpc = asbd.pointee.mBitsPerChannel
                        aSrL.stringValue = bpc > 0
                            ? String(format: "%.3g kHz  %d-bit", sr, bpc)
                            : String(format: "%.3g kHz", sr)
                    }
                }
                if let br = try? await at.load(.estimatedDataRate) {
                    aBrL.stringValue = propBitrateStr(Double(br))
                }
            }
        }
    }

    // MARK: - Layout helpers

    private func addSep(to stack: NSStackView) {
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.widthAnchor.constraint(equalToConstant: innerW).isActive = true
        sep.heightAnchor.constraint(equalToConstant: 1).isActive = true
        stack.addArrangedSubview(sep)
        stack.setCustomSpacing(8, after: sep)
    }

    private func addSectionTitle(_ title: String, to stack: NSStackView) {
        let l = NSTextField(labelWithString: title.uppercased())
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(l)
        stack.setCustomSpacing(4, after: l)
    }

    @discardableResult
    private func addRow(_ key: String, to stack: NSStackView, value: String) -> NSTextField {
        let keyL = NSTextField(labelWithString: key + ":")
        keyL.font = .systemFont(ofSize: 12, weight: .medium)
        keyL.textColor = .secondaryLabelColor
        keyL.alignment = .right
        keyL.translatesAutoresizingMaskIntoConstraints = false
        keyL.widthAnchor.constraint(equalToConstant: keyW).isActive = true

        let valL = NSTextField(labelWithString: value)
        valL.font = .systemFont(ofSize: 12)
        valL.lineBreakMode = .byTruncatingTail
        valL.isSelectable = true
        valL.translatesAutoresizingMaskIntoConstraints = false

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: innerW).isActive = true
        row.heightAnchor.constraint(equalToConstant: rowH).isActive  = true
        row.addSubview(keyL)
        row.addSubview(valL)
        NSLayoutConstraint.activate([
            keyL.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            keyL.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            valL.leadingAnchor.constraint(equalTo: keyL.trailingAnchor, constant: 8),
            valL.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            valL.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        stack.addArrangedSubview(row)
        return valL
    }
}

// MARK: - Shared fileprivate helpers (FileTableViewController + PropertiesPanel)

/// A directory size, plus whether the scan gave up before reaching the bottom.
/// `truncated` means `bytes` is a lower bound, and the UI says so with a "> " prefix.
struct FolderSize {
    var bytes: Int64
    var truncated: Bool
}

/// Walks the whole subtree, but never without a ceiling: a folder holding a deep
/// `node_modules` (or `/`) would otherwise pin a core for as long as it takes, and
/// nothing about the row tells the user that in advance.
///
/// - Parameter limit: stop after this many entries have been visited.
/// - Parameter deadline: stop once this instant has passed. Checked every 512 entries,
///   because `Date()` per entry costs more than the `resourceValues` call it guards.
/// - Parameter isCancelled: polled per entry so a scan of, say, `/System` stops when
///   the user navigates away instead of running to completion in the background.
fileprivate func calculateDirectorySize(
    _ url: URL,
    limit: Int = 200_000,
    deadline: Date = .distantFuture,
    isCancelled: () -> Bool = { false }
) -> FolderSize {
    let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
    guard let e = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: keys, options: []) else {
        return FolderSize(bytes: 0, truncated: false)
    }
    var total: Int64 = 0
    var visited = 0
    for case let u as URL in e {
        if isCancelled() { return FolderSize(bytes: total, truncated: true) }
        visited += 1
        if visited > limit { return FolderSize(bytes: total, truncated: true) }
        if visited % 512 == 0, Date() > deadline {
            return FolderSize(bytes: total, truncated: true)
        }
        guard let v = try? u.resourceValues(forKeys: Set(keys)),
              v.isRegularFile == true, let s = v.fileSize else { continue }
        total += Int64(s)
    }
    return FolderSize(bytes: total, truncated: false)
}

/// "1.2 GB", or "> 1.2 GB" when the scan hit its budget.
fileprivate func folderSizeStr(_ size: FolderSize) -> String {
    let hr = ByteCountFormatter.string(fromByteCount: size.bytes, countStyle: .file)
    return size.truncated ? "> \(hr)" : hr
}

fileprivate func propSizeStr(_ bytes: Int64) -> String {
    let hr    = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    let exact = NumberFormatter.localizedString(from: NSNumber(value: bytes), number: .decimal)
    return "\(hr) (\(exact) bytes)"
}

/// Same, but says out loud when the scan stopped early rather than quietly reporting
/// a partial total as if it were the answer.
fileprivate func propSizeStr(_ size: FolderSize) -> String {
    let base = propSizeStr(size.bytes)
    return size.truncated ? "\(base), scan stopped early" : base
}

fileprivate func propDateStr(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateStyle = .medium; f.timeStyle = .short
    return f.string(from: date)
}

fileprivate func propPosixStr(_ mode: Int) -> String {
    var s = ""
    for sh in stride(from: 6, through: 0, by: -3) {
        s += (mode >> (sh + 2)) & 1 == 1 ? "r" : "-"
        s += (mode >> (sh + 1)) & 1 == 1 ? "w" : "-"
        s += (mode >>  sh)      & 1 == 1 ? "x" : "-"
    }
    return "\(s)  (\(String(mode, radix: 8)))"
}

fileprivate func propDurationStr(_ secs: Double) -> String {
    guard secs.isFinite, secs >= 0 else { return "—" }
    let h = Int(secs) / 3600
    let m = (Int(secs) % 3600) / 60
    let s = Int(secs) % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                 : String(format: "%d:%02d", m, s)
}

fileprivate func propBitrateStr(_ bps: Double) -> String {
    if bps >= 1_000_000 { return String(format: "%.1f Mbps", bps / 1_000_000) }
    if bps >= 1_000     { return String(format: "%.0f kbps", bps / 1_000) }
    return "\(Int(bps)) bps"
}

fileprivate func propCodecName(_ type: FourCharCode) -> String {
    switch type {
    case kCMVideoCodecType_H264:             return "H.264 (AVC)"
    case kCMVideoCodecType_HEVC:             return "H.265 (HEVC)"
    case kCMVideoCodecType_MPEG4Video:       return "MPEG-4"
    case kCMVideoCodecType_MPEG2Video:       return "MPEG-2"
    case kCMVideoCodecType_AppleProRes422:   return "ProRes 422"
    case kCMVideoCodecType_AppleProRes4444:  return "ProRes 4444"
    case kAudioFormatMPEG4AAC:              return "AAC"
    case kAudioFormatMPEGLayer3:            return "MP3"
    case kAudioFormatLinearPCM:             return "PCM"
    case kAudioFormatAppleLossless:         return "ALAC"
    case kAudioFormatFLAC:                  return "FLAC"
    case kAudioFormatOpus:                  return "Opus"
    default:
        let b: [UInt8] = [(type >> 24) & 0xFF, (type >> 16) & 0xFF,
                          (type >>  8) & 0xFF,  type         & 0xFF].map { UInt8($0) }
        let s = String(bytes: b, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
        return s.isEmpty ? String(format: "0x%08X", type) : s
    }
}
