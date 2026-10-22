import Foundation

/// WebDAV server for one mounted archive (docs/FSKIT.md, option C), on 127.0.0.1 only.
///
/// - Class 2 (with LOCK) when the archive is writable, so macOS mounts it read-write; class 1
///   (read-only) otherwise.
/// - Every request needs the mount's random credentials (HTTP Basic: traffic never leaves the
///   loopback interface) and the random path prefix.
/// - Bodies stream both ways: GET reads the entry while sending it, PUT writes to disk while
///   receiving, so memory stays flat whatever the file size.
/// - One thread per connection, blocking sockets: the kernel's buffers provide backpressure.
public final class DAVServer: @unchecked Sendable {
    public let tree: MountedArchive
    public let user: String
    public let password: String
    /// "/<random>/<volume name>": the URL path the mount uses (decoded). The last component names
    /// the mount point (/Volumes/<name>).
    public let prefix: String
    public private(set) var port: UInt16 = 0
    /// Called for every request (method, path, status), for logs and tests.
    public var log: (@Sendable (String, String, Int) -> Void)?

    private var listener: Int32 = -1
    private let state = NSLock()
    private var stopped = false
    private var connections: Set<Int32> = []
    private var locks: [String: String] = [:]  // token -> path

    public init(tree: MountedArchive, volumeName: String) {
        self.tree = tree
        user = "xipper"
        password = Self.random(24)
        let name = volumeName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        prefix = "/" + Self.random(16) + "/" + (name.isEmpty ? "Archivio" : name)
    }

