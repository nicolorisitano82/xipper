import CryptoKit
import Dispatch
import Foundation
import Synchronization
import XipperKit

/// Xipper's MCP server: JSON-RPC 2.0 messages in, JSON-RPC messages out.
///
/// Transport-agnostic: `receive` takes one message (one stdio line), `send` emits one.
/// Tool calls run concurrently; `notifications/cancelled` cancels them cooperatively.
public final class MCPServer: @unchecked Sendable {
    public static let serverVersion = "1.0.2"
    /// Stateless revisions: every request carries its version and capabilities in `_meta`.
    static let modernVersions = ["2026-07-28"]
    /// Session-based revisions, selected by `initialize` for the life of the stdio process.
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    static let metaVersion = "io.modelcontextprotocol/protocolVersion"
    static let metaCapabilities = "io.modelcontextprotocol/clientCapabilities"
    static let metaClientInfo = "io.modelcontextprotocol/clientInfo"
    static let metaServerInfo = "io.modelcontextprotocol/serverInfo"

    /// Which protocol generation a request belongs to.
    enum Era {
        case legacy
        case modern(capabilities: JSON, client: String)
    }

    /// Signs MRTR `requestState` tokens; new per process, so tokens die with the server.
    private let stateKey = SymmetricKey(size: .bits256)

    let config: MCPConfig
    private let policy: PathPolicy
    private let audit: AuditLog
    private let send: @Sendable (Data) -> Void
    private let tools: [String: Tool]
    private let toolOrder: [String]
    private let queue = DispatchQueue(label: "xipper.mcp.calls", qos: .userInitiated, attributes: .concurrent)
    private let group = DispatchGroup()
    private let state = Mutex(State())

    private struct State {
        var protocolVersion: String?
        var clientName = "unknown"
        var clientCapabilities: JSON = [:]
        var inFlight: [String: CancellationToken] = [:]
        var pending: [String: (JSON) -> Void] = [:]
        var nextServerRequest = 1
    }

    public init(config: MCPConfig, send: @escaping @Sendable (Data) -> Void) {
        self.config = config
        policy = PathPolicy(roots: config.allowedRoots)
        audit = AuditLog(path: config.auditLogPath)
        self.send = send
        let list = XipperTools.all(readOnly: config.readOnly)
        tools = Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
        toolOrder = list.map(\.name)
    }

    /// Blocks until every running tool call has answered (used at end of input and in tests).
    public func waitForIdle() { group.wait() }

    // MARK: input

    public func receive(_ data: Data) {
        let message: JSON
        do { message = try JSON.parse(data) } catch {
            reply(id: .null, error: MCPError(code: MCPError.parseError, message: "parse error"))
            return
        }
        guard case let .object(m) = message, m["jsonrpc"]?.string == "2.0" else {
            reply(id: message["id"] ?? .null, error: MCPError(code: MCPError.invalidRequest, message: "not a JSON-RPC 2.0 message"))
            return
        }
        if let method = m["method"]?.string {
            let params = m["params"]?.object ?? [:]
            if let id = m["id"] {
                handleRequest(id: id, method: method, params: params)
            } else {
                handleNotification(method: method, params: params)
            }
        } else if let id = m["id"] {
            // Response to a request we sent (elicitation).
            let key = id.serialized()
            let cb = state.withLock { $0.pending.removeValue(forKey: String(decoding: key, as: UTF8.self)) }
            cb?(message)
        }
    }

    private func handleNotification(method: String, params: [String: JSON]) {
        switch method {
        case "notifications/cancelled":
            if let id = params["requestId"] {
                let key = String(decoding: id.serialized(), as: UTF8.self)
                state.withLock { $0.inFlight[key] }?.cancel()
            }
        default:
            break  // notifications/initialized and unknown notifications need no answer
        }
    }

