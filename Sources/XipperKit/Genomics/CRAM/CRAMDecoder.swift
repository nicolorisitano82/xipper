import Foundation

// MARK: - encodings (CRAMv3 §13)

indirect enum CRAMEncoding {
    case null
    case external(Int32)
    case golomb(offset: Int32, m: Int32)
    case huffman(CRAMHuffman)
    case byteArrayLen(CRAMEncoding, CRAMEncoding)
    case byteArrayStop(UInt8, Int32)
    case beta(offset: Int32, bits: Int32)
    case subexp(offset: Int32, k: Int32)
    case golombRice(offset: Int32, log2m: Int32)
    case gamma(offset: Int32)

    static func parse(_ r: inout CRAMIO.Reader) throws -> CRAMEncoding {
        let id = try r.itf8()
        let len = Int(try r.itf8())
        var p = CRAMIO.Reader(try r.bytes(len))
        switch id {
        case 0: return .null
        case 1: return .external(try p.itf8())
        case 2: return .golomb(offset: try p.itf8(), m: try p.itf8())
        case 3:
            let alphabet = try (0..<Int(try p.itf8())).map { _ in try p.itf8() }
            let lengths = try (0..<Int(try p.itf8())).map { _ in try p.itf8() }
            guard alphabet.count == lengths.count, !alphabet.isEmpty else { throw XipperError.corrupt("CRAM: invalid Huffman code") }
            return .huffman(try CRAMHuffman(alphabet, lengths))
        case 4: return .byteArrayLen(try parse(&p), try parse(&p))
        case 5: return .byteArrayStop(try p.u8(), try p.itf8())
        case 6: return .beta(offset: try p.itf8(), bits: try p.itf8())
        case 7: return .subexp(offset: try p.itf8(), k: try p.itf8())
        case 8: return .golombRice(offset: try p.itf8(), log2m: try p.itf8())
        case 9: return .gamma(offset: try p.itf8())
        default: throw XipperError.unsupported("CRAM encoding \(id)")
        }
    }

    func serialized() -> [UInt8] {
        var p: [UInt8] = []
        let id: Int32
        switch self {
        case .null: id = 0
        case let .external(b): id = 1; CRAMIO.itf8(b, into: &p)
        case let .golomb(o, m): id = 2; CRAMIO.itf8(o, into: &p); CRAMIO.itf8(m, into: &p)
        case let .huffman(h):
            id = 3
            CRAMIO.itf8(Int32(h.alphabet.count), into: &p); for s in h.alphabet { CRAMIO.itf8(s, into: &p) }
            CRAMIO.itf8(Int32(h.lengths.count), into: &p); for l in h.lengths { CRAMIO.itf8(l, into: &p) }
        case let .byteArrayLen(a, b): id = 4; p = a.serialized() + b.serialized()
        case let .byteArrayStop(s, b): id = 5; p = [s]; CRAMIO.itf8(b, into: &p)
        case let .beta(o, b): id = 6; CRAMIO.itf8(o, into: &p); CRAMIO.itf8(b, into: &p)
        case let .subexp(o, k): id = 7; CRAMIO.itf8(o, into: &p); CRAMIO.itf8(k, into: &p)
        case let .golombRice(o, l): id = 8; CRAMIO.itf8(o, into: &p); CRAMIO.itf8(l, into: &p)
        case let .gamma(o): id = 9; CRAMIO.itf8(o, into: &p)
        }
        var w: [UInt8] = []
        CRAMIO.itf8(id, into: &w); CRAMIO.itf8(Int32(p.count), into: &w)
        return w + p
    }
}

/// Canonical Huffman code (codewords from the bit lengths alone).
struct CRAMHuffman {
    let alphabet: [Int32], lengths: [Int32]
    /// Per bit length: codeword → symbol.
    private var byLength: [Int: [UInt32: Int32]] = [:]
    let single: Int32?

    init(_ alphabet: [Int32], _ lengths: [Int32]) throws {
        self.alphabet = alphabet
        self.lengths = lengths
        single = alphabet.count == 1 ? alphabet[0] : nil
        let order = alphabet.indices.sorted { (lengths[$0], alphabet[$0]) < (lengths[$1], alphabet[$1]) }
        var code: UInt32 = 0, prev = Int(lengths[order[0]])
        for (n, i) in order.enumerated() {
            let l = Int(lengths[i])
            guard l >= 0, l <= 31 else { throw XipperError.corrupt("CRAM: Huffman code length") }
            if n > 0 { code += 1; if l > prev { code <<= UInt32(l - prev) } }
            prev = l
            byLength[l, default: [:]][code] = alphabet[i]
        }
    }

