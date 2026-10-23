import Foundation
import Testing
@testable import XipperKit

/// ZIP Deflate64 (method 9), read only: a fixture made by 7-Zip (`-mm=Deflate64`) with 60 KB
/// distances and a 50 KB match, archives 7-Zip makes on the fly at several levels, and damaged
/// data, which must fail cleanly.
@Suite("ZIP Deflate64")
struct Deflate64Tests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/zip/deflate64.zip")

    @Test func readsTheFixture() throws {
        let a = Self.fixture
        #expect(try Xipper.test(a).isOK)
        let far = try Xipper.readEntry(a, path: "far.bin", maxBytes: 1 << 20).data
        #expect(far.count == 110_000)
        #expect(far[0..<50_000] == far[60_000...])
        #expect(far[50_000..<60_000].allSatisfy { $0 == UInt8(ascii: "Z") })
        let text = String(decoding: try Xipper.readEntry(a, path: "text.txt", maxBytes: 1 << 20).data, as: UTF8.self)
        #expect(text.hasPrefix("riga 0 del file di prova Deflate64\n") && text.hasSuffix("riga 2999 del file di prova Deflate64\n"))
        #expect(try Xipper.list(a).first { $0.path == "far.bin" }?.method == "deflate64")
    }

    @Test(.enabled(if: sevenZip != nil), arguments: [1, 5, 9])
    func readsWhat7ZipWrites(level: Int) throws {
        let t = TempDir()
        t.write("src/random.bin", sampleData(3 << 20, seed: 64))
        t.write("src/text.txt", String(repeating: "Deflate64 con finestra da 64 KiB e corrispondenze lunghe\n", count: 40_000))
        var big = sampleData(40_000, seed: 2)
        for _ in 0..<6 { big += sampleData(20_000, seed: 3) + big.prefix(40_000) }
        t.write("src/sub/far.bin", big)
        let r = run(sevenZip!, ["a", "-bd", "-tzip", "-mm=Deflate64", "-mx=\(level)", t.path + "/d.zip", "src"], cwd: t.path)
        #expect(r.status == 0, "\(r.output)")
        #expect(try Xipper.test(t.url("d.zip")).isOK)
        t.mkdir("out")
        try Xipper.extract(t.url("d.zip"), to: t.url("out"), mode: .into)
        #expect(treesEqual(t.path + "/src", t.path + "/out/src").0)
    }

    @Test func damagedDataFailsCleanly() throws {
        let t = TempDir()
        let original = try [UInt8](Data(contentsOf: Self.fixture))
        for k in 0..<40 {
            var bytes = original
            let at = 200 + (k * 1_373) % (bytes.count - 2_000)
            bytes[at] ^= UInt8(1 << (k % 8))
            try Data(bytes).write(to: t.url("bad\(k).zip"))
            // Either an error or (rarely) a CRC mismatch report; never a crash or a hang.
            if let r = try? Xipper.test(t.url("bad\(k).zip")) { _ = r.isOK }
        }
    }

    // MARK: writing (2.1)

    func tree(_ t: TempDir) {
        t.write("src/text.txt", String(repeating: "Deflate64 scritto da Xipper, finestra da 64 KiB\n", count: 30_000))
        var far = sampleData(40_000, seed: 5)
        for _ in 0..<20 { far += sampleData(15_000, seed: 6) + far.prefix(40_000) }  // matches 55 KB back
        t.write("src/far.bin", far)
        t.write("src/run.bin", [UInt8](repeating: 7, count: 300_000) + sampleData(1000, seed: 8))  // matches > 258
        t.write("src/big.bin", (0..<5).flatMap { _ in sampleData(4 << 20, seed: 9) })  // 20 MB: chunked in parallel
        t.write("src/random.bin", (0..<70_000).map { _ in UInt8.random(in: 0...255) })  // stored
        t.write("src/one.txt", "x")
        t.write("src/empty.txt", "")
    }

    @Test(arguments: [(1, nil), (6, nil), (9, nil), (6, "Segreto-64")] as [(Int, String?)])
    func writesDeflate64(level: Int, password: String?) throws {
        let t = TempDir()
        tree(t)
        var o = CreateOptions()
        o.format = .zip
        o.zipMethod = .deflate64
        o.level = level
        o.password = password
        o.storeAlreadyCompressed = false
        try Xipper.create(from: [t.url("src")], to: t.url("d.zip"), options: o)
        let entries = try Xipper.list(t.url("d.zip"), password: password)
        #expect(entries.first { $0.path == "src/big.bin" }?.method == "deflate64")
        #expect(try Xipper.test(t.url("d.zip"), password: password).isOK)
        t.mkdir("out")
        var x = ExtractOptions()
        x.password = password
        try Xipper.extract(t.url("d.zip"), to: t.url("out"), mode: .into, options: x)
        #expect(treesEqual(t.path + "/src", t.path + "/out/src").0)
        if let sevenZip {
            let pw = password.map { ["-p" + $0] } ?? []
            let r = run(sevenZip, ["t", "-bd"] + pw + [t.path + "/d.zip"])
            #expect(r.status == 0 && r.output.contains("Everything is Ok"), "\(r.output)")
        }
        if password == nil {  // Info-ZIP unzip 6 (macOS) decodes Deflate64 too
            let u = run("/usr/bin/unzip", ["-tq", t.path + "/d.zip"])
            #expect(u.status == 0, "\(u.output)")
        }
        // Smaller than deflate at the same level on data with long-range matches.
        if password == nil {
            o.zipMethod = .deflate
            try Xipper.create(from: [t.url("src/far.bin")], to: t.url("plain.zip"), options: o)
            o.zipMethod = .deflate64
            try Xipper.create(from: [t.url("src/far.bin")], to: t.url("d64.zip"), options: o)
            #expect(try Data(contentsOf: t.url("d64.zip")).count < Data(contentsOf: t.url("plain.zip")).count)
        }
    }
}
