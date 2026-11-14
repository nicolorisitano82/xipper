import CryptoKit
import Foundation
import Security

/// A CMS SignedData (RFC 5652): the structure of `.p7m` files (CAdES), of the signatures inside
/// PDF files (PAdES) and of RFC 3161 time-stamp tokens. Read, then checked signer by signer.
struct CMSSignedData {
    struct Signer {
        /// issuerAndSerialNumber, or subjectKeyIdentifier.
        var issuerDER: [UInt8]?
        var serial: [UInt8]?
        var keyID: [UInt8]?
        var digestOID: String
        var signatureOID: String
        var signatureParams: [UInt8]?
        var signature: [UInt8]
        /// The signed attributes as they appear (tag [0]); nil when there are none.
        var signedAttributesRaw: [UInt8]?
        var signedAttributes: [(String, [UInt8])]
        var unsignedAttributes: [(String, [UInt8])]

        func signed(_ oid: String) -> [UInt8]? { signedAttributes.first { $0.0 == oid }?.1 }
        func unsigned(_ oid: String) -> [[UInt8]] { unsignedAttributes.filter { $0.0 == oid }.map(\.1) }
    }

    var contentType: String
    /// nil when detached (the content is elsewhere: a PDF's byte ranges, a .p7s next to the file).
    var content: [UInt8]?
    var certificates: [SignerCertificate]
    /// DER CRLs carried in the message (revocation data).
    var crls: [[UInt8]]
    var signers: [Signer]

    static let signedDataOID = "1.2.840.113549.1.7.2"

    /// Parses a ContentInfo holding a SignedData. Throws when it is not one.
    init(der bytes: [UInt8]) throws {
        let a = ASN1(bytes)
        let ci = try a.children(try a.root())
        guard ci.count == 2, a.oid(ci[0]) == Self.signedDataOID, ci[1].tag == 0xA0, let sdNode = try a.children(ci[1]).first else {
            throw ASN1.Failure.malformed("not a CMS SignedData")
        }
        let sd = try a.children(sdNode)
        guard sd.count >= 4 else { throw ASN1.Failure.malformed("SignedData") }
        let encap = try a.children(sd[2])
        guard let ct = encap.first else { throw ASN1.Failure.malformed("encapContentInfo") }
        contentType = a.oid(ct)
        if encap.count > 1, encap[1].tag == 0xA0, let octets = try a.children(encap[1]).first {
            content = try a.octets(octets)
        } else {
            content = nil
        }
        var certs: [SignerCertificate] = []
        var crls: [[UInt8]] = []
        for n in sd.dropFirst(3) where n.tag == 0xA0 || n.tag == 0xA1 {
            for c in try a.children(n) where c.tag == 0x30 {
                if n.tag == 0xA0 { if let cert = try? SignerCertificate(der: Array(a.raw(c))) { certs.append(cert) } }
                else { crls.append(Array(a.raw(c))) }
            }
        }
        certificates = certs
        self.crls = crls
        guard let infos = sd.last, infos.tag == 0x31 else { throw ASN1.Failure.malformed("signerInfos") }
        signers = try a.children(infos).map { try Self.signer(a, $0) }
    }

    static func signer(_ a: ASN1, _ n: ASN1.Node) throws -> Signer {
        let p = try a.children(n)
        guard p.count >= 5 else { throw ASN1.Failure.malformed("SignerInfo") }
        var s = Signer(digestOID: "", signatureOID: "", signature: [], signedAttributes: [], unsignedAttributes: [])
        let sid = p[1]
        if sid.tag == 0x30 {
            let x = try a.children(sid)
            if x.count == 2 { s.issuerDER = Array(a.raw(x[0])); s.serial = a.integer(x[1]) }
        } else if sid.tag == 0x80 {
            s.keyID = Array(a.content(sid))
        }
        s.digestOID = try a.children(p[2]).first.map { a.oid($0) } ?? ""
        var i = 3
        if p[i].tag == 0xA0 {
            s.signedAttributesRaw = Array(a.raw(p[i]))
            s.signedAttributes = try attributes(a, p[i])
            i += 1
        }
        guard i + 1 < p.count else { throw ASN1.Failure.malformed("SignerInfo") }
        let alg = try a.children(p[i])
        s.signatureOID = alg.first.map { a.oid($0) } ?? ""
        if alg.count > 1 { s.signatureParams = Array(a.raw(alg[1])) }
        s.signature = try a.octets(p[i + 1])
        if i + 2 < p.count, p[i + 2].tag == 0xA1 { s.unsignedAttributes = try attributes(a, p[i + 2]) }
        return s
    }

