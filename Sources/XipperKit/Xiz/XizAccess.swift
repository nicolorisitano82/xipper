import CryptoKit
import Foundation
import Security

// XIZ 1.3 (docs/XIZ_SPEC.md §13): access groups, recipients, k-of-n threshold keys and signed
// segments. This file holds the public description of an access policy, the identities and
// credentials, Shamir secret sharing, the keys-block stanzas (types 2–5), the catalog directory
// and the segment signatures (Ed25519, optional RFC 3161 time-stamp).

// MARK: - Public API

/// Who can open which part of an XIZ archive.
public struct XizAccess: Sendable {
    /// Groups besides group 0 ("everything else"): a name and the folders it holds.
    public var groups: [Group]
    public var recipients: [Recipient]
    public var thresholds: [Threshold]
    /// Every file gets its own key in an erasable key slot (§13.7): `Xipper.xizErase` can later
    /// make it unreadable. Files are then stored one per frame and deduplicated only within themselves.
    public var erasable: Bool

    public init(groups: [Group] = [], recipients: [Recipient] = [], thresholds: [Threshold] = [], erasable: Bool = false) {
        self.groups = groups
        self.recipients = recipients
        self.thresholds = thresholds
        self.erasable = erasable
    }

    public struct Group: Sendable, Equatable {
        public var name: String
        /// Folder paths inside the archive ("referti", "dati/grezzi").
        public var prefixes: [String]
        public init(name: String, prefixes: [String]) { self.name = name; self.prefixes = prefixes }
    }

    /// A password or an X25519 public key.
    public enum Credential: Sendable, Equatable {
        case password(String)
        case publicKey([UInt8])
    }

    public struct Recipient: Sendable {
        public var label: String
        public var credential: Credential
        /// Names of the groups it opens ("" is group 0); nil: all of them.
        public var groups: [String]?
        public init(label: String, credential: Credential, groups: [String]? = nil) {
            self.label = label
            self.credential = credential
            self.groups = groups
        }
    }

    /// The groups open only when `k` of the custodians unlock together.
    public struct Threshold: Sendable {
        public var label: String
        public var k: Int
        public var custodians: [Recipient]
        public var groups: [String]?
        public init(label: String, k: Int, custodians: [Recipient], groups: [String]? = nil) {
            self.label = label
            self.k = k
            self.custodians = custodians
            self.groups = groups
        }
    }

    /// The name of group 0 in policies.
    public static let defaultGroup = ""
}

/// An X25519 key pair to receive XIZ archives (`xizpk1…` public, `XIZ-SECRET-KEY-1-…` secret).
public struct XizIdentity: Sendable {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey
    public var publicKey: [UInt8] { Array(privateKey.publicKey.rawRepresentation) }
    public var publicText: String { Self.publicPrefix + Base64URL.encode(publicKey) }
    public var secretText: String { Self.secretPrefix + Base64URL.encode(Array(privateKey.rawRepresentation)) }

    static let publicPrefix = "xizpk1", secretPrefix = "XIZ-SECRET-KEY-1-"

    public init() { privateKey = Curve25519.KeyAgreement.PrivateKey() }
    public init(secretText: String) throws {
        guard let line = Self.keyLine(secretText, prefix: Self.secretPrefix),
              let raw = Base64URL.decode(String(line.dropFirst(Self.secretPrefix.count))), raw.count == 32 else {
            throw XipperError.invalidArgument("not an XIZ secret key")
        }
        privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
    }

    public static func publicKey(fromText text: String) throws -> [UInt8] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix(publicPrefix), let raw = Base64URL.decode(String(t.dropFirst(publicPrefix.count))), raw.count == 32 else {
            throw XipperError.invalidArgument("not an XIZ public key: \(t)")
        }
        return raw
    }

    /// The first line starting with `prefix` (key files carry comments).
    static func keyLine(_ text: String, prefix: String) -> Substring? {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(prefix) }.map { Substring($0) }
    }

    /// Key file contents: comments with the public key, then the secret.
    public var fileText: String {
        "# XIZ identity (X25519), created \(ISO8601DateFormatter().string(from: Date()))\n# public key: \(publicText)\n\(secretText)\n"
    }
}

/// An Ed25519 key to sign XIZ segments (`xizsig1…` public, `XIZ-SIGNING-KEY-1-…` secret).
public struct XizSigningKey: Sendable {
    public let privateKey: Curve25519.Signing.PrivateKey
    public var publicKey: [UInt8] { Array(privateKey.publicKey.rawRepresentation) }
    public var publicText: String { Self.publicPrefix + Base64URL.encode(publicKey) }
    public var secretText: String { Self.secretPrefix + Base64URL.encode(Array(privateKey.rawRepresentation)) }

    static let publicPrefix = "xizsig1", secretPrefix = "XIZ-SIGNING-KEY-1-"

    public init() { privateKey = Curve25519.Signing.PrivateKey() }
    public init(secretText: String) throws {
        guard let line = XizIdentity.keyLine(secretText, prefix: Self.secretPrefix),
              let raw = Base64URL.decode(String(line.dropFirst(Self.secretPrefix.count))), raw.count == 32 else {
            throw XipperError.invalidArgument("not an XIZ signing key")
        }
        privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    }

    public static func publicText(_ key: [UInt8]) -> String { publicPrefix + Base64URL.encode(key) }

    public var fileText: String {
        "# XIZ signing key (Ed25519), created \(ISO8601DateFormatter().string(from: Date()))\n# public key: \(publicText)\n\(secretText)\n"
    }
}

