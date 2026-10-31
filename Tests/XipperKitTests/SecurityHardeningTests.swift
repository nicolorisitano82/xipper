import Foundation
import Testing
@testable import XipperKit
@testable import XipperMCP

/// Attacks beyond the classic zip-slip (SecurityTests): symlink chains, hard links through links
/// already on disk, case and Unicode aliases, special files, hostile permissions and extended
/// attributes, encryption leaks, and the WebDAV and MCP front doors.
@Suite("Security hardening")
struct SecurityHardeningTests {
    func python(_ script: String, _ args: [String]) {
        let r = run("/usr/bin/python3", ["-I", "-c", script] + args)
        precondition(r.status == 0, r.output)
    }

    /// Every symlink below `root` resolves (physically, following other links) inside `root`.
    func linksEscaping(_ root: String) -> [String] {
        guard let rr = realpath(root, nil) else { return [] }
        let realRoot = String(cString: rr)
        free(rr)
        var out: [String] = []
        guard let e = FileManager.default.enumerator(atPath: root) else { return out }
        for case let rel as String in e {
            var st = stat()
            guard lstat(root + "/" + rel, &st) == 0, st.st_mode & S_IFMT == S_IFLNK else { continue }
            // Resolve without requiring the target to exist: realpath of the deepest existing part.
            var target = root + "/" + rel
            var resolved: String?
            for _ in 0..<40 {
                if let r = realpath(target, nil) { resolved = String(cString: r); free(r); break }
                target = (target as NSString).deletingLastPathComponent
            }
            let r = resolved ?? "/"
            if !(r == realRoot || r.hasPrefix(realRoot + "/")) { out.append("\(rel) -> \(r)") }
        }
        return out
    }

    // MARK: links

    /// "a/b" → ".." is inside, "c" → "a/b/../.." is lexically inside too, but on disk it climbs
    /// above the destination through the first link.
    @Test(arguments: ["tar", "zip"])
    func symlinkChainsCannotPointOutside(kind: String) throws {
        let t = TempDir()
        t.mkdir("dest")
        let a = t.path + "/chain." + kind
        python("""
        import sys, io, stat, tarfile, zipfile
        links = [('a/b', '..'), ('c', 'a/b/../..'), ('d', 'a/b/b/b/..'), ('e/f', '../a/b/../../..')]
        if sys.argv[1].endswith('.tar'):
            tf = tarfile.open(sys.argv[1], 'w')
            for n, target in links:
                i = tarfile.TarInfo(n); i.type = tarfile.SYMTYPE; i.linkname = target; tf.addfile(i)
            tf.close()
        else:
            z = zipfile.ZipFile(sys.argv[1], 'w')
            for n, target in links:
                i = zipfile.ZipInfo(n); i.create_system = 3; i.external_attr = (stat.S_IFLNK | 0o777) << 16
                z.writestr(i, target)
            z.close()
        """, [a])
        _ = try Xipper.extract(URL(fileURLWithPath: a), to: t.url("dest"), mode: .into)
        let bad = linksEscaping(t.path + "/dest")
        #expect(bad.isEmpty, "links escaping the destination: \(bad)")
    }

    /// The destination already holds "dir" → outside; a hard link "hl" → "dir/secret" must not
    /// make the outside file reachable (and writable) from inside the destination.
    @Test func hardLinkThroughExistingSymlinkIsRefused() throws {
        let t = TempDir()
        t.write("outside/secret", "top secret\n")
        t.mkdir("dest")
        t.symlink("dest/dir", to: t.path + "/outside")
        let a = t.path + "/hl.tar"
        python("""
        import sys, tarfile
        tf = tarfile.open(sys.argv[1], 'w')
        i = tarfile.TarInfo('hl'); i.type = tarfile.LNKTYPE; i.linkname = 'dir/secret'; tf.addfile(i)
        tf.close()
        """, [a])
        _ = try? Xipper.extract(URL(fileURLWithPath: a), to: t.url("dest"), mode: .into)
        var inside = stat(), outside = stat()
        let linked = lstat(t.path + "/dest/hl", &inside) == 0 && stat(t.path + "/outside/secret", &outside) == 0
            && inside.st_ino == outside.st_ino
        #expect(!linked, "hard link to a file outside the destination")
    }

