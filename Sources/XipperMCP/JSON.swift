import Foundation

/// Minimal JSON value for JSON-RPC messages (no SDK: XipperMCP depends on Foundation only).
public enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    // MARK: access

    public subscript(key: String) -> JSON? {
        if case let .object(o) = self { return o[key] }
        return nil
    }

    public var string: String? { if case let .string(s) = self { return s } else { return nil } }
    public var bool: Bool? { if case let .bool(b) = self { return b } else { return nil } }
    public var array: [JSON]? { if case let .array(a) = self { return a } else { return nil } }
    public var object: [String: JSON]? { if case let .object(o) = self { return o } else { return nil } }
    public var int: Int? {
        switch self {
        case let .int(i): return Int(exactly: i)
        case let .double(d): return Int(exactly: d)
        default: return nil
        }
    }

    // MARK: parse / serialize

    public static func parse(_ data: Data) throws -> JSON {
        try from(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    static func from(_ any: Any) throws -> JSON {
        switch any {
        case is NSNull: return .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            if CFNumberIsFloatType(n) { return .double(n.doubleValue) }
            return .int(n.int64Value)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(try a.map(from))
        case let o as [String: Any]: return .object(try o.mapValues(from))
        default: throw MCPError(code: -32700, message: "unsupported JSON value")
        }
    }

    var foundation: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(b): return b
        case let .int(i): return i
        case let .double(d): return d
        case let .string(s): return s
        case let .array(a): return a.map(\.foundation)
        case let .object(o): return o.mapValues(\.foundation)
        }
    }

    /// Single-line serialization (stdio framing forbids embedded newlines; JSON escapes them).
    public func serialized() -> Data {
        (try? JSONSerialization.data(withJSONObject: foundation, options: [.fragmentsAllowed, .withoutEscapingSlashes, .sortedKeys]))
            ?? Data("null".utf8)
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral v: String) { self = .string(v) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
    public init(integerLiteral v: Int64) { self = .int(v) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
    public init(nilLiteral: ()) { self = .null }
}

extension JSON {
    init(_ v: Int64) { self = .int(v) }
    init(_ v: Int) { self = .int(Int64(v)) }
    init(_ v: Double) { self = .double(v) }
    init(_ v: String?) { self = v.map(JSON.string) ?? .null }
}

/// JSON-RPC error (protocol level, as opposed to a tool result with `isError`).
public struct MCPError: Error, Sendable {
    public var code: Int
    public var message: String
    public var data: JSON?

    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603

    var json: JSON {
        var o: [String: JSON] = ["code": .int(Int64(code)), "message": .string(message)]
        if let data { o["data"] = data }
        return .object(o)
    }
}