    /// Attributes as (OID, the first value's encoding).
    static func attributes(_ a: ASN1, _ n: ASN1.Node) throws -> [(String, [UInt8])] {
        try a.children(n).compactMap { attr in
            let x = try a.children(attr)
            guard x.count == 2, let v = try a.children(x[1]).first else { return nil }
            return (a.oid(x[0]), Array(a.raw(v)))
        }
    }

    // MARK: checking one signer

    struct SignerCheck {
        var certificate: SignerCertificate?
        /// The content's digest equals the signed messageDigest (or the signature covers the content).
        var digestMatches = false
        var signatureValid = false
        /// signing-certificate(-v2) names this certificate (CAdES-BES requires it).
        var certificateBound: Bool?
        var signingTime: Date?
        var problems: [String] = []
        var valid: Bool { digestMatches && signatureValid }
    }

    static let messageDigest = "1.2.840.113549.1.9.4", signingTime = "1.2.840.113549.1.9.5"
    static let signingCertificate = "1.2.840.113549.1.9.16.2.12", signingCertificateV2 = "1.2.840.113549.1.9.16.2.47"
    static let timeStampToken = "1.2.840.113549.1.9.16.2.14", counterSignature = "1.2.840.113549.1.9.6"

    /// Checks `signer` over `content` (the attached one, or the detached bytes given).
    func check(_ signer: Signer, content detached: [UInt8]? = nil) -> SignerCheck {
        var r = SignerCheck()
        guard let data = detached ?? content else { r.problems.append("the signed content is missing (detached signature)"); return r }
        guard let hash = Self.hash(signer.digestOID) else { r.problems.append("digest algorithm \(signer.digestOID) not supported"); return r }
        let digest = hash(data)
        r.certificate = certificates.first { c in
            if let k = signer.keyID { return c.subjectKeyID == k }
            return c.issuerDER == signer.issuerDER && c.serial == signer.serial
        }
        guard let cert = r.certificate, let key = cert.secKey else { r.problems.append("the signer's certificate is not in the signature"); return r }
        let message: [UInt8]
        if let raw = signer.signedAttributesRaw {
            // The signature covers the attributes as a DER SET.
            message = [0x31] + raw.dropFirst()
            if let md = signer.signed(Self.messageDigest).flatMap({ v -> [UInt8]? in
                let a = ASN1(v)
                return (try? a.root()).map { Array(a.content($0)) }
            }) {
                r.digestMatches = md == digest
                if !r.digestMatches { r.problems.append("the content does not match the signature (changed after signing)") }
            } else {
                r.problems.append("no message digest among the signed attributes")
            }
            if let t = signer.signed(Self.signingTime) { let a = ASN1(t); r.signingTime = (try? a.root()).flatMap { a.time($0) } }
            r.certificateBound = Self.boundCertificate(signer, cert)
        } else {
            message = data
            r.digestMatches = true
        }
        r.signatureValid = Self.verifySignature(key: key, digestOID: signer.digestOID, signatureOID: signer.signatureOID,
                                                params: signer.signatureParams, message: message, signature: signer.signature)
        if !r.signatureValid { r.problems.append("the signature does not verify with the signer's certificate") }
        return r
    }

