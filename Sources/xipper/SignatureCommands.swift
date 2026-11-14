// Signed documents on the command line (3.3): .p7m (CAdES), signed PDF (PAdES), ASiC.
import Darwin
import Foundation
import Security
import XipperKit

let sigUsage = """
  sig verify [--online] [--country CC | --no-trusted-list] [--json] <file>
                                  check every signature of a .p7m, a signed PDF or an ASiC container:
                                  integrity, signer, time, qualified or not (EU trusted list), revocation.
                                  --online: download the trusted list and ask OCSP/CRL services
                                  (otherwise the cached list and the revocation data inside the file)
  sig extract [-o FILE] <file.p7m>  the signed document inside a .p7m (also nested), without checking
  sig sign --certificate NAME [--parallel | --nested] [--timestamp URL [--tsa-user USER]]
           [-o FILE] [--overwrite] <file>
                                  sign as .p7m (CAdES-BES; CAdES-T with --timestamp) with a certificate in
                                  the Keychain or on a smart card (the card may ask for its PIN).
                                  A plain file becomes FILE.p7m; for a .p7m, --parallel adds a signer in
                                  place, --nested wraps it (.p7m.p7m). The TSA password: XIPPER_TSA_PASSWORD
                                  or asked on the terminal
  sig certificates                the signing certificates available (Keychain, smart cards)
"""

@MainActor func runSignature() -> Never {
    guard let sub = positional.first, ["verify", "extract", "sign", "certificates"].contains(sub),
          positional.count == (sub == "certificates" ? 1 : 2) else { fail(sigUsage, code: 2) }
    if sub == "certificates" {
        let ids = XizCertificateSigner.identities()
        if ids.isEmpty { fputs("xipper: no signing certificates (Keychain, smart cards)\n", stderr); exit(1) }
        // Certificate only (no private key is touched): which ones are for signing documents.
        for i in ids {
            var c: SecCertificate?
            SecIdentityCopyCertificate(i.identity, &c)
            let cert = c.flatMap { try? SignerCertificate(der: Array(SecCertificateCopyData($0) as Data)) }
            var tags: [String] = []
            if cert?.nonRepudiation == true { tags.append("non-repudiation") }
            if cert?.qcCompliance == true { tags.append("qualified") }
            if let c = cert, !c.isValid(at: Date()) { tags.append("expired") }
            print(i.name + (tags.isEmpty ? "" : "  [" + tags.joined(separator: ", ") + "]"))
        }
        exit(0)
    }
    let url = URL(fileURLWithPath: positional[1])
    if sub == "extract" {
        do {
            let (name, data) = try Xipper.signedContent(url)
            let out = value("-o", "--output") ?? url.deletingLastPathComponent().appendingPathComponent(name).path
            if FileManager.default.fileExists(atPath: out) { fail("\(out) exists: choose another name with -o") }
            try Data(data).write(to: URL(fileURLWithPath: out))
            print(out)
            exit(0)
        } catch { fail("\(error)") }
    }
    if sub == "sign" { signDocument(url) }
    let online = flag("--online")
    var tl: TrustedList?
    if !flag("--no-trusted-list") {
        let cc = (value("--country") ?? "IT").uppercased()
        tl = online ? (try? TrustedList.load(country: cc)) : TrustedList.cached(country: cc)
        if tl == nil && !online { fputs("xipper: no cached trusted list for \(cc): qualified status not checked (use --online)\n", stderr) }
    }
    let doc: SignedDocument
    do { doc = try Xipper.verifySignedDocument(url, options: SignatureCheckOptions(trustedList: tl, online: online)) } catch { fail("\(error)") }
    let iso = ISO8601DateFormatter()
    if flag("--json") {
        let sigs: [[String: Any]] = doc.signatures.map { s in
            var d: [String: Any] = ["kind": s.kind.rawValue, "level": s.level.rawValue, "integrity": s.integrity, "depth": s.depth,
                                    "certificate_valid": s.certificateValidAtSigning, "problems": s.problems,
                                    "reference_time": iso.string(from: s.referenceTime), "revocation": describe(s.revocation),
                                    "covers_whole_file": s.coversWholeFile]
            if let c = s.signer {
                d["signer"] = c.subject.display
                d["tax_code"] = c.taxCode ?? ""
                d["organization"] = c.subject.organization ?? ""
                d["issuer"] = c.issuer.display
                d["certificate_sha256"] = c.sha256
                d["not_after"] = iso.string(from: c.notAfter)
            }
            if let t = s.claimedTime { d["claimed_time"] = iso.string(from: t) }
            if let ts = s.timestamp {
                d["timestamp"] = ["time": iso.string(from: ts.time), "authority": ts.authority, "valid": ts.valid, "qualified": ts.qualified]
            }
            if let q = s.qualifiedAuthority { d["qualified_authority"] = q }
            return d
        }
        var root: [String: Any] = ["file": url.lastPathComponent, "format": doc.format.rawValue, "level": doc.level.rawValue,
                                   "valid": doc.allValid, "document": doc.contentName, "signatures": sigs]
        if let t = doc.trustedList { root["trusted_list"] = t }
        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
        exit(doc.allValid ? 0 : 3)
    }
    print("\(url.lastPathComponent): \(doc.format.rawValue), document \(doc.contentName)")
    for (i, s) in doc.signatures.enumerated() {
        let who = s.signer.map { c in [c.subject.display, c.taxCode.map { "CF \($0)" }, c.subject.organization].compactMap { $0 }.joined(separator: ", ") } ?? "?"
        let kind = s.kind == .documentTimestamp ? "document time-stamp" : "signature"
        print("\n#\(i + 1) \(kind)\(s.depth > 0 && doc.format == .p7m ? " (nested, level \(s.depth))" : "")  \(label(s.level))")
        if s.kind == .signature { print("  signer       \(who)") }
        if let c = s.signer { print("  issued by    \(c.issuer.display)\(s.qualifiedAuthority.map { "  [qualified: \($0)]" } ?? "")") }
        if let ts = s.timestamp {
            print("  time-stamp   \(iso.string(from: ts.time)) by \(ts.authority)\(ts.qualified ? " (qualified)" : "")\(ts.valid ? "" : " INVALID")")
        }
        if let t = s.claimedTime { print("  signing time \(iso.string(from: t)) (declared by the signer's computer)") }
        print("  integrity    \(s.integrity ? "ok" : "FAILED")")
        if s.signer != nil { print("  certificate  \(s.certificateValidAtSigning ? "valid at the time of signing" : "NOT valid at the time of signing")") }
        print("  revocation   \(describe(s.revocation))")
        for p in s.problems { print("  ! \(p)") }
    }
    if let t = doc.trustedList { print("\ntrusted list: \(t["country"] ?? "") sequence \(t["sequence"] ?? ""), SHA-256 \(t["sha256"] ?? "")") }
    exit(doc.allValid ? 0 : 3)
}

