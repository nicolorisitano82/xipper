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

    // MARK: writing (2.1)

    /// Info-ZIP layout: a.z01, a.z02, …, a.zip; read back by Xipper, 7-Zip and Info-ZIP.
    @Test(arguments: [false, true])
    func writesSpannedVolumes(encrypted: Bool) throws {
        let t = TempDir()
        tree(t)
        var o = CreateOptions()
        o.format = .zip
        o.zipMethod = .store  // the sample data compresses: stored, it fills several volumes
        o.volumeSize = 400 << 10
        o.password = encrypted ? "Segreto-zip" : nil
        try Xipper.create(from: [t.url("src")], to: t.url("a.zip"), options: o)
        let parts = try FileManager.default.contentsOfDirectory(atPath: t.path).filter { $0.hasPrefix("a.") }.sorted()
        #expect(parts == ["a.z01", "a.z02", "a.z03", "a.zip"])
        for p in parts { #expect(try Data(contentsOf: t.url(p)).count <= 400 << 10) }
        var x = ExtractOptions()
        x.password = o.password
        for opened in ["a.zip", "a.z01"] {
            #expect(try Xipper.test(t.url(opened), password: o.password).isOK)
        }
        t.mkdir("out")
        try Xipper.extract(t.url("a.zip"), to: t.url("out"), mode: .into, options: x)
        #expect(treesEqual(t.path + "/src", t.path + "/out/src").0)
        if let sevenZip {
            let pw = o.password.map { ["-p" + $0] } ?? []
            let r = run(sevenZip, ["t", "-bd"] + pw + [t.path + "/a.zip"])
            #expect(r.status == 0 && r.output.contains("Everything is Ok"), "\(r.output)")
        }
        if !encrypted, toolExists("/usr/bin/zip") {
            #expect(run("/usr/bin/zip", ["-q", "-s", "0", "a.zip", "--out", "joined.zip"], cwd: t.path).status == 0)
            let r = run("/usr/bin/unzip", ["-tq", t.path + "/joined.zip"])
            #expect(r.status == 0, "\(r.output)")
        }
        // Rewriting with bigger volumes removes the parts the new set does not have.
        o.volumeSize = 1 << 20
        o.overwrite = true
        try Xipper.create(from: [t.url("src")], to: t.url("a.zip"), options: o)
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.path).filter { $0.hasPrefix("a.") }.sorted() == ["a.z01", "a.zip"])
        #expect(try Xipper.test(t.url("a.zip"), password: o.password).isOK)
    }

    /// Everything fits in the first volume: one file marked as a single-segment split archive.
    @Test func spannedArchiveInOneVolume() throws {
        let t = TempDir()
        t.write("src/x.txt", "piccolo")
        var o = CreateOptions()
        o.format = .zip
        o.volumeSize = 1 << 20
        try Xipper.create(from: [t.url("src")], to: t.url("a.zip"), options: o)
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.path).filter { $0.hasPrefix("a.") } == ["a.zip"])
        #expect(try Xipper.test(t.url("a.zip")).isOK)
        #expect(run("/usr/bin/unzip", ["-tq", t.path + "/a.zip"]).status == 0)
        if let sevenZip { #expect(run(sevenZip, ["t", "-bd", t.path + "/a.zip"]).status == 0) }
    }

    @Test func writesNumberedPieces() throws {
        let t = TempDir()
        tree(t)
        var o = CreateOptions()
        o.format = .zip
        o.zipMethod = .store
        o.volumeSize = 500 << 10
        o.zipVolumeStyle = .numbered
        try Xipper.create(from: [t.url("src")], to: t.url("b.zip"), options: o)
        let parts = try FileManager.default.contentsOfDirectory(atPath: t.path).filter { $0.hasPrefix("b.") }.sorted()
        #expect(parts == ["b.zip.001", "b.zip.002", "b.zip.003", "b.zip.004"])
        #expect(try Xipper.test(t.url("b.zip.001")).isOK)
        // Joined, the pieces are a plain ZIP.
        var joined = Data()
        for p in parts { joined += try Data(contentsOf: t.url(p)) }
        try joined.write(to: t.url("joined.zip"))
        #expect(run("/usr/bin/unzip", ["-tq", t.path + "/joined.zip"]).status == 0)
        if let sevenZip { #expect(run(sevenZip, ["t", "-bd", t.path + "/b.zip.001"]).status == 0) }
    }
}
