import Foundation
import Testing
@testable import XipperKit

let htsBgzip = ["/opt/homebrew/bin/bgzip", "/usr/local/bin/bgzip"].first(where: toolExists)
let htsTabix = ["/opt/homebrew/bin/tabix", "/usr/local/bin/tabix"].first(where: toolExists)
let htsSamtools = ["/opt/homebrew/bin/samtools", "/usr/local/bin/samtools"].first(where: toolExists)

/// Small coordinate-sorted VCF (tabix needs sorted input).
func sampleVCF(records: Int = 20_000) -> String {
    var s = "##fileformat=VCFv4.2\n##contig=<ID=chr1,length=248956422>\n##INFO=<ID=DP,Number=1,Type=Integer,Description=\"Depth\">\n"
    s += "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n"
    var pos = 1
    for i in 0..<records {
        pos += 1 + (i * 7919) % 1500
        s += "chr1\t\(pos)\trs\(i)\t\(["A", "C", "G", "T"][i % 4])\t\(["C", "G", "T", "A"][i % 4])\t\(30 + i % 60)\tPASS\tDP=\(5 + i % 200)\n"
    }
    return s
}

@Suite("BGZF / genomics")
struct GenomicsTests {
    func bgzf(_ t: TempDir, _ name: String, level: Int? = nil, index: Bool = false) throws -> URL {
        var o = CreateOptions()
        o.format = .bgzf
        o.level = level
        o.writeBGZFIndex = index
        let out = t.url(name + ".gz")
        try Xipper.create(from: [t.url(name)], to: out, options: o)
        return out
    }

    @Test(arguments: [0, 1, BGZF.blockInput, BGZF.blockInput + 1, 3 << 20])
    func blockStructureAndRoundTrip(size: Int) throws {
        let t = TempDir()
        let data = sampleData(size, seed: UInt64(size) + 1)
        t.write("d.bin", data)
        let gz = try bgzf(t, "d.bin")
        #expect(try ArchiveFormat.detect(gz) == .bgzf)
        let bytes = try Data(contentsOf: gz)
        #expect(Array(bytes.suffix(28)) == BGZF.eofMarker)
        let layout = try BGZFLayout.scan(FileReader(path: gz.path))
        #expect(layout.endsWithEOFMarker)
        #expect(layout.uncompressedSize == UInt64(size))
        #expect(layout.blocks == (size + BGZF.blockInput - 1) / BGZF.blockInput + 1)
        // Every block ≤ 64 KiB (BSIZE is a uint16 of size − 1).
        let out = try Xipper.decompressSingle(gz, to: t.url("back.bin"))
        #expect(FileManager.default.contents(atPath: out.path) == Data(data))
        // Any gunzip reads BGZF (concatenated members).
        let g = run("/bin/sh", ["-c", "/usr/bin/gzip -dc '\(gz.path)' | /usr/bin/cmp - '\(t.path)/d.bin'"])
        #expect(g.status == 0, "\(g.output)")
        #expect(try Xipper.test(gz).isOK)
    }

    @Test func incompressibleBlocksStayWithin64KiB() throws {
        let t = TempDir()
        var rnd = [UInt8](repeating: 0, count: 1 << 20)
        arc4random_buf(&rnd, rnd.count)
        t.write("r.bin", rnd)
        let gz = try bgzf(t, "r.bin", level: 9)
        #expect(try Xipper.test(gz).isOK)
        let info = try Xipper.bgzfInfo(gz)
        #expect(info.blocks == 18)  // 17 data blocks + EOF
    }

    @Test func htslibInterop() throws {
        guard let bgzip = htsBgzip, let tabix = htsTabix else { return }
        let t = TempDir()
        t.write("v.vcf", sampleVCF())
        let ours = try bgzf(t, "v.vcf", index: true)
        #expect(run(bgzip, ["-t", ours.path]).status == 0)
        let tbx = run(tabix, ["-p", "vcf", ours.path])
        #expect(tbx.status == 0, "\(tbx.output)")
        #expect(run(tabix, [ours.path, "chr1:100000-200000"]).output.split(separator: "\n").count > 10)
        // .gzi identical to htslib's.
        try FileManager.default.copyItem(atPath: ours.path + ".gzi", toPath: t.path + "/ours.gzi")
        #expect(run(bgzip, ["-r", ours.path]).status == 0)
        #expect(FileManager.default.contents(atPath: t.path + "/ours.gzi") == FileManager.default.contents(atPath: ours.path + ".gzi"))
        // We read htslib's output and verify it.
        _ = run("/bin/sh", ["-c", "'\(bgzip)' -c '\(t.path)/v.vcf' > '\(t.path)/ref.vcf.gz'"])
        let ref = t.url("ref.vcf.gz")
        #expect(try ArchiveFormat.detect(ref) == .bgzf)
        #expect(try Xipper.test(ref).isOK)
        let back = try Xipper.decompressSingle(ref, to: t.url("ref.vcf"))
        #expect(FileManager.default.contents(atPath: back.path) == FileManager.default.contents(atPath: t.path + "/v.vcf"))
    }

