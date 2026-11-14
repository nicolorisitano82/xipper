import CryptoKit
import Foundation
import Security

/// What a signature on a document is worth, from the strongest:
/// - `qualified`: qualified electronic signature (QES, eIDAS art. 25.2: the Italian "firma digitale"):
///   a qualified certificate from an authority granted on the EU trusted list at the time of signing,
///   with the key in a qualified signature creation device (QSCD);
/// - `qualifiedCertificate`: advanced signature with a qualified certificate, without a QSCD;
/// - `advanced`: the certificate chains to an authority this Mac or the list trusts, not qualified;
/// - `untrustedSigner`: the signature verifies, but nobody vouches for the certificate;
/// - `invalid`: the content changed, the signature does not verify, or the certificate was not valid.
public enum SignatureLevel: String, Sendable, Comparable {
    case invalid, untrustedSigner, advanced, qualifiedCertificate, qualified
    static let order: [SignatureLevel] = [.invalid, .untrustedSigner, .advanced, .qualifiedCertificate, .qualified]
    public static func < (a: SignatureLevel, b: SignatureLevel) -> Bool { order.firstIndex(of: a)! < order.firstIndex(of: b)! }
}

/// Whether the signer's certificate was revoked.
public enum RevocationStatus: Sendable, Equatable {
    /// Not checked, and why (no consent to go online, no data).
    case notChecked(String)
    /// Not revoked at the time of signing, according to `source` (embedded CRL, CRL, OCSP).
    case good(source: String)
    /// Revoked (at `date` when known) before the signature's time.
    case revoked(date: Date?, source: String)
    /// Revoked after the signature's time: the signature stands.
    case revokedLater(date: Date, source: String)
    case unknown(String)
}

/// A verified time-stamp on a signature (CAdES-T: signature-time-stamp attribute; PAdES: document time-stamp).
public struct SignatureTimestamp: Sendable {
    public var time: Date
    public var authority: String
    /// The token's signature verifies and its imprint is the signature's.
    public var valid: Bool
    /// The authority is a qualified time-stamp service on the trusted list at that time.
    public var qualified: Bool
}

public struct DocumentSignature: Sendable {
    public enum Kind: String, Sendable { case signature, documentTimestamp }
    /// A signature, or a PDF document time-stamp (ETSI.RFC3161: it proves the time, not a person).
    public var kind: Kind = .signature
    public var signer: SignerCertificate?
    /// Certificates carried with the signature (the signer's and its issuers').
    public var chain: [SignerCertificate]
    /// The time the signer's computer claims (not a proof).
    public var claimedTime: Date?
    public var timestamp: SignatureTimestamp?
    /// The content is the one signed and the signature verifies.
    public var integrity: Bool
    /// CAdES-BES: the signed attributes name this certificate (nil: no such attribute).
    public var certificateBound: Bool?
    /// The certificate was within its dates at the signature's time.
    public var certificateValidAtSigning: Bool
    /// The qualified authority on the trusted list that issued the certificate.
    public var qualifiedAuthority: String?
    /// Trusted by this Mac's roots (without the list).
    public var trustedBySystem: Bool
    public var level: SignatureLevel
    public var revocation: RevocationStatus
    /// 0 for the outer signature of a nested `.p7m`, 1 for the one inside it, and so on.
    public var depth: Int
    public var problems: [String]
    /// The time used for every check: the time-stamp's when valid, else the claimed one, else now.
    public var referenceTime: Date
    /// PDF: the signature covers the whole file (no change after it).
    public var coversWholeFile: Bool = true

    static func unreadable(_ problem: String) -> DocumentSignature {
        DocumentSignature(signer: nil, chain: [], claimedTime: nil, timestamp: nil, integrity: false, certificateBound: nil,
                          certificateValidAtSigning: false, qualifiedAuthority: nil, trustedBySystem: false, level: .invalid,
                          revocation: .notChecked("no certificate"), depth: 0, problems: [problem], referenceTime: Date())
    }
}

