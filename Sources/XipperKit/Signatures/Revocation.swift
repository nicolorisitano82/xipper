import CryptoKit
import Foundation
import Security

/// Whether a signer's certificate was revoked: CRLs carried in the signature first (always), then,
/// only with the user's consent, OCSP and CRL from the addresses in the certificate. What matters is
/// the status at the signature's time: a certificate revoked afterwards leaves the signature standing.
enum Revocation {
    static func status(_ cert: SignerCertificate, chain: [SignerCertificate], embeddedCRLs: [[UInt8]], at time: Date,
                       online: Bool) -> RevocationStatus {
        let issuer = chain.first { $0.subjectDER == cert.issuerDER && $0 != cert }
        for der in embeddedCRLs {
            if let r = checkCRL(der, cert: cert, issuer: issuer, at: time, source: "CRL in the signature") { return r }
        }
        if cert.ocspURLs.isEmpty && cert.crlURLs.isEmpty { return .notChecked("the certificate names no revocation service") }
        guard online else { return .notChecked("online checks not allowed") }
        var issuerCert = issuer
        if issuerCert == nil {
            for u in cert.issuerURLs {
                if let url = URL(string: u), let d = fetch(url), let c = try? SignerCertificate(der: d) { issuerCert = c; break }
            }
        }
        if let issuerCert {
            for u in cert.ocspURLs {
                if let url = URL(string: u), let r = ocsp(url, cert: cert, issuer: issuerCert, at: time) { return r }
            }
        }
        for u in cert.crlURLs where u.hasPrefix("http") {
            if let url = URL(string: u), let d = fetch(url),
               let r = checkCRL(d, cert: cert, issuer: issuerCert, at: time, source: "CRL from \(url.host() ?? u)") { return r }
        }
        return .unknown("no revocation service answered")
    }

    // MARK: CRL

    /// nil when the CRL is not from the certificate's issuer or does not verify.
    static func checkCRL(_ der: [UInt8], cert: SignerCertificate, issuer: SignerCertificate?, at time: Date, source: String) -> RevocationStatus? {
        let a = ASN1(der)
        guard let root = try? a.root(), let parts = try? a.children(root), parts.count == 3,
              var tbs = try? a.children(parts[0]) else { return nil }
        if tbs.first?.tag == 0x02 { tbs.removeFirst() }  // version
        guard tbs.count >= 3, Array(a.raw(tbs[1])) == cert.issuerDER else { return nil }
        // Its signature, with the issuer's key (the CRL is worthless otherwise).
        guard let key = issuer?.secKey, let algNode = (try? a.children(parts[1]))?.first,
              CMSSignedData.verifySignature(key: key, digestOID: "", signatureOID: a.oid(algNode), params: nil,
                                            message: Array(a.raw(parts[0])), signature: Array(a.content(parts[2]).dropFirst())) else { return nil }
        for n in tbs.dropFirst(3) where n.tag == 0x30 {
            for entry in (try? a.children(n)) ?? [] {
                let e = (try? a.children(entry)) ?? []
                guard e.count >= 2, a.integer(e[0]) == cert.serial else { continue }
                let when = a.time(e[1])
                if let when, when > time { return .revokedLater(date: when, source: source) }
                return .revoked(date: when, source: source)
            }
        }
        return .good(source: source)
    }

    // MARK: OCSP (RFC 6960)

