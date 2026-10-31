import Foundation

/// Renames entries so Windows can extract them. A Mac allows names that Explorer and 7-Zip on
/// Windows refuse or silently alter: `a:b`, `why?`, `CON.txt`, `notes.` (trailing dots and
/// spaces), and two names that differ only in case, which overwrite each other there.
enum WindowsNames {
    static let forbidden: Set<Unicode.Scalar> = ["<", ">", ":", "\"", "\\", "|", "?", "*"]
    static let reserved: Set<String> = {
        var s: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        for d in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "¹", "²", "³"] {
            s.insert("COM" + d)
            s.insert("LPT" + d)
        }
        return s
    }()

    /// One path component, made valid on Windows (never empty).
    static func component(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in name.unicodeScalars {
            scalars.append(u.value < 0x20 || forbidden.contains(u) ? "_" : u)
        }
        var s = String(scalars)
        while let last = s.last, last == "." || last == " " { s.removeLast() }
        if s.isEmpty { return "_" }
        // `CON`, `con.txt`, `Nul .tar.gz`: the part before the first dot, trailing spaces ignored.
        let stem = s.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)[0]
        if reserved.contains(stem.uppercased().trimmingCharacters(in: .whitespaces)) { s = "_" + s }
        return s
    }

    /// Returns the items with Windows-safe names, parents renamed along with their children,
    /// and how many entries changed name. Clashes (also case-only ones) get " 2", " 3"…; names
    /// already valid are claimed first, so `a_b` keeps its name and `a:b` becomes `a_b 2`.
    static func apply(_ items: [ArchiveItem]) -> (items: [ArchiveItem], renamed: Int) {
        var taken = Set<String>()  // lowercased new paths
        var owners = Set<Int>()
        for (i, item) in items.enumerated() where item.name.split(separator: "/").allSatisfy({ component(String($0)) == $0 }) {
            if taken.insert(item.name.lowercased()).inserted { owners.insert(i) }
        }
        var folders: [String: String] = [:]  // original folder path → new one
        var renamed = 0
        let out = items.enumerated().map { i, item -> ArchiveItem in
            var parts = item.name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let last = parts.removeLast()
            let original = parts.joined(separator: "/")
            let parent = parts.isEmpty ? "" : folders[original] ?? parts.map(component).joined(separator: "/")
            let prefix = parent.isEmpty ? "" : parent + "/"
            var leaf = component(last)
            if owners.contains(i) && prefix + leaf == item.name {
                // Already valid and first of its kind: keeps its name.
            } else if taken.contains((prefix + leaf).lowercased()) {
                let ext = item.kind == .directory ? "" : (leaf as NSString).pathExtension
                let stem = ext.isEmpty ? leaf : String(leaf.dropLast(ext.count + 1))
                var n = 2
                repeat {
                    leaf = stem + " \(n)" + (ext.isEmpty ? "" : "." + ext)
                    n += 1
                } while taken.contains((prefix + leaf).lowercased())
            }
            var copy = item
            copy.name = prefix + leaf
            taken.insert(copy.name.lowercased())
            if item.kind == .directory { folders[item.name] = copy.name }
            if case let .symlink(target) = item.kind, !target.hasPrefix("/") {
                copy.kind = .symlink(target: target.split(separator: "/", omittingEmptySubsequences: false)
                    .map { $0 == "." || $0 == ".." || $0.isEmpty ? String($0) : component(String($0)) }
                    .joined(separator: "/"))
            }
            if copy.name != item.name { renamed += 1 }
            return copy
        }
        return (out, renamed)
    }
}
