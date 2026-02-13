import Foundation
import UniformTypeIdentifiers

struct FileItem: Comparable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modifiedDate: Date
    let kind: String
    let isHidden: Bool

    static func < (lhs: FileItem, rhs: FileItem) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    static func loadDirectory(_ url: URL) -> [FileItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            .localizedTypeDescriptionKey, .isHiddenKey, .isSymbolicLinkKey
        ]
        guard let urls = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: []
        ) else { return [] }

        return urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
            var isDir = v.isDirectory ?? false
            if v.isSymbolicLink ?? false {
                isDir = (try? u.resolvingSymlinksInPath().resourceValues(
                    forKeys: [.isDirectoryKey]).isDirectory) ?? isDir
            }
            return FileItem(
                url: u, name: u.lastPathComponent, isDirectory: isDir,
                size: Int64(v.fileSize ?? 0),
                modifiedDate: v.contentModificationDate ?? .distantPast,
                kind: v.localizedTypeDescription ?? "Unknown",
                isHidden: v.isHidden ?? false
            )
        }.sorted()
    }
}
