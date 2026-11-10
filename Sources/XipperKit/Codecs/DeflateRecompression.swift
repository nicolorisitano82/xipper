import CPreflate
import Foundation

/// Lossless recompression of the Deflate streams inside PNG images, PDF files and ZIP-based
/// documents (DOCX, XLSX, PPTX, ODF, EPUB) for XIZ 1.9 (docs/XIZ_SPEC.md §19). A file becomes a
/// "split" form: its bytes outside the streams, each stream's uncompressed data and the preflate
/// reconstruction information that gives the stream back bit for bit. The split form is then
/// compressed with zstd or LZMA2, which do far better on the uncompressed data than on Deflate.
/// preflate runs in the `xipper-decoder` helper when there is one, like brunsli.
enum DeflateRecompression {
    static let minimumSize: Int64 = 4096
    /// Smaller than this fraction of the file compressed as usual, or stored the usual way.
    static let worthIt = 0.97
    /// The split form is at most this big (writers stop before, readers refuse more).
    static let maxSplit = 256 << 20
    /// Streams shorter than this are left as they are.
    static let minimumStream = 64
    static let magic: [UInt8] = Array("XPF1".utf8)

    enum Kind { case png, pdf, zip }

    static func kind(name: String) -> Kind? {
        switch (name as NSString).pathExtension.lowercased() {
        case "png": .png
        case "pdf": .pdf
        case "docx", "xlsx", "pptx", "docm", "xlsm", "pptm", "odt", "ods", "odp", "odg", "epub": .zip
        default: nil
        }
    }

    /// A file worth trying: a known extension, the right magic, from 4 KiB to a frame.
    static func isCandidate(name: String, path: String, size: Int64) -> Bool {
        guard size >= minimumSize, size <= Int64(Xiz.maxFrameData), let kind = kind(name: name),
              let r = try? FileReader(path: path), let head = try? r.read(at: 0, count: 8) else { return false }
        switch kind {
        case .png: return head == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        case .pdf: return head.starts(with: Array("%PDF".utf8))
        case .zip: return head.starts(with: [0x50, 0x4B, 0x03, 0x04])
        }
    }

    // MARK: split form

    /// One part of a file: bytes kept as they are, a raw Deflate stream, or the IDAT chunks of a PNG
    /// (a zlib stream cut into chunks).
    enum Segment {
        case literal(ArraySlice<UInt8>)
        case deflate(unpacked: [UInt8], diff: [UInt8])
        case pngIDAT(chunks: [UInt32], header: [UInt8], trailer: [UInt8], unpacked: [UInt8], diff: [UInt8])
    }

    private static func split(_ stream: ArraySlice<UInt8>, budget: Int) -> (unpacked: [UInt8], diff: [UInt8], consumed: Int)? {
        guard stream.count >= minimumStream, budget > 0 else { return nil }
        var u = xpf_buffer(), d = xpf_buffer()
        var consumed = 0
        let ok = stream.withUnsafeBufferPointer { xpf_decode($0.baseAddress, $0.count, budget, &u, &d, &consumed) }
        guard ok == 1 else { return nil }
        defer { xpf_free(&u); xpf_free(&d) }
        return (Array(UnsafeBufferPointer(start: u.data, count: u.size)), Array(UnsafeBufferPointer(start: d.data, count: d.size)), consumed)
    }

    /// zlib header: deflate, 32 KiB window or less, no preset dictionary, valid check bits.
    private static func isZlibHeader(_ a: UInt8, _ b: UInt8) -> Bool {
        a & 0x0F == 8 && a >> 4 <= 7 && b & 0x20 == 0 && (UInt16(a) << 8 | UInt16(b)) % 31 == 0
    }

