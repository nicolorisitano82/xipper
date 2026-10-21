import Foundation
import Testing
@testable import XipperKit

/// Editing archives in place (ROADMAP v2 §5): ZIP without recompressing untouched entries, the
/// other formats rebuilt in their format.
@Suite("Editing archives")
struct EditTests {
    func tree(_ t: TempDir) -> [UInt8] {
        let big = sampleData(2 << 20, seed: 61)
        t.write("src/a.txt", "alpha\n")
        t.write("src/big.bin", big)
        t.write("src/sub/c.txt", "gamma\n")
        t.write("src/sub/deep/d.txt", "delta\n")
        t.write("extra/new.txt", "nuovo\n")
        t.write("extra/folder/one.txt", "uno\n")
        t.write("extra/folder/two.txt", "due\n")
        return big
    }

    func paths(_ a: URL, password: String? = nil) throws -> Set<String> {
        Set(try Xipper.list(a, password: password).filter { $0.kind != .directory }.map(\.path))
    }

    func text(_ a: URL, _ p: String, password: String? = nil) throws -> String {
        String(decoding: try Xipper.readEntry(a, path: p, password: password).data, as: UTF8.self)
    }


    func apply(_ t: TempDir, _ a: URL, password: String? = nil) throws -> EditReport {
        try Xipper.edit(a, changes: [
            .delete("src/a.txt"),
            .rename("src/sub", to: "src/renamed"),
            .add(t.url("extra/new.txt"), as: "src/new.txt"),
            .add(t.url("extra/folder"), as: "src/renamed"),  // merges into the renamed folder
            .makeDirectory("src/empty"),
        ], password: password)
    }