func label(_ l: SignatureLevel) -> String {
    switch l {
    case .qualified: "QUALIFIED electronic signature (QES)"
    case .qualifiedCertificate: "advanced, qualified certificate (no QSCD)"
    case .advanced: "advanced (trusted certificate, not qualified)"
    case .untrustedSigner: "signer not trusted (certificate unknown to this Mac and to the list)"
    case .invalid: "INVALID"
    }
}

func describe(_ r: RevocationStatus) -> String {
    let iso = ISO8601DateFormatter()
    switch r {
    case let .notChecked(why): return "not checked (\(why))"
    case let .good(source): return "not revoked (\(source))"
    case let .revoked(date, source): return "REVOKED\(date.map { " on \(iso.string(from: $0))" } ?? "") (\(source))"
    case let .revokedLater(date, source): return "revoked after the signature, on \(iso.string(from: date)) (\(source))"
    case let .unknown(why): return "unknown (\(why))"
    }
}

@MainActor func signDocument(_ url: URL) -> Never {
    guard let name = value("--certificate") else { fail("sig sign needs --certificate NAME (see: xipper sig certificates)", code: 2) }
    if flag("--parallel") && flag("--nested") { fail("--parallel or --nested, not both", code: 2) }
    let mode: DocumentSignatureMode = flag("--parallel") ? .parallel : flag("--nested") ? .nested : .new
    guard let identity = XizCertificateSigner.identity(named: name) else { fail("no signing certificate \"\(name)\" (see: xipper sig certificates)") }
    var timestamp: TimestampSource?
    if let t = value("--timestamp") {
        guard let u = URL(string: t), u.scheme == "https" || u.scheme == "http" else { fail("invalid time-stamp URL \(t)", code: 2) }
        var credentials: (user: String, password: String)?
        if let user = value("--tsa-user") {
            let pw = ProcessInfo.processInfo.environment["XIPPER_TSA_PASSWORD"] ?? getpass("Password for \(user) at \(u.host ?? t): ").map { String(cString: $0) }
            guard let pw, !pw.isEmpty else { fail("no time-stamp password") }
            credentials = (user, pw)
        }
        timestamp = .authority(u, credentials: credentials)
    } else if value("--tsa-user") != nil { fail("--tsa-user needs --timestamp", code: 2) }
    do {
        let signer = try XizCertificateSigner(identity: identity)
        let out = try Xipper.signDocument(url, output: value("-o", "--output").map { URL(fileURLWithPath: $0) }, mode: mode,
                                          signer: signer, timestamp: timestamp, overwrite: flag("--overwrite"))
        print(out.path)
        exit(0)
    } catch { fail("\(error)") }
}
