import Foundation

/// POSIX ustar/pax headers (plus GNU long-name records on read).
enum Tar {
    static let block = 512
    /// GNU tar and bsdtar pad archives to 20 blocks.
    static let record = 10240

    enum TypeFlag: UInt8 {
        case file = 0x30, hardlink = 0x31, symlink = 0x32, char = 0x33, block = 0x34, directory = 0x35, fifo = 0x36, contiguous = 0x37
        case paxLocal = 0x78, paxGlobal = 0x67  // 'x', 'g'
        case gnuLongName = 0x4C, gnuLongLink = 0x4B  // 'L', 'K'
    }

    struct Header {
        var path: String
        var type: UInt8
        var size: Int64
        var mode: UInt16
        var uid: UInt32
        var gid: UInt32
        var mtime: Date
        var linkTarget: String
        /// macOS extended attributes from pax `SCHILY.xattr.*` (GNU tar, bsdtar) or `LIBARCHIVE.xattr.*`.
        var xattrs: [(name: String, value: [UInt8])] = []
    }

    // MARK: writing

    /// Header blocks for one item: optional pax record + ustar header.
    static func headerBlocks(for item: ArchiveItem, xattrs: [(name: String, value: [UInt8])] = []) -> [UInt8] {
        let isDir = item.kind == .directory
        let name = isDir ? item.name + "/" : item.name
        let type: TypeFlag
        var link = ""
        switch item.kind {
        case .file: type = .file
        case .directory: type = .directory
        case let .symlink(t): type = .symlink; link = t
        }
        var pax: [(String, String)] = []
        let (ustarName, prefix) = splitUstar(name) ?? { pax.append(("path", name)); return (asciiTruncated(name, 100), "") }()
        if !link.isEmpty && (link.utf8.count > 100 || !isASCII(link)) { pax.append(("linkpath", link)) }
        if item.size > 0o77777777777 { pax.append(("size", String(item.size))) }
        if item.uid > 0o7777777 { pax.append(("uid", String(item.uid))) }
        if item.gid > 0o7777777 { pax.append(("gid", String(item.gid))) }
        let frac = item.modified.timeIntervalSince1970.truncatingRemainder(dividingBy: 1)
        if frac != 0 { pax.append(("mtime", String(format: "%.9f", item.modified.timeIntervalSince1970))) }

        var out: [UInt8] = []
        if !pax.isEmpty || !xattrs.isEmpty {
            var data: [UInt8] = []
            for (k, v) in pax { data += paxRecord(k, v) }
            // Both spellings, as bsdtar writes them: macOS tar restores LIBARCHIVE.* by default,
            // GNU tar reads SCHILY.*.
            for (k, v) in xattrs {
                let escaped = k.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-_:"))) ?? k
                let base64 = Data(v).base64EncodedString().replacingOccurrences(of: "=", with: "")
                data += paxRecord("LIBARCHIVE.xattr." + escaped, base64)
                data += paxRecord("SCHILY.xattr." + k, v)
            }
            out += ustar(name: asciiTruncated("PaxHeader/" + (name as NSString).lastPathComponent, 100), prefix: "",
                         mode: 0o644, uid: 0, gid: 0, size: Int64(data.count), mtime: item.modified,
                         type: TypeFlag.paxLocal.rawValue, link: "")
            out += data
            out += [UInt8](repeating: 0, count: padding(Int64(data.count)))
        }
        out += ustar(name: ustarName, prefix: prefix, mode: item.permissions, uid: min(item.uid, 0o7777777),
                     gid: min(item.gid, 0o7777777), size: isFileKind(item) ? min(item.size, 0o77777777777) : 0,
                     mtime: item.modified, type: type.rawValue, link: asciiTruncated(link, 100))
        return out
    }

    private static func isFileKind(_ item: ArchiveItem) -> Bool { if case .file = item.kind { return true } else { return false } }

    static func padding(_ size: Int64) -> Int { Int((Int64(block) - size % Int64(block)) % Int64(block)) }

    private static func isASCII(_ s: String) -> Bool { s.utf8.allSatisfy { $0 < 0x80 } }

