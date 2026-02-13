import AppKit
import QuickLookThumbnailing

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

    private var allEntries: [FileItem] = []  // unfiltered
    var entries: [FileItem] = []             // filtered + sorted for display
    var showHidden = false
    var searchText = ""
    var viewMode = 0  // 0=Details, 1=Icons, 2=List
    var onNavigate: ((URL) -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onGoUp: (() -> Void)?
    var onRefresh: (() -> Void)?
    private var draggedURLs: [URL] = []  // track dragged files for move

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
                    selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
            case "Size":
                col.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)
            case "Date":
                col.sortDescriptorPrototype = NSSortDescriptor(key: "date", ascending: true)
            case "Kind":
                col.sortDescriptorPrototype = NSSortDescriptor(key: "kind", ascending: true,
                    selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
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
        viewMode = mode
        if mode == 0 {
            scrollView.isHidden = false
            collectionScroll.isHidden = true
            tableView.reloadData()
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
    }

    // MARK: - Cleanup

    func prepareForClose() {
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

    func loadDirectory(_ url: URL) {
        var items = FileItem.loadDirectory(url)
        if !showHidden { items = items.filter { !$0.isHidden } }
        allEntries = items
        applyFilterAndSort()
    }

    func filterBySearch(_ text: String) {
        searchText = text
        applyFilterAndSort()
    }

    private func applyFilterAndSort() {
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
    }

    private func sortEntries() {
        guard let descriptor = tableView.sortDescriptors.first else { return }
        let asc = descriptor.ascending
        switch descriptor.key {
        case "name":
            entries.sort {
                let r = $0.name.localizedCaseInsensitiveCompare($1.name)
                return asc ? r == .orderedAscending : r == .orderedDescending
            }
        case "size":
            entries.sort { asc ? $0.size < $1.size : $0.size > $1.size }
        case "date":
            entries.sort { asc ? $0.modifiedDate < $1.modifiedDate : $0.modifiedDate > $1.modifiedDate }
        case "kind":
            entries.sort {
                let r = $0.kind.localizedCaseInsensitiveCompare($1.kind)
                return asc ? r == .orderedAscending : r == .orderedDescending
            }
        default: break
        }
    }

    // MARK: - Column Sort

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        applyFilterAndSort()
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
        // Only accept drops on the whole table (not between rows)
        if dropOperation == .on { return [] }
        let dominated = info.draggingSourceOperationMask.contains(.move)
            && (info.draggingSource as? NSTableView) !== tableView
        return dominated ? .move : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                    row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        return acceptFileDrop(info: info)
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
        let entry = entries[indexPath.item]
        if viewMode == 1 {
            let cell = cv.makeItem(withIdentifier: .init("IconCell"), for: indexPath) as! IconCell
            cell.configure(with: entry)
            return cell
        } else {
            let cell = cv.makeItem(withIdentifier: .init("ListCell"), for: indexPath) as! ListCell
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
        let dominated = draggingInfo.draggingSourceOperationMask.contains(.move)
            && (draggingInfo.draggingSource as? NSCollectionView) !== cv
        return dominated ? .move : .copy
    }

    func collectionView(_ cv: NSCollectionView, acceptDrop draggingInfo: any NSDraggingInfo,
                         indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        return acceptFileDrop(info: draggingInfo)
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

    private static var isCut = false  // true = cut, false = copy
    var currentDirectoryURL: URL?     // set by FileExplorerWindow on navigate

    // MARK: - Context Menu (NSMenuDelegate)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Select clicked row if not already selected (table view)
        if menu === tableView.menu {
            let clicked = tableView.clickedRow
            if clicked >= 0, !tableView.selectedRowIndexes.contains(clicked) {
                tableView.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
            }
        }

        let items = selectedItems
        let hasSelection = !items.isEmpty
        let hasPasteboard = NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: nil)

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
    }

    // MARK: - Context Menu Actions

    @objc func contextOpen(_ sender: Any?) {
        for item in selectedItems { openItem(item) }
    }

    @objc func contextCopy(_ sender: Any?) {
        let urls = selectedItems.map(\.url) as [NSURL]
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls)
        Self.isCut = false
    }

    @objc func contextCopyPath(_ sender: Any?) {
        let paths = selectedItems.map(\.url.path).joined(separator: "\n")
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
        Self.isCut = true
    }

    @objc func contextPaste(_ sender: Any?) {
        guard let destDir = currentDirectoryURL else { return }
        let pb = NSPasteboard.general
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else { return }
        let fm = FileManager.default
        for src in urls {
            let dst = destDir.appendingPathComponent(src.lastPathComponent)
            let target = uniqueURL(dst)
            if Self.isCut {
                try? fm.moveItem(at: src, to: target)
            } else {
                try? fm.copyItem(at: src, to: target)
            }
        }
        if Self.isCut {
            pb.clearContents()
            Self.isCut = false
        }
        loadDirectory(destDir)
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
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != item.name else { return }
        let newURL = item.url.deletingLastPathComponent().appendingPathComponent(newName)
        try? FileManager.default.moveItem(at: item.url, to: newURL)
        if let dir = currentDirectoryURL { loadDirectory(dir) }
    }

    @objc func contextDelete(_ sender: Any?) {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        for url in urls {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        if let dir = currentDirectoryURL { loadDirectory(dir) }
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
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let newURL = destDir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: newURL, withIntermediateDirectories: false)
        loadDirectory(destDir)
    }

    private func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
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

    // MARK: - Drop Target

    private func acceptFileDrop(info: any NSDraggingInfo) -> Bool {
        guard let destDir = currentDirectoryURL else { return false }
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        let fm = FileManager.default
        let isMove = info.draggingSourceOperationMask.contains(.move)
        for src in urls {
            let dst = uniqueURL(destDir.appendingPathComponent(src.lastPathComponent))
            if isMove {
                try? fm.moveItem(at: src, to: dst)
            } else {
                try? fm.copyItem(at: src, to: dst)
            }
        }
        loadDirectory(destDir)
        return true
    }

    // MARK: - Helpers

    private func openItem(_ item: FileItem) {
        if item.isDirectory {
            onNavigate?(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
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
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: item.url.path)
        cell.imageView?.image?.size = NSSize(width: 16, height: 16)
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
            text = item.isDirectory ? "\u{2014}"
                : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
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

// MARK: - Icon Cell (grid view — 48px icon + name below)

class IconCell: NSCollectionViewItem {
    private var currentURL: URL?  // tracks which file this cell is showing

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

    func configure(with item: FileItem) {
        currentURL = item.url
        textField?.stringValue = item.name
        textField?.textColor = item.isHidden ? .tertiaryLabelColor : .labelColor
        textField?.font = item.isDirectory ? .systemFont(ofSize: 11, weight: .medium)
            : .systemFont(ofSize: 11)

        // Show generic icon immediately as placeholder
        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        icon.size = NSSize(width: 48, height: 48)
        imageView?.image = icon

        // Request QuickLook thumbnail for files (not directories)
        if !item.isDirectory {
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            let request = QLThumbnailGenerator.Request(
                fileAt: item.url,
                size: CGSize(width: 48, height: 48),
                scale: scale,
                representationTypes: .thumbnail
            )
            let url = item.url
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
                guard let self, self.currentURL == url, let rep else { return }
                DispatchQueue.main.async {
                    guard self.currentURL == url else { return }
                    self.imageView?.image = rep.nsImage
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
        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        icon.size = NSSize(width: 16, height: 16)
        imageView?.image = icon
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
