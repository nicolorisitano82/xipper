import CryptoKit
import Foundation
import Security

/// A signing identity bound to a person by an X.509 certificate (§13.5, algorithms 2 and 3): a key in the
/// Keychain, on a smart card (CryptoTokenKit: PIV, or an Italian signature card with its driver) or in
/// the Secure Enclave, with its certificate chain. The private key never leaves its token: signing
/// goes through `SecKeyCreateSignature`, which may ask for the PIN.
public struct XizCertificateSigner: @unchecked Sendable {
    public let privateKey: SecKey
    /// DER certificates, the signer's first, then the issuers as far as known.
    public let chain: [[UInt8]]
    /// 2 = ECDSA P-256 with SHA-256, 3 = RSA PKCS#1 v1.5 with SHA-256.
    public let algorithm: UInt8

    public init(privateKey: SecKey, chain: [[UInt8]]) throws {
        guard let leafDER = chain.first, let leaf = SecCertificateCreateWithData(nil, Data(leafDER) as CFData),
              let certKey = SecCertificateCopyKey(leaf) else {
            throw XipperError.invalidArgument("no signer certificate")
        }
        guard let attrs = SecKeyCopyAttributes(privateKey) as? [String: Any], let type = attrs[kSecAttrKeyType as String] as? String else {
            throw XipperError.invalidArgument("unreadable signing key")
        }
        let bits = attrs[kSecAttrKeySizeInBits as String] as? Int ?? 0
        if type == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            guard bits == 256 else { throw XipperError.unsupported("EC key of \(bits) bits (P-256 only)") }
            algorithm = 2
        } else if type == (kSecAttrKeyTypeRSA as String) {
            guard bits >= 2048 else { throw XipperError.unsupported("RSA key of \(bits) bits (2048 or more)") }
            algorithm = 3
        } else {
            throw XipperError.unsupported("signing key type")
        }
        // The key must be the certificate's: sign a probe and check it with the certificate.
        let probe = Array("XIZ certificate key check".utf8)
        let sig = try Self.sign(privateKey, algorithm, probe)
        guard SecKeyVerifySignature(certKey, Self.secAlgorithm(algorithm), Data(probe) as CFData, Data(sig) as CFData, nil) else {
            throw XipperError.invalidArgument("the key does not belong to the certificate")
        }
        self.privateKey = privateKey
        self.chain = chain
    }

    /// An identity from the Keychain or a token, with the chain macOS builds for it.
    public init(identity: SecIdentity) throws {
        var key: SecKey?, cert: SecCertificate?
        guard SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key,
              SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert else {
            throw XipperError.invalidArgument("unusable identity")
        }
        var chain = [Array(SecCertificateCopyData(cert) as Data)]
        var trust: SecTrust?
        if SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust {
            _ = SecTrustEvaluateWithError(trust, nil)
            for c in (SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []).dropFirst() {
                chain.append(Array(SecCertificateCopyData(c) as Data))
            }
        }
        try self.init(privateKey: key, chain: chain)
    }

    /// Signing identities available to this user (Keychain and inserted smart cards), by certificate name.
    public static func identities() -> [(name: String, identity: SecIdentity)] {
        let q: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecReturnRef as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let list = out as? [SecIdentity] else { return [] }
        var result: [(String, SecIdentity)] = []
        for id in list {
            var cert: SecCertificate?
            guard SecIdentityCopyCertificate(id, &cert) == errSecSuccess, let cert,
                  let name = SecCertificateCopySubjectSummary(cert) as String? else { continue }
            result.append((name, id))
        }
        return result.sorted { $0.0 < $1.0 }
    }

    /// The identity whose certificate is called `name` (subject summary), or nil.
    public static func identity(named name: String) -> SecIdentity? { identities().first { $0.name == name }?.identity }

    public var subject: String { XizCertificateInfo(chain.first ?? []).subject }

    func sign(_ message: [UInt8]) throws -> [UInt8] { try Self.sign(privateKey, algorithm, message) }

    static func secAlgorithm(_ a: UInt8) -> SecKeyAlgorithm {
        a == 2 ? .ecdsaSignatureMessageX962SHA256 : .rsaSignatureMessagePKCS1v15SHA256
    }

    static func sign(_ key: SecKey, _ algorithm: UInt8, _ message: [UInt8]) throws -> [UInt8] {
        var error: Unmanaged<CFError>?
        guard let s = SecKeyCreateSignature(key, secAlgorithm(algorithm), Data(message) as CFData, &error) as Data? else {
            let e = error?.takeRetainedValue()
            throw XipperError.invalidArgument("signing with the certificate key failed\(e.map { ": \(CFErrorCopyDescription($0) as String)" } ?? "")")
        }
        return Array(s)
    }

    /// Checks `signature` over `message` with the chain's first certificate.
    static func verify(algorithm: UInt8, chain: [[UInt8]], message: [UInt8], signature: [UInt8]) -> Bool {
        guard algorithm == 2 || algorithm == 3, let leaf = chain.first, let cert = SecCertificateCreateWithData(nil, Data(leaf) as CFData),
              let key = SecCertificateCopyKey(cert) else { return false }
        return SecKeyVerifySignature(key, secAlgorithm(algorithm), Data(message) as CFData, Data(signature) as CFData, nil)
    }
}

