import Foundation
import Testing
@testable import XipperKit

@Suite("Round trips and foreign archives")
struct RoundTripTests {
    static let formats: [ArchiveFormat] = [.zip, .tar, .tarGzip, .tarBzip2, .tarXz, .tarZstd]

    @Test(arguments: formats)
    func roundTrip(format: ArchiveFormat) throws {
        let t = TempDir()
        makeTree(t)
        var o = CreateOptions()
        o.format = format
        o.workload = .threads(4)
        let archive = t.url("out." + format.fileExtension)
        try Xipper.create(from: [t.url("src")], to: archive, options: o)
        #expect(try ArchiveFormat.detect(archive) == format)

        let test = try Xipper.test(archive)
        #expect(test.isOK, "\(test.failures)")
        let list = try Xipper.list(archive)
        #expect(list.contains { $0.path == "src/link-to-readme" && $0.kind == .symlink })
        #expect(list.contains { $0.path == "src/emptydir" && $0.kind == .directory })

        t.mkdir("x")
        let report = try Xipper.extract(archive, to: t.url("x"))
        #expect(report.destination.lastPathComponent == "src")  // single top-level item → placed directly
        #expect(report.skipped.isEmpty, "\(report.skipped)")
        let (same, diff) = treesEqual(t.path + "/src", t.path + "/x/src")
        #expect(same, "\(diff)")

        // Second extraction into the same folder keeps both.
        let again = try Xipper.extract(archive, to: t.url("x"))
        #expect(again.destination.lastPathComponent == "src 2")
    }

    @Test(arguments: [ZipMethod.deflate, .zstd, .store, .bzip2, .lzma, .xz])
    func zipMethodsWithPassword(method: ZipMethod) throws {
        let t = TempDir()
        makeTree(t, bigSize: 13 << 20)
        var o = CreateOptions()
        o.zipMethod = method
        o.password = "Passw0rd-xipper"
        let archive = t.url("enc.zip")
        try Xipper.create(from: [t.url("src")], to: archive, options: o)
        #expect(throws: XipperError.self) { try Xipper.test(archive) }
        let wrong = try Xipper.test(archive, password: "nope")
        #expect(!wrong.isOK)
        #expect(try Xipper.test(archive, password: "Passw0rd-xipper").isOK)
        var eo = ExtractOptions()
        eo.password = "Passw0rd-xipper"
        let r = try Xipper.extract(archive, to: t.url(""), options: eo)
        let (same, diff) = treesEqual(t.path + "/src", r.destination.path)
        #expect(same, "\(diff)")
    }

    @Test func readsArchivesFromInfoZipDittoAnd7Zip() throws {
        let t = TempDir()
        makeTree(t)
        // Info-ZIP (symlinks with -y), ditto, 7-Zip AES + LZMA/BZip2/zstd methods.
        var made: [(String, String?)] = []
        run("/usr/bin/zip", ["-r", "-y", "-q", t.path + "/infozip.zip", "src"], cwd: t.path)
        made.append(("infozip.zip", nil))
        run("/usr/bin/ditto", ["-c", "-k", "--keepParent", t.path + "/src", t.path + "/ditto.zip"])
        made.append(("ditto.zip", nil))
        if let sz = sevenZip {
            for (name, args) in [("7z-aes.zip", ["-mem=AES256", "-pPassw0rd-xipper"]), ("7z-lzma.zip", ["-mm=LZMA"]),
                                 ("7z-bzip2.zip", ["-mm=BZip2"]), ("7z-zipcrypto.zip", ["-mem=ZipCrypto", "-pPassw0rd-xipper"])] {
                run(sz, ["a", "-tzip", "-snl"] + args + [t.path + "/" + name, "src"], cwd: t.path)
                made.append((name, args.contains { $0.hasPrefix("-p") } ? "Passw0rd-xipper" : nil))
            }
        }
        for (name, pw) in made {
            let url = t.url(name)
            let test = try Xipper.test(url, password: pw)
            #expect(test.isOK, "\(name): \(test.failures)")
            var eo = ExtractOptions()
            eo.password = pw
            t.mkdir("out-" + name)
            let r = try Xipper.extract(url, to: t.url("out-" + name), options: eo)
            let (same, diff) = treesEqual(t.path + "/src", r.destination.path)
            #expect(same, "\(name): \(diff)")
        }
    }