    @Test func zipKeepsUntouchedEntriesAsTheyAre() throws {
        let t = TempDir()
        let big = tree(t)
        var o = CreateOptions()
        o.format = .zip
        try Xipper.create(from: [t.url("src")], to: t.url("a.zip"), options: o)
        let before = try ZipArchive(path: t.path + "/a.zip")
        let bigRaw = before.records.first { $0.entry.path == "src/big.bin" }!
        let r = try apply(t, t.url("a.zip"))
        #expect(!r.rebuilt && r.copied >= 4 && r.compressed >= 3)
        #expect(try paths(t.url("a.zip")) == ["src/big.bin", "src/renamed/c.txt", "src/renamed/deep/d.txt", "src/new.txt",
                                               "src/renamed/one.txt", "src/renamed/two.txt"])
        #expect(try Xipper.list(t.url("a.zip")).contains { $0.path == "src/empty" && $0.kind == .directory })
        #expect(try text(t.url("a.zip"), "src/renamed/deep/d.txt") == "delta\n")
        #expect(try text(t.url("a.zip"), "src/renamed/two.txt") == "due\n")
        #expect(try Xipper.readEntry(t.url("a.zip"), path: "src/big.bin", maxBytes: 4 << 20).data == big)
        // Same compressed bytes and CRC: copied, not recompressed.
        let after = try ZipArchive(path: t.path + "/a.zip").records.first { $0.entry.path == "src/big.bin" }!
        #expect(after.compressedSize == bigRaw.compressedSize && after.crc == bigRaw.crc)
        #expect(try Xipper.test(t.url("a.zip")).isOK)
        #expect(run("/usr/bin/unzip", ["-tq", t.path + "/a.zip"]).status == 0)
    }

    @Test func zipFromDittoWithDataDescriptorsAndAES() throws {
        let t = TempDir()
        _ = tree(t)
        // ditto writes data descriptors; the AES archive comes from Xipper.
        #expect(run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", t.path + "/src", t.path + "/d.zip"]).status == 0)
        try Xipper.edit(t.url("d.zip"), changes: [.rename("big.bin", to: "grande.bin"), .delete("sub")])
        #expect(try paths(t.url("d.zip")) == ["a.txt", "grande.bin"])
        #expect(run("/usr/bin/unzip", ["-tq", t.path + "/d.zip"]).status == 0)

        var o = CreateOptions()
        o.format = .zip
        o.password = "segreto"
        try Xipper.create(from: [t.url("src")], to: t.url("e.zip"), options: o)
        _ = try apply(t, t.url("e.zip"), password: "segreto")
        #expect(try text(t.url("e.zip"), "src/renamed/c.txt", password: "segreto") == "gamma\n")
        #expect(try text(t.url("e.zip"), "src/new.txt", password: "segreto") == "nuovo\n")
        #expect(try Xipper.list(t.url("e.zip")).filter { $0.kind == .file }.allSatisfy(\.isEncrypted))
        #expect(try Xipper.test(t.url("e.zip"), password: "segreto").isOK)
    }

    @Test(arguments: [ArchiveFormat.tarZstd, .sevenZip, .appleArchive])
    func otherFormatsAreRebuilt(format: ArchiveFormat) throws {
        let t = TempDir()
        let big = tree(t)
        var o = CreateOptions()
        o.format = format
        o.password = format == .sevenZip ? "pw" : nil
        let a = t.url("a." + format.fileExtension)
        try Xipper.create(from: [t.url("src")], to: a, options: o)
        let r = try apply(t, a, password: o.password)
        #expect(r.rebuilt)
        #expect(try ArchiveFormat.detect(a) == format)
        #expect(try paths(a, password: o.password).contains("src/renamed/one.txt"))
        #expect(!(try paths(a, password: o.password)).contains("src/a.txt"))
        #expect(try Xipper.readEntry(a, path: "src/big.bin", password: o.password, maxBytes: 4 << 20).data == big)
    }

    @Test func invalidChangesLeaveTheArchiveUntouched() throws {
        let t = TempDir()
        _ = tree(t)
        var o = CreateOptions()
        o.format = .zip
        try Xipper.create(from: [t.url("src")], to: t.url("a.zip"), options: o)
        let before = try Data(contentsOf: t.url("a.zip"))
        #expect(throws: XipperError.self) { try Xipper.edit(t.url("a.zip"), changes: [.delete("nope.txt")]) }
        #expect(throws: XipperError.self) { try Xipper.edit(t.url("a.zip"), changes: [.rename("src/a.txt", to: "src/big.bin")]) }
        #expect(throws: XipperError.self) { try Xipper.edit(t.url("a.zip"), changes: [.rename("src", to: "src/inside")]) }
        #expect(throws: XipperError.self) { try Xipper.edit(t.url("a.zip"), changes: [.delete("../etc")]) }
        #expect(throws: XipperError.self) { try Xipper.edit(t.url("a.zip"), changes: [.add(t.url("a.zip"), as: "self.zip")]) }
        #expect(try Data(contentsOf: t.url("a.zip")) == before)
    }

    // MARK: XIZ in place (1.1 segments)

    @Test(arguments: [nil, "segreto"] as [String?])
    func xizAppendsWithoutTouchingWhatIsWritten(password: String?) throws {
        let t = TempDir()
        let big = tree(t)
        var o = CreateOptions()
        o.format = .xiz
        o.password = password
        o.xizKDF = .minimum
        let a = t.url("a.xiz")
        try Xipper.create(from: [t.url("src")], to: a, options: o)
        let original = try [UInt8](Data(contentsOf: a))
        // Same content as big.bin under a new name: deduplicated against the archive, no new frame.
        t.write("extra/copy.bin", big)
        let r = try Xipper.edit(a, changes: [
            .delete("src/a.txt"),
            .rename("src/sub", to: "src/renamed"),
            .add(t.url("extra/new.txt"), as: "src/new.txt"),
            .add(t.url("extra/copy.bin"), as: "src/copy.bin"),
            .makeDirectory("src/empty"),
        ], password: password)
        #expect(!r.rebuilt)
        let after = try [UInt8](Data(contentsOf: a))
        #expect(Array(after.prefix(original.count - Xiz.footerSize)) == Array(original.dropLast(Xiz.footerSize)))  // only appended
        #expect(after.count < original.count + (64 << 10))  // the 2 MiB copy cost nothing
        #expect(try XizArchive(path: a.path, password: password).segments == 2)
        #expect(try paths(a, password: password) == ["src/big.bin", "src/copy.bin", "src/new.txt", "src/renamed/c.txt", "src/renamed/deep/d.txt"])
        #expect(try Xipper.readEntry(a, path: "src/copy.bin", password: password, maxBytes: 4 << 20).data == big)
        #expect(try text(a, "src/renamed/deep/d.txt", password: password) == "delta\n")
        #expect(try Xipper.test(a, password: password).isOK)
        if password != nil { #expect(throws: XipperError.self) { _ = try Xipper.list(a) } }

        // A second segment, then an interrupted third: the archive still opens, the next edit cleans up.
        try Xipper.edit(a, changes: [.rename("src/new.txt", to: "src/nuovo.txt")], password: password)
        #expect(try XizArchive(path: a.path, password: password).segments == 3)
        let good = try Data(contentsOf: a)
        try (good + Data(sampleData(5000, seed: 3))).write(to: a)
        #expect(try paths(a, password: password).contains("src/nuovo.txt"))
        try Xipper.edit(a, changes: [.delete("src/copy.bin")], password: password)
        #expect(try XizArchive(path: a.path, password: password).segments == 4)
        #expect(try Xipper.test(a, password: password).isOK)

        // Compaction rewrites a single segment without the deleted data.
        let before = try Data(contentsOf: a).count
        try Xipper.edit(a, changes: [.delete("src/big.bin")], password: password, compact: true)
        #expect(try XizArchive(path: a.path, password: password).segments == 1)
        #expect(try Data(contentsOf: a).count < before)
        t.mkdir("out")
        var x = ExtractOptions()
        x.password = password
        try Xipper.extract(a, to: t.url("out"), mode: .into, options: x)
        #expect(try String(contentsOfFile: t.path + "/out/src/nuovo.txt", encoding: .utf8) == "nuovo\n")
    }
}