/// Who signs the segments an archive gains, and the RFC 3161 authority to time-stamp them (none:
/// Xipper makes no network connection).
public struct XizSigner: Sendable {
    public var key: XizSigningKey
    public var label: String
    public var timestampURL: URL?
    public init(key: XizSigningKey, label: String, timestampURL: URL? = nil) {
        self.key = key
        self.label = label
        self.timestampURL = timestampURL
    }
}

/// Credentials tried when opening XIZ 1.3 archives, besides the password passed to each call:
/// identities (X25519 secret keys) and more passwords (custodians of a threshold group).
public final class XizCredentials: @unchecked Sendable {
    public static let shared = XizCredentials()
    private let lock = NSLock()
    private var _identities: [XizIdentity] = []
    private var _passwords: [String] = []

    public func add(identity: XizIdentity) { lock.withLock { _identities.append(identity) } }
    public func add(password: String) { lock.withLock { _passwords.append(password) } }
    public func removeAll() { lock.withLock { _identities = []; _passwords = [] } }
    var identities: [XizIdentity] { lock.withLock { _identities } }
    var passwords: [String] { lock.withLock { _passwords } }
}

/// One segment's signature, as `Xipper.xizHistory` reports it.
public struct XizSegmentSignature: Sendable {
    public var segment: Int
    public var signed: Bool
    public var label: String
    public var publicKey: [UInt8]
    public var time: Date?
    /// The signature checks against the segment's content.
    public var valid: Bool
    /// The chain to the previous segment's signature holds (true for the first segment).
    public var chained: Bool
    public var timestamp: XizTimestamp?
    public var publicKeyText: String { publicKey.isEmpty ? "" : XizSigningKey.publicText(publicKey) }
}

public struct XizTimestamp: Sendable {
    public var time: Date
    /// The authority's certificate subject.
    public var authority: String
    /// The token's CMS signature verifies and its imprint is this signature's hash.
    public var valid: Bool
    /// The authority's certificate chains to a trusted root of this Mac.
    public var trusted: Bool
}

enum Base64URL {
    static func encode(_ b: [UInt8]) -> String {
        Data(b).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ s: String) -> [UInt8]? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t).map { Array($0) }
    }
}

// MARK: - Shamir secret sharing over GF(2^8)

enum Shamir {
    private static let tables: (exp: [UInt8], log: [UInt8]) = {
        var exp = [UInt8](repeating: 0, count: 512), log = [UInt8](repeating: 0, count: 256)
        var x: UInt8 = 1
        for i in 0..<255 {
            exp[i] = x
            log[Int(x)] = UInt8(i)
            // x *= 3 in GF(2^8) with x^8 + x^4 + x^3 + x + 1
            let hi = x & 0x80
            var d = x << 1
            if hi != 0 { d ^= 0x1B }
            x = d ^ x
        }
        for i in 255..<512 { exp[i] = exp[i - 255] }
        return (exp, log)
    }()

    static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        if a == 0 || b == 0 { return 0 }
        return tables.exp[Int(tables.log[Int(a)]) + Int(tables.log[Int(b)])]
    }

    static func div(_ a: UInt8, _ b: UInt8) -> UInt8 {
        precondition(b != 0)
        if a == 0 { return 0 }
        return tables.exp[(Int(tables.log[Int(a)]) + 255 - Int(tables.log[Int(b)])) % 255]
    }

    /// Shares x = 1…n of `secret`, any `k` of which rebuild it.
    static func split(_ secret: [UInt8], k: Int, n: Int) -> [[UInt8]] {
        precondition(k >= 2 && k <= n && n <= 255)
        var shares = [[UInt8]](repeating: [UInt8](repeating: 0, count: secret.count), count: n)
        var coeffs = [UInt8](repeating: 0, count: k - 1)
        for (j, s) in secret.enumerated() {
            arc4random_buf(&coeffs, coeffs.count)
            for x in 1...n {
                // Horner: s + c1·x + c2·x² + …
                var y: UInt8 = 0
                for c in coeffs.reversed() { y = mul(y, UInt8(x)) ^ c }
                y = mul(y, UInt8(x)) ^ s
                shares[x - 1][j] = y
            }
        }
        coeffs.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
        return shares
    }

    /// The secret from shares (x, y): Lagrange interpolation at 0.
    static func combine(_ shares: [(x: UInt8, y: [UInt8])]) -> [UInt8] {
        let len = shares[0].y.count
        var out = [UInt8](repeating: 0, count: len)
        for (i, si) in shares.enumerated() {
            var basis: UInt8 = 1
            for (j, sj) in shares.enumerated() where j != i {
                basis = mul(basis, div(sj.x, sj.x ^ si.x))
            }
            for b in 0..<len { out[b] ^= mul(si.y[b], basis) }
        }
        return out
    }
}

// MARK: - Keys block (1.3)

enum XizAccessKeys {
    enum StanzaType: UInt8 { case passwordRecipient = 2, keyRecipient = 3, threshold = 4, share = 5 }

    static func bundle(_ keys: [(UInt16, SymmetricKey)]) -> [UInt8] {
        var w = ByteWriter(capacity: 2 + keys.count * 34)
        w.u16(UInt16(keys.count))
        for (g, k) in keys { w.u16(g); k.withUnsafeBytes { w.append(Array($0)) } }
        return w.bytes
    }

    static func unbundle(_ b: [UInt8]) throws -> [UInt16: SymmetricKey] {
        try b.withUnsafeBytes { raw in
            var r = ByteReader(raw)
            var out: [UInt16: SymmetricKey] = [:]
            for _ in 0..<Int(try r.u16()) {
                let g = try r.u16()
                out[g] = SymmetricKey(data: Array(try r.bytes(32)))
            }
            guard r.remaining == 0 else { throw XipperError.corrupt("XIZ key bundle") }
            return out
        }
    }

