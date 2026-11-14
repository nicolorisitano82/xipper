import AppleArchive
import CryptoKit
import Foundation
import System

/// Signed Apple Archives: AEA profile 0 (`hkdf_sha256_hmac__none__ecdsa_p256`, signed with ECDSA
/// P-256, not encrypted), which `aea decrypt -sign-pub-value KEY` also checks.
///
/// AEA has no profile that is both password-encrypted and signed. Xipper signs with a P-256 key
/// derived from the user's XIZ signing key (Ed25519), so one key in the Keychain serves both
/// formats, and stores in the header's authenticated data (key-value form) the signer's label,
/// both public keys and an Ed25519 signature binding the P-256 key to the Ed25519 one. Without
/// that binding anyone could copy someone else's Ed25519 key next to their own P-256 signature.
enum AEASignature {
    static let labelKey = "xipper.signer", ed25519Key = "xipper.ed25519", p256Key = "xipper.p256", bindingKey = "xipper.binding"
    static let bindingContext = Array("xipper-aea-binding-v1".utf8)

    /// The P-256 signing key derived from an XIZ signing key (HKDF-SHA256, retried in the rare
    /// case the output is not a valid scalar).
    static func p256(for key: XizSigningKey) -> P256.Signing.PrivateKey {
        let ikm = SymmetricKey(data: key.privateKey.rawRepresentation)
        for counter in UInt8(0)...UInt8.max {
            let raw = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: Array("xipper-aea-p256".utf8), info: [counter], outputByteCount: 32)
            if let k = raw.withUnsafeBytes({ try? P256.Signing.PrivateKey(rawRepresentation: Data($0)) }) { return k }
        }
        fatalError("no valid P-256 scalar in 256 HKDF outputs")
    }

    static func bindingMessage(p256: [UInt8], label: String) -> [UInt8] { bindingContext + p256 + Array(label.utf8) }

    /// Authenticated data naming the signer.
    static func authData(for signer: XizSigner) throws -> Data {
        // AEA wants a P-256 key derived from the Ed25519 one: not a certificate's, not the Secure Enclave's.
        guard signer.certificate == nil, signer.enclave == nil else {
            throw XipperError.unsupported("Apple Archive signs with an XIZ Ed25519 key only (not a certificate or a Secure Enclave key)")
        }
        let p256 = Array(Self.p256(for: signer.key).publicKey.x963Representation)
        let binding = try signer.key.privateKey.signature(for: bindingMessage(p256: p256, label: signer.label))
        return encode([(labelKey, Array(signer.label.utf8)), (ed25519Key, signer.key.publicKey), (p256Key, p256),
                       (bindingKey, Array(binding))])
    }

    /// AEA key-value auth data: each entry is a little-endian u32 size (itself included), the key,
    /// a NUL and the value.
    static func encode(_ entries: [(String, [UInt8])]) -> Data {
        var out = Data()
        for (k, v) in entries {
            let size = UInt32(4 + k.utf8.count + 1 + v.count)
            withUnsafeBytes(of: size.littleEndian) { out.append(contentsOf: $0) }
            out.append(contentsOf: Array(k.utf8) + [0] + v)
        }
        return out
    }

    static func decode(_ data: Data) -> [String: [UInt8]] {
        let b = [UInt8](data)
        var out: [String: [UInt8]] = [:]
        var p = 0
        while p + 4 <= b.count {
            let size = Int(b[p]) | Int(b[p + 1]) << 8 | Int(b[p + 2]) << 16 | Int(b[p + 3]) << 24
            guard size > 4, p + size <= b.count, let nul = b[(p + 4)..<(p + size)].firstIndex(of: 0) else { break }
            out[String(decoding: b[(p + 4)..<nul], as: UTF8.self)] = Array(b[(nul + 1)..<(p + size)])
            p += size
        }
        return out
    }

    struct Signer {
        var label: String
        var ed25519: [UInt8]
        var p256: P256.Signing.PublicKey
        /// The Ed25519 key vouches for the P-256 key that signed the archive.
        var bound: Bool
    }

    /// The signer Xipper stored in a signed archive's header; nil when the archive is not signed
    /// or was signed by another tool (whose key is not in the header).
    static func signer(_ context: ArchiveEncryptionContext) -> Signer? {
        guard context.signatureMode == .ecdsa_p256, let data = context.authData else { return nil }
        let d = decode(data)
        guard let raw = d[p256Key], let p256 = try? P256.Signing.PublicKey(x963Representation: raw) else { return nil }
        let label = d[labelKey].map { String(decoding: $0, as: UTF8.self) } ?? ""
        let ed = d[ed25519Key] ?? []
        let bound = (try? Curve25519.Signing.PublicKey(rawRepresentation: ed)).map {
            $0.isValidSignature(d[bindingKey] ?? [], for: bindingMessage(p256: raw, label: label))
        } ?? false
        return Signer(label: label, ed25519: ed, p256: p256, bound: bound)
    }

    /// The signature of a signed Apple Archive as one history entry, like an XIZ segment. `valid`
    /// covers the header (signature and binding); the content is checked by reading it, as
    /// `Xipper.test` does. Empty when the archive is not signed.
    static func history(_ path: String) throws -> [XizSegmentSignature] {
        guard let f = ArchiveByteStream.fileStream(path: FilePath(path), mode: .readOnly, options: [],
                                                   permissions: FilePermissions(rawValue: 0o644)) else {
            throw XipperError.posix("open", path)
        }
        defer { try? f.close() }
        guard let context = ArchiveEncryptionContext(from: f) else { throw XipperError.corrupt("invalid AEA header") }
        guard context.signatureMode == .ecdsa_p256 else { return [] }
        guard let s = signer(context) else {
            return [XizSegmentSignature(segment: 0, signed: true, label: "", publicKey: [], time: nil, valid: false, chained: true, timestamp: nil)]
        }
        var valid = s.bound
        if valid {
            do {
                try context.setSigningPublicKey(s.p256)
                if let d = ArchiveByteStream.decryptionStream(readingFrom: f, encryptionContext: context) { try? d.close() } else { valid = false }
            } catch { valid = false }
        }
        return [XizSegmentSignature(segment: 0, signed: true, label: s.label, publicKey: s.ed25519, time: nil, valid: valid, chained: true,
                                    timestamp: nil, aeaPublicKeyPEM: s.p256.pemRepresentation)]
    }
}
