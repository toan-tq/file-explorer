import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var windows: [FileExplorerWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        openNewWindow(at: FileManager.default.homeDirectoryForCurrentUser)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed() -> Bool { true }

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

    private var activeExplorer: FileExplorerWindow? {
        guard let key = NSApp.keyWindow else { return nil }
        return windows.first { $0.window === key }
    }

    @objc func newWindow(_ sender: Any?) {
        let dir = activeExplorer?.currentDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
        openNewWindow(at: dir)
    }

    @objc func closeWindow(_ sender: Any?) { NSApp.keyWindow?.close() }

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

    @objc func refresh(_ sender: Any?) {
        guard let explorer = activeExplorer else { return }
        explorer.contentVC.loadDirectory(explorer.currentDirectory)
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

    @objc func copyPath(_ sender: Any?) {
        activeExplorer?.contentVC.contextCopyPath(sender)
    }
}