    static func label(_ s: String) -> [UInt8] {
        var b = Array(s.utf8.prefix(255))
        while String(bytes: b, encoding: .utf8) == nil { b.removeLast() }  // never cut a character
        return [UInt8(b.count)] + b
    }

    /// A stanza waiting for the superblock its AAD covers: header and KEK are ready.
    struct Pending {
        var type: StanzaType
        var header: [UInt8]
        var kek: SymmetricKey
        var plaintext: [UInt8]
        var size: Int { 1 + 2 + header.count + 12 + plaintext.count + 16 }
    }

    static func keyID(_ publicKey: [UInt8]) -> [UInt8] { Array(Array(SHA256.hash(data: publicKey)).prefix(8)) }

    /// KEK and header fields for a password (Argon2id) or a public key (X25519 to an ephemeral key).
    static func credentialKEK(_ c: XizAccess.Credential, kdf: XizKeys.KDF) throws -> (header: [UInt8], kek: SymmetricKey) {
        switch c {
        case let .password(p):
            var salt = [UInt8](repeating: 0, count: 32)
            arc4random_buf(&salt, 32)
            var w = ByteWriter(capacity: 44)
            w.u32(kdf.memoryKiB); w.u32(kdf.iterations); w.u32(kdf.parallelism); w.append(salt)
            return (w.bytes, try XizKeys.argon2id(p, salt: salt, kdf))
        case let .publicKey(pub):
            let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pub)
            let eph = Curve25519.KeyAgreement.PrivateKey()
            let ephPub = Array(eph.publicKey.rawRepresentation)
            let kek = try x25519KEK(shared: try eph.sharedSecretFromKeyAgreement(with: recipient), ephemeral: ephPub, recipient: pub)
            return (ephPub + keyID(pub), kek)
        }
    }

    static func x25519KEK(shared: SharedSecret, ephemeral: [UInt8], recipient: [UInt8]) throws -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(ephemeral + recipient),
                                       sharedInfo: Data("xiz/1.3/x25519".utf8), outputByteCount: 32)
    }

    static func thresholdKEK(_ secret: [UInt8], archiveID: [UInt8]) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data(archiveID),
                               info: Data("xiz/1.3/threshold".utf8), outputByteCount: 32)
    }

    /// The stanzas of a policy: recipients and thresholds, each with the keys of its groups.
    static func prepare(_ access: XizAccess, groupIDs: [String: UInt16], groupKeys: [UInt16: SymmetricKey],
                        archiveID: [UInt8], kdf: XizKeys.KDF) throws -> [Pending] {
        func keys(_ names: [String]?) throws -> [(UInt16, SymmetricKey)] {
            let ids = try (names ?? Array(groupIDs.keys)).map { n -> UInt16 in
                guard let id = groupIDs[n] else { throw XipperError.invalidArgument("unknown access group \"\(n)\"") }
                return id
            }
            return Set(ids).sorted().map { ($0, groupKeys[$0]!) }
        }
        var out: [Pending] = []
        for r in access.recipients {
            let (header, kek) = try credentialKEK(r.credential, kdf: kdf)
            let type: StanzaType = if case .password = r.credential { .passwordRecipient } else { .keyRecipient }
            out.append(Pending(type: type, header: header + label(r.label), kek: kek, plaintext: bundle(try keys(r.groups))))
        }
        for (tid, t) in access.thresholds.enumerated() {
            let n = t.custodians.count
            guard t.k >= 2, t.k <= n, n <= 255, tid < 256 else {
                throw XipperError.invalidArgument("threshold \"\(t.label)\": need 2 ≤ k ≤ custodians ≤ 255")
            }
            var secret = [UInt8](repeating: 0, count: 32)
            arc4random_buf(&secret, 32)
            out.append(Pending(type: .threshold, header: [UInt8(tid), UInt8(t.k), UInt8(n)] + label(t.label),
                               kek: thresholdKEK(secret, archiveID: archiveID), plaintext: bundle(try keys(t.groups))))
            for (i, (c, share)) in zip(t.custodians, Shamir.split(secret, k: t.k, n: n)).enumerated() {
                let (header, kek) = try credentialKEK(c.credential, kdf: kdf)
                let kind: UInt8 = if case .password = c.credential { 1 } else { 2 }
                out.append(Pending(type: .share, header: [UInt8(tid), UInt8(i + 1), kind] + header + label(c.label), kek: kek, plaintext: share))
            }
            secret.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
        }
        guard !out.isEmpty else { throw XipperError.invalidArgument("an access policy needs at least one recipient") }
        return out
    }

    static func size(_ stanzas: [Pending]) -> Int { 4 + 2 + stanzas.reduce(0) { $0 + $1.size } + 4 }

    static func seal(_ stanzas: [Pending], superblock: [UInt8]) throws -> [UInt8] {
        var w = ByteWriter(capacity: size(stanzas))
        w.append(Xiz.keysMagic); w.u16(UInt16(stanzas.count))
        for s in stanzas {
            let aad = Array(superblock[0..<60]) + [s.type.rawValue] + s.header
            let box = try AES.GCM.seal(s.plaintext, using: s.kek, authenticating: Data(aad))
            let body = s.header + Array(box.nonce) + Array(box.ciphertext) + Array(box.tag)
            w.u8(s.type.rawValue); w.u16(UInt16(body.count)); w.append(body)
        }
        w.u32(Xiz.crc32c(w.bytes))
        return w.bytes
    }

    struct Opened {
        var groupKeys: [UInt16: SymmetricKey] = [:]
        /// Stanzas seen (to tell "no credential fits" from "nothing to open").
        var stanzas = 0
        /// Thresholds: label, k, how many shares were opened.
        var thresholds: [(label: String, k: Int, opened: Int)] = []
    }

    /// Opens every stanza the credentials fit and unions the group keys.
    static func open(_ b: [UInt8], superblock: [UInt8], passwords: [String], identities: [XizIdentity]) throws -> Opened {
        guard b.count >= 10, b.starts(with: Xiz.keysMagic) else { throw XipperError.corrupt("XIZ keys block") }
        let crc = b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: b.count - 4, as: UInt32.self).littleEndian }
        guard crc == Xiz.crc32c(Array(b[..<(b.count - 4)])) else { throw XipperError.corrupt("XIZ keys block checksum mismatch") }
        var stanzas: [(UInt8, [UInt8])] = []
        try b.withUnsafeBytes { raw in
            var r = ByteReader(UnsafeRawBufferPointer(rebasing: raw[..<(raw.count - 4)]), at: 4)
            for _ in 0..<Int(try r.u16()) {
                let type = try r.u8(), len = Int(try r.u16())
                stanzas.append((type, Array(try r.bytes(len))))
            }
            guard r.remaining == 0 else { throw XipperError.corrupt("XIZ keys block") }
        }
        let prefix = Array(superblock[0..<60])
        var result = Opened()
        var argonCache: [[UInt8]: [String: SymmetricKey]] = [:]  // KDF header → password → KEK

        /// Header length of a credential: 44 (password) or 40 (public key); kind 1 or 2.
        func credentialKEKs(_ kind: UInt8, _ body: [UInt8], at p: Int) throws -> (Int, [SymmetricKey]) {
            if kind == 1 {
                guard body.count >= p + 44 else { throw XipperError.corrupt("XIZ stanza") }
                let h = Array(body[p..<(p + 44)])
                let kdf = h.withUnsafeBytes { q in
                    XizKeys.KDF(memoryKiB: q.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian,
                                iterations: q.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian,
                                parallelism: q.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian)
                }
                guard kdf.isAcceptable else { throw XipperError.limitExceeded("XIZ key derivation parameters") }
                var keks: [SymmetricKey] = []
                for pw in passwords {
                    if let k = argonCache[h]?[pw] { keks.append(k); continue }
                    let k = try XizKeys.argon2id(pw, salt: Array(h[12..<44]), kdf)
                    argonCache[h, default: [:]][pw] = k
                    keks.append(k)
                }
                return (44, keks)
            }
            guard kind == 2, body.count >= p + 40 else { throw XipperError.corrupt("XIZ stanza") }
            let eph = Array(body[p..<(p + 32)]), id = Array(body[(p + 32)..<(p + 40)])
            var keks: [SymmetricKey] = []
            for idn in identities where keyID(idn.publicKey) == id {
                let shared = try idn.privateKey.sharedSecretFromKeyAgreement(with: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: eph))
                keks.append(try x25519KEK(shared: shared, ephemeral: eph, recipient: idn.publicKey))
            }
            return (40, keks)
        }

        func openBox(_ type: UInt8, _ body: [UInt8], headerEnd: Int, keks: [SymmetricKey]) -> [UInt8]? {
            guard body.count >= headerEnd + 28 else { return nil }
            let aad = prefix + [type] + Array(body[..<headerEnd])
            for kek in keks {
                if let box = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: body[headerEnd..<(headerEnd + 12)]),
                                                    ciphertext: body[(headerEnd + 12)..<(body.count - 16)], tag: body[(body.count - 16)...]),
                   let plain = try? AES.GCM.open(box, using: kek, authenticating: Data(aad)) {
                    return Array(plain)
                }
            }
            return nil
        }

        func labelEnd(_ body: [UInt8], at p: Int) throws -> Int {
            guard p < body.count, p + 1 + Int(body[p]) <= body.count else { throw XipperError.corrupt("XIZ stanza label") }
            return p + 1 + Int(body[p])
        }

        var shares: [UInt8: [(x: UInt8, y: [UInt8])]] = [:]
        var thresholdStanzas: [(id: UInt8, k: Int, label: String, body: [UInt8], headerEnd: Int)] = []
        for (type, body) in stanzas {
            guard let t = StanzaType(rawValue: type) else { continue }  // unknown types are skipped (§6.2)
            result.stanzas += 1
            switch t {
            case .passwordRecipient, .keyRecipient:
                let (n, keks) = try credentialKEKs(t == .passwordRecipient ? 1 : 2, body, at: 0)
                let end = try labelEnd(body, at: n)
                if let plain = openBox(type, body, headerEnd: end, keks: keks) {
                    result.groupKeys.merge(try unbundle(plain)) { a, _ in a }
                }
            case .threshold:
                guard body.count >= 3 else { throw XipperError.corrupt("XIZ threshold stanza") }
                let end = try labelEnd(body, at: 3)
                thresholdStanzas.append((body[0], Int(body[1]), String(decoding: body[4..<end], as: UTF8.self), body, end))
            case .share:
                guard body.count >= 3 else { throw XipperError.corrupt("XIZ share stanza") }
                let (n, keks) = try credentialKEKs(body[2], body, at: 3)
                let end = try labelEnd(body, at: 3 + n)
                if let y = openBox(type, body, headerEnd: end, keks: keks), y.count == 32, body[1] != 0,
                   !(shares[body[0]] ?? []).contains(where: { $0.x == body[1] }) {
                    shares[body[0], default: []].append((body[1], y))
                }
            }
        }
        for t in thresholdStanzas {
            let got = shares[t.id] ?? []
            result.thresholds.append((t.label, t.k, got.count))
            guard got.count >= t.k, t.k >= 2 else { continue }
            let secret = Shamir.combine(Array(got.prefix(t.k)))
            let kek = thresholdKEK(secret, archiveID: Array(superblock[16..<32]))
            if let plain = openBox(StanzaType.threshold.rawValue, t.body, headerEnd: t.headerEnd, keks: [kek]) {
                result.groupKeys.merge(try unbundle(plain)) { a, _ in a }
            }
        }
        return result
    }
}

