import CryptoKit
import Foundation
import Security

/// Signing documents as `.p7m` (CAdES-BES, ETSI EN 319 122-1; the Italian "firma digitale" when the
/// certificate is qualified and the key sits in a qualified device such as a smart card): the content
/// inside, the signed attributes content-type, signing-time, message-digest and signing-certificate-v2,
/// SHA-256, RSA PKCS#1 v1.5 or ECDSA. Optionally a time-stamp on the signature (CAdES-T).
public enum DocumentSignatureMode: String, Sendable {
    /// A new `.p7m` around any file.
    case new
    /// One more signer in an existing `.p7m`, side by side ("firma parallela").
    case parallel
    /// A `.p7m` around the `.p7m` ("firma a matrioska", also used as a countersignature).
    case nested
}

/// Where the time-stamp comes from.
public enum TimestampSource: Sendable {
    /// An RFC 3161 authority (https; with credentials for qualified authorities that want an account).
    case authority(URL, credentials: (user: String, password: String)?)
    /// Anything else that answers a request with a TimeStampToken (tests, other transports).
    case custom(@Sendable (_ imprint: [UInt8]) throws -> [UInt8])
}

enum CAdES {
    static let sha256 = DER.seq(DER.oid([2, 16, 840, 1, 101, 3, 4, 2, 1]))
    static let idData = DER.oid([1, 2, 840, 113549, 1, 7, 1])

