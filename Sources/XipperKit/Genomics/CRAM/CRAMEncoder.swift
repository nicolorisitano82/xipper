import CryptoKit
import Foundation

/// BAM → CRAM 3.0/3.1 (CRAMv3). Choices, all within the specification:
/// - every data series in its own external block, compressed with the smallest of rANS Nx16,
///   the adaptive arithmetic coder and gzip (3.1), or rANS 4x8 and gzip (3.0); read names with
///   the name tokeniser and qualities with fqzcomp (3.1);
/// - mates stored "detached" (verbatim), so mate fields round-trip exactly;
/// - substitutions as X features with a matrix ordered by frequency; any other base (IUPAC
///   codes, or a reference that is not ACGTN) as a one-base `b` stretch, which keeps the QS block
///   made only of whole quality strings, as fqzcomp needs;
/// - all tags stored verbatim, MD and NM included.
enum CRAMEncoder {
    struct Options {
        var minor: UInt8 = 1
        var recordsPerContainer = 10_000
    }

    // Content ids of the data series (tags use their 3-byte key, lengths the key + 2^24).
    static let ids: [String: Int32] = [
        "BF": 1, "CF": 2, "RI": 3, "RL": 4, "AP": 5, "RG": 6, "RN": 7, "MF": 8, "NS": 9, "NP": 10, "TS": 11, "NF": 12,
        "TL": 13, "FN": 14, "FC": 15, "FP": 16, "DL": 17, "BB": 18, "QQ": 19, "BS": 20, "IN": 21, "RS": 22, "PD": 23,
        "HC": 24, "SC": 25, "MQ": 26, "BA": 27, "QS": 28,
    ]
    static let byteArraySeries: Set<String> = ["RN", "IN", "SC", "BB", "QQ"]

    /// External blocks being filled for one slice.
    struct Streams {
        var blocks: [Int32: [UInt8]] = [:]
        mutating func int(_ key: String, _ v: Int32) { CRAMIO.itf8(v, into: &blocks[ids[key]!, default: []]) }
        mutating func byte(_ key: String, _ v: UInt8) { blocks[ids[key]!, default: []].append(v) }
        mutating func bytes(_ key: String, _ v: [UInt8]) { blocks[ids[key]!, default: []] += v }
        mutating func stop(_ key: String, _ v: [UInt8]) { blocks[ids[key]!, default: []] += v + [0] }
    }

    static func tagID(_ key: [UInt8], _ type: UInt8) -> Int32 { Int32(key[0]) << 16 | Int32(key[1]) << 8 | Int32(type) }
    static func fixedSize(_ type: UInt8) -> Int? {
        switch type { case 65, 99, 67: 1; case 115, 83: 2; case 105, 73, 102: 4; default: nil }
    }