// MARK: - Directory (1.3)

struct XizDirectory {
    struct GroupCatalog: Equatable {
        var group: UInt16
        var segment: UInt32
        var offset: Int64
        var csize: Int64
        var usize: Int64
        var sha256: [UInt8]
    }

    struct SlotTable: Equatable {
        var segment: UInt32
        var offset: Int64
        var count: UInt32
    }

    static let magic: [UInt8] = Array("XDIR".utf8)
    static let erasableFlag: UInt16 = 1
    var version: UInt16 = 2
    /// Version 2: bit 0, erasable (files added later get key slots too).
    var flags: UInt16 = 0
    var groups: [GroupCatalog]
    /// Version 2: every key slot table of the archive (§13.7).
    var slotTables: [SlotTable] = []
    /// Version 2: the leaf table and the Merkle root (§13.6).
    var leafOffset: Int64 = 0
    var leafCount: UInt32 = 0
    var merkleRoot = [UInt8](repeating: 0, count: 32)
    var signature: [UInt8] = []

    /// Everything before `signature_length`: what a segment signature covers.
    var signedPart: [UInt8] {
        var w = ByteWriter(capacity: 64 + groups.count * 62 + slotTables.count * 16)
        w.append(Self.magic); w.u16(version)
        if version >= 2 { w.u16(flags) }
        w.u16(UInt16(groups.count))
        for g in groups {
            w.u16(g.group); w.u32(g.segment); w.u64(UInt64(g.offset)); w.u64(UInt64(g.csize)); w.u64(UInt64(g.usize)); w.append(g.sha256)
        }
        if version >= 2 {
            w.u16(UInt16(slotTables.count))
            for t in slotTables { w.u32(t.segment); w.u64(UInt64(t.offset)); w.u32(t.count) }
            w.u64(UInt64(leafOffset)); w.u32(leafCount); w.append(merkleRoot)
        }
        return w.bytes
    }