    func decode(_ bits: inout CRAMIO.BitReader) throws -> Int32 {
        if let single { return single }
        var code: UInt32 = 0
        for len in 1...31 {
            code = code << 1 | UInt32(try bits.read(1))
            if let s = byLength[len]?[code] { return s }
        }
        throw XipperError.corrupt("CRAM: invalid Huffman codeword")
    }

    /// Codewords for encoding: symbol → (code, length).
    func codes() -> [Int32: (UInt32, Int)] {
        var out: [Int32: (UInt32, Int)] = [:]
        for (l, m) in byLength { for (c, s) in m { out[s] = (c, l) } }
        return out
    }
}

// MARK: - compression header (§8.4)

struct CRAMCompressionHeader {
    var readNames = true, apDelta = true, referenceRequired = true
    /// Substitution matrix as stored (5 bytes) and as a lookup: [ref base index][code] → base.
    var sm: [UInt8] = [0x1B, 0x1B, 0x1B, 0x1B, 0x1B]
    var tagDictionary: [[(key: [UInt8], type: UInt8)]] = []
    var series: [String: CRAMEncoding] = [:]
    var tags: [Int32: CRAMEncoding] = [:]

    static let bases: [UInt8] = Array("ACGTN".utf8)
    static func baseIndex(_ b: UInt8) -> Int? {
        switch b { case 65: 0; case 67: 1; case 71: 2; case 84: 3; case 78: 4; default: nil }
    }

    /// [ref][code] → substituted base.
    var substitutions: [[UInt8]] {
        (0..<5).map { ref in
            var t = [UInt8](repeating: 78, count: 4)
            let others = (0..<5).filter { $0 != ref }
            for (k, base) in others.enumerated() { t[Int(sm[ref] >> (6 - 2 * UInt8(k)) & 3)] = Self.bases[base] }
            return t
        }
    }

    static func parse(_ data: [UInt8]) throws -> CRAMCompressionHeader {
        var h = CRAMCompressionHeader()
        var r = CRAMIO.Reader(data)
        _ = try r.itf8()  // preservation map size
        for _ in 0..<Int(try r.itf8()) {
            let key = String(decoding: try r.bytes(2), as: UTF8.self)
            switch key {
            case "RN": h.readNames = try r.u8() != 0
            case "AP": h.apDelta = try r.u8() != 0
            case "RR": h.referenceRequired = try r.u8() != 0
            case "SM": h.sm = try r.bytes(5)
            case "TD":
                let td = try r.bytes(Int(try r.itf8()))
                h.tagDictionary = td.split(separator: 0, omittingEmptySubsequences: false).dropLast(td.last == 0 ? 1 : 0).map { line in
                    stride(from: 0, to: line.count - 2, by: 3).map { i in
                        let a = Array(line[(line.startIndex + i)..<(line.startIndex + i + 3)])
                        return ([a[0], a[1]], a[2])
                    }
                }
            default: throw XipperError.unsupported("CRAM preservation key \(key)")
            }
        }
        _ = try r.itf8()
        for _ in 0..<Int(try r.itf8()) {
            let key = String(decoding: try r.bytes(2), as: UTF8.self)
            h.series[key] = try CRAMEncoding.parse(&r)
        }
        _ = try r.itf8()
        for _ in 0..<Int(try r.itf8()) {
            let key = try r.itf8()
            h.tags[key] = try CRAMEncoding.parse(&r)
        }
        return h
    }
}

// MARK: - slice decoding (§10)

/// Reads data series values from a slice's core and external blocks.
struct CRAMSeriesReader {
    var core: CRAMIO.BitReader
    var external: [Int32: CRAMIO.Reader]

