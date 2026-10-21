import Foundation
import Testing
@testable import XipperKit

let htsBcftools = ["/opt/homebrew/bin/bcftools", "/usr/local/bin/bcftools"].first(where: toolExists)

/// Multi-contig sorted VCF with SNPs, indels, END= records, symbolic SVs and gVCF blocks.
func richVCF(contigs: [String] = ["chr1", "chr2", "chrX"], perContig: Int = 6000) -> String {
    var s = "##fileformat=VCFv4.3\n"
    for c in contigs { s += "##contig=<ID=\(c),length=248956422>\n" }
    s += "##INFO=<ID=END,Number=1,Type=Integer,Description=\"End\">\n##INFO=<ID=SVLEN,Number=A,Type=Integer,Description=\"SV length\">\n"
    s += "##INFO=<ID=DP,Number=1,Type=Integer,Description=\"Depth\">\n##ALT=<ID=DEL,Description=\"Deletion\">\n##ALT=<ID=DUP,Description=\"Duplication\">\n"
    s += "##FORMAT=<ID=GT,Number=1,Type=String,Description=\"Genotype\">\n##FORMAT=<ID=LEN,Number=1,Type=Integer,Description=\"Block length\">\n"
    s += "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tS1\n"
    for c in contigs {
        var pos = 1
        for i in 0..<perContig {
            pos += 1 + (i * 7919) % 700
            switch i % 10 {
            case 3: s += "\(c)\t\(pos)\t.\tACGTACGT\tA\t50\tPASS\tDP=3\tGT\t0/1\n"
            case 5: s += "\(c)\t\(pos)\t.\tN\t<DEL>\t50\tPASS\tSVLEN=-\(20_000 + i);END=\(pos + 20_000 + i)\tGT\t0/1\n"
            case 7: s += "\(c)\t\(pos)\t.\tA\t<*>\t.\t.\t.\tGT:LEN\t0/0:\(100 + i % 50)\n"
            case 8: s += "\(c)\t\(pos)\t.\tC\t<DUP>\t50\tPASS\tSVLEN=\(70_000 + i)\tGT\t0/1\n"
            default: s += "\(c)\t\(pos)\trs\(i)\t\(["A", "C", "G", "T"][i % 4])\t\(["C", "G", "T", "A"][i % 4])\t\(30 + i % 60)\tPASS\tDP=\(5 + i % 200)\tGT\t0/1\n"
            }
        }
    }
    return s
}

func sampleBED() -> String {
    var s = "track name=test\n#chrom\tstart\tend\n"
    for c in ["chr1", "chr2"] {
        var p = 0
        for i in 0..<8000 { p += 50 + i % 300; s += "\(c)\t\(p)\t\(p + 10 + (i * 31) % 5000)\tf\(i)\n" }
    }
    return s
}

func sampleGFF() -> String {
    var s = "##gff-version 3\n"
    var p = 1
    for i in 0..<8000 { p += 40 + i % 200; s += "chr7\tsrc\texon\t\(p)\t\(p + (i * 13) % 3000)\t.\t+\t.\tID=e\(i)\n" }
    return s
}

@Suite("Genomics 2: tabix/CSI, index checks, CRAM, manifests")
struct Genomics2Tests {
    func compress(_ t: TempDir, _ name: String, _ text: String) throws -> URL {
        t.write(name, text)
        var o = CreateOptions()
        o.format = .bgzf
        let out = t.url(name + ".gz")
        try Xipper.create(from: [t.url(name)], to: out, options: o)
        return out
    }