    @Test func readsTarFromBsdtar() throws {
        let t = TempDir()
        makeTree(t)
        for (name, flag) in [("b.tar", ""), ("b.tar.gz", "z"), ("b.tar.bz2", "j"), ("b.tar.xz", "J")] {
            run("/usr/bin/tar", ["-c\(flag)f", t.path + "/" + name, "src"], cwd: t.path)
            t.mkdir("o-" + name)
            let r = try Xipper.extract(t.url(name), to: t.url("o-" + name))
            let (same, diff) = treesEqual(t.path + "/src", r.destination.path)
            #expect(same, "\(name): \(diff)")
        }
    }

    /// Methods 12, 14 and 95, with entries big enough for the chunked paths (bzip2 blocks joined
    /// into one stream, xz blocks under one index) and the streamed LZMA path.
    @Test(arguments: [ZipMethod.bzip2, .lzma, .xz])
    func sevenZipAndBsdtarReadOurZipMethods(method: ZipMethod) throws {
        let t = TempDir()
        makeTree(t, bigSize: 36 << 20)
        var o = CreateOptions()
        o.zipMethod = method
        o.level = 1
        o.storeAlreadyCompressed = false
        let archive = t.url("m.zip")
        try Xipper.create(from: [t.url("src")], to: archive, options: o)
        #expect(try Xipper.list(archive).contains { $0.path == "src/data/big.bin" && $0.method == method.name })
        #expect(try Xipper.test(archive).isOK)
        t.mkdir("bsd")
        let r = run("/usr/bin/tar", ["-xf", archive.path, "-C", t.path + "/bsd"])
        #expect(r.status == 0, "\(r.output)")
        var (same, diff) = treesEqual(t.path + "/src", t.path + "/bsd/src")
        #expect(same, "\(diff)")
        if let sevenZip {
            let s = run(sevenZip, ["x", "-y", "-o" + t.path + "/7z", archive.path])
            #expect(s.status == 0, "\(s.output)")
            (same, diff) = treesEqual(t.path + "/src", t.path + "/7z/src")
            #expect(same, "\(diff)")
        }
    }

    @Test(arguments: [ArchiveFormat.tarGzip, .tarBzip2, .tarXz, .tarZstd])
    func bsdtarReadsOurTars(format: ArchiveFormat) throws {
        let t = TempDir()
        makeTree(t)
        var o = CreateOptions()
        o.format = format
        let archive = t.url("o." + format.fileExtension)
        try Xipper.create(from: [t.url("src")], to: archive, options: o)
        t.mkdir("bsd")
        let r = run("/usr/bin/tar", ["-xf", archive.path, "-C", t.path + "/bsd"])
        if format == .tarZstd && r.status != 0 && r.output.contains("zstd") { return }  // system bsdtar without zstd
        #expect(r.status == 0, "\(r.output)")
        let (same, diff) = treesEqual(t.path + "/src", t.path + "/bsd/src")
        #expect(same, "\(diff)")
    }

    @Test(arguments: [ArchiveFormat.gzip, .bzip2, .xz, .zstd])
    func singleFileCompression(format: ArchiveFormat) throws {
        let t = TempDir()
        let data = sampleData(3 << 20)
        t.write("doc.bin", data)
        var o = CreateOptions()
        o.format = format
        let archive = t.url("doc.bin." + format.fileExtension)
        try Xipper.create(from: [t.url("doc.bin")], to: archive, options: o)
        #expect(try Xipper.test(archive).isOK)
        t.mkdir("x")
        let r = try Xipper.extract(archive, to: t.url("x"))
        #expect(r.destination.lastPathComponent == "doc.bin")
        #expect(FileManager.default.contents(atPath: r.destination.path) == Data(data))
        if format == .gzip {
            #expect(run("/usr/bin/gzip", ["-t", archive.path]).status == 0)
        }
    }
}