    mutating func int(_ e: CRAMEncoding?) throws -> Int32 {
        guard let e else { throw XipperError.corrupt("CRAM: data series without encoding") }
        switch e {
        case .null: return 0
        case let .external(id):
            guard external[id] != nil else { throw XipperError.corrupt("CRAM: missing external block \(id)") }
            return try external[id]!.itf8()
        case let .huffman(h): return try h.decode(&core)
        case let .beta(o, b): return try core.read(Int(b)) - o
        case let .gamma(o):
            var n = 0
            while try !core.one() { n += 1; if n > 31 { throw XipperError.corrupt("CRAM: gamma code") } }
            return Int32(bitPattern: UInt32(1) << UInt32(n) | UInt32(bitPattern: try core.read(n))) - o
        case let .subexp(o, k):
            var u = 0
            while try core.one() { u += 1; if u > 31 { throw XipperError.corrupt("CRAM: subexp code") } }
            let n: Int32 = u == 0 ? try core.read(Int(k)) : Int32(bitPattern: UInt32(1) << UInt32(u + Int(k) - 1) | UInt32(bitPattern: try core.read(u + Int(k) - 1)))
            return n - o
        case let .golombRice(o, l):
            var q: Int32 = 0
            while try core.one() { q += 1 }
            return q << l | (try core.read(Int(l))) - o
        case let .golomb(o, m):
            var q: Int32 = 0
            while try core.one() { q += 1 }
            var b = 0
            while (1 << b) < m { b += 1 }
            var r = try core.read(b - 1)
            let cut = Int32(1 << b) - m
            if r >= cut { r = r * 2 + (try core.read(1)) - cut }
            return q * m + r - o
        default: throw XipperError.corrupt("CRAM: byte-array encoding used for an integer")
        }
    }

    mutating func byte(_ e: CRAMEncoding?) throws -> UInt8 {
        if case let .external(id)? = e {
            guard external[id] != nil else { throw XipperError.corrupt("CRAM: missing external block \(id)") }
            return try external[id]!.u8()
        }
        return UInt8(truncatingIfNeeded: try int(e))
    }

    mutating func bytes(_ e: CRAMEncoding?, count: Int) throws -> [UInt8] {
        if case let .external(id)? = e {
            guard external[id] != nil else { throw XipperError.corrupt("CRAM: missing external block \(id)") }
            return try external[id]!.bytes(count)
        }
        return try (0..<count).map { _ in try byte(e) }
    }

    mutating func array(_ e: CRAMEncoding?) throws -> [UInt8] {
        switch e {
        case let .byteArrayLen(len, val)?:
            let n = Int(try int(len))
            guard n >= 0, n < 1 << 28 else { throw XipperError.corrupt("CRAM: byte array length") }
            return try bytes(val, count: n)
        case let .byteArrayStop(stop, id)?:
            guard var x = external[id] else { throw XipperError.corrupt("CRAM: missing external block \(id)") }
            guard let end = x.b[x.pos...].firstIndex(of: stop) else { throw XipperError.corrupt("CRAM: unterminated byte array") }
            let v = Array(x.b[x.pos..<end])
            x.pos = end + 1
            external[id] = x
            return v
        default: throw XipperError.corrupt("CRAM: byte array without a byte-array encoding")
        }
    }
}

/// A decoded CRAM record before the slice's mates are resolved.
struct CRAMRecord {
    var bam = AlignmentRecord()
    var cf: Int32 = 0
    var nextFragment = -1  // index in the slice
    var readGroup: Int32 = -1
    var mateResolved = false
}

struct CRAMSliceHeader {
    var refID: Int32 = -1, start: Int32 = 0, span: Int32 = 0, records: Int32 = 0
    var counter: Int64 = 0
    /// Blocks in the slice (core included); `contentIDs` lists only the external ones.
    var blockCount: Int32 = 0
    var contentIDs: [Int32] = []
    var embeddedRef: Int32 = -1
    var md5: [UInt8] = []

    static func parse(_ data: [UInt8]) throws -> CRAMSliceHeader {
        var r = CRAMIO.Reader(data)
        var s = CRAMSliceHeader()
        s.refID = try r.itf8(); s.start = try r.itf8(); s.span = try r.itf8(); s.records = try r.itf8()
        s.counter = try r.ltf8()
        s.blockCount = try r.itf8()
        s.contentIDs = try (0..<Int(try r.itf8())).map { _ in try r.itf8() }
        s.embeddedRef = try r.itf8()
        s.md5 = try r.bytes(16)
        return s
    }
}

/// Options shared by the decoder entry points.
struct CRAMDecodeOptions {
    /// Generate MD and NM for mapped reads that do not store them, as htslib does.
    var regenerateMDNM = true
}

