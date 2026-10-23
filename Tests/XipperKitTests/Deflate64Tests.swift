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
}
