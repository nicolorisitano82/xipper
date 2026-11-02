import Foundation
import Testing
@testable import XipperKit

/// ZIP repair without recovery data: the directory is rebuilt from the local headers.
@Suite("ZIP repair")
struct ZipRepairTests {
    func source(_ t: TempDir) throws -> URL {
        for i in 0..<6 { t.write("src/f\(i).txt", sampleData(300_000, seed: UInt64(i + 1))) }
        t.write("src/sub/r.bin", sampleData(50_000, seed: 99))
        t.write("src/run.sh", Array("#!/bin/sh\necho hi\n".utf8), mode: 0o755)
        t.symlink("src/link", to: "f1.txt")
        try Xipper.create(from: [t.url("src")], to: t.url("a.zip"), options: CreateOptions())
        return t.url("a.zip")
    }

    func damaged(_ t: TempDir, _ name: String, _ change: (inout [UInt8]) -> Void) throws -> URL {
        var b = try [UInt8](Data(contentsOf: t.url("a.zip")))
        change(&b)
        try Data(b).write(to: t.url(name))
        return t.url(name)
    }

    func offset(of s: String, in b: [UInt8]) -> Int {
        let n = Array(s.utf8)
        return (0...(b.count - n.count)).first { b[$0..<($0 + n.count)].elementsEqual(n) }!
    }

    @Test func centralDirectoryDestroyed() throws {
        let t = TempDir()
        _ = try source(t)
        let bad = try damaged(t, "c.zip") { b in
            let cd = offset(of: "PK\u{1}\u{2}", in: b)
            b.removeSubrange(cd...)
        }
        #expect(throws: (any Error).self) { _ = try Xipper.test(bad) }
        let r = try Xipper.repairZip(bad)
        #expect(r.output.lastPathComponent == "c (riparato).zip")
        #expect(r.lost.isEmpty)
        #expect(try Xipper.test(r.output).isOK)
        t.mkdir("out")
        try Xipper.extract(r.output, to: t.url("out"), mode: .into, options: ExtractOptions())
        // Contents survive; permissions and links need the old directory, gone here.
        for i in 0..<6 {
            #expect(FileManager.default.contentsEqual(atPath: t.path + "/src/f\(i).txt", andPath: t.path + "/out/src/f\(i).txt"))
        }
        #expect(run("/usr/bin/unzip", ["-tq", r.output.path]).status == 0)
    }

    @Test func partlyDamagedDirectoryKeepsWhatItCan() throws {
        let t = TempDir()
        _ = try source(t)
        // Only the end of central directory record is gone: every central record is still there.
        let bad = try damaged(t, "e.zip") { b in b.removeLast(22) }
        let r = try Xipper.repairZip(bad)
        t.mkdir("out")
        try Xipper.extract(r.output, to: t.url("out"), mode: .into, options: ExtractOptions())
        #expect(treesEqual(t.path + "/src", t.path + "/out/src").0)  // links and the executable bit too
    }

    @Test func truncatedArchiveLosesOnlyTheCutEntry() throws {
        let t = TempDir()
        let a = try source(t)
        let size = try FileManager.default.attributesOfItem(atPath: a.path)[.size] as! Int
        let bad = try damaged(t, "t.zip") { b in b.removeLast(size / 2) }
        let r = try Xipper.repairZip(bad, to: t.url("fixed.zip"))
        #expect(r.lost.count == 1)
        #expect(r.recovered >= 3)
        #expect(try Xipper.test(r.output).isOK)
    }

    @Test func damagedDataIsLeftOut() throws {
        let t = TempDir()
        _ = try source(t)
        let bad = try damaged(t, "m.zip") { b in
            let at = offset(of: "src/f2.txt", in: b) + 5000
            for i in at..<(at + 40) { b[i] ^= 0xAA }
        }
        let r = try Xipper.repairZip(bad)
        #expect(r.lost == ["src/f2.txt"])
        #expect(try Xipper.test(r.output).isOK)
        #expect(try Xipper.list(r.output).count == (try Xipper.list(t.url("a.zip")).count - 1))
    }

    @Test func storedZipInsideIsNotSplitApart() throws {
        let t = TempDir()
        _ = try source(t)
        t.mkdir("outer")
        try FileManager.default.copyItem(atPath: t.path + "/a.zip", toPath: t.path + "/outer/inner.zip")
        t.write("outer/z.txt", "z\n")
        var o = CreateOptions()
        o.zipMethod = .store
        try Xipper.create(from: [t.url("outer/inner.zip"), t.url("outer/z.txt")], to: t.url("o.zip"), options: o)
        var b = try [UInt8](Data(contentsOf: t.url("o.zip")))
        b.removeLast(30)
        try Data(b).write(to: t.url("ot.zip"))
        let r = try Xipper.repairZip(t.url("ot.zip"))
        #expect(try Xipper.list(r.output).map(\.path).sorted() == ["inner.zip", "z.txt"])
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/ditto")))
    func dataDescriptorsFromDitto() throws {
        let t = TempDir()
        _ = try source(t)
        #expect(run("/usr/bin/ditto", ["-c", "-k", t.path + "/src", t.path + "/d.zip"]).status == 0)
        var b = try [UInt8](Data(contentsOf: t.url("d.zip")))
        b.removeLast(60)
        try Data(b).write(to: t.url("dt.zip"))
        let r = try Xipper.repairZip(t.url("dt.zip"))
        #expect(r.lost.isEmpty)
        #expect(try Xipper.test(r.output).isOK)
    }

    @Test func libarchiveZipWithoutEndRecord() throws {
        let t = TempDir()
        let src = LibarchiveVectorTests.dir.appendingPathComponent("test_read_format_zip_extra_padding.zip")
        try FileManager.default.copyItem(at: src, to: t.url("p.zip"))
        let r = try Xipper.repairZip(t.url("p.zip"))
        #expect(try Xipper.readEntry(r.output, path: "a", maxBytes: 10).data == Array("b\n".utf8))
    }

    @Test func notAZipAndExistingTargetAreRefused() throws {
        let t = TempDir()
        t.write("x.zip", "nothing here")
        #expect(throws: XipperError.self) { try Xipper.repairZip(t.url("x.zip")) }
        let a = try source(t)
        t.write("busy.zip", "x")
        #expect(throws: XipperError.self) { try Xipper.repairZip(a, to: t.url("busy.zip")) }
    }
}