    /// APFS is case- and normalization-insensitive: "LINK/x" and "lin\u{301}k/x" name the same
    /// folder as the link "link". Even with every link allowed, no file lands outside.
    @Test(arguments: [SymlinkPolicy.insideDestinationOnly, .allowAll])
    func caseAndUnicodeAliasesDoNotRedirectWrites(policy: SymlinkPolicy) throws {
        let t = TempDir()
        t.mkdir("outside")
        t.mkdir("dest")
        let a = t.path + "/alias.zip"
        python("""
        import sys, stat, zipfile
        z = zipfile.ZipFile(sys.argv[1], 'w')
        def link(n, target):
            i = zipfile.ZipInfo(n); i.create_system = 3; i.external_attr = (stat.S_IFLNK | 0o777) << 16
            z.writestr(i, target)
        link('link', sys.argv[2])
        z.writestr('LINK/pwned1', 'x')
        z.writestr('Link/pwned2', 'x')
        link('caf\\u00e9', sys.argv[2])
        z.writestr('cafe\\u0301/pwned3', 'x')
        z.close()
        """, [a, t.path + "/outside"])
        var o = ExtractOptions()
        o.symlinks = policy
        _ = try? Xipper.extract(URL(fileURLWithPath: a), to: t.url("dest"), mode: .into, options: o)
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.path + "/outside").isEmpty)
    }

    /// A symlink entry followed by a file entry with the same name: the file must not be
    /// written through the link, in any format that stores links.
    @Test(arguments: ["tar", "cpio"])
    func fileAfterSymlinkWithSameNameStaysInside(kind: String) throws {
        let t = TempDir()
        t.write("outside/target.txt", "original\n")
        t.mkdir("dest")
        let a = t.path + "/dup." + kind
        if kind == "tar" {
            python("""
            import sys, io, tarfile
            tf = tarfile.open(sys.argv[1], 'w')
            i = tarfile.TarInfo('f'); i.type = tarfile.SYMTYPE; i.linkname = sys.argv[2]; tf.addfile(i)
            d = b'overwritten'; i = tarfile.TarInfo('f'); i.size = len(d); tf.addfile(i, io.BytesIO(d))
            tf.close()
            """, [a, t.path + "/outside/target.txt"])
        } else {
            t.mkdir("cp")
            t.symlink("cp/f", to: t.path + "/outside/target.txt")
            let r = run("/bin/sh", ["-c", "cd '\(t.path)/cp' && (echo f; echo f) | /usr/bin/cpio -o -H newc > '\(a)' 2>/dev/null; rm f; printf overwritten > f; echo f | /usr/bin/cpio -o -H newc >> '\(a)' 2>/dev/null; true"])
            #expect(r.status == 0)
        }
        var o = ExtractOptions()
        o.symlinks = .allowAll
        o.overwrite = .replace
        _ = try? Xipper.extract(URL(fileURLWithPath: a), to: t.url("dest"), mode: .into, options: o)
        #expect(FileManager.default.contents(atPath: t.path + "/outside/target.txt") == Data("original\n".utf8))
    }

    // MARK: special files, permissions, attributes

    /// FIFOs and device nodes are listed but never created.
    @Test func specialFilesAreNeverCreated() throws {
        let t = TempDir()
        t.mkdir("dest")
        let a = t.path + "/special.tar"
        python("""
        import sys, tarfile
        tf = tarfile.open(sys.argv[1], 'w')
        for name, kind in [('fifo', tarfile.FIFOTYPE), ('chr', tarfile.CHRTYPE), ('blk', tarfile.BLKTYPE)]:
            i = tarfile.TarInfo(name); i.type = kind; i.devmajor = 1; i.devminor = 3; tf.addfile(i)
        tf.close()
        """, [a])
        _ = try? Xipper.extract(URL(fileURLWithPath: a), to: t.url("dest"), mode: .into)
        for n in ["fifo", "chr", "blk"] {
            var st = stat()
            if lstat(t.path + "/dest/" + n, &st) == 0 {
                #expect(st.st_mode & S_IFMT == S_IFREG || st.st_mode & S_IFMT == S_IFDIR, "\(n) created as a special file")
            }
        }
    }

    /// setuid/setgid/sticky never survive; a folder stored as 000 stays usable by its owner;
    /// ownership is never taken from the archive.
    @Test func hostilePermissionsAreSanitized() throws {
        let t = TempDir()
        t.mkdir("dest")
        let a = t.path + "/perm.tar"
        python("""
        import sys, io, tarfile
        tf = tarfile.open(sys.argv[1], 'w')
        i = tarfile.TarInfo('locked'); i.type = tarfile.DIRTYPE; i.mode = 0o000; tf.addfile(i)
        d = b'#!/bin/sh\\n'
        for name, mode in [('locked/suid', 0o4755), ('sgid', 0o2755), ('sticky', 0o1777), ('root', 0o644)]:
            i = tarfile.TarInfo(name); i.size = len(d); i.mode = mode; i.uid = 0; i.gid = 0; i.uname = 'root'; i.gname = 'wheel'
            tf.addfile(i, io.BytesIO(d))
        tf.close()
        """, [a])
        _ = try Xipper.extract(URL(fileURLWithPath: a), to: t.url("dest"), mode: .into)
        for n in ["locked/suid", "sgid", "sticky", "root"] {
            var st = stat()
            #expect(lstat(t.path + "/dest/" + n, &st) == 0, "\(n) missing")
            #expect(st.st_mode & (S_ISUID | S_ISGID | S_ISVTX) == 0, "\(n) kept special bits")
            #expect(st.st_uid == getuid(), "\(n) owned by \(st.st_uid)")
        }
        var st = stat()
        #expect(stat(t.path + "/dest/locked", &st) == 0 && st.st_mode & 0o700 == 0o700)
    }

    /// An archive cannot clear or replace the quarantine Xipper propagates from the download,
    /// nor write security-relevant attributes through stored xattrs.
    @Test func storedQuarantineCannotOverrideTheDownloadOne() throws {
        let t = TempDir()
        t.write("src/app.sh", Array("#!/bin/sh\n".utf8), mode: 0o755)
        let fake = "0000;00000000;Attacker;"
        _ = fake.withCString { setxattr(t.path + "/src/app.sh", "com.apple.quarantine", $0, strlen($0), 0, 0) }
        var o = CreateOptions()
        o.format = .tar
        let a = t.url("x.tar")
        try Xipper.create(from: [t.url("src")], to: a, options: o)
        let real = "0083;6720a1b2;Safari;"
        _ = real.withCString { setxattr(a.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        t.mkdir("dest")
        _ = try Xipper.extract(a, to: t.url("dest"), mode: .into)
        let q = ExtractionContext.readXattr(t.path + "/dest/src/app.sh", "com.apple.quarantine").map { String(decoding: $0, as: UTF8.self) }
        #expect(q == real, "quarantine is \(q ?? "missing")")
    }

    // MARK: hostile names

    @Test func hostileNamesStayInside() throws {
        let t = TempDir()
        t.mkdir("outside")
        t.mkdir("dest")
        let home = "xipper-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/" + home) }
        let a = t.path + "/names.zip"
        python("""
        import sys, zipfile
        z = zipfile.ZipFile(sys.argv[1], 'w')
        def add(name, system=3):
            i = zipfile.ZipInfo(name); i.create_system = system; z.writestr(i, 'x')
        add('..\\\\..\\\\outside\\\\win.txt', 0)
        add('C:\\\\..\\\\outside\\\\drive.txt', 0)
        add('a/./../../outside/dot.txt')
        add('//outside/abs.txt')
        add('./../outside/rel.txt')
        add('~/' + sys.argv[2] + '/tilde.txt')
        add('x/' + 'n' * 300 + '/long.txt')
        add('/'.join(['p'] * 600) + '/deep.txt')
        add('nul\\x00/../../outside/nul.txt')
        add('..')
        add('.')
        add('')
        z.close()
        """, [a, home])
        _ = try? Xipper.extract(URL(fileURLWithPath: a), to: t.url("dest"), mode: .into)
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.path + "/outside").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: NSHomeDirectory() + "/" + home))
        #expect(!FileManager.default.fileExists(atPath: "/outside"))
        #expect(linksEscaping(t.path + "/dest").isEmpty)
    }

    // MARK: encryption

    /// Content (and, where the format hides them, names) never appear in clear; the password is
    /// never stored; two archives of the same data with the same password differ (random salt).
    @Test(arguments: [ArchiveFormat.zip, .sevenZip, .xiz])
    func encryptedArchivesLeakNothing(format: ArchiveFormat) throws {
        let t = TempDir()
        let marker = "MARCATORE-SEGRETO-\(UUID().uuidString)"
        t.write("src/\(marker)-nome.txt", String(repeating: marker + "\n", count: 50))
        t.write("src/incomprimibile.bin", Array(marker.utf8) + sampleData(4000))
        let password = "Pässwörd-\(UUID().uuidString.prefix(8))"
        var o = CreateOptions()
        o.format = format
        o.password = password
        if format == .zip { o.zipMethod = .store }  // the worst case: nothing scrambled by compression
        if format == .xiz { o.xizKDF = .minimum }
        let a1 = t.url("1." + format.fileExtension), a2 = t.url("2." + format.fileExtension)
        try Xipper.create(from: [t.url("src")], to: a1, options: o)
        try Xipper.create(from: [t.url("src")], to: a2, options: o)
        let raw = try Data(contentsOf: a1)
        let contentHits = raw.range(of: Data((marker + "\n").utf8)) != nil
        #expect(!contentHits, "\(format): content in clear")
        if format != .zip {
            #expect(raw.range(of: Data(marker.utf8)) == nil, "\(format): name in clear")
        }
        for encoding in [String.Encoding.utf8, .utf16LittleEndian] {
            #expect(raw.range(of: password.data(using: encoding)!) == nil, "\(format): password stored")
        }
        #expect(raw != (try Data(contentsOf: a2)), "\(format): deterministic encryption")
    }

    /// Flipped ciphertext bytes: every reader refuses, and no file with wrong content is left.
    @Test(arguments: [ArchiveFormat.zip, .sevenZip, .xiz])
    func tamperedCiphertextNeverYieldsWrongFiles(format: ArchiveFormat) throws {
        let t = TempDir()
        let content = sampleData(200_000, seed: 11)
        t.write("src/doc.bin", content)
        var o = CreateOptions()
        o.format = format
        o.password = "pw"
        if format == .xiz { o.xizKDF = .minimum }
        let a = t.url("e." + format.fileExtension)
        try Xipper.create(from: [t.url("src")], to: a, options: o)
        let original = try Data(contentsOf: a)
        for offset in [original.count / 4, original.count / 2, original.count * 3 / 4] {
            var d = original
            d[offset] ^= 0x01
            try d.write(to: a)
            #expect(!((try? Xipper.test(a, password: "pw"))?.isOK ?? false), "\(format) tamper at \(offset) passed test")
            let dest = "d\(offset)"
            t.mkdir(dest)
            var x = ExtractOptions()
            x.password = "pw"
            _ = try? Xipper.extract(a, to: t.url(dest), mode: .into, options: x)
            if let got = FileManager.default.contents(atPath: t.path + "/" + dest + "/src/doc.bin") {
                #expect(Array(got) == content, "\(format) tamper at \(offset) produced a wrong file")
            }
        }
    }

    // MARK: WebDAV server

    @Test func davServerRefusesTraversalAndForgedRequests() throws {
        let t = TempDir()
        t.write("src/a.txt", "alpha\n")
        let archive = t.url("a.zip")
        try Xipper.create(from: [t.url("src")], to: archive)
        let work = t.url("work")
        let m = try MountedArchive(archive: archive, workDirectory: work)
        let s = DAVServer(tree: m, volumeName: "v")
        try s.start()
        defer { s.stop(); m.close() }
        let http = MountTests.HTTP(s)
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: t.path)) ?? [])

        // Wrong credentials, wrong prefix.
        var r = URLRequest(url: s.url.appendingPathComponent("src/a.txt"))
        r.setValue("Basic " + Data("xipper:nope".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        #expect(statusOf(r) == 401)
        var other = URLComponents(url: s.url, resolvingAgainstBaseURL: false)!
        other.path = "/nonrandom/v/src/a.txt"
        var r2 = URLRequest(url: other.url!)
        r2.setValue(http.auth, forHTTPHeaderField: "Authorization")
        #expect(statusOf(r2) == 404)

        // Traversal in every method that writes.
        for p in ["../evil.txt", "src/../../evil.txt", "%2e%2e/evil.txt", "src/%2e%2e%2f%2e%2e%2fevil.txt", "src/a%00.txt"] {
            #expect(http.send("PUT", p, body: Data("x".utf8)).0 >= 400, "PUT \(p)")
            #expect(http.send("MKCOL", p).0 >= 400, "MKCOL \(p)")
            #expect(http.send("DELETE", p).0 >= 400, "DELETE \(p)")
        }
        for dest in [s.url.absoluteString + "../evil.txt", s.url.absoluteString + "src/%2e%2e/%2e%2e/evil.txt",
                     "http://127.0.0.1:1/other/evil.txt", "/etc/evil.txt"] {
            #expect(http.send("COPY", "src/a.txt", headers: ["Destination": dest]).0 >= 400, "COPY to \(dest)")
            #expect(http.send("MOVE", "src/a.txt", headers: ["Destination": dest]).0 >= 400, "MOVE to \(dest)")
        }
        #expect(http.send("GET", "src/a.txt").2 == Data("alpha\n".utf8))
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: t.path)) ?? [])
        #expect(after.subtracting(before).isEmpty, "created next to the mount: \(after.subtracting(before))")
        #expect(!FileManager.default.fileExists(atPath: "/etc/evil.txt"))
    }

    /// Garbage, oversized headers and half-sent requests on the socket: the server survives and
    /// keeps answering.
    @Test func davServerSurvivesMalformedTraffic() throws {
        let t = TempDir()
        t.write("src/a.txt", "alpha\n")
        let archive = t.url("a.zip")
        try Xipper.create(from: [t.url("src")], to: archive)
        let m = try MountedArchive(archive: archive, workDirectory: t.url("work"))
        let s = DAVServer(tree: m, volumeName: "v")
        try s.start()
        defer { s.stop(); m.close() }
        let auth = "Authorization: Basic \(Data("\(s.user):\(s.password)".utf8).base64EncodedString())\r\n"
        let payloads: [[UInt8]] = [
            Array(sampleData(4096, seed: 1)),
            Array("GET / HTTP/1.1\r\n".utf8) + Array(repeating: UInt8(ascii: "A"), count: 1 << 20),
            Array("PUT \(s.url.path)src/x HTTP/1.1\r\n\(auth)Content-Length: 99999999999999999999\r\n\r\nabc".utf8),
            Array("PUT \(s.url.path)src/y HTTP/1.1\r\n\(auth)Content-Length: -5\r\n\r\n".utf8),
            Array("PUT \(s.url.path)src/z HTTP/1.1\r\n\(auth)Transfer-Encoding: chunked\r\n\r\nFFFFFFFFFFFFFFFFFF\r\nabc".utf8),
            Array("PROPFIND \(s.url.path) HTTP/1.1\r\n\(auth)Depth: infinity\r\nContent-Length: 5\r\n\r\n<<<<<".utf8),
            Array("\r\n\r\n\r\n".utf8),
        ]
        for p in payloads { rawSend(port: s.port, p) }
        let http = MountTests.HTTP(s)
        #expect(http.send("GET", "src/a.txt").2 == Data("alpha\n".utf8))
    }

    func statusOf(_ r: URLRequest) -> Int {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var status = -1
        URLSession.shared.dataTask(with: r) { _, resp, _ in
            status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            done.signal()
        }.resume()
        done.wait()
        return status
    }

    /// Sends bytes on a fresh connection, reads whatever comes back for a moment, closes.
    func rawSend(port: UInt16, _ bytes: [UInt8]) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0 else { return }
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var buf = [UInt8](repeating: 0, count: 4096)
        _ = read(fd, &buf, buf.count)
    }

    // MARK: MCP

    /// Outputs reached through links inside the allowed folder must not land outside it.
    @Test func mcpOutputsCannotEscapeThroughLinks() throws {
        let t = TempDir()
        let outside = TempDir()
        t.write("src/a.txt", "a\n")
        t.symlink("dangling.zip", to: outside.path + "/written-outside.zip")
        t.symlink("linkdir", to: outside.path)
        var c = MCPConfig()
        c.allowedRoots = [t.path]
        let h = MCPHarness(config: c)
        h.initializeLegacy()
        for out in [t.path + "/dangling.zip", t.path + "/linkdir/out.zip", t.path + "/src/../../" + (outside.path as NSString).lastPathComponent + "/x.zip"] {
            _ = h.call("archive_create", ["sources": [.string(t.path + "/src")], "output": .string(out)])
        }
        try Xipper.create(from: [t.url("src")], to: t.url("ok.zip"))
        _ = h.call("archive_extract", ["path": .string(t.path + "/ok.zip"), "destination": .string(t.path + "/linkdir")])
        let written = try FileManager.default.contentsOfDirectory(atPath: outside.path)
        #expect(written.isEmpty, "written outside: \(written)")
    }
}
