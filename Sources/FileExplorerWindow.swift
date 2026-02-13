import AppKit

class FileExplorerWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let mainVC: MainViewController
    let sidebarVC: SidebarViewController
    let contentVC: FileTableViewController

    var currentDirectory: URL
    var backStack: [URL] = []
    var forwardStack: [URL] = []

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
        window.title = "File Explorer"
        window.contentViewController = mainVC

        // Set size AFTER contentViewController (it can resize the window)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let w = screen.width * 0.85
        let h = screen.height * 0.85
        let x = screen.midX - w / 2
        let y = screen.midY - h / 2
        window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)

        // Callbacks
        sidebarVC.onSelect = { [weak self] url in self?.navigateTo(url) }
        contentVC.onNavigate = { [weak self] url in self?.navigateTo(url) }
        contentVC.onSelectionChanged = { [weak self] in self?.updateStatus() }
        contentVC.onGoUp = { [weak self] in self?.goUp() }
        contentVC.onRefresh = { [weak self] in
            guard let self else { return }
            self.contentVC.loadDirectory(self.currentDirectory)
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
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if addToHistory {
            backStack.append(currentDirectory)
            forwardStack.removeAll()
        }
        currentDirectory = url
        contentVC.currentDirectoryURL = url
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
        let folders = items.filter(\.isDirectory).count
        let files = items.count - folders
        let totalSize = items.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
        let sizeStr = ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)

        let selected = contentVC.selectedItems.count
        if selected > 0 {
            mainVC.statusLeft.stringValue = "\(selected) of \(items.count) selected"
        } else {
            mainVC.statusLeft.stringValue =
                "\(items.count) items (\(folders) folders, \(files) files)"
        }
        mainVC.statusRight.stringValue = sizeStr
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Don't let AppKit run window.close() — its internal
        // _NSWindowTransformAnimation crashes on freed layer objects.
        contentVC.prepareForClose()
        window.orderOut(nil)
        window.delegate = nil
        window.contentViewController = nil
        let appDelegate = NSApp.delegate as? AppDelegate
        appDelegate?.removeWindow(window)
        if appDelegate?.windows.isEmpty == true {
            exit(0)
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
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            let path = addressField.stringValue.trimmingCharacters(in: .whitespaces)
            let expanded = NSString(string: path).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            if FileManager.default.fileExists(atPath: url.path) {
                onNavigate?(url)
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
