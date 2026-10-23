import Foundation

/// SAM header: the text and the reference sequences (SAM/BAM specification v1 §1.3, §4.2).
struct SAMHeader {
    var text: String
    var references: [(name: String, length: Int)]

    /// Read group IDs in header order (CRAM's RG data series is an index into this list).
    var readGroups: [String] {
        text.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("@RG\t") else { return nil }
            return line.split(separator: "\t").first { $0.hasPrefix("ID:") }.map { String($0.dropFirst(3)) }
        }
    }

    /// Value of field `key` (e.g. "M5") of the @SQ line for `name`.
    func sequenceField(_ name: String, _ key: String) -> String? {
        for line in text.split(separator: "\n") where line.hasPrefix("@SQ\t") {
            let fields = line.split(separator: "\t")
            guard fields.contains("SN:" + name) else { continue }
            return fields.first { $0.hasPrefix(key + ":") }.map { String($0.dropFirst(key.count + 1)) }
        }
        return nil
    }

    /// @SQ lines built from `references` when the text has none (BAM allows that).
    static func sqLines(_ refs: [(name: String, length: Int)]) -> String {
        refs.map { "@SQ\tSN:\($0.name)\tLN:\($0.length)\n" }.joined()
    }
}

/// One alignment, as in BAM (0-based positions, CIGAR packed as length << 4 | op).
struct AlignmentRecord: Equatable {
    struct Tag: Equatable {
        var key: [UInt8]  // 2 bytes
        var type: UInt8  // A c C s S i I f Z H B
        var value: [UInt8]  // BAM binary value (Z/H with their NUL)
    }

    var name: [UInt8] = []
    var flag: UInt16 = 0
    var refID: Int32 = -1
    var pos: Int32 = -1
    var mapq: UInt8 = 255
    var cigar: [UInt32] = []
    var nextRefID: Int32 = -1
    var nextPos: Int32 = -1
    var tlen: Int32 = 0
    /// Upper-case IUPAC letters (BAM's 4-bit alphabet), or empty for "*".
    var seq: [UInt8] = []
    /// Phred scores; 0xFF everywhere when absent ("*").
    var qual: [UInt8] = []
    var tags: [Tag] = []

    static let cigarOps: [UInt8] = Array("MIDNSHP=X".utf8)
    static func op(_ c: UInt32) -> UInt8 { cigarOps[Int(c & 0xF)] }

    var isUnmapped: Bool { flag & 4 != 0 }

    /// Reference bases covered (M, D, N, =, X).
    var referenceLength: Int {
        cigar.reduce(0) { n, c in "MDN=X".utf8.contains(Self.op(c)) ? n + Int(c >> 4) : n }
    }

    func tag(_ key: String) -> Tag? { tags.first { $0.key == Array(key.utf8) } }

    /// Size of a BAM aux value of `type` at the start of `b` (nil if malformed).
    static func valueSize(_ type: UInt8, _ b: UnsafeRawBufferPointer) -> Int? {
        switch type {
        case UInt8(ascii: "A"), UInt8(ascii: "c"), UInt8(ascii: "C"): return 1
        case UInt8(ascii: "s"), UInt8(ascii: "S"): return 2
        case UInt8(ascii: "i"), UInt8(ascii: "I"), UInt8(ascii: "f"): return 4
        case UInt8(ascii: "Z"), UInt8(ascii: "H"):
            guard let nul = b.firstIndex(of: 0) else { return nil }
            return nul + 1
        case UInt8(ascii: "B"):
            guard b.count >= 5 else { return nil }
            let n = Int(b.loadUnaligned(fromByteOffset: 1, as: UInt32.self).littleEndian)
            let size: Int
            switch b[0] {
            case UInt8(ascii: "c"), UInt8(ascii: "C"): size = 1
            case UInt8(ascii: "s"), UInt8(ascii: "S"): size = 2
            case UInt8(ascii: "i"), UInt8(ascii: "I"), UInt8(ascii: "f"): size = 4
            default: return nil
            }
            return 5 + n * size
        default: return nil
        }
    }