@Suite("Codec edge cases")
struct CodecEdgeTests {
    /// Regression: a zstd frame whose last block exactly fills the 1 MiB output buffer was
    /// reported as truncated (the decoder was called once more and asked for a new frame).
    @Test func zstdFrameEndingOnOutputBoundary() throws {
        for size in [1 << 20, 2 << 20, (1 << 20) - 1, (1 << 20) + 1] {
            let data = sampleData(size)
            let enc = try ZstdEncoder(level: 3, threads: 1)
            var compressed: [UInt8] = []
            try data.withUnsafeBytes { try enc.process($0) { compressed += $0 } }
            try enc.finish { compressed += $0 }
            let dec = try ZstdDecoder()
            var out: [UInt8] = []
            try compressed.withUnsafeBytes { try dec.process($0) { out += $0 } }
            try dec.finish { out += $0 }
            #expect(out == data, "size \(size)")
        }
    }

    @Test func gzipParallelMatchesSystemGunzip() throws {
        let t = TempDir()
        let data = sampleData(7 << 20 + 12345)
        let enc = ParallelGzipEncoder(level: 6, workload: .threads(4), cancel: nil)
        var gz: [UInt8] = []
        try data.withUnsafeBytes { try enc.process($0) { gz += $0 } }
        try enc.finish { gz += $0 }
        t.write("x.gz", gz)
        let r = run("/usr/bin/gzip", ["-t", t.path + "/x.gz"])
        #expect(r.status == 0, "\(r.output)")
        let dec = try InflateDecoder(gzip: true)
        var out: [UInt8] = []
        try gz.withUnsafeBytes { try dec.process($0) { out += $0 } }
        try dec.finish { out += $0 }
        #expect(out == data)
    }

    @Test func winZipAESCounterIsLittleEndian() throws {
        // CTR keystream must be identical whatever the call granularity.
        let key = [UInt8](repeating: 7, count: 32)
        var a = sampleData(100_003), b = a
        let c1 = try AESCTRLittleEndian(key: key)
        a.withUnsafeMutableBytes { c1.apply($0) }
        let c2 = try AESCTRLittleEndian(key: key)
        var pos = 0
        for step in [1, 15, 16, 17, 4096, 70000] where pos < b.count {
            let n = min(step, b.count - pos)
            b.withUnsafeMutableBytes { c2.apply(UnsafeMutableRawBufferPointer(rebasing: $0[pos..<pos + n])) }
            pos += n
        }
        b.withUnsafeMutableBytes { c2.apply(UnsafeMutableRawBufferPointer(rebasing: $0[pos...])) }
        #expect(a == b)
    }
}

@Suite("macOS extended attributes in tar")
struct ExtendedAttributeTests {
    @Test(arguments: [ArchiveFormat.tar, .tarZstd])
    func finderTagsAndBinaryAttributesSurvive(format: ArchiveFormat) throws {
        let t = TempDir()
        t.write("src/doc.txt", "tagged")
        t.mkdir("src/folder")
        let tags = Array("bplist00\u{A1}\u{01}_\u{10}\u{05}Rosso\n6\u{08}\u{0A}".utf8)
        let binary: [UInt8] = (0..<300).map { UInt8($0 % 256) }  // NUL, newline and '=' bytes included
        for (path, name, value) in [(t.path + "/src/doc.txt", "com.apple.metadata:_kMDItemUserTags", tags),
                                    (t.path + "/src/doc.txt", "app.xipper.test", binary),
                                    (t.path + "/src/folder", "app.xipper.dir", Array("dir".utf8)),
                                    (t.path + "/src/doc.txt", "com.apple.quarantine", Array("0081;0;Test;".utf8))] {
            #expect(value.withUnsafeBytes { setxattr(path, name, $0.baseAddress, value.count, 0, 0) } == 0)
        }
        var o = CreateOptions()
        o.format = format
        let archive = t.url("a." + format.fileExtension)
        try Xipper.create(from: [t.url("src")], to: archive, options: o)
        t.mkdir("out")
        var x = ExtractOptions()
        x.propagateQuarantine = false
        try Xipper.extract(archive, to: t.url("out"), mode: .into, options: x)
        let file = t.path + "/out/src/doc.txt"
        #expect(ExtendedAttributes.read(file).first { $0.name == "com.apple.metadata:_kMDItemUserTags" }?.value == tags)
        #expect(ExtendedAttributes.read(file).first { $0.name == "app.xipper.test" }?.value == binary)
        #expect(ExtendedAttributes.read(t.path + "/out/src/folder").first { $0.name == "app.xipper.dir" } != nil)
        // Quarantine never travels inside the archive.
        #expect(getxattr(file, "com.apple.quarantine", nil, 0, 0, 0) < 0)
    }

