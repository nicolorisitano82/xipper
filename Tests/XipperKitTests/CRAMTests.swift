import Foundation
import Testing
@testable import XipperKit

/// CRAM 3.0/3.1 ↔ BAM (Genomics/CRAM). The round trip runs everywhere; the interop tests use
/// samtools when it is installed.
@Suite("CRAM 3.1")
struct CRAMTests {
    static let samtools = ["/opt/homebrew/bin/samtools", "/usr/local/bin/samtools"].first(where: toolExists)

    /// A reference with lower case, N and IUPAC bases, and reads covering every CIGAR operation,
    /// substitutions and ambiguous bases, pairs, unmapped reads, "*" sequences and qualities,
    /// and every aux tag type.
    func dataset(_ t: TempDir, reads: Int = 3000, seed: UInt64 = 3) throws -> (bam: URL, ref: URL, records: [AlignmentRecord]) {
        var rng = SplitMix(seed)
        let acgt = Array("ACGT".utf8)
        var chr1 = (0..<30000).map { _ in acgt[rng.int(4)] }
        for i in 500..<520 { chr1[i] = Array("acgtnNRYacgtACGTnnNN".utf8)[i - 500] }
        let chr2 = (0..<9000).map { _ in acgt[rng.int(4)] }
        var fasta = ">chr1 test\n"
        for i in stride(from: 0, to: chr1.count, by: 70) { fasta += String(decoding: chr1[i..<min(chr1.count, i + 70)], as: UTF8.self) + "\n" }
        fasta += ">chr2\n" + String(decoding: chr2, as: UTF8.self) + "\n"
        t.write("ref.fa", fasta)
        let upper = [chr1.map { $0 >= 97 ? $0 - 32 : $0 }, chr2]
        let header = SAMHeader(text: "@HD\tVN:1.6\tSO:coordinate\n@SQ\tSN:chr1\tLN:30000\n@SQ\tSN:chr2\tLN:9000\n@RG\tID:a\tSM:x\n@RG\tID:b\tSM:x\n",
                               references: [("chr1", 30000), ("chr2", 9000)])
        func tag(_ k: String, _ type: Character, _ v: [UInt8]) -> AlignmentRecord.Tag {
            .init(key: Array(k.utf8), type: type.asciiValue!, value: v)
        }
        var recs: [AlignmentRecord] = []
        for i in 0..<reads {
            var r = AlignmentRecord()
            r.name = Array("r\(i):\(rng.int(9999))".utf8)
            let ref = rng.int(5) == 0 ? 1 : 0
            let L = [50, 100, 101][rng.int(3)]
            let pos = rng.int(upper[ref].count - L - 60)
            r.refID = Int32(ref); r.pos = Int32(pos); r.mapq = UInt8(rng.int(61))
            var seq = Array(upper[ref][pos..<(pos + L)])
            switch rng.int(8) {
            case 0: r.cigar = [5 << 4 | 4, UInt32(L - 5) << 4]; for k in 0..<5 { seq[k] = acgt[rng.int(4)] }  // 5S
            case 1: seq.insert(contentsOf: [65, 67], at: 20); seq.removeLast(2); r.cigar = [20 << 4, 2 << 4 | 1, UInt32(L - 22) << 4]  // I
            case 2: seq = Array(upper[ref][pos..<(pos + 30)] + upper[ref][(pos + 33)..<(pos + L + 3)]); r.cigar = [30 << 4, 3 << 4 | 2, UInt32(L - 30) << 4]  // D
            case 3: seq = Array(upper[ref][pos..<(pos + 40)] + upper[ref][(pos + 50)..<(pos + L + 10)]); r.cigar = [3 << 4 | 5, 40 << 4, 10 << 4 | 3, UInt32(L - 40) << 4, 2 << 4 | 5]  // H N H
            case 4: seq.insert(65, at: 10); seq.removeLast(); r.cigar = [10 << 4, 1 << 4 | 1, UInt32(L - 11) << 4]  // single-base I
            default: r.cigar = [UInt32(L) << 4]
            }
            for _ in 0..<rng.int(4) { seq[rng.int(seq.count)] = Array("ACGTNRYKM".utf8)[rng.int(9)] }
            r.seq = seq
            r.qual = rng.int(15) == 0 ? [UInt8](repeating: 0xFF, count: L) : (0..<L).map { _ in UInt8(2 + rng.int(40)) }
            if rng.int(2) == 0 { r.flag |= 16 }
            if rng.int(40) == 0 { r.seq = []; r.qual = [] }  // "*"
            r.tags = [tag("NM", "C", [UInt8(rng.int(5))]), tag("AS", "i", [UInt8(rng.int(200)), 0, 0, 0])]
            if rng.int(3) == 0 { r.tags.append(tag("XS", "Z", Array("+-".utf8)[rng.int(2)...].prefix(1) + [0])) }
            if rng.int(5) == 0 { r.tags.append(tag("XB", "B", [UInt8(ascii: "s"), 3, 0, 0, 0, 1, 0, 0xFF, 0xFF, 7, 1])) }
            if rng.int(7) == 0 { r.tags += [tag("XA", "A", [UInt8(ascii: "q")]), tag("Xc", "c", [0xF0]), tag("XS", "S", [1, 2]),
                                            tag("Xs", "s", [0xFE, 0xFF]), tag("XI", "I", [1, 2, 3, 4]), tag("XF", "f", [0, 0, 0x80, 0x3F]),
                                            tag("XH", "H", Array("1AE3".utf8) + [0])] }
            r.tags.append(tag("RG", "Z", Array((rng.int(3) == 0 ? "b" : "a").utf8) + [0]))
            recs.append(r)
        }
        // Pairs (some across references), then unmapped reads.
        for i in stride(from: 0, to: reads / 2, by: 3) {
            var m = recs[i]
            let ref = Int(m.refID)
            m.pos = min(Int32(upper[ref].count - 120), m.pos + Int32(rng.int(300)))
            m.cigar = [100 << 4]; m.seq = Array(upper[ref][Int(m.pos)..<(Int(m.pos) + 100)]); m.qual = [UInt8](repeating: 30, count: 100)
            recs[i].flag |= 1 | 2 | 64; m.flag = 1 | 2 | 128 | (recs[i].flag & 16 != 0 ? 32 : 0)
            if rng.int(2) == 0 { m.flag |= 16; recs[i].flag |= 32 }
            recs[i].nextRefID = m.refID; recs[i].nextPos = m.pos; m.nextRefID = recs[i].refID; m.nextPos = recs[i].pos
            let tl = m.pos + 100 - recs[i].pos
            recs[i].tlen = tl; m.tlen = -tl
            m.tags = [tag("RG", "Z", Array("a".utf8) + [0])]
            recs.append(m)
        }
        recs.sort { ($0.refID, $0.pos) < ($1.refID, $1.pos) }
        for i in 0..<40 {
            var u = AlignmentRecord()
            u.name = Array("u\(i)".utf8); u.flag = 4; u.mapq = 0
            u.seq = (0..<80).map { _ in Array("ACGTN".utf8)[rng.int(5)] }; u.qual = [UInt8](repeating: 20, count: 80)
            recs.append(u)
        }
        let w = try BAMWriter(path: t.path + "/in.bam", header: header)
        for r in recs { try w.write(r) }
        try w.finish(overwrite: true)
        return (t.url("in.bam"), t.url("ref.fa"), recs)
    }