enum CRAMDecoder {
    /// Decodes one slice: `blocks` are the slice's data blocks (core and external).
    static func decodeSlice(_ s: CRAMSliceHeader, blocks: [CRAMIO.Block], ch: CRAMCompressionHeader, header: SAMHeader,
                            readGroups: [String], reference: ReferenceSet?, options: CRAMDecodeOptions) throws -> [AlignmentRecord] {
        var core = CRAMIO.BitReader([])
        var external: [Int32: CRAMIO.Reader] = [:]
        for b in blocks {
            if b.contentType == .core { core = CRAMIO.BitReader(b.data) } else if b.contentType == .external { external[b.contentID] = CRAMIO.Reader(b.data) }
        }
        var rd = CRAMSeriesReader(core: core, external: external)
        let sub = ch.substitutions
        let ds = ch.series

        // Reference bases for the slice (or per record for multi-reference slices).
        var refCache: [Int32: [UInt8]] = [:]
        var embedded: [UInt8]?
        if s.embeddedRef >= 0 {
            guard let b = blocks.first(where: { $0.contentType == .external && $0.contentID == s.embeddedRef }) else {
                throw XipperError.corrupt("CRAM: embedded reference block missing")
            }
            embedded = b.data.map { $0 >= 97 ? $0 - 32 : $0 }
        }
        func refBases(_ id: Int32) throws -> [UInt8]? {
            if let c = refCache[id] { return c }
            guard id >= 0, id < Int32(header.references.count), let reference else { return nil }
            let seq = try reference.sequence(header.references[Int(id)].name)
            refCache[id] = seq
            return seq
        }
        // The slice's MD5 tells whether the reference given is the one used to write it.
        if s.refID >= 0, embedded == nil, !s.md5.allSatisfy({ $0 == 0 }), s.span > 0, let seq = try refBases(s.refID) {
            let a = Int(s.start) - 1, b = min(seq.count, a + Int(s.span))
            if a >= 0, a <= b, ReferenceSet.md5Hex(seq[a..<b]) != s.md5.map({ String(format: "%02x", $0) }).joined() {
                throw XipperError.corrupt("CRAM: the reference does not match the one used to write the file (\(header.references[Int(s.refID)].name))")
            }
        }

        var recs: [CRAMRecord] = []
        recs.reserveCapacity(Int(s.records))
        var lastPos = s.start
        for idx in 0..<Int(s.records) {
            var c = CRAMRecord()
            var r = AlignmentRecord()
            r.flag = UInt16(truncatingIfNeeded: try rd.int(ds["BF"]))
            c.cf = try rd.int(ds["CF"])
            r.refID = s.refID == -2 ? try rd.int(ds["RI"]) : s.refID
            let length = Int(try rd.int(ds["RL"]))
            guard length >= 0, length < 1 << 28 else { throw XipperError.corrupt("CRAM: read length") }
            var ap = try rd.int(ds["AP"])
            if ch.apDelta { ap += lastPos; lastPos = ap }
            r.pos = ap - 1
            c.readGroup = try rd.int(ds["RG"])
            if ch.readNames { r.name = try rd.array(ds["RN"]) }
            // Mates.
            if c.cf & 2 != 0 {
                let mf = try rd.int(ds["MF"])
                if mf & 1 != 0 { r.flag |= 0x20 }
                if mf & 2 != 0 { r.flag |= 0x08 }
                if !ch.readNames { r.name = try rd.array(ds["RN"]) }
                r.nextRefID = try rd.int(ds["NS"])
                r.nextPos = try rd.int(ds["NP"]) - 1
                r.tlen = try rd.int(ds["TS"])
                c.mateResolved = true
            } else if c.cf & 4 != 0 {
                c.nextFragment = idx + Int(try rd.int(ds["NF"])) + 1
            }
            if !ch.readNames && r.name.isEmpty { r.name = Array("\(s.counter + Int64(idx))".utf8) }
            // Tags.
            let tl = Int(try rd.int(ds["TL"]))
            guard tl >= 0, tl < ch.tagDictionary.count || (tl == 0 && ch.tagDictionary.isEmpty) else { throw XipperError.corrupt("CRAM: tag line \(tl)") }
            if tl < ch.tagDictionary.count {
                for (key, type) in ch.tagDictionary[tl] {
                    let id = Int32(key[0]) << 16 | Int32(key[1]) << 8 | Int32(type)
                    r.tags.append(AlignmentRecord.Tag(key: key, type: type, value: try rd.array(ch.tags[id])))
                }
            }
            // Sequence.
            if r.flag & 4 == 0 {
                let ref = try embedded ?? refBases(r.refID)
                let refOffset = embedded != nil ? Int(s.start) - 1 : 0
                try decodeMapped(&r, length: length, cf: c.cf, rd: &rd, ds: ds, sub: sub, ref: ref, refOffset: refOffset)
            } else {
                r.seq = try rd.bytes(ds["BA"], count: length)
                r.qual = c.cf & 1 != 0 ? try rd.bytes(ds["QS"], count: length) : [UInt8](repeating: 0xFF, count: length)
                r.mapq = 0
            }
            if c.cf & 8 != 0 { r.seq = []; r.qual = [] }
            c.bam = r
            recs.append(c)
        }
        resolveMates(&recs)
        return try recs.map { c in
            var r = c.bam
            if options.regenerateMDNM && r.flag & 4 == 0 && !r.seq.isEmpty && !r.cigar.isEmpty {
                let ref = try embedded ?? refBases(r.refID)
                if let ref { addMDNM(&r, ref: ref, refOffset: embedded != nil ? Int(s.start) - 1 : 0) }
            }
            if c.readGroup >= 0 && Int(c.readGroup) < readGroups.count {
                r.tags.append(AlignmentRecord.Tag(key: Array("RG".utf8), type: UInt8(ascii: "Z"), value: Array(readGroups[Int(c.readGroup)].utf8) + [0]))
            }
            return r
        }
    }