    @Test(.enabled(if: toolExists("/usr/bin/tar")))
    func bsdtarSeesOurAttributes() throws {
        let t = TempDir()
        t.write("src/doc.txt", "x")
        let v = Array("hello".utf8)
        _ = v.withUnsafeBytes { setxattr(t.path + "/src/doc.txt", "app.xipper.bsd", $0.baseAddress, v.count, 0, 0) }
        var o = CreateOptions()
        o.format = .tar
        try Xipper.create(from: [t.url("src")], to: t.url("a.tar"), options: o)
        t.mkdir("bsd")
        // macOS tar restores pax attributes with --xattrs (by default it only uses AppleDouble ._ files).
        #expect(run("/usr/bin/tar", ["--xattrs", "-xf", t.path + "/a.tar", "-C", t.path + "/bsd"]).status == 0)
        #expect(ExtendedAttributes.read(t.path + "/bsd/src/doc.txt").first { $0.name == "app.xipper.bsd" }?.value == v)
    }
}

@Suite("AppleDouble from Finder and macOS tar")
struct AppleDoubleTests {
    func taggedFolder(_ t: TempDir) -> [UInt8] {
        t.write("src/doc.txt", "tagged")
        let v = Array("Rosso\n6".utf8)
        _ = v.withUnsafeBytes { setxattr(t.path + "/src/doc.txt", "app.xipper.ad", $0.baseAddress, v.count, 0, 0) }
        return v
    }

    /// `ditto -c -k --sequesterRsrc` writes ZIPs like the Finder's "Compress": metadata in __MACOSX/…/._name.
    @Test(.enabled(if: toolExists("/usr/bin/ditto")))
    func finderZipMetadataIsMergedNotExtracted() throws {
        let t = TempDir()
        let v = taggedFolder(t)
        #expect(run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", t.path + "/src", t.path + "/f.zip"]).status == 0)
        #expect(try Xipper.list(t.url("f.zip")).contains { $0.path.hasPrefix("__MACOSX") })
        t.mkdir("out")
        try Xipper.extract(t.url("f.zip"), to: t.url("out"), mode: .into)
        #expect(!FileManager.default.fileExists(atPath: t.path + "/out/__MACOSX"))
        #expect(ExtendedAttributes.read(t.path + "/out/src/doc.txt").first { $0.name == "app.xipper.ad" }?.value == v)
    }

