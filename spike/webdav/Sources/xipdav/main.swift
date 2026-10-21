import Foundation
import Network
import XipperKit

// Usage: xipdav <archive> [port]   then   mount_webdav -o rdonly http://127.0.0.1:<port>/<token>/ <mnt>
// Read-only WebDAV class 1: OPTIONS, PROPFIND (depth 0/1), GET/HEAD with Range. Everything else 403.
// The random token in the path keeps other local users' processes out (the port is loopback-only).

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: xipdav <archive> [port]"); exit(2) }
let archive = URL(fileURLWithPath: args[1])
let port = UInt16(args.count > 2 ? args[2] : "0") ?? 0
let token = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16)
let verbose = ProcessInfo.processInfo.environment["XIPDAV_VERBOSE"] != nil

// MARK: tree

final class Node {
    let name: String
    let entry: ArchiveEntry?
    var children: [String: Node] = [:]
    var isDir: Bool { entry == nil || entry!.kind == .directory }
    init(name: String, entry: ArchiveEntry?) { self.name = name; self.entry = entry }
}

let t0 = Date()
let entries = try Xipper.list(archive)
let root = Node(name: "", entry: nil)
for e in entries where e.kind == .file || e.kind == .directory {
    let parts = e.path.split(separator: "/").map(String.init)
    guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { continue }  // same rule as safe extraction
    var dir = root
    for (i, p) in parts.enumerated() {
        let last = i == parts.count - 1
        if let n = dir.children[p] { dir = n; continue }
        let n = Node(name: p, entry: last ? e : nil)
        dir.children[p] = n
        dir = n
    }
}
print("indexed \(entries.count) entries in \(String(format: "%.3f", Date().timeIntervalSince(t0))) s")

func lookup(_ path: String) -> Node? {
    var n = root
    for p in path.split(separator: "/") {
        guard let c = n.children[String(p)] else { return nil }
        n = c
    }
    return n
}

// MARK: content cache (whole entries, bounded)

final class Cache: @unchecked Sendable {
    private var items: [String: [UInt8]] = [:]
    private var order: [String] = []
    private var bytes = 0
    private let limit = 512 << 20
    private let lock = NSLock()
    func data(for path: String, size: Int64) throws -> [UInt8] {
        lock.lock()
        if let d = items[path] { lock.unlock(); return d }
        lock.unlock()
        let content = try Xipper.readEntry(archive, path: path, maxBytes: Int(max(size, 1)))
        lock.lock(); defer { lock.unlock() }
        items[path] = content.data; order.append(path); bytes += content.data.count
        while bytes > limit, let old = order.first, old != path {
            order.removeFirst(); bytes -= items.removeValue(forKey: old)?.count ?? 0
        }
        return content.data
    }
}
let cache = Cache()

// MARK: HTTP

let httpDate: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT")
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return f
}()
let isoDate = ISO8601DateFormatter()

struct Request { var method: String; var path: String; var headers: [String: String]; var body: Data }

func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
}
func hrefEncode(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))) ?? s
}

func propResponse(_ href: String, _ n: Node) -> String {
    let mod = n.entry?.modified ?? Date(timeIntervalSince1970: 0)
    var props = "<D:displayname>\(xmlEscape(n.name))</D:displayname>"
    props += "<D:getlastmodified>\(httpDate.string(from: mod))</D:getlastmodified>"
    props += "<D:creationdate>\(isoDate.string(from: mod))</D:creationdate>"
    if n.isDir {
        props += "<D:resourcetype><D:collection/></D:resourcetype>"
    } else {
        props += "<D:resourcetype/><D:getcontentlength>\(n.entry!.uncompressedSize)</D:getcontentlength>"
        props += "<D:getcontenttype>application/octet-stream</D:getcontenttype>"
        props += "<D:getetag>\"\(n.entry!.crc32.map { String($0, radix: 16) } ?? String(n.entry!.uncompressedSize))\"</D:getetag>"
    }
    return "<D:response><D:href>\(hrefEncode(href))</D:href><D:propstat><D:prop>\(props)</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
}