    /// The segments of `file`, nil when no stream could be split (nothing to gain).
    static func segments(_ file: [UInt8], kind: Kind) -> [Segment]? {
        var out: [Segment] = []
        var budget = maxSplit - file.count
        var at = 0, literalStart = 0
        var found = false
        func flush(to end: Int) {
            if end > literalStart { out.append(.literal(file[literalStart..<end])) }
        }
        switch kind {
        case .png:
            // Chunks: length u32be, type, data, CRC. The IDAT chunks must follow one another.
            var p = 8
            var idat: [(start: Int, length: Int)] = []
            while p + 12 <= file.count {
                let len = Int(UInt32(file[p]) << 24 | UInt32(file[p + 1]) << 16 | UInt32(file[p + 2]) << 8 | UInt32(file[p + 3]))
                guard len <= file.count - p - 12 else { return nil }
                let type = Array(file[(p + 4)..<(p + 8)])
                if type == Array("IDAT".utf8) {
                    if let last = idat.last, last.start + last.length + 12 != p { return nil }
                    idat.append((p, len))
                }
                p += 12 + len
                if type == Array("IEND".utf8) { break }
            }
            guard let first = idat.first, let last = idat.last else { return nil }
            var z: [UInt8] = []
            for c in idat { z += file[(c.start + 8)..<(c.start + 8 + c.length)] }
            guard z.count > 6, isZlibHeader(z[0], z[1]), let s = split(z[2...], budget: budget) else { return nil }
            flush(to: first.start)
            out.append(.pngIDAT(chunks: idat.map { UInt32($0.length) }, header: Array(z[0..<2]), trailer: Array(z[(2 + s.consumed)...]),
                                unpacked: s.unpacked, diff: s.diff))
            literalStart = last.start + 12 + last.length
            found = true
        case .pdf:
            // "stream" + EOL, then a zlib stream (FlateDecode).
            let key = Array("stream".utf8)
            while let k = find(key, in: file, from: at) {
                var d = k + key.count
                if d < file.count, file[d] == 0x0D { d += 1 }
                guard d < file.count, file[d] == 0x0A else { at = k + 1; continue }
                d += 1
                guard d + 2 < file.count, isZlibHeader(file[d], file[d + 1]), let s = split(file[(d + 2)...], budget: budget) else {
                    at = d
                    continue
                }
                flush(to: d + 2)
                out.append(.deflate(unpacked: s.unpacked, diff: s.diff))
                budget -= s.unpacked.count + s.diff.count
                at = d + 2 + s.consumed
                literalStart = at
                found = true
            }
        case .zip:
            // Local headers in order: a deflated, unencrypted entry's data follows its header.
            while at + 30 <= file.count, file[at] == 0x50, file[at + 1] == 0x4B, file[at + 2] == 3, file[at + 3] == 4 {
                func u16(_ o: Int) -> Int { Int(file[at + o]) | Int(file[at + o + 1]) << 8 }
                func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
                let flags = u16(6), method = u16(8), csize = u32(18)
                let data = at + 30 + u16(26) + u16(28)
                guard data <= file.count else { break }
                if method == 8, flags & 1 == 0, let s = split(file[data...], budget: budget),
                   flags & 8 != 0 || s.consumed == csize {
                    flush(to: data)
                    out.append(.deflate(unpacked: s.unpacked, diff: s.diff))
                    budget -= s.unpacked.count + s.diff.count
                    literalStart = data + s.consumed
                    found = true
                    at = data + s.consumed
                } else if flags & 8 == 0 {
                    at = data + csize
                } else {
                    break  // a size we cannot know without decoding
                }
                // A data descriptor may follow; the next local header is found by its signature.
                guard let next = find([0x50, 0x4B, 3, 4], in: file, from: at, limit: 32) else { break }
                at = next
            }
        }
        guard found else { return nil }
        flush(to: file.count)
        return out
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8], from: Int, limit: Int = .max) -> Int? {
        guard from >= 0, needle.count <= hay.count else { return nil }
        let last = limit >= hay.count ? hay.count - needle.count : min(hay.count - needle.count, from + limit)
        var i = from
        while i <= last {
            if hay[i] == needle[0], hay[i..<(i + needle.count)].elementsEqual(needle) { return i }
            i += 1
        }
        return nil
    }

    /// The split form: "XPF1", the segment table, then every literal and uncompressed stream in
    /// file order, then every reconstruction record (§19).
    static func encodeSplit(_ segments: [Segment]) -> [UInt8] {
        var table = ByteWriter(capacity: 64), data: [UInt8] = [], diffs: [UInt8] = []
        table.append(magic)
        table.u32(UInt32(segments.count))
        for s in segments {
            switch s {
            case let .literal(b):
                table.u8(0); table.u32(UInt32(b.count))
                data += b
            case let .deflate(u, d):
                table.u8(1); table.u32(UInt32(u.count)); table.u32(UInt32(d.count))
                data += u
                diffs += d
            case let .pngIDAT(chunks, header, trailer, u, d):
                table.u8(2); table.u32(UInt32(chunks.count))
                for c in chunks { table.u32(c) }
                table.append(header); table.u32(UInt32(trailer.count)); table.u32(UInt32(u.count)); table.u32(UInt32(d.count))
                data += trailer + u
                diffs += d
            }
        }
        return table.bytes + data + diffs
    }

    /// The file back from its split form: exactly `size` bytes or an error.
    static func rebuild(_ split: [UInt8], size: Int) throws -> [UInt8] {
        func bad(_ m: String = "damaged Deflate recompression data") -> XipperError { .corrupt(m) }
        guard split.count <= maxSplit, split.starts(with: magic) else { throw bad() }
        return try split.withUnsafeBytes { raw in
            var r = ByteReader(raw, at: 4)
            let n = Int(try r.u32())
            guard n <= split.count / 5 else { throw bad() }
            enum Plan { case literal(Int), deflate(Int, Int), png([UInt32], [UInt8], Int, Int, Int) }
            var plans: [Plan] = []
            var dataSize = 0, diffSize = 0
            for _ in 0..<n {
                switch try r.u8() {
                case 0:
                    let l = Int(try r.u32()); dataSize += l
                    plans.append(.literal(l))
                case 1:
                    let u = Int(try r.u32()), d = Int(try r.u32()); dataSize += u; diffSize += d
                    plans.append(.deflate(u, d))
                case 2:
                    let c = Int(try r.u32())
                    guard c >= 1, c <= r.remaining / 4 else { throw bad() }
                    var chunks: [UInt32] = []
                    for _ in 0..<c { chunks.append(try r.u32()) }
                    let header = Array(try r.bytes(2))
                    let t = Int(try r.u32()), u = Int(try r.u32()), d = Int(try r.u32())
                    dataSize += t + u; diffSize += d
                    plans.append(.png(chunks, header, t, u, d))
                default: throw bad()
                }
            }
            guard dataSize + diffSize == r.remaining else { throw bad() }
            var data = r.pos, diff = r.pos + dataSize
            var out: [UInt8] = []
            out.reserveCapacity(size)
            func take(_ count: Int, from p: inout Int) -> ArraySlice<UInt8> {
                defer { p += count }
                return split[p..<(p + count)]
            }
            func reencode(_ u: ArraySlice<UInt8>, _ d: ArraySlice<UInt8>) throws -> [UInt8] {
                var o = xpf_buffer()
                let ok = d.withUnsafeBufferPointer { dp in u.withUnsafeBufferPointer { up in
                    xpf_reencode(dp.baseAddress, dp.count, up.baseAddress, up.count, &o)
                } }
                guard ok == 1 else { throw bad() }
                defer { xpf_free(&o) }
                return Array(UnsafeBufferPointer(start: o.data, count: o.size))
            }
            for p in plans {
                switch p {
                case let .literal(l):
                    out += take(l, from: &data)
                case let .deflate(u, d):
                    out += try reencode(take(u, from: &data), take(d, from: &diff))
                case let .png(chunks, header, t, u, d):
                    let trailer = take(t, from: &data)
                    let z = header + (try reencode(take(u, from: &data), take(d, from: &diff))) + trailer
                    guard chunks.reduce(0, { $0 + Int($1) }) == z.count else { throw bad() }
                    var at = 0
                    for c in chunks.map(Int.init) {
                        let body = Array("IDAT".utf8) + z[at..<(at + c)]
                        out += [UInt8(c >> 24 & 0xFF), UInt8(c >> 16 & 0xFF), UInt8(c >> 8 & 0xFF), UInt8(c & 0xFF)] + body
                        let crc = body.withUnsafeBytes { CRC32.checksum($0) }
                        out += [UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)]
                        at += c
                    }
                }
                guard out.count <= size else { throw bad() }
            }
            guard out.count == size else { throw bad() }
            return out
        }
    }

    /// The split form of `file`, nil when there is nothing to split. In process: the helper calls this.
    static func splitInProcess(_ file: [UInt8], name: String) -> [UInt8]? {
        guard let kind = kind(name: name) else { return nil }
        return splitInProcess(file, kind: kind)
    }

    static func splitInProcess(_ file: [UInt8], kind: Kind) -> [UInt8]? {
        segments(file, kind: kind).map(encodeSplit)
    }

    static func code(_ k: Kind) -> UInt8 { k == .png ? 1 : k == .pdf ? 2 : 3 }
    static func kind(code: UInt8) -> Kind? { code == 1 ? .png : code == 2 ? .pdf : code == 3 ? .zip : nil }

    // MARK: frames (through the helper)

    /// Inner codecs of a frame payload: `inner u8 ‖ split size u32 ‖ compressed split form` (§19).
    static let innerZstd: UInt8 = 1, innerLZMA2: UInt8 = 2

    /// The frame payload for `file`, or nil to store it the usual way: nothing to split, a split
    /// form that does not rebuild the file exactly (checked here, whatever the helper says), or a
    /// gain under 3% against the file compressed as usual.
    static func encode(_ file: [UInt8], name: String, level: Int, lzma2: Bool) -> [UInt8]? {
        guard let kind = kind(name: name) else { return nil }
        let split: [UInt8]?
        if let pool = JPEGCoderPool.shared {
            split = try? pool.run(.deflateSplit, [code(kind)] + file)
        } else {
            split = splitInProcess(file, kind: kind)
        }
        guard let split, split.count <= maxSplit, (try? rebuildChecked(split, size: file.count)) == file else { return nil }
        // LZMA2 for «Massimo» and above, zstd at the archive's level otherwise.
        let useLZMA2 = lzma2 || level >= 12
        func pack(_ b: [UInt8]) -> [UInt8]? {
            b.withUnsafeBytes { useLZMA2 ? (try? Xiz.lzma2Compress($0, arm64: false)) ?? nil : ZipWriter.zstdCompress($0, level: max(level, 3), pool: nil) }
        }
        guard let packed = pack(split) else { return nil }
        let usual = pack(file)?.count ?? file.count
        guard Double(packed.count + 5) < Double(usual) * worthIt else { return nil }
        var w = ByteWriter(capacity: packed.count + 5)
        w.u8(useLZMA2 ? innerLZMA2 : innerZstd)
        w.u32(UInt32(split.count))
        w.append(packed)
        return w.bytes
    }

    /// The file from a frame payload: exactly `size` bytes or an error.
    static func decode(_ payload: [UInt8], size: Int) throws -> [UInt8] {
        guard payload.count > 5 else { throw XipperError.corrupt("damaged Deflate recompression data") }
        let inner = payload[0]
        let splitSize = Int(UInt32(payload[1]) | UInt32(payload[2]) << 8 | UInt32(payload[3]) << 16 | UInt32(payload[4]) << 24)
        guard splitSize <= maxSplit else { throw XipperError.limitExceeded("Deflate recompression data of \(splitSize) bytes") }
        let split: [UInt8] = try payload.withUnsafeBytes { raw in
            let body = UnsafeRawBufferPointer(rebasing: raw[5...])
            switch inner {
            case innerZstd: return try Xiz.zstdDecompress(body, size: splitSize)
            case innerLZMA2: return try Xiz.lzma2Decompress(body, size: splitSize, arm64: false)
            default: throw XipperError.corrupt("Deflate recompression codec \(inner)")
            }
        }
        return try rebuildChecked(split, size: size)
    }

    /// Rebuilds through the helper when there is one.
    static func rebuildChecked(_ split: [UInt8], size: Int) throws -> [UInt8] {
        guard let pool = JPEGCoderPool.shared else { return try rebuild(split, size: size) }
        var w = ByteWriter(capacity: split.count + 4)
        w.u32(UInt32(size))
        w.append(split)
        guard let out = try pool.run(.deflateRebuild, w.bytes), out.count == size else {
            throw XipperError.corrupt("damaged Deflate recompression data")
        }
        return out
    }
}

/// For `xipper-bench --deflate`: split and rebuild one file in process, with the times.
public enum DeflateRecompressionProbe {
    public struct Result: Sendable {
        /// nil: nothing to split (or refused).
        public var split: [UInt8]?
        public var identical: Bool
        public var splitSeconds: Double
        public var rebuildSeconds: Double
    }

    public static func run(_ file: [UInt8], name: String) -> Result {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let split = DeflateRecompression.splitInProcess(file, name: name)
        let t1 = DispatchTime.now().uptimeNanoseconds
        let back = split.flatMap { try? DeflateRecompression.rebuild($0, size: file.count) }
        let t2 = DispatchTime.now().uptimeNanoseconds
        return Result(split: split, identical: back == file, splitSeconds: Double(t1 - t0) / 1e9, rebuildSeconds: Double(t2 - t1) / 1e9)
    }
}
