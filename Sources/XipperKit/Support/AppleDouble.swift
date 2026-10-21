import Foundation

/// AppleDouble files (`._name`, and `__MACOSX/…/._name` in ZIPs made by the Finder) carry the
/// Finder info, resource fork and extended attributes of `name`. Extraction merges them back
/// into the real file, as Archive Utility does, instead of leaving `._` clutter behind.
enum AppleDouble {
    static let magic: UInt32 = 0x0005_1607
    /// Larger "._" files are extracted as ordinary files.
    static let maxSize: Int64 = 16 << 20

    /// The attributes described by an AppleDouble file; empty if it is not one.
    static func attributes(_ data: [UInt8]) -> [(name: String, value: [UInt8])] {
        func u32(_ at: Int) -> UInt32? {
            guard at >= 0, at + 4 <= data.count else { return nil }
            return UInt32(data[at]) << 24 | UInt32(data[at + 1]) << 16 | UInt32(data[at + 2]) << 8 | UInt32(data[at + 3])
        }
        func u16(_ at: Int) -> Int? {
            guard at >= 0, at + 2 <= data.count else { return nil }
            return Int(data[at]) << 8 | Int(data[at + 1])
        }
        guard u32(0) == magic, let count = u16(24), count <= 64 else { return [] }
        var out: [(String, [UInt8])] = []
        for i in 0..<count {
            let at = 26 + i * 12
            guard let id = u32(at), let off32 = u32(at + 4), let len32 = u32(at + 8) else { break }
            let off = Int(off32), len = Int(len32)
            guard off >= 0, len >= 0, off <= data.count, len <= data.count - off else { continue }
            switch id {
            case 2 where len > 0:  // resource fork
                out.append(("com.apple.ResourceFork", Array(data[off..<(off + len)])))
            case 9:  // Finder info, optionally followed by Apple's extended-attribute block
                let info = Array(data[off..<(off + min(32, len))])
                if info.count == 32 && info.contains(where: { $0 != 0 }) { out.append(("com.apple.FinderInfo", info)) }
                out += extendedAttributes(data, start: off + 34)
            default:
                break
            }
        }
        return out
    }

    /// The "ATTR" block Apple appends to the Finder info entry (offsets are from the file start).
    private static func extendedAttributes(_ data: [UInt8], start: Int) -> [(name: String, value: [UInt8])] {
        func u32(_ at: Int) -> Int? {
            guard at >= 0, at + 4 <= data.count else { return nil }
            return Int(data[at]) << 24 | Int(data[at + 1]) << 16 | Int(data[at + 2]) << 8 | Int(data[at + 3])
        }
        guard u32(start) == 0x4154_5452,  // "ATTR"
              start + 36 <= data.count else { return [] }
        let count = Int(data[start + 34]) << 8 | Int(data[start + 35])
        var at = start + 36
        var out: [(String, [UInt8])] = []
        for _ in 0..<min(count, 4096) {
            guard let off = u32(at), let len = u32(at + 4), at + 11 <= data.count else { break }
            let nameLen = Int(data[at + 10])
            guard nameLen > 0, at + 11 + nameLen <= data.count, off <= data.count, len <= data.count - off else { break }
            let name = String(decoding: data[(at + 11)..<(at + 11 + nameLen)].prefix { $0 != 0 }, as: UTF8.self)
            if !name.isEmpty { out.append((name, Array(data[off..<(off + len)]))) }
            at = (at + 11 + nameLen + 3) & ~3
        }
        return out
    }
}

extension ArchiveEntry {
    /// Finder/macOS-tar metadata ("__MACOSX/…", "._name") that extraction merges into the real files.
    public var isAppleDoubleMetadata: Bool {
        path == "__MACOSX" || path.hasPrefix("__MACOSX/")
            || (kind == .file && (path as NSString).lastPathComponent.hasPrefix("._"))
    }
}
