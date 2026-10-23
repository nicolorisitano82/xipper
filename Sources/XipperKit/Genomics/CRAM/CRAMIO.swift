import CDeflate
import CHtsCodecs
import CXipShims
import Foundation

/// CRAM 3.x building blocks (CRAMv3 §2–§8): ITF8/LTF8 integers, bit streams for the core
/// block, and blocks with the nine compression methods.
enum CRAMIO {
    // MARK: integers

    static func itf8(_ value: Int32, into w: inout [UInt8]) {
        let v = UInt32(bitPattern: value)
        switch v {
        case ..<0x80: w.append(UInt8(v))
        case ..<0x4000: w += [UInt8(0x80 | v >> 8), UInt8(v & 0xFF)]
        case ..<0x20_0000: w += [UInt8(0xC0 | v >> 16), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        case ..<0x1000_0000: w += [UInt8(0xE0 | v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        default: w += [UInt8(0xF0 | v >> 28), UInt8(v >> 20 & 0xFF), UInt8(v >> 12 & 0xFF), UInt8(v >> 4 & 0xFF), UInt8(v & 0x0F)]
        }
    }

    static func ltf8(_ value: Int64, into w: inout [UInt8]) {
        let v = UInt64(bitPattern: value)
        // Number of extra bytes: the smallest that holds the value with 7 - extra free bits in the first byte.
        var extra = 0
        while extra < 8 {
            let bits = (extra < 8 ? 7 - extra : 0) + 8 * extra
            if extra == 7 { if v >> 56 == 0 { break } } else if bits < 64 && v >> UInt64(bits) == 0 { break }
            extra += 1
        }
        if extra == 8 {
            w.append(0xFF)
            for s in stride(from: 56, through: 0, by: -8) { w.append(UInt8(v >> UInt64(s) & 0xFF)) }
            return
        }
        let prefix: UInt8 = extra == 0 ? 0 : UInt8(0xFF << (8 - extra) & 0xFF)
        let top = extra == 7 ? 0 : UInt8(v >> UInt64(8 * extra) & 0xFF)
        w.append(prefix | top)
        for s in stride(from: 8 * (extra - 1), through: 0, by: -8) where extra > 0 { w.append(UInt8(v >> UInt64(s) & 0xFF)) }
    }

    static func int32(_ v: Int32, into w: inout [UInt8]) {
        let u = UInt32(bitPattern: v)
        w += [UInt8(u & 0xFF), UInt8(u >> 8 & 0xFF), UInt8(u >> 16 & 0xFF), UInt8(u >> 24)]
    }

    /// Byte stream reader (external blocks, headers).
    struct Reader {
        let b: [UInt8]
        var pos = 0
        init(_ b: [UInt8], at pos: Int = 0) { self.b = b; self.pos = pos }
        var remaining: Int { b.count - pos }

        mutating func u8() throws -> UInt8 {
            guard pos < b.count else { throw XipperError.corrupt("CRAM: data ends early") }
            defer { pos += 1 }
            return b[pos]
        }
        mutating func bytes(_ n: Int) throws -> [UInt8] {
            guard n >= 0, pos + n <= b.count else { throw XipperError.corrupt("CRAM: data ends early") }
            defer { pos += n }
            return Array(b[pos..<(pos + n)])
        }
        mutating func int32() throws -> Int32 {
            let x = try bytes(4)
            return Int32(bitPattern: UInt32(x[0]) | UInt32(x[1]) << 8 | UInt32(x[2]) << 16 | UInt32(x[3]) << 24)
        }
        mutating func itf8() throws -> Int32 {
            let b0 = UInt32(try u8())
            if b0 < 0x80 { return Int32(b0) }
            if b0 < 0xC0 { return Int32((b0 & 0x3F) << 8 | UInt32(try u8())) }
            if b0 < 0xE0 { let x = UInt32(try u8()) << 8 | UInt32(try u8()); return Int32((b0 & 0x1F) << 16 | x) }
            if b0 < 0xF0 {
                let x = UInt32(try u8()) << 16 | UInt32(try u8()) << 8 | UInt32(try u8())
                return Int32(bitPattern: (b0 & 0x0F) << 24 | x)
            }
            let x = UInt32(try u8()) << 20 | UInt32(try u8()) << 12 | UInt32(try u8()) << 4 | UInt32(try u8() & 0x0F)
            return Int32(bitPattern: (b0 & 0x0F) << 28 | x)
        }
        mutating func ltf8() throws -> Int64 {
            let b0 = try u8()
            var extra = 0
            while extra < 8 && b0 & (0x80 >> extra) != 0 { extra += 1 }
            var v: UInt64 = extra < 8 ? UInt64(b0 & (0xFF >> (extra + 1))) : 0
            for _ in 0..<extra { v = v << 8 | UInt64(try u8()) }
            return Int64(bitPattern: v)
        }
    }

    // MARK: bit streams (core data block, most significant bit first)

    struct BitReader {
        let b: [UInt8]
        var bit = 0
        init(_ b: [UInt8]) { self.b = b }

        mutating func read(_ n: Int) throws -> Int32 {
            guard n > 0 else { return 0 }
            guard bit + n <= b.count * 8 else { throw XipperError.corrupt("CRAM: core block ends early") }
            var v: UInt32 = 0
            for _ in 0..<n {
                v = v << 1 | UInt32(b[bit >> 3] >> (7 - UInt8(bit & 7)) & 1)
                bit += 1
            }
            return Int32(bitPattern: v)
        }
        mutating func one() throws -> Bool { try read(1) == 1 }
    }

    struct BitWriter {
        var bytes: [UInt8] = []
        private var acc: UInt64 = 0
        private var n = 0
        mutating func write(_ value: UInt32, _ bits: Int) {
            guard bits > 0 else { return }
            for k in stride(from: bits - 1, through: 0, by: -1) {
                acc = acc << 1 | UInt64(value >> UInt32(k) & 1)
                n += 1
                if n == 8 { bytes.append(UInt8(acc)); acc = 0; n = 0 }
            }
        }
        mutating func finish() -> [UInt8] {
            if n > 0 { bytes.append(UInt8(acc << UInt64(8 - n))); acc = 0; n = 0 }
            return bytes
        }
    }

    // MARK: blocks

    enum Method: UInt8 { case raw = 0, gzip, bzip2, lzma, rans4x8, ransNx16, arith, fqzcomp, tok3 }
    enum ContentType: UInt8 { case fileHeader = 0, compressionHeader = 1, sliceHeader = 2, external = 4, core = 5 }

    struct Block {
        var method: Method = .raw
        var contentType: ContentType
        var contentID: Int32 = 0
        /// Uncompressed data.
        var data: [UInt8]
    }

    /// Reads one block at `r.pos`, checks its CRC32 (3.0+) and decompresses it.
    static func readBlock(_ r: inout Reader, crc: Bool = true) throws -> Block {
        let start = r.pos
        let m = try r.u8(), t = try r.u8()
        guard let method = Method(rawValue: m) else { throw XipperError.unsupported("CRAM block compression method \(m)") }
        guard let type = ContentType(rawValue: t) else { throw XipperError.corrupt("CRAM block content type \(t)") }
        let id = try r.itf8(), size = Int(try r.itf8()), rawSize = Int(try r.itf8())
        guard size >= 0, rawSize >= 0, rawSize < 1 << 30 else { throw XipperError.corrupt("CRAM block size") }
        let payload = try r.bytes(size)
        if crc {
            let expected = UInt32(bitPattern: try r.int32())
            let actual = r.b.withUnsafeBytes { CRC32.checksum(UnsafeRawBufferPointer(rebasing: $0[start..<(r.pos - 4)])) }
            guard expected == actual else { throw XipperError.checksumMismatch(entry: "CRAM block", expected: expected, actual: actual) }
        }
        let data = rawSize == 0 ? [] : try decompress(method, payload, rawSize: rawSize)
        guard data.count == rawSize else { throw XipperError.corrupt("CRAM block: \(data.count) bytes, \(rawSize) declared") }
        return Block(method: rawSize == 0 ? .raw : method, contentType: type, contentID: id, data: data)
    }

    /// A block as written: header, payload and CRC32.
    static func blockBytes(_ b: Block, compressed: [UInt8]? = nil) -> [UInt8] {
        let payload = compressed ?? b.data
        var w: [UInt8] = [compressed == nil ? Method.raw.rawValue : b.method.rawValue, b.contentType.rawValue]
        itf8(b.contentID, into: &w)
        itf8(Int32(payload.count), into: &w)
        itf8(Int32(b.data.count), into: &w)
        w += payload
        int32(Int32(bitPattern: CRC32.checksum(w)), into: &w)
        return w
    }

    // MARK: methods

    private static func takeMalloced(_ p: UnsafeMutablePointer<UInt8>?, _ n: Int) -> [UInt8]? {
        guard let p else { return nil }
        defer { free(p) }
        return Array(UnsafeBufferPointer(start: p, count: n))
    }

    static func decompress(_ method: Method, _ data: [UInt8], rawSize: Int) throws -> [UInt8] {
        var input = data
        let n = UInt32(input.count)
        var out: [UInt8]?
        switch method {
        case .raw: out = data
        case .gzip:
            var result: [UInt8] = []
            let d = try InflateDecoder(gzip: true)
            try input.withUnsafeBytes { try d.process($0) { result += $0 } }
            try d.finish { result += $0 }
            out = result
        case .bzip2:
            var cap = UInt32(rawSize)
            var o = [UInt8](repeating: 0, count: max(rawSize, 1))
            let r = o.withUnsafeMutableBufferPointer { ob in
                input.withUnsafeMutableBufferPointer { ib in
                    ib.baseAddress!.withMemoryRebound(to: CChar.self, capacity: ib.count) { i in
                        ob.baseAddress!.withMemoryRebound(to: CChar.self, capacity: ob.count) { BZ2_bzBuffToBuffDecompress($0, &cap, i, n, 0, 0) }
                    }
                }
            }
            guard r == BZ_OK else { throw XipperError.corrupt("CRAM: invalid bzip2 block") }
            out = Array(o.prefix(Int(cap)))
        case .lzma:
            var result: [UInt8] = []
            let d = try LZMACoder.xzDecoder(threads: 1)
            try input.withUnsafeBytes { try d.process($0) { result += $0 } }
            try d.finish { result += $0 }
            out = result
        case .rans4x8:
            var size: UInt32 = 0
            out = takeMalloced(input.withUnsafeMutableBufferPointer { rans_uncompress($0.baseAddress, n, &size) }, Int(size))
            if out != nil { out = Array(out!.prefix(Int(size))) }
        case .ransNx16:
            var size: UInt32 = 0
            let p = input.withUnsafeMutableBufferPointer { rans_uncompress_4x16($0.baseAddress, n, &size) }
            out = takeMalloced(p, Int(size))
        case .arith:
            var size: UInt32 = 0
            let p = input.withUnsafeMutableBufferPointer { arith_uncompress($0.baseAddress, n, &size) }
            out = takeMalloced(p, Int(size))
        case .fqzcomp:
            var size = 0
            let p = input.withUnsafeMutableBufferPointer { b in
                b.baseAddress!.withMemoryRebound(to: CChar.self, capacity: b.count) { fqz_decompress($0, Int(n), &size, nil, 0) }
            }
            out = p.map { c in defer { free(c) }; return Array(UnsafeRawBufferPointer(start: c, count: size).bindMemory(to: UInt8.self)) }
        case .tok3:
            var size: UInt32 = 0
            let p = input.withUnsafeMutableBufferPointer { tok3_decode_names($0.baseAddress, n, &size) }
            out = takeMalloced(p, Int(size))
        }
        guard let out else { throw XipperError.corrupt("CRAM: invalid \(method) block") }
        return out
    }

    /// Compressed with `method` (`order`: rANS/arith order and flags; nil when it fails).
    static func compress(_ method: Method, _ data: [UInt8], order: Int32 = 0, fqz: (lengths: [UInt32], flags: [UInt32])? = nil) -> [UInt8]? {
        var input = data
        let n = UInt32(input.count)
        switch method {
        case .raw: return data
        case .gzip:
            let c = libdeflate_alloc_compressor(order > 0 ? order : 6)!
            defer { libdeflate_free_compressor(c) }
            let bound = libdeflate_gzip_compress_bound(c, input.count)
            var o = [UInt8](repeating: 0, count: bound)
            let size = o.withUnsafeMutableBytes { ob in input.withUnsafeBytes { libdeflate_gzip_compress(c, $0.baseAddress, $0.count, ob.baseAddress, bound) } }
            return size == 0 ? nil : Array(o.prefix(size))
        case .bzip2: return input.withUnsafeBytes { ZipBzip2.compress($0, level: 9, allowExpansion: true) }
        case .lzma: return input.withUnsafeBytes { ZipLZMA.xz($0, preset: 6, allowExpansion: true) }
        case .rans4x8:
            var size: UInt32 = 0
            return takeMalloced(input.withUnsafeMutableBufferPointer { rans_compress($0.baseAddress, n, &size, order) }, Int(size))
        case .ransNx16:
            var size: UInt32 = 0
            return takeMalloced(input.withUnsafeMutableBufferPointer { rans_compress_4x16($0.baseAddress, n, &size, order) }, Int(size))
        case .arith:
            var size: UInt32 = 0
            return takeMalloced(input.withUnsafeMutableBufferPointer { arith_compress($0.baseAddress, n, &size, order) }, Int(size))
        case .fqzcomp:
            guard var (lengths, flags) = fqz else { return nil }
            var size = 0
            let p: UnsafeMutablePointer<CChar>? = lengths.withUnsafeMutableBufferPointer { l in
                flags.withUnsafeMutableBufferPointer { f in
                    var s = fqz_slice(num_records: Int32(l.count), len: l.baseAddress, flags: f.baseAddress)
                    return input.withUnsafeMutableBufferPointer { b in
                        b.baseAddress!.withMemoryRebound(to: CChar.self, capacity: b.count) { fqz_compress(3, &s, $0, Int(n), &size, 0, nil) }
                    }
                }
            }
            return p.map { c in defer { free(c) }; return Array(UnsafeRawBufferPointer(start: c, count: size).bindMemory(to: UInt8.self)) }
        case .tok3:
            var size: Int32 = 0, last: Int32 = 0
            let p = input.withUnsafeMutableBufferPointer { b in
                b.baseAddress!.withMemoryRebound(to: CChar.self, capacity: b.count) { tok3_encode_names($0, Int32(n), 9, 0, &size, &last) }
            }
            return takeMalloced(p, Int(size))
        }
    }
}
