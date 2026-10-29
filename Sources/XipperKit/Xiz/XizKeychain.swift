import Foundation
import Security

/// XIZ identities (X25519) and signing keys (Ed25519) in the login Keychain, by name, so the app
/// and the CLI (`--identity keychain:NAME`, `--sign keychain:NAME`) share them and no secret sits
/// in a file. The public key is kept in the item's comment, so listing needs no unlock; reading a
/// secret may make macOS ask whether this program may use it (the app also asks for Touch ID).
public enum XizKeychain {
    public enum Kind: Sendable {
        case identity, signing
        var service: String { self == .identity ? "app.xipper.xiz-identity" : "app.xipper.xiz-signing" }
    }

    public struct Item: Sendable, Identifiable, Hashable {
        public var name: String
        public var publicKey: String
        public var created: Date?
        public var id: String { name }
    }

    private static func query(_ kind: Kind, name: String?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: kind.service]
        if let name { q[kSecAttrAccount as String] = name }
        return q
    }

    /// The keys of a kind, sorted by name (no unlock needed).
    public static func list(_ kind: Kind) -> [Item] {
        var q = query(kind, name: nil)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { a in
            guard let name = a[kSecAttrAccount as String] as? String else { return nil }
            return Item(name: name, publicKey: a[kSecAttrComment as String] as? String ?? "", created: a[kSecAttrCreationDate as String] as? Date)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Stores a secret key under `name` (replacing one with the same name).
    public static func save(_ kind: Kind, name: String, secretText: String, publicText: String) throws {
        guard !name.isEmpty else { throw XipperError.invalidArgument("a key needs a name") }
        SecItemDelete(query(kind, name: name) as CFDictionary)
        var add = query(kind, name: name)
        add[kSecValueData as String] = Data(secretText.utf8)
        add[kSecAttrComment as String] = publicText
        add[kSecAttrLabel as String] = "Xipper: \(name)"
        add[kSecAttrDescription as String] = kind == .identity ? "XIZ identity (X25519)" : "XIZ signing key (Ed25519)"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw XipperError.io("Keychain: save \(name)", path: nil, errno: Int32(truncatingIfNeeded: status)) }
    }

    /// The secret key text, nil if missing or not allowed.
    public static func secret(_ kind: Kind, name: String) -> String? {
        var q = query(kind, name: name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(_ kind: Kind, name: String) {
        SecItemDelete(query(kind, name: name) as CFDictionary)
    }

    /// A new identity or signing key, stored under `name`; returns its public key.
    @discardableResult
    public static func generate(_ kind: Kind, name: String) throws -> String {
        switch kind {
        case .identity:
            let k = XizIdentity()
            try save(kind, name: name, secretText: k.secretText, publicText: k.publicText)
            return k.publicText
        case .signing:
            let k = XizSigningKey()
            try save(kind, name: name, secretText: k.secretText, publicText: k.publicText)
            return k.publicText
        }
    }

    /// Imports a key file written by `xipper keygen` (or exported from the app).
    @discardableResult
    public static func importKey(fileText: String, name: String) throws -> (Kind, String) {
        if let i = try? XizIdentity(secretText: fileText) {
            try save(.identity, name: name, secretText: i.secretText, publicText: i.publicText)
            return (.identity, i.publicText)
        }
        let s = try XizSigningKey(secretText: fileText)
        try save(.signing, name: name, secretText: s.secretText, publicText: s.publicText)
        return (.signing, s.publicText)
    }
}

/// Who can open an XIZ 1.3 archive, read from its keys block without any credential.
public struct XizRecipientInfo: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case password
        /// The first 8 bytes of SHA-256 of the recipient's public key.
        case publicKey(keyID: [UInt8])
        /// A k-of-n group: its custodians follow as `.custodian`.
        case threshold(k: Int, n: Int)
        case custodian(threshold: String, keyID: [UInt8]?)
    }

    public var label: String
    public var kind: Kind
}

/// What an XIZ archive is, from its public parts.
public struct XizArchiveInfo: Sendable {
    /// XIZ 1.3 (directory: groups, signatures, proofs).
    public var hasDirectory: Bool
    public var encrypted: Bool
    public var recipients: [XizRecipientInfo]
    /// Created with erasable files (§13.7).
    public var erasable: Bool
    /// Its segments carry a Merkle tree (proofs can be made).
    public var provable: Bool
    /// At least one segment is signed.
    public var signed: Bool

    /// Whether one of these identities (public key texts) can open it.
    public func matches(publicKeys: [String]) -> Bool {
        let ids = Set(publicKeys.compactMap { try? XizIdentity.publicKey(fromText: $0) }.map(XizAccessKeys.keyID))
        return recipients.contains { r in
            switch r.kind {
            case let .publicKey(id): ids.contains(id)
            case let .custodian(_, id?): ids.contains(id)
            default: false
            }
        }
    }

    public var needsCustodians: Bool { recipients.contains { if case .threshold = $0.kind { true } else { false } } }
}

extension XizAccessKeys {
    /// The public part of every stanza: labels and kinds (no key is opened).
    static func describe(_ b: [UInt8]) throws -> [XizRecipientInfo] {
        guard b.count >= 10, b.starts(with: Xiz.keysMagic) else { throw XipperError.corrupt("XIZ keys block") }
        var out: [XizRecipientInfo] = []
        var thresholds: [UInt8: String] = [:]
        var thresholdAt: [UInt8: Int] = [:]  // index in `out`
        var shares: [(UInt8, XizRecipientInfo)] = []
        try b.withUnsafeBytes { raw in
            var r = ByteReader(UnsafeRawBufferPointer(rebasing: raw[..<(raw.count - 4)]), at: 4)
            for _ in 0..<Int(try r.u16()) {
                let type = try r.u8(), len = Int(try r.u16())
                let body = Array(try r.bytes(len))
                func label(at p: Int) -> String {
                    guard p < body.count, p + 1 + Int(body[p]) <= body.count else { return "" }
                    return String(decoding: body[(p + 1)..<(p + 1 + Int(body[p]))], as: UTF8.self)
                }
                switch StanzaType(rawValue: type) {
                case .passwordRecipient?: out.append(XizRecipientInfo(label: label(at: 44), kind: .password))
                case .keyRecipient?:
                    guard body.count >= 40 else { continue }
                    out.append(XizRecipientInfo(label: label(at: 40), kind: .publicKey(keyID: Array(body[32..<40]))))
                case .threshold?:
                    guard body.count >= 4 else { continue }
                    let l = label(at: 3)
                    thresholds[body[0]] = l
                    thresholdAt[body[0]] = out.count
                    out.append(XizRecipientInfo(label: l, kind: .threshold(k: Int(body[1]), n: Int(body[2]))))
                case .share?:
                    guard body.count >= 4 else { continue }
                    let kind = body[2]
                    let id: [UInt8]? = kind == 2 && body.count >= 43 ? Array(body[35..<43]) : nil
                    shares.append((body[0], XizRecipientInfo(label: label(at: 3 + (kind == 1 ? 44 : 40)), kind: .custodian(threshold: "", keyID: id))))
                default: continue
                }
            }
        }
        // Custodians right after their group.
        var result: [XizRecipientInfo] = []
        for (i, r) in out.enumerated() {
            result.append(r)
            guard let tid = thresholdAt.first(where: { $0.value == i })?.key else { continue }
            for (t, var s) in shares where t == tid {
                if case let .custodian(_, id) = s.kind { s.kind = .custodian(threshold: thresholds[tid] ?? "", keyID: id) }
                result.append(s)
            }
        }
        return result
    }
}
