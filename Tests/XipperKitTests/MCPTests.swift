import Foundation
import Synchronization
import Testing
@testable import XipperKit
@testable import XipperMCP

/// Drives an in-process MCPServer: sends requests, collects responses/notifications,
/// optionally answers server→client elicitation requests (legacy era).
final class MCPHarness: @unchecked Sendable {
    let server: MCPServer
    private let messages = Mutex<[JSON]>([])
    private let cond = NSCondition()
    private var nextID = 1
    let elicitationAnswer = Mutex<JSON?>(nil)

    init(config: MCPConfig) {
        var c = config
        if c.auditLogPath == MCPConfig.defaultAuditLog { c.auditLogPath = nil }
        var srv: MCPServer!
        let box = UnsafeBox()
        srv = MCPServer(config: c) { data in box.harness?.received(data) }
        server = srv
        box.harness = self
    }

    final class UnsafeBox: @unchecked Sendable { weak var harness: MCPHarness? }

    private func received(_ data: Data) {
        let msg = try! JSON.parse(data)
        if msg["method"]?.string == "elicitation/create", let id = msg["id"] {
            let answer = elicitationAnswer.withLock { $0 } ?? ["action": "decline"]
            server.receive(JSON.object(["jsonrpc": "2.0", "id": id, "result": answer]).serialized())
            return
        }
        cond.lock()
        messages.withLock { $0.append(msg) }
        cond.broadcast()
        cond.unlock()
    }

    static let modernMeta: JSON = [
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": ["elicitation": ["form": [:]]],
        "io.modelcontextprotocol/clientInfo": ["name": "test-client", "version": "1"],
    ]

    @discardableResult
    func request(_ method: String, _ params: JSON = [:], modern: Bool = false, meta: JSON? = nil) -> JSON {
        var p = params.object ?? [:]
        if modern || meta != nil {
            var m = (meta ?? Self.modernMeta).object!
            if let existing = p["_meta"]?.object { m.merge(existing) { $1 } }
            p["_meta"] = .object(m)
        }
        cond.lock()
        let id = JSON.int(Int64(nextID))
        nextID += 1
        cond.unlock()
        server.receive(JSON.object(["jsonrpc": "2.0", "id": id, "method": .string(method), "params": .object(p)]).serialized())
        cond.lock()
        defer { cond.unlock() }
        let deadline = Date().addingTimeInterval(60)
        while true {
            if let r = messages.withLock({ $0.first { $0["id"] == id } }) { return r }
            if !cond.wait(until: deadline) { return ["timeout": true] }
        }
    }

    func call(_ tool: String, _ args: JSON, modern: Bool = false, extra: [String: JSON] = [:]) -> JSON {
        var p: [String: JSON] = ["name": .string(tool), "arguments": args]
        p.merge(extra) { $1 }
        return request("tools/call", .object(p), modern: modern)["result"] ?? .null
    }

    var notifications: [JSON] { messages.withLock { $0.filter { $0["id"] == nil } } }

    func initializeLegacy(elicitation: Bool = false) {
        let caps: JSON = elicitation ? ["elicitation": [:]] : [:]
        request("initialize", ["protocolVersion": "2025-11-25", "capabilities": caps, "clientInfo": ["name": "legacy-test", "version": "1"]])
        server.receive(JSON.object(["jsonrpc": "2.0", "method": "notifications/initialized"]).serialized())
    }
}

func text(_ result: JSON) -> String { result["content"]?.array?.first?["text"]?.string ?? "" }

@Suite("MCP server")
struct MCPTests {
    func harness(_ t: TempDir, readOnly: Bool = false, audit: String? = nil, allowPassword: Bool = false) -> MCPHarness {
        var c = MCPConfig()
        c.allowedRoots = [t.path]
        c.readOnly = readOnly
        c.auditLogPath = audit
        c.allowPasswordArgument = allowPassword
        c.workload = .threads(4)
        return MCPHarness(config: c)
    }