    /// The signed attributes of a signature over `digest`, sorted as DER requires for a SET OF.
    static func signedAttributes(digest: [UInt8], certificate: SignerCertificate, time: Date) -> [UInt8] {
        func attribute(_ oid: [UInt], _ value: [UInt8]) -> [UInt8] { DER.seq(DER.oid(oid) + DER.tlv(0x31, value)) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyMMddHHmmss'Z'"
        // ESSCertIDv2 { certHash, issuerSerial { GeneralNames { [4] issuer }, serial } }, SHA-256 by default.
        let issuerSerial = DER.seq(DER.seq(DER.tlv(0xA4, certificate.issuerDER)) + DER.integer(certificate.serial))
        let essCertID = DER.seq(DER.tlv(0x04, Array(SHA256.hash(data: certificate.der))) + issuerSerial)
        let attrs = [
            attribute([1, 2, 840, 113549, 1, 9, 3], idData),
            attribute([1, 2, 840, 113549, 1, 9, 5], DER.tlv(0x17, Array(f.string(from: time).utf8))),
            attribute([1, 2, 840, 113549, 1, 9, 4], DER.tlv(0x04, digest)),
            attribute([1, 2, 840, 113549, 1, 9, 16, 2, 47], DER.seq(DER.seq(essCertID))),
        ].sorted { $0.lexicographicallyPrecedes($1) }
        return attrs.flatMap { $0 }
    }

    /// One SignerInfo for `content`, signed with `signer` (and time-stamped by `timestamp`).
    static func signerInfo(content: [UInt8], signer: XizCertificateSigner, time: Date, timestamp: TimestampSource?) throws -> [UInt8] {
        guard let leaf = signer.chain.first else { throw XipperError.invalidArgument("no certificate") }
        let certificate = try SignerCertificate(der: leaf)
        let attrs = signedAttributes(digest: Array(SHA256.hash(data: content)), certificate: certificate, time: time)
        let signature = try signer.sign(DER.tlv(0x31, attrs))
        let sigAlg = signer.algorithm == 2
            ? DER.seq(DER.oid([1, 2, 840, 10045, 4, 3, 2]))                         // ecdsa-with-SHA256
            : DER.seq(DER.oid([1, 2, 840, 113549, 1, 1, 11]) + [0x05, 0x00])        // sha256WithRSAEncryption
        var body = DER.integer([1])
            + DER.seq(certificate.issuerDER + DER.integer(certificate.serial))
            + sha256
            + DER.tlv(0xA0, attrs)
            + sigAlg
            + DER.tlv(0x04, signature)
        if let timestamp {
            let token = try stamp(Array(SHA256.hash(data: signature)), timestamp)
            body += DER.tlv(0xA1, DER.seq(DER.oid([1, 2, 840, 113549, 1, 9, 16, 2, 14]) + DER.tlv(0x31, token)))
        }
        return DER.seq(body)
    }

    static func stamp(_ imprint: [UInt8], _ source: TimestampSource) throws -> [UInt8] {
        switch source {
        case let .authority(url, credentials): return try RFC3161.request(url, imprint: imprint, credentials: credentials)
        case let .custom(f): return try f(imprint)
        }
    }

    /// ContentInfo { signedData, SignedData { 1, {sha256}, {data, content}, certificates, signerInfos } }.
    static func message(content: [UInt8], certificates: [[UInt8]], digestAlgorithms: [[UInt8]], signerInfos: [[UInt8]],
                        crls: [[UInt8]] = []) -> [UInt8] {
        var sd = DER.integer([1])
            + DER.tlv(0x31, Array(Set(digestAlgorithms)).sorted { $0.lexicographicallyPrecedes($1) }.flatMap { $0 })
            + DER.seq(idData + DER.tlv(0xA0, DER.tlv(0x04, content)))
            + DER.tlv(0xA0, certificates.flatMap { $0 })
        if !crls.isEmpty { sd += DER.tlv(0xA1, crls.flatMap { $0 }) }
        sd += DER.tlv(0x31, signerInfos.flatMap { $0 })
        return DER.seq(DER.oid([1, 2, 840, 113549, 1, 7, 2]) + DER.tlv(0xA0, DER.seq(sd)))
    }

    /// Signs `input` (any file, or a `.p7m` for the parallel and nested modes).
    static func sign(_ input: [UInt8], mode: DocumentSignatureMode, signer: XizCertificateSigner, time: Date = Date(),
                     timestamp: TimestampSource?) throws -> [UInt8] {
        switch mode {
        case .new, .nested:
            let content = mode == .nested ? (SignedDocuments.p7mBytes(input) ?? input) : input
            let info = try signerInfo(content: content, signer: signer, time: time, timestamp: timestamp)
            return message(content: content, certificates: signer.chain, digestAlgorithms: [sha256], signerInfos: [info])
        case .parallel:
            guard let p7m = SignedDocuments.p7mBytes(input) else { throw XipperError.invalidArgument("a parallel signature needs a .p7m") }
            let a = ASN1(p7m)
            let ci = try a.children(try a.root())
            guard ci.count == 2, let sdNode = try a.children(ci[1]).first else { throw XipperError.corrupt("CMS") }
            let sd = try a.children(sdNode)
            let cms = try CMSSignedData(der: p7m)
            guard let content = cms.content else { throw XipperError.unsupported("detached signature") }
            let info = try signerInfo(content: content, signer: signer, time: time, timestamp: timestamp)
            let digestAlgorithms = try a.children(sd[1]).map { Array(a.raw($0)) } + [sha256]
            var certs: [[UInt8]] = []
            for n in sd.dropFirst(3) where n.tag == 0xA0 { certs += try a.children(n).map { Array(a.raw($0)) } }
            for c in signer.chain where !certs.contains(c) { certs.append(c) }
            var crls: [[UInt8]] = []
            for n in sd.dropFirst(3) where n.tag == 0xA1 { crls += try a.children(n).map { Array(a.raw($0)) } }
            guard let infos = sd.last, infos.tag == 0x31 else { throw XipperError.corrupt("CMS signerInfos") }
            let existing = try a.children(infos).map { Array(a.raw($0)) }
            return message(content: content, certificates: certs, digestAlgorithms: digestAlgorithms, signerInfos: existing + [info], crls: crls)
        }
    }
}

extension Xipper {
    /// Signs a file as `.p7m` (CAdES-BES, or CAdES-T with `timestamp`). `mode` .new wraps any file;
    /// for a `.p7m`, .parallel adds a signer beside the others and .nested wraps it again.
    /// Returns where it was written: `output`, or next to the input (`name.p7m`; a parallel signature
    /// replaces the `.p7m` in place, written under a temporary name first).
    @discardableResult
    public static func signDocument(_ input: URL, output: URL? = nil, mode: DocumentSignatureMode = .new,
                                    signer: XizCertificateSigner, timestamp: TimestampSource? = nil, overwrite: Bool = false) throws -> URL {
        let data = try [UInt8](Data(contentsOf: input))
        let signed = try CAdES.sign(data, mode: mode, signer: signer, timestamp: timestamp)
        let out = output ?? (mode == .parallel ? input : input.appendingPathExtension("p7m"))
        if out != input, FileManager.default.fileExists(atPath: out.path), !overwrite { throw XipperError.alreadyExists(path: out.path) }
        let tmp = out.deletingLastPathComponent().appendingPathComponent(".\(out.lastPathComponent).\(UUID().uuidString).tmp")
        try Data(signed).write(to: tmp)
        // Checked before it takes the name: our own verifier must find every signature intact.
        let check = try SignedDocuments.verifyP7M(signed, name: out.lastPathComponent, options: SignatureCheckOptions())
        guard check.signatures.allSatisfy(\.integrity) else {
            try? FileManager.default.removeItem(at: tmp)
            throw XipperError.integrity(entry: out.lastPathComponent, detail: "the new signature does not verify")
        }
        if FileManager.default.fileExists(atPath: out.path) {
            _ = try FileManager.default.replaceItemAt(out, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: out)
        }
        return out
    }
}
