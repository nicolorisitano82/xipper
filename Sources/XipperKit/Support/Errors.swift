import Darwin

/// Every failure XipperKit reports. Messages are English and technical;
/// the app maps cases to localized UI text.
public enum XipperError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A system call failed. `path` is the file involved, if any.
    case io(String, path: String?, errno: Int32)
    /// The archive structure is invalid or truncated.
    case corrupt(String)
    /// Valid archive, but uses a feature or method Xipper does not implement.
    case unsupported(String)
    /// An encrypted entry was found and no password was supplied.
    case passwordRequired(entry: String)
    /// The supplied password does not match (password verifier or check byte).
    case wrongPassword(entry: String)
    /// Data decoded but the checksum / authentication code does not match.
    case integrity(entry: String, detail: String)
    /// The entry would escape the destination or is otherwise unsafe.
    case unsafeEntry(entry: String, reason: String)
    /// A configured safety limit (size, ratio, count) was exceeded.
    case limitExceeded(String)
    /// Not enough free space on the destination volume (checked before and while writing).
    case insufficientSpace(needed: Int64, available: Int64)
    /// The destination already exists and the overwrite policy forbids replacing it.
    case alreadyExists(path: String)
    case invalidArgument(String)
    /// A codec library returned an error.
    case codec(String)
    case cancelled

    public var description: String {
        switch self {
        case let .io(op, path, err):
            return "\(op) failed\(path.map { " for \($0)" } ?? ""): \(String(cString: strerror(err)))"
        case let .corrupt(m): return "corrupt archive: \(m)"
        case let .unsupported(m): return "unsupported: \(m)"
        case let .passwordRequired(e): return "password required for \(e)"
        case let .wrongPassword(e): return "wrong password for \(e)"
        case let .integrity(e, d): return "integrity check failed for \(e): \(d)"
        case let .unsafeEntry(e, r): return "unsafe entry \(e): \(r)"
        case let .limitExceeded(m): return "safety limit exceeded: \(m)"
        case let .insufficientSpace(needed, available):
            return "not enough free space: \(needed) bytes needed, \(available) available"
        case let .alreadyExists(p): return "already exists: \(p)"
        case let .invalidArgument(m): return "invalid argument: \(m)"
        case let .codec(m): return "codec error: \(m)"
        case .cancelled: return "cancelled"
        }
    }

    static func posix(_ op: String, _ path: String? = nil) -> XipperError {
        .io(op, path: path, errno: errno)
    }
}
