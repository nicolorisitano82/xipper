import Foundation
import Testing
@testable import XipperKit

/// Mounted archives (docs/FSKIT.md): streaming reads, the copy-on-write tree, the WebDAV server
/// and, on a Mac, a real read-write mount through macOS's WebDAV client.
@Suite("Mounting archives")
struct MountTests {
    func tree(_ t: TempDir) -> [UInt8] {
        let big = sampleData(3 << 20, seed: 77)
        t.write("src/a.txt", "alpha\n")
        t.write("src/sub/big.bin", big)
        t.write("src/sub/deep/c.txt", "gamma\n")
        t.mkdir("src/empty")
        return big
    }

    func archive(_ t: TempDir, _ format: ArchiveFormat, password: String? = nil) throws -> URL {
        var o = CreateOptions()
        o.format = format
        o.password = password
        let url = t.url("a." + format.fileExtension)
        try Xipper.create(from: [t.url("src")], to: url, options: o)
        return url
    }

    // MARK: streaming

    @Test(arguments: [ArchiveFormat.zip, .sevenZip, .tarZstd, .tarGzip, .xiz, .cpio, .appleArchive])
    func streamEntryFromOffsets(format: ArchiveFormat) throws {
        let t = TempDir()
        let big = tree(t)
        let a = try archive(t, format)
        for offset in [0, 1, 65_535, 1 << 20, big.count - 3, big.count, big.count + 10] {
            var got = [UInt8]()
            let e = try Xipper.streamEntry(a, path: "src/sub/big.bin", from: Int64(offset)) { got.append(contentsOf: $0) }
            #expect(e.path == "src/sub/big.bin")
            #expect(got == Array(big.dropFirst(offset)), "\(format) offset \(offset)")
        }
        // readEntry is the same stream, cut short.
        let head = try Xipper.readEntry(a, path: "src/sub/big.bin", maxBytes: 1000)
        #expect(head.data == Array(big.prefix(1000)) && head.truncated)
    }

    // MARK: copy-on-write tree

    @Test func overlayShadowsAndWhiteouts() throws {
        let t = TempDir()
        _ = tree(t)
        let m = try MountedArchive(archive: try archive(t, .zip), workDirectory: t.url("work"))
        defer { m.close() }
        #expect(m.children("").map(\.name) == ["src"])
        #expect(Set(m.children("src").map(\.name)) == ["a.txt", "sub", "empty"])
        #expect(m.info("src/sub")?.isDirectory == true && m.info("src/sub/big.bin")?.size == 3 << 20)
        #expect(!m.hasChanges)

        try m.write("src/a.txt") { try $0.write(contentsOf: Data("changed\n".utf8)) }
        var text = [UInt8]()
        try m.read("src/a.txt") { text.append(contentsOf: $0) }
        #expect(text == Array("changed\n".utf8))

        try m.delete("src/sub")
        #expect(m.info("src/sub") == nil && m.info("src/sub/deep/c.txt") == nil)
        try m.makeDirectory("src/sub")  // same name again: the old content stays hidden
        #expect(m.children("src/sub").isEmpty)

        try m.move("src/a.txt", to: "src/moved.txt", overwrite: false)
        #expect(m.info("src/a.txt") == nil && m.info("src/moved.txt")?.size == 8)
        try m.copy("src/empty", to: "src/empty2", overwrite: false)
        #expect(m.info("src/empty2")?.isDirectory == true)
        #expect(throws: XipperError.self) { try m.makeDirectory("src/missing/x") }
        #expect(throws: XipperError.self) { try m.copy("src", to: "src/inside", overwrite: false) }
        #expect(MountedArchive.normalize("../etc/passwd") == nil && MountedArchive.normalize("/a//b/") == "a/b")
        #expect(m.hasChanges)
    }

    @Test(arguments: [ArchiveFormat.zip, .sevenZip, .tarZstd, .xiz, .appleArchive])
    func saveRebuildsTheArchive(format: ArchiveFormat) throws {
        let t = TempDir()
        let big = tree(t)
        let password: String? = format == .zip || format == .sevenZip ? "segreto" : nil
        let a = try archive(t, format, password: password)
        let m = try MountedArchive(archive: a, password: password, workDirectory: t.url("work"))
        #expect(m.writable)
        try m.write("src/new.txt") { try $0.write(contentsOf: Data("nuovo\n".utf8)) }
        try m.write("src/._new.txt") { try $0.write(contentsOf: Data([0, 5, 22, 7])) }  // Finder's AppleDouble: dropped
        try m.delete("src/a.txt")
        try m.move("src/sub/deep", to: "src/deep", overwrite: false)
        try m.save()
        m.close()

        #expect(try ArchiveFormat.detect(a) == format)
        #expect(try Xipper.test(a, password: password).isOK)
        let paths = Set(try Xipper.list(a, password: password).map(\.path).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 })
        #expect(paths.contains("src/new.txt") && paths.contains("src/deep/c.txt") && paths.contains("src/sub/big.bin"))
        #expect(!paths.contains("src/a.txt") && !paths.contains("src/sub/deep/c.txt") && !paths.contains("src/._new.txt"))
        #expect(try Xipper.readEntry(a, path: "src/sub/big.bin", password: password, maxBytes: 4 << 20).data == big)
        if password != nil { #expect((try? Xipper.test(a, password: "sbagliata"))?.isOK != true) }  // still encrypted
    }