    /// ESSCertIDv2 / ESSCertID: the hash of the signer's certificate, in the signed attributes.
    static func boundCertificate(_ s: Signer, _ cert: SignerCertificate) -> Bool? {
        func firstHash(_ v: [UInt8], defaultSHA256: Bool) -> (String, [UInt8])? {
            let a = ASN1(v)
            guard let root = try? a.root(), let certs = try? a.children(root).first,
                  let first = try? a.children(certs).first, let parts = try? a.children(first), !parts.isEmpty else { return nil }
            if parts[0].tag == 0x30, parts.count > 1 {  // v2 with an explicit algorithm
                let alg = (try? a.children(parts[0]).first).flatMap { $0 }.map { a.oid($0) } ?? "2.16.840.1.101.3.4.2.1"
                return (alg, Array(a.content(parts[1])))
            }
            return (defaultSHA256 ? "2.16.840.1.101.3.4.2.1" : "1.3.14.3.2.26", Array(a.content(parts[0])))
        }
        if let v = s.signed(signingCertificateV2), let (alg, h) = firstHash(v, defaultSHA256: true), let f = hash(alg) { return f(cert.der) == h }
        if let v = s.signed(signingCertificate), let (alg, h) = firstHash(v, defaultSHA256: false), let f = hash(alg) { return f(cert.der) == h }
        return nil
    }

    static func hash(_ oid: String) -> (([UInt8]) -> [UInt8])? {
        switch oid {
        case "2.16.840.1.101.3.4.2.1": { Array(SHA256.hash(data: $0)) }
        case "2.16.840.1.101.3.4.2.2": { Array(SHA384.hash(data: $0)) }
        case "2.16.840.1.101.3.4.2.3": { Array(SHA512.hash(data: $0)) }
        case "1.3.14.3.2.26": { Array(Insecure.SHA1.hash(data: $0)) }
        default: nil
        }
    }

    /// RSA PKCS#1 v1.5, RSA-PSS and ECDSA, with the digest named by the signer or by the signature OID.
    static func verifySignature(key: SecKey, digestOID: String, signatureOID: String, params: [UInt8]?, message: [UInt8], signature: [UInt8]) -> Bool {
        let digestName: String
        switch signatureOID {
        case "1.2.840.113549.1.1.11", "1.2.840.10045.4.3.2": digestName = "256"
        case "1.2.840.113549.1.1.12", "1.2.840.10045.4.3.3": digestName = "384"
        case "1.2.840.113549.1.1.13", "1.2.840.10045.4.3.4": digestName = "512"
        case "1.2.840.113549.1.1.5", "1.2.840.10045.4.1": digestName = "1"
        default:
            switch digestOID {
            case "2.16.840.1.101.3.4.2.2": digestName = "384"
            case "2.16.840.1.101.3.4.2.3": digestName = "512"
            case "1.3.14.3.2.26": digestName = "1"
            default: digestName = "256"
            }
        }
        let ecdsa = signatureOID.hasPrefix("1.2.840.10045.")
        let pss = signatureOID == "1.2.840.113549.1.1.10"
        let algorithm: SecKeyAlgorithm
        switch (ecdsa, pss, digestName) {
        case (true, _, "1"): algorithm = .ecdsaSignatureMessageX962SHA1
        case (true, _, "384"): algorithm = .ecdsaSignatureMessageX962SHA384
        case (true, _, "512"): algorithm = .ecdsaSignatureMessageX962SHA512
        case (true, _, _): algorithm = .ecdsaSignatureMessageX962SHA256
        case (_, true, "384"): algorithm = .rsaSignatureMessagePSSSHA384
        case (_, true, "512"): algorithm = .rsaSignatureMessagePSSSHA512
        case (_, true, "1"): algorithm = .rsaSignatureMessagePSSSHA1
        case (_, true, _): algorithm = .rsaSignatureMessagePSSSHA256
        case (_, _, "1"): algorithm = .rsaSignatureMessagePKCS1v15SHA1
        case (_, _, "384"): algorithm = .rsaSignatureMessagePKCS1v15SHA384
        case (_, _, "512"): algorithm = .rsaSignatureMessagePKCS1v15SHA512
        default: algorithm = .rsaSignatureMessagePKCS1v15SHA256
        }
        return SecKeyVerifySignature(key, algorithm, Data(message) as CFData, Data(signature) as CFData, nil)
    }
}