    /// Random region queries must return identical lines with our index and with htslib's.
    func compareQueries(_ tabix: String, ours: URL, theirs: URL, contigs: [String], span: Int, count: Int = 120) {
        var rng = SystemRandomNumberGenerator()
        var regions = contigs + ["chrNope:1-100"]
        for _ in 0..<count {
            let c = contigs.randomElement(using: &rng)!
            let a = Int.random(in: 1...span, using: &rng)
            regions.append("\(c):\(a)-\(a + Int.random(in: 0...200_000, using: &rng))")
        }
        regions.append("\(contigs[0]):1-1")
        var lines = 0
        defer { #expect(lines > 1000, "queries returned almost nothing") }
        for r in regions {
            let x = run(tabix, [ours.path, r]), y = run(tabix, [theirs.path, r])
            #expect(x.status == y.status, "\(r): \(x.output) vs \(y.output)")
            #expect(x.output == y.output, "region \(r) differs")
            lines += x.output.split(separator: "\n").count
        }
    }

    @Test(arguments: [false, true])
    func tabixVCFMatchesHtslib(csi: Bool) throws {
        guard let tabix = htsTabix, let bgzip = htsBgzip else { return }
        let t = TempDir()
        let vcf = richVCF()
        // Our BGZF + our index vs htslib's BGZF + htslib's index (different block layouts).
        let ours = try compress(t, "a.vcf", vcf)
        let r = try Xipper.tabixIndex(ours, csi: csi)
        #expect(r.sequences == ["chr1", "chr2", "chrX"])
        #expect(r.records == 18000)
        t.mkdir("ref")
        t.write("ref/a.vcf", vcf)
        #expect(run(bgzip, ["-f", t.path + "/ref/a.vcf"]).status == 0)
        let theirs = t.url("ref/a.vcf.gz")
        #expect(run(tabix, csi ? ["-C", "-p", "vcf", theirs.path] : ["-p", "vcf", theirs.path]).status == 0)
        #expect(run(tabix, ["-l", ours.path]).output == "chr1\nchr2\nchrX\n")
        compareQueries(tabix, ours: ours, theirs: theirs, contigs: ["chr1", "chr2", "chrX"], span: 2_200_000)
        // Our index over htslib's own BGZF file: same answers.
        let copy = t.url("ref2.vcf.gz")
        try FileManager.default.copyItem(at: theirs, to: copy)
        try Xipper.tabixIndex(copy, csi: csi)
        compareQueries(tabix, ours: copy, theirs: theirs, contigs: ["chr1", "chr2", "chrX"], span: 2_200_000, count: 40)
        if let bcftools = htsBcftools {
            let v = run(bcftools, ["view", "-H", "-r", "chr2:100000-900000", ours.path])
            #expect(v.status == 0 && v.output.split(separator: "\n").count > 100, "\(v.output.prefix(300))")
        }
    }

    @Test func tabixBEDAndGFFMatchHtslib() throws {
        guard let tabix = htsTabix, let bgzip = htsBgzip else { return }
        let t = TempDir()
        for (name, text, preset, contigs) in [("b.bed", sampleBED(), "bed", ["chr1", "chr2"]), ("g.gff3", sampleGFF(), "gff", ["chr7"])] {
            let ours = try compress(t, name, text)
            try Xipper.tabixIndex(ours)
            t.mkdir("ref-\(name)")
            // htslib rejects the UCSC track line, so its reference copy drops it.
            t.write("ref-\(name)/\(name)", text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("track") }.joined(separator: "\n"))
            #expect(run(bgzip, ["-f", t.path + "/ref-\(name)/\(name)"]).status == 0)
            let theirs = t.url("ref-\(name)/\(name).gz")
            let ti = run(tabix, ["-p", preset, theirs.path])
            #expect(ti.status == 0, "\(ti.output)")
            compareQueries(tabix, ours: ours, theirs: theirs, contigs: contigs, span: 1_500_000)
        }
    }