public struct SignedDocument: Sendable {
    public enum Format: String, Sendable { case p7m, pdf, asic }
    public var format: Format
    public var signatures: [DocumentSignature]
    /// The signed document (the innermost content of a `.p7m`).
    public var content: [UInt8]?
    /// Its name: the file's without `.p7m` (or the PDF's own).
    public var contentName: String
    /// The trusted list used, for the report (nil: none).
    public var trustedList: [String: String]?
    public var allValid: Bool { !signatures.isEmpty && signatures.allSatisfy { $0.level != .invalid } }
    /// The weakest level among the signatures.
    public var level: SignatureLevel { signatures.map(\.level).min() ?? .invalid }
}

/// Options of a check.
public struct SignatureCheckOptions: Sendable {
    /// The EU trusted list to judge "qualified" (AgID for Italy); nil: only this Mac's roots.
    public var trustedList: TrustedList?
    /// Revocation: embedded data is always used; `online` allows OCSP and CRL requests (consent).
    public var online = false
    public init(trustedList: TrustedList? = nil, online: Bool = false) {
        self.trustedList = trustedList
        self.online = online
    }
}

enum SignedDocuments {
    /// A `.p7m`: DER or BER, or base64/PEM of it.
    static func p7mBytes(_ data: [UInt8]) -> [UInt8]? {
        if data.first == 0x30, (try? CMSSignedData(der: data)) != nil { return data }
        var text = String(decoding: data.prefix(64 << 20), as: UTF8.self)
        if let r = text.range(of: "-----BEGIN") { text = String(text[r.lowerBound...]) }
        let body = text.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let d = Data(base64Encoded: body, options: .ignoreUnknownCharacters), d.first == 0x30,
              (try? CMSSignedData(der: Array(d))) != nil else { return nil }
        return Array(d)
    }

    static func isP7M(_ data: [UInt8]) -> Bool { p7mBytes(data) != nil }

    /// Verifies a `.p7m`, unwrapping nested ones; the content is the innermost.
    static func verifyP7M(_ data: [UInt8], name: String, options: SignatureCheckOptions) throws -> SignedDocument {
        guard var current = p7mBytes(data) else { throw XipperError.unsupported("not a signed file (.p7m)") }
        var signatures: [DocumentSignature] = []
        var depth = 0
        var content: [UInt8]?
        while true {
            let cms = try CMSSignedData(der: current)
            guard let inner = cms.content else { throw XipperError.unsupported("detached signature: the signed file is needed too") }
            for s in cms.signers { signatures.append(check(cms, s, detached: nil, depth: depth, options: options)) }
            content = inner
            // "Firme a matrioska": the content is itself a signed file.
            if depth < 16, inner.first == 0x30, let nested = try? CMSSignedData(der: inner), nested.content != nil {
                current = inner
                depth += 1
                continue
            }
            break
        }
        var contentName = name
        while contentName.lowercased().hasSuffix(".p7m") { contentName = String(contentName.dropLast(4)) }
        return SignedDocument(format: .p7m, signatures: signatures, content: content, contentName: contentName,
                              trustedList: options.trustedList?.record)
    }