    static func parseTags(_ b: UnsafeRawBufferPointer) throws -> [Tag] {
        var tags: [Tag] = []
        var i = 0
        while i < b.count {
            guard i + 3 <= b.count, let n = valueSize(b[i + 2], UnsafeRawBufferPointer(rebasing: b[(i + 3)...])),
                  i + 3 + n <= b.count else { throw XipperError.corrupt("BAM: invalid auxiliary field") }
            tags.append(Tag(key: [b[i], b[i + 1]], type: b[i + 2], value: Array(b[(i + 3)..<(i + 3 + n)])))
            i += 3 + n
        }
        return tags
    }
}

// MARK: - BAM

enum BAM {
    static let magic: [UInt8] = [0x42, 0x41, 0x4D, 0x01]  // "BAM\1"
    static let nibble: [UInt8] = Array("=ACMGRSVTWYHKDBN".utf8)
    static let code: [UInt8] = {
        var t = [UInt8](repeating: 15, count: 256)
        for (i, c) in nibble.enumerated() { t[Int(c)] = UInt8(i); t[Int(Character(String(UnicodeScalar(c))).lowercased().utf8.first!)] = UInt8(i) }
        return t
    }()

    /// UCSC binning scheme (SAM specification §5.3), for [beg, end) 0-based.
    static func reg2bin(_ beg: Int, _ end: Int) -> UInt16 {
        let end = end - 1
        if beg >> 14 == end >> 14 { return UInt16(((1 << 15) - 1) / 7 + (beg >> 14)) }
        if beg >> 17 == end >> 17 { return UInt16(((1 << 12) - 1) / 7 + (beg >> 17)) }
        if beg >> 20 == end >> 20 { return UInt16(((1 << 9) - 1) / 7 + (beg >> 20)) }
        if beg >> 23 == end >> 23 { return UInt16(((1 << 6) - 1) / 7 + (beg >> 23)) }
        if beg >> 26 == end >> 26 { return UInt16(((1 << 3) - 1) / 7 + (beg >> 26)) }
        return 0
    }

    static func encode(_ r: AlignmentRecord, into w: inout ByteWriter) {
        let start = w.bytes.count
        w.u32(0)  // block_size, patched below
        w.u32(UInt32(bitPattern: r.refID)); w.u32(UInt32(bitPattern: r.pos))
        let span = max(1, r.referenceLength)
        let bin = r.pos < 0 ? 4680 : reg2bin(Int(r.pos), Int(r.pos) + (r.isUnmapped ? 1 : span))
        w.u8(UInt8(r.name.count + 1)); w.u8(r.mapq); w.u16(bin)
        w.u16(UInt16(r.cigar.count)); w.u16(r.flag); w.u32(UInt32(r.seq.count))
        w.u32(UInt32(bitPattern: r.nextRefID)); w.u32(UInt32(bitPattern: r.nextPos)); w.u32(UInt32(bitPattern: r.tlen))
        w.append(r.name); w.u8(0)
        for c in r.cigar { w.u32(c) }
        var i = 0
        while i < r.seq.count {
            let hi = code[Int(r.seq[i])], lo = i + 1 < r.seq.count ? code[Int(r.seq[i + 1])] : 0
            w.u8(hi << 4 | lo)
            i += 2
        }
        if r.qual.count == r.seq.count { w.append(r.qual) } else { w.append([UInt8](repeating: 0xFF, count: r.seq.count)) }
        for t in r.tags { w.append(t.key); w.u8(t.type); w.append(t.value) }
        let size = UInt32(w.bytes.count - start - 4)
        for k in 0..<4 { w.bytes[start + k] = UInt8(truncatingIfNeeded: size >> (8 * UInt32(k))) }
    }

