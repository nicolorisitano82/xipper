import Foundation

/// A BER/DER reader over one buffer, without copying: nodes are ranges. BER matters here because
/// many `.p7m` files (and CMS in general) use indefinite lengths and constructed OCTET STRINGs.
/// Hostile input: lengths are bounded by the buffer, nesting by `maxDepth`.
struct ASN1 {
    struct Node: Equatable {
        var tag: UInt8
        /// Where the header starts.
        var header: Int
        /// The content.
        var start: Int, end: Int
        /// The end of the whole element (after the end-of-contents octets of an indefinite length).
        var next: Int
        var constructed: Bool { tag & 0x20 != 0 }
    }

    let bytes: [UInt8]
    static let maxDepth = 64

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    enum Failure: Error { case malformed(String) }

    func node(at p: Int, limit: Int? = nil, depth: Int = 0) throws -> Node {
        let lim = limit ?? bytes.count
        guard depth < Self.maxDepth else { throw Failure.malformed("nesting too deep") }
        guard p + 2 <= lim else { throw Failure.malformed("truncated header") }
        let tag = bytes[p]
        guard tag & 0x1F != 0x1F else { throw Failure.malformed("multi-byte tag") }
        var i = p + 1
        let first = Int(bytes[i]); i += 1
        if first == 0x80 {
            // Indefinite length (BER, constructed only): children up to the end-of-contents octets.
            guard tag & 0x20 != 0 else { throw Failure.malformed("indefinite primitive") }
            var q = i
            while true {
                guard q + 2 <= lim else { throw Failure.malformed("no end-of-contents") }
                if bytes[q] == 0, bytes[q + 1] == 0 { return Node(tag: tag, header: p, start: i, end: q, next: q + 2) }
                q = try node(at: q, limit: lim, depth: depth + 1).next
            }
        }
        var len = first
        if first & 0x80 != 0 {
            let n = first & 0x7F
            guard n >= 1, n <= 4, i + n <= lim else { throw Failure.malformed("length") }
            len = 0
            for _ in 0..<n { len = len << 8 | Int(bytes[i]); i += 1 }
        }
        guard len >= 0, i + len <= lim else { throw Failure.malformed("truncated content") }
        return Node(tag: tag, header: p, start: i, end: i + len, next: i + len)
    }

    func root() throws -> Node { try node(at: 0) }

    func children(_ n: Node) throws -> [Node] {
        guard n.constructed else { return [] }
        var out: [Node] = []
        var p = n.start
        while p < n.end {
            let c = try node(at: p, limit: n.end)
            out.append(c)
            p = c.next
        }
        return out
    }

    func content(_ n: Node) -> ArraySlice<UInt8> { bytes[n.start..<n.end] }
    func raw(_ n: Node) -> ArraySlice<UInt8> { bytes[n.header..<n.next] }

    /// An OCTET STRING's bytes, joined when it is constructed (BER).
    func octets(_ n: Node) throws -> [UInt8] {
        if !n.constructed { return Array(content(n)) }
        var out: [UInt8] = []
        for c in try children(n) { out += try octets(c) }
        return out
    }

    /// An OBJECT IDENTIFIER in dotted form.
    func oid(_ n: Node) -> String { Self.oidString(content(n)) }

    static func oidString<C: Collection>(_ b: C) -> String where C.Element == UInt8 {
        guard let first = b.first else { return "" }
        var parts = [first < 80 ? Int(first) / 40 : 2, first < 80 ? Int(first) % 40 : Int(first) - 80]
        var v = 0
        for byte in b.dropFirst() {
            v = v << 7 | Int(byte & 0x7F)
            if byte & 0x80 == 0 { parts.append(v); v = 0 }
        }
        return parts.map(String.init).joined(separator: ".")
    }

    /// A string of any of the X.509 string types.
    func string(_ n: Node) -> String {
        let c = content(n)
        switch n.tag {
        case 0x1E:  // BMPString, UTF-16BE
            var units: [UInt16] = []
            var i = c.startIndex
            while i + 1 < c.endIndex { units.append(UInt16(c[i]) << 8 | UInt16(c[i + 1])); i += 2 }
            return String(decoding: units, as: UTF16.self)
        case 0x1C:  // UniversalString, UTF-32BE
            var s = ""
            var i = c.startIndex
            while i + 3 < c.endIndex {
                let v = UInt32(c[i]) << 24 | UInt32(c[i + 1]) << 16 | UInt32(c[i + 2]) << 8 | UInt32(c[i + 3])
                if let u = Unicode.Scalar(v) { s.unicodeScalars.append(u) }
                i += 4
            }
            return s
        case 0x14:  // T61String: Latin-1 in practice
            return String(decoding: c.map { UInt16($0) }, as: UTF16.self)
        default:
            return String(decoding: c, as: UTF8.self)
        }
    }

    /// UTCTime or GeneralizedTime.
    func time(_ n: Node) -> Date? {
        var s = String(decoding: content(n), as: UTF8.self)
        if n.tag == 0x17 {  // UTCTime: YY < 50 is 20YY
            guard let yy = Int(s.prefix(2)) else { return nil }
            s = (yy < 50 ? "20" : "19") + s
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyyMMddHHmmss'Z'", "yyyyMMddHHmm'Z'", "yyyyMMddHHmmss.SSS'Z'", "yyyyMMddHHmmss.SS'Z'", "yyyyMMddHHmmss.S'Z'",
                       "yyyyMMddHHmmssZ"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    /// An INTEGER's big-endian bytes, without leading zeros.
    func integer(_ n: Node) -> [UInt8] {
        let c = Array(content(n))
        let trimmed = c.drop { $0 == 0 }
        return trimmed.isEmpty ? [0] : Array(trimmed)
    }
}
