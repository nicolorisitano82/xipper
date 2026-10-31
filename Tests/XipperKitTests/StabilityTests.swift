import Foundation
import Synchronization
import Testing
@testable import XipperKit

/// Stability under stress: concurrent use, unusual trees, failures and cancellation at any
/// point, truncation at every offset, long edit sequences and descriptor leaks. Every outcome
/// is checked for "no crash, no wrong data, nothing left behind".
@Suite("Stability")
struct StabilityTests {
    static let writable: [ArchiveFormat] = [.zip, .sevenZip, .xiz, .tar, .tarZstd, .tarGzip, .tarXz, .cpio, .appleArchive]

    func archive(_ t: TempDir, _ format: ArchiveFormat, password: String? = nil, name: String = "a") throws -> URL {
        var o = CreateOptions()
        o.format = format
        o.password = password
        if format == .xiz { o.xizKDF = .minimum }
        let url = t.url(name + "." + format.fileExtension)
        try Xipper.create(from: [t.url("src")], to: url, options: o)
        return url
    }

    /// Regular files below `root`, relative path → content.
    func files(_ root: String) -> [String: Data] {
        var out: [String: Data] = [:]
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: root) else { return out }
        for case let rel as String in e {
            var st = stat()
            guard lstat(root + "/" + rel, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { continue }
            out[rel.precomposedStringWithCanonicalMapping] = fm.contents(atPath: root + "/" + rel)
        }
        return out
    }

    /// Names of everything in `dir` (to spot staging folders and temporary files left behind).
    func leftovers(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
    }

    // MARK: concurrency