    static func decode(_ b: UnsafeRawBufferPointer) throws -> AlignmentRecord {
        guard b.count >= 32 else { throw XipperError.corrupt("BAM record too short") }
        func i32(_ o: Int) -> Int32 { Int32(littleEndian: b.loadUnaligned(fromByteOffset: o, as: Int32.self)) }
        func u16(_ o: Int) -> UInt16 { UInt16(littleEndian: b.loadUnaligned(fromByteOffset: o, as: UInt16.self)) }
        var r = AlignmentRecord()
        r.refID = i32(0); r.pos = i32(4)
        let nameLen = Int(b[8]); r.mapq = b[9]
        let nCigar = Int(u16(12)); r.flag = u16(14)
        let lSeq = Int(i32(16))
        r.nextRefID = i32(20); r.nextPos = i32(24); r.tlen = i32(28)
        var o = 32
        guard nameLen >= 1, lSeq >= 0, o + nameLen + 4 * nCigar + (lSeq + 1) / 2 + lSeq <= b.count else {
            throw XipperError.corrupt("BAM record fields exceed its size")
        }
        r.name = Array(b[o..<(o + nameLen - 1)]); o += nameLen
        r.cigar = (0..<nCigar).map { UInt32(littleEndian: b.loadUnaligned(fromByteOffset: o + 4 * $0, as: UInt32.self)) }
        o += 4 * nCigar
        r.seq = [UInt8](unsafeUninitializedCapacity: lSeq) { buf, n in
            for k in 0..<lSeq {
                let byte = b[o + k / 2]
                buf[k] = nibble[Int(k & 1 == 0 ? byte >> 4 : byte & 0xF)]
            }
            n = lSeq
        }
        o += (lSeq + 1) / 2
        r.qual = Array(b[o..<(o + lSeq)]); o += lSeq
        r.tags = try AlignmentRecord.parseTags(UnsafeRawBufferPointer(rebasing: b[o...]))
        // CIGAR stored in the CG tag (more than 65535 operations).
        if nCigar == 2, lSeq > 0, AlignmentRecord.op(r.cigar[0]) == UInt8(ascii: "S"), Int(r.cigar[0] >> 4) == lSeq,
           let cg = r.tags.firstIndex(where: { $0.key == Array("CG".utf8) && $0.type == UInt8(ascii: "B") }) {
            let v = r.tags[cg].value
            r.cigar = stride(from: 5, to: v.count, by: 4).map { UInt32(v[$0]) | UInt32(v[$0 + 1]) << 8 | UInt32(v[$0 + 2]) << 16 | UInt32(v[$0 + 3]) << 24 }
            r.tags.remove(at: cg)
        }
        return r
    }
}

/// Sequential BAM reader (BGZF decompressed in parallel on its own thread).
final class BAMReader {
    let header: SAMHeader
    private let pipe: DecodingPipe
    private var buf: [UInt8] = []
    private var pos = 0
    private var ended = false

    init(_ url: URL, workload: Workload = .interactive) throws {
        let file = try FileReader(path: url.path)
        pipe = try DecodingPipe(file: file, compression: .bgzf, threads: workload.workerCount,
                                qos: workload == .background ? .utility : .userInitiated)
        var magic = [UInt8](repeating: 0, count: 4)
        try Self.read(pipe, &magic, 4)
        guard magic == BAM.magic else { pipe.close(); throw XipperError.corrupt("not a BAM file") }
        let lText = Int(try Self.int32(pipe))
        guard lText >= 0, lText < 1 << 30 else { throw XipperError.corrupt("BAM header too large") }
        var text = [UInt8](repeating: 0, count: lText)
        try Self.read(pipe, &text, lText)
        if let nul = text.firstIndex(of: 0) { text.removeSubrange(nul...) }
        let nRef = Int(try Self.int32(pipe))
        guard nRef >= 0, nRef < 1 << 24 else { throw XipperError.corrupt("BAM reference count") }
        var refs: [(String, Int)] = []
        for _ in 0..<nRef {
            let l = Int(try Self.int32(pipe))
            guard l > 0, l < 1 << 16 else { throw XipperError.corrupt("BAM reference name") }
            var name = [UInt8](repeating: 0, count: l)
            try Self.read(pipe, &name, l)
            refs.append((String(decoding: name.dropLast(), as: UTF8.self), Int(try Self.int32(pipe))))
        }
        header = SAMHeader(text: String(decoding: text, as: UTF8.self), references: refs)
    }