    func read(_ bam: URL) throws -> [AlignmentRecord] {
        let r = try BAMReader(bam)
        var out: [AlignmentRecord] = []
        while let x = try r.next() { out.append(x) }
        return out
    }

    func sortedTags(_ r: AlignmentRecord) -> AlignmentRecord {
        var r = r
        r.tags.sort { $0.key.lexicographicallyPrecedes($1.key) }
        return r
    }

    @Test(arguments: [UInt8(1), 0])
    func roundTripKeepsEveryRecord(minor: UInt8) throws {
        let t = TempDir()
        let (bam, ref, recs) = try dataset(t)
        #expect(try read(bam) == recs)
        let report = try Xipper.bamToCRAM(bam, output: t.url("x.cram"), reference: ref, minor: minor)
        #expect(report.records == Int64(recs.count))
        #expect(report.outputBytes < (try FileReader(path: bam.path).size))
        let check = try Xipper.checkCRAM(t.url("x.cram"))
        #expect(check.isOK, "\(check.problems)")
        #expect(check.version == "3.\(minor)")
        // Without MD/NM regeneration the records come back exactly (tag order aside: RG goes last).
        let cram = try CRAMFileReader(t.url("x.cram"))
        let refs = try ReferenceSet(fasta: ref)
        var back: [AlignmentRecord] = []
        for c in try cram.containers() { back += try cram.decode(c, reference: refs, options: CRAMDecodeOptions(regenerateMDNM: false)) }
        #expect(back.count == recs.count)
        for (a, b) in zip(back, recs) where sortedTags(a) != sortedTags(b) {
            Issue.record("\(String(decoding: b.name, as: UTF8.self)) differs")
            break
        }
        try Xipper.cramToBAM(t.url("x.cram"), output: t.url("back.bam"), reference: ref)
        #expect(try read(t.url("back.bam")).count == recs.count)
    }