    @Test func singleFileStreamsAreReadOnly() throws {
        let t = TempDir()
        t.write("one.txt", "solo\n")
        var o = CreateOptions()
        o.format = .gzip
        try Xipper.create(from: [t.url("one.txt")], to: t.url("one.txt.gz"), options: o)
        let m = try MountedArchive(archive: t.url("one.txt.gz"), workDirectory: t.url("work"))
        defer { m.close() }
        #expect(!m.writable)
        #expect(throws: XipperError.self) { try m.makeDirectory("x") }
    }

    // MARK: WebDAV server

    final class HTTP: @unchecked Sendable {
        let base: URL
        let auth: String
        init(_ s: DAVServer) {
            base = s.url
            auth = "Basic " + Data("\(s.user):\(s.password)".utf8).base64EncodedString()
        }

        func send(_ method: String, _ path: String, headers: [String: String] = [:], body: Data? = nil,
                  authorized: Bool = true) -> (Int, [String: String], Data) {
            var r = URLRequest(url: path.isEmpty ? base : URL(string: path, relativeTo: base)!)
            r.httpMethod = method
            r.httpBody = body
            if authorized { r.setValue(auth, forHTTPHeaderField: "Authorization") }
            for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var out: (Int, [String: String], Data) = (0, [:], Data())
            URLSession.shared.dataTask(with: r) { data, response, _ in
                let h = response as? HTTPURLResponse
                out = (h?.statusCode ?? -1, (h?.allHeaderFields as? [String: String]) ?? [:], data ?? Data())
                done.signal()
            }.resume()
            done.wait()
            return out
        }
    }

    @Test func davServerSpeaksClass2() throws {
        let t = TempDir()
        let big = tree(t)
        let m = try MountedArchive(archive: try archive(t, .zip), workDirectory: t.url("work"))
        let s = DAVServer(tree: m, volumeName: "Prova archivio")
        try s.start()
        defer { s.stop(); m.close() }
        let http = HTTP(s)

        #expect(http.send("PROPFIND", "src/", headers: ["Depth": "1"], authorized: false).0 == 401)
        let opts = http.send("OPTIONS", "")
        #expect(opts.0 == 200 && opts.1.first { $0.key.lowercased() == "dav" }?.value.contains("2") == true)
        let list = http.send("PROPFIND", "src/", headers: ["Depth": "1"])
        let xml = String(decoding: list.2, as: UTF8.self)
        #expect(list.0 == 207 && xml.contains("a.txt") && xml.contains("<D:collection/>") && xml.contains("Prova%20archivio"))

        let range = http.send("GET", "src/sub/big.bin", headers: ["Range": "bytes=100-199"])
        #expect(range.0 == 206 && Array(range.2) == Array(big[100...199]))
        #expect(Array(http.send("GET", "src/sub/big.bin").2) == big)
        #expect(http.send("GET", "src/%2e%2e/%2e%2e/etc/passwd").0 == 404)
        #expect(http.send("GET", "../../etc/passwd").0 == 404)

        #expect(http.send("PUT", "src/new.txt", body: Data("ciao".utf8)).0 == 201)
        #expect(http.send("PUT", "src/new.txt", body: Data("ciao!".utf8)).0 == 204)
        #expect(http.send("GET", "src/new.txt").2 == Data("ciao!".utf8))
        #expect(http.send("MKCOL", "src/dir").0 == 201)
        #expect(http.send("MKCOL", "src/dir").0 == 405)
        #expect(http.send("MKCOL", "src/nope/dir").0 == 409)
        let dest = s.url.appendingPathComponent("src/dir/renamed.txt").absoluteString
        #expect(http.send("MOVE", "src/new.txt", headers: ["Destination": dest]).0 == 201)
        #expect(http.send("GET", "src/new.txt").0 == 404 && http.send("GET", "src/dir/renamed.txt").2 == Data("ciao!".utf8))
        #expect(http.send("COPY", "src/a.txt", headers: ["Destination": dest, "Overwrite": "F"]).0 == 412)
        let lock = http.send("LOCK", "src/locked.txt", body: Data("<?xml version=\"1.0\"?><D:lockinfo xmlns:D=\"DAV:\"><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockinfo>".utf8))
        #expect(lock.0 == 201 && lock.1["Lock-Token"]?.contains("opaquelocktoken:") == true)
        #expect(http.send("UNLOCK", "src/locked.txt", headers: ["Lock-Token": lock.1["Lock-Token"] ?? ""]).0 == 204)
        #expect(http.send("DELETE", "src/sub").0 == 204 && http.send("PROPFIND", "src/sub/", headers: ["Depth": "0"]).0 == 404)
        #expect(http.send("PROPPATCH", "src/a.txt", body: Data("<D:propertyupdate xmlns:D=\"DAV:\"/>".utf8)).0 == 207)
        #expect(m.hasChanges)
    }