    /// Our ZIPs with `zipAppleDouble`: the Finder (`ditto -x -k`) and Xipper both restore the attributes.
    @Test(.enabled(if: toolExists("/usr/bin/ditto")))
    func ourAppleDoubleZipIsReadByDittoAndByUs() throws {
        let t = TempDir()
        let v = taggedFolder(t)
        let rf: [UInt8] = Array(repeating: 0xAB, count: 1000)
        _ = rf.withUnsafeBytes { setxattr(t.path + "/src/doc.txt", "com.apple.ResourceFork", $0.baseAddress, rf.count, 0, 0) }
        var o = CreateOptions()
        o.zipAppleDouble = true
        try Xipper.create(from: [t.url("src")], to: t.url("a.zip"), options: o)
        #expect(try Xipper.list(t.url("a.zip")).contains { $0.path == "__MACOSX/src/._doc.txt" })
        #expect(run("/usr/bin/ditto", ["-x", "-k", t.path + "/a.zip", t.path + "/ditto"]).status == 0)
        #expect(ExtendedAttributes.read(t.path + "/ditto/src/doc.txt").first { $0.name == "app.xipper.ad" }?.value == v)
        #expect(ExtendedAttributes.read(t.path + "/ditto/src/doc.txt").first { $0.name == "com.apple.ResourceFork" }?.value == rf)
        t.mkdir("ours")
        try Xipper.extract(t.url("a.zip"), to: t.url("ours"), mode: .into)
        #expect(ExtendedAttributes.read(t.path + "/ours/src/doc.txt").first { $0.name == "app.xipper.ad" }?.value == v)
        #expect(!FileManager.default.fileExists(atPath: t.path + "/ours/__MACOSX"))
        // Off by default: plain ZIPs for Windows.
        try Xipper.create(from: [t.url("src")], to: t.url("plain.zip"))
        #expect(!(try Xipper.list(t.url("plain.zip")).contains { $0.path.hasPrefix("__MACOSX") }))
    }

    /// macOS tar (bsdtar with copyfile) stores attributes as "._name" entries next to the file.
    @Test(.enabled(if: toolExists("/usr/bin/tar")))
    func macTarDotUnderscoreIsMerged() throws {
        let t = TempDir()
        let v = taggedFolder(t)
        #expect(run("/usr/bin/tar", ["-cf", t.path + "/m.tar", "src"], cwd: t.path).status == 0)
        #expect(try Xipper.list(t.url("m.tar")).contains { $0.path.hasSuffix("._doc.txt") })
        t.mkdir("out")
        try Xipper.extract(t.url("m.tar"), to: t.url("out"), mode: .into)
        #expect(!FileManager.default.fileExists(atPath: t.path + "/out/src/._doc.txt"))
        #expect(ExtendedAttributes.read(t.path + "/out/src/doc.txt").first { $0.name == "app.xipper.ad" }?.value == v)
    }
}

/// Progress of the multi-threaded stream encoders follows the compressed data, not the buffered input.
@Suite("Progress of tar.xz and tar.zst")
struct StreamProgressTests {
    final class Snapshots: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [ProgressSnapshot] = []
        func add(_ s: ProgressSnapshot) { lock.lock(); values.append(s); lock.unlock() }
        var all: [ProgressSnapshot] { lock.lock(); defer { lock.unlock() }; return values }
    }

    @Test(arguments: [ArchiveFormat.tarXz, .tarZstd])
    func monotonicAndComplete(format: ArchiveFormat) throws {
        let t = TempDir()
        t.write("src/a.bin", sampleData(24 << 20, seed: 41))
        t.write("src/b.txt", String(repeating: "progress\n", count: 200_000))
        let seen = Snapshots()
        var o = CreateOptions()
        o.format = format
        o.level = format == .tarXz ? 1 : 3
        o.workload = .threads(4)
        try Xipper.create(from: [t.url("src")], to: t.url("p." + format.fileExtension), options: o, progress: { seen.add($0) })
        let all = seen.all
        #expect(zip(all, all.dropFirst()).allSatisfy { $0.completedBytes <= $1.completedBytes })
        #expect(all.last.map { $0.completedBytes == $0.totalBytes } == true)
        #expect(try Xipper.test(t.url("p." + format.fileExtension)).isOK)
    }

    @Test func encoderBacklogDrainsToZero() throws {
        let data = sampleData(16 << 20, seed: 42)
        for encoder in [try LZMACoder.xzEncoder(preset: 1, threads: 4) as StreamTransform, try ZstdEncoder(level: 3, threads: 4)] {
            var out = 0
            try data.withUnsafeBytes { try encoder.process($0) { out += $0.count } }
            #expect(encoder.backlog >= 0 && encoder.backlog <= Int64(data.count))
            try encoder.finish { out += $0.count }
            #expect(encoder.backlog == 0)
            #expect(out > 0)
        }
    }
}
