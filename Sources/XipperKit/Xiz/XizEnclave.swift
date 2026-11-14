import CryptoKit
import Foundation
import Security

/// A key to sign XIZ segments that never leaves this Mac's Secure Enclave (XIZ 1.13, §23,
/// algorithm 5): ECDSA P-256 and ML-DSA-65, both made and kept by the Secure Enclave, both signing
/// every segment, like the hybrid key of §22. What the Keychain stores is two blobs only this
/// Mac's Secure Enclave can use: the key cannot be copied, and is lost with the Mac (keep another
/// key, or a certificate, for archives that must outlive it).
public struct XizEnclaveSigningKey: @unchecked Sendable {
    let p256: SecureEnclave.P256.Signing.PrivateKey
    let mldsa: SecureEnclave.MLDSA65.PrivateKey

    public static let secretPrefix = "XIZ-SIGNING-KEY-SE-1-", publicPrefix = "xizsigse1"
    static let p256KeySize = 65
    static let recordKeySize = p256KeySize + XizSigningKey.mldsaPublicKeySize        // 2017
    static let signatureSize = 64 + XizSigningKey.mldsaSignatureSize                  // 3373
    /// FIPS 204 context of the ML-DSA half.
    static let mldsaContext = Array("XIZ113enclave".utf8)

    /// This Mac has a Secure Enclave (every Apple silicon Mac).
    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    /// A new key, made inside the Secure Enclave; usable only while the Mac is unlocked.
    public init() throws {
        guard SecureEnclave.isAvailable else { throw XipperError.unsupported("this Mac has no Secure Enclave") }
        guard let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, nil) else {
            throw XipperError.unsupported("Secure Enclave access control")
        }
        p256 = try SecureEnclave.P256.Signing.PrivateKey(accessControl: ac)
        mldsa = try SecureEnclave.MLDSA65.PrivateKey(accessControl: ac)
    }

    public init(secretText: String) throws {
        guard let line = XizIdentity.keyLine(secretText, prefix: Self.secretPrefix),
              let raw = Base64URL.decode(String(line.dropFirst(Self.secretPrefix.count))), raw.count > 2 else {
            throw XipperError.invalidArgument("not an XIZ Secure Enclave signing key")
        }
        let n = Int(raw[0]) << 8 | Int(raw[1])
        guard raw.count > 2 + n else { throw XipperError.invalidArgument("not an XIZ Secure Enclave signing key") }
        do {
            p256 = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: Data(raw[2..<(2 + n)]))
            mldsa = try SecureEnclave.MLDSA65.PrivateKey(dataRepresentation: Data(raw[(2 + n)...]))
        } catch {
            throw XipperError.invalidArgument("this Secure Enclave key belongs to another Mac (or was reset)")
        }
    }

    public static func isSecretText(_ text: String) -> Bool { XizIdentity.keyLine(text, prefix: secretPrefix) != nil }

    /// P-256 public key (X9.63, 65 bytes) ‖ ML-DSA-65 public key (1952 bytes).
    public var recordKey: [UInt8] { Array(p256.publicKey.x963Representation) + Array(mldsa.publicKey.rawRepresentation) }
    public var publicText: String { Self.publicPrefix + Base64URL.encode(recordKey) }
    /// The blobs the Secure Enclave gave: not the keys, which stay inside it.
    public var secretText: String {
        let a = Array(p256.dataRepresentation)
        return Self.secretPrefix + Base64URL.encode([UInt8(a.count >> 8), UInt8(a.count & 0xFF)] + a + Array(mldsa.dataRepresentation))
    }
    public var fileText: String {
        "# XIZ signing key in the Secure Enclave (P-256 + ML-DSA-65): works only on the Mac that made it\n# public key: \(Self.displayText(recordKey))\n\(secretText)\n"
    }

    /// ECDSA (raw r ‖ s, 64 bytes) ‖ ML-DSA-65 with its context: the Secure Enclave signs both.
    func recordSignature(_ message: [UInt8]) throws -> [UInt8] {
        // Data, not [UInt8]: with byte arrays the Secure Enclave's ML-DSA returns an empty signature
        // (macOS 27 beta); the sizes are checked anyway.
        let ec = Array(try p256.signature(for: Data(message)).rawRepresentation)
        let pq = Array(try mldsa.signature(for: Data(message), context: Data(Self.mldsaContext)))
        guard ec.count == 64, pq.count == XizSigningKey.mldsaSignatureSize else {
            throw XipperError.codec("Secure Enclave signature of \(ec.count) + \(pq.count) bytes")
        }
        return ec + pq
    }

    static func verify(recordKey key: [UInt8], signature: [UInt8], message: [UInt8]) -> Bool {
        guard key.count == recordKeySize, signature.count == signatureSize,
              let ec = try? P256.Signing.PublicKey(x963Representation: key[0..<p256KeySize]),
              let ecSig = try? P256.Signing.ECDSASignature(rawRepresentation: signature[0..<64]),
              let pq = try? MLDSA65.PublicKey(rawRepresentation: key[p256KeySize...]) else { return false }
        return ec.isValidSignature(ecSig, for: message) && pq.isValidSignature(signature[64...], for: message, context: mldsaContext)
    }

    /// `xizsigse1:` and the first 128 bits of SHA-256 of the record key, in hex.
    public static func displayText(_ key: [UInt8]) -> String {
        publicPrefix + ":" + Xiz.sha256(key).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

extension XizSigner {
    /// A signer from a stored secret: an Ed25519 or hybrid key, or a Secure Enclave key.
    public init(secretText: String, label: String, timestampURL: URL? = nil) throws {
        if XizEnclaveSigningKey.isSecretText(secretText) {
            self.init(enclave: try XizEnclaveSigningKey(secretText: secretText), label: label, timestampURL: timestampURL)
        } else {
            self.init(key: try XizSigningKey(secretText: secretText), label: label, timestampURL: timestampURL)
        }
    }
}
