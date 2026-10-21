import Foundation
import Testing
@testable import XipperKit

@Suite("7z")
struct SevenZipTests {
    /// Tree with an arm64 executable (for the ARM64 filter) and an already-compressed file.
    func tree(_ t: TempDir, bigSize: Int = 6 << 20) {
        makeTree(t, bigSize: bigSize)
        try! FileManager.default.copyItem(atPath: "/bin/ls", toPath: t.path + "/src/ls")
        t.write("src/data/notes.md", Array(String(repeating: "PPMd likes text. ", count: 20_000).utf8))
    }

    func create(_ t: TempDir, _ name: String, configure: (inout CreateOptions) -> Void = { _ in }) throws -> URL {
        var o = CreateOptions()
        o.format = .sevenZip
        o.workload = .threads(4)
        configure(&o)
        let url = t.url(name)
        try Xipper.create(from: [t.url("src")], to: url, options: o)
        return url
    }

    func extractAndCompare(_ t: TempDir, _ archive: URL, password: String? = nil, file: String = #filePath, line: Int = #line) throws {
        var eo = ExtractOptions()
        eo.password = password
        let dest = "x-\(UUID().uuidString.prefix(6))"
        t.mkdir(dest)
        let r = try Xipper.extract(archive, to: t.url(dest), options: eo)
        #expect(r.skipped.isEmpty, "\(r.skipped)")
        let (same, diff) = treesEqual(t.path + "/src", t.path + "/\(dest)/src")
        #expect(same, "\(diff)")
    }

    // MARK: round trips

    static let solidModes: [(String, Int64?)] = [("solid", nil), ("non-solid", 0), ("small blocks", 1 << 20)]

    @Test(arguments: solidModes)
    func roundTrip(name: String, solid: Int64?) throws {
        let t = TempDir()
        tree(t)
        let a = try create(t, "out.7z") { $0.solidBlockSize = solid }
        #expect(try ArchiveFormat.detect(a) == .sevenZip)
        #expect(try Xipper.test(a).isOK)
        let list = try Xipper.list(a)
        #expect(list.contains { $0.path == "src/link-to-readme" && $0.kind == .symlink })
        #expect(list.contains { $0.path == "src/emptydir" && $0.kind == .directory })
        #expect(list.contains { $0.path == "src/empty.bin" && $0.kind == .file && $0.uncompressedSize == 0 })
        #expect(list.first { $0.path == "src/ls" }?.method.contains("ARM64") == true)
        #expect(list.first { $0.path == "src/data/random.jpg" }?.method == "Copy")
        try extractAndCompare(t, a)
        let entry = try Xipper.readEntry(a, path: "src/data/small.bin")
        #expect(entry.data == sampleData(5000, seed: 7))
    }