    private static func random(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        arc4random_buf(&bytes, n)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    private var encodedPrefix: String {
        prefix.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#;&+"))) ?? String($0) }
            .reduce("") { $0 + "/" + $1 }
    }

    /// The URL to mount, without credentials.
    public var url: URL { URL(string: "http://127.0.0.1:\(port)\(encodedPrefix)/")! }

    /// Starts listening (port 0: any free port).
    public func start(port requested: UInt16 = 0) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw XipperError.posix("socket", nil) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = requested.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); throw XipperError.posix("bind 127.0.0.1", nil) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = UInt16(bigEndian: addr.sin_port)
        listener = fd
        let t = Thread { [weak self] in self?.acceptLoop(fd) }
        t.name = "xipper-dav"
        t.start()
    }

    public func stop() {
        state.withLock {
            stopped = true
            if listener >= 0 { shutdown(listener, SHUT_RDWR); close(listener); listener = -1 }
            for c in connections { shutdown(c, SHUT_RDWR) }
        }
    }

    deinit { stop() }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 {
                if errno == EINTR { continue }
                return
            }
            var nosig: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
            let accepted = state.withLock { () -> Bool in
                if stopped { return false }
                connections.insert(c)
                return true
            }
            guard accepted else { close(c); return }
            let t = Thread { [weak self] in
                let conn = Connection(fd: c)
                self?.serve(conn)
                close(c)
                self?.state.withLock { _ = self?.connections.remove(c) }
            }
            t.name = "xipper-dav-conn"
            t.start()
        }
    }

    // MARK: HTTP

    struct Request {
        var method: String
        var target: String
        var headers: [String: String]
        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    struct Response {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
    }

    private func serve(_ conn: Connection) {
        while let req = conn.readHead() {
            let status = handle(req, conn)
            log?(req.method, req.target, status)
            if status < 0 || req.header("connection")?.lowercased() == "close" { return }
        }
    }

    /// Handles one request (reading its body and writing the response); returns the status, or
    /// -1 when the connection must close.
    private func handle(_ req: Request, _ conn: Connection) -> Int {
        // Authentication and the random prefix come first; the body is drained either way.
        let expectsContinue = req.header("expect")?.lowercased() == "100-continue"
        guard authorized(req) else {
            if expectsContinue {  // the body was not sent: answer and close instead of reading it
                send(conn, req, Response(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"Xipper\"", "Connection": "close"]))
                return -1
            }
            guard conn.drainBody(req) else { return -1 }
            return send(conn, req, Response(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"Xipper\""]))
        }
        if expectsContinue { _ = conn.write(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) }
        guard let path = relativePath(req.target) else {
            guard conn.drainBody(req) else { return -1 }
            return send(conn, req, Response(status: 404))
        }
        switch req.method {
        case "GET", "HEAD":
            guard conn.drainBody(req) else { return -1 }
            return get(req, path, conn)
        case "PUT":
            return put(req, path, conn)
        default:
            guard let body = conn.readBody(req, limit: 1 << 20) else { return -1 }
            return send(conn, req, other(req, path, body))
        }
    }

    private func authorized(_ req: Request) -> Bool {
        guard let h = req.header("authorization"), h.hasPrefix("Basic "),
              let decoded = Data(base64Encoded: String(h.dropFirst(6))), let pair = String(data: decoded, encoding: .utf8) else { return false }
        return Self.constantTimeEqual(pair, "\(user):\(password)")
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// The tree path of a request target (or a Destination URL); nil when outside the prefix or invalid.
    func relativePath(_ target: String) -> String? {
        var t = target
        if let r = t.range(of: "://"), let slash = t[r.upperBound...].firstIndex(of: "/") { t = String(t[slash...]) }
        if let q = t.firstIndex(where: { $0 == "?" || $0 == "#" }) { t = String(t[..<q]) }
        guard let decoded = t.removingPercentEncoding, decoded == prefix || decoded.hasPrefix(prefix + "/") else { return nil }
        return MountedArchive.normalize(String(decoded.dropFirst(prefix.count)))
    }

    private func href(_ path: String, isDirectory: Bool) -> String {
        let encoded = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#;&+"))) ?? String($0)
        }.joined(separator: "/")
        return encodedPrefix + "/" + encoded + (isDirectory && !encoded.isEmpty ? "/" : "")
    }

    private static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    @discardableResult
    private func send(_ conn: Connection, _ req: Request, _ r: Response) -> Int {
        var h = r.headers
        h["Content-Length"] = h["Content-Length"] ?? String(r.body.count)
        conn.writeHead(r.status, h)
        if req.method != "HEAD", !r.body.isEmpty { guard conn.write(r.body) else { return -1 } }
        return r.status
    }

    private func error(_ e: Error) -> Int {
        switch e as? XipperError {
        case .alreadyExists?: 405
        case let .io(_, _, code)? where code == ENOENT: 409
        case let .io(_, _, code)? where code == EROFS: 403
        case let .io(_, _, code)? where code == EISDIR: 405
        case .passwordRequired?, .wrongPassword?: 403
        default: 500
        }
    }

    // MARK: methods

    private func get(_ req: Request, _ path: String, _ conn: Connection) -> Int {
        guard let info = tree.info(path) else { return send(conn, req, Response(status: 404)) }
        var headers = ["Last-Modified": Self.httpDate.string(from: info.modified), "ETag": "\"\(info.etag)\""]
        if info.isDirectory {
            headers["Content-Type"] = "text/plain; charset=utf-8"
            return send(conn, req, Response(status: 200, headers: headers))
        }
        headers["Content-Type"] = "application/octet-stream"
        headers["Accept-Ranges"] = "bytes"
        let size = info.size
        var lo: Int64 = 0, hi: Int64 = size - 1, status = 200
        if let range = req.header("range"), range.hasPrefix("bytes="), !range.contains(",") {
            let spec = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            if spec.count == 2 {
                if spec[0].isEmpty, let suffix = Int64(spec[1]) { lo = max(0, size - suffix) } else {
                    lo = Int64(spec[0]) ?? 0
                    if let h = Int64(spec[1]) { hi = min(h, size - 1) }
                }
                guard lo <= hi, lo < size else {
                    return send(conn, req, Response(status: 416, headers: ["Content-Range": "bytes */\(size)"]))
                }
                status = 206
                headers["Content-Range"] = "bytes \(lo)-\(hi)/\(size)"
            }
        }
        let length = size == 0 ? 0 : hi - lo + 1
        headers["Content-Length"] = String(length)
        conn.writeHead(status, headers)
        if req.method == "HEAD" || length == 0 { return status }
        // Stream exactly `length` bytes; on a decoding error the connection closes, so the client
        // sees a short body instead of wrong data.
        var left = length
        let cancel = CancellationToken()
        do {
            try tree.read(path, from: lo, cancel: cancel) { chunk in
                let n = Int(min(Int64(chunk.count), left))
                guard conn.write(UnsafeRawBufferPointer(rebasing: chunk[..<n])) else { throw XipperError.cancelled }
                left -= Int64(n)
                if left == 0 { throw StopStreaming() }
            }
        } catch is StopStreaming {
        } catch {
            return -1
        }
        return left == 0 ? status : -1
    }

    private struct StopStreaming: Error {}

    private func put(_ req: Request, _ path: String, _ conn: Connection) -> Int {
        guard tree.writable else {
            guard conn.drainBody(req) else { return -1 }
            return send(conn, req, Response(status: 403))
        }
        var bodyOK = true
        do {
            let created = try tree.write(path) { handle in
                bodyOK = conn.streamBody(req) { try handle.write(contentsOf: Data($0)) }
                if !bodyOK { throw XipperError.cancelled }
            }
            return send(conn, req, Response(status: created ? 201 : 204))
        } catch {
            if !bodyOK { return -1 }
            return send(conn, req, Response(status: self.error(error)))
        }
    }

    private func other(_ req: Request, _ path: String, _ body: Data) -> Response {
        let writable = tree.writable
        let readOnlyMethods: Set = ["OPTIONS", "PROPFIND"]
        if !writable && !readOnlyMethods.contains(req.method) { return Response(status: 403) }
        do {
            switch req.method {
            case "OPTIONS":
                return Response(status: 200, headers: [
                    "DAV": writable ? "1, 2" : "1",
                    "Allow": writable ? "OPTIONS, GET, HEAD, PROPFIND, PROPPATCH, PUT, MKCOL, DELETE, COPY, MOVE, LOCK, UNLOCK"
                                      : "OPTIONS, GET, HEAD, PROPFIND",
                    "MS-Author-Via": "DAV",
                ])
            case "PROPFIND":
                return propfind(req, path)
            case "PROPPATCH":
                // Properties are not stored; accept so clients setting dates or Finder info go on.
                guard tree.info(path) != nil else { return Response(status: 404) }
                return multistatus("<D:response><D:href>\(Self.xmlEscape(href(path, isDirectory: tree.info(path)!.isDirectory)))</D:href><D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>")
            case "MKCOL":
                if !body.isEmpty { return Response(status: 415) }
                if tree.info(path) != nil { return Response(status: 405) }
                try tree.makeDirectory(path)
                return Response(status: 201)
            case "DELETE":
                guard tree.info(path) != nil else { return Response(status: 404) }
                try tree.delete(path)
                return Response(status: 204)
            case "COPY", "MOVE":
                guard tree.info(path) != nil else { return Response(status: 404) }
                guard let d = req.header("destination"), let dest = relativePath(d) else { return Response(status: 502) }
                let overwrite = req.header("overwrite")?.uppercased() != "F"
                if !overwrite, tree.info(dest) != nil { return Response(status: 412) }
                let created = req.method == "MOVE" ? try tree.move(path, to: dest, overwrite: overwrite)
                                                   : try tree.copy(path, to: dest, overwrite: overwrite)
                return Response(status: created ? 201 : 204)
            case "LOCK":
                return lock(req, path, body)
            case "UNLOCK":
                if let t = req.header("lock-token")?.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) {
                    _ = state.withLock { locks.removeValue(forKey: t) }
                }
                return Response(status: 204)
            default:
                return Response(status: 405)
            }
        } catch {
            return Response(status: self.error(error))
        }
    }

    private func multistatus(_ responses: String) -> Response {
        let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:multistatus xmlns:D=\"DAV:\">\(responses)</D:multistatus>"
        return Response(status: 207, headers: ["Content-Type": "application/xml; charset=utf-8"], body: Data(xml.utf8))
    }

    private func propfind(_ req: Request, _ path: String) -> Response {
        guard let info = tree.info(path) else { return Response(status: 404) }
        var xml = props(path, info)
        if info.isDirectory, req.header("depth") != "0" {
            for c in tree.children(path) { xml += props(path.isEmpty ? c.name : path + "/" + c.name, c) }
        }
        return multistatus(xml)
    }

    private func props(_ path: String, _ i: Info) -> String {
        var p = "<D:displayname>\(Self.xmlEscape(i.name))</D:displayname>"
        p += "<D:getlastmodified>\(Self.httpDate.string(from: i.modified))</D:getlastmodified>"
        p += "<D:creationdate>\(ISO8601DateFormatter().string(from: i.modified))</D:creationdate>"
        p += "<D:getetag>\"\(Self.xmlEscape(i.etag))\"</D:getetag>"
        if i.isDirectory {
            p += "<D:resourcetype><D:collection/></D:resourcetype>"
        } else {
            p += "<D:resourcetype/><D:getcontentlength>\(i.size)</D:getcontentlength><D:getcontenttype>application/octet-stream</D:getcontenttype>"
        }
        if tree.writable {
            p += "<D:supportedlock><D:lockentry><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockentry></D:supportedlock>"
        }
        return "<D:response><D:href>\(Self.xmlEscape(href(path, isDirectory: i.isDirectory)))</D:href><D:propstat><D:prop>\(p)</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
    }

    private typealias Info = MountedArchive.Info

    /// Exclusive write locks are granted to anyone holding the mount's credentials: the client
    /// needs them to write (DAV class 2), and there is a single client.
    private func lock(_ req: Request, _ path: String, _ body: Data) -> Response {
        var status = 200
        if tree.info(path) == nil {
            // LOCK on a new name creates an empty file (RFC 4918 §9.10.4).
            do { try tree.write(path) { _ in } } catch { return Response(status: self.error(error)) }
            status = 201
        }
        let token = req.header("if").flatMap { h -> String? in
            guard let r = h.range(of: "opaquelocktoken:") else { return nil }
            return "opaquelocktoken:" + h[r.upperBound...].prefix { $0 != ">" }
        } ?? "opaquelocktoken:\(UUID().uuidString.lowercased())"
        state.withLock { locks[token] = path }
        let timeout = req.header("timeout").flatMap { $0.split(separator: ",").first.map(String.init) } ?? "Second-3600"
        let owner = String(data: body, encoding: .utf8).flatMap { s -> String? in
            guard let a = s.range(of: "<D:owner>") ?? s.range(of: "<owner>") ?? s.range(of: ":owner>"),
                  let b = s.range(of: "owner>", range: a.upperBound..<s.endIndex) else { return nil }
            let inner = s[a.upperBound..<b.lowerBound]
            return String(inner.dropLast(inner.hasSuffix("</D:") ? 4 : (inner.hasSuffix("</") ? 2 : 0)))
        } ?? ""
        let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:prop xmlns:D=\"DAV:\"><D:lockdiscovery><D:activelock><D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope><D:depth>0</D:depth><D:owner>\(owner)</D:owner><D:timeout>\(timeout)</D:timeout><D:locktoken><D:href>\(token)</D:href></D:locktoken><D:lockroot><D:href>\(Self.xmlEscape(href(path, isDirectory: tree.info(path)?.isDirectory ?? false)))</D:href></D:lockroot></D:activelock></D:lockdiscovery></D:prop>"
        return Response(status: status, headers: ["Lock-Token": "<\(token)>", "Content-Type": "application/xml; charset=utf-8"], body: Data(xml.utf8))
    }
}

