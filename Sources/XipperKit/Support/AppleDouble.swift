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

    /// An AppleDouble file for these attributes, laid out like the Finder's and `ditto`'s
    /// (Finder info entry followed by the "ATTR" block, then the resource fork).
    static func encode(_ attrs: [(name: String, value: [UInt8])]) -> [UInt8] {
        var finderInfo = [UInt8](repeating: 0, count: 32)
        var resourceFork: [UInt8] = []
        var others: [(name: [UInt8], value: [UInt8])] = []
        for (name, value) in attrs {
            switch name {
            case "com.apple.FinderInfo": finderInfo = Array(value.prefix(32)) + [UInt8](repeating: 0, count: max(0, 32 - value.count))
            case "com.apple.ResourceFork": resourceFork = value
            default: others.append((Array(name.utf8) + [0], value))
            }
        }
        func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        let headerSize = 26 + 2 * 12
        let attrStart = headerSize + 32 + 2  // "ATTR" header, 4-byte aligned (84)
        var entriesSize = 0
        for o in others { entriesSize = (entriesSize + 11 + o.name.count + 3) & ~3 }
        var dataStart = attrStart + 36 + entriesSize
        let firstData = dataStart
        var table: [UInt8] = []
        var blob: [UInt8] = []
        for o in others {
            var e = be32(dataStart) + be32(o.value.count) + be16(0) + [UInt8(o.name.count)] + o.name
            while e.count % 4 != 0 { e.append(0) }
            table += e
            blob += o.value
            dataStart += o.value.count
        }
        let attrEnd = firstData + blob.count
        var out = be32(Int(magic)) + be32(0x0002_0000) + Array("Mac OS X        ".utf8) + be16(2)
        out += be32(9) + be32(headerSize) + be32(attrEnd - headerSize)  // Finder info + attributes
        out += be32(2) + be32(attrEnd) + be32(resourceFork.count)  // resource fork
        out += finderInfo + [0, 0]
        out += Array("ATTR".utf8) + be32(0) + be32(attrEnd) + be32(firstData) + be32(blob.count)
        out += [UInt8](repeating: 0, count: 12) + be16(0) + be16(others.count)
        out += table + blob + resourceFork
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
