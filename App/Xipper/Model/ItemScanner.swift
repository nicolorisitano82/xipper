import Foundation
import UniformTypeIdentifiers

/// Size and content of a dropped item, computed off the main thread (2.2).
struct ItemInfo: Sendable, Equatable {
    var isFolder: Bool
    var kind: String
    var size: Int64
    /// Files inside a folder (1 for a file).
    var files: Int
    /// .DS_Store, ._*, __MACOSX… that the archive will leave out.
    var excludedMacFiles: Int
}

enum ItemScanner {
    private static let macNames: Set<String> = [".DS_Store", "__MACOSX", ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems"]

    static func scan(_ url: URL) -> ItemInfo {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .localizedTypeDescriptionKey])
        let kind = values?.localizedTypeDescription ?? "Documento"
        guard values?.isDirectory == true else {
            return ItemInfo(isFolder: false, kind: kind, size: Int64(values?.fileSize ?? 0), files: 1, excludedMacFiles: 0)
        }
        var size: Int64 = 0, files = 0, excluded = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: []) {
            for case let child as URL in e {
                let name = child.lastPathComponent
                if macNames.contains(name) || name.hasPrefix("._") {
                    excluded += 1
                    if name == "__MACOSX" { e.skipDescendants() }
                    continue
                }
                guard let v = try? child.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                files += 1
                size += Int64(v.fileSize ?? 0)
            }
        }
        return ItemInfo(isFolder: true, kind: "Cartella", size: size, files: files, excludedMacFiles: excluded)
    }
}