/// One client connection: buffered reads of request heads, Content-Length and chunked bodies.
final class Connection {
    let fd: Int32
    private var buffer = [UInt8]()
    private var start = 0

    init(fd: Int32) { self.fd = fd }

    private func fill() -> Bool {
        if start > 0 && start == buffer.count { buffer.removeAll(keepingCapacity: true); start = 0 }
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        guard n > 0 else { return false }
        buffer.append(contentsOf: chunk[0..<n])
        return true
    }

    private var available: Int { buffer.count - start }

    func readHead() -> DAVServer.Request? {
        while true {
            if let end = findHeaderEnd() {
                let text = String(decoding: buffer[start..<end], as: UTF8.self)
                start = end + 4
                var lines = text.components(separatedBy: "\r\n")
                let first = lines.removeFirst().split(separator: " ")
                guard first.count >= 2 else { return nil }
                var headers: [String: String] = [:]
                for l in lines {
                    guard let i = l.firstIndex(of: ":") else { continue }
                    headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
                }
                return DAVServer.Request(method: String(first[0]), target: String(first[1]), headers: headers)
            }
            if available > 64 << 10 { return nil }  // header too large
            guard fill() else { return nil }
        }
    }

    private func findHeaderEnd() -> Int? {
        guard available >= 4 else { return nil }
        var i = start
        while i + 3 < buffer.count {
            if buffer[i] == 13 && buffer[i + 1] == 10 && buffer[i + 2] == 13 && buffer[i + 3] == 10 { return i }
            i += 1
        }
        return nil
    }