    @Test func wrongReferenceAndDamageAreRefused() throws {
        let t = TempDir()
        let (bam, ref, _) = try dataset(t, reads: 500)
        try Xipper.bamToCRAM(bam, output: t.url("x.cram"), reference: ref)
        var fasta = try String(contentsOf: ref, encoding: .utf8)
        fasta = fasta.replacingOccurrences(of: "\n>chr2\nA", with: "\n>chr2\nC").replacingOccurrences(of: "\n>chr2\nC", with: "\n>chr2\nG")
        let lines = fasta.split(separator: "\n", omittingEmptySubsequences: false)
        t.write("other.fa", ([String(lines[0]), String(lines[1].reversed())] + lines.dropFirst(2).map(String.init)).joined(separator: "\n"))
        #expect(throws: XipperError.self) { try Xipper.cramToBAM(t.url("x.cram"), output: t.url("a.bam"), reference: t.url("other.fa")) }
        var bytes = try [UInt8](Data(contentsOf: t.url("x.cram")))
        bytes[bytes.count / 2] ^= 0x20
        try Data(bytes).write(to: t.url("bad.cram"))
        #expect(throws: XipperError.self) { try Xipper.cramToBAM(t.url("bad.cram"), output: t.url("b.bam"), reference: ref) }
        // A BAM whose @SQ carry M5 (here: decoded from the CRAM) is checked against the reference.
        try Xipper.cramToBAM(t.url("x.cram"), output: t.url("m5.bam"), reference: ref)
        #expect(throws: XipperError.self) { try Xipper.bamToCRAM(t.url("m5.bam"), output: t.url("y.cram"), reference: t.url("other.fa")) }
    }

    // MARK: samtools interop

    func samtoolsView(_ args: [String]) -> [String] {
        let r = run(Self.samtools!, ["view"] + args)
        #expect(r.status == 0, "\(r.output.prefix(300))")
        return r.output.split(separator: "\n").map(String.init)
    }

    @Test(.enabled(if: samtools != nil), arguments: ["version=3.1", "version=3.0", "version=3.1,archive", "version=3.1,embed_ref=1"])
    func readsWhatSamtoolsWrites(option: String) throws {
        let t = TempDir()
        let (bam, ref, _) = try dataset(t)
        #expect(run(Self.samtools!, ["view", "-C", "-T", ref.path, "--output-fmt-option", option, "-o", t.path + "/s.cram", bam.path]).status == 0)
        try Xipper.cramToBAM(t.url("s.cram"), output: t.url("x.bam"), reference: ref)
        #expect(samtoolsView(["-T", ref.path, t.path + "/s.cram"]) == samtoolsView([t.path + "/x.bam"]))
    }

    @Test(.enabled(if: samtools != nil), arguments: [UInt8(1), 0])
    func samtoolsReadsWhatWeWrite(minor: UInt8) throws {
        let t = TempDir()
        let (bam, ref, _) = try dataset(t)
        try Xipper.bamToCRAM(bam, output: t.url("x.cram"), reference: ref, minor: minor)
        let ours = samtoolsView(["-T", ref.path, t.path + "/x.cram"])
        let orig = samtoolsView([bam.path])
        #expect(ours.count == orig.count)
        // samtools adds MD (and NM) where they are missing; everything else must be identical.
        for (x, y) in zip(ours, orig) {
            let fx = x.split(separator: "\t").map(String.init), fy = y.split(separator: "\t").map(String.init)
            let keys = Set(fy.dropFirst(11).map { $0.prefix(2) })
            let tx = fx.dropFirst(11).filter { keys.contains($0.prefix(2)) || !["MD", "NM"].contains($0.prefix(2)) }.sorted()
            if Array(fx.prefix(11)) != Array(fy.prefix(11)) || tx != fy.dropFirst(11).sorted() {
                Issue.record("differs:\n\(x.prefix(200))\n\(y.prefix(200))")
                break
            }
        }
        #expect(run(Self.samtools!, ["quickcheck", t.path + "/x.cram"]).status == 0)
    }
}

/// Small deterministic generator for test data.
struct SplitMix {
    var s: UInt64
    init(_ seed: UInt64) { s = seed }
    mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}
