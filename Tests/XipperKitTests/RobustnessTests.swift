import Foundation
import Testing
@testable import XipperKit

@Suite("Cancellation and large archives")
struct RobustnessTests {
    /// Folder with ~200 MB of mixed data so jobs last long enough to be cancelled.
    func bigTree(_ t: TempDir) {
        for i in 0..<8 { t.write("src/f\(i).bin", sampleData(25 << 20, seed: UInt64(i + 1))) }
    }

    func leftovers(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.contains(".xiptmp") || $0.contains(".partial") || $0.hasSuffix(".part") }
    }

    @Test(arguments: [ArchiveFormat.zip, .tarXz])
    func cancelledCreationLeavesNothing(format: ArchiveFormat) throws {
        let t = TempDir()
        bigTree(t)
        let cancel = CancellationToken()
        var o = CreateOptions()
        o.format = format
        o.level = format == .tarXz ? 9 : 9
        let out = t.url("out." + format.fileExtension)
        // Cancelled at the first progress report: the job is surely under way, whatever the machine's speed.
        #expect(throws: XipperError.cancelled) {
            try Xipper.create(from: [t.url("src")], to: out, options: o, progress: { _ in cancel.cancel() }, cancel: cancel)
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
        #expect(leftovers(t.path).isEmpty)
    }

    @Test func cancelledExtractionCleansStaging() throws {
        let t = TempDir()
        bigTree(t)
        try Xipper.create(from: [t.url("src")], to: t.url("a.zip"))
        t.mkdir("dest")
        let cancel = CancellationToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { cancel.cancel() }
        var o = ExtractOptions()
        o.workload = .threads(2)
        do {
            try Xipper.extract(t.url("a.zip"), to: t.url("dest"), options: o, cancel: cancel)
        } catch XipperError.cancelled {}
        // Smart mode: either it finished before the cancel, or nothing (not even staging) remains.
        let content = try FileManager.default.contentsOfDirectory(atPath: t.path + "/dest")
        #expect(content.isEmpty || content == ["src"])
        #expect(leftovers(t.path + "/dest").isEmpty)
    }

    /// Real ZIP64: one 4.5 GiB entry (> 4 GiB) and archive offsets beyond 32 bits.
    /// Slow (~10 s, 4.5 GiB of disk): only with XIPPER_BIG_TESTS=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["XIPPER_BIG_TESTS"] != nil))
    func zip64OverFourGiB() throws {
        let t = TempDir()
        let path = t.path + "/src/huge.bin"
        try FileManager.default.createDirectory(atPath: t.path + "/src", withIntermediateDirectories: true)
        // Mostly zeros (fast to compress) with a marker at the end.
        let fd = open(path, O_WRONLY | O_CREAT, 0o644)
        ftruncate(fd, (9 << 29) - 16)  // 4.5 GiB - 16
        lseek(fd, 0, SEEK_END)
        _ = "XIPPER-END-MARK!".withCString { write(fd, $0, 16) }
        close(fd)
        t.write("src/small.txt", "after the big one\n")
        for method in [ZipMethod.deflate, .store] {
            var o = CreateOptions()
            o.zipMethod = method
            let zip = t.url("big-\(method).zip")
            try Xipper.create(from: [t.url("src")], to: zip, options: o)
            #expect(try Xipper.test(zip).isOK)
            let entries = try Xipper.list(zip)
            #expect(entries.first { $0.path == "src/huge.bin" }?.uncompressedSize == 9 << 29)
            if let sz = sevenZip { #expect(run(sz, ["t", zip.path]).status == 0) }
            let tail = try Xipper.readEntry(zip, path: "src/small.txt")
            #expect(String(decoding: tail.data, as: UTF8.self) == "after the big one\n")
            try FileManager.default.removeItem(at: zip)
        }
    }
}
