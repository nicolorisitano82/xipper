import Darwin
import Foundation
import Security
import XipperKit

/// Server configuration: from `~/Library/Application Support/Xipper/mcp.json`, overridden by CLI flags.
public struct MCPConfig: Sendable {
    /// Folders the agent may read from and write to. Empty = every path is refused.
    public var allowedRoots: [String] = []
    /// Only info/list/test/read tools are exposed.
    public var readOnly = false
    /// Accept a clear-text `password` argument (off: the password would sit in the model's context).
    public var allowPasswordArgument = false
    public var extractionLimits = ExtractionLimits()
    public var maxListEntries = 1000
    public var auditLogPath: String? = MCPConfig.defaultAuditLog
    public var workload: Workload = .interactive

    public init() {}

    public static let defaultConfigPath = NSHomeDirectory() + "/Library/Application Support/Xipper/mcp.json"
    public static let defaultAuditLog = NSHomeDirectory() + "/Library/Logs/Xipper/mcp-audit.jsonl"

    /// Loads the JSON config file if present: {"allowedRoots": [...], "readOnly": bool,
    /// "allowPasswordArgument": bool, "maxTotalBytes": n, "auditLog": path | null}.
    public static func load(path: String = defaultConfigPath) throws -> MCPConfig {
        var c = MCPConfig()
        guard let data = FileManager.default.contents(atPath: path) else { return c }
        let j = try JSON.parse(data)
        c.allowedRoots = j["allowedRoots"]?.array?.compactMap(\.string) ?? []
        c.readOnly = j["readOnly"]?.bool ?? false
        c.allowPasswordArgument = j["allowPasswordArgument"]?.bool ?? false
        if let max = j["maxTotalBytes"]?.int { c.extractionLimits.maxTotalBytes = Int64(max) }
        if j["auditLog"] == .null { c.auditLogPath = nil } else if let a = j["auditLog"]?.string { c.auditLogPath = a }
        return c
    }
}

/// Resolves agent-supplied paths and enforces the allowlist.
struct PathPolicy: Sendable {
    let roots: [String]

    init(roots: [String]) {
        self.roots = roots.compactMap { Self.canonical(Self.expand($0)) }
    }

    static func expand(_ p: String) -> String {
        p.hasPrefix("~") ? NSHomeDirectory() + p.dropFirst() : p
    }

    /// realpath(3): resolves symlinks and `..`; nil if the path does not exist.
    static func canonical(_ p: String) -> String? {
        guard let r = realpath(p, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    /// Canonical absolute path inside an allowed root, or a tool error explaining why not.
    /// Paths that do not exist yet (outputs) are resolved through their parent folder.
    func resolve(_ raw: String, mustExist: Bool) throws -> String {
        let p = Self.expand(raw)
        guard p.hasPrefix("/") else { throw ToolError("path must be absolute: \(raw)") }
        // The allowlist is checked before existence, so the answer never reveals whether a
        // file exists outside the allowed folders.
        let existing = Self.canonical(p)
        let parent = (p as NSString).deletingLastPathComponent
        let name = (p as NSString).lastPathComponent
        let candidate: String
        if let existing {
            candidate = existing
        } else if let cp = Self.canonical(parent), !name.isEmpty, name != "..", name != "." {
            candidate = cp == "/" ? "/" + name : cp + "/" + name
        } else {
            candidate = (p as NSString).standardizingPath
        }
        guard isAllowed(candidate) else {
            throw ToolError(roots.isEmpty
                ? "no folders are allowed: configure them in Xipper (Settings › Integrations) or start the server with --allow <folder>"
                : "\(raw) is outside the allowed folders (\(roots.joined(separator: ", ")))")
        }
        if existing == nil {
            if mustExist { throw ToolError("no such file: \(raw)") }
            if Self.canonical(parent) == nil { throw ToolError("parent folder does not exist: \(raw)") }
        }
        return candidate
    }

    private func isAllowed(_ path: String) -> Bool {
        roots.contains { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }
    }
}

/// Archive passwords stored in the login Keychain and referenced by name, so they never
/// travel through the model's context.
public enum PasswordStore {
    public static let service = "app.xipper.mcp"

    public static func get(_ name: String) throws -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: name, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        guard st == errSecSuccess, let d = out as? Data, let s = String(data: d, encoding: .utf8) else {
            throw ToolError("no password named \"\(name)\" in the Keychain (create it with: xipper mcp password set \(name))")
        }
        return s
    }

    public static func set(_ name: String, password: String) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: name]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrLabel as String] = "Xipper archive password: \(name)"
        let st = SecItemAdd(add as CFDictionary, nil)
        if st != errSecSuccess { throw ToolError("Keychain error \(st)") }
    }

    @discardableResult
    public static func delete(_ name: String) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: name]
        return SecItemDelete(q as CFDictionary) == errSecSuccess
    }

    public static func names() -> [String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }
}

/// Append-only JSONL log of every tool call (no secrets, no file contents).
final class AuditLog: @unchecked Sendable {
    private let path: String?
    private let lock = NSLock()

    init(path: String?) {
        self.path = path
        if let path {
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    func record(client: String, tool: String, arguments: [String: JSON], outcome: String, seconds: Double) {
        guard let path else { return }
        // Only path-like and option arguments are logged; anything password-like is dropped.
        let safe = arguments.filter { !$0.key.lowercased().contains("password") }
        let entry: JSON = [
            "time": .string(ISO8601DateFormatter().string(from: Date())),
            "client": .string(client), "tool": .string(tool), "arguments": .object(safe),
            "outcome": .string(outcome), "seconds": .double((seconds * 1000).rounded() / 1000),
        ]
        var line = entry.serialized()
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }
}

/// A failure reported to the agent as a tool result with `isError: true`.
struct ToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