    private static func asciiTruncated(_ s: String, _ n: Int) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { $0.isASCII ? $0 : "_" }).prefix(n))
    }

    /// ustar stores names up to 255 bytes as prefix (≤155) + "/" + name (≤100), ASCII only here.
    private static func splitUstar(_ name: String) -> (String, String)? {
        guard isASCII(name) else { return nil }
        let b = Array(name.utf8)
        if b.count <= 100 { return (name, "") }
        if b.count > 256 { return nil }
        // Split at a "/" so that both parts fit.
        for i in stride(from: min(155, b.count - 1), through: 1, by: -1) where b[i] == UInt8(ascii: "/") {
            if b.count - i - 1 <= 100 && b.count - i - 1 > 0 {
                return (String(decoding: b[(i + 1)...], as: UTF8.self), String(decoding: b[..<i], as: UTF8.self))
            }
        }
        return nil
    }

    /// "%d key=value\n" where %d counts the whole record including itself.
    private static func paxRecord(_ key: String, _ value: String) -> [UInt8] { paxRecord(key, Array(value.utf8)) }

    /// Values are length-delimited, so binary data (extended attributes) is stored as is.
    private static func paxRecord(_ key: String, _ value: [UInt8]) -> [UInt8] {
        let body = Array(" \(key)=".utf8) + value + [0x0A]
        var len = body.count + 1
        while String(len).count + body.count != len { len = String(len).count + body.count }
        return Array(String(len).utf8) + body
    }

    private static func ustar(name: String, prefix: String, mode: UInt16, uid: UInt32, gid: UInt32,
                              size: Int64, mtime: Date, type: UInt8, link: String) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: block)
        func put(_ s: String, _ off: Int, _ len: Int) {
            for (i, c) in s.utf8.prefix(len).enumerated() { h[off + i] = c }
        }
        func octal(_ v: Int64, _ off: Int, _ len: Int) {
            put(String(repeating: "0", count: max(0, len - 1 - String(v, radix: 8).count)) + String(v, radix: 8), off, len - 1)
        }
        put(name, 0, 100)
        octal(Int64(mode & 0o7777), 100, 8)
        octal(Int64(uid), 108, 8)
        octal(Int64(gid), 116, 8)
        octal(size, 124, 12)
        octal(Int64(max(0, mtime.timeIntervalSince1970.rounded(.down))), 136, 12)
        h[156] = type
        put(link, 157, 100)
        put("ustar", 257, 6)  // "ustar\0"
        put("00", 263, 2)
        put(prefix, 345, 155)
        for i in 148..<156 { h[i] = 0x20 }
        let sum = h.reduce(0) { $0 + Int($1) }
        octal(Int64(sum), 148, 7)
        h[155] = 0x20
        return h
    }

    // MARK: reading

    /// Parses a raw 512-byte header. Returns nil for an all-zero block (end of archive).
    static func parseHeader(_ b: UnsafeRawBufferPointer) throws -> Header? {
        if b.allSatisfy({ $0 == 0 }) { return nil }
        // Checksum: unsigned (POSIX) or signed (old tars) sum with the checksum field as spaces.
        let stored = try numeric(b, 148, 8)
        var unsignedSum = 0, signedSum = 0
        for i in 0..<block {
            let c = (148..<156).contains(i) ? 0x20 : b[i]
            unsignedSum += Int(c)
            signedSum += Int(Int8(bitPattern: c))
        }
        if stored != Int64(unsignedSum) && stored != Int64(signedSum) { throw XipperError.corrupt("tar header checksum mismatch") }
        let isUstar = b[257] == UInt8(ascii: "u") && b[258] == UInt8(ascii: "s") && b[259] == UInt8(ascii: "t")
        var path = string(b, 0, 100)
        if isUstar && b[263] == UInt8(ascii: "0") {  // POSIX ustar (GNU uses "ustar  \0" without prefix)
            let prefix = string(b, 345, 155)
            if !prefix.isEmpty { path = prefix + "/" + path }
        }
        return Header(path: path, type: b[156] == 0 ? TypeFlag.file.rawValue : b[156],
                      size: try numeric(b, 124, 12), mode: UInt16(truncatingIfNeeded: try numeric(b, 100, 8) & 0o7777),
                      uid: UInt32(truncatingIfNeeded: try numeric(b, 108, 8)), gid: UInt32(truncatingIfNeeded: try numeric(b, 116, 8)),
                      mtime: Date(timeIntervalSince1970: Double(try numeric(b, 136, 12))),
                      linkTarget: string(b, 157, 100))
    }

    static func looksLikeHeader(_ b: UnsafeRawBufferPointer) -> Bool {
        (try? parseHeader(b)) != nil
    }

    private static func string(_ b: UnsafeRawBufferPointer, _ off: Int, _ len: Int) -> String {
        var end = off
        while end < off + len && b[end] != 0 { end += 1 }
        let bytes = Array(b[off..<end])
        return String(bytes: bytes, encoding: .utf8) ?? ZipArchive.decodeName(bytes, utf8Flag: false)
    }

    /// Octal (space/NUL terminated) or GNU base-256 (high bit set) number.
    private static func numeric(_ b: UnsafeRawBufferPointer, _ off: Int, _ len: Int) throws -> Int64 {
        if b[off] & 0x80 != 0 {
            var v: Int64 = Int64(b[off] & 0x7F)
            for i in 1..<len {
                if v > Int64.max >> 8 { throw XipperError.corrupt("tar number overflow") }
                v = v << 8 | Int64(b[off + i])
            }
            return v
        }
        var v: Int64 = 0
        var i = off
        while i < off + len && (b[i] == 0x20 || b[i] == 0) { i += 1 }
        while i < off + len, b[i] >= 0x30, b[i] <= 0x37 {
            if v > Int64.max >> 3 { throw XipperError.corrupt("tar number overflow") }
            v = v * 8 + Int64(b[i] - 0x30)
            i += 1
        }
        return v
    }

    /// Parses pax "len key=value\n" records.
    static func parsePax(_ data: [UInt8]) -> [String: String] {
        parsePaxRaw(data).mapValues { String(decoding: $0, as: UTF8.self) }
    }

    /// The same records with raw values (extended attributes are binary).
    static func parsePaxRaw(_ data: [UInt8]) -> [String: [UInt8]] {
        var out: [String: [UInt8]] = [:]
        var i = 0
        while i < data.count {
            var j = i
            while j < data.count && data[j] != 0x20 { j += 1 }
            guard j < data.count, let len = Int(String(decoding: data[i..<j], as: UTF8.self)), len > 0, i + len <= data.count else { break }
            let rec = data[(j + 1)..<(i + len - 1)]  // drop trailing "\n"
            if let eq = rec.firstIndex(of: UInt8(ascii: "=")) {
                out[String(decoding: rec[rec.startIndex..<eq], as: UTF8.self)] = Array(rec[(eq + 1)...])
            }
            i += len
        }
        return out
    }
}