    /// Lines longer than a BGZF block (and spanning three of them) and a final line without newline.
    @Test func tabixLongLinesAcrossBlocks() throws {
        guard let tabix = htsTabix else { return }
        let t = TempDir()
        var s = "##fileformat=VCFv4.2\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n"
        for i in 0..<400 {
            let info = i % 50 == 7 ? "X=" + String(repeating: "a", count: 150_000) : "DP=\(i)"
            s += "chr1\t\(1000 + i * 977)\t.\tA\tC\t.\t.\t\(info)\n"
        }
        s += "chr2\t5\t.\tA\tC\t.\t.\tEND=90000"
        let v = try compress(t, "l.vcf", s)
        let r = try Xipper.tabixIndex(v)
        #expect(r.records == 401)
        #expect(try Xipper.checkIndex(r.index).isOK)
        for (region, n) in [("chr1:1000-1000", 1), ("chr1:7000-60000", 54), ("chr1", 400), ("chr2:80000-80001", 1)] {
            #expect(run(tabix, [v.path, region]).output.split(separator: "\n").count == n, "\(region)")
        }
        try FileManager.default.copyItem(atPath: v.path, toPath: t.path + "/h.vcf.gz")
        #expect(run(tabix, ["-p", "vcf", t.path + "/h.vcf.gz"]).status == 0)
        compareQueries(tabix, ours: v, theirs: t.url("h.vcf.gz"), contigs: ["chr1", "chr2"], span: 400_000, count: 60)
        // Skipped first lines (-S) are not indexed even when unparseable.
        let sk = try compress(t, "k.bed", "garbage line\nmore garbage\nchr1\t10\t20\n")
        var c = TabixConfig(preset: .bed)
        c.skipLines = 2
        #expect(try Xipper.tabixIndex(sk, config: c).records == 1)
        do { try Xipper.tabixIndex(sk); Issue.record("parsed garbage") } catch { #expect("\(error)".contains("line 1 cannot be parsed")) }
    }

    @Test func tabixClearErrors() throws {
        let t = TempDir()
        // Plain gzip.
        t.write("p.vcf", sampleVCF(records: 100))
        _ = run("/usr/bin/gzip", ["-k", t.path + "/p.vcf"])
        #expect(throws: XipperError.self) { try Xipper.tabixIndex(t.url("p.vcf.gz")) }
        do { try Xipper.tabixIndex(t.url("p.vcf.gz")) } catch { #expect("\(error)".contains("bgzf_convert")) }
        // Not compressed.
        do { try Xipper.tabixIndex(t.url("p.vcf")) } catch { #expect("\(error)".contains("bgzf_compress")) }
        // Unsorted positions and split contigs.
        let unsorted = try compress(t, "u.vcf", "##fileformat=VCFv4.2\n#CHROM\tPOS\tID\tREF\tALT\n1\t200\t.\tA\tC\n1\t100\t.\tA\tC\n")
        do { try Xipper.tabixIndex(unsorted); Issue.record("accepted unsorted") } catch { #expect("\(error)".contains("not sorted: line 4")) }
        let split = try compress(t, "s.vcf", "#h\n1\t1\t.\tA\tC\n2\t1\t.\tA\tC\n1\t5\t.\tA\tC\n")
        do { try Xipper.tabixIndex(split); Issue.record("accepted split contigs") } catch { #expect("\(error)".contains("appears again")) }
        // Unknown preset from name.
        let other = try compress(t, "x.txt", "a\t1\n")
        #expect(throws: XipperError.self) { try Xipper.tabixIndex(other) }
        // Positions beyond the .tbi limit need CSI.
        let big = try compress(t, "big.bed", "chr1\t10\t20\nchr1\t600000000\t600000010\n")
        do { try Xipper.tabixIndex(big); Issue.record("tbi beyond 2^29") } catch { #expect("\(error)".contains("CSI")) }
        #expect(try Xipper.tabixIndex(big, csi: true).records == 2)
        if let tabix = htsTabix {
            #expect(run(tabix, [big.path, "chr1:599999990-600000005"]).output == "chr1\t600000000\t600000010\n")
        }
        // Truncated BGZF (no EOF marker).
        let ok = try compress(t, "tr.vcf", sampleVCF(records: 3000))
        let data = try Data(contentsOf: ok)
        try data.prefix(data.count - 28).write(to: ok)
        do { try Xipper.tabixIndex(ok); Issue.record("indexed truncated file") } catch { #expect("\(error)".contains("truncated")) }
    }

    // MARK: index checks

    func samText(reads: Int = 20_000) -> String {
        var s = "@HD\tVN:1.6\tSO:coordinate\n@SQ\tSN:chr1\tLN:5000000\n@SQ\tSN:chr2\tLN:5000000\n"
        let seq = String(repeating: "ACGTTGCA", count: 6)
        let qual = String(repeating: "I", count: 48)
        for c in ["chr1", "chr2"] {
            var pos = 1
            for i in 0..<reads / 2 {
                pos += i % 37
                s += "r\(c)_\(i)\t0\t\(c)\t\(pos)\t60\t48M\t*\t0\t0\t\(seq)\t\(qual)\n"
            }
        }
        return s
    }

    @Test func indexCheckAcceptsHtslibIndexes() throws {
        guard let samtools = htsSamtools, let tabix = htsTabix, let bgzip = htsBgzip else { return }
        let t = TempDir()
        // VCF.gz with tabix .tbi, CSI and .gzi from htslib, plus ours.
        t.write("v.vcf", richVCF(perContig: 3000))
        #expect(run(bgzip, ["-i", t.path + "/v.vcf"]).status == 0)
        let vcf = t.url("v.vcf.gz")
        #expect(run(tabix, ["-p", "vcf", vcf.path]).status == 0)
        #expect(run(tabix, ["-C", "-p", "vcf", vcf.path]).status == 0)
        for ext in ["tbi", "csi", "gzi"] {
            let r = try Xipper.checkIndex(URL(fileURLWithPath: vcf.path + "." + ext))
            #expect(r.isOK, "\(ext): \(r.problems)")
            #expect(r.offsetsChecked > 0)
        }
        // BAM with .bai and .csi, CRAM with .crai.
        t.write("a.sam", samText())
        #expect(run(samtools, ["view", "-b", "-o", t.path + "/a.bam", t.path + "/a.sam"]).status == 0)
        #expect(run(samtools, ["index", t.path + "/a.bam"]).status == 0)
        #expect(run(samtools, ["index", "-c", "-o", t.path + "/a.bam.csi", t.path + "/a.bam"]).status == 0)
        let bam = t.url("a.bam")
        let g = try Xipper.genomicsCheck(bam)
        #expect(g.kind == .bam && g.isOK, "\(g.problems) \(g.indexes.map(\.problems))")
        #expect(g.detail.contains("2 reference"))
        #expect(Set(g.indexes.map(\.kind)) == [.bai, .csi])
        #expect(g.indexes.allSatisfy { $0.references == 2 })
        let cramOut = run(samtools, ["view", "-C", "--output-fmt-option", "no_ref=1", "--output-fmt-option", "version=3.1",
                                     "-o", t.path + "/a.cram", bam.path])
        #expect(cramOut.status == 0, "\(cramOut.output)")
        #expect(run(samtools, ["index", t.path + "/a.cram"]).status == 0)
        let c = try Xipper.genomicsCheck(t.url("a.cram"))
        #expect(c.kind == .cram && c.isOK, "\(c.problems) \(c.indexes.map(\.problems))")
        #expect(c.cram?.version == "3.1")
        #expect(c.cram?.records == 20_000)
        #expect(c.indexes.first?.kind == .crai && c.indexes.first?.isOK == true)
    }

    @Test func indexCheckDetectsMismatches() throws {
        let t = TempDir()
        let vcf = try compress(t, "v.vcf", richVCF(perContig: 3000))
        let tbi = try Xipper.tabixIndex(vcf).index
        #expect(try Xipper.checkIndex(tbi).isOK)
        // 1. Stale: the data file was recompressed (bgzf_convert reblocks it) after indexing.
        _ = try Xipper.convert(vcf, to: t.url("re.vcf.gz"), format: .bgzf, level: 1)
        let stale = try Xipper.checkIndex(tbi, data: t.url("re.vcf.gz"))
        #expect(!stale.isOK)
        #expect(stale.problems.contains { $0.contains("bad virtual offset") })
        #expect(stale.warnings.contains { $0.contains("older than the data") })
        // 2. Hand-corrupted offsets.
        var idx = try BinningIndex.parse(Array(try Data(contentsOf: tbi)))
        idx.references[0].bins[0].chunks[0].begin += 3 << 16
        idx.references[1].linear[0] = UInt64(1 << 40) << 16
        try Data(Xipper.compressBGZFBlocks(idx.serialize())).write(to: tbi)
        let bad = try Xipper.checkIndex(tbi)
        #expect(bad.problems.count >= 2, "\(bad.problems)")
        #expect(bad.problems.contains { $0.contains("past the end") })
        // 3. Truncated data file.
        let ok = try Xipper.tabixIndex(vcf).index
        let d = try Data(contentsOf: vcf)
        try d.prefix(d.count / 2).write(to: vcf)
        #expect(try !Xipper.checkIndex(ok).isOK)
        // 4. .gzi of another file.
        let other = try compress(t, "o.vcf", richVCF(perContig: 1000))
        try Xipper.writeBGZFIndex(for: other, to: t.url("o.gzi"))
        let g = try Xipper.checkIndex(t.url("o.gzi"), data: t.url("re.vcf.gz"))
        #expect(!g.isOK)
        // Not an index.
        t.write("junk.tbi", sampleData(5000))
        #expect(throws: XipperError.self) { try Xipper.checkIndex(t.url("junk.tbi"), data: t.url("re.vcf.gz")) }
    }

    // MARK: CRAM / VCF / BCF

    @Test func cramCorruptionAndTruncation() throws {
        guard let samtools = htsSamtools else { return }
        let t = TempDir()
        t.write("a.sam", samText(reads: 30_000))
        for version in ["3.0", "3.1"] {
            let cram = t.path + "/a\(version).cram"
            let r = run(samtools, ["view", "-C", "--output-fmt-option", "no_ref=1", "--output-fmt-option", "version=\(version)",
                                   "-o", cram, t.path + "/a.sam"])
            #expect(r.status == 0, "\(r.output)")
            let good = try Xipper.checkCRAM(URL(fileURLWithPath: cram))
            #expect(good.isOK && good.hasEOFContainer && good.version == version, "\(good.problems)")
            #expect(good.containers >= 3 && good.records == 30_000)
            let data = try Data(contentsOf: URL(fileURLWithPath: cram))
            // Truncated: EOF container lost.
            try data.prefix(data.count - 38).write(to: t.url("trunc.cram"))
            let tr = try Xipper.checkCRAM(t.url("trunc.cram"))
            #expect(!tr.isOK && !tr.hasEOFContainer && tr.problems.joined().contains("EOF container missing"))
            try data.prefix(data.count / 2).write(to: t.url("half.cram"))
            #expect(try !Xipper.checkCRAM(t.url("half.cram")).isOK)
            // One flipped bit in the middle: a block CRC fails.
            var bytes = [UInt8](data)
            bytes[bytes.count / 2] ^= 0x10
            try Data(bytes).write(to: t.url("flip.cram"))
            let f = try Xipper.genomicsCheck(t.url("flip.cram"))
            #expect(!f.isOK && f.problems.joined().contains("CRC32 mismatch"), "\(f.problems)")
        }
        t.write("x.cram", "CRAM")
        #expect(throws: XipperError.self) { try Xipper.checkCRAM(t.url("x.cram")) }
    }

    @Test func vcfAndBCFChecks() throws {
        let t = TempDir()
        let vcf = try compress(t, "v.vcf", richVCF(perContig: 2000))
        let ok = try Xipper.genomicsCheck(vcf)
        #expect(ok.kind == .vcf && ok.isOK && ok.detail.hasPrefix("VCFv4.3") && ok.detail.contains("1 samples"), "\(ok.problems)")
        // Missing ##fileformat.
        let bad = try compress(t, "bad.vcf", "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\nchr1\t1\t.\tA\tC\t.\t.\t.\n")
        let b = try Xipper.genomicsCheck(bad)
        #expect(!b.isOK && b.problems.contains { $0.contains("##fileformat") })
        // Plain gzip and uncompressed.
        t.write("p.vcf", sampleVCF(records: 50))
        _ = run("/usr/bin/gzip", ["-k", t.path + "/p.vcf"])
        let gz = try Xipper.genomicsCheck(t.url("p.vcf.gz"))
        #expect(gz.kind == .gzip && gz.problems.joined().contains("bgzf_convert"))
        #expect(try Xipper.genomicsCheck(t.url("p.vcf")).problems.joined().contains("bgzf_compress"))
        // Truncated VCF.gz: EOF marker missing.
        let d = try Data(contentsOf: vcf)
        try d.prefix(d.count - 28).write(to: t.url("tr.vcf.gz"))
        #expect(try Xipper.genomicsCheck(t.url("tr.vcf.gz")).problems.joined().contains("truncated"))
        // BCF from bcftools, with its CSI index.
        guard let bcftools = htsBcftools else { return }
        let conv = run(bcftools, ["view", "-Ob", "-o", t.path + "/v.bcf", vcf.path])
        #expect(conv.status == 0, "\(conv.output)")
        #expect(run(bcftools, ["index", t.path + "/v.bcf"]).status == 0)
        let bcf = try Xipper.genomicsCheck(t.url("v.bcf"))
        #expect(bcf.kind == .bcf && bcf.isOK && bcf.detail.hasPrefix("BCF 2.2"), "\(bcf.problems) \(bcf.indexes.map(\.problems))")
        #expect(bcf.indexes.map(\.kind) == [.csi])
        let bd = try Data(contentsOf: t.url("v.bcf"))
        var flipped = [UInt8](bd)
        flipped[flipped.count / 2] ^= 0xFF
        try Data(flipped).write(to: t.url("f.bcf"))
        #expect(try !Xipper.genomicsCheck(t.url("f.bcf")).isOK)
    }

    // MARK: checksums

    @Test func crc32cVectors() throws {
        func reference(_ d: [UInt8]) -> UInt32 {
            var c: UInt32 = ~0
            for b in d { c ^= UInt32(b); for _ in 0..<8 { c = c & 1 != 0 ? (c >> 1) ^ 0x82F63B78 : c >> 1 } }
            return ~c
        }
        let t = TempDir()
        t.write("v.txt", "123456789")
        #expect(try Xipper.checksum(t.url("v.txt"), algorithm: .crc32c) == "e3069283")
        for n in [0, 1, 7, 24_575, 24_576, 24_577, 100_003, 1 << 20] {
            let d = sampleData(n, seed: UInt64(n) + 9)
            t.write("d\(n)", d)
            #expect(try Xipper.checksum(t.url("d\(n)"), algorithm: .crc32c) == String(format: "%08x", reference(d)), "n=\(n)")
        }
        #expect(try Xipper.checksum(t.url("v.txt"), algorithm: .sha256) == "15e2b0d3c33891ebb0f1ef609ec419420c20e320ce94c65fbc8c3312448eb225")
        #expect(try Xipper.checksum(t.url("v.txt"), algorithm: .md5) == "25f9e794323b453885f5181f1b624d0b")
        #expect(ChecksumAlgorithm(name: "sha256") == .sha256 && ChecksumAlgorithm(name: "SHA-256") == .sha256)
        #expect(ChecksumAlgorithm(name: "CRC32C") == .crc32c && ChecksumAlgorithm(name: "etag") == nil)
    }

    @Test func manifestsRoundTripAndInterop() throws {
        let t = TempDir()
        makeTree(t, root: "data", bigSize: 3 << 20)
        t.write("data/sub/name with\\backslash.txt", "x")
        let src = [t.url("data")]
        // .sha256 compatible with `shasum -a 256 -c`.
        let sha = try Xipper.createManifest(of: src, to: t.url("data.sha256"))
        #expect(sha.algorithms == [.sha256] && sha.entries.count >= 6)
        let plain = sha.entries.filter { !$0.path.contains("\\") }.map { ManifestCodec.textLine($0.checksums[.sha256]!, $0.path) }.joined()
        t.write("plain.sha256", plain)
        let c = run("/usr/bin/shasum", ["-a", "256", "-c", "plain.sha256"], cwd: t.path)
        #expect(c.status == 0, "\(c.output)")
        #expect(try Xipper.verifyManifest(sha.manifest).isOK)
        // md5sum format, and a BSD-style file produced by `shasum --tag`-like output.
        let md5 = try Xipper.createManifest(of: src, to: t.url("md5sum.txt"))
        #expect(md5.algorithms == [.md5])
        #expect(try Xipper.verifyManifest(md5.manifest).isOK)
        let bsd = run("/bin/sh", ["-c", "cd '\(t.path)' && /sbin/md5 data/readme.txt"])
        t.write("bsd.txt", bsd.output)
        #expect(try Xipper.verifyManifest(t.url("bsd.txt")).isOK)
        // JSON with DRS fields and every default algorithm.
        let js = try Xipper.createManifest(of: src, to: t.url("manifest.json"), algorithms: [.sha256, .md5, .crc32c, .sha512t24u])
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: js.manifest)) as! [String: Any]
        let first = (doc["objects"] as! [[String: Any]]).first!
        #expect(Set(first.keys).isSuperset(of: ["id", "name", "size", "checksums", "created_time", "updated_time"]))
        #expect(((first["checksums"] as! [[String: String]]).map { $0["type"]! }) == ["sha-256", "md5", "crc32c", "sha512t24u"])
        #expect(try Xipper.verifyManifest(js.manifest).isOK)
        #expect(throws: XipperError.self) { try Xipper.createManifest(of: src, to: t.url("manifest.json")) }  // exists
        // Tampering, deletion, escaping paths, legacy type names.
        t.write("data/readme.txt", "hello xippeR\n")
        try FileManager.default.removeItem(atPath: t.path + "/data/data/small.bin")
        let v = try Xipper.verifyManifest(js.manifest)
        #expect(!v.isOK)
        #expect(Set(v.mismatches.map(\.path)) == ["data/readme.txt"] && v.mismatches.count == 4)
        #expect(v.missing == ["data/data/small.bin"])
        t.write("evil.json", #"{"objects":[{"path":"../../etc/hosts","checksums":[{"type":"sha256","checksum":"00"}]},{"path":"data/script.sh","size":18,"checksums":[{"type":"SHA256","checksum":"\#(try Xipper.checksum(t.url("data/script.sh"), algorithm: .sha256))"},{"type":"etag","checksum":"x"}]}]}"#)
        let e = try Xipper.verifyManifest(t.url("evil.json"))
        #expect(e.refused == ["../../etc/hosts"] && e.checked == 1 && e.mismatches.isEmpty && e.skippedTypes == ["etag"])
        // Sources outside the manifest folder are refused.
        t.write("elsewhere/f.txt", "f")
        #expect(throws: XipperError.self) { try Xipper.createManifest(of: [t.url("elsewhere/f.txt")], to: t.url("data/m.sha256")) }
    }
}

