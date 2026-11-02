import Foundation
import Testing
@testable import XipperKit

@Suite("Nested archives")
struct NestedExtractionTests {
    /// outer.zip › l1/{top.txt, mid.7z › l2/{inner.tar.gz › l3/deep.txt, app.log.gz, s.vcf.gz, doc.docx, set.7z.001}}
    func nested(_ t: TempDir) throws -> URL {
        t.write("l3/deep.txt", "deep\n")
        t.mkdir("l2")
        t.mkdir("l1")
        try Xipper.create(from: [t.url("l3")], to: t.url("l2/inner.tar.gz"), options: { var o = CreateOptions(); o.format = .tarGzip; return o }())
        t.write("log/app.log", String(repeating: "log line\n", count: 100))
        try Xipper.create(from: [t.url("log/app.log")], to: t.url("l2/app.log.gz"), options: { var o = CreateOptions(); o.format = .gzip; return o }())
        t.write("vcf/s.vcf", "##fileformat=VCFv4.2\n")
        try Xipper.create(from: [t.url("vcf/s.vcf")], to: t.url("l2/s.vcf.gz"), options: { var o = CreateOptions(); o.format = .gzip; return o }())
        t.write("l2/doc.docx", "not really a docx")
        t.write("l2/set.7z.001", "a volume")
        try Xipper.create(from: [t.url("l2")], to: t.url("l1/mid.7z"), options: { var o = CreateOptions(); o.format = .sevenZip; return o }())
        t.write("l1/top.txt", "top\n")
        try Xipper.create(from: [t.url("l1/mid.7z"), t.url("l1/top.txt")], to: t.url("outer.zip"), options: CreateOptions())
        return t.url("outer.zip")
    }

    @Test func extractsEveryLevelAndRemovesTheInnerArchives() throws {
        let t = TempDir()
        let a = try nested(t)
        t.mkdir("out")
        var o = ExtractOptions()
        o.nestedDepth = 3
        let r = try Xipper.extract(a, to: t.url("out"), options: o)
        let root = r.destination.path
        #expect(r.nested.count == 3)  // mid.7z, inner.tar.gz, app.log.gz
        #expect(r.skipped.isEmpty)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: root + "/top.txt"))
        #expect(fm.fileExists(atPath: root + "/l2/l3/deep.txt"))
        #expect(fm.fileExists(atPath: root + "/l2/app.log"))
        #expect(!fm.fileExists(atPath: root + "/mid.7z") && !fm.fileExists(atPath: root + "/l2/inner.tar.gz"))
        // Left alone: genomic gzip, a volume, a document.
        for kept in ["s.vcf.gz", "set.7z.001", "doc.docx"] { #expect(fm.fileExists(atPath: root + "/l2/" + kept), "\(kept)") }
    }

    @Test func depthLimitAndKeepingArchives() throws {
        let t = TempDir()
        let a = try nested(t)
        t.mkdir("out")
        var o = ExtractOptions()
        o.nestedDepth = 1
        o.keepNestedArchives = true
        let r = try Xipper.extract(a, to: t.url("out"), options: o)
        let root = r.destination.path
        #expect(r.nested.count == 1)
        #expect(FileManager.default.fileExists(atPath: root + "/mid.7z"))
        #expect(FileManager.default.fileExists(atPath: root + "/l2/inner.tar.gz"))  // level 2: not reached
    }

    @Test func intoModeOnlyTouchesWhatItExtracted() throws {
        let t = TempDir()
        let a = try nested(t)
        t.mkdir("out")
        try Xipper.create(from: [t.url("l3")], to: t.url("out/already.zip"), options: CreateOptions())
        var o = ExtractOptions()
        o.nestedDepth = 3
        _ = try Xipper.extract(a, to: t.url("out"), mode: .into, options: o)
        #expect(FileManager.default.fileExists(atPath: t.path + "/out/already.zip"))  // was there before: not extracted
        #expect(FileManager.default.fileExists(atPath: t.path + "/out/l2/l3/deep.txt"))
    }

    @Test func aDamagedNestedArchiveIsKeptAndReported() throws {
        let t = TempDir()
        t.write("in/bad.zip", "PK\u{3}\u{4} definitely not a zip")
        t.write("in/ok.txt", "ok")
        try Xipper.create(from: [t.url("in")], to: t.url("o.zip"), options: CreateOptions())
        t.mkdir("out")
        var o = ExtractOptions()
        o.nestedDepth = 2
        let r = try Xipper.extract(t.url("o.zip"), to: t.url("out"), options: o)
        #expect(r.skipped.map(\.path) == ["in/bad.zip"])
        #expect(FileManager.default.fileExists(atPath: r.destination.path + "/bad.zip"))
    }
}
