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
        if !format.canCreate { #expect(throws: XipperError.self) {
            var o = CreateOptions()
            o.format = format
            try Xipper.create(from: [t.url("src")], to: t.url("never." + format.fileExtension), options: o)
        } }
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

@Suite("Writing cpio and Apple Archive (also AEA)")
struct CpioAppleArchiveWriteTests {
    func tree(_ t: TempDir) -> [UInt8] {
        t.write("src/a.txt", String(repeating: "Apple Archive ", count: 5000))
        t.write("src/sub/b.bin", sampleData(900 << 10, seed: 31))
        t.symlink("src/link", to: "a.txt")
        let v = Array("Verde\n2".utf8)
        _ = v.withUnsafeBytes { setxattr(t.path + "/src/a.txt", "app.xipper.aar", $0.baseAddress, v.count, 0, 0) }
        return v
    }

    @Test(arguments: [1, 6, 9])
    func appleArchiveReadByAaAndUs(level: Int) throws {
        let t = TempDir()
        let v = tree(t)
        var o = CreateOptions()
        o.format = .appleArchive
        o.level = level
        try Xipper.create(from: [t.url("src")], to: t.url("a.aar"), options: o)
        #expect(try ArchiveFormat.detect(t.url("a.aar")) == .appleArchive)
        #expect(try Xipper.test(t.url("a.aar")).isOK)
        // macOS's own tool extracts it, attributes included.
        t.mkdir("aa")
        #expect(run("/usr/bin/aa", ["extract", "-i", t.path + "/a.aar", "-d", t.path + "/aa"]).status == 0)
        #expect(treesEqual(t.path + "/src", t.path + "/aa/src").0)
        #expect(ExtendedAttributes.read(t.path + "/aa/src/a.txt").first { $0.name == "app.xipper.aar" }?.value == v)
        t.mkdir("ours")
        try Xipper.extract(t.url("a.aar"), to: t.url("ours"), mode: .into)
        #expect(treesEqual(t.path + "/src", t.path + "/ours/src").0)
        #expect(ExtendedAttributes.read(t.path + "/ours/src/a.txt").first { $0.name == "app.xipper.aar" }?.value == v)
    }

    @Test func encryptedAEAWithPassword() throws {
        let t = TempDir()
        _ = tree(t)
        var o = CreateOptions()
        o.format = .appleArchive
        #expect(throws: XipperError.self) {  // AEA needs at least 20 bytes
            var short = CreateOptions()
            short.format = .appleArchive
            short.password = "corta"
            try Xipper.create(from: [t.url("src")], to: t.url("short.aar"), options: short)
        }
        o.password = "una parola segreta lunga"
        try Xipper.create(from: [t.url("src")], to: t.url("s.aar"), options: o)
        let bytes = try Data(contentsOf: t.url("s.aar"))
        #expect(bytes.starts(with: Array("AEA1".utf8)))
        #expect(bytes.range(of: Data("b.bin".utf8)) == nil)  // names are encrypted too
        #expect(throws: XipperError.passwordRequired(entry: "s.aar")) { _ = try Xipper.list(t.url("s.aar")) }
        #expect(throws: XipperError.self) { _ = try Xipper.test(t.url("s.aar"), password: "sbagliata") }
        #expect(try Xipper.test(t.url("s.aar"), password: "una parola segreta lunga").isOK)
        // macOS decrypts it with aea and the same password.
        #expect(run("/usr/bin/aea", ["decrypt", "-i", t.path + "/s.aar", "-o", t.path + "/plain.aar",
                                     "-password-value", "una parola segreta lunga"]).status == 0)
        t.mkdir("aa")
        #expect(run("/usr/bin/aa", ["extract", "-i", t.path + "/plain.aar", "-d", t.path + "/aa"]).status == 0)
        #expect(treesEqual(t.path + "/src", t.path + "/aa/src").0)
        t.mkdir("ours")
        var x = ExtractOptions()
        x.password = "una parola segreta lunga"
        try Xipper.extract(t.url("s.aar"), to: t.url("ours"), mode: .into, options: x)
        #expect(treesEqual(t.path + "/src", t.path + "/ours/src").0)
    }

    @Test(.enabled(if: toolExists("/usr/bin/cpio")))
    func cpioReadByCpio() throws {
        let t = TempDir()
        _ = tree(t)
        var o = CreateOptions()
        o.format = .cpio
        try Xipper.create(from: [t.url("src")], to: t.url("c.cpio"), options: o)
        #expect(try Xipper.test(t.url("c.cpio")).isOK)
        t.mkdir("cp")
        #expect(run("/bin/sh", ["-c", "/usr/bin/cpio -idm < ../c.cpio"], cwd: t.path + "/cp").status == 0)
        #expect(treesEqual(t.path + "/src", t.path + "/cp/src").0)
    }
}
