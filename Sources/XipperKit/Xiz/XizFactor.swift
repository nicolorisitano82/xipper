import CryptoKit
import Foundation

/// A second factor for XIZ passwords (1.14, §24.3): 32 random bytes kept apart from the archive,
/// in a `.xizfactor` file (`XIZ-FACTOR-1-` + base64url, one line) or in the Keychain. Without it
/// the password cannot be checked, so the archive alone cannot be attacked by guessing.
public struct XizFactor: Sendable, Equatable {
    public static let prefix = "XIZ-FACTOR-1-"
    public static let fileExtension = "xizfactor"
    public var bytes: [UInt8]

    public init() {
        var b = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&b, 32)
        bytes = b
    }

    public init(bytes: [UInt8]) throws {
        guard bytes.count == 32 else { throw XipperError.invalidArgument("a XIZ factor is 32 bytes") }
        self.bytes = bytes
    }

    /// From its text form (surrounding blanks and other lines ignored).
    public init(text: String) throws {
        guard let line = text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { $0.hasPrefix(Self.prefix) }) else { throw XipperError.invalidArgument("not a XIZ factor (XIZ-FACTOR-1-…)") }
        var b64 = String(line.dropFirst(Self.prefix.count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64) else { throw XipperError.invalidArgument("not a XIZ factor (bad base64)") }
        try self.init(bytes: Array(data))
    }

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count < 4096 else { throw XipperError.invalidArgument("not a XIZ factor file") }
        try self.init(text: String(decoding: data, as: UTF8.self))
    }

    public var text: String {
        Self.prefix + Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// First 8 bytes of SHA-256, as stored in the stanza (hex).
    public var id: String { XizAccessKeys.factorID(bytes).map { String(format: "%02x", $0) }.joined() }

    /// Writes the file readable by its owner only (0600), refusing to replace one.
    public func write(to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw errno == EEXIST ? XipperError.alreadyExists(path: url.path) : XipperError.posix("create", url.path) }
        defer { close(fd) }
        let line = Array((text + "\n").utf8)
        guard Darwin.write(fd, line, line.count) == line.count, fsync(fd) == 0 else { throw XipperError.posix("write", url.path) }
    }

    /// The factor ids (hex) of the password-with-factor stanzas of an archive: what it needs.
    public static func required(by archive: URL) -> [String] {
        guard let fh = try? FileHandle(forReadingFrom: archive) else { return [] }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: Xiz.superblockSize), let sb = try? Xiz.Superblock.decode(Array(head)),
              sb.keysLength > 0, let block = try? fh.read(upToCount: Int(sb.keysLength)), block.count >= 10 else { return [] }
        let b = Array(block)
        var out: [String] = []
        var p = 6
        let count = Int(UInt16(b[4]) | UInt16(b[5]) << 8)
        for _ in 0..<count {
            guard p + 3 <= b.count else { break }
            let type = b[p], len = Int(UInt16(b[p + 1]) | UInt16(b[p + 2]) << 8)
            p += 3
            guard p + len <= b.count else { break }
            if type == 8, len >= 52 { out.append(b[(p + 44)..<(p + 52)].map { String(format: "%02x", $0) }.joined()) }
            p += len
        }
        return out
    }
}
