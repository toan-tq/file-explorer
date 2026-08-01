import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var windows: [FileExplorerWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        openNewWindow(at: FileManager.default.homeDirectoryForCurrentUser)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Clicking the Dock icon with no explorer window open did nothing at all. That state
    /// is reachable: closing the last window while a Properties panel is still floating
    /// deliberately skips the exit so the panel survives, and leaves the app with a Dock
    /// icon, a menu bar, and no way to get a window back.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if windows.isEmpty {
            openNewWindow(at: FileManager.default.homeDirectoryForCurrentUser)
        }
        return true
    }

    /// ⌘Q during a background copy would tear the process down mid-`copyItem` and leave
    /// a half-written file behind. Hold the quit until the batch is done — the same
    /// guarantee the old main-thread loop gave for free by blocking everything.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard FileOperation.isBusy else { return .terminateNow }
        FileOperation.onIdle = { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func openNewWindow(at url: URL) {
        let w = FileExplorerWindow(directory: url)
        windows.append(w)
        w.window.makeKeyAndOrderFront(nil)
    }

    func removeWindow(_ window: NSWindow) {
        windows.removeAll { $0.window === window }
    }

    // MARK: - Main Menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About File Explorer",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit File Explorer",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        // File menu
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "New Folder", action: #selector(newFolder(_:)), keyEquivalent: "n")
        fileMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Rename", action: #selector(renameFile(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: "Properties", action: #selector(showProperties(_:)), keyEquivalent: "i")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(closeWindow(_:)), keyEquivalent: "w")

        // Edit menu
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let copyPathItem = editMenu.addItem(withTitle: "Copy Path",
            action: #selector(copyPath(_:)), keyEquivalent: "c")
        copyPathItem.keyEquivalentModifierMask = [.command, .option]
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        let deleteItem = editMenu.addItem(withTitle: "Delete",
            action: #selector(deleteFile(_:)), keyEquivalent: "\u{08}")
        deleteItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // View menu
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "Show Hidden Files",
                         action: #selector(toggleHidden(_:)), keyEquivalent: ".")
        viewMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(withTitle: "Refresh", action: #selector(refresh(_:)), keyEquivalent: "r")

        // Go menu
        let goItem = NSMenuItem()
        mainMenu.addItem(goItem)
        let goMenu = NSMenu(title: "Go")
        goItem.submenu = goMenu
        goMenu.addItem(withTitle: "Back", action: #selector(goBack(_:)), keyEquivalent: "[")
        goMenu.addItem(withTitle: "Forward", action: #selector(goForward(_:)), keyEquivalent: "]")
        goMenu.addItem(withTitle: "Enclosing Folder", action: #selector(goUp(_:)), keyEquivalent: "\u{1b}")
        goMenu.items.last?.keyEquivalentModifierMask = [.command]
        goMenu.addItem(.separator())
        goMenu.addItem(withTitle: "Go to Path...", action: #selector(editAddress(_:)), keyEquivalent: "l")
        goMenu.addItem(withTitle: "Home", action: #selector(goHome(_:)), keyEquivalent: "h")
        goMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]

        // Window menu
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu Actions

    // The Properties panel is a floating NSPanel that is not in `windows`, so while it holds
    // key, resolving on keyWindow alone made every menu action a silent no-op.
    //
    // mainWindow is the right fallback rather than just a remembered window: a panel can't
    // become main (measured — NSPanel.canBecomeMain is false), so it stays pointed at the
    // explorer underneath, which is also the window AppKit routes ⌘C/⌘X/⌘V to through the
    // main-window responder chain. Resolving the same way keeps the menu bar and the
    // keyboard acting on one window instead of two.
    private weak var lastActiveExplorerWindow: NSWindow?

    func noteActiveExplorer(_ window: NSWindow) { lastActiveExplorerWindow = window }

    private var activeExplorer: FileExplorerWindow? {
        if let key = NSApp.keyWindow, let w = windows.first(where: { $0.window === key }) { return w }
        if let main = NSApp.mainWindow, let w = windows.first(where: { $0.window === main }) { return w }
        if let last = lastActiveExplorerWindow,
           let w = windows.first(where: { $0.window === last }) { return w }
        return windows.last
    }

    /// A window to hang a sheet on when the one that started an operation is already
    /// gone — see `FileTableViewController.presentAlert`.
    var sheetHostWindow: NSWindow? { activeExplorer?.window }

    @objc func newWindow(_ sender: Any?) {
        let dir = activeExplorer?.currentDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
        openNewWindow(at: dir)
    }

    // performClose, not close: only the former asks windowShouldClose(_:), which is where
    // the whole teardown path lives (FSEventStream, timer, window bookkeeping).
    @objc func closeWindow(_ sender: Any?) { NSApp.keyWindow?.performClose(nil) }

    @objc func goBack(_ sender: Any?) { activeExplorer?.goBack() }
    @objc func goForward(_ sender: Any?) { activeExplorer?.goForward() }
    @objc func goUp(_ sender: Any?) { activeExplorer?.goUp() }

    @objc func goHome(_ sender: Any?) {
        activeExplorer?.navigateTo(FileManager.default.homeDirectoryForCurrentUser)
    }

    @objc func editAddress(_ sender: Any?) {
        activeExplorer?.mainVC.startEditAddress()
    }

    @objc func toggleHidden(_ sender: Any?) {
        guard let explorer = activeExplorer else { return }
        explorer.toggleHiddenFiles()
    }

    // Routed through the same callback F5 uses, rather than calling loadDirectory
    // directly. Once loadDirectory started preserving folder sizes for an unchanged
    // directory, that callback grew a refreshFolderSizes() to keep "refresh" meaning
    // refresh — and this path, which doesn't go through it, quietly became a weaker
    // refresh than the key that is supposed to be its twin.
    @objc func refresh(_ sender: Any?) {
        activeExplorer?.contentVC.onRefresh?()
    }

    @objc func newFolder(_ sender: Any?) {
        activeExplorer?.contentVC.contextNewFolder(sender)
    }

    @objc func renameFile(_ sender: Any?) {
        activeExplorer?.contentVC.contextRename(sender)
    }

    @objc func deleteFile(_ sender: Any?) {
        activeExplorer?.contentVC.contextDelete(sender)
    }

    // The context menu carries its own ⌘I item, but a key equivalent on a menu that is
    // not in the menu bar never fires — the shortcut only works from here.
    @objc func showProperties(_ sender: Any?) {
        activeExplorer?.contentVC.contextProperties(sender)
    }

    @objc func copyPath(_ sender: Any?) {
        activeExplorer?.contentVC.contextCopyPath(sender)
    }
}

// MARK: - Menu validation

/// Without this, every menu-bar item AppKit routes here stayed enabled whenever any
/// responder implemented the selector — which is always. Delete, Rename, Properties and
/// Copy Path were live with nothing selected and did nothing when picked, while the
/// context menu greyed the very same commands out. Same commands, same state, two
/// different answers.
extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(deleteFile(_:)), #selector(copyPath(_:)):
            return (activeExplorer?.contentVC.selectedCount ?? 0) > 0
        // Both act on one item, and the context menu offers them only for one.
        case #selector(renameFile(_:)), #selector(showProperties(_:)):
            return (activeExplorer?.contentVC.selectedCount ?? 0) == 1
        // The toolbar buttons already disable correctly off backStack/forwardStack —
        // the Go menu items reaching the same commands stayed enabled regardless,
        // so Back/Forward/Enclosing Folder could be picked with nothing to do.
        case #selector(goBack(_:)):
            return !(activeExplorer?.backStack.isEmpty ?? true)
        case #selector(goForward(_:)):
            return !(activeExplorer?.forwardStack.isEmpty ?? true)
        case #selector(goUp(_:)):
            guard let explorer = activeExplorer else { return false }
            return explorer.currentDirectory.path != "/"
        case #selector(toggleHidden(_:)):
            item.state = (activeExplorer?.contentVC.showHidden ?? false) ? .on : .off
            return true
        default:
            return true
        }
    }
}