    @Test func legacyHandshakeAndToolList() throws {
        let t = TempDir()
        let h = harness(t)
        let r = h.request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "x", "version": "1"]])
        #expect(r["result"]?["protocolVersion"]?.string == "2025-06-18")
        #expect(r["result"]?["serverInfo"]?["name"]?.string == "xipper")
        let unknown = h.request("initialize", ["protocolVersion": "2099-01-01", "capabilities": [:]])
        #expect(unknown["result"]?["protocolVersion"]?.string == "2025-11-25")
        let tools = h.request("tools/list")["result"]?["tools"]?.array ?? []
        #expect(tools.count == 12)
        let extract = tools.first { $0["name"]?.string == "archive_extract" }
        #expect(extract?["annotations"]?["destructiveHint"]?.bool == true)
        #expect(tools.allSatisfy { $0["inputSchema"]?["type"]?.string == "object" })
        #expect(h.request("ping")["result"] == [:])
        #expect(h.request("nope")["error"]?["code"]?.int == MCPError.methodNotFound)
    }

    @Test func modernDiscoverAndErrors() throws {
        let t = TempDir()
        let h = harness(t)
        let d = h.request("server/discover", modern: true)["result"]
        #expect(d?["resultType"]?.string == "complete")
        #expect(d?["supportedVersions"]?.array == ["2026-07-28"])
        #expect(d?["capabilities"]?["tools"] != nil)
        #expect(d?["ttlMs"]?.int != nil && d?["cacheScope"]?.string != nil)
        #expect(d?["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"]?.string == "xipper")
        let list = h.request("tools/list", modern: true)["result"]
        #expect(list?["resultType"]?.string == "complete" && list?["ttlMs"] != nil && list?["cacheScope"] != nil)
        let bad = h.request("server/discover", meta: ["io.modelcontextprotocol/protocolVersion": "1900-01-01",
                                                      "io.modelcontextprotocol/clientCapabilities": [:]])
        #expect(bad["error"]?["code"]?.int == -32022)
        #expect(bad["error"]?["data"]?["requested"]?.string == "1900-01-01")
        let noCaps = h.request("tools/list", meta: ["io.modelcontextprotocol/protocolVersion": "2026-07-28"])
        #expect(noCaps["error"]?["code"]?.int == MCPError.invalidParams)
    }

    @Test func allowlistIsEnforced() throws {
        let t = TempDir()
        let outside = TempDir()
        outside.write("secret.txt", "s")
        try Xipper.create(from: [outside.url("secret.txt")], to: outside.url("o.zip"))
        t.symlink("sneaky.zip", to: outside.path + "/o.zip")
        let h = harness(t)
        h.initializeLegacy()
        for p in [outside.path + "/o.zip", t.path + "/sneaky.zip", t.path + "/../" + (outside.path as NSString).lastPathComponent + "/o.zip", "relative.zip"] {
            let r = h.call("archive_list", ["path": .string(p)])
            #expect(r["isError"]?.bool == true, "\(p) should be refused")
        }
        // A missing file outside the allowed folders must not be reported as missing (no existence oracle).
        #expect(text(h.call("archive_info", ["path": "/etc/definitely-not-here.zip"])).contains("outside the allowed folders"))
        let empty = MCPHarness(config: MCPConfig())
        empty.initializeLegacy()
        #expect(text(empty.call("archive_info", ["path": .string(t.path + "/x.zip")])).contains("no folders are allowed"))
    }

    @Test func readOnlyHidesWritingTools() throws {
        let t = TempDir()
        let h = harness(t, readOnly: true)
        h.initializeLegacy()
        let names = (h.request("tools/list")["result"]?["tools"]?.array ?? []).compactMap { $0["name"]?.string }
        #expect(Set(names) == ["archive_info", "archive_list", "archive_test", "archive_read_entry", "bgzf_check", "genomics_check", "checksum_manifest"])
        let r = h.request("tools/call", ["name": "archive_extract", "arguments": [:]])
        #expect(r["error"]?["code"]?.int == MCPError.invalidParams)
    }

    @Test(arguments: [false, true])
    func archiveWorkflow(modern: Bool) throws {
        let t = TempDir()
        makeTree(t, bigSize: 2 << 20)
        let auditPath = t.path + "/audit.jsonl"
        let h = harness(t, audit: auditPath)
        if !modern { h.initializeLegacy() }
        let zip = t.path + "/out.zip"
        let created = h.call("archive_create", ["sources": [.string(t.path + "/src")], "output": .string(zip)], modern: modern)
        #expect(created["isError"]?.bool == false, "\(text(created))")
        if modern { #expect(created["resultType"]?.string == "complete") }
        #expect(created["structuredContent"]?["entries"]?.int ?? 0 > 5)

        let info = h.call("archive_info", ["path": .string(zip)], modern: modern)
        #expect(info["structuredContent"]?["format"]?.string == "zip")

        let page1 = h.call("archive_list", ["path": .string(zip), "limit": 3], modern: modern)
        #expect(page1["structuredContent"]?["entries"]?.array?.count == 3)
        let cursor = page1["structuredContent"]?["nextCursor"]?.string
        #expect(cursor == "3")
        let page2 = h.call("archive_list", ["path": .string(zip), "limit": 3, "cursor": .string(cursor ?? "")], modern: modern)
        #expect(page2["structuredContent"]?["entries"]?.array?.first?["path"] != page1["structuredContent"]?["entries"]?.array?.first?["path"])
        let globbed = h.call("archive_list", ["path": .string(zip), "glob": "*.txt"], modern: modern)
        #expect(globbed["structuredContent"]?["totalCount"]?.int == 2)

        let read = h.call("archive_read_entry", ["path": .string(zip), "entry": "src/readme.txt"], modern: modern)
        #expect(text(read) == "hello xipper\n")
        let bin = h.call("archive_read_entry", ["path": .string(zip), "entry": "src/data/big.bin", "max_bytes": 4096], modern: modern)
        #expect(bin["isError"]?.bool == true)

        let tested = h.call("archive_test", ["path": .string(zip)], modern: modern, extra: ["_meta": ["progressToken": "p1"]])
        #expect(tested["structuredContent"]?["ok"]?.bool == true)
        #expect(h.notifications.contains { $0["method"]?.string == "notifications/progress" && $0["params"]?["progressToken"] == "p1" })

        t.mkdir("dest")
        let ex = h.call("archive_extract", ["path": .string(zip), "destination": .string(t.path + "/dest")], modern: modern)
        #expect(ex["isError"]?.bool == false, "\(text(ex))")
        #expect(FileManager.default.fileExists(atPath: t.path + "/dest/src/readme.txt"))

        // Audit: one line per call, tool names, no secrets.
        h.server.waitForIdle()
        let log = (try? String(contentsOfFile: auditPath, encoding: .utf8)) ?? ""
        #expect(log.split(separator: "\n").count == 9)
        #expect(log.contains("\"tool\":\"archive_extract\""))
    }

    @Test func modernConfirmationUsesSignedRequestState() throws {
        let t = TempDir()
        t.write("a.txt", "one")
        let h = harness(t)
        let out = t.path + "/a.zip"
        let args: JSON = ["sources": [.string(t.path + "/a.txt")], "output": .string(out)]
        #expect(h.call("archive_create", args, modern: true)["isError"]?.bool == false)
        var overwrite = args.object!
        overwrite["overwrite"] = true
        // 1. Server asks for confirmation.
        let ask = h.call("archive_create", .object(overwrite), modern: true)
        #expect(ask["resultType"]?.string == "input_required")
        let state = ask["requestState"]?.string ?? ""
        #expect(ask["inputRequests"]?["confirm"]?["method"]?.string == "elicitation/create")
        let accept: JSON = ["confirm": ["action": "accept", "content": ["confirm": true]]]
        // 2. A tampered call (different output) with that state is asked again.
        var other = overwrite
        other["output"] = .string(t.path + "/b.zip")
        t.write("b.zip", "x")
        let tampered = h.call("archive_create", .object(other), modern: true, extra: ["inputResponses": accept, "requestState": .string(state)])
        #expect(tampered["resultType"]?.string == "input_required")
        // 3. Forged state is ignored.
        let forged = h.call("archive_create", .object(overwrite), modern: true, extra: ["inputResponses": accept, "requestState": "Zm9v.YmFy"])
        #expect(forged["resultType"]?.string == "input_required")
        // 4. Declined.
        let declined = h.call("archive_create", .object(overwrite), modern: true,
                              extra: ["inputResponses": ["confirm": ["action": "decline"]], "requestState": .string(state)])
        #expect(declined["isError"]?.bool == true && text(declined).contains("declined"))
        // 5. Accepted: done.
        let done = h.call("archive_create", .object(overwrite), modern: true, extra: ["inputResponses": accept, "requestState": .string(state)])
        #expect(done["resultType"]?.string == "complete" && done["isError"]?.bool == false, "\(text(done))")
        // 6. A client without elicitation cannot overwrite.
        let noElicit = h.request("tools/call", ["name": "archive_create", "arguments": .object(overwrite)],
                                 meta: ["io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": [:]])
        #expect(noElicit["result"]?["isError"]?.bool == true)
    }

    @Test func legacyConfirmationUsesElicitationRequest() throws {
        let t = TempDir()
        t.write("a.txt", "one")
        let h = harness(t)
        h.initializeLegacy(elicitation: true)
        let args: JSON = ["sources": [.string(t.path + "/a.txt")], "output": .string(t.path + "/a.zip"), "overwrite": true]
        t.write("a.zip", "old")
        h.elicitationAnswer.withLock { $0 = ["action": "decline"] }
        #expect(h.call("archive_create", args)["isError"]?.bool == true)
        h.elicitationAnswer.withLock { $0 = ["action": "accept", "content": ["confirm": true]] }
        let ok = h.call("archive_create", args)
        #expect(ok["isError"]?.bool == false, "\(text(ok))")
        #expect(try ArchiveFormat.detect(t.url("a.zip")) == .zip)
    }

    @Test func passwordsComeFromKeychainNotChat() throws {
        let t = TempDir()
        t.write("s/secret.txt", "classified")
        var o = CreateOptions()
        o.password = "Passw0rd-xipper"
        try Xipper.create(from: [t.url("s")], to: t.url("enc.zip"), options: o)
        let zip = t.path + "/enc.zip"
        let ref = "xipper-test-\(UUID().uuidString.prefix(8))"
        try PasswordStore.set(ref, password: "Passw0rd-xipper")
        defer { PasswordStore.delete(ref) }

        let h = harness(t)
        h.initializeLegacy()
        #expect(h.call("archive_test", ["path": .string(zip)])["isError"]?.bool == true)
        let clear = h.call("archive_test", ["path": .string(zip), "password": "Passw0rd-xipper"])
        #expect(text(clear).contains("disabled"))
        let viaRef = h.call("archive_test", ["path": .string(zip), "password_ref": .string(ref)])
        #expect(viaRef["structuredContent"]?["ok"]?.bool == true, "\(text(viaRef))")
        let read = h.call("archive_read_entry", ["path": .string(zip), "entry": "s/secret.txt", "password_ref": .string(ref)])
        #expect(text(read) == "classified")
        let missing = h.call("archive_test", ["path": .string(zip), "password_ref": "does-not-exist"])
        #expect(text(missing).contains("no password named"))

        let permissive = harness(t, allowPassword: true)
        permissive.initializeLegacy()
        #expect(permissive.call("archive_test", ["path": .string(zip), "password": "Passw0rd-xipper"])["structuredContent"]?["ok"]?.bool == true)
    }

    @Test func bgzfTools() throws {
        let t = TempDir()
        t.write("calls.vcf", sampleVCF(records: 3000))
        _ = run("/bin/sh", ["-c", "/usr/bin/gzip -c '\(t.path)/calls.vcf' > '\(t.path)/plain.vcf.gz'"])
        let h = harness(t)
        h.initializeLegacy(elicitation: true)
        let c = h.call("bgzf_compress", ["path": .string(t.path + "/calls.vcf"), "index": true])
        #expect(c["isError"]?.bool == false, "\(text(c))")
        #expect(FileManager.default.fileExists(atPath: t.path + "/calls.vcf.gz.gzi"))
        let check = h.call("bgzf_check", ["path": .string(t.path + "/calls.vcf.gz")])
        #expect(check["structuredContent"]?["ok"]?.bool == true)
        let notBGZF = h.call("bgzf_check", ["path": .string(t.path + "/plain.vcf.gz")])
        #expect(notBGZF["isError"]?.bool == true)
        let conv = h.call("bgzf_convert", ["path": .string(t.path + "/plain.vcf.gz"), "output": .string(t.path + "/fixed.vcf.gz")])
        #expect(conv["isError"]?.bool == false, "\(text(conv))")
        #expect(try ArchiveFormat.detect(t.url("fixed.vcf.gz")) == .bgzf)
        h.elicitationAnswer.withLock { $0 = ["action": "accept", "content": ["confirm": true]] }
        let inPlace = h.call("bgzf_convert", ["path": .string(t.path + "/plain.vcf.gz"), "in_place": true])
        #expect(inPlace["isError"]?.bool == false, "\(text(inPlace))")
        #expect(try ArchiveFormat.detect(t.url("plain.vcf.gz")) == .bgzf)
    }

    /// The real binary over stdio: a modern probe, then a legacy session in a second process.
    @Test func stdioEndToEnd() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [".build/debug/xipper", ".build/arm64-apple-macosx/debug/xipper", ".build/release/xipper"].map { root.path + "/" + $0 }
        guard let exe = candidates.first(where: toolExists) else { return }
        let t = TempDir()
        t.write("a.txt", "hello")
        let modern = """
        {"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
        {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"archive_create","arguments":{"sources":["\(t.path)/a.txt"],"output":"\(t.path)/a.tar.zst"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}

        """
        let r = run(exe, ["mcp", "--allow", t.path, "--no-audit"], stdin: modern)
        let lines = r.output.split(separator: "\n").filter { $0.hasPrefix("{") }
        #expect(lines.count == 2, "\(r.output)")
        #expect(lines.contains { $0.contains("\"supportedVersions\":[\"2026-07-28\"]") })
        #expect(FileManager.default.fileExists(atPath: t.path + "/a.tar.zst"))
        let legacy = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"e2e","version":"1"}}}
        {"jsonrpc":"2.0","method":"notifications/initialized"}
        {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"archive_list","arguments":{"path":"\(t.path)/a.tar.zst"}}}

        """
        let l = run(exe, ["mcp", "--allow", t.path, "--no-audit"], stdin: legacy)
        #expect(l.output.contains("\"protocolVersion\":\"2025-11-25\""))
        #expect(l.output.contains("a.txt"))
    }
}