    /// Read features applied to the reference (§10.6).
    private static func decodeMapped(_ r: inout AlignmentRecord, length: Int, cf: Int32, rd: inout CRAMSeriesReader,
                                     ds: [String: CRAMEncoding], sub: [[UInt8]], ref: [UInt8]?, refOffset: Int) throws {
        func refBase(_ p: Int) -> UInt8 {
            guard let ref, p - refOffset >= 0, p - refOffset < ref.count else { return 78 }
            return ref[p - refOffset]
        }
        var seq = [UInt8](repeating: 0, count: length)
        var qual = [UInt8](repeating: 0xFF, count: length)
        var cigar: [UInt32] = []
        func op(_ code: UInt8, _ n: Int) {
            guard n > 0 else { return }
            let o = UInt32(AlignmentRecord.cigarOps.firstIndex(of: code)!)
            if let last = cigar.last, last & 0xF == o { cigar[cigar.count - 1] = (last >> 4 + UInt32(n)) << 4 | o } else { cigar.append(UInt32(n) << 4 | o) }
        }
        var p = 0  // read position (0-based)
        var rp = Int(r.pos)  // reference position (0-based)
        func matchTo(_ target: Int) {
            while p < target && p < length { seq[p] = refBase(rp); p += 1; rp += 1; op(77, 1) }
        }
        let n = Int(try rd.int(ds["FN"]))
        var last = 0
        for _ in 0..<n {
            let code = try rd.byte(ds["FC"])
            let fp = Int(try rd.int(ds["FP"])) + last
            last = fp
            matchTo(fp - 1)
            switch code {
            case UInt8(ascii: "B"):
                let base = try rd.byte(ds["BA"]), q = try rd.byte(ds["QS"])
                if p < length { seq[p] = base; qual[p] = q }
                p += 1; rp += 1; op(77, 1)
            case UInt8(ascii: "X"):
                let bs = Int(try rd.byte(ds["BS"]))
                let rb = refBase(rp)
                if p < length { seq[p] = sub[CRAMCompressionHeader.baseIndex(rb) ?? 4][bs & 3] }
                p += 1; rp += 1; op(77, 1)
            case UInt8(ascii: "I"):
                let b = try rd.array(ds["IN"])
                for x in b where p < length { seq[p] = x; p += 1 }
                op(73, b.count)
            case UInt8(ascii: "i"):
                let b = try rd.byte(ds["BA"])
                if p < length { seq[p] = b; p += 1 }
                op(73, 1)
            case UInt8(ascii: "S"):
                let b = try rd.array(ds["SC"])
                for x in b where p < length { seq[p] = x; p += 1 }
                op(83, b.count)
            case UInt8(ascii: "D"):
                let d = Int(try rd.int(ds["DL"])); rp += d; op(68, d)
            case UInt8(ascii: "N"):
                let d = Int(try rd.int(ds["RS"])); rp += d; op(78, d)
            case UInt8(ascii: "P"):
                op(80, Int(try rd.int(ds["PD"])))
            case UInt8(ascii: "H"):
                op(72, Int(try rd.int(ds["HC"])))
            case UInt8(ascii: "Q"):
                let q = try rd.byte(ds["QS"])
                if fp - 1 < length { qual[fp - 1] = q }
            case UInt8(ascii: "b"):
                let b = try rd.array(ds["BB"])
                for x in b where p < length { seq[p] = x; p += 1; rp += 1; op(77, 1) }
            case UInt8(ascii: "q"):
                let q = try rd.array(ds["QQ"])
                for (k, x) in q.enumerated() where fp - 1 + k < length { qual[fp - 1 + k] = x }
            default: throw XipperError.corrupt("CRAM: read feature \(code)")
            }
        }
        matchTo(length)
        r.mapq = UInt8(truncatingIfNeeded: try rd.int(ds["MQ"]))
        if cf & 1 != 0 { qual = try rd.bytes(ds["QS"], count: length) }
        r.seq = seq
        r.qual = qual
        r.cigar = cigar
    }