    @Test func levelsAndStore() throws {
        let t = TempDir()
        tree(t, bigSize: 1 << 20)
        for level in [0, 1, 9] {
            let a = try create(t, "l\(level).7z") { $0.level = level }
            #expect(try Xipper.test(a).isOK)
            try extractAndCompare(t, a)
            if level == 0 { #expect(try Xipper.list(a).filter { $0.kind == .file }.allSatisfy { $0.method == "Copy" || $0.uncompressedSize == 0 }) }
        }
    }

    @Test func encryptedNamesAndPasswords() throws {
        let t = TempDir()
        tree(t, bigSize: 2 << 20)
        let pw = "pässwörd-7z ✓"
        let a = try create(t, "enc.7z") { $0.password = pw }
        // File names are hidden: listing needs the password.
        #expect(throws: XipperError.passwordRequired(entry: "enc.7z")) { try Xipper.list(a) }
        #expect(throws: XipperError.wrongPassword(entry: "enc.7z")) { try Xipper.list(a, password: "nope") }
        #expect(try Xipper.list(a, password: pw).allSatisfy { $0.isEncrypted })
        let raw = try Data(contentsOf: a)
        #expect(raw.range(of: Data("readme".utf8)) == nil && raw.range(of: Data("r\0e\0a\0d\0m\0e".utf8)) == nil)
        #expect(throws: XipperError.self) { try Xipper.test(a) }
        #expect(!(try Xipper.test(a, password: "nope")).isOK)
        #expect(try Xipper.test(a, password: pw).isOK)
        try extractAndCompare(t, a, password: pw)
        var eo = ExtractOptions()
        eo.password = "nope"
        t.mkdir("wrong")
        #expect(throws: XipperError.self) { try Xipper.extract(a, to: t.url("wrong"), options: eo) }

        // Readable names, encrypted data.
        let b = try create(t, "names.7z") { $0.password = pw; $0.encryptFileNames = false }
        #expect(try Xipper.list(b).contains { $0.path == "src/readme.txt" })
        #expect(throws: XipperError.passwordRequired(entry: "src/data/big.bin")) { try Xipper.readEntry(b, path: "src/data/big.bin") }
        #expect(throws: XipperError.wrongPassword(entry: "src/readme.txt")) { try Xipper.readEntry(b, path: "src/readme.txt", password: "nope") }
        #expect(try Xipper.readEntry(b, path: "src/readme.txt", password: pw).data == Array("hello xipper\n".utf8))
    }

    @Test func volumes() throws {
        let t = TempDir()
        tree(t, bigSize: 3 << 20)
        _ = try create(t, "vol.7z") { $0.volumeSize = 128 << 10; $0.password = "v" }
        let parts = try FileManager.default.contentsOfDirectory(atPath: t.path).filter { $0.hasPrefix("vol.7z.") }.sorted()
        #expect(parts.count > 3 && parts.first == "vol.7z.001")
        #expect(!FileManager.default.fileExists(atPath: t.path + "/vol.7z"))
        let first = t.url("vol.7z.001")
        #expect(try ArchiveFormat.detect(t.url("vol.7z.002")) == .sevenZip)
        #expect(try Xipper.test(first, password: "v").isOK)
        try extractAndCompare(t, first, password: "v")
        // A missing volume is reported, not crashed on.
        try FileManager.default.removeItem(atPath: t.path + "/" + parts[parts.count / 2])
        #expect(throws: XipperError.self) { try Xipper.extract(first, to: t.url(""), options: { var o = ExtractOptions(); o.password = "v"; return o }()) }
    }

    @Test func selectionFlattenAndConflicts() throws {
        let t = TempDir()
        tree(t, bigSize: 1 << 20)
        let a = try create(t, "s.7z")
        t.mkdir("sel")
        var o = ExtractOptions()
        o.selection = ["src/data"]
        o.flatten = true
        let r = try Xipper.extract(a, to: t.url("sel"), mode: .into, options: o)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: t.path + "/sel"))
        #expect(names == ["big.bin", "small.bin", "random.jpg", "notes.md"], "\(names)")
        #expect(r.files == 4)
        #expect(try Xipper.plannedConflicts(a, into: t.url("sel"), selection: ["src/data"], flatten: true).count == 4)
        o.overwrite = .skip
        let again = try Xipper.extract(a, to: t.url("sel"), mode: .into, options: o)
        #expect(again.skipped.count == 4)
    }

    @Test func progressAndCancellation() throws {
        let t = TempDir()
        tree(t, bigSize: 8 << 20)
        let seen = ProgressBox()
        var o = CreateOptions()
        o.format = .sevenZip
        let a = t.url("p.7z")
        try Xipper.create(from: [t.url("src")], to: a, options: o, progress: { seen.set($0) })
        #expect(seen.last.map { $0.completedBytes == $0.totalBytes && $0.totalBytes > 8 << 20 } == true)
        let cancel = CancellationToken()
        cancel.cancel()
        #expect(throws: XipperError.cancelled) { try Xipper.create(from: [t.url("src")], to: t.url("c.7z"), options: o, cancel: cancel) }
        #expect(!FileManager.default.fileExists(atPath: t.path + "/c.7z"))
        t.mkdir("d")
        #expect(throws: XipperError.cancelled) { try Xipper.extract(a, to: t.url("d"), cancel: cancel) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.path + "/d").isEmpty)
    }

    // MARK: interoperability with 7-Zip

    @Test func sevenZipAcceptsOurArchives() throws {
        guard let sevenZip else { return }
        let t = TempDir()
        tree(t, bigSize: 4 << 20)
        let cases: [(String, (inout CreateOptions) -> Void, [String])] = [
            ("solid.7z", { _ in }, []),
            ("nonsolid.7z", { $0.solidBlockSize = 0 }, []),
            ("enc.7z", { $0.password = "Secret-7z" }, ["-pSecret-7z"]),
            ("store.7z", { $0.level = 0; $0.password = "Secret-7z"; $0.encryptFileNames = false }, ["-pSecret-7z"]),
        ]
        for (name, configure, pw) in cases {
            let a = try create(t, name, configure: configure)
            let r = run(sevenZip, ["t", "-bd"] + pw + [a.path])
            #expect(r.status == 0 && r.output.contains("Everything is Ok"), "\(name): \(r.output)")
            let out = t.path + "/7zz-" + name
            #expect(run(sevenZip, ["x", "-bd", "-snl", "-o" + out] + pw + [a.path]).status == 0)
            let (same, diff) = treesEqual(t.path + "/src", out + "/src")
            #expect(same, "\(name): \(diff)")
        }
        let info = run(sevenZip, ["l", "-slt", "-pSecret-7z", t.path + "/enc.7z"]).output
        #expect(info.contains("Method = ARM64 LZMA2") || info.contains("ARM64"), "\(info)")
        #expect(info.contains("7zAES"))
        // Without the password 7-Zip cannot even list the names.
        #expect(!run(sevenZip, ["l", "-p", t.path + "/enc.7z"], stdin: "\n").output.contains("readme.txt"))
        // Volumes.
        _ = try create(t, "vol.7z") { $0.volumeSize = 1 << 20 }
        let v = run(sevenZip, ["t", "-bd", t.path + "/vol.7z.001"])
        #expect(v.status == 0 && v.output.contains("Everything is Ok"), "\(v.output)")
    }

    /// Archives written by 7-Zip with every method and filter Xipper reads.
    static let foreign: [(String, [String])] = [
        ("lzma2-solid", ["-mx=5"]), ("lzma", ["-m0=LZMA"]), ("ppmd", ["-m0=PPMd"]), ("ppmd-o32", ["-m0=PPMd:o=32:mem=64m"]),
        ("bzip2", ["-m0=BZip2"]), ("deflate", ["-m0=Deflate"]), ("copy", ["-m0=Copy"]),
        ("bcj", ["-mf=BCJ"]), ("bcj2", ["-mf=BCJ2"]), ("arm64", ["-mf=ARM64"]), ("arm", ["-mf=ARM"]), ("armt", ["-mf=ARMT"]),
        ("ppc", ["-mf=PPC"]), ("sparc", ["-mf=SPARC"]), ("delta", ["-mf=Delta:4"]),
        ("non-solid", ["-ms=off"]), ("mt-lzma2", ["-mmt=8", "-md=1m", "-mx=9"]),
        ("encrypted-headers", ["-mhe=on", "-pSecret1"]), ("encrypted-data", ["-pSecret1"]),
        ("volumes", ["-v300k"]), ("volumes-encrypted", ["-v300k", "-mhe=on", "-pSecret1"]),
        ("headers-uncompressed", ["-mhc=off"]),
    ]

    @Test(arguments: foreign)
    func readsSevenZipArchives(name: String, switches: [String]) throws {
        guard let sevenZip else { return }
        let t = TempDir()
        tree(t, bigSize: 2 << 20)
        let a = t.path + "/\(name).7z"
        let r = run(sevenZip, ["a", "-bd", "-snl"] + switches + [a, "src"], cwd: t.path)
        #expect(r.status == 0, "\(r.output)")
        let path = switches.contains { $0.hasPrefix("-v") } ? a + ".001" : a
        let pw = switches.contains("-pSecret1") ? "Secret1" : nil
        let url = URL(fileURLWithPath: path)
        #expect(try ArchiveFormat.detect(url) == .sevenZip)
        let test = try Xipper.test(url, password: pw)
        #expect(test.isOK, "\(name): \(test.failures)")
        #expect(try Xipper.list(url, password: pw).contains { $0.path == "src/link-to-readme" && $0.kind == .symlink })
        try extractAndCompare(t, url, password: pw)
    }

    // MARK: damage

    @Test func truncatedAndCorruptArchives() throws {
        let t = TempDir()
        tree(t, bigSize: 2 << 20)
        for (name, pw) in [("plain.7z", String?.none), ("enc.7z", "pw")] {
            let a = try create(t, name) { $0.password = pw }
            let bytes = try [UInt8](Data(contentsOf: a))
            // Truncated anywhere: an error, never a crash or a silent success.
            for cut in [10, 31, 32, 100, bytes.count / 2, bytes.count - 40, bytes.count - 1] {
                let p = t.path + "/cut-\(cut)-\(name)"
                FileManager.default.createFile(atPath: p, contents: Data(bytes[0..<cut]))
                let u = URL(fileURLWithPath: p)
                if let r = try? Xipper.test(u, password: pw) { #expect(!r.isOK, "cut at \(cut)") }
                #expect(throws: (any Error).self) { try Xipper.extract(u, to: t.url(""), options: { var o = ExtractOptions(); o.password = pw; return o }()) }
            }
            // Flipped bytes in the data: detected by the CRC (or the codec, or AES padding).
            for pos in stride(from: 40, to: bytes.count - 200, by: max(1, (bytes.count - 240) / 13)) {
                var damaged = bytes
                damaged[pos] ^= 0x55
                let p = t.path + "/flip-\(pos)-\(name)"
                FileManager.default.createFile(atPath: p, contents: Data(damaged))
                let r = try Xipper.test(URL(fileURLWithPath: p), password: pw)
                #expect(!r.isOK, "flip at \(pos) of \(bytes.count) not detected")
            }
        }
        // Garbage after a valid signature.
        var junk = SevenZip.signature + [0, 4]
        for i in 0..<4000 { junk.append(UInt8(truncatingIfNeeded: i &* 2_654_435_761 >> 13)) }
        FileManager.default.createFile(atPath: t.path + "/junk.7z", contents: Data(junk))
        #expect(throws: XipperError.self) { try Xipper.list(t.url("junk.7z")) }
    }

    /// Hand-made headers that lie: offsets beyond the end, absurd counts, cyclic coder graphs.
    @Test func hostileHeaders() throws {
        let t = TempDir()
        func archive(_ header: [UInt8], data: [UInt8] = [], nextOffset: UInt64? = nil) -> URL {
            var start = ByteWriter()
            start.u64(nextOffset ?? UInt64(data.count))
            start.u64(UInt64(header.count))
            start.u32(CRC32.checksum(header))
            var w = ByteWriter()
            w.append(SevenZip.signature)
            w.u8(0); w.u8(4)
            w.u32(CRC32.checksum(start.bytes))
            w.append(start.bytes)
            w.append(data)
            w.append(header)
            let p = t.path + "/h\(UUID().uuidString.prefix(6)).7z"
            FileManager.default.createFile(atPath: p, contents: Data(w.bytes))
            return URL(fileURLWithPath: p)
        }
        // Pack stream far beyond the file.
        var h = ByteWriter()
        h.u8(SevenZip.ID.header); h.u8(SevenZip.ID.mainStreamsInfo)
        h.u8(SevenZip.ID.packInfo); h.number(UInt64(1) << 40); h.number(1); h.u8(SevenZip.ID.size); h.number(100); h.u8(0)
        h.u8(0); h.u8(0)
        #expect(throws: XipperError.self) { try Xipper.list(archive(h.bytes)) }
        // A billion files.
        h = ByteWriter()
        h.u8(SevenZip.ID.header); h.u8(SevenZip.ID.filesInfo); h.number(1_000_000_000); h.u8(0); h.u8(0)
        #expect(throws: XipperError.self) { try Xipper.list(archive(h.bytes)) }
        // Two LZMA2 coders feeding each other, beside the one that reads the packed stream.
        h = ByteWriter()
        h.u8(SevenZip.ID.header); h.u8(SevenZip.ID.mainStreamsInfo)
        h.u8(SevenZip.ID.packInfo); h.number(0); h.number(1); h.u8(SevenZip.ID.size); h.number(4); h.u8(0)
        h.u8(SevenZip.ID.unpackInfo); h.u8(SevenZip.ID.folder); h.number(1); h.u8(0)
        h.number(3)
        for _ in 0..<3 { h.u8(0x21); h.u8(0x21); h.number(1); h.u8(16) }
        h.number(0); h.number(1)  // in 0 <- out 1
        h.number(1); h.number(0)  // in 1 <- out 0
        h.u8(SevenZip.ID.codersUnpackSize); h.number(10); h.number(10); h.number(10); h.u8(0)
        h.u8(0); h.u8(0)
        #expect(throws: XipperError.corrupt("7z folder has unused coders")) { try Xipper.list(archive(h.bytes, data: [1, 2, 3, 4])) }
        // Header offset pointing before the data / wrong CRC.
        #expect(throws: XipperError.self) { try Xipper.list(archive([1, 0], nextOffset: UInt64.max - 10)) }
    }

    // MARK: security

    @Test func pathTraversalInsideSevenZip() throws {
        let t = TempDir()
        t.mkdir("outside")
        t.write("payload.txt", "slip")
        let payload = t.path + "/payload.txt"
        let now = Date()
        func item(_ name: String, _ kind: ArchiveItem.Kind, source: String = "") -> ArchiveItem {
            ArchiveItem(name: name, sourcePath: source, kind: kind, permissions: 0o644, modified: now, uid: 0, gid: 0)
        }
        let items = [
            item("ok.txt", .file(size: 4), source: payload),
            item("../evil.txt", .file(size: 4), source: payload),
            item("a/../../evil.txt", .file(size: 4), source: payload),
            item("..\\evil.txt", .file(size: 4), source: payload),
            item("/tmp/xipper-7z-abs.txt", .file(size: 4), source: payload),
            item("escape", .symlink(target: "../outside")),
            item("abs-link", .symlink(target: "/etc")),
            item("inside-link", .symlink(target: "ok.txt")),
            item("escape/pwned", .file(size: 4), source: payload),
        ]
        for solid in [Int64?.none, 0] {
            var o = SevenZipOptions()
            o.solidBlockSize = solid
            let a = t.path + "/evil-\(solid ?? -1).7z"
            _ = try SevenZipWriter.write(items: items, to: a, options: o, overwrite: true, progress: nil, cancel: nil)
            let dest = "dest\(solid ?? -1)"
            t.mkdir(dest)
            let r = try Xipper.extract(URL(fileURLWithPath: a), to: t.url(dest), mode: .into)
            #expect(!FileManager.default.fileExists(atPath: t.path + "/evil.txt"))
            #expect(!FileManager.default.fileExists(atPath: t.path + "/outside/pwned"))
            #expect(!FileManager.default.fileExists(atPath: "/tmp/xipper-7z-abs.txt"))
            #expect(FileManager.default.fileExists(atPath: t.path + "/\(dest)/ok.txt"))
            #expect(FileManager.default.fileExists(atPath: t.path + "/\(dest)/tmp/xipper-7z-abs.txt"))
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: t.path + "/\(dest)/inside-link")) == "ok.txt")
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: t.path + "/\(dest)/escape")) == nil)
            let skipped = Set(r.skipped.map(\.path))
            #expect(skipped.isSuperset(of: ["../evil.txt", "a/../../evil.txt", "escape", "abs-link"]), "\(r.skipped)")
        }
    }

    @Test func compressionBombIsRefused() throws {
        let t = TempDir()
        t.write("src/zeros.bin", [UInt8](repeating: 0, count: 80 << 20))
        var o = CreateOptions()
        o.format = .sevenZip
        try Xipper.create(from: [t.url("src")], to: t.url("bomb.7z"), options: o)
        t.mkdir("d")
        #expect(throws: XipperError.self) { try Xipper.extract(t.url("bomb.7z"), to: t.url("d")) }
        var eo = ExtractOptions()
        eo.limits.maxTotalBytes = 1 << 20
        eo.limits.maxCompressionRatio = 1e9
        #expect(throws: XipperError.limitExceeded("extraction would write more than 1048576 bytes")) {
            try Xipper.extract(t.url("bomb.7z"), to: t.url("d"), options: eo)
        }
    }

    // MARK: codecs

    @Test func filtersRoundTrip() throws {
        let data = sampleData(300_000, seed: 9) + [0xE8, 1, 2, 3, 0, 0xE9, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F, 0x85, 1, 0, 0, 0]
        for kind in [BranchFilter.Kind.x86, .arm, .armThumb, .arm64, .ppc, .sparc, .riscv] {
            for piece in [1, 7, 4096, 1 << 20] {
                let enc = try runTransform(BranchFilter(kind, encoding: true), data, piece: piece)
                let dec = try runTransform(BranchFilter(kind, encoding: false), enc, piece: piece)
                #expect(dec == data, "\(kind) piece \(piece)")
            }
        }
        let enc = try runTransform(DeltaFilter(props: [3], encoding: true), data, piece: 1000)
        #expect(try runTransform(DeltaFilter(props: [3], encoding: false), enc, piece: 333) == data)
    }

    @Test func numberEncoding() throws {
        for v: UInt64 in [0, 1, 0x7F, 0x80, 0x3FFF, 0x4000, 1 << 20, 1 << 35, 1 << 56, UInt64.max - 1, .max] {
            var w = ByteWriter()
            w.number(v)
            let (decoded, rest) = try w.bytes.withUnsafeBytes { b throws -> (UInt64, Int) in
                var r = ByteReader(b)
                return (try r.number(), r.remaining)
            }
            #expect(decoded == v && rest == 0)
        }
    }

    func runTransform(_ t: StreamTransform, _ input: [UInt8], piece: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < input.count {
            let n = min(piece, input.count - i)
            try input[i..<(i + n)].withUnsafeBytes { try t.process($0) { out.append(contentsOf: $0) } }
            i += n
        }
        try t.finish { out.append(contentsOf: $0) }
        return out
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ProgressSnapshot?
    func set(_ s: ProgressSnapshot) { lock.lock(); value = s; lock.unlock() }
    var last: ProgressSnapshot? { lock.lock(); defer { lock.unlock() }; return value }
}