    static func ocsp(_ url: URL, cert: SignerCertificate, issuer: SignerCertificate, at time: Date) -> RevocationStatus? {
        guard let keyBits = issuerKeyBits(issuer) else { return nil }
        let sha1 = DER.seq(DER.oid([1, 3, 14, 3, 2, 26]) + [0x05, 0x00])
        let certID = DER.seq(sha1 + DER.tlv(0x04, Array(Insecure.SHA1.hash(data: issuer.subjectDER)))
                             + DER.tlv(0x04, Array(Insecure.SHA1.hash(data: keyBits))) + DER.integer(cert.serial))
        let request = DER.seq(DER.seq(DER.seq(DER.seq(certID))))
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/ocsp-request", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(request)
        guard let body = send(req) else { return nil }
        // OCSPResponse { status ENUMERATED, [0] { ResponseBytes { oid, OCTET STRING BasicOCSPResponse } } }
        let a = ASN1(body)
        guard let root = try? a.root(), let top = try? a.children(root), top.count == 2, a.content(top[0]).first == 0,
              let rb = try? a.children(top[1]).first, let rbParts = try? a.children(rb), rbParts.count == 2,
              let basicBytes = try? a.octets(rbParts[1]) else { return nil }
        let b = ASN1(basicBytes)
        guard let broot = try? b.root(), let basic = try? b.children(broot), basic.count >= 3,
              let tbs = try? b.children(basic[0]) else { return nil }
        // The response's signature: by the issuer, or by a responder certificate the issuer signed.
        let sigOID = (try? b.children(basic[1]).first).flatMap { $0 }.map { b.oid($0) } ?? ""
        let message = Array(b.raw(basic[0]))
        let signature = Array(b.content(basic[2]).dropFirst())
        var signers: [SignerCertificate] = [issuer]
        if basic.count > 3, let certs = try? b.children(basic[3]).first, let list = try? b.children(certs) {
            for n in list {
                if let c = try? SignerCertificate(der: Array(b.raw(n))), c.issuerDER == issuer.subjectDER, signedBy(c, issuer) { signers.append(c) }
            }
        }
        guard signers.contains(where: { s in s.secKey.map { CMSSignedData.verifySignature(key: $0, digestOID: "", signatureOID: sigOID, params: nil, message: message, signature: signature) } ?? false })
        else { return .unknown("the OCSP answer from \(url.host() ?? "") does not verify") }
        let source = "OCSP \(url.host() ?? "")"
        guard let responses = tbs.first(where: { $0.tag == 0x30 && (try? b.children($0).first?.tag) == 0x30 }),
              let list = try? b.children(responses) else { return nil }
        for single in list {
            let s = (try? b.children(single)) ?? []
            guard s.count >= 3, let id = try? b.children(s[0]), id.count == 4, b.integer(id[3]) == cert.serial else { continue }
            switch s[1].tag {
            case 0x80: return .good(source: source)
            case 0xA1:
                let when = (try? b.children(s[1]).first).flatMap { $0 }.flatMap { b.time($0) }
                if let when, when > time { return .revokedLater(date: when, source: source) }
                return .revoked(date: when, source: source)
            default: return .unknown("\(source): status unknown")
            }
        }
        return nil
    }

    /// The issuer's public key bits (subjectPublicKeyInfo's BIT STRING, without the unused-bits byte).
    static func issuerKeyBits(_ c: SignerCertificate) -> [UInt8]? {
        let a = ASN1(c.der)
        guard let root = try? a.root(), let cert = try? a.children(root), var tbs = try? a.children(cert[0]) else { return nil }
        if tbs.first?.tag == 0xA0 { tbs.removeFirst() }
        guard tbs.count >= 6, let spki = try? a.children(tbs[5]), spki.count == 2 else { return nil }
        return Array(a.content(spki[1]).dropFirst())
    }

    /// Whether `issuer` signed `c` (its signature over the TBS part).
    static func signedBy(_ c: SignerCertificate, _ issuer: SignerCertificate) -> Bool {
        let a = ASN1(c.der)
        guard let root = try? a.root(), let p = try? a.children(root), p.count == 3, let key = issuer.secKey,
              let oid = (try? a.children(p[1]).first).flatMap({ $0 }).map({ a.oid($0) }) else { return false }
        return CMSSignedData.verifySignature(key: key, digestOID: "", signatureOID: oid, params: nil,
                                             message: Array(a.raw(p[0])), signature: Array(a.content(p[2]).dropFirst()))
    }

    // MARK: network (only with consent: callers pass online = true)

    static func fetch(_ url: URL) -> [UInt8]? {
        guard url.scheme == "http" || url.scheme == "https" else { return nil }
        return send(URLRequest(url: url, timeoutInterval: 15))
    }

    static func send(_ req: URLRequest) -> [UInt8]? {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out: [UInt8]?
        URLSession.shared.dataTask(with: req) { d, r, _ in
            if let h = r as? HTTPURLResponse, h.statusCode == 200, let d { out = Array(d) }
            done.signal()
        }.resume()
        done.wait()
        return out
    }
}