    /// Mate fields of records whose next fragment is in the same slice (§10.4).
    private static func resolveMates(_ recs: inout [CRAMRecord]) {
        for i in recs.indices where recs[i].nextFragment >= 0 && !recs[i].mateResolved {
            // The chain of fragments starting at i.
            var chain = [i]
            var j = recs[i].nextFragment
            while j < recs.count && j > chain.last! {
                chain.append(j)
                recs[j].mateResolved = true
                if recs[j].cf & 4 == 0 || recs[j].nextFragment < 0 { break }
                j = recs[j].nextFragment
            }
            recs[i].mateResolved = true
            guard chain.count > 1 else { continue }
            for (k, a) in chain.enumerated() {
                let b = chain[(k + 1) % chain.count]
                let mate = recs[b].bam
                recs[a].bam.nextRefID = mate.refID
                recs[a].bam.nextPos = mate.pos
                if mate.flag & 0x10 != 0 { recs[a].bam.flag |= 0x20 }
                if mate.flag & 0x04 != 0 { recs[a].bam.flag |= 0x08 }
            }
            // Template size: from the leftmost to the rightmost mapped base, same reference only.
            let members = chain.map { recs[$0].bam }
            let sameRef = Set(members.map(\.refID)).count == 1 && members[0].refID >= 0
            guard sameRef, members.allSatisfy({ $0.flag & 4 == 0 }) else {
                for a in chain { recs[a].bam.tlen = 0 }
                continue
            }
            let starts = members.map { Int($0.pos) }
            let ends = members.map { Int($0.pos) + max(1, $0.referenceLength) - 1 }
            let left = starts.min()!, right = ends.max()!
            let size = Int32(right - left + 1)
            let leftmost = chain[starts.firstIndex(of: left)!]
            for a in chain { recs[a].bam.tlen = a == leftmost ? size : -size }
        }
    }

    /// MD and NM as samtools computes them (SAMtags), appended when absent.
    static func addMDNM(_ r: inout AlignmentRecord, ref: [UInt8], refOffset: Int) {
        let hasMD = r.tag("MD") != nil, hasNM = r.tag("NM") != nil
        if hasMD && hasNM { return }
        var md = "", run = 0, nm = 0
        var p = 0, rp = Int(r.pos) - refOffset
        func refBase(_ i: Int) -> UInt8 { i >= 0 && i < ref.count ? ref[i] : 78 }
        for c in r.cigar {
            let n = Int(c >> 4)
            switch AlignmentRecord.op(c) {
            case 77, 61, 88:  // M = X
                for _ in 0..<n {
                    let rb = refBase(rp), b = p < r.seq.count ? r.seq[p] : 78
                    if (b == rb && rb != 78) || b == 61 { run += 1 } else {
                        md += "\(run)" + String(UnicodeScalar(rb)); run = 0; nm += 1
                    }
                    p += 1; rp += 1
                }
            case 73: p += n; nm += n  // I
            case 83: p += n  // S
            case 68:  // D
                md += "\(run)^" + String(decoding: (0..<n).map { refBase(rp + $0) }, as: UTF8.self); run = 0
                rp += n; nm += n
            case 78: rp += n  // N
            default: break
            }
        }
        md += "\(run)"
        if !hasMD { r.tags.append(AlignmentRecord.Tag(key: Array("MD".utf8), type: UInt8(ascii: "Z"), value: Array(md.utf8) + [0])) }
        if !hasNM {
            let v = UInt32(nm)
            let tag: AlignmentRecord.Tag = v <= 0xFF ? .init(key: Array("NM".utf8), type: UInt8(ascii: "C"), value: [UInt8(v)])
                : v <= 0xFFFF ? .init(key: Array("NM".utf8), type: UInt8(ascii: "S"), value: [UInt8(v & 0xFF), UInt8(v >> 8)])
                : .init(key: Array("NM".utf8), type: UInt8(ascii: "I"), value: [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)])
            r.tags.append(tag)
        }
    }
}