    /// Passes the body to `sink` piece by piece (Content-Length or chunked). False on a broken connection.
    func streamBody(_ req: DAVServer.Request, _ sink: (UnsafeRawBufferPointer) throws -> Void) -> Bool {
        do {
            if req.header("transfer-encoding")?.lowercased().contains("chunked") == true {
                while true {
                    guard let line = readLine(), let size = Int(line.split(separator: ";").first ?? "", radix: 16) else { return false }
                    if size == 0 {
                        while let trailer = readLine(), !trailer.isEmpty {}
                        return true
                    }
                    guard try copy(size, sink), readLine() != nil else { return false }
                }
            }
            let length = Int(req.header("content-length") ?? "0") ?? 0
            return try copy(length, sink)
        } catch {
            return false
        }
    }

    private func copy(_ count: Int, _ sink: (UnsafeRawBufferPointer) throws -> Void) throws -> Bool {
        var left = count
        while left > 0 {
            if available == 0 { guard fill() else { return false } }
            let n = min(left, available)
            try buffer.withUnsafeBytes { try sink(UnsafeRawBufferPointer(rebasing: $0[start..<start + n])) }
            start += n
            left -= n
        }
        return true
    }

    private func readLine() -> String? {
        while true {
            if let i = buffer[start...].firstIndex(of: 10) {
                let line = String(decoding: buffer[start..<i], as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                start = i + 1
                return line
            }
            guard fill() else { return nil }
        }
    }

    func readBody(_ req: DAVServer.Request, limit: Int) -> Data? {
        var data = Data()
        let ok = streamBody(req) { chunk in
            if data.count + chunk.count > limit { throw XipperError.limitExceeded("request body") }
            data.append(contentsOf: chunk)
        }
        return ok ? data : nil
    }

    func drainBody(_ req: DAVServer.Request) -> Bool { streamBody(req) { _ in } }

    func writeHead(_ status: Int, _ headers: [String: String]) {
        var s = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var h = headers
        h["Date"] = h["Date"] ?? DAVServerDate.now()
        h["Server"] = "Xipper"
        for (k, v) in h.sorted(by: { $0.key < $1.key }) { s += "\(k): \(v)\r\n" }
        s += "\r\n"
        _ = write(Data(s.utf8))
    }

    @discardableResult
    func write(_ data: Data) -> Bool { data.withUnsafeBytes { write($0) } }

    func write(_ bytes: UnsafeRawBufferPointer) -> Bool {
        var off = 0
        while off < bytes.count {
            let n = send(fd, bytes.baseAddress! + off, min(bytes.count - off, 1 << 30), 0)
            if n < 0 { if errno == EINTR { continue }; return false }
            off += n
        }
        return true
    }

    static func reason(_ s: Int) -> String {
        [200: "OK", 201: "Created", 204: "No Content", 206: "Partial Content", 207: "Multi-Status", 401: "Unauthorized",
         403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 412: "Precondition Failed",
         415: "Unsupported Media Type", 416: "Range Not Satisfiable", 500: "Internal Server Error", 502: "Bad Gateway"][s] ?? "Status"
    }
}

private enum DAVServerDate {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()
    static let lock = NSLock()
    static func now() -> String { lock.withLock { formatter.string(from: Date()) } }
}