    private func handleRequest(id: JSON, method: String, params: [String: JSON]) {
        if let meta = params["_meta"]?.object, let version = meta[Self.metaVersion]?.string {
            handleModern(id: id, method: method, params: params, version: version, meta: meta)
            return
        }
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.string ?? ""
            let version = Self.legacyVersions.contains(requested) ? requested : Self.legacyVersions[0]
            state.withLock {
                $0.protocolVersion = version
                $0.clientName = params["clientInfo"]?["name"]?.string ?? "unknown"
                $0.clientCapabilities = params["capabilities"] ?? [:]
            }
            reply(id: id, result: [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "xipper", "title": "Xipper", "version": .string(Self.serverVersion)],
                "instructions": .string(instructions),
            ])
        case "ping":
            reply(id: id, result: [:])
        case "tools/list":
            reply(id: id, result: ["tools": .array(toolOrder.map { tools[$0]!.definition })])
        case "tools/call":
            callTool(id: id, params: params, era: .legacy)
        default:
            reply(id: id, error: MCPError(code: MCPError.methodNotFound, message: "method not found: \(method)"))
        }
    }

    /// 2026-07-28: no handshake, no session; each request is self-describing.
    private func handleModern(id: JSON, method: String, params: [String: JSON], version: String, meta: [String: JSON]) {
        guard Self.modernVersions.contains(version) else {
            reply(id: id, error: MCPError(code: -32022, message: "Unsupported protocol version",
                                          data: ["supported": .array((Self.modernVersions + Self.legacyVersions).map(JSON.string)),
                                                 "requested": .string(version)]))
            return
        }
        guard let caps = meta[Self.metaCapabilities] else {
            reply(id: id, error: MCPError(code: MCPError.invalidParams, message: "missing \(Self.metaCapabilities) in _meta"))
            return
        }
        let client = meta[Self.metaClientInfo]?["name"]?.string ?? "unknown"
        switch method {
        case "server/discover":
            replyModern(id: id, [
                "supportedVersions": .array(Self.modernVersions.map(JSON.string)),
                "capabilities": ["tools": [:]],
                "instructions": .string(instructions),
                "ttlMs": 3_600_000, "cacheScope": "private",
            ])
        case "tools/list":
            replyModern(id: id, ["tools": .array(toolOrder.map { tools[$0]!.definition }), "ttlMs": 3_600_000, "cacheScope": "private"])
        case "tools/call":
            callTool(id: id, params: params, era: .modern(capabilities: caps, client: client))
        case "ping":
            replyModern(id: id, [:])
        default:
            reply(id: id, error: MCPError(code: MCPError.methodNotFound, message: "method not found: \(method)"))
        }
    }

    private var serverInfo: JSON { ["name": "xipper", "title": "Xipper", "version": .string(Self.serverVersion)] }

    /// Modern results always carry `resultType` and the server identity.
    private func replyModern(id: JSON, _ result: [String: JSON], type: String = "complete") {
        var r = result
        r["resultType"] = .string(type)
        r["_meta"] = .object([Self.metaServerInfo: serverInfo])
        reply(id: id, result: .object(r))
    }

    var instructions: String {
        var s = "Xipper creates, lists, verifies and extracts archives (zip, tar.*, gz, BGZF/bgzip for genomics) on this Mac. "
        s += "Only paths inside the user's allowed folders are accepted"
        s += policy.roots.isEmpty ? " (none configured yet). " : ": \(policy.roots.joined(separator: ", ")). "
        s += "Never ask the user to type an archive password in chat: use password_ref (a Keychain entry name). "
        s += "Prefer archive_info/archive_list before extracting; extraction never overwrites unless the user confirms. "
        s += "Genomics: genomics_check verifies VCF.gz/BCF/BAM/CRAM files and their indexes, genomics_index builds tabix/CSI indexes, checksum_manifest creates and verifies sha-256/md5/crc32c manifests."
        if config.readOnly { s += " The server is in read-only mode." }
        return s
    }

    // MARK: tools/call

    private func callTool(id: JSON, params: [String: JSON], era: Era) {
        guard let name = params["name"]?.string, let tool = tools[name] else {
            reply(id: id, error: MCPError(code: MCPError.invalidParams, message: "unknown tool \(params["name"]?.string ?? "")"))
            return
        }
        let args = params["arguments"]?.object ?? [:]
        let progressToken = params["_meta"]?["progressToken"]
        let token = CancellationToken()
        let key = String(decoding: id.serialized(), as: UTF8.self)
        let legacyClient = state.withLock { s -> String in
            s.inFlight[key] = token
            return s.clientName
        }
        let client: String
        let confirmation: @Sendable (String) throws -> Bool
        switch era {
        case .legacy:
            client = legacyClient
            confirmation = { [self] in try confirmLegacy($0) }
        case let .modern(caps, clientName):
            client = clientName
            let answer = verifiedConfirmation(params: params, tool: name, arguments: args)
            confirmation = { message in
                guard caps["elicitation"] != nil else {
                    throw ToolError("this operation needs the user's confirmation, but the client cannot ask for it (no elicitation support)")
                }
                guard let answer else { throw NeedsConfirmation(message: message) }
                return answer
            }
        }
        let modern: Bool = if case .modern = era { true } else { false }
        group.enter()
        queue.async { [self] in
            defer {
                state.withLock { _ = $0.inFlight.removeValue(forKey: key) }
                group.leave()
            }
            let start = Date()
            let ctx = ToolContext(config: config, policy: policy, cancel: token,
                                  progress: progressToken.map(progressHandler), confirm: confirmation)
            var outcome = "ok"
            func result(_ r: [String: JSON]) {
                if modern { replyModern(id: id, r) } else { reply(id: id, result: .object(r)) }
            }
            do {
                let r = try tool.handler(args, ctx)
                var content: [JSON] = [["type": "text", "text": .string(r.text)]]
                content += r.extraContent
                var out: [String: JSON] = ["content": .array(content), "isError": false]
                if let s = r.structured { out["structuredContent"] = s }
                result(out)
            } catch let need as NeedsConfirmation {
                // MRTR: ask the client to elicit, then retry the same call with the answer.
                outcome = "confirmation requested"
                replyModern(id: id, [
                    "inputRequests": ["confirm": ["method": "elicitation/create", "params": [
                        "mode": "form", "message": .string(need.message),
                        "requestedSchema": ["type": "object", "required": ["confirm"], "properties": [
                            "confirm": ["type": "boolean", "title": "Confirm", "description": .string(need.message), "default": false],
                        ]],
                    ]]],
                    "requestState": .string(requestState(tool: name, arguments: args)),
                ], type: "input_required")
            } catch XipperError.cancelled {
                outcome = "cancelled"  // the client cancelled: no response is sent
            } catch let e as MCPError {
                outcome = "invalid: \(e.message)"
                reply(id: id, error: e)
            } catch {
                let message = (error as? ToolError)?.message ?? (error as? XipperError)?.description ?? "\(error)"
                outcome = "error: \(message)"
                result(["content": [["type": "text", "text": .string(message)]], "isError": true])
            }
            audit.record(client: client, tool: name, arguments: args, outcome: outcome, seconds: Date().timeIntervalSince(start))
        }
    }

    // MARK: MRTR request state

    private struct NeedsConfirmation: Error { let message: String }

    /// Opaque token binding a confirmation to this tool, these exact arguments and a 10-minute
    /// expiry, authenticated with a per-process HMAC key (the client could otherwise replay or
    /// forge it for a different call).
    private func requestState(tool: String, arguments: [String: JSON]) -> String {
        let expiry = Int(Date().timeIntervalSince1970) + 600
        let body = "\(expiry):" + digest(tool: tool, arguments: arguments)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: stateKey)
        return Data(body.utf8).base64EncodedString() + "." + Data(mac).base64EncodedString()
    }

    private func digest(tool: String, arguments: [String: JSON]) -> String {
        var d = Data(tool.utf8)
        d.append(0)
        d.append(JSON.object(arguments).serialized())
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    /// The user's answer carried by a retried call, if its requestState is authentic, unexpired and
    /// matches the call; nil means "ask (again)".
    private func verifiedConfirmation(params: [String: JSON], tool: String, arguments: [String: JSON]) -> Bool? {
        guard let token = params["requestState"]?.string, let response = params["inputResponses"]?["confirm"] else { return nil }
        let parts = token.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let body = Data(base64Encoded: parts[0]), let mac = Data(base64Encoded: parts[1]),
              HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: body, using: stateKey),
              let text = String(data: body, encoding: .utf8) else { return nil }
        let fields = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard fields.count == 2, let expiry = Int(fields[0]), expiry >= Int(Date().timeIntervalSince1970),
              fields[1] == digest(tool: tool, arguments: arguments) else { return nil }
        return response["action"]?.string == "accept" && response["content"]?["confirm"]?.bool == true
    }

    private func progressHandler(_ token: JSON) -> ProgressHandler {
        { [self] p in
            var params: [String: JSON] = ["progressToken": token, "progress": .int(p.completedBytes)]
            if p.totalBytes > 0 { params["total"] = .int(p.totalBytes) }
            if let e = p.currentEntry { params["message"] = .string(e) }
            notify("notifications/progress", params: .object(params))
        }
    }

    // MARK: confirmation (elicitation)

    /// Asks the human through the client and waits for the answer. Requires the client's
    /// `elicitation` capability; without it destructive operations are refused.
    private func confirmLegacy(_ message: String) throws -> Bool {
        let caps = state.withLock { $0.clientCapabilities }
        guard caps["elicitation"] != nil else {
            throw ToolError("this operation needs the user's confirmation, but the client cannot ask for it (no elicitation support)")
        }
        let answer = Mutex<JSON?>(nil)
        let done = DispatchSemaphore(value: 0)
        let id = state.withLock { s -> JSON in
            let id = JSON.string("xipper-confirm-\(s.nextServerRequest)")
            s.nextServerRequest += 1
            s.pending[String(decoding: id.serialized(), as: UTF8.self)] = { reply in
                answer.withLock { $0 = reply }
                done.signal()
            }
            return id
        }
        write(["jsonrpc": "2.0", "id": id, "method": "elicitation/create", "params": [
            "message": .string(message),
            "requestedSchema": ["type": "object", "required": ["confirm"], "properties": [
                "confirm": ["type": "boolean", "title": "Confirm", "description": .string(message)],
            ]],
        ]])
        if done.wait(timeout: .now() + 600) == .timedOut { throw ToolError("no confirmation received within 10 minutes") }
        let r = answer.withLock { $0 } ?? .null
        return r["result"]?["action"]?.string == "accept" && r["result"]?["content"]?["confirm"]?.bool == true
    }

    // MARK: output

    private func reply(id: JSON, result: JSON) { write(["jsonrpc": "2.0", "id": id, "result": result]) }
    private func reply(id: JSON, error: MCPError) { write(["jsonrpc": "2.0", "id": id, "error": error.json]) }
    func notify(_ method: String, params: JSON) { write(["jsonrpc": "2.0", "method": .string(method), "params": params]) }

    private func write(_ message: JSON) { send(message.serialized()) }
}

/// Runs a server over stdin/stdout: one JSON-RPC message per line, logs on stderr.
public enum StdioTransport {
    public static func run(_ makeServer: (@escaping @Sendable (Data) -> Void) -> MCPServer) {
        let out = Mutex(())
        let server = makeServer { data in
            out.withLock { _ in
                var line = data
                line.append(0x0A)
                line.withUnsafeBytes { b in
                    var done = 0
                    while done < b.count {
                        let n = Darwin.write(STDOUT_FILENO, b.baseAddress! + done, b.count - done)
                        if n < 0 { if errno == EINTR { continue }; return }
                        done += n
                    }
                }
            }
        }
        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }
            server.receive(Data(line.utf8))
        }
        server.waitForIdle()
    }
}