    func encode() -> [UInt8] {
        var w = ByteWriter(capacity: 16 + groups.count * 62 + signature.count)
        w.append(signedPart); w.u32(UInt32(signature.count)); w.append(signature)
        w.u32(Xiz.crc32c(w.bytes))
        return w.bytes
    }

    static func decode(_ b: [UInt8]) throws -> XizDirectory {
        guard b.count >= 16, b.starts(with: magic) else { throw XipperError.corrupt("XIZ directory") }
        let crc = b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: b.count - 4, as: UInt32.self).littleEndian }
        guard crc == Xiz.crc32c(Array(b[..<(b.count - 4)])) else { throw XipperError.corrupt("XIZ directory checksum mismatch") }
        return try b.withUnsafeBytes { raw in
            var r = ByteReader(UnsafeRawBufferPointer(rebasing: raw[..<(raw.count - 4)]), at: 4)
            let version = try r.u16()
            guard version == 1 || version == 2 else { throw XipperError.unsupported("XIZ directory version") }
            let flags = version >= 2 ? try r.u16() : 0
            guard flags & ~Self.erasableFlag == 0 else { throw XipperError.unsupported("XIZ directory flags \(flags)") }
            let n = Int(try r.u16())
            guard n >= 1 else { throw XipperError.corrupt("XIZ directory without groups") }
            var d = XizDirectory(version: version, flags: flags, groups: [])
            for _ in 0..<n {
                let g = GroupCatalog(group: try r.u16(), segment: try r.u32(), offset: Int64(bitPattern: try r.u64()),
                                     csize: Int64(bitPattern: try r.u64()), usize: Int64(bitPattern: try r.u64()), sha256: Array(try r.bytes(32)))
                if let last = d.groups.last, last.group >= g.group { throw XipperError.corrupt("XIZ directory groups out of order") }
                d.groups.append(g)
            }
            guard d.groups[0].group == 0 else { throw XipperError.corrupt("XIZ directory without group 0") }
            if version >= 2 {
                for _ in 0..<Int(try r.u16()) {
                    let t = SlotTable(segment: try r.u32(), offset: Int64(bitPattern: try r.u64()), count: try r.u32())
                    if let last = d.slotTables.last, last.segment >= t.segment { throw XipperError.corrupt("XIZ slot tables out of order") }
                    d.slotTables.append(t)
                }
                d.leafOffset = Int64(bitPattern: try r.u64()); d.leafCount = try r.u32(); d.merkleRoot = Array(try r.bytes(32))
            }
            let sl = Int(try r.u32())
            d.signature = Array(try r.bytes(sl))
            guard r.remaining == 0 else { throw XipperError.corrupt("XIZ directory trailing data") }
            return d
        }
    }
}

/// Group catalogs (§13.2): associated data of the sealed catalog.
extension XizKeys {
    static func groupCatalogAAD(archiveID: [UInt8], group: UInt16, segment: UInt32, usize: Int64, frameCount: UInt32) -> Data {
        var w = ByteWriter(capacity: 48)
        w.append(Array("XIZ13catalog".utf8)); w.append(archiveID); w.u16(group); w.u32(segment); w.u64(UInt64(usize)); w.u32(frameCount)
        return Data(w.bytes)
    }
}

/// Which group an entry belongs to: the longest prefix equal to its path or to a leading run of its components.
struct XizGroupMap {
    /// (id, name, prefixes); group 0 first, with no prefixes.
    var groups: [(id: UInt16, name: String, prefixes: [String])]

