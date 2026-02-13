import AppKit

// MARK: - Data Model

class SidebarSection {
    let title: String
    let items: [SidebarItem]
    init(title: String, items: [SidebarItem]) {
        self.title = title
        self.items = items
    }
}

class SidebarItem {
    let name: String
    let url: URL
    let icon: NSImage?
    init(name: String, url: URL, icon: NSImage? = nil) {
        self.name = name
        self.url = url
        self.icon = icon ?? NSWorkspace.shared.icon(forFile: url.path)
    }
}

// MARK: - Sidebar View Controller

class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    var sections: [SidebarSection] = []
    var onSelect: ((URL) -> Void)?

    override func loadView() {
        buildSections()

        let column = NSTableColumn(identifier: .init("SidebarColumn"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = false
        outlineView.indentationPerLevel = 12

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true

        // Use scrollView directly as the view
        view = scrollView
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        for section in sections {
            outlineView.expandItem(section)
        }
    }

    private func buildSections() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // Favorites — common folders with SF Symbol icons
        let favDefs: [(String, URL, String)] = [
            ("Home",         home,                                  "house"),
            ("Desktop",      home.appending(path: "Desktop"),       "menubar.dock.rectangle"),
            ("Documents",    home.appending(path: "Documents"),     "doc.on.doc"),
            ("Downloads",    home.appending(path: "Downloads"),     "arrow.down.circle"),
            ("Pictures",     home.appending(path: "Pictures"),      "photo"),
            ("Music",        home.appending(path: "Music"),         "music.note"),
            ("Movies",       home.appending(path: "Movies"),        "film"),
            ("Applications", URL(fileURLWithPath: "/Applications"), "square.grid.2x2"),
        ]
        var favorites: [SidebarItem] = []
        for (name, url, symbol) in favDefs {
            guard fm.fileExists(atPath: url.path) else { continue }
            let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
            favorites.append(SidebarItem(name: name, url: url, icon: icon))
        }

        // System — main disk only
        let system = [
            SidebarItem(name: "Macintosh HD", url: URL(fileURLWithPath: "/"),
                        icon: NSImage(systemSymbolName: "internaldrive",
                                      accessibilityDescription: nil)),
        ]

        sections = [
            SidebarSection(title: "Favorites", items: favorites),
            SidebarSection(title: "System", items: system),
        ]
    }

    func selectItem(for url: URL) {
        for section in sections {
            for item in section.items {
                if item.url == url {
                    let row = outlineView.row(forItem: item)
                    if row >= 0 {
                        outlineView.selectRowIndexes(IndexSet(integer: row),
                                                     byExtendingSelection: false)
                    }
                    return
                }
            }
        }
        outlineView.deselectAll(nil)
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return sections.count }
        if let section = item as? SidebarSection { return section.items.count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return sections[index] }
        if let section = item as? SidebarSection { return section.items[index] }
        fatalError()
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return item is SidebarSection
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        if let section = item as? SidebarSection {
            let tf = NSTextField(labelWithString: section.title.uppercased())
            tf.font = .systemFont(ofSize: 11, weight: .semibold)
            tf.textColor = .secondaryLabelColor
            return tf
        }
        if let sidebarItem = item as? SidebarItem {
            let cellID = NSUserInterfaceItemIdentifier("SidebarCell")
            let cell = (outlineView.makeView(withIdentifier: cellID, owner: self)
                        as? NSTableCellView) ?? makeSidebarCell(cellID)
            cell.textField?.stringValue = sidebarItem.name
            cell.imageView?.image = sidebarItem.icon
            cell.imageView?.image?.size = NSSize(width: 18, height: 18)
            return cell
        }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        return item is SidebarSection
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        return item is SidebarItem
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        return false  // Hide disclosure triangles for a cleaner look
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem else { return }
        onSelect?(item.url)
    }

    // MARK: - Cell Factory

    private func makeSidebarCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let iv = NSImageView()
        let tf = NSTextField(labelWithString: "")
        tf.font = .systemFont(ofSize: 13)
        tf.lineBreakMode = .byTruncatingTail
        iv.translatesAutoresizingMaskIntoConstraints = false
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(iv)
        cell.addSubview(tf)
        cell.imageView = iv
        cell.textField = tf
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 18),
            iv.heightAnchor.constraint(equalToConstant: 18),
            tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
