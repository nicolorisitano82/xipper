import Foundation
import Testing
@testable import XipperKit

/// `Xipper.buildIndex`: .bai/.csi (BAM), .crai, .csi (BCF), .fai, tabix SAM, against htslib when installed.
@Suite("Genomics indexes")
struct GenomicsIndexTests {
    static let samtools = CRAMTests.samtools
    static let bcftools = ["/opt/homebrew/bin/bcftools", "/usr/local/bin/bcftools"].first(where: toolExists)

    @Test func faiMatchesSamtoolsFormat() throws {
        let t = TempDir()
        t.write("r.fa", ">a desc\nACGTACGTAC\nACGTACGTAC\nACG\n>b\nTTTT\n")
        t.write("r.fq", "@q1 x\nACGT\n+\nIIII\n@q2\nAC\n+\n##\n")
        try Xipper.buildIndex(t.url("r.fa"))
        try Xipper.buildIndex(t.url("r.fq"))
        #expect(try String(contentsOf: t.url("r.fa.fai"), encoding: .utf8) == "a\t23\t8\t10\t11\nb\t4\t37\t4\t5\n")
        #expect(try String(contentsOf: t.url("r.fq.fai"), encoding: .utf8) == "q1\t4\t6\t4\t5\t13\nq2\t2\t22\t2\t3\t27\n")
        t.write("bad.fa", ">a\nACG\nACGTT\n")
        #expect(throws: XipperError.self) { try Xipper.buildIndex(t.url("bad.fa")) }
    }

    @Test func bamAndCramIndexesAreValid() throws {
        let t = TempDir()
        let (bam, ref, _) = try CRAMTests().dataset(t)
        for csi in [false, true] {
            let r = try Xipper.buildIndex(bam, csi: csi)
            #expect(r.kind == (csi ? "csi" : "bai"))
            #expect(try Xipper.checkIndex(r.index).isOK)
        }
        try Xipper.bamToCRAM(bam, output: t.url("x.cram"), reference: ref)
        let c = try Xipper.buildIndex(t.url("x.cram"))
        #expect(try c.kind == "crai" && Xipper.checkIndex(c.index).isOK)
        guard let samtools = Self.samtools else { return }
        // Same idxstats and the same records for many regions as with samtools' own indexes.
        try FileManager.default.createDirectory(atPath: t.path + "/h", withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bam, to: t.url("h/in.bam"))
        try FileManager.default.copyItem(at: t.url("x.cram"), to: t.url("h/x.cram"))
        #expect(run(samtools, ["index", t.path + "/h/in.bam"]).status == 0)
        #expect(run(samtools, ["index", t.path + "/h/x.cram"]).status == 0)
        #expect(run(samtools, ["idxstats", bam.path]).output == run(samtools, ["idxstats", t.path + "/h/in.bam"]).output)
        #expect(run("/usr/bin/gunzip", ["-c", c.index.path]).output == run("/usr/bin/gunzip", ["-c", t.path + "/h/x.cram.crai"]).output)
        var rng = SplitMix(9)
        for _ in 0..<40 {
            let chr = rng.int(4) == 0 ? "chr2" : "chr1"
            let a = 1 + rng.int(chr == "chr1" ? 29000 : 8000), reg = "\(chr):\(a)-\(a + [1, 100, 3000][rng.int(3)])"
            #expect(run(samtools, ["view", "-X", bam.path, bam.path + ".bai", reg]).output == run(samtools, ["view", t.path + "/h/in.bam", reg]).output, "\(reg)")
            #expect(run(samtools, ["view", "-X", bam.path, bam.path + ".csi", reg]).output == run(samtools, ["view", t.path + "/h/in.bam", reg]).output, "\(reg)")
            #expect(run(samtools, ["view", "-T", ref.path, t.path + "/x.cram", reg]).output == run(samtools, ["view", "-T", ref.path, t.path + "/h/x.cram", reg]).output)
        }
    }

    @Test(.enabled(if: bcftools != nil)) func bcfIndexMatchesBcftools() throws {
        let t = TempDir()
        var vcf = "##fileformat=VCFv4.2\n##contig=<ID=c1,length=900000>\n##contig=<ID=c2,length=70000>\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n"
        var rng = SplitMix(4)
        for (c, n) in [("c1", 900_000), ("c2", 70000)] {
            var p = 1
            while p < n - 1000 { p += 1 + rng.int(400); vcf += "\(c)\t\(p)\t.\t\(String(repeating: "A", count: 1 + rng.int(30)))\tG\t50\tPASS\t.\n" }
        }
        t.write("v.vcf", vcf)
        #expect(run(Self.bcftools!, ["view", "-O", "b", "-o", t.path + "/v.bcf", t.path + "/v.vcf"]).status == 0)
        try FileManager.default.createDirectory(atPath: t.path + "/h", withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: t.url("v.bcf"), to: t.url("h/v.bcf"))
        #expect(run(Self.bcftools!, ["index", "-c", t.path + "/h/v.bcf"]).status == 0)
        let r = try Xipper.buildIndex(t.url("v.bcf"))
        #expect(try r.kind == "csi" && Xipper.checkIndex(r.index).isOK)
        for _ in 0..<40 {
            let c = rng.int(3) == 0 ? "c2" : "c1", a = 1 + rng.int(c == "c1" ? 890_000 : 60000), reg = "\(c):\(a)-\(a + rng.int(20000))"
            #expect(run(Self.bcftools!, ["view", "-H", t.path + "/v.bcf", "-r", reg]).output == run(Self.bcftools!, ["view", "-H", t.path + "/h/v.bcf", "-r", reg]).output, "\(reg)")
        }
    }
}
