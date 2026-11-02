import CryptoKit
import Foundation
import Testing
@testable import XipperKit

/// «Cambia formato»: entries with a codec both formats share keep their compressed bytes, the
/// rest is recompressed, the result is verified before it gets its name, the source is untouched.
@Suite("Changing an archive's format")
struct ConvertTests {
    func zip(_ t: TempDir, method: ZipMethod = .deflate, password: String? = nil, name: String = "a.zip") throws -> URL {
        var o = CreateOptions()
        o.format = .zip
        o.zipMethod = method
        o.password = password
        let url = t.url(name)
        try Xipper.create(from: [t.url("src")], to: url, options: o)
        return url
    }

    func options(_ format: ArchiveFormat, password: String? = nil) -> CreateOptions {
        var o = CreateOptions()
        o.format = format
        o.password = password
        return o
    }

    /// SHA-256 of each file entry's compressed bytes, by path.
    func payloads(_ url: URL) throws -> [String: String] {
        let z = try ZipArchive(path: url.path)
        var out: [String: String] = [:]
        for r in z.records where r.entry.kind == .file && r.entry.uncompressedSize > 0 {
            let bytes = try z.reader.read(at: try z.dataOffset(r), count: Int(r.compressedSize))
            out[r.entry.path] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
        return out
    }

    func extractsToSource(_ t: TempDir, _ url: URL, password: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let out = "x-" + url.lastPathComponent
        t.mkdir(out)
        var eo = ExtractOptions()
        eo.password = password
        let r = try Xipper.extract(url, to: t.url(out), options: eo)
        let (same, diff) = treesEqual(t.path + "/src", r.destination.path)
        #expect(same, "\(url.lastPathComponent): \(diff)", sourceLocation: sourceLocation)
    }

    @Test(arguments: [ZipMethod.deflate, .store, .bzip2, .deflate64, .lzma])
    func zipToSevenZipCopiesTheCompressedBytes(method: ZipMethod) throws {
        let t = TempDir()
        makeTree(t, bigSize: 3 << 20)
        let a = try zip(t, method: method)
        let before = try Data(contentsOf: a)
        let plan = try Xipper.conversionPlan(a, to: .sevenZip)
        #expect(plan.recompressed == 0, "\(plan.items.filter { $0.action == .recompressed }.map { "\($0.path): \($0.reason ?? "")" })")
        #expect(plan.copied >= 4)
        let r = try Xipper.convert(a, to: t.url("a.7z"), options: options(.sevenZip))
        #expect(r.plan.copied == plan.copied)
        try extractsToSource(t, t.url("a.7z"))
        #expect(try Data(contentsOf: a) == before, "the source changed")
        if let sz = sevenZip { #expect(run(sz, ["t", t.path + "/a.7z"]).status == 0) }

        // And back: the ZIP entries carry exactly the bytes of the first ZIP.
        let back = try Xipper.convert(t.url("a.7z"), to: t.url("back.zip"), options: options(.zip))
        #expect(back.plan.recompressed == 0)
        #expect(try payloads(t.url("back.zip")) == payloads(a))
        try extractsToSource(t, t.url("back.zip"))
        if method == .deflate || method == .store { #expect(run("/usr/bin/unzip", ["-tq", t.path + "/back.zip"]).status == 0) }
        if let sz = sevenZip { #expect(run(sz, ["t", t.path + "/back.zip"]).status == 0) }
    }

    /// bsdtar (libarchive) extracts `url` to the same tree as `src`.
    func bsdtarExtractsToSource(_ t: TempDir, _ url: URL, sourceLocation: SourceLocation = #_sourceLocation) {
        let out = "bsd-" + url.lastPathComponent
        t.mkdir(out)
        let r = run("/usr/bin/bsdtar", ["-xf", url.path, "-C", t.path + "/" + out])
        #expect(r.status == 0, "\(r)", sourceLocation: sourceLocation)
        let (same, diff) = treesEqual(t.path + "/src", t.path + "/" + out + "/src")
        #expect(same, "\(url.lastPathComponent): \(diff)", sourceLocation: sourceLocation)
    }

    @Test func sevenZipLZMA2BecomesZipXzWithoutRecompressing() throws {
        let t = TempDir()
        makeTree(t, bigSize: 3 << 20)
        var o = options(.sevenZip)
        o.solidBlockSize = 0
        try Xipper.create(from: [t.url("src")], to: t.url("a.7z"), options: o)
        let plan = try Xipper.conversionPlan(t.url("a.7z"), to: .zip)
        #expect(plan.recompressed == 0, "\(plan.items.filter { $0.action == .recompressed }.map { "\($0.path): \($0.reason ?? "")" })")
        try Xipper.convert(t.url("a.7z"), to: t.url("a.zip"), options: options(.zip))
        let z = try ZipArchive(path: t.path + "/a.zip")
        #expect(z.records.filter { $0.method == Zip.Method.xz.rawValue }.count >= 3)
        try extractsToSource(t, t.url("a.zip"))
        bsdtarExtractsToSource(t, t.url("a.zip"))
        if let sz = sevenZip { #expect(run(sz, ["t", t.path + "/a.zip"]).status == 0) }
    }

    /// Deflate, bzip2, zstd and xz ZIP entries become members of the tar's compressed stream.
    @Test(arguments: [(ZipMethod.deflate, ArchiveFormat.tarGzip), (.bzip2, .tarBzip2), (.zstd, .tarZstd), (.xz, .tarXz)])
    func zipToTarCopiesEntriesAsMembers(method: ZipMethod, format: ArchiveFormat) throws {
        let t = TempDir()
        makeTree(t, bigSize: 3 << 20)
        let a = try zip(t, method: method)
        let plan = try Xipper.conversionPlan(a, to: format)
        #expect(plan.copied >= 2)
        // Only what the ZIP stored (tiny files, the JPEG-like one) is compressed again.
        #expect(plan.items.filter { $0.action == .recompressed }.allSatisfy { $0.reason?.hasPrefix("store") == true })
        let target = t.url("a." + format.fileExtension)
        try Xipper.convert(a, to: target, options: options(format))
        try extractsToSource(t, target)
        if format != .tarZstd { bsdtarExtractsToSource(t, target) }  // macOS bsdtar runs an external zstd for .zst
    }

    @Test func zipZstdToXizCopiesFrames() throws {
        let t = TempDir()
        makeTree(t, bigSize: 3 << 20)
        let a = try zip(t, method: .zstd)
        let plan = try Xipper.conversionPlan(a, to: .xiz)
        #expect(plan.copied >= 2)
        try Xipper.convert(a, to: t.url("a.xiz"), options: options(.xiz))
        #expect(try Xipper.test(t.url("a.xiz"), digests: true).isOK)
        try extractsToSource(t, t.url("a.xiz"))
        // With LZMA2 chosen nothing is copied.
        var o = options(.xiz)
        o.xizCodec = .lzma2
        #expect(try Xipper.conversionPlan(a, to: .xiz, options: o).copied == 0)
    }

    @Test func solidSevenZipToZipIsRecompressed() throws {
        let t = TempDir()
        makeTree(t, bigSize: 1 << 20)
        var o = options(.sevenZip)
        o.solidBlockSize = 64 << 20
        try Xipper.create(from: [t.url("src")], to: t.url("s.7z"), options: o)
        let plan = try Xipper.conversionPlan(t.url("s.7z"), to: .zip)
        // The solid LZMA2 block is recompressed; the JPEG-like file Xipper stored in a folder of
        // its own (Copy coder) is copied.
        #expect(plan.recompressed >= 3)
        #expect(plan.items.filter { $0.action == .recompressed }.allSatisfy { $0.reason?.contains("solid") == true })
        #expect(plan.items.filter { $0.action == .copied }.map { ($0.path as NSString).lastPathComponent } == ["random.jpg"])
        try Xipper.convert(t.url("s.7z"), to: t.url("s.zip"), options: options(.zip))
        try extractsToSource(t, t.url("s.zip"))
        #expect(run("/usr/bin/unzip", ["-tq", t.path + "/s.zip"]).status == 0)
    }

    @Test(arguments: [ArchiveFormat.tarZstd, .tarGzip, .xiz, .appleArchive, .cpio, .zip, .sevenZip])
    func everyTargetHoldsTheSameTree(format: ArchiveFormat) throws {
        let t = TempDir()
        makeTree(t, bigSize: 1 << 20)
        var o = options(.tarXz)
        let source = t.url("a.tar.xz")
        o.format = .tarXz
        try Xipper.create(from: [t.url("src")], to: source, options: o)
        let target = t.url("out." + format.fileExtension)
        let r = try Xipper.convert(source, to: target, options: options(format))
        #expect(r.plan.copied == 0)
        try extractsToSource(t, target)
    }

    @Test func passwordsOnEitherSide() throws {
        let t = TempDir()
        makeTree(t, bigSize: 1 << 20)
        let locked = try zip(t, password: "segreta")
        // Encrypted source, plain target: decrypted, and the plan says the encryption goes away.
        let plan = try Xipper.conversionPlan(locked, to: .sevenZip, password: "segreta")
        #expect(plan.losses.contains(.encryption))
        #expect(plan.copied == 0)
        try Xipper.convert(locked, to: t.url("plain.7z"), password: "segreta", options: options(.sevenZip))
        try extractsToSource(t, t.url("plain.7z"))
        // Plain source, encrypted target: nothing can be copied in clear.
        let open = try zip(t, name: "open.zip")
        let p2 = try Xipper.conversionPlan(open, to: .sevenZip, options: options(.sevenZip, password: "nuova"))
        #expect(p2.copied == 0)
        try Xipper.convert(open, to: t.url("locked.7z"), options: options(.sevenZip, password: "nuova"))
        #expect(throws: (any Error).self) { try Xipper.test(t.url("locked.7z")) }
        try extractsToSource(t, t.url("locked.7z"), password: "nuova")
    }

    @Test func refusesToOverwriteAndLeavesNothingBehindWhenCancelled() throws {
        let t = TempDir()
        makeTree(t, bigSize: 8 << 20)
        let a = try zip(t)
        let before = try Data(contentsOf: a)
        t.write("exists.7z", "keep me")
        #expect(throws: XipperError.self) { try Xipper.convert(a, to: t.url("exists.7z"), options: options(.sevenZip)) }
        #expect(FileManager.default.contents(atPath: t.path + "/exists.7z") == Data("keep me".utf8))

        let cancel = CancellationToken()
        cancel.cancel()
        #expect(throws: (any Error).self) { try Xipper.convert(a, to: t.url("never.tar.zst"), options: options(.tarZstd), cancel: cancel) }
        #expect(!FileManager.default.fileExists(atPath: t.path + "/never.tar.zst"))
        #expect(try Data(contentsOf: a) == before)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: t.path).filter { $0.hasPrefix(".xipper-convert") }
        #expect(leftovers.isEmpty)
    }

    @Test func sameNameAndSingleFileSourcesAreRefused() throws {
        let t = TempDir()
        makeTree(t, bigSize: 1000)
        let a = try zip(t)
        #expect(throws: XipperError.self) { try Xipper.convert(a, to: a, options: options(.zip)) }
        t.write("one.txt", "x")
        var o = options(.gzip)
        try Xipper.create(from: [t.url("one.txt")], to: t.url("one.txt.gz"), options: o)
        o.format = .zip
        #expect(throws: XipperError.self) { try Xipper.conversionPlan(t.url("one.txt.gz"), to: .zip) }
    }

    /// Killed at any moment (SIGKILL: no cleanup code runs), the conversion leaves the source as
    /// it was and no file under the target name; the next conversion removes the work folder.
    @Test(.enabled(if: CLITests.exe != nil), .timeLimit(.minutes(3)))
    func killedMidwayLosesNothing() throws {
        let t = TempDir()
        t.write("src/big.bin", sampleData(48 << 20, seed: 5))
        t.write("src/small.txt", "small\n")
        let a = try zip(t)
        let digest = SHA256.hash(data: try Data(contentsOf: a))
        for delay in [0.02, 0.15, 0.4, 0.8] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: CLITests.exe!)
            p.arguments = ["convert", a.path, "--to", "tar.xz", "-o", t.path + "/out.tar.xz", "-q"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            Thread.sleep(forTimeInterval: delay)
            kill(p.processIdentifier, SIGKILL)
            p.waitUntilExit()
            #expect(SHA256.hash(data: try Data(contentsOf: a)) == digest, "source changed (killed after \(delay)s)")
            if FileManager.default.fileExists(atPath: t.path + "/out.tar.xz") {
                // It finished before the kill: then it is complete and verified.
                #expect(try Xipper.test(t.url("out.tar.xz")).isOK)
                try FileManager.default.removeItem(atPath: t.path + "/out.tar.xz")
            }
        }
        try Xipper.convert(a, to: t.url("final.tar.zst"), options: options(.tarZstd))
        let left = try FileManager.default.contentsOfDirectory(atPath: t.path).filter { $0.hasPrefix(".xipper-convert") }
        #expect(left.isEmpty, "\(left)")
        try extractsToSource(t, t.url("final.tar.zst"))
    }
}