    deinit { pipe.close() }

    private static func read(_ p: DecodingPipe, _ b: inout [UInt8], _ n: Int) throws {
        guard n > 0 else { return }
        _ = try b.withUnsafeMutableBytes { try p.readExactly(into: $0.baseAddress!, count: n) }
    }
    private static func int32(_ p: DecodingPipe) throws -> Int32 {
        var b = [UInt8](repeating: 0, count: 4)
        try read(p, &b, 4)
        return Int32(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
    }

    /// Makes at least `n` bytes available from `pos`; false at a clean end of stream.
    private func fill(_ n: Int) throws -> Bool {
        if buf.count - pos >= n { return true }
        if pos > 0 { buf.removeSubrange(0..<pos); pos = 0 }
        while buf.count < n && !ended {
            let want = max(n - buf.count, 1 << 20)
            let old = buf.count
            buf.append(contentsOf: repeatElement(0, count: want))
            let got = try buf.withUnsafeMutableBytes { try pipe.read(into: $0.baseAddress! + old, max: want) }
            buf.removeSubrange((old + got)...)
            if got == 0 { ended = true }
        }
        return buf.count >= n
    }

    func next() throws -> AlignmentRecord? {
        guard try fill(4) else {
            if buf.count - pos != 0 { throw XipperError.corrupt("truncated BAM record") }
            return nil
        }
        let size = Int(UInt32(buf[pos]) | UInt32(buf[pos + 1]) << 8 | UInt32(buf[pos + 2]) << 16 | UInt32(buf[pos + 3]) << 24)
        guard size >= 32, size < 1 << 28, try fill(4 + size) else { throw XipperError.corrupt("truncated BAM record") }
        let r = try buf.withUnsafeBytes { try BAM.decode(UnsafeRawBufferPointer(rebasing: $0[(pos + 4)..<(pos + 4 + size)])) }
        pos += 4 + size
        return r
    }
}

/// BAM writer: records are buffered and BGZF-compressed in parallel.
final class BAMWriter {
    private let out: OutputFile
    private let encoder: BGZFEncoder
    private var w = ByteWriter(capacity: 1 << 20)

    init(path: String, header: SAMHeader, level: Int = 6, workload: Workload = .interactive) throws {
        out = try OutputFile(path: path)
        encoder = BGZFEncoder(level: level, workload: workload, cancel: nil)
        var text = header.text
        if !text.contains("@SQ\t") && !header.references.isEmpty { text += SAMHeader.sqLines(header.references) }
        let t = Array(text.utf8)
        w.append(BAM.magic); w.u32(UInt32(t.count)); w.append(t)
        w.u32(UInt32(header.references.count))
        for r in header.references {
            let n = Array(r.name.utf8)
            w.u32(UInt32(n.count + 1)); w.append(n); w.u8(0); w.u32(UInt32(r.length))
        }
    }

    func write(_ r: AlignmentRecord) throws {
        BAM.encode(r, into: &w)
        if w.bytes.count >= 1 << 20 { try flush() }
    }

    private func flush() throws {
        let out = self.out
        try w.bytes.withUnsafeBytes { try encoder.process($0, { try out.write($0) }) }
        w.bytes.removeAll(keepingCapacity: true)
    }

    func finish(overwrite: Bool) throws {
        try flush()
        let out = self.out
        try encoder.finish { try out.write($0) }
        try out.commit(overwrite: overwrite)
    }
}
