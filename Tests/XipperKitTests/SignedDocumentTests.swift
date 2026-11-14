import CryptoKit
import Foundation
import Testing
@testable import XipperKit

/// Signed documents (3.3, phase A): `.p7m` made by OpenSSL with a small test PKI: a root, a CA,
/// a "qualified" signer (QCStatements, non-repudiation, tax code), an ECDSA signer, an untrusted one.
let opensslTool = ["/opt/homebrew/opt/openssl@3/bin/openssl", "/usr/local/opt/openssl@3/bin/openssl"].first(where: toolExists)

@Suite("Signed documents (.p7m)", .enabled(if: opensslTool != nil), .serialized)
struct SignedDocumentTests {
    static let openssl = opensslTool

    /// The test PKI, built once per run.
    final class PKI: @unchecked Sendable {
        let dir: TempDir
        init() throws {
            dir = TempDir()
            let o = SignedDocumentTests.openssl!
            let cnf = """
            [req]
            distinguished_name = dn
            [dn]
            [root]
            basicConstraints = critical,CA:true
            keyUsage = critical,keyCertSign,cRLSign
            subjectKeyIdentifier = hash
            [qualified]
            basicConstraints = CA:false
            keyUsage = critical,nonRepudiation
            subjectKeyIdentifier = hash
            authorityKeyIdentifier = keyid
            qcStatements = DER:30143008060604008e4601013008060604008e460104
            [plain]
            basicConstraints = CA:false
            keyUsage = critical,digitalSignature,nonRepudiation
            subjectKeyIdentifier = hash
            authorityKeyIdentifier = keyid
            """
            dir.write("openssl.cnf", cnf)
            let p = dir.path
            func sh(_ args: [String]) throws {
                let r = run(o, args, cwd: p)
                guard r.status == 0 else { throw XipperError.io("openssl \(args.first ?? ""): \(r.output)", path: p, errno: 0) }
            }
            try sh(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.pem", "-days", "3650",
                    "-subj", "/C=IT/O=Test Trust Service/CN=Test Qualified CA", "-config", "openssl.cnf", "-extensions", "root"])
            try sh(["req", "-newkey", "rsa:2048", "-nodes", "-keyout", "ada.key", "-out", "ada.csr", "-config", "openssl.cnf",
                    "-subj", "/C=IT/GN=Ada/SN=Rossi/serialNumber=TINIT-RSSDAA80A41H501X/CN=Ada Rossi"])
            try sh(["x509", "-req", "-in", "ada.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-out", "ada.pem",
                    "-days", "730", "-extfile", "openssl.cnf", "-extensions", "qualified"])
            try sh(["req", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes", "-keyout", "bruno.key", "-out", "bruno.csr",
                    "-config", "openssl.cnf", "-subj", "/C=IT/CN=Bruno Bianchi"])
            try sh(["x509", "-req", "-in", "bruno.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-out", "bruno.pem",
                    "-days", "730", "-extfile", "openssl.cnf", "-extensions", "plain"])
            try sh(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "self.key", "-out", "self.pem", "-days", "30",
                    "-subj", "/CN=Self Signed", "-config", "openssl.cnf", "-extensions", "plain"])
        }

        func sign(_ input: String, _ output: String, signer: String, extra: [String] = []) throws {
            let r = run(SignedDocumentTests.openssl!, ["cms", "-sign", "-binary", "-nodetach", "-cades", "-md", "sha256", "-in", input,
                                                       "-signer", "\(signer).pem", "-inkey", "\(signer).key", "-certfile", "ca.pem",
                                                       "-outform", "DER", "-out", output] + extra, cwd: dir.path)
            guard r.status == 0 else { throw XipperError.io("openssl cms: \(r.output)", path: dir.path, errno: 0) }
        }

        var caDER: [UInt8] {
            let pem = (try? String(contentsOfFile: dir.path + "/ca.pem", encoding: .utf8)) ?? ""
            let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
            return Array(Data(base64Encoded: body) ?? Data())
        }

        /// A trusted list naming the test CA as a granted CA/QC service, with the given qualifiers.
        func trustedList(qualifiers: [String] = ["QCWithQSCD"], status: String = "granted") throws -> TrustedList {
            let q = qualifiers.map { "<Qualifier uri=\"http://uri.etsi.org/TrstSvc/TrustedList/SvcInfoExt/\($0)\"/>" }.joined()
            let xml = """
            <TrustServiceStatusList xmlns="http://uri.etsi.org/02231/v2#"><SchemeInformation><TSLSequenceNumber>1</TSLSequenceNumber>
            <ListIssueDateTime>2026-01-01T00:00:00Z</ListIssueDateTime></SchemeInformation><TrustServiceProviderList>
            <TrustServiceProvider><TSPInformation><TSPName><Name xml:lang="en">Test Trust Service</Name></TSPName></TSPInformation>
            <TSPServices><TSPService><ServiceInformation><ServiceTypeIdentifier>http://uri.etsi.org/TrstSvc/Svctype/CA/QC</ServiceTypeIdentifier>
            <ServiceName><Name xml:lang="en">Test Qualified CA</Name></ServiceName><ServiceDigitalIdentity><DigitalId>
            <X509Certificate>\(Data(caDER).base64EncodedString())</X509Certificate></DigitalId></ServiceDigitalIdentity>
            <ServiceStatus>http://uri.etsi.org/TrstSvc/TrustedList/Svcstatus/\(status)</ServiceStatus>
            <StatusStartingTime>2020-01-01T00:00:00Z</StatusStartingTime><ServiceInformationExtensions><Extension>
            <Qualifications><QualificationElement><Qualifiers>\(q)</Qualifiers></QualificationElement></Qualifications>
            </Extension></ServiceInformationExtensions></ServiceInformation></TSPService></TSPServices></TrustServiceProvider>
            </TrustServiceProviderList></TrustServiceStatusList>
            """
            return try TrustedList(xml: Data(xml.utf8), country: "IT", url: URL(string: "https://example.test/tl.xml")!)
        }
    }

    static let pki = Result { try PKI() }

    func doc(_ p: PKI, _ name: String, _ text: String = "Contratto di prova\n") -> String {
        p.dir.write(name, text)
        return name
    }

    @Test func certificateFieldsAreRead() throws {
        let p = try Self.pki.get()
        let pem = try String(contentsOfFile: p.dir.path + "/ada.pem", encoding: .utf8)
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        let c = try SignerCertificate(der: Array(Data(base64Encoded: body)!))
        #expect(c.subject.display == "Ada Rossi" && c.taxCode == "RSSDAA80A41H501X" && c.subject.country == "IT")
        #expect(c.issuer.commonName == "Test Qualified CA")
        #expect(c.nonRepudiation && c.keyUsagePresent && c.qcCompliance && c.qcSSCD)
        #expect(c.subjectKeyID != nil && c.authorityKeyID != nil)
    }

    @Test func qualifiedSignatureWithTheTrustedList() throws {
        let p = try Self.pki.get()
        try p.sign(doc(p, "contratto.pdf"), "contratto.pdf.p7m", signer: "ada")
        let url = p.dir.url("contratto.pdf.p7m")
        #expect(Xipper.isSignedDocument(url))
        let d = try Xipper.verifySignedDocument(url, options: SignatureCheckOptions(trustedList: try p.trustedList()))
        #expect(d.format == .p7m && d.contentName == "contratto.pdf" && d.content == Array("Contratto di prova\n".utf8))
        let s = try #require(d.signatures.first)
        #expect(d.signatures.count == 1 && s.integrity && s.certificateBound == true && s.certificateValidAtSigning)
        #expect(s.level == .qualified, "\(s.level) \(s.problems)")
        #expect(s.qualifiedAuthority?.contains("Test Qualified CA") == true && s.signer?.taxCode == "RSSDAA80A41H501X")
        #expect(s.claimedTime != nil)
        if case .notChecked = s.revocation {} else { Issue.record("revocation should be not checked offline: \(s.revocation)") }
    }

    @Test func levelsFollowTheListAndTheCertificate() throws {
        let p = try Self.pki.get()
        try p.sign(doc(p, "a.txt"), "a.txt.p7m", signer: "ada")
        try p.sign(doc(p, "b.txt"), "b.txt.p7m", signer: "bruno")
        try p.sign(doc(p, "c.txt"), "c.txt.p7m", signer: "self")
        func level(_ f: String, _ tl: TrustedList?) throws -> SignatureLevel {
            try Xipper.verifySignedDocument(p.dir.url(f), options: SignatureCheckOptions(trustedList: tl)).level
        }
        #expect(try level("a.txt.p7m", nil) == .untrustedSigner)  // no list: the test CA is unknown to this Mac
        #expect(try level("a.txt.p7m", try p.trustedList(qualifiers: ["QCNoQSCD"])) == .qualifiedCertificate)
        #expect(try level("a.txt.p7m", try p.trustedList(status: "withdrawn")) == .untrustedSigner)
        // ECDSA, no QcCompliance in the certificate: qualified only when the list says so (QCStatement).
        #expect(try level("b.txt.p7m", try p.trustedList()) == .advanced)
        #expect(try level("b.txt.p7m", try p.trustedList(qualifiers: ["QCStatement", "QCWithQSCD"])) == .qualified)
        #expect(try level("b.txt.p7m", try p.trustedList(qualifiers: ["QCStatement"])) == .qualifiedCertificate)
        #expect(try level("c.txt.p7m", try p.trustedList()) == .untrustedSigner)
    }

    @Test func nestedAndBase64() throws {
        let p = try Self.pki.get()
        try p.sign(doc(p, "n.pdf", "documento\n"), "n.pdf.p7m", signer: "ada")
        try p.sign("n.pdf.p7m", "n.pdf.p7m.p7m", signer: "bruno")
        let d = try Xipper.verifySignedDocument(p.dir.url("n.pdf.p7m.p7m"), options: SignatureCheckOptions(trustedList: try p.trustedList()))
        #expect(d.contentName == "n.pdf" && d.content == Array("documento\n".utf8))
        #expect(d.signatures.map(\.depth) == [0, 1] && d.signatures.map { $0.signer?.subject.display } == ["Bruno Bianchi", "Ada Rossi"])
        #expect(d.allValid)
        // The same file as base64 (some systems send p7m that way), and as PEM.
        let der = try Data(contentsOf: p.dir.url("n.pdf.p7m"))
        p.dir.write("b64.pdf.p7m", der.base64EncodedString(options: .lineLength64Characters))
        p.dir.write("pem.pdf.p7m", "-----BEGIN PKCS7-----\n" + der.base64EncodedString(options: .lineLength64Characters) + "\n-----END PKCS7-----\n")
        for f in ["b64.pdf.p7m", "pem.pdf.p7m"] {
            let x = try Xipper.verifySignedDocument(p.dir.url(f))
            #expect(x.content == Array("documento\n".utf8) && x.signatures.first?.integrity == true, "\(f)")
        }
    }

    @Test func tamperingIsDetected() throws {
        let p = try Self.pki.get()
        try p.sign(doc(p, "t.txt", "importo: 1000 euro\n"), "t.txt.p7m", signer: "ada")
        var b = try [UInt8](Data(contentsOf: p.dir.url("t.txt.p7m")))
        let needle = Array("1000".utf8)
        let at = try #require((0..<(b.count - 4)).first { Array(b[$0..<($0 + 4)]) == needle })
        b.replaceSubrange(at..<(at + 4), with: Array("9000".utf8))
        try Data(b).write(to: p.dir.url("t2.txt.p7m"))
        let d = try Xipper.verifySignedDocument(p.dir.url("t2.txt.p7m"), options: SignatureCheckOptions(trustedList: try p.trustedList()))
        let s = try #require(d.signatures.first)
        #expect(!s.integrity && s.level == .invalid && !d.allValid)
        #expect(s.problems.contains { $0.contains("does not match") })
        // A flipped bit in the signature value itself.
        var c = try [UInt8](Data(contentsOf: p.dir.url("t.txt.p7m")))
        c[c.count - 20] ^= 0x01
        try Data(c).write(to: p.dir.url("t3.txt.p7m"))
        if let x = try? Xipper.verifySignedDocument(p.dir.url("t3.txt.p7m")) { #expect(x.signatures.allSatisfy { !$0.integrity }) }
    }

    @Test func hostileInputNeverCrashes() throws {
        let p = try Self.pki.get()
        try p.sign(doc(p, "h.txt"), "h.txt.p7m", signer: "ada")
        let good = try [UInt8](Data(contentsOf: p.dir.url("h.txt.p7m")))
        var x: UInt64 = 0x51CA
        for k in 0..<1500 {
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            var b = good
            switch k % 3 {
            case 0: b[Int(x % UInt64(b.count))] ^= UInt8(truncatingIfNeeded: x >> 20) | 1
            case 1: b.removeLast(Int(x % UInt64(b.count)))
            default: for _ in 0..<6 { b[Int(UInt64(b.count - 1) & (x >> UInt64(k % 40)))] = UInt8(truncatingIfNeeded: x) ; x = x &* 6364136223846793005 &+ 1 }
            }
            _ = try? SignedDocuments.verifyP7M(b, name: "h.p7m", options: SignatureCheckOptions())
        }
        // An indefinite-length (BER) nest of 100 levels: refused, not a stack overflow.
        let deep = Array(repeating: [UInt8]([0x30, 0x80]), count: 100).flatMap { $0 } + [UInt8](repeating: 0, count: 200)
        #expect(throws: (any Error).self) { _ = try SignedDocuments.verifyP7M(deep, name: "d.p7m", options: SignatureCheckOptions()) }
    }

    /// Revocation against a real authority made with OpenSSL: a CRL that revokes a certificate,
    /// and an OCSP responder on localhost asked the way Xipper does online.
    @Test func revocationByCRLAndOCSP() throws {
        let p = try Self.pki.get()
        let o = Self.openssl!
        let dir = p.dir.path
        let port = 20000 + Int.random(in: 0..<20000)
        p.dir.write("ca.cnf", """
        [ca]
        default_ca = test
        [test]
        database = index.txt
        crlnumber = crlnumber
        default_md = sha256
        default_crl_days = 30
        [carla]
        basicConstraints = CA:false
        keyUsage = critical,nonRepudiation
        authorityInfoAccess = OCSP;URI:http://127.0.0.1:\(port)/
        """)
        p.dir.write("index.txt", "")
        p.dir.write("crlnumber", "01\n")
        func sh(_ a: [String]) throws {
            let r = run(o, a, cwd: dir)
            guard r.status == 0 else { throw XipperError.io("openssl \(a.first ?? ""): \(r.output)", path: dir, errno: 0) }
        }
        try sh(["req", "-newkey", "rsa:2048", "-nodes", "-keyout", "carla.key", "-out", "carla.csr", "-config", "openssl.cnf", "-subj", "/CN=Carla Verdi"])
        try sh(["x509", "-req", "-in", "carla.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-out", "carla.pem",
                "-days", "365", "-extfile", "ca.cnf", "-extensions", "carla"])
        try sh(["ca", "-config", "ca.cnf", "-revoke", "carla.pem", "-keyfile", "ca.key", "-cert", "ca.pem"])
        try sh(["ca", "-config", "ca.cnf", "-gencrl", "-keyfile", "ca.key", "-cert", "ca.pem", "-out", "ca.crl.pem"])
        try sh(["crl", "-in", "ca.crl.pem", "-outform", "DER", "-out", "ca.crl"])
        func der(_ f: String) throws -> [UInt8] {
            let pem = try String(contentsOfFile: dir + "/" + f, encoding: .utf8)
            return Array(Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined())!)
        }
        let carla = try SignerCertificate(der: der("carla.pem")), ca = try SignerCertificate(der: der("ca.pem"))
        let ada = try SignerCertificate(der: der("ada.pem"))
        let crl = try [UInt8](Data(contentsOf: p.dir.url("ca.crl")))
        // Signed after the revocation: revoked; signed before it: the signature stands.
        if case .revoked = Revocation.checkCRL(crl, cert: carla, issuer: ca, at: Date().addingTimeInterval(60), source: "t") {} else {
            Issue.record("CRL: carla should be revoked")
        }
        if case .revokedLater = Revocation.checkCRL(crl, cert: carla, issuer: ca, at: Date().addingTimeInterval(-86400), source: "t") {} else {
            Issue.record("CRL: revoked after the signature")
        }
        #expect(Revocation.checkCRL(crl, cert: ada, issuer: ca, at: Date(), source: "t") == .good(source: "t"))
        // A CRL signed by someone else is ignored.
        var forged = crl
        forged[forged.count - 10] ^= 0x01
        #expect(Revocation.checkCRL(forged, cert: carla, issuer: ca, at: Date(), source: "t") == nil)

        // Ada in the authority's database as valid (V), so the responder knows her.
        let serial = run(o, ["x509", "-in", "ada.pem", "-noout", "-serial"], cwd: dir).output
            .trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "serial=", with: "")
        var index = try String(contentsOfFile: dir + "/index.txt", encoding: .utf8)
        index += "V\t351231000000Z\t\t\(serial)\tunknown\t/CN=Ada Rossi\n"
        try index.write(toFile: dir + "/index.txt", atomically: true, encoding: .utf8)
        // OCSP: a responder for three requests (Carla, Ada, someone it does not know).
        let responder = Process()
        responder.executableURL = URL(fileURLWithPath: o)
        responder.currentDirectoryURL = p.dir.url("")
        responder.arguments = ["ocsp", "-index", "index.txt", "-port", "\(port)", "-rsigner", "ca.pem", "-rkey", "ca.key", "-CA", "ca.pem",
                               "-nrequest", "3", "-ignore_err"]
        responder.standardOutput = FileHandle.nullDevice
        responder.standardError = FileHandle.nullDevice
        try responder.run()
        defer { if responder.isRunning { responder.terminate() } }
        Thread.sleep(forTimeInterval: 1.0)
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        let r1 = Revocation.ocsp(url, cert: carla, issuer: ca, at: Date().addingTimeInterval(60))
        if case .revoked = r1 {} else { Issue.record("OCSP: carla should be revoked, got \(String(describing: r1))") }
        let r2 = Revocation.ocsp(url, cert: ada, issuer: ca, at: Date())
        #expect(r2 == .good(source: "OCSP 127.0.0.1"), "\(String(describing: r2))")
        let bruno = try SignerCertificate(der: der("bruno.pem"))
        if case .unknown = Revocation.ocsp(url, cert: bruno, issuer: ca, at: Date()) {} else { Issue.record("OCSP: bruno is unknown to the responder") }
        // Through the certificate's own address, only when online checks are allowed.
        #expect(Revocation.status(carla, chain: [ca], embeddedCRLs: [], at: Date(), online: false) == .notChecked("online checks not allowed"))
        #expect(Revocation.status(carla, chain: [ca], embeddedCRLs: [crl], at: Date().addingTimeInterval(60), online: false)
                != .notChecked("online checks not allowed"))
    }

    // MARK: PAdES and ASiC

    /// A minimal signed PDF: the signature dictionary's /Contents is a fixed-size placeholder, the
    /// byte ranges cover everything else, OpenSSL signs them (detached CMS), the hex goes in.
    func signedPDF(_ p: PKI, name: String, signer: String) throws -> [UInt8] {
        let placeholder = String(repeating: "0", count: 16384)
        let head = "%PDF-1.7\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] /SigFlags 3 >> >>\nendobj\n"
            + "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] >>\nendobj\n"
            + "4 0 obj\n<< /FT /Sig /T (Firma) /V 5 0 R >>\nendobj\n5 0 obj\n<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /ETSI.CAdES.detached "
            + "/ByteRange [0 AAAAAAAAAA BBBBBBBBBB CCCCCCCCCC] /Contents <"
        let tail = "> /M (D:20261114120000Z) >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n"
        var pdf = Array((head + placeholder + tail).utf8)
        let l1 = head.utf8.count - 1  // up to before "<"
        let c = l1 + 1 + placeholder.count + 1
        let l2 = pdf.count - c
        func pad(_ v: Int) -> [UInt8] { Array(String(format: "%010d", v).utf8) }
        for (marker, v) in [("AAAAAAAAAA", l1), ("BBBBBBBBBB", c), ("CCCCCCCCCC", l2)] {
            let m = Array(marker.utf8)
            let at = (0..<(pdf.count - 10)).first { Array(pdf[$0..<($0 + 10)]) == m }!
            pdf.replaceSubrange(at..<(at + 10), with: pad(v))
        }
        let signed = Array(pdf[0..<l1]) + Array(pdf[c..<(c + l2)])
        try Data(signed).write(to: p.dir.url(name + ".ranges"))
        let r = run(Self.openssl!, ["cms", "-sign", "-binary", "-cades", "-md", "sha256", "-in", name + ".ranges", "-signer", "\(signer).pem",
                                    "-inkey", "\(signer).key", "-certfile", "ca.pem", "-outform", "DER", "-out", name + ".cms"], cwd: p.dir.path)
        guard r.status == 0 else { throw XipperError.io("openssl: \(r.output)", path: p.dir.path, errno: 0) }
        let cms = try [UInt8](Data(contentsOf: p.dir.url(name + ".cms")))
        let hex = Array(cms.map { String(format: "%02X", $0) }.joined().utf8)
        pdf.replaceSubrange((l1 + 1)..<(l1 + 1 + hex.count), with: hex)
        try Data(pdf).write(to: p.dir.url(name))
        return pdf
    }

    @Test func signedPDF() throws {
        let p = try Self.pki.get()
        let pdf = try signedPDF(p, name: "firmato.pdf", signer: "ada")
        let url = p.dir.url("firmato.pdf")
        #expect(Xipper.isSignedDocument(url))
        let d = try Xipper.verifySignedDocument(url, options: SignatureCheckOptions(trustedList: try p.trustedList()))
        let s = try #require(d.signatures.first)
        #expect(d.format == .pdf && d.signatures.count == 1 && s.integrity && s.coversWholeFile && s.level == .qualified, "\(s.problems)")
        // Changed inside the signed range: invalid.
        var bad = pdf
        let at = (0..<(bad.count - 7)).first { Array(bad[$0..<($0 + 7)]) == Array("/Count ".utf8) }!
        bad[at + 7] = UInt8(ascii: "9")
        try Data(bad).write(to: p.dir.url("altered.pdf"))
        #expect(try Xipper.verifySignedDocument(p.dir.url("altered.pdf")).signatures.first?.integrity == false)
        // An update appended after the signature: the signature holds, the change is reported.
        try Data(pdf + Array("6 0 obj\n<< /Annot (later) >>\nendobj\n%%EOF\n".utf8)).write(to: p.dir.url("updated.pdf"))
        let u = try #require(try Xipper.verifySignedDocument(p.dir.url("updated.pdf")).signatures.first)
        #expect(u.integrity && !u.coversWholeFile && u.problems.contains { $0.contains("changed after this signature") })
        // An unsigned PDF is not a signed document.
        p.dir.write("plain.pdf", "%PDF-1.7\n%%EOF\n")
        #expect(!Xipper.isSignedDocument(p.dir.url("plain.pdf")))
    }

    @Test func asicSimpleAndExtended() throws {
        let p = try Self.pki.get()
        let o = Self.openssl!
        let dir = p.dir.path
        // ASiC-S: one file and META-INF/signature.p7s (detached).
        let s = p.dir.url("s")
        try FileManager.default.createDirectory(at: s.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        p.dir.write("s/mimetype", "application/vnd.etsi.asic-s+zip")
        p.dir.write("s/fattura.xml", "<fattura>100</fattura>")
        #expect(run(o, ["cms", "-sign", "-binary", "-cades", "-md", "sha256", "-in", "s/fattura.xml", "-signer", "ada.pem", "-inkey", "ada.key",
                        "-certfile", "ca.pem", "-outform", "DER", "-out", "s/META-INF/signature.p7s"], cwd: dir).status == 0)
        #expect(run("/usr/bin/zip", ["-X", "-0", "-q", "../doc.asics", "mimetype"], cwd: s.path).status == 0)
        #expect(run("/usr/bin/zip", ["-X", "-q", "-r", "../doc.asics", "fattura.xml", "META-INF"], cwd: s.path).status == 0)
        let ds = try Xipper.verifySignedDocument(p.dir.url("doc.asics"), options: SignatureCheckOptions(trustedList: try p.trustedList()))
        #expect(ds.format == .asic && ds.contentName == "fattura.xml" && ds.level == .qualified, "\(ds.signatures.map(\.problems))")
        // ASiC-E: a manifest with the files' digests, signed.
        let e = p.dir.url("e")
        try FileManager.default.createDirectory(at: e.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        p.dir.write("e/mimetype", "application/vnd.etsi.asic-e+zip")
        p.dir.write("e/a.txt", "primo")
        p.dir.write("e/b.txt", "secondo")
        func b64(_ t: String) -> String { Data(SHA256.hash(data: Data(t.utf8))).base64EncodedString() }
        let manifest = """
        <ASiCManifest xmlns="http://uri.etsi.org/02918/v1.2.1#" xmlns:ns2="http://www.w3.org/2000/09/xmldsig#">
        <SigReference URI="META-INF/signature001.p7s" MimeType="application/x-pkcs7-signature"/>
        <DataObjectReference URI="a.txt"><ns2:DigestMethod Algorithm="http://www.w3.org/2001/04/xmlenc#sha256"/><ns2:DigestValue>\(b64("primo"))</ns2:DigestValue></DataObjectReference>
        <DataObjectReference URI="b.txt"><ns2:DigestMethod Algorithm="http://www.w3.org/2001/04/xmlenc#sha256"/><ns2:DigestValue>\(b64("secondo"))</ns2:DigestValue></DataObjectReference>
        </ASiCManifest>
        """
        p.dir.write("e/META-INF/ASiCManifest001.xml", manifest)
        #expect(run(o, ["cms", "-sign", "-binary", "-cades", "-md", "sha256", "-in", "e/META-INF/ASiCManifest001.xml", "-signer", "bruno.pem",
                        "-inkey", "bruno.key", "-certfile", "ca.pem", "-outform", "DER", "-out", "e/META-INF/signature001.p7s"], cwd: dir).status == 0)
        func pack(_ name: String) {
            _ = run("/usr/bin/zip", ["-X", "-0", "-q", "../\(name)", "mimetype"], cwd: e.path)
            _ = run("/usr/bin/zip", ["-X", "-q", "-r", "../\(name)", "a.txt", "b.txt", "META-INF"], cwd: e.path)
        }
        pack("doc.asice")
        let de = try Xipper.verifySignedDocument(p.dir.url("doc.asice"), options: SignatureCheckOptions(trustedList: try p.trustedList()))
        #expect(de.signatures.count == 1 && de.signatures[0].integrity, "\(de.signatures.map(\.problems))")
        // A data file changed after signing: the manifest's digest catches it.
        p.dir.write("e/b.txt", "terzo")
        pack("changed.asice")
        let dc = try Xipper.verifySignedDocument(p.dir.url("changed.asice"))
        #expect(dc.signatures.first?.level == .invalid && dc.signatures.first?.problems.contains { $0.contains("b.txt") } == true)
    }

    /// The real Italian list (AgID), when a previous run cached it: the qualified authorities and
    /// their qualifiers are read. Skipped without the cache (no network in tests).
    @Test func realItalianListHasQualifiedAuthorities() throws {
        guard let tl = TrustedList.cached(country: "IT") else { return }
        #expect(tl.certificateAuthorities.count > 100, "\(tl.certificateAuthorities.count)")
        #expect(tl.services.count > 10)
        #expect(tl.certificateAuthorities.contains { !$0.qualifiers.isEmpty })
        #expect(tl.certificateAuthorities.allSatisfy { !$0.certificates.isEmpty && !$0.history.isEmpty })
    }

    /// The chain check Xipper does itself when macOS refuses a valid certificate as "not standards
    /// compliant" (found on a real ArubaPEC certificate of 2016): issuer name and signature, dates.
    @Test func ownChainCheck() throws {
        let p = try Self.pki.get()
        func cert(_ f: String) throws -> SignerCertificate {
            let pem = try String(contentsOfFile: p.dir.path + "/" + f, encoding: .utf8)
            return try SignerCertificate(der: Array(Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined())!))
        }
        let ada = try cert("ada.pem"), ca = try cert("ca.pem"), other = try cert("self.pem")
        #expect(TrustedList.chains(ada, to: ca, through: [], at: Date()))
        #expect(!TrustedList.chains(ada, to: other, through: [], at: Date()))
        #expect(!TrustedList.chains(ada, to: ca, through: [], at: Date().addingTimeInterval(5 * 365 * 86400)))  // after it expired
        #expect(!TrustedList.chains(other, to: ca, through: [ada], at: Date()))
    }
}