    @Test func levelsMatchBgzip() throws {
        guard let bgzip = htsBgzip else { return }
        let t = TempDir()
        t.write("v.vcf", sampleVCF(records: 60_000))
        for level in [1, 6, 9] {
            let ours = try bgzf(t, "v.vcf", level: level)
            let size = (try FileManager.default.attributesOfItem(atPath: ours.path)[.size] as! NSNumber).doubleValue
            _ = run("/bin/sh", ["-c", "'\(bgzip)' -l \(level) -c '\(t.path)/v.vcf' > '\(t.path)/h.gz'"])
            let ref = (try FileManager.default.attributesOfItem(atPath: t.path + "/h.gz")[.size] as! NSNumber).doubleValue
            #expect(abs(size - ref) / ref < 0.01, "level \(level): \(size) vs \(ref)")
            try FileManager.default.removeItem(at: ours)
        }
    }

    @Test func genomicsPreferenceUsesBGZFForGzip() throws {
        let t = TempDir()
        t.write("calls.vcf", sampleVCF(records: 2000))
        t.write("notes.txt", "plain text\n")
        var o = CreateOptions()
        o.format = .gzip
        try Xipper.create(from: [t.url("calls.vcf")], to: t.url("calls.vcf.gz"), options: o)
        try Xipper.create(from: [t.url("notes.txt")], to: t.url("notes.txt.gz"), options: o)
        #expect(try ArchiveFormat.detect(t.url("calls.vcf.gz")) == .bgzf)
        #expect(try ArchiveFormat.detect(t.url("notes.txt.gz")) == .gzip)
        o.genomicsUsesBGZF = false
        try Xipper.create(from: [t.url("calls.vcf")], to: t.url("plain.vcf.gz"), options: o)
        #expect(try ArchiveFormat.detect(t.url("plain.vcf.gz")) == .gzip)
    }

    @Test func convertPlainGzipInPlace() throws {
        let t = TempDir()
        t.write("v.vcf", sampleVCF(records: 5000))
        _ = run("/bin/sh", ["-c", "/usr/bin/gzip -c '\(t.path)/v.vcf' > '\(t.path)/v.vcf.gz'"])
        t.write("v.vcf.gz.tbi", [1, 2, 3])
        let gz = t.url("v.vcf.gz")
        #expect(try ArchiveFormat.detect(gz) == .gzip)
        let r = try Xipper.convert(gz)
        #expect(try ArchiveFormat.detect(gz) == .bgzf)
        #expect(r.staleIndexes.map(\.lastPathComponent) == ["v.vcf.gz.tbi"])
        let back = try Xipper.decompressSingle(gz, to: t.url("back.vcf"))
        #expect(FileManager.default.contents(atPath: back.path) == FileManager.default.contents(atPath: t.path + "/v.vcf"))
        // And back to plain gzip.
        try Xipper.convert(gz, to: t.url("plain.gz"), format: .gzip)
        #expect(try ArchiveFormat.detect(t.url("plain.gz")) == .gzip)
    }

    @Test func truncationAndCorruptionAreDetected() throws {
        let t = TempDir()
        t.write("d.bin", sampleData(400_000))
        let gz = try bgzf(t, "d.bin")
        let full = try Data(contentsOf: gz)
        // Missing EOF marker: data intact but the file was cut at a block boundary.
        try full.dropLast(28).write(to: t.url("noeof.gz"))
        let noEOF = try Xipper.test(t.url("noeof.gz"))
        #expect(!noEOF.isOK && noEOF.failures[0].reason.contains("end-of-file marker"))
        #expect(!(try Xipper.bgzfInfo(t.url("noeof.gz")).endsWithEOFMarker))
        // Cut inside a block.
        try full.prefix(full.count / 2).write(to: t.url("cut.gz"))
        #expect(!(try Xipper.test(t.url("cut.gz")).isOK))
        // Flipped byte in the middle.
        var bad = full
        bad[full.count / 2] ^= 0xFF
        try bad.write(to: t.url("bad.gz"))
        #expect(!(try Xipper.test(t.url("bad.gz")).isOK))
    }

    @Test func bamIsVerifiedButNotExtracted() throws {
        guard let samtools = htsSamtools else { return }
        let t = TempDir()
        var sam = "@HD\tVN:1.6\tSO:coordinate\n@SQ\tSN:chr1\tLN:100000\n"
        for i in 0..<5000 {
            sam += "r\(i)\t0\tchr1\t\(1 + i * 10)\t60\t20M\t*\t0\t0\tACGTACGTACGTACGTACGT\tIIIIIIIIIIIIIIIIIIII\n"
        }
        t.write("a.sam", sam)
        #expect(run(samtools, ["view", "-b", "-o", t.path + "/a.bam", t.path + "/a.sam"]).status == 0)
        let bam = t.url("a.bam")
        #expect(try ArchiveFormat.detect(bam) == .bgzf)
        #expect(try Xipper.test(bam).isOK)
        #expect(try Xipper.bgzfInfo(bam).endsWithEOFMarker)
        #expect(throws: XipperError.self) { try Xipper.extract(bam) }
        #expect(AlreadyCompressed.matches("sample.bam") && AlreadyCompressed.matches("sample.cram"))
    }
}
