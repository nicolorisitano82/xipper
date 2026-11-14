import Foundation
import Testing
@testable import XipperKit

/// «Cambia formato» with little free space: ZIP and 7z → XIZ a batch at a time, the original's
/// bytes released as they are carried over, resumable after an interruption at any step.
@Suite("Changing format with little free space", .serialized)
struct LowSpaceConversionTests {
    /// 24 files of 300–700 KB plus the usual tree: several batches of 1 MiB.
    func source(_ t: TempDir, _ format: ArchiveFormat, solid: Bool = false) throws -> URL {
        makeTree(t, bigSize: 2 << 20)
        for i in 0..<24 { t.write("src/many/f\(i).bin", sampleData(300_000 + i * 17_000, seed: UInt64(i + 100))) }
        var o = CreateOptions()
        o.format = format
        if format == .sevenZip { o.solidBlockSize = solid ? 2 << 20 : 0 }
        let url = t.url(format == .zip ? "a.zip" : "a.7z")
        try Xipper.create(from: [t.url("src")], to: url, options: o)
        return url
    }

    func xiz() -> CreateOptions {
        var o = CreateOptions()
        o.format = .xiz
        return o
    }

    func extractsToSource(_ t: TempDir, _ url: URL, password: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let out = "x-\(UUID().uuidString)"
        t.mkdir(out)
        var eo = ExtractOptions()
        eo.password = password
        let r = try Xipper.extract(url, to: t.url(out), options: eo)
        let (same, diff) = treesEqual(t.path + "/src", r.destination.path)
        #expect(same, "\(diff)", sourceLocation: sourceLocation)
    }

    func withHooks<T>(batch: Int64 = 1 << 20, stop: String? = nil, _ body: () throws -> T) rethrows -> T {
        LowSpaceConverter.testBatchLimit.withLock { $0 = batch }
        LowSpaceConverter.testStop.withLock { $0 = stop }
        defer {
            LowSpaceConverter.testBatchLimit.withLock { $0 = nil }
            LowSpaceConverter.testStop.withLock { $0 = nil }
        }
        return try body()
    }

    static let sources: [(ArchiveFormat, Bool)] = [(.zip, false), (.sevenZip, false), (.sevenZip, true)]

    @Test(arguments: [0, 1, 2])
    func convertsAndRemovesTheOriginal(kind: Int) throws {
        let (format, solid) = Self.sources[kind]
        let t = TempDir()
        let a = try source(t, format, solid: solid)
        #expect(Xipper.lowSpaceConversionProblem(a, to: .xiz) == nil)
        let target = t.url("a.xiz")
        let r = try withHooks { try Xipper.convertWithLittleSpace(a, to: target, options: xiz()) }
        #expect(r.originalReleased)
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(!FileManager.default.fileExists(atPath: a.path + LowSpaceConverter.journalSuffix))
        #expect(!FileManager.default.fileExists(atPath: LowSpaceConverter.stagedURL(target).path))
        #expect(try Xipper.test(target).failures.isEmpty)
        // One segment per batch.
        #expect(try XizArchive(path: target.path).segments > 3)
        try extractsToSource(t, target)
    }

