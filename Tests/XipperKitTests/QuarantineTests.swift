import Foundation
import Testing
@testable import XipperKit

/// The archive's com.apple.quarantine reaches everything that leaves it, so Gatekeeper checks what
/// came from the internet. Regressions of the bugs other archivers had: CVE-2025-0411 (7-Zip,
/// nested archives), CVE-2022-42821 / CVE-2021-1810 (Archive Utility), and a quarantine value
/// smuggled inside the archive.
@Suite("Quarantine propagation")
struct QuarantineTests {
    static let value = "0083;6720a000;Safari;"

    static func quarantine(_ path: String) -> String? {
        let n = getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
        guard n > 0 else { return nil }
        var b = [UInt8](repeating: 0, count: n)
        _ = getxattr(path, "com.apple.quarantine", &b, n, 0, XATTR_NOFOLLOW)
        return String(decoding: b, as: UTF8.self)
    }
    static func setQuarantine(_ path: String, _ v: String = value) {
        _ = v.withCString { setxattr(path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
    }

    func tree(_ t: TempDir) {
        t.write("src/a.txt", "alpha\n")
        t.write("src/tool.sh", Array("#!/bin/sh\n".utf8), mode: 0o755)
        t.mkdir("src/sub/empty")
        t.symlink("src/link", to: "a.txt")
    }

    func archive(_ t: TempDir, _ format: ArchiveFormat, sources: [String] = ["src"], name: String = "a") throws -> URL {
        var o = CreateOptions()
        o.format = format
        let url = t.url(name + "." + format.fileExtension)
        try Xipper.create(from: sources.map { t.url($0) }, to: url, options: o)
        return url
    }

    /// Every item below `root`, links included.
    static func allItems(_ root: String) -> [String] {
        var out = [root]
        if let e = FileManager.default.enumerator(atPath: root) { for case let p as String in e { out.append(root + "/" + p) } }
        return out
    }

    @Test(arguments: [ArchiveFormat.zip, .sevenZip, .tarZstd, .appleArchive, .xiz, .cpio])
    func everyExtractedItemIsQuarantined(format: ArchiveFormat) throws {
        let t = TempDir()
        tree(t)
        let a = try archive(t, format)
        Self.setQuarantine(a.path)
        t.mkdir("out")
        let r = try Xipper.extract(a, to: t.url("out"))
        let items = Self.allItems(r.destination.path)
        #expect(items.count >= 6)
        for p in items { #expect(Self.quarantine(p) == Self.value, "\(format): \(p)") }
    }

    @Test func noQuarantineWhenTheArchiveHasNoneOrWhenDisabled() throws {
        let t = TempDir()
        tree(t)
        let a = try archive(t, .zip)
        t.mkdir("plain")
        for p in Self.allItems(try Xipper.extract(a, to: t.url("plain")).destination.path) { #expect(Self.quarantine(p) == nil) }
        Self.setQuarantine(a.path)
        var o = ExtractOptions()
        o.propagateQuarantine = false
        t.mkdir("off")
        for p in Self.allItems(try Xipper.extract(a, to: t.url("off"), options: o).destination.path) { #expect(Self.quarantine(p) == nil) }
    }

    /// CVE-2025-0411: an archive inside a downloaded archive lost the mark, and so did what it held.
    @Test func nestedArchivesKeepTheMark() throws {
        let t = TempDir()
        tree(t)
        _ = try archive(t, .zip, name: "inner")
        t.mkdir("outer")
        try FileManager.default.moveItem(at: t.url("inner.zip"), to: t.url("outer/inner.zip"))
        let outer = try archive(t, .sevenZip, sources: ["outer"], name: "outer")
        Self.setQuarantine(outer.path)
        t.mkdir("x1")
        let r1 = try Xipper.extract(outer, to: t.url("x1"))
        let inner = r1.destination.appendingPathComponent("inner.zip")
        #expect(Self.quarantine(inner.path) == Self.value)
        t.mkdir("x2")
        let r2 = try Xipper.extract(inner, to: t.url("x2"))
        for p in Self.allItems(r2.destination.path) { #expect(Self.quarantine(p) == Self.value, "\(p)") }
    }

    /// What the browser stages for Quick Look, dragging and opening an entry (mode .into, a selection).
    @Test func stagedEntriesAreQuarantined() throws {
        let t = TempDir()
        tree(t)
        let a = try archive(t, .zip)
        Self.setQuarantine(a.path)
        t.mkdir("stage")
        var o = ExtractOptions()
        o.selection = ["src/tool.sh"]
        _ = try Xipper.extract(a, to: t.url("stage"), mode: .into, options: o)
        #expect(Self.quarantine(t.path + "/stage/src/tool.sh") == Self.value)
    }

    /// A quarantine attribute stored inside the archive (Apple Archive keeps extended attributes)
    /// is never restored: it could carry the "user approved" flag, or hide the real origin.
    @Test(.enabled(if: toolExists("/usr/bin/aa")))
    func quarantineStoredInsideTheArchiveIsIgnored() throws {
        let t = TempDir()
        t.write("src/app.sh", Array("#!/bin/sh\n".utf8), mode: 0o755)
        Self.setQuarantine(t.path + "/src/app.sh", "00c3;6720a000;Approved;")  // 0x40: user approved
        run("/usr/bin/aa", ["archive", "-d", t.path + "/src", "-o", t.path + "/inside.aar", "-include-field", "xat"])
        let a = t.url("inside.aar")
        t.mkdir("x")
        let plain = try Xipper.extract(a, to: t.url("x"))
        for p in Self.allItems(plain.destination.path) { #expect(Self.quarantine(p) == nil, "\(p)") }
        Self.setQuarantine(a.path)
        t.mkdir("y")
        let marked = try Xipper.extract(a, to: t.url("y"))
        for p in Self.allItems(marked.destination.path) { #expect(Self.quarantine(p) == Self.value, "\(p)") }
    }

    // MARK: mounted volumes (CVE-2022-42821 class: an app opened from the volume skipped Gatekeeper)

    @Test func mountedTreeServesQuarantineSidecars() throws {
        let t = TempDir()
        tree(t)
        let a = try archive(t, .zip)
        Self.setQuarantine(a.path)
        let m = try MountedArchive(archive: a, writable: false)
        defer { m.close() }
        for item in ["src/a.txt", "src/sub", "src"] {
            let side = (item as NSString).deletingLastPathComponent
            let path = (side.isEmpty ? "" : side + "/") + "._" + (item as NSString).lastPathComponent
            #expect(m.info(path) != nil, "\(path)")
            var bytes: [UInt8] = []
            try m.read(path) { bytes += $0 }
            #expect(bytes.count == Int(m.info(path)?.size ?? -1))
            #expect(String(decoding: bytes, as: UTF8.self).contains(Self.value), "\(path)")
        }
        #expect(m.info("src/._missing") == nil)
        #expect(!m.children("src").contains { $0.name.hasPrefix("._") })

        let off = try MountedArchive(archive: a, writable: false, propagateQuarantine: false)
        defer { off.close() }
        #expect(off.info("src/._a.txt") == nil)
    }

    @Test(.enabled(if: MountTests.canMount), .timeLimit(.minutes(1)))
    func realMountShowsTheQuarantine() throws {
        let t = TempDir()
        tree(t)
        let a = try archive(t, .zip)
        Self.setQuarantine(a.path)
        let mount = try ArchiveMount(archive: a, writable: false)
        let point = try mount.mount(at: nil)
        defer { try? mount.unmount(); try? mount.finish(save: false) }
        #expect(Self.quarantine(point.path + "/src/a.txt") == Self.value)
        #expect(Self.quarantine(point.path + "/src/tool.sh") == Self.value)
        #expect(Self.quarantine(point.path + "/src/sub") == Self.value)
    }
}