    init(_ access: XizAccess?) throws {
        groups = [(0, XizAccess.defaultGroup, [])]
        var names: Set<String> = [XizAccess.defaultGroup]
        for (i, g) in (access?.groups ?? []).enumerated() {
            guard !g.name.isEmpty, names.insert(g.name).inserted else { throw XipperError.invalidArgument("duplicate or empty group name \"\(g.name)\"") }
            let prefixes = g.prefixes.compactMap { MountedArchive.normalize($0) }
            guard !prefixes.isEmpty else { throw XipperError.invalidArgument("group \"\(g.name)\" has no folders") }
            groups.append((UInt16(i + 1), g.name, prefixes))
        }
    }

    /// The groups an archive already has (id, name, folders).
    init(groups: [(id: UInt16, name: String, prefixes: [String])]) { self.groups = groups }

    var ids: [String: UInt16] { Dictionary(uniqueKeysWithValues: groups.map { ($0.name, $0.id) }) }

    func group(of path: String) -> UInt16 {
        var best: (UInt16, Int) = (0, -1)
        for g in groups {
            for p in g.prefixes where (path == p || path.hasPrefix(p + "/")) && p.count > best.1 { best = (g.id, p.count) }
        }
        return best.0
    }
}

// MARK: - Segment signatures (§13.5)

enum XizSignature {
    struct Record {
        var publicKey: [UInt8]
        var label: String
        var time: Int64
        var previous: [UInt8]
        var signature: [UInt8]
        var token: [UInt8]

        func encode() -> [UInt8] {
            var w = ByteWriter(capacity: 180 + token.count)
            w.u8(1); w.append(publicKey); w.append(XizAccessKeys.label(label)); w.u64(UInt64(bitPattern: time))
            w.append(previous); w.append(signature); w.u32(UInt32(token.count)); w.append(token)
            return w.bytes
        }

        static func decode(_ b: [UInt8]) throws -> Record {
            try b.withUnsafeBytes { raw in
                var r = ByteReader(raw)
                guard try r.u8() == 1 else { throw XipperError.unsupported("XIZ signature algorithm") }
                let pk = Array(try r.bytes(32))
                let label = String(decoding: try r.bytes(Int(try r.u8())), as: UTF8.self)
                let time = Int64(bitPattern: try r.u64())
                let prev = Array(try r.bytes(32)), sig = Array(try r.bytes(64))
                let token = Array(try r.bytes(Int(try r.u32())))
                guard r.remaining == 0 else { throw XipperError.corrupt("XIZ signature trailing data") }
                return Record(publicKey: pk, label: label, time: time, previous: prev, signature: sig, token: token)
            }
        }
    }

    static func message(archiveID: [UInt8], segment: UInt32, directory: XizDirectory, previousFooter: UInt64, _ r: Record) -> [UInt8] {
        var w = ByteWriter(capacity: 256)
        w.append(Array("XIZ13sign".utf8)); w.append(archiveID); w.u32(segment)
        w.append(Xiz.sha256(directory.signedPart)); w.u64(previousFooter); w.u64(UInt64(bitPattern: r.time))
        w.append(r.previous); w.u8(1); w.append(r.publicKey); w.append(XizAccessKeys.label(r.label))
        return w.bytes
    }

    static func chainDigest(_ message: [UInt8], _ signature: [UInt8]) -> [UInt8] { Xiz.sha256(message + signature) }

    /// What the next segment's signature chains to: the chained digest of this segment's
    /// signature, zeros when it is unsigned.
    static func chainDigest(archiveID: [UInt8], segment: UInt32, directory: XizDirectory, previousFooter: UInt64) -> [UInt8] {
        guard !directory.signature.isEmpty, let r = try? Record.decode(directory.signature) else { return [UInt8](repeating: 0, count: 32) }
        return chainDigest(message(archiveID: archiveID, segment: segment, directory: directory, previousFooter: previousFooter, r), r.signature)
    }

    /// Every segment's signature, oldest first, checked: content, chain, time-stamp. Needs no key
    /// to the content (signatures cover the sealed catalogs).
    static func history(_ path: String) throws -> [XizSegmentSignature] {
        let reader = try FileReader(path: path)
        let sbBytes = try reader.read(at: 0, count: Xiz.superblockSize)
        let sb = try Xiz.Superblock.decode(sbBytes)
        guard sb.required.contains(.directory) else { return [] }
        let dataStart = Int64(Xiz.superblockSize) + Int64(sb.keysLength)
        var chain: [(Xiz.Footer, XizDirectory)] = []
        // The last complete footer (an interrupted append leaves bytes after it).
        var at = try XizArchive.lastFooter(reader, dataStart: dataStart).0
        while true {
            let f = try Xiz.Footer.decode(try reader.read(at: at, count: Xiz.footerSize))
            guard f.catalogOffset >= dataStart, f.catalogOffset + f.catalogCSize == at, f.catalogCSize <= Int64(Xiz.maxCatalog) else {
                throw XipperError.corrupt("XIZ segment chain")
            }
            let bytes = try reader.read(at: f.catalogOffset, count: Int(f.catalogCSize))
            guard Xiz.sha256(bytes) == f.catalogSHA256 else { throw XipperError.corrupt("XIZ directory hash mismatch") }
            chain.append((f, try XizDirectory.decode(bytes)))
            guard f.previousFooter != 0, chain.count < 65536 else { break }
            guard Int64(f.previousFooter) < f.catalogOffset else { throw XipperError.corrupt("XIZ segment chain") }
            at = Int64(f.previousFooter)
        }
        chain.reverse()
        var out: [XizSegmentSignature] = []
        var previous = [UInt8](repeating: 0, count: 32)
        for (i, (f, d)) in chain.enumerated() {
            guard !d.signature.isEmpty, let r = try? Record.decode(d.signature) else {
                out.append(XizSegmentSignature(segment: i, signed: false, label: "", publicKey: [], time: nil, valid: false,
                                               chained: false, timestamp: nil))
                previous = [UInt8](repeating: 0, count: 32)
                continue
            }
            let m = message(archiveID: sb.archiveID, segment: UInt32(i), directory: d, previousFooter: f.previousFooter, r)
            let valid = (try? Curve25519.Signing.PublicKey(rawRepresentation: r.publicKey))?.isValidSignature(r.signature, for: m) ?? false
            let ts = r.token.isEmpty ? nil : try? RFC3161.verify(r.token, imprint: Xiz.sha256(r.signature))
            out.append(XizSegmentSignature(segment: i, signed: true, label: r.label, publicKey: r.publicKey,
                                           time: Date(timeIntervalSince1970: Double(r.time)), valid: valid, chained: r.previous == previous,
                                           timestamp: ts))
            previous = chainDigest(m, r.signature)
        }
        return out
    }

