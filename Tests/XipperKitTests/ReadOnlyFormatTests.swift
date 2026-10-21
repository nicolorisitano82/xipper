import Foundation
import Testing
@testable import XipperKit

/// Read-only formats of the matrix (STUDIO.md §4.2): LZ4, brotli, cpio, Apple Archive, made by the
/// reference tools and read back through detect, list, test and extract.
@Suite("Read-only formats: lz4, brotli, cpio, Apple Archive")
struct ReadOnlyFormatTests {
    static let lz4 = ["/opt/homebrew/bin/lz4", "/usr/local/bin/lz4"].first(where: toolExists)
    static let brotli = ["/opt/homebrew/bin/brotli", "/usr/local/bin/brotli"].first(where: toolExists)

    func tree(_ t: TempDir) {
        t.write("src/a.txt", String(repeating: "Xipper read-only formats\n", count: 2000))
        t.write("src/sub/b.bin", sampleData(700 << 10, seed: 11))
        t.symlink("src/link", to: "a.txt")
    }

    /// Extracts `archive`, compares with `src` (or `src` inside the output when `nested`).
    func roundTrip(_ t: TempDir, _ archive: String, expect format: ArchiveFormat, nested: Bool) throws {
        #expect(try ArchiveFormat.detect(t.url(archive)) == format)
        #expect(try Xipper.test(t.url(archive)).isOK)
        #expect(try Xipper.list(t.url(archive)).contains { $0.path.hasSuffix("sub/b.bin") })
        let out = "out-" + archive
        t.mkdir(out)
        try Xipper.extract(t.url(archive), to: t.url(out), mode: .into)
        let (same, why) = treesEqual(t.path + "/src", t.path + "/" + out + (nested ? "/src" : ""))
        #expect(same, "\(archive): \(why)")
        #expect(throws: XipperError.self) {
            var o = CreateOptions()
            o.format = format
            try Xipper.create(from: [t.url("src")], to: t.url("never." + format.fileExtension), options: o)
        }
    }

    @Test(.enabled(if: lz4 != nil), arguments: ["-BI", "-BD", "--content-size"])
    func lz4Frames(mode: String) throws {
        let t = TempDir()
        tree(t)
        #expect(run("/usr/bin/tar", ["-cf", "t.tar", "src"], cwd: t.path).status == 0)
        #expect(run(Self.lz4!, ["-q", mode, "-BX", "t.tar", "t.tar.lz4"], cwd: t.path).status == 0)
        try roundTrip(t, "t.tar.lz4", expect: .tarLz4, nested: true)
        // Single file, linked blocks.
        #expect(run(Self.lz4!, ["-q", "-BD", "src/sub/b.bin", "b.bin.lz4"], cwd: t.path).status == 0)
        t.mkdir("single")
        try Xipper.extract(t.url("b.bin.lz4"), to: t.url("single"), mode: .into)
        #expect(FileManager.default.contentsEqual(atPath: t.path + "/single/b.bin", andPath: t.path + "/src/sub/b.bin"))
    }

    @Test(.enabled(if: brotli != nil))
    func brotliTar() throws {
        let t = TempDir()
        tree(t)
        #expect(run("/usr/bin/tar", ["-cf", "t.tar", "src"], cwd: t.path).status == 0)
        #expect(run(Self.brotli!, ["-q", "9", "-o", "t.tar.br", "t.tar"], cwd: t.path).status == 0)
        try roundTrip(t, "t.tar.br", expect: .tarBrotli, nested: true)
    }

    @Test(.enabled(if: toolExists("/usr/bin/cpio")), arguments: ["newc", "odc"])
    func cpioArchives(format: String) throws {
        let t = TempDir()
        tree(t)
        let r = run("/bin/sh", ["-c", "find . | /usr/bin/cpio -o -H \(format) > ../c.cpio"], cwd: t.path + "/src")
        #expect(r.status == 0)
        try roundTrip(t, "c.cpio", expect: .cpio, nested: false)
        // cpio inside gzip is read through the normal decompression pipeline.
        #expect(run("/usr/bin/gzip", ["-k", "c.cpio"], cwd: t.path).status == 0)
        t.mkdir("gz")
        try Xipper.extract(t.url("c.cpio.gz"), to: t.url("gz"), mode: .into)
        #expect(treesEqual(t.path + "/src", t.path + "/gz").0)
    }

    @Test(.enabled(if: toolExists("/usr/bin/aa")), arguments: ["lzfse", "lzma", "raw", "lz4", "zlib"])
    func appleArchive(algorithm: String) throws {
        let t = TempDir()
        tree(t)
        #expect(run("/usr/bin/aa", ["archive", "-d", "src", "-o", "a.aar", "-a", algorithm], cwd: t.path).status == 0)
        try roundTrip(t, "a.aar", expect: .appleArchive, nested: false)
    }

    /// Mutated copies of tool-made archives: errors are fine, crashes and escapes are not.
    @Test(.enabled(if: lz4 != nil && brotli != nil))
    func mutatedReadOnlyArchivesNeverCrash() throws {
        let t = TempDir()
        tree(t)
        _ = run("/usr/bin/tar", ["-cf", "t.tar", "src"], cwd: t.path)
        _ = run(Self.lz4!, ["-q", "-BD", "t.tar", "t.tar.lz4"], cwd: t.path)
        _ = run(Self.brotli!, ["-q", "-o", "t.tar.br", "t.tar"], cwd: t.path)
        _ = run("/bin/sh", ["-c", "find . | /usr/bin/cpio -o -H newc > ../c.cpio"], cwd: t.path + "/src")
        _ = run("/usr/bin/aa", ["archive", "-d", "src", "-o", "a.aar"], cwd: t.path)
        var rng = FuzzTests.SplitMix(state: 99)
        let fuzz = FuzzTests()
        for name in ["t.tar.lz4", "t.tar.br", "c.cpio", "a.aar"] {
            guard let bytes = try? [UInt8](Data(contentsOf: t.url(name))) else { continue }
            for i in 0..<FuzzTests.iterations {
                let sample = t.url("m\(i)-" + name)
                try Data(fuzz.mutate(bytes, &rng)).write(to: sample)
                _ = try? Xipper.list(sample)
                _ = try? Xipper.test(sample, workload: .threads(2))
                t.mkdir("x\(i)")
                var o = ExtractOptions()
                o.limits.maxTotalBytes = 64 << 20
                _ = try? Xipper.extract(sample, to: t.url("x\(i)"), mode: .into, options: o)
                try? FileManager.default.removeItem(at: sample)
                try? FileManager.default.removeItem(at: t.url("x\(i)"))
            }
        }
        let stray = try FileManager.default.contentsOfDirectory(atPath: t.path)
            .filter { !["src", "t.tar", "t.tar.lz4", "t.tar.br", "c.cpio", "a.aar"].contains($0) }
        #expect(stray.isEmpty, "\(stray)")
    }

    @Test func xxHash32KnownVectors() {
        var h = XXH32()
        #expect(h.digest() == 0x02CC_5D05)  // empty input, seed 0
        let abc = Array("abc".utf8)
        abc.withUnsafeBytes { h.update($0) }
        #expect(h.digest() == 0x32D1_53FF)
    }
}