/// What a reader shows about a signer certificate: names, validity, and whether macOS trusts the chain
/// (at the time the signature claims; a qualified status needs the EU trusted lists, see ForensicKit).
public struct XizCertificateInfo: Sendable, Equatable {
    public var subject = ""
    public var issuer = ""
    public var serial = ""
    public var notBefore: Date?
    public var notAfter: Date?
    /// SHA-256 of the certificate, hex.
    public var fingerprint = ""
    /// The chain reaches a root this Mac trusts, evaluated at the signing time.
    public var trusted = false
    /// The signing time falls within the certificate's validity.
    public var validAtSigning = false

    public init(_ der: [UInt8], chain: [[UInt8]] = [], at time: Date? = nil) {
        fingerprint = Xiz.sha256(der).map { String(format: "%02x", $0) }.joined()
        guard let cert = SecCertificateCreateWithData(nil, Data(der) as CFData) else { return }
        subject = SecCertificateCopySubjectSummary(cert) as String? ?? ""
        if let tbs = try? DER.children(of: try DER.element(der, at: 0)).first, let fields = try? DER.children(of: tbs) {
            let f = fields.first?.tag == 0xA0 ? Array(fields.dropFirst()) : fields
            if f.count >= 5 {
                serial = f[0].content.map { String(format: "%02x", $0) }.joined()
                issuer = Self.commonName(f[2].raw) ?? ""
                let validity = (try? DER.children(of: f[3])) ?? []
                if validity.count == 2 { notBefore = Self.time(validity[0]); notAfter = Self.time(validity[1]) }
            }
        }
        if let t = time, let a = notBefore, let b = notAfter { validAtSigning = a <= t && t <= b }
        let certs = ([der] + chain.dropFirst()).compactMap { SecCertificateCreateWithData(nil, Data($0) as CFData) }
        var trust: SecTrust?
        if SecTrustCreateWithCertificates(certs as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust {
            if let time { SecTrustSetVerifyDate(trust, time as CFDate) }
            SecTrustSetNetworkFetchAllowed(trust, false)
            trusted = SecTrustEvaluateWithError(trust, nil)
        }
    }

    static func time(_ e: DER.Element) -> Date? {
        let s = String(decoding: e.content, as: UTF8.self)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = e.tag == 0x17 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return f.date(from: s)
    }

    /// The CN (or the last attribute) of an X.501 Name.
    static func commonName(_ name: [UInt8]) -> String? {
        guard let rdns = try? DER.children(of: try DER.element(name, at: 0)) else { return nil }
        var last: String?
        for rdn in rdns {
            for atv in (try? DER.children(of: rdn)) ?? [] {
                guard let p = try? DER.children(of: atv), p.count == 2 else { continue }
                let v = String(decoding: p[1].content, as: UTF8.self)
                if p[0].content == [0x55, 0x04, 0x03] { return v }
                last = v
            }
        }
        return last
    }
}