    @Test func davServerChunkedUploadStreamsToDisk() throws {
        let t = TempDir()
        _ = tree(t)
        let m = try MountedArchive(archive: try archive(t, .zip), workDirectory: t.url("work"))
        let s = DAVServer(tree: m, volumeName: "c")
        try s.start()
        defer { s.stop(); m.close() }
        // Raw socket: a chunked PUT, which URLSession would not send for a Data body.
        let payload = sampleData(300_000, seed: 3)
        var req = "PUT \(s.url.path)/src/chunked.bin HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Basic \(Data("\(s.user):\(s.password)".utf8).base64EncodedString())\r\nTransfer-Encoding: chunked\r\nExpect: 100-continue\r\nConnection: close\r\n\r\n"
        var bytes = Array(req.utf8)
        for piece in stride(from: 0, to: payload.count, by: 70_000) {
            let chunk = payload[piece..<min(piece + 70_000, payload.count)]
            bytes += Array((String(chunk.count, radix: 16) + ";ext=1\r\n").utf8) + chunk + Array("\r\n".utf8)
        }
        bytes += Array("0\r\n\r\n".utf8)
        req = ""
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = s.port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        #expect(ok == 0)
        _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        var reply = [UInt8](repeating: 0, count: 4096), got = [UInt8]()
        while true {
            let n = recv(fd, &reply, reply.count, 0)
            if n <= 0 { break }
            got += reply[0..<n]
        }
        close(fd)
        let text = String(decoding: got, as: UTF8.self)
        #expect(text.contains("100 Continue") && text.contains("201 Created"))
        var back = [UInt8]()
        try m.read("src/chunked.bin") { back.append(contentsOf: $0) }
        #expect(back == payload)
    }

    // MARK: real mount (macOS WebDAV client through NetFS)

    static let canMount = ProcessInfo.processInfo.environment["XIPPER_SKIP_MOUNT"] == nil

    @Test(.enabled(if: canMount), .timeLimit(.minutes(2)))
    func readWriteMountRoundTrip() throws {
        let t = TempDir()
        let big = tree(t)
        let a = try archive(t, .zip)
        let mount = try ArchiveMount(archive: a)
        let point = try mount.mount(at: nil)
        #expect(mount.isMounted)
        let fm = FileManager.default
        #expect(fm.contents(atPath: point.path + "/src/sub/big.bin") == Data(big))
        try Data("dal volume\n".utf8).write(to: point.appendingPathComponent("src/written.txt"))
        try fm.createDirectory(at: point.appendingPathComponent("src/nuova"), withIntermediateDirectories: false)
        try fm.moveItem(at: point.appendingPathComponent("src/a.txt"), to: point.appendingPathComponent("src/nuova/a.txt"))
        try fm.removeItem(at: point.appendingPathComponent("src/sub/deep"))
        try mount.unmount()
        #expect(!mount.isMounted)
        try mount.finish(save: true)

        let paths = Set(try Xipper.list(a).map(\.path))
        #expect(paths.contains("src/written.txt") && paths.contains("src/nuova/a.txt"))
        #expect(!paths.contains("src/a.txt") && !paths.contains { $0.hasPrefix("src/sub/deep") })
        #expect(try Xipper.readEntry(a, path: "src/written.txt").data == Array("dal volume\n".utf8))
        #expect(!paths.contains { ($0 as NSString).lastPathComponent.hasPrefix("._") })
        #expect(try Xipper.test(a).isOK)
    }

    @Test(.enabled(if: canMount), .timeLimit(.minutes(1)))
    func readOnlyMountRefusesWrites() throws {
        let t = TempDir()
        _ = tree(t)
        let a = try archive(t, .zip)
        let before = try Data(contentsOf: a)
        let mount = try ArchiveMount(archive: a, writable: false)
        let point = try mount.mount(at: nil)
        #expect(FileManager.default.contents(atPath: point.path + "/src/a.txt") == Data("alpha\n".utf8))
        #expect(throws: (any Error).self) { try Data("x".utf8).write(to: point.appendingPathComponent("src/x.txt")) }
        try mount.unmount()
        try mount.finish(save: true)
        #expect(try Data(contentsOf: a) == before)
    }
}
