import Foundation
import Testing
@testable import XipperKit

@Suite("XIZ v0 (beta format)")
struct XizTests {
    func tree(_ t: TempDir) {
        t.write("src/text.txt", String(repeating: "Xipper XIZ ", count: 40_000))
        t.write("src/big.bin", sampleData(9 << 20, seed: 41))  // spans three frames
        t.write("src/copy/big.bin", sampleData(9 << 20, seed: 41))  // identical: stored once
        t.write("src/empty", "")
        for i in 0..<200 { t.write("src/small/f\(i).txt", "file \(i)\n") }
        t.symlink("src/link", to: "text.txt")
        let v = Array("Blu".utf8)
        _ = v.withUnsafeBytes { setxattr(t.path + "/src/text.txt", "app.xipper.xiz", $0.baseAddress, v.count, 0, 0) }
    }

    @Test func roundTripWithDedupAndAttributes() throws {
        let t = TempDir()
        tree(t)
        var o = CreateOptions()
        o.format = .xiz
        let r = try Xipper.create(from: [t.url("src")], to: t.url("a.xiz"), options: o)
        #expect(try ArchiveFormat.detect(t.url("a.xiz")) == .xiz)
        // The 9 MiB duplicate is stored once (random data does not compress).
        #expect(r.outputBytes < (9 << 20) + (2 << 20))
        let report = try Xipper.test(t.url("a.xiz"), digests: true)
        #expect(report.isOK)
        #expect(report.digests["src/big.bin"] == report.digests["src/copy/big.bin"])
        t.mkdir("out")
        try Xipper.extract(t.url("a.xiz"), to: t.url("out"), mode: .into)
        #expect(treesEqual(t.path + "/src", t.path + "/out/src").0)
        #expect(ExtendedAttributes.read(t.path + "/out/src/text.txt").first { $0.name == "app.xipper.xiz" }?.value == Array("Blu".utf8))
        let preview = try Xipper.readEntry(t.url("a.xiz"), path: "src/text.txt", maxBytes: 11)
        #expect(String(decoding: preview.data, as: UTF8.self) == "Xipper XIZ " && preview.truncated)
        // Selection extracts only what is asked.
        t.mkdir("sel")
        var x = ExtractOptions()
        x.selection = ["src/small"]
        try Xipper.extract(t.url("a.xiz"), to: t.url("sel"), mode: .into, options: x)
        #expect(FileManager.default.fileExists(atPath: t.path + "/sel/src/small/f199.txt"))
        #expect(!FileManager.default.fileExists(atPath: t.path + "/sel/src/big.bin"))
    }

    @Test func damagedFrameIsDetectedAndNothingWrongIsWritten() throws {
        let t = TempDir()
        tree(t)
        var o = CreateOptions()
        o.format = .xiz
        try Xipper.create(from: [t.url("src")], to: t.url("a.xiz"), options: o)
        var bytes = try [UInt8](Data(contentsOf: t.url("a.xiz")))
        bytes[Xiz.superblockSize + Xiz.frameHeaderSize + 1000] ^= 0x55  // inside the first frame's payload
        try Data(bytes).write(to: t.url("bad.xiz"))
        let r = try Xipper.test(t.url("bad.xiz"))
        #expect(!r.isOK)
        #expect(r.failures.contains { if case .checksumMismatch = $0.problem { true } else { false } })
        t.mkdir("out")
        #expect(throws: XipperError.self) { try Xipper.extract(t.url("bad.xiz"), to: t.url("out")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.path + "/out").isEmpty)  // smart mode cleaned up
        // Truncation and a damaged catalog are refused before anything else.
        try Data(bytes.prefix(bytes.count - 10)).write(to: t.url("short.xiz"))
        #expect(throws: XipperError.self) { _ = try Xipper.list(t.url("short.xiz")) }
    }

    @Test func passwordIsRefusedInTheBeta() {
        let t = TempDir()
        t.write("src/a.txt", "x")
        var o = CreateOptions()
        o.format = .xiz
        o.password = "segreto"
        #expect(throws: XipperError.self) { try Xipper.create(from: [t.url("src")], to: t.url("a.xiz"), options: o) }
    }
}
