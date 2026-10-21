import Foundation
import Testing
@testable import XipperKit

@Suite("ZIP writer interoperability")
struct ZipWriterTests {
    func create(_ t: TempDir, _ options: ZipOptions, name: String = "out.zip") throws -> String {
        let items = try SourceScanner.scan([t.url("src")], options: ScanOptions())
        let out = t.path + "/" + name
        _ = try ZipWriter.write(items: items, to: out, options: options, overwrite: false, progress: nil, cancel: nil)
        return out
    }

    @Test(arguments: [false, true])
    func readableByUnzipPythonAndDitto(forceZip64: Bool) throws {
        let t = TempDir()
        makeTree(t)
        var o = ZipOptions()
        o.forceZip64 = forceZip64
        o.workload = .threads(4)
        let zip = try create(t, o)
        let test = run("/usr/bin/unzip", ["-t", zip])
        #expect(test.status == 0, "\(test.output)")
        let py = run("/usr/bin/python3", ["-I", "-c", "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); r=z.testzip(); sys.exit(0 if r is None else 1)", zip])
        #expect(py.status == 0, "\(py.output)")
        t.mkdir("ditto")
        #expect(run("/usr/bin/ditto", ["-x", "-k", zip, t.path + "/ditto"]).status == 0)
        let (same, diff) = treesEqual(t.path + "/src", t.path + "/ditto/src")
        #expect(same, "\(diff)")
    }

    @Test func aesReadableBy7Zip() throws {
        guard let sz = sevenZip else { return }
        let t = TempDir()
        makeTree(t)
        var o = ZipOptions()
        o.password = "Passw0rd-xipper"
        let zip = try create(t, o)
        let r = run(sz, ["t", "-pPassw0rd-xipper", zip])
        #expect(r.status == 0, "\(r.output)")
        let bad = run(sz, ["t", "-pwrong", zip])
        #expect(bad.status != 0)
        t.mkdir("x")
        #expect(run(sz, ["x", "-pPassw0rd-xipper", "-o" + t.path + "/x", zip]).status == 0)
        let (same, diff) = treesEqual(t.path + "/src", t.path + "/x/src")
        #expect(same, "\(diff)")
    }

    @Test func zstdReadableBy7Zip() throws {
        guard let sz = sevenZip else { return }
        let t = TempDir()
        makeTree(t)
        var o = ZipOptions()
        o.method = .zstd
        o.level = 3
        let zip = try create(t, o)
        let r = run(sz, ["t", zip])
        #expect(r.status == 0, "\(r.output)")
    }

    @Test func compressesAndStoresSensibly() throws {
        let t = TempDir()
        makeTree(t)
        let zip = try create(t, ZipOptions())
        let info = run("/usr/bin/zipinfo", ["-v", zip]).output
        // jpg extension is stored, text deflated
        #expect(info.contains("compression method:                             none (stored)"))
        #expect(info.contains("deflated"))
        let size = try FileManager.default.attributesOfItem(atPath: zip)[.size] as! Int
        #expect(size < 9 << 20)
    }
}

@Suite("ZIP64 entry count")
struct Zip64CountTests {
    /// More than 65 535 entries forces the ZIP64 end records without needing 4 GiB of data.
    @Test func seventyThousandEntries() throws {
        let t = TempDir()
        let items = (0..<70_000).map { i in
            ArchiveItem(name: "d/\(i)", sourcePath: "/nonexistent", kind: .directory, permissions: 0o755,
                        modified: Date(timeIntervalSince1970: 1_700_000_000), uid: 0, gid: 0)
        }
        let out = t.path + "/many.zip"
        _ = try ZipWriter.write(items: items, to: out, options: ZipOptions(), overwrite: false, progress: nil, cancel: nil)
        let zip = try ZipArchive(path: out)
        #expect(zip.records.count == 70_000)
        let py = run("/usr/bin/python3", ["-I", "-c", "import zipfile,sys; print(len(zipfile.ZipFile(sys.argv[1]).infolist()))", out])
        #expect(py.output.trimmingCharacters(in: .whitespacesAndNewlines) == "70000")
        #expect(run("/usr/bin/unzip", ["-tqq", out]).status == 0)
    }
}
