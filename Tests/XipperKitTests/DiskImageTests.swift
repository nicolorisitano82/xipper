import Foundation
import Testing
@testable import XipperKit

/// Disc and disk images, read only (3.4): ISO 9660 through libarchive, UDF and Apple disk images
/// through hdiutil. The images are made here with hdiutil from a small tree.
@Suite("Disk images (read only)", .serialized)
struct DiskImageTests {
    func tree(_ t: TempDir) {
        t.write("src/a.txt", "uno\n")
        t.write("src/sub/b.bin", sampleData(200_000, seed: 9))
        t.write("src/sub/deep/c.txt", "tre\n")
    }

    func make(_ t: TempDir, _ args: [String]) {
        let r = run("/usr/bin/hdiutil", args)
        #expect(r.status == 0, "\(r.output)")
    }

    /// Nothing made by these tests is left attached.
    func attachedImages(_ t: TempDir) -> [String] {
        let r = run("/usr/bin/hdiutil", ["info"])
        return r.output.split(separator: "\n").filter { $0.hasPrefix("image-path") && $0.contains(t.path) }.map(String.init)
    }

    func checkFiles(_ t: TempDir, _ image: URL, format: ArchiveFormat, password: String? = nil) throws {
        #expect(try ArchiveFormat.detect(image) == format)
        let files = Set(try Xipper.list(image, password: password).filter { $0.kind == .file }.map(\.path))
        #expect(files == ["a.txt", "sub/b.bin", "sub/deep/c.txt"])
        let out = t.url("out-\(image.lastPathComponent)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var options = ExtractOptions()
        options.password = password
        try Xipper.extract(image, to: out, mode: .into, options: options)
        #expect(try Data(contentsOf: out.appendingPathComponent("sub/b.bin")) == Data(sampleData(200_000, seed: 9)))
        #expect(try String(contentsOf: out.appendingPathComponent("sub/deep/c.txt"), encoding: .utf8) == "tre\n")
        #expect(try Xipper.test(image, password: password).isOK)
        #expect(try Xipper.readEntry(image, path: "a.txt", password: password, maxBytes: 100).data == Array("uno\n".utf8))
        #expect(attachedImages(t).isEmpty)
    }

    @Test func iso9660() throws {
        let t = TempDir()
        tree(t)
        make(t, ["makehybrid", "-quiet", "-iso", "-joliet", "-o", t.path + "/x.iso", t.path + "/src"])
        #expect(DiskImage.kind(t.path + "/x.iso") == .iso9660)
        try checkFiles(t, t.url("x.iso"), format: .iso)
    }

    @Test func udfAndBridge() throws {
        let t = TempDir()
        tree(t)
        make(t, ["makehybrid", "-quiet", "-udf", "-o", t.path + "/u.iso", t.path + "/src"])
        make(t, ["makehybrid", "-quiet", "-iso", "-joliet", "-udf", "-o", t.path + "/h.iso", t.path + "/src"])
        #expect(DiskImage.kind(t.path + "/u.iso") == .udf)
        #expect(DiskImage.kind(t.path + "/h.iso") == .udf)  // a bridge disc: the UDF side is read
        try checkFiles(t, t.url("u.iso"), format: .iso)
        try checkFiles(t, t.url("h.iso"), format: .iso)
    }

    @Test func appleDiskImages() throws {
        let t = TempDir()
        tree(t)
        make(t, ["create", "-quiet", "-srcfolder", t.path + "/src", "-format", "UDZO", "-volname", "Prova", t.path + "/x.dmg"])
        make(t, ["create", "-quiet", "-srcfolder", t.path + "/src", "-format", "UDTO", "-volname", "Raw", t.path + "/r.cdr"])
        #expect(DiskImage.kind(t.path + "/x.dmg") == .appleImage(encrypted: false))
        try checkFiles(t, t.url("x.dmg"), format: .dmg)
        try checkFiles(t, t.url("r.cdr"), format: .dmg)
        #expect(Xipper.baseName("x.dmg") == "x" && Xipper.baseName("disc.iso") == "disc")
        #expect(!ArchiveFormat.dmg.canCreate && !ArchiveFormat.iso.canCreate)
    }

    @Test func encryptedDiskImage() throws {
        let t = TempDir()
        tree(t)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["create", "-quiet", "-srcfolder", t.path + "/src", "-format", "UDZO", "-encryption", "AES-256",
                       "-stdinpass", t.path + "/e.dmg"]
        let input = Pipe()
        p.standardInput = input
        try p.run()
        input.fileHandleForWriting.write(Data("segreta".utf8) + [0])
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(DiskImage.kind(t.path + "/e.dmg") == .appleImage(encrypted: true))
        #expect(throws: XipperError.passwordRequired(entry: "e.dmg")) { _ = try Xipper.list(t.url("e.dmg")) }
        #expect(throws: XipperError.wrongPassword(entry: "e.dmg")) { _ = try Xipper.list(t.url("e.dmg"), password: "sbagliata") }
        try checkFiles(t, t.url("e.dmg"), format: .dmg, password: "segreta")
    }

    @Test func notImages() throws {
        let t = TempDir()
        t.write("plain.iso", sampleData(100_000))
        #expect(DiskImage.kind(t.path + "/plain.iso") == nil)
        t.write("short.dmg", "koly")
        #expect(DiskImage.kind(t.path + "/short.dmg") == nil)
    }
}