func respond(_ r: Request) -> (Int, [String: String], Data) {
    let prefix = "/\(token)"
    guard r.path == prefix || r.path.hasPrefix(prefix + "/") else { return (404, [:], Data()) }
    let rel = String(r.path.dropFirst(prefix.count)).removingPercentEncoding ?? ""
    switch r.method {
    case "OPTIONS":
        return (200, ["DAV": "1", "Allow": "OPTIONS, GET, HEAD, PROPFIND", "MS-Author-Via": "DAV"], Data())
    case "PROPFIND":
        guard let n = lookup(rel) else { return (404, [:], Data()) }
        let base = prefix + (rel.hasPrefix("/") ? rel : "/" + rel)
        var xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:multistatus xmlns:D=\"DAV:\">"
        xml += propResponse(n.isDir && !base.hasSuffix("/") ? base + "/" : base, n)
        if n.isDir && r.headers["depth"] != "0" {
            let dirBase = base.hasSuffix("/") ? base : base + "/"
            for c in n.children.values { xml += propResponse(dirBase + c.name + (c.isDir ? "/" : ""), c) }
        }
        xml += "</D:multistatus>"
        return (207, ["Content-Type": "application/xml; charset=utf-8"], Data(xml.utf8))
    case "GET", "HEAD":
        guard let n = lookup(rel) else { return (404, [:], Data()) }
        if n.isDir { return (200, ["Content-Type": "text/plain"], Data()) }
        let size = n.entry!.uncompressedSize
        var headers = ["Content-Type": "application/octet-stream", "Accept-Ranges": "bytes",
                       "Last-Modified": httpDate.string(from: n.entry!.modified ?? Date(timeIntervalSince1970: 0))]
        var lo: Int64 = 0, hi: Int64 = size - 1, status = 200
        if let range = r.headers["range"], range.hasPrefix("bytes=") {
            let spec = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            if spec.count == 2 {
                if spec[0].isEmpty, let suffix = Int64(spec[1]) { lo = max(0, size - suffix) }
                else { lo = Int64(spec[0]) ?? 0; if let h = Int64(spec[1]) { hi = min(h, size - 1) } }
                status = 206
                headers["Content-Range"] = "bytes \(lo)-\(hi)/\(size)"
            }
        }
        if size == 0 { return (200, headers, Data()) }
        guard lo <= hi else { return (416, ["Content-Range": "bytes */\(size)"], Data()) }
        if r.method == "HEAD" { headers["Content-Length"] = String(hi - lo + 1); return (status, headers, Data()) }
        do {
            let data = try cache.data(for: n.entry!.path, size: size)
            return (status, headers, Data(data[Int(lo)...Int(min(hi, Int64(data.count) - 1))]))
        } catch {
            return (500, [:], Data("\(error)".utf8))
        }
    default:
        return (403, [:], Data())  // read-only: PUT, MKCOL, LOCK, PROPPATCH, DELETE, MOVE, COPY
    }
}

let reasons = [200: "OK", 206: "Partial Content", 207: "Multi-Status", 403: "Forbidden", 404: "Not Found",
               416: "Range Not Satisfiable", 500: "Internal Server Error"]

final class Client: @unchecked Sendable {
    let c: NWConnection
    var buffer = Data()
    init(_ c: NWConnection) { self.c = c }
    func start(_ q: DispatchQueue) { c.start(queue: q); receive() }
    func receive() {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, error in
            if let data { self.buffer.append(data) }
            while let r = self.parse() { self.handle(r) }
            if done || error != nil { self.c.cancel() } else { self.receive() }
        }
    }
    func parse() -> Request? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { buffer.removeAll(); return nil }
        var headers: [String: String] = [:]
        for l in lines { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard buffer.distance(from: end.upperBound, to: buffer.endIndex) >= length else { return nil }
        let body = buffer[end.upperBound..<buffer.index(end.upperBound, offsetBy: length)]
        buffer = Data(buffer[buffer.index(end.upperBound, offsetBy: length)...])
        var path = String(first[1])
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        return Request(method: String(first[0]), path: path, headers: headers, body: Data(body))
    }
    func handle(_ r: Request) {
        let t = Date()
        let (status, headers, body) = respond(r)
        var out = "HTTP/1.1 \(status) \(reasons[status] ?? "")\r\n"
        var h = headers
        if h["Content-Length"] == nil { h["Content-Length"] = String(body.count) }
        h["Date"] = httpDate.string(from: Date())
        for (k, v) in h { out += "\(k): \(v)\r\n" }
        out += "\r\n"
        var data = Data(out.utf8)
        if r.method != "HEAD" { data.append(body) }
        c.send(content: data, completion: .idempotent)
        if verbose {
            print(String(format: "%@ %@ %@ -> %d (%d B, %.1f ms)", r.method, r.headers["depth"] ?? "-", r.path, status, body.count,
                         Date().timeIntervalSince(t) * 1000))
        }
    }
}

let params = NWParameters.tcp
params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
let listener = try NWListener(using: params)
let queue = DispatchQueue(label: "xipdav", attributes: .concurrent)
listener.newConnectionHandler = { conn in Client(conn).start(DispatchQueue(label: "conn")) }
listener.stateUpdateHandler = { state in
    if case .ready = state, let p = listener.port {
        print("serving \(archive.lastPathComponent) at http://127.0.0.1:\(p.rawValue)/\(token)/")
    }
}
listener.start(queue: queue)
dispatchMain()