    /// Signs a segment's directory; time-stamps when the signer names an authority.
    static func sign(_ signer: XizSigner, archiveID: [UInt8], segment: UInt32, directory: XizDirectory, previousFooter: UInt64,
                     previous: [UInt8]) throws -> Record {
        var r = Record(publicKey: signer.key.publicKey, label: signer.label, time: Int64(Date().timeIntervalSince1970),
                       previous: previous, signature: [], token: [])
        let m = message(archiveID: archiveID, segment: segment, directory: directory, previousFooter: previousFooter, r)
        r.signature = Array(try signer.key.privateKey.signature(for: m))
        if let url = signer.timestampURL { r.token = try RFC3161.request(url, imprint: Xiz.sha256(r.signature)) }
        return r
    }
}

// MARK: - RFC 3161 time-stamps

enum RFC3161 {
    /// TimeStampReq for a SHA-256 imprint (with a nonce and certReq), DER.
    static func requestDER(imprint: [UInt8], nonce: [UInt8]) -> [UInt8] {
        let sha256 = DER.seq(DER.oid([2, 16, 840, 1, 101, 3, 4, 2, 1]) + [0x05, 0x00])
        let messageImprint = DER.seq(sha256 + DER.tlv(0x04, imprint))
        return DER.seq(DER.integer([1]) + messageImprint + DER.integer(nonce) + [0x01, 0x01, 0xFF])
    }