    @Test(arguments: [0, 2])
    func resumesAfterReleasingPartOfTheOriginal(kind: Int) throws {
        let (format, solid) = Self.sources[kind]
        let t = TempDir()
        let a = try source(t, format, solid: solid)
        let size = Int64((try FileManager.default.attributesOfItem(atPath: a.path)[.size] as! NSNumber).int64Value)
        let target = t.url("a.xiz")
        #expect(throws: XipperError.cancelled) {
            try withHooks(stop: "batch2-released") { try Xipper.convertWithLittleSpace(a, to: target, options: xiz()) }
        }
        let s = try #require(Xipper.interruptedConversion(of: a))
        #expect(s.released)
        #expect(s.batchesDone == 3)
        #expect(s.batches > 3)
        var st = stat()
        stat(a.path, &st)
        #expect(Int64(st.st_blocks) * 512 < size - (512 << 10), "the original's bytes were not released: \(Int64(st.st_blocks) * 512) of \(size)")
        #expect(throws: (any Error).self) { try Xipper.abandonConversion(s.journal) }
        // Running the same conversion again resumes it.
        let r = try withHooks { try Xipper.convertWithLittleSpace(a, to: target, options: xiz()) }
        #expect(r.output == target.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: a.path))
        try extractsToSource(t, target)
    }

    /// After a reboot the volume's st_dev is often another number (power-cut test in a VM, 3.2):
    /// the conversion must resume all the same, journals of 3.0 and 3.1 (no volume UUID) included.
    @Test(arguments: [true, false])
    func resumesWhenTheDeviceNumberChanged(oldJournal: Bool) throws {
        let t = TempDir()
        let a = try source(t, .zip)
        let target = t.url("a.xiz")
        #expect(throws: XipperError.cancelled) {
            try withHooks(stop: "batch1-released") { try Xipper.convertWithLittleSpace(a, to: target, options: xiz()) }
        }
        let url = LowSpaceConverter.journalURL(a.standardizedFileURL)
        var j = try LowSpaceConverter.read(url)
        #expect(j.volume != nil && j.volume == LowSpaceConverter.volumeUUID(a))
        j.device += 3
        if oldJournal { j.volume = nil }
        try LowSpaceConverter.write(j, to: url)
        _ = try withHooks { try Xipper.convertWithLittleSpace(a, to: target, options: xiz()) }
        #expect(!FileManager.default.fileExists(atPath: a.path))
        try extractsToSource(t, target)
    }

    /// Another volume (a copy of the original elsewhere) is still refused.
    @Test func refusesTheOriginalOnAnotherVolume() throws {
        let t = TempDir()
        let a = try source(t, .zip)
        #expect(throws: XipperError.cancelled) {
            try withHooks(stop: "batch1-released") { try Xipper.convertWithLittleSpace(a, to: t.url("a.xiz"), options: xiz()) }
        }
        let url = LowSpaceConverter.journalURL(a.standardizedFileURL)
        var j = try LowSpaceConverter.read(url)
        j.volume = UUID().uuidString
        try LowSpaceConverter.write(j, to: url)
        #expect(throws: XipperError.self) { _ = try withHooks { try Xipper.convertWithLittleSpace(a, to: t.url("a.xiz"), options: xiz()) } }
    }

    @Test(arguments: ["batch0-written", "batch1-written", "verified", "renamed"])
    func resumesFromEveryStep(step: String) throws {
        let t = TempDir()
        let a = try source(t, .zip)
        let target = t.url("a.xiz")
        #expect(throws: XipperError.cancelled) {
            try withHooks(stop: step) { try Xipper.convertWithLittleSpace(a, to: target, options: xiz()) }
        }
        let journal = URL(fileURLWithPath: a.path + LowSpaceConverter.journalSuffix)
        #expect(FileManager.default.fileExists(atPath: journal.path))
        // What a run killed while writing the first segment leaves behind.
        let leftover = t.path + "/." + LowSpaceConverter.stagedURL(target).lastPathComponent + ".xiptmp-12345"
        FileManager.default.createFile(atPath: leftover, contents: Data(count: 1000))
        try withHooks { _ = try Xipper.resumeConversion(journal) }
        #expect(!FileManager.default.fileExists(atPath: leftover))
        #expect(!FileManager.default.fileExists(atPath: journal.path))
        #expect(!FileManager.default.fileExists(atPath: a.path))
        try extractsToSource(t, target)
    }

    @Test func anErrorBeforeAnythingIsReleasedLeavesTheOriginal() throws {
        let t = TempDir()
        let a = try source(t, .zip)
        let before = try Data(contentsOf: a)
        let cancel = CancellationToken()
        cancel.cancel()
        #expect(throws: XipperError.cancelled) {
            try withHooks { try Xipper.convertWithLittleSpace(a, to: t.url("a.xiz"), options: xiz(), cancel: cancel) }
        }
        #expect(try Data(contentsOf: a) == before)
        #expect(Xipper.interruptedConversion(of: a) == nil)
        #expect(!FileManager.default.fileExists(atPath: LowSpaceConverter.stagedURL(t.url("a.xiz")).path))
    }

    @Test func encryptedBothWays() throws {
        let t = TempDir()
        makeTree(t, bigSize: 2 << 20)
        for i in 0..<8 { t.write("src/many/f\(i).bin", sampleData(400_000, seed: UInt64(i))) }
        var o = CreateOptions()
        o.format = .sevenZip
        o.password = "vecchia"
        o.solidBlockSize = 0
        let a = t.url("a.7z")
        try Xipper.create(from: [t.url("src")], to: a, options: o)
        var x = xiz()
        x.password = "nuova"
        x.xizKDF = .minimum
        let target = t.url("a.xiz")
        #expect(throws: XipperError.cancelled) {
            try withHooks(stop: "batch1-released") { try Xipper.convertWithLittleSpace(a, to: target, password: "vecchia", options: x) }
        }
        let journal = URL(fileURLWithPath: a.path + LowSpaceConverter.journalSuffix)
        #expect(throws: (any Error).self) { try Xipper.resumeConversion(journal, password: "vecchia") }
        try withHooks { _ = try Xipper.resumeConversion(journal, password: "vecchia", newPassword: "nuova") }
        try extractsToSource(t, target, password: "nuova")
    }

    @Test func refusesWhatItCannotDo() throws {
        let t = TempDir()
        let a = try source(t, .zip)
        #expect(Xipper.lowSpaceConversionProblem(a, to: .sevenZip) != nil)
        // A clone shares its blocks: releasing them would free nothing.
        #expect(clonefile(a.path, t.url("copy.zip").path, 0) == 0)
        let problem = Xipper.lowSpaceConversionProblem(a, to: .xiz)
        #expect(problem?.contains("clone") == true, "\(problem ?? "nil")")
        var tar = CreateOptions()
        tar.format = .tarZstd
        try Xipper.create(from: [t.url("src")], to: t.url("a.tar.zst"), options: tar)
        #expect(Xipper.lowSpaceConversionProblem(t.url("a.tar.zst"), to: .xiz) != nil)
    }
}
