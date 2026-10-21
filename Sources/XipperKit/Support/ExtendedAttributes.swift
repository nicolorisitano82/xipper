import Darwin
import Foundation

/// macOS extended attributes kept in archives: Finder tags and info, resource forks,
/// Spotlight comments, text encodings… (STUDIO.md §4.3).
enum ExtendedAttributes {
    /// Never stored or restored: quarantine is propagated from the archive instead, the others
    /// are per-machine security state that must not travel.
    static let excluded: Set<String> = [
        "com.apple.quarantine", "com.apple.provenance", "com.apple.macl", "com.apple.rootless",
        "com.apple.system.Security", "com.apple.cs.CodeDirectory", "com.apple.lastuseddate#PS",
    ]

    /// Largest single attribute stored (resource forks can be big; the pax reader caps records at 16 MiB).
    static let maxValue = 8 << 20

    /// The attributes of `path` (not following a final symlink), in name order.
    static func read(_ path: String) -> [(name: String, value: [UInt8])] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var names = [CChar](repeating: 0, count: size)
        let got = listxattr(path, &names, size, XATTR_NOFOLLOW)
        guard got > 0 else { return [] }
        var out: [(String, [UInt8])] = []
        for raw in names[0..<got].split(separator: 0) {
            let name = String(decoding: raw.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !excluded.contains(name) else { continue }
            let len = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard len >= 0, len <= maxValue else { continue }
            var value = [UInt8](repeating: 0, count: len)
            if len > 0 { guard getxattr(path, name, &value, len, 0, XATTR_NOFOLLOW) == len else { continue } }
            out.append((name, value))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// Applies attributes to an open file; failures are ignored (a filesystem may not support them).
    static func apply(_ attrs: [(name: String, value: [UInt8])], fd: Int32) {
        for (name, value) in attrs where !excluded.contains(name) {
            _ = value.withUnsafeBytes { fsetxattr(fd, name, $0.baseAddress, value.count, 0, 0) }
        }
    }

    static func apply(_ attrs: [(name: String, value: [UInt8])], path: String) {
        for (name, value) in attrs where !excluded.contains(name) {
            _ = value.withUnsafeBytes { setxattr(path, name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) }
        }
    }
}