    /// One container (one slice) of records, as bytes. `counter` is the index of the first record.
    static func container(_ recs: [AlignmentRecord], counter: Int64, header: SAMHeader, groups: [String: Int32],
                          reference: ReferenceSet?, options: Options) throws -> [UInt8] {
        let refIDs = Set(recs.map { $0.flag & 4 != 0 && $0.refID < 0 ? -1 : $0.refID })
        let sliceRef: Int32 = refIDs.count == 1 ? refIDs.first! : -2
        // AP as deltas when positions never go back within a single reference.
        let positions = recs.map(\.pos)
        let apDelta = sliceRef >= 0 && zip(positions, positions.dropFirst()).allSatisfy { $0 <= $1 }
        var start: Int32 = 0, end: Int32 = 0
        if sliceRef >= 0 {
            start = (positions.min() ?? 0) + 1
            end = recs.map { $0.pos + Int32($0.flag & 4 != 0 ? 1 : max(1, $0.referenceLength)) }.max() ?? start
        }
        var refCache: [Int32: [UInt8]] = [:]
        func ref(_ id: Int32) throws -> [UInt8]? {
            if let c = refCache[id] { return c }
            guard id >= 0, Int(id) < header.references.count, let reference else { return nil }
            let s = try reference.sequence(header.references[Int(id)].name)
            refCache[id] = s
            return s
        }

        // Substitution matrix: per reference base, codes by decreasing frequency.
        var counts = [[Int]](repeating: [Int](repeating: 0, count: 5), count: 5)
        var features: [[(pos: Int, code: UInt8, data: Feature)]] = []
        for r in recs {
            let f = try readFeatures(r, ref: try ref(r.refID))
            for x in f { if case let .sub(rb, b) = x.data { counts[rb][b] += 1 } }
            features.append(f)
        }
        var sm = [UInt8](repeating: 0, count: 5)
        var codeOf = [[UInt8]](repeating: [UInt8](repeating: 0, count: 5), count: 5)
        for rb in 0..<5 {
            let others = (0..<5).filter { $0 != rb }
            let ranked = others.sorted { (counts[rb][$0], -$0) > (counts[rb][$1], -$1) }
            for (code, b) in ranked.enumerated() { codeOf[rb][b] = UInt8(code) }
            sm[rb] = others.enumerated().reduce(UInt8(0)) { $0 | codeOf[rb][$1.element] << (6 - 2 * UInt8($1.offset)) }
        }

        // Tag lines.
        var tagLines: [[(key: [UInt8], type: UInt8)]] = []
        var lineIndex: [[UInt8]: Int32] = [:]
        var tagTypes: [Int32: UInt8] = [:]

        var s = Streams()
        var lastPos = start
        var bases: Int64 = 0
        var qualLengths: [UInt32] = [], qualFlags: [UInt32] = []
        for (i, r) in recs.enumerated() {
            let unmapped = r.flag & 4 != 0
            let noSeq = r.seq.isEmpty
            let hasQual = !noSeq && r.qual.count == r.seq.count && !r.qual.allSatisfy { $0 == 0xFF }
            var cf: Int32 = 2  // detached
            if hasQual { cf |= 1 }
            if noSeq && !unmapped { cf |= 8 }
            let length = noSeq ? (unmapped ? 0 : r.cigar.reduce(0) { "MIS=X".utf8.contains(AlignmentRecord.op($1)) ? $0 + Int($1 >> 4) : $0 }) : r.seq.count
            bases += Int64(length)
            s.int("BF", Int32(r.flag))
            s.int("CF", cf)
            if sliceRef == -2 { s.int("RI", r.refID) }
            s.int("RL", Int32(length))
            if apDelta { s.int("AP", r.pos + 1 - lastPos); lastPos = r.pos + 1 } else { s.int("AP", r.pos + 1) }
            var tags = r.tags
            var rg: Int32 = -1
            if let k = tags.firstIndex(where: { $0.key == [82, 71] && $0.type == 90 }),
               let g = groups[String(decoding: tags[k].value.dropLast(), as: UTF8.self)] {
                rg = g
                tags.remove(at: k)
            }
            s.int("RG", rg)
            s.stop("RN", r.name)
            var mf: Int32 = 0
            if r.flag & 0x20 != 0 { mf |= 1 }
            if r.flag & 0x08 != 0 { mf |= 2 }
            s.int("MF", mf)
            s.int("NS", r.nextRefID)
            s.int("NP", r.nextPos + 1)
            s.int("TS", r.tlen)
            let line = tags.flatMap { $0.key + [$0.type] }
            let tl: Int32
            if let k = lineIndex[line] { tl = k } else {
                tl = Int32(tagLines.count)
                lineIndex[line] = tl
                tagLines.append(tags.map { ($0.key, $0.type) })
            }
            s.int("TL", tl)
            for t in tags {
                let id = tagID(t.key, t.type)
                tagTypes[id] = t.type
                if fixedSize(t.type) == nil { CRAMIO.itf8(Int32(t.value.count), into: &s.blocks[id + (1 << 24), default: []]) }
                s.blocks[id, default: []] += t.value
            }
            if !unmapped {
                let f = features[i]
                s.int("FN", Int32(f.count))
                var last = 0
                for x in f {
                    s.byte("FC", x.code)
                    s.int("FP", Int32(x.pos - last))
                    last = x.pos
                    switch x.data {
                    case let .sub(rb, b): s.byte("BS", codeOf[rb][b])
                    case let .bases(b): s.stop("BB", b)  // as BYTE_ARRAY_STOP
                    case let .insertion(b): s.stop("IN", b)
                    case let .insertBase(b): s.byte("BA", b)
                    case let .softClip(b): s.stop("SC", b)
                    case let .deletion(n): s.int("DL", Int32(n))
                    case let .skip(n): s.int("RS", Int32(n))
                    case let .padding(n): s.int("PD", Int32(n))
                    case let .hardClip(n): s.int("HC", Int32(n))
                    }
                }
                s.int("MQ", Int32(r.mapq))
            } else {
                s.bytes("BA", r.seq)
            }
            if hasQual {
                s.bytes("QS", r.qual)
                qualLengths.append(UInt32(r.qual.count))
                qualFlags.append(UInt32(r.flag))
            }
        }

        // Compression header.
        var ch: [UInt8] = []
        var pm: [UInt8] = []
        var n = 0
        func put(_ key: String, _ v: [UInt8]) { pm += Array(key.utf8) + v; n += 1 }
        put("RN", [1]); put("AP", [apDelta ? 1 : 0]); put("RR", [1]); put("SM", sm)
        var td: [UInt8] = []
        for l in tagLines { td += l.flatMap { $0.key + [$0.type] } + [0] }
        var tdField: [UInt8] = []
        CRAMIO.itf8(Int32(td.count), into: &tdField)
        put("TD", tdField + td)
        func map(_ body: [UInt8], count: Int) -> [UInt8] {
            var w: [UInt8] = []
            var inner: [UInt8] = []
            CRAMIO.itf8(Int32(count), into: &inner)
            inner += body
            CRAMIO.itf8(Int32(inner.count), into: &w)
            return w + inner
        }
        ch += map(pm, count: n)
        var dsBody: [UInt8] = []
        var dsCount = 0
        for (key, id) in ids.sorted(by: { $0.value < $1.value }) {
            let e: CRAMEncoding = byteArraySeries.contains(key) ? .byteArrayStop(0, id) : .external(id)
            dsBody += Array(key.utf8) + e.serialized()
            dsCount += 1
        }
        ch += map(dsBody, count: dsCount)
        var tagBody: [UInt8] = []
        for (id, type) in tagTypes.sorted(by: { $0.key < $1.key }) {
            CRAMIO.itf8(id, into: &tagBody)
            let len: CRAMEncoding = fixedSize(type).map { .huffman(try! CRAMHuffman([Int32($0)], [0])) } ?? .external(id + (1 << 24))
            tagBody += CRAMEncoding.byteArrayLen(len, .external(id)).serialized()
        }
        ch += map(tagBody, count: tagTypes.count)
        let chBlock = CRAMIO.blockBytes(CRAMIO.Block(contentType: .compressionHeader, data: ch))

        // Data blocks, compressed in parallel.
        let externalIDs = s.blocks.keys.filter { !(s.blocks[$0]?.isEmpty ?? true) }.sorted()
        let packed = Slots<[UInt8]>(externalIDs.count)
        let streams = s.blocks
        try parallelFor(externalIDs.count, workload: .interactive, cancel: nil) { k in
            let id = externalIDs[k]
            let data = streams[id]!
            packed[k] = bestBlock(id: id, data: data, minor: options.minor,
                                  fqz: id == ids["QS"]! ? (qualLengths, qualFlags) : nil)
        }
        let core = CRAMIO.blockBytes(CRAMIO.Block(contentType: .core, contentID: 0, data: []))

        // Slice header.
        var sh: [UInt8] = []
        CRAMIO.itf8(sliceRef, into: &sh)
        CRAMIO.itf8(sliceRef >= 0 ? start : 0, into: &sh)
        CRAMIO.itf8(sliceRef >= 0 ? end - start + 1 : 0, into: &sh)
        CRAMIO.itf8(Int32(recs.count), into: &sh)
        CRAMIO.ltf8(counter, into: &sh)
        CRAMIO.itf8(Int32(externalIDs.count + 1), into: &sh)
        CRAMIO.itf8(Int32(externalIDs.count), into: &sh)
        for id in externalIDs { CRAMIO.itf8(id, into: &sh) }
        CRAMIO.itf8(-1, into: &sh)
        if sliceRef >= 0, let seq = try ref(sliceRef) {
            let a = Int(start) - 1, b = min(seq.count, Int(end))
            sh += a <= b ? Array(Insecure_MD5(seq[a..<b])) : [UInt8](repeating: 0, count: 16)
        } else {
            sh += [UInt8](repeating: 0, count: 16)
        }
        let shBlock = CRAMIO.blockBytes(CRAMIO.Block(contentType: .sliceHeader, data: sh))

        var blocks = chBlock + shBlock + core
        for k in externalIDs.indices { blocks += packed.take(k)! }
        return containerHeader(length: blocks.count, refID: sliceRef, start: sliceRef >= 0 ? start : 0,
                               span: sliceRef >= 0 ? end - start + 1 : 0, records: Int32(recs.count), counter: counter,
                               bases: bases, blockCount: Int32(3 + externalIDs.count), landmarks: [Int32(chBlock.count)]) + blocks
    }