    /// The same archives read by many threads at once: list, test, read and extract must agree
    /// with a single-threaded run (shared caches, codecs and descriptors are thread-safe).
    @Test(arguments: [ArchiveFormat.zip, .sevenZip, .xiz, .tarZstd, .appleArchive])
    func concurrentReadersAgree(format: ArchiveFormat) throws {
        let t = TempDir()
        makeTree(t, bigSize: 1 << 20)
        let a = try archive(t, format)
        let expected = files(t.path + "/src")
        let paths = try Xipper.list(a).filter { $0.kind == .file }.map(\.path).sorted()
        let errors = Mutex<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 24) { i in
            do {
                switch i % 4 {
                case 0:
                    let p = try Xipper.list(a).filter { $0.kind == .file }.map(\.path).sorted()
                    if p != paths { errors.withLock { $0.append("list \(i)") } }
                case 1:
                    if !(try Xipper.test(a).isOK) { errors.withLock { $0.append("test \(i)") } }
                case 2:
                    let r = try Xipper.readEntry(a, path: "src/data/small.bin", maxBytes: 1 << 20)
                    if Data(r.data) != expected["data/small.bin"] { errors.withLock { $0.append("read \(i)") } }
                default:
                    let d = t.path + "/out\(i)"
                    try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
                    let r = try Xipper.extract(a, to: URL(fileURLWithPath: d), mode: .into)
                    if files(r.destination.path + "/src") != expected { errors.withLock { $0.append("extract \(i)") } }
                }
            } catch {
                errors.withLock { $0.append("\(i): \(error)") }
            }
        }
        #expect(errors.withLock { $0 }.isEmpty, "\(format): \(errors.withLock { $0 })")
    }

    /// Many archives written at once, in every writable format: each one is complete and intact.
    @Test func concurrentWritersProduceIntactArchives() throws {
        let t = TempDir()
        makeTree(t, bigSize: 512 << 10)
        let expected = files(t.path + "/src")
        let formats = Self.writable
        let errors = Mutex<[String]>([])
        DispatchQueue.concurrentPerform(iterations: formats.count * 2) { i in
            let f = formats[i % formats.count]
            do {
                let a = try archive(t, f, name: "w\(i)")
                let d = t.path + "/x\(i)"
                try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
                let r = try Xipper.extract(a, to: URL(fileURLWithPath: d), mode: .into)
                if files(r.destination.path + "/src") != expected { errors.withLock { $0.append("\(f) content") } }
            } catch {
                errors.withLock { $0.append("\(f): \(error)") }
            }
        }
        #expect(errors.withLock { $0 }.isEmpty, "\(errors.withLock { $0 })")
    }

    // MARK: unusual trees

    /// Names and shapes that break naive code: deep nesting, the longest legal name, dashes and
    /// dots, quotes and shell characters, emoji and decomposed accents, many tiny files.
    @Test(arguments: StabilityTests.writable)
    func unusualTreesRoundTrip(format: ArchiveFormat) throws {
        let t = TempDir()
        let deep = (0..<40).map { "d\($0)" }.joined(separator: "/")
        t.write("src/\(deep)/fondo.txt", "deep\n")
        t.write("src/" + String(repeating: "n", count: 251) + ".txt", "long name\n")
        t.write("src/-rf", "dash\n")
        t.write("src/...", "dots\n")
        t.write("src/.nascosto", "hidden\n")
        t.write("src/spazi  doppi .txt", "spaces\n")
        t.write("src/virgolette \"'`$(echo).txt", "shell\n")
        t.write("src/a:b.txt", "colon\n")
        t.write("src/emoji 🗜️👩‍💻.txt", "emoji\n")
        t.write("src/Cafe\u{301}.txt", "nfd\n")
        t.write("src/zero.bin", [])
        for i in 0..<1500 { t.write("src/molti/f\(i).txt", Array("\(i)".utf8)) }
        t.mkdir("src/vuota/annidata")
        let a = try archive(t, format)
        #expect(try Xipper.test(a).isOK, "\(format)")
        t.mkdir("out")
        let r = try Xipper.extract(a, to: t.url("out"), mode: .into)
        #expect(r.skipped.isEmpty, "\(format): \(r.skipped.map(\.path))")
        let (same, diff) = treesEqual(t.path + "/src", t.path + "/out/src")
        #expect(same, "\(format):\n\(diff)")
    }

    // MARK: failures leave nothing behind

    @Test(arguments: [ArchiveFormat.zip, .sevenZip, .xiz, .tarZstd])
    func failedCreateKeepsTheExistingArchive(format: ArchiveFormat) throws {
        let t = TempDir()
        makeTree(t, bigSize: 64 << 10)
        let a = try archive(t, format)
        let before = try Data(contentsOf: a)
        var o = CreateOptions()
        o.format = format
        o.overwrite = true
        if format == .xiz { o.xizKDF = .minimum }
        // A source that vanished between choosing it and compressing it.
        #expect(throws: (any Error).self) { try Xipper.create(from: [t.url("src"), t.url("missing")], to: a, options: o) }
        #expect(try Data(contentsOf: a) == before, "\(format): the archive was clobbered")
        // An unreadable file in the middle of the tree.
        t.write("src/data/locked.bin", sampleData(10_000), mode: 0o000)
        defer { chmod(t.path + "/src/data/locked.bin", 0o644) }
        _ = try? Xipper.create(from: [t.url("src")], to: a, options: o)
        #expect(try Data(contentsOf: a) == before || (try Xipper.test(a).isOK), "\(format): half-written archive")
        #expect(leftovers(t.path).allSatisfy { !$0.hasPrefix(".") && !$0.contains(".tmp") && !$0.contains("xip-") }, "\(leftovers(t.path))")
    }

    @Test func createIntoReadOnlyFolderFailsCleanly() throws {
        let t = TempDir()
        makeTree(t, bigSize: 64 << 10)
        t.mkdir("ro")
        chmod(t.path + "/ro", 0o555)
        defer { chmod(t.path + "/ro", 0o755) }
        for f in [ArchiveFormat.zip, .sevenZip, .xiz, .tarZstd] {
            var o = CreateOptions(); o.format = f
            #expect(throws: (any Error).self) { try Xipper.create(from: [t.url("src")], to: t.url("ro/a." + f.fileExtension), options: o) }
        }
        #expect(leftovers(t.path + "/ro").isEmpty)
    }

    /// A wrong password, a damaged archive or a missing volume: smart extraction leaves no
    /// staging folder and no partial file next to the archive.
    @Test(arguments: [ArchiveFormat.zip, .sevenZip, .xiz])
    func failedExtractionLeavesNothing(format: ArchiveFormat) throws {
        let t = TempDir()
        makeTree(t, bigSize: 2 << 20)
        let a = try archive(t, format, password: "giusta")
        t.mkdir("dest")
        var o = ExtractOptions()
        o.password = "sbagliata"
        #expect(throws: XipperError.self) { try Xipper.extract(a, to: t.url("dest"), options: o) }
        #expect(leftovers(t.path + "/dest").isEmpty, "\(format) wrong password: \(leftovers(t.path + "/dest"))")
        o.password = nil
        #expect(throws: XipperError.self) { try Xipper.extract(a, to: t.url("dest"), options: o) }
        #expect(leftovers(t.path + "/dest").isEmpty)

        var data = try Data(contentsOf: a)
        for i in stride(from: data.count / 2, to: data.count / 2 + 32, by: 1) { data[i] ^= 0xA5 }
        try data.write(to: a)
        o.password = "giusta"
        _ = try? Xipper.extract(a, to: t.url("dest"), options: o)
        #expect(leftovers(t.path + "/dest").isEmpty, "\(format) damaged: \(leftovers(t.path + "/dest"))")
    }

    /// Cancelling at many different moments: no partial archive, no staging folder.
    @Test(arguments: [ArchiveFormat.zip, .sevenZip, .xiz, .tarZstd, .tarXz])
    func cancellationAtAnyMomentIsClean(format: ArchiveFormat) throws {
        let t = TempDir()
        makeTree(t, bigSize: 24 << 20)
        let full = try archive(t, format, name: "full")
        for after in [0, 1, 2, 4, 8] {
            let token = CancellationToken()
            let calls = Atomic<Int>(0)
            let progress: ProgressHandler = { _ in
                if calls.add(1, ordering: .relaxed).newValue > after { token.cancel() }
            }
            if after == 0 { token.cancel() }
            var o = CreateOptions(); o.format = format
            if format == .xiz { o.xizKDF = .minimum }
            let out = t.url("c\(after)." + format.fileExtension)
            do {
                try Xipper.create(from: [t.url("src")], to: out, options: o, progress: progress, cancel: token)
                #expect(try Xipper.test(out).isOK, "\(format) finished despite cancel but is broken")
            } catch XipperError.cancelled {
                #expect(!FileManager.default.fileExists(atPath: out.path), "\(format) partial archive after cancel at \(after)")
            }

            let dest = "dest\(after)-\(format.rawValue)"
            t.mkdir(dest)
            let token2 = CancellationToken()
            let calls2 = Atomic<Int>(0)
            if after == 0 { token2.cancel() }
            do {
                try Xipper.extract(full, to: t.url(dest), progress: { _ in
                    if calls2.add(1, ordering: .relaxed).newValue > after { token2.cancel() }
                }, cancel: token2)
            } catch XipperError.cancelled {
                #expect(leftovers(t.path + "/" + dest).isEmpty, "\(format) staging left after cancel at \(after)")
            }
        }
        #expect(leftovers(t.path).allSatisfy { !$0.contains("xip-") && !$0.hasSuffix(".tmp") }, "\(leftovers(t.path))")
    }

    // MARK: truncation

    /// Every prefix of a small archive: readers may refuse it, but when `test` accepts it, what
    /// is extracted must be exactly the original files (no silently wrong data).
    @Test(arguments: [ArchiveFormat.zip, .sevenZip, .xiz, .tar, .tarZstd, .tarGzip, .cpio, .appleArchive])
    func everyTruncationIsRefusedOrCorrect(format: ArchiveFormat) throws {
        let t = TempDir()
        t.write("src/a.txt", String(repeating: "Xipper truncation ", count: 40))
        t.write("src/b/c.bin", sampleData(3000, seed: 9))
        t.write("src/d.txt", "end\n")
        let expected = files(t.path + "/src")
        let full = try Data(contentsOf: try archive(t, format))
        let step = max(1, full.count / 300)
        let cuts = Set(Array(stride(from: 0, to: full.count, by: step)) + Array(max(0, full.count - 64)..<full.count))
        let cut = t.url("cut." + format.fileExtension)
        var wrong: [Int] = []
        for n in cuts.sorted() {
            try full.prefix(n).write(to: cut)
            _ = try? Xipper.list(cut)
            guard let r = try? Xipper.test(cut), r.isOK else { continue }
            let d = t.path + "/t\(n)"
            try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
            guard let e = try? Xipper.extract(cut, to: URL(fileURLWithPath: d), mode: .into) else { continue }
            for (k, v) in files(e.destination.path + "/src") where expected[k] != v { wrong.append(n) }
            try? FileManager.default.removeItem(atPath: d)
        }
        #expect(wrong.isEmpty, "\(format): wrong data accepted at cuts \(wrong.prefix(10)) of \(full.count)")
    }

    // MARK: long edit sequences

    /// Thirty random edits in a row (add, rename, delete): after each one the listing matches
    /// the model and the archive tests clean; at the end the content is exact.
    @Test(arguments: [ArchiveFormat.zip, .xiz, .sevenZip, .tarZstd])
    func longEditSequencesStayConsistent(format: ArchiveFormat) throws {
        let t = TempDir()
        t.write("src/base.txt", "base\n")
        let a = try archive(t, format)
        var model: [String: Data] = ["src/base.txt": Data("base\n".utf8)]
        var rng = SystemRandomNumberGenerator()
        var counter = 0
        for step in 0..<30 {
            counter += 1
            let change: ArchiveChange
            switch Int.random(in: 0..<3, using: &rng) {
            case 1 where model.count > 1:
                let from = model.keys.sorted()[Int.random(in: 0..<model.count, using: &rng)]
                let to = "src/r\(counter).txt"
                change = .rename(from, to: to)
                model[to] = model.removeValue(forKey: from)
            case 2 where model.count > 1:
                let p = model.keys.sorted()[Int.random(in: 0..<model.count, using: &rng)]
                change = .delete(p)
                model[p] = nil
            default:
                let content = Data(sampleData(Int.random(in: 0...40_000, using: &rng), seed: UInt64(counter)))
                let file = t.url("new\(counter).bin")
                try content.write(to: file)
                let dest = "src/n\(counter).bin"
                change = .add(file, as: dest)
                model[dest] = content
            }
            try Xipper.edit(a, changes: [change])
            let listed = Set(try Xipper.list(a).filter { $0.kind == .file }.map(\.path))
            #expect(listed == Set(model.keys), "\(format) step \(step) \(change)")
            #expect(try Xipper.test(a).isOK, "\(format) step \(step)")
        }
        t.mkdir("out")
        let r = try Xipper.extract(a, to: t.url("out"), mode: .into)
        let got = files(r.destination.path + "/src")
        #expect(got == Dictionary(uniqueKeysWithValues: model.map { (String($0.key.dropFirst(4)), $0.value) }), "\(format)")
    }

    // MARK: resources

    /// Descriptors opened on files of this test (F_GETPATH): other tests running in parallel
    /// do not disturb the count.
    func openDescriptors(under root: String) -> [String] {
        var out: [String] = []
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let real = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/private" + root)) ?? root
        for fd in 0..<getdtablesize() where fcntl(fd, F_GETPATH, &buf) == 0 {
            let p = String(cString: buf)
            if p.hasPrefix(root) || p.hasPrefix("/private" + root) || p.hasPrefix(real) { out.append(p) }
        }
        return out
    }

    /// Hundreds of operations, many failing on purpose: no descriptor stays open afterwards.
    @Test func noDescriptorLeaks() throws {
        let t = TempDir()
        makeTree(t, bigSize: 256 << 10)
        // The probe sees a descriptor opened here (otherwise the check below would prove nothing).
        let probe = open(t.path + "/src/readme.txt", O_RDONLY)
        #expect(openDescriptors(under: t.path).count == 1)
        close(probe)
        var archives: [URL] = []
        for f in [ArchiveFormat.zip, .sevenZip, .xiz, .tarZstd, .tarGzip, .cpio, .appleArchive] { archives.append(try archive(t, f)) }
        for f in [ArchiveFormat.zip, .sevenZip, .xiz] { archives.append(try archive(t, f, password: "pw", name: "enc")) }
        try Data(sampleData(5000)).write(to: t.url("garbage.zip"))
        archives.append(t.url("garbage.zip"))
        for round in 0..<5 {
            for (i, a) in archives.enumerated() {
                _ = try? Xipper.list(a)
                _ = try? Xipper.test(a)
                _ = try? Xipper.test(a, password: "wrong")
                _ = try? Xipper.readEntry(a, path: "src/readme.txt", password: "pw")
                let d = t.path + "/o\(round)-\(i)"
                try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
                var o = ExtractOptions()
                o.password = round % 2 == 0 ? "pw" : "wrong"
                _ = try? Xipper.extract(a, to: URL(fileURLWithPath: d), options: o)
            }
        }
        let open = openDescriptors(under: t.path)
        #expect(open.isEmpty, "\(open.count) descriptors left open: \(open.prefix(5))")
    }
}