    /// Asks `url` to time-stamp `imprint`; returns the TimeStampToken (DER).
    static func request(_ url: URL, imprint: [UInt8]) throws -> [UInt8] {
        var nonce = [UInt8](repeating: 0, count: 8)
        arc4random_buf(&nonce, 8)
        nonce[0] &= 0x7F
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/timestamp-query", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(requestDER(imprint: imprint, nonce: nonce))
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<Data, Error> = .failure(XipperError.io("time-stamp request", path: url.absoluteString, errno: ETIMEDOUT))
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error { result = .failure(error) }
            else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(XipperError.io("time-stamp authority answered HTTP \(http.statusCode)", path: url.absoluteString, errno: EPROTO))
            } else { result = .success(data ?? Data()) }
            done.signal()
        }.resume()
        done.wait()
        let token = try tokenFromResponse(Array(try result.get()))
        guard let info = try? verify(token, imprint: imprint), info.valid else {
            throw XipperError.integrity(entry: "time-stamp", detail: "the authority's answer does not verify")
        }
        return token
    }

    /// The TimeStampToken out of a TimeStampResp, after checking its status (granted).
    static func tokenFromResponse(_ der: [UInt8]) throws -> [UInt8] {
        let resp = try DER.children(of: try DER.element(der, at: 0))
        guard resp.count >= 2 else { throw XipperError.integrity(entry: "time-stamp", detail: "no token in the answer") }
        let status = try DER.children(of: resp[0])
        guard let s = status.first, s.tag == 0x02, let v = s.content.last, s.content.count == 1, v <= 1 else {
            throw XipperError.integrity(entry: "time-stamp", detail: "request refused by the authority")
        }
        return resp[1].raw
    }

    /// Verifies a token: CMS signature, imprint, time; whether the authority chains to a trusted root.
    /// The CMS SignedData is checked here (Apple's CMSDecoder does not take a TSTInfo as attached
    /// content): the content's digest must equal the signed `messageDigest` attribute, and the
    /// signature over the signed attributes must verify with the signer certificate's key.
    static func verify(_ token: [UInt8], imprint: [UInt8]) throws -> XizTimestamp {
        func fail(_ m: String) -> XipperError { .integrity(entry: "time-stamp", detail: m) }
        let contentInfo = try DER.children(of: try DER.element(token, at: 0))
        guard contentInfo.count == 2, contentInfo[1].tag == 0xA0 else { throw fail("not a CMS message") }
        let signedData = try DER.children(of: try DER.element(contentInfo[1].content, at: 0))
        guard signedData.count >= 4 else { throw fail("SignedData") }
        let encap = try DER.children(of: signedData[2])
        guard encap.count == 2, encap[1].tag == 0xA0 else { throw fail("no TSTInfo") }
        let eContent = try DER.element(encap[1].content, at: 0).content
        let certs = signedData.first { $0.tag == 0xA0 }.map { try? DER.children(of: $0) } ?? nil
        guard let signerInfos = signedData.last, signerInfos.tag == 0x31,
              let signer = try DER.children(of: signerInfos).first else { throw fail("unsigned") }
        let si = try DER.children(of: signer)
        guard si.count >= 6, let attrsIndex = si.firstIndex(where: { $0.tag == 0xA0 }), attrsIndex + 2 < si.count else {
            throw fail("signer without signed attributes")
        }
        let digestAlg = try DER.children(of: si[attrsIndex - 1]).first?.content ?? []
        let sigAlg = try DER.children(of: si[attrsIndex + 1]).first?.content ?? []
        let signature = si[attrsIndex + 2].content
        // messageDigest (1.2.840.113549.1.9.4) among the signed attributes.
        let messageDigestOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x04]
        var signedDigest: [UInt8]?
        for attr in try DER.children(of: si[attrsIndex]) {
            let parts = try DER.children(of: attr)
            if parts.count == 2, parts[0].content == messageDigestOID, let v = try DER.children(of: parts[1]).first { signedDigest = v.content }
        }
        let sha256OID: [UInt8] = [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01]
        let sha384OID: [UInt8] = [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02]
        let sha512OID: [UInt8] = [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03]
        let contentDigest: [UInt8]
        let algorithm: SecKeyAlgorithm
        let ecdsa = sigAlg.starts(with: [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03])  // ecdsa-with-SHA*
        switch digestAlg {
        case sha256OID: contentDigest = Array(SHA256.hash(data: eContent))
            algorithm = ecdsa ? .ecdsaSignatureMessageX962SHA256 : .rsaSignatureMessagePKCS1v15SHA256
        case sha384OID: contentDigest = Array(SHA384.hash(data: eContent))
            algorithm = ecdsa ? .ecdsaSignatureMessageX962SHA384 : .rsaSignatureMessagePKCS1v15SHA384
        case sha512OID: contentDigest = Array(SHA512.hash(data: eContent))
            algorithm = ecdsa ? .ecdsaSignatureMessageX962SHA512 : .rsaSignatureMessagePKCS1v15SHA512
        default: throw XipperError.unsupported("time-stamp digest algorithm")
        }
        // The signature covers the signed attributes as a DER SET (tag 0x31 instead of [0]).
        let signedBytes = [UInt8(0x31)] + Array(si[attrsIndex].raw.dropFirst())
        var certificate: SecCertificate?
        var signatureOK = false
        for c in certs ?? [] where c.tag == 0x30 {
            guard let cert = SecCertificateCreateWithData(nil, Data(c.raw) as CFData), let key = SecCertificateCopyKey(cert) else { continue }
            if SecKeyVerifySignature(key, algorithm, Data(signedBytes) as CFData, Data(signature) as CFData, nil) {
                certificate = cert
                signatureOK = true
                break
            }
        }
        let info = try DER.children(of: try DER.element(eContent, at: 0))
        guard info.count >= 5 else { throw fail("TSTInfo") }
        let mi = try DER.children(of: info[2])
        let hashed = mi.count == 2 ? mi[1].content : []
        let time = DER.generalizedTime(info[4].content) ?? Date(timeIntervalSince1970: 0)
        var authority = ""
        var trusted = false
        if let certificate {
            authority = (SecCertificateCopySubjectSummary(certificate) as String?) ?? ""
            var trust: SecTrust?
            if SecTrustCreateWithCertificates([certificate] as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust {
                trusted = SecTrustEvaluateWithError(trust, nil)
            }
        }
        return XizTimestamp(time: time, authority: authority,
                            valid: signatureOK && signedDigest == contentDigest && hashed == imprint, trusted: trusted)
    }
}

/// The few DER pieces RFC 3161 needs.
enum DER {
    struct Element {
        var tag: UInt8
        var content: [UInt8]
        var raw: [UInt8]
    }

    static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var b: [UInt8] = []
        var v = n
        while v > 0 { b.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return [0x80 | UInt8(b.count)] + b
    }

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + length(content.count) + content }
    static func seq(_ content: [UInt8]) -> [UInt8] { tlv(0x30, content) }

    static func integer(_ bytes: [UInt8]) -> [UInt8] {
        var b = Array(bytes.drop { $0 == 0 })
        if b.isEmpty { b = [0] }
        if b[0] & 0x80 != 0 { b.insert(0, at: 0) }
        return tlv(0x02, b)
    }

    static func oid(_ arcs: [UInt]) -> [UInt8] {
        var out: [UInt8] = [UInt8(arcs[0] * 40 + arcs[1])]
        for a in arcs.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(a & 0x7F)]
            var v = a >> 7
            while v > 0 { chunk.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
            out += chunk
        }
        return tlv(0x06, out)
    }

    static func element(_ b: [UInt8], at p: Int) throws -> Element {
        guard p + 2 <= b.count else { throw XipperError.corrupt("DER") }
        let tag = b[p]
        var i = p + 1
        var len = Int(b[i]); i += 1
        if len & 0x80 != 0 {
            let n = len & 0x7F
            guard n >= 1, n <= 4, i + n <= b.count else { throw XipperError.corrupt("DER length") }
            len = 0
            for _ in 0..<n { len = len << 8 | Int(b[i]); i += 1 }
        }
        guard i + len <= b.count else { throw XipperError.corrupt("DER truncated") }
        return Element(tag: tag, content: Array(b[i..<(i + len)]), raw: Array(b[p..<(i + len)]))
    }

    static func children(of e: Element) throws -> [Element] {
        var out: [Element] = []
        var p = 0
        while p < e.content.count {
            let c = try element(e.content, at: p)
            out.append(c)
            p += c.raw.count
        }
        return out
    }

    static func generalizedTime(_ b: [UInt8]) -> Date? {
        let s = String(decoding: b, as: UTF8.self)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyyMMddHHmmss'Z'", "yyyyMMddHHmmss.SSS'Z'", "yyyyMMddHHmmss.SS'Z'", "yyyyMMddHHmmss.S'Z'"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
