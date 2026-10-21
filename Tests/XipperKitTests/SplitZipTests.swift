import Foundation
import Testing
@testable import XipperKit

@Suite("Split ZIP archives")
struct SplitZipTests {
    func tree(_ t: TempDir) {
        for i in 0..<5 { t.write("src/f\(i).bin", sampleData(300 << 10, seed: UInt64(i + 7))) }
        t.write("src/note.txt", "split")
    }

    /// Info-ZIP `zip -s`: name.z01, name.z02, …, name.zip with per-part offsets.
    @Test(.enabled(if: toolExists("/usr/bin/zip")))
    func infoZipSplitExtractsFromAnyPart() throws {
        let t = TempDir()
        tree(t)
        let r = run("/usr/bin/zip", ["-q", "-r", "-0", "-s", "400k", "a.zip", "src"], cwd: t.path)
        #expect(r.status == 0)
        #expect(FileManager.default.fileExists(atPath: t.path + "/a.z01"))
        for opened in ["a.zip", "a.z01"] {
            #expect(try ArchiveFormat.detect(t.url(opened)) == .zip)
            #expect(try Xipper.test(t.url(opened)).isOK)
            let dest = "out-" + opened
            t.mkdir(dest)
            try Xipper.extract(t.url(opened), to: t.url(dest), mode: .into)
            #expect(treesEqual(t.path + "/src", t.path + "/\(dest)/src").0)
        }
    }

    /// 7-Zip / `split` style: plain pieces name.zip.001, name.zip.002, …
    @Test func numberedPiecesAreJoined() throws {
        let t = TempDir()
        tree(t)
        try Xipper.create(from: [t.url("src")], to: t.url("whole.zip"))
        let data = try Data(contentsOf: t.url("whole.zip"))
        let piece = 500 << 10
        for (i, start) in stride(from: 0, to: data.count, by: piece).enumerated() {
            try data[start..<min(start + piece, data.count)].write(to: t.url(String(format: "b.zip.%03d", i + 1)))
        }
        #expect(try Xipper.test(t.url("b.zip.001")).isOK)
        t.mkdir("out")
        try Xipper.extract(t.url("b.zip.001"), to: t.url("out"), mode: .into)
        #expect(treesEqual(t.path + "/src", t.path + "/out/src").0)
    }

    @Test(.enabled(if: toolExists("/usr/bin/zip")))
    func missingPartIsReported() throws {
        let t = TempDir()
        tree(t)
        _ = run("/usr/bin/zip", ["-q", "-r", "-0", "-s", "400k", "c.zip", "src"], cwd: t.path)
        try FileManager.default.removeItem(atPath: t.path + "/c.z02")
        #expect(throws: XipperError.self) { _ = try Xipper.test(t.url("c.zip")) }
    }
}
