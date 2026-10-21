import Foundation
import Testing
@testable import XipperKit

/// Malicious archives are built with Python's zipfile/tarfile, which write whatever names they are given.
@Suite("Extraction safety")
struct SecurityTests {
    func python(_ script: String, _ args: [String]) {
        let r = run("/usr/bin/python3", ["-I", "-c", script] + args)
        precondition(r.status == 0, r.output)
    }

    func nothingOutside(_ t: TempDir) -> Bool {
        !FileManager.default.fileExists(atPath: t.path + "/evil.txt") &&
            !FileManager.default.fileExists(atPath: t.path + "/outside/pwned")
    }

    @Test func zipSlipAbsoluteAndSymlinkTraversal() throws {
        let t = TempDir()
        t.mkdir("outside")
        let zip = t.path + "/evil.zip"
        python("""
        import zipfile, sys, stat
        z = zipfile.ZipFile(sys.argv[1], 'w')
        z.writestr('ok.txt', 'fine')
        z.writestr('../evil.txt', 'slip')
        z.writestr('a/../../evil.txt', 'slip2')
        z.writestr('/tmp/xipper-abs-test.txt', 'abs')
        def link(name, target):
            i = zipfile.ZipInfo(name); i.create_system = 3
            i.external_attr = (stat.S_IFLNK | 0o777) << 16
            z.writestr(i, target)
        link('escape', '../outside')
        link('abs-link', '/etc')
        link('inside-link', 'ok.txt')
        z.writestr('escape/pwned', 'through symlink')
        z.close()
        """, [zip])
        t.mkdir("dest")
        let r = try Xipper.extract(URL(fileURLWithPath: zip), to: t.url("dest"), mode: .into)
        #expect(nothingOutside(t))
        #expect(FileManager.default.fileExists(atPath: t.path + "/dest/ok.txt"))
        // Absolute paths are made relative, not written to /tmp.
        #expect(!FileManager.default.fileExists(atPath: "/tmp/xipper-abs-test.txt"))
        #expect(FileManager.default.fileExists(atPath: t.path + "/dest/tmp/xipper-abs-test.txt"))
        // Inside link kept, outside links skipped.
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: t.path + "/dest/inside-link")) == "ok.txt")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: t.path + "/dest/escape")) == nil)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: t.path + "/dest/abs-link")) == nil)
        let reasons = r.skipped.map(\.path)
        #expect(reasons.contains("../evil.txt"))
        #expect(reasons.contains("escape"))
        #expect(reasons.contains("abs-link"))
    }

    @Test func preexistingSymlinkInDestinationIsNotFollowed() throws {
        let t = TempDir()
        t.mkdir("outside")
        t.mkdir("dest")
        t.symlink("dest/dir", to: t.path + "/outside")
        let zip = t.path + "/a.zip"
        python("""
        import zipfile, sys
        z = zipfile.ZipFile(sys.argv[1], 'w'); z.writestr('dir/pwned', 'x'); z.close()
        """, [zip])
        let r = try Xipper.extract(URL(fileURLWithPath: zip), to: t.url("dest"), mode: .into)
        #expect(nothingOutside(t))
        #expect(r.skipped.contains { $0.path == "dir/pwned" })
    }

    @Test func tarTraversalAndHardlinks() throws {
        let t = TempDir()
        t.mkdir("outside")
        let tar = t.path + "/evil.tar.gz"
        python("""
        import tarfile, sys, io
        tf = tarfile.open(sys.argv[1], 'w:gz')
        def add(name, data=b'x', **kw):
            i = tarfile.TarInfo(name); i.size = len(data)
            for k, v in kw.items(): setattr(i, k, v)
            tf.addfile(i, io.BytesIO(data) if i.type == tarfile.REGTYPE else None)
        add('ok.txt', b'fine')
        add('../evil.txt')
        i = tarfile.TarInfo('hl'); i.type = tarfile.LNKTYPE; i.linkname = '/etc/passwd'; tf.addfile(i)
        i = tarfile.TarInfo('hl2'); i.type = tarfile.LNKTYPE; i.linkname = 'ok.txt'; tf.addfile(i)
        i = tarfile.TarInfo('sl'); i.type = tarfile.SYMTYPE; i.linkname = '../outside'; tf.addfile(i)
        add('sl/pwned')
        tf.close()
        """, [tar])
        t.mkdir("dest")
        let r = try Xipper.extract(URL(fileURLWithPath: tar), to: t.url("dest"), mode: .into)
        #expect(nothingOutside(t))
        #expect(FileManager.default.contents(atPath: t.path + "/dest/hl2") == Data("fine".utf8))
        // "/etc/passwd" is sanitized to "etc/passwd" inside the destination, which does not exist: no link.
        #expect(!FileManager.default.fileExists(atPath: t.path + "/dest/hl"))
        #expect(r.skipped.contains { $0.path == "sl" })
    }

    @Test func overlappingEntriesAreRejected() throws {
        let t = TempDir()
        let zip = t.path + "/overlap.zip"
        // Two central directory records pointing at the same local header (the "better zip bomb" trick).
        python("""
        import zipfile, sys, struct
        z = zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_DEFLATED); z.writestr('a', b'A'*100000); z.close()
        d = bytearray(open(sys.argv[1], 'rb').read())
        eocd = d.rfind(b'PK\\x05\\x06'); cdo = struct.unpack('<I', d[eocd+16:eocd+20])[0]
        cd = d[cdo:eocd]
        rec2 = bytearray(cd); rec2[46:47] = b'b'
        out = d[:cdo] + cd + rec2
        n = struct.pack('<HH', 2, 2); size = struct.pack('<I', len(cd)*2)
        tail = d[eocd:]; tail[8:12] = n; tail[12:16] = size
        open(sys.argv[1], 'wb').write(out + tail)
        """, [zip])
        #expect(throws: XipperError.self) { try Xipper.extract(URL(fileURLWithPath: zip), to: t.url("")) }
        #expect(throws: XipperError.self) { _ = try Xipper.list(URL(fileURLWithPath: zip)) }
    }

    @Test func ratioBombIsRefusedBeforeWriting() throws {
        let t = TempDir()
        let zip = t.path + "/bomb.zip"
        python("""
        import zipfile, sys
        z = zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_DEFLATED, compresslevel=9)
        with z.open('zeros.bin', 'w', force_zip64=True) as f:
            chunk = b'\\0' * (1 << 20)
            for _ in range(300): f.write(chunk)
        z.close()
        """, [zip])
        t.mkdir("dest")
        do {
            _ = try Xipper.extract(URL(fileURLWithPath: zip), to: t.url("dest"))
            Issue.record("bomb extracted")
        } catch let XipperError.limitExceeded(m) {
            #expect(m.contains("zip bomb"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.path + "/dest").isEmpty)
        // An explicit higher limit allows it.
        var o = ExtractOptions()
        o.limits.maxCompressionRatio = 1_000_000
        let r = try Xipper.extract(URL(fileURLWithPath: zip), to: t.url("dest"), options: o)
        #expect(r.bytes == 300 << 20)
    }

    @Test func totalSizeLimitStopsExtraction() throws {
        let t = TempDir()
        makeTree(t)
        let archive = t.url("a.tar.zst")
        var c = CreateOptions(); c.format = .tarZstd
        try Xipper.create(from: [t.url("src")], to: archive, options: c)
        var o = ExtractOptions()
        o.limits.maxTotalBytes = 1 << 20
        t.mkdir("dest")
        #expect(throws: XipperError.self) { try Xipper.extract(archive, to: t.url("dest"), options: o) }
        // Smart mode cleans up its staging folder on failure.
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.path + "/dest").isEmpty)
    }

    @Test func quarantineIsPropagatedAndSetuidDropped() throws {
        let t = TempDir()
        t.write("src/tool", Array("#!/bin/sh\n".utf8), mode: 0o4755)
        let archive = t.url("q.zip")
        try Xipper.create(from: [t.url("src")], to: archive)
        let q = "0081;6720a1b2;Safari;"
        _ = q.withCString { setxattr(archive.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        t.mkdir("dest")
        let r = try Xipper.extract(archive, to: t.url("dest"))
        let file = r.destination.path + "/tool"
        #expect(ExtractionContext.readXattr(file, "com.apple.quarantine").map { String(decoding: $0, as: UTF8.self) } == q)
        let mode = (try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as! NSNumber).uint16Value
        #expect(mode == 0o755)
    }

    @Test func truncatedAndCorruptedArchivesFail() throws {
        let t = TempDir()
        makeTree(t)
        for format in [ArchiveFormat.zip, .tarGzip, .tarXz, .tarZstd] {
            var c = CreateOptions(); c.format = format
            let archive = t.url("c." + format.fileExtension)
            try Xipper.create(from: [t.url("src")], to: archive, options: c)
            var data = try Data(contentsOf: archive)
            // Flip bytes in the middle of the compressed data.
            for i in stride(from: data.count / 2, to: data.count / 2 + 64, by: 1) { data[i] ^= 0x5A }
            try data.write(to: archive)
            let ok = (try? Xipper.test(archive).isOK) ?? false
            #expect(!ok, "\(format) corruption not detected")
        }
    }
}
