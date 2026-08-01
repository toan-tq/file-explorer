# File Explorer

A native macOS file manager built with Swift and AppKit, inspired by Windows Explorer.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![AppKit](https://img.shields.io/badge/UI-AppKit-green)

## Features

- **Three view modes** — Details (table), Icons (grid with thumbnails), List (compact)
- **Breadcrumb address bar** — Click path components to navigate, click empty area to type a path
- **Sidebar** — Favorites (Home, Desktop, Documents, Downloads, etc.) and system volumes
- **Column sorting** — Click column headers in Details mode to sort by name, size, date, kind
- **Live search** — Filter files in the current directory
- **Drag & drop** — Drag files to other apps (upload, copy, move); drop files into current directory
- **Full context menu** — Open, Copy, Copy Path, Cut, Paste, Rename, Delete, New Folder
- **Keyboard shortcuts** — Enter (open), Backspace (go up), F2 (rename), F5 (refresh), Cmd+Backspace (delete)
- **Thumbnail previews** — QuickLook thumbnails for images and documents in Icons mode
- **Multi-window** — Cmd+N to open new windows
- **Hidden files** — Toggle with Cmd+Shift+.

## Build & Run

### Prerequisites

- macOS 13+
- Swift 5.9+ (included with Xcode 15+)

### Quick build

```bash
swift build -c release
.build/release/FileExplorer
```

### Build .app bundle

```bash
bash build-app.sh
```

This creates `dist/FileExplorer.app` with the app icon.

### Install

```bash
cp -R dist/FileExplorer.app /Applications/
```

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Enter | Open selected |
| Backspace | Go to parent folder |
| Cmd+Backspace | Delete (move to trash) |
| F2 | Rename |
| F5 | Refresh |
| Cmd+C | Copy |
| Cmd+X | Cut |
| Cmd+V | Paste |
| Cmd+A | Select all |
| Cmd+Opt+C | Copy path |
| Cmd+N | New window |
| Cmd+Shift+N | New folder |
| Cmd+L | Edit address bar |
| Cmd+R | Refresh |
| Cmd+[ | Back |
| Cmd+] | Forward |
| Cmd+Shift+. | Toggle hidden files |
| Cmd+W | Close window |
| Cmd+Q | Quit |

## Architecture

| File | Lines | Description |
|------|-------|-------------|
| `main.swift` | 6 | Entry point |
| `AppDelegate.swift` | 160 | Menu bar, multi-window management |
| `FileExplorerWindow.swift` | 476 | Window, toolbar, navigation, status bar |
| `FileTableViewController.swift` | 937 | All 3 view modes, drag & drop, context menu, search, sort |
| `SidebarViewController.swift` | 197 | Sidebar with favorites and system volumes |
| `FileItem.swift` | 44 | File data model |