    /// Container header (§7) for `length` bytes of blocks, with its CRC32.
    static func containerHeader(length: Int, refID: Int32, start: Int32, span: Int32, records: Int32, counter: Int64,
                                bases: Int64, blockCount: Int32, landmarks: [Int32]) -> [UInt8] {
        var w: [UInt8] = []
        CRAMIO.int32(Int32(length), into: &w)
        for v in [refID, start, span, records] { CRAMIO.itf8(v, into: &w) }
        CRAMIO.ltf8(counter, into: &w)
        CRAMIO.ltf8(bases, into: &w)
        CRAMIO.itf8(blockCount, into: &w)
        CRAMIO.itf8(Int32(landmarks.count), into: &w)
        for l in landmarks { CRAMIO.itf8(l, into: &w) }
        CRAMIO.int32(Int32(bitPattern: CRC32.checksum(w)), into: &w)
        return w
    }

    /// The smallest encoding of an external block.
    static func bestBlock(id: Int32, data: [UInt8], minor: UInt8, fqz: ([UInt32], [UInt32])?) -> [UInt8] {
        let plain = CRAMIO.Block(contentType: .external, contentID: id, data: data)
        var best = CRAMIO.blockBytes(plain)
        func consider(_ m: CRAMIO.Method, _ order: Int32 = 0, fqz: ([UInt32], [UInt32])? = nil) {
            guard let c = CRAMIO.compress(m, data, order: order, fqz: fqz.map { (lengths: $0.0, flags: $0.1) }) else { return }
            var b = plain
            b.method = m
            let bytes = CRAMIO.blockBytes(b, compressed: c)
            if bytes.count < best.count { best = bytes }
        }
        consider(.gzip, 6)
        if minor >= 1 {
            for o: Int32 in [0, 1, 0x40, 0x41, 0x80, 0xC0] { consider(.ransNx16, o) }
            if data.count > 4096 { for o: Int32 in [0, 1] { consider(.arith, o) } }
            if id == ids["RN"]! { consider(.tok3) }
            if let fqz, !fqz.0.isEmpty, fqz.0.reduce(0, { $0 + Int($1) }) == data.count { consider(.fqzcomp, fqz: fqz) }
        } else {
            for o: Int32 in [0, 1] { consider(.rans4x8, o) }
        }
        return best
    }