    /// One signer of a CMS message, judged.
    static func check(_ cms: CMSSignedData, _ s: CMSSignedData.Signer, detached: [UInt8]?, depth: Int,
                      options: SignatureCheckOptions) -> DocumentSignature {
        let c = cms.check(s, content: detached)
        var problems = c.problems
        // A time-stamp on the signature value (CAdES-T).
        var timestamp: SignatureTimestamp?
        if let token = s.unsigned(CMSSignedData.timeStampToken).first {
            timestamp = verifyTimestamp(token, over: s.signature, options: options)
            if timestamp?.valid != true { problems.append("the time-stamp does not verify") }
        }
        let reference = (timestamp?.valid == true ? timestamp?.time : nil) ?? c.signingTime ?? Date()
        let cert = c.certificate
        let chain = cms.certificates
        let validAt = cert?.isValid(at: reference) ?? false
        if cert != nil, !validAt { problems.append("the certificate was not valid at the signature's time") }
        if c.certificateBound == false { problems.append("the signed attributes name another certificate") }
        var authority: String?
        var qualifiers: Set<String> = []
        var listed: [SignerCertificate] = []
        if let cert, let tl = options.trustedList, let svc = tl.qualifiedAuthority(for: cert, chain: chain, at: reference) {
            authority = svc.provider.isEmpty ? svc.name : "\(svc.provider) — \(svc.name)"
            qualifiers = svc.qualifiers
            // The authority's certificates from the list: issuers for the revocation check too.
            listed = svc.certificates.compactMap { try? SignerCertificate(der: $0) }
        }
        let system = cert.map { systemTrust($0, chain: chain, at: reference) } ?? false
        // Revocation: embedded CRLs, then (with consent) OCSP and CRL online.
        let revocation = cert.map { Revocation.status($0, chain: chain + listed, embeddedCRLs: cms.crls, at: reference, online: options.online) }
            ?? .notChecked("no certificate")
        var level: SignatureLevel
        if !c.valid || !validAt || c.certificateBound == false { level = .invalid }
        else if case .revoked = revocation { level = .invalid; problems.append("the certificate was revoked before the signature's time") }
        else if authority != nil {
            let q = "http://uri.etsi.org/TrstSvc/TrustedList/SvcInfoExt/"
            let qualifiedCert = (cert?.qcCompliance ?? false) || qualifiers.contains(q + "QCStatement")
            let qscd = qualifiers.contains(q + "QCWithSSCD") || qualifiers.contains(q + "QCWithQSCD")
                || ((cert?.qcSSCD ?? false) && !qualifiers.contains(q + "QCNoSSCD") && !qualifiers.contains(q + "QCNoQSCD"))
            level = qualifiedCert ? (qscd ? .qualified : .qualifiedCertificate) : .advanced
            if level == .qualified, cert?.keyUsagePresent == true, cert?.nonRepudiation == false {
                problems.append("the certificate's key usage lacks non-repudiation, required for a firma digitale")
            }
        } else if system { level = .advanced }
        else { level = .untrustedSigner }
        return DocumentSignature(kind: .signature, signer: cert, chain: chain, claimedTime: c.signingTime, timestamp: timestamp, integrity: c.valid,
                                 certificateBound: c.certificateBound, certificateValidAtSigning: validAt, qualifiedAuthority: authority,
                                 trustedBySystem: system, level: level, revocation: revocation, depth: depth, problems: problems,
                                 referenceTime: reference)
    }

    static func systemTrust(_ cert: SignerCertificate, chain: [SignerCertificate], at time: Date) -> Bool {
        guard let leaf = cert.secCertificate else { return false }
        var trust: SecTrust?
        let all = [leaf] + chain.filter { $0 != cert }.compactMap(\.secCertificate)
        guard SecTrustCreateWithCertificates(all as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust else { return false }
        SecTrustSetVerifyDate(trust, time as CFDate)
        SecTrustSetNetworkFetchAllowed(trust, false)
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// An RFC 3161 token over `signature`: its own CMS signature, the imprint, the time; qualified
    /// when the authority is a granted QTST on the list.
    static func verifyTimestamp(_ token: [UInt8], over signature: [UInt8], options: SignatureCheckOptions) -> SignatureTimestamp? {
        guard let cms = try? CMSSignedData(der: token), let info = cms.content, let s = cms.signers.first else { return nil }
        let c = cms.check(s)
        let a = ASN1(info)
        guard let root = try? a.root(), let f = try? a.children(root), f.count >= 5,
              let mi = try? a.children(f[2]), mi.count == 2,
              let algNode = try? a.children(mi[0]).first, let time = a.time(f[4]) else { return nil }
        let imprint = Array(a.content(mi[1]))
        let matches = CMSSignedData.hash(a.oid(algNode)).map { $0(signature) == imprint } ?? false
        var ts = SignatureTimestamp(time: time, authority: c.certificate?.subject.display ?? "", valid: c.valid && matches, qualified: false)
        if ts.valid, let tl = options.trustedList, let cert = c.certificate {
            let x = XizTimestamp(time: time, authority: ts.authority, valid: true, trusted: false, certificate: cert.der,
                                 issuers: cms.certificates.filter { $0 != cert }.map(\.der))
            ts.qualified = tl.qualified(x) != nil
        }
        return ts
    }
}