    // MARK: read features

    enum Feature {
        case sub(Int, Int)  // reference base index, read base index (ACGTN)
        case bases([UInt8]), insertion([UInt8]), insertBase(UInt8), softClip([UInt8])
        case deletion(Int), skip(Int), padding(Int), hardClip(Int)
    }

    /// CIGAR and sequence against the reference → read features (positions 1-based in the read).
    static func readFeatures(_ r: AlignmentRecord, ref: [UInt8]?) throws -> [(pos: Int, code: UInt8, data: Feature)] {
        guard r.flag & 4 == 0 else { return [] }
        var out: [(Int, UInt8, Feature)] = []
        var p = 0, rp = Int(r.pos)
        let noSeq = r.seq.isEmpty
        func refBase(_ i: Int) -> UInt8 {
            guard let ref, i >= 0, i < ref.count else { return 78 }
            return ref[i]
        }
        for c in r.cigar {
            let n = Int(c >> 4)
            switch AlignmentRecord.op(c) {
            case 77, 61, 88:  // M = X
                if !noSeq {
                    for k in 0..<n {
                        let b = r.seq[p + k], rb = refBase(rp + k)
                        if b == rb || b == 61 { continue }
                        if let bi = CRAMCompressionHeader.baseIndex(b), let ri = CRAMCompressionHeader.baseIndex(rb) {
                            out.append((p + k + 1, 88, .sub(ri, bi)))
                        } else {
                            out.append((p + k + 1, 98, .bases([b])))
                        }
                    }
                }
                p += n; rp += n
            case 73:  // I
                if noSeq { out.append((p + 1, 73, .insertion([UInt8](repeating: 78, count: n)))) }
                else if n == 1 { out.append((p + 1, 105, .insertBase(r.seq[p]))) }
                else { out.append((p + 1, 73, .insertion(Array(r.seq[p..<(p + n)])))) }
                p += n
            case 83:  // S
                out.append((p + 1, 83, .softClip(noSeq ? [UInt8](repeating: 78, count: n) : Array(r.seq[p..<(p + n)]))))
                p += n
            case 68: out.append((p + 1, 68, .deletion(n))); rp += n
            case 78: out.append((p + 1, 78, .skip(n))); rp += n
            case 80: out.append((p + 1, 80, .padding(n)))
            case 72: out.append((p + 1, 72, .hardClip(n)))
            default: throw XipperError.corrupt("BAM: invalid CIGAR operation")
            }
        }
        if !noSeq && p != r.seq.count { throw XipperError.corrupt("BAM: CIGAR and sequence lengths differ (\(String(decoding: r.name, as: UTF8.self)))") }
        return out
    }
}

private func Insecure_MD5<C: Collection>(_ c: C) -> [UInt8] where C.Element == UInt8 { Array(Insecure.MD5.hash(data: Array(c))) }
