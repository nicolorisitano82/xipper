import CryptoKit
import Foundation
import Security
import Testing
@testable import XipperKit

/// Signing `.p7m` (3.3, phase B): ours checked by OpenSSL and by our own verifier; parallel, nested,
/// time-stamped (CAdES-T, with a local OpenSSL time-stamp authority).
@Suite("Signing documents (.p7m)", .enabled(if: opensslTool != nil), .serialized)
struct DocumentSigningTests {
    typealias PKI = SignedDocumentTests.PKI
    static let pki = Result { try PKI() }

    func der(_ p: PKI, pem file: String) throws -> [UInt8] {
        let pem = try String(contentsOfFile: p.dir.path + "/" + file, encoding: .utf8)
        return Array(Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()) ?? Data())
    }

    func ossl(_ p: PKI, _ args: [String]) -> (status: Int32, output: String) {
        let r = run(opensslTool!, args, cwd: p.dir.path)
        return (r.status, r.output)
    }

    /// A signer from the PKI's key files, as a smart card or the Keychain would give it.
    func signer(_ p: PKI, _ name: String, ec: Bool = false) throws -> XizCertificateSigner {
        let key: SecKey
        if ec {
            #expect(ossl(p, ["ec", "-in", "\(name).key", "-outform", "DER", "-out", "\(name).sec1"]).status == 0)
            let k = try P256.Signing.PrivateKey(derRepresentation: Data(contentsOf: p.dir.url("\(name).sec1")))
            key = SecKeyCreateWithData(k.x963Representation as CFData, [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                                                                         kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, nil)!
        } else {
            #expect(ossl(p, ["rsa", "-in", "\(name).key", "-traditional", "-outform", "DER", "-out", "\(name).pk1"]).status == 0)
            key = SecKeyCreateWithData(try Data(contentsOf: p.dir.url("\(name).pk1")) as CFData,
                                       [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, nil)!
        }
        return try XizCertificateSigner(privateKey: key, chain: [try der(p, pem: "\(name).pem"), p.caDER])
    }

    /// OpenSSL's verdict on a `.p7m` of ours, against the test CA; the content it extracts.
    func opensslVerifies(_ p: PKI, _ file: String) -> (ok: Bool, content: String) {
        let r = ossl(p, ["cms", "-verify", "-binary", "-inform", "DER", "-in", file, "-CAfile", "ca.pem", "-purpose", "any",
                         "-out", file + ".out"])
        return (r.status == 0, (try? String(contentsOfFile: p.dir.path + "/" + file + ".out", encoding: .utf8)) ?? "")
    }

    @Test func newSignatureRSAAndECDSA() throws {
        let p = try Self.pki.get()
        p.dir.write("contratto.txt", "Contratto firmato da Xipper\n")
        let tl = try p.trustedList(qualifiers: ["QCWithQSCD"])
        for (who, ec) in [("ada", false), ("bruno", true)] {
            let out = p.dir.url("contratto-\(who).txt.p7m")
            try Xipper.signDocument(p.dir.url("contratto.txt"), output: out, signer: try signer(p, who, ec: ec))
            let o = opensslVerifies(p, out.lastPathComponent)
            #expect(o.ok && o.content == "Contratto firmato da Xipper\n", "OpenSSL on \(who)")
            let d = try Xipper.verifySignedDocument(out, options: SignatureCheckOptions(trustedList: tl))
            #expect(d.signatures.count == 1 && d.allValid)
            #expect(d.signatures[0].certificateBound == true)  // signing-certificate-v2
            #expect(d.signatures[0].level == (who == "ada" ? .qualified : .advanced))
            #expect(abs((d.signatures[0].claimedTime ?? .distantPast).timeIntervalSinceNow) < 120)
            #expect(d.content.map { String(decoding: $0, as: UTF8.self) } == "Contratto firmato da Xipper\n")
        }
        // Not over an existing file unless asked.
        #expect(throws: (any Error).self) {
            try Xipper.signDocument(p.dir.url("contratto.txt"), output: p.dir.url("contratto-ada.txt.p7m"), signer: try signer(p, "ada"))
        }
    }

    @Test func parallelAndNested() throws {
        let p = try Self.pki.get()
        p.dir.write("delibera.txt", "Delibera\n")
        let first = try Xipper.signDocument(p.dir.url("delibera.txt"), signer: try signer(p, "ada"))
        #expect(first.lastPathComponent == "delibera.txt.p7m")
        // Parallel: in place, two signers over the same content.
        try Xipper.signDocument(first, mode: .parallel, signer: try signer(p, "bruno", ec: true))
        var d = try Xipper.verifySignedDocument(first)
        #expect(d.signatures.count == 2 && d.signatures.allSatisfy(\.integrity))
        #expect(Set(d.signatures.compactMap { $0.signer?.subject.commonName }) == ["Ada Rossi", "Bruno Bianchi"])
        #expect(opensslVerifies(p, "delibera.txt.p7m").ok)
        // Also onto a .p7m made by OpenSSL.
        try p.sign("delibera.txt", "openssl.p7m", signer: "ada")
        try Xipper.signDocument(p.dir.url("openssl.p7m"), mode: .parallel, signer: try signer(p, "bruno", ec: true))
        d = try Xipper.verifySignedDocument(p.dir.url("openssl.p7m"))
        #expect(d.signatures.count == 2 && d.signatures.allSatisfy(\.integrity))
        #expect(opensslVerifies(p, "openssl.p7m").ok)
        // Nested: a .p7m around the .p7m.
        let nested = try Xipper.signDocument(first, mode: .nested, signer: try signer(p, "ada"))
        #expect(nested.lastPathComponent == "delibera.txt.p7m.p7m")
        d = try Xipper.verifySignedDocument(nested)
        #expect(d.signatures.count == 3 && d.signatures.allSatisfy(\.integrity))
        #expect(d.signatures.map(\.depth).sorted() == [0, 1, 1])
        #expect(d.content.map { String(decoding: $0, as: UTF8.self) } == "Delibera\n")
        // A parallel signature needs a .p7m.
        #expect(throws: (any Error).self) {
            try Xipper.signDocument(p.dir.url("delibera.txt"), output: p.dir.url("x.p7m"), mode: .parallel, signer: try signer(p, "ada"))
        }
    }

    @Test func timestampedSignature() throws {
        let p = try Self.pki.get()
        p.dir.write("tsa.cnf", """
            [ req ]
            distinguished_name = dn
            prompt = no
            [ dn ]
            CN = Xipper Test TSA
            [ ext ]
            basicConstraints = CA:FALSE
            keyUsage = critical, digitalSignature
            extendedKeyUsage = critical, timeStamping
            [ tsa1 ]
            dir = .
            serial = ./tsaserial
            crypto_device = builtin
            signer_digest = sha256
            default_policy = 1.2.3.4.1
            digests = sha256
            accuracy = secs:1
            ordering = yes
            tsa_name = no
            ess_cert_id_chain = no
            ess_cert_id_alg = sha256
            """)
        p.dir.write("tsaserial", "01\n")
        #expect(ossl(p, ["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes", "-keyout", "tsa.key",
                         "-out", "tsa.pem", "-days", "2", "-config", "tsa.cnf", "-extensions", "ext"]).status == 0)
        let dir = p.dir.path
        let tsa = TimestampSource.custom { imprint in
            try Data(RFC3161.requestDER(imprint: imprint, nonce: [0x01, 0x02])).write(to: URL(fileURLWithPath: dir + "/q.tsq"))
            let r = run(opensslTool!, ["ts", "-reply", "-queryfile", "q.tsq", "-signer", "tsa.pem", "-inkey", "tsa.key",
                                       "-config", "tsa.cnf", "-section", "tsa1", "-out", "r.tsr"], cwd: dir)
            guard r.status == 0 else { throw XipperError.io("openssl ts: \(r.output)", path: dir, errno: 0) }
            return try RFC3161.tokenFromResponse([UInt8](Data(contentsOf: URL(fileURLWithPath: dir + "/r.tsr"))))
        }
        p.dir.write("verbale.txt", "Verbale\n")
        let out = try Xipper.signDocument(p.dir.url("verbale.txt"), signer: try signer(p, "ada"), timestamp: tsa)
        #expect(opensslVerifies(p, out.lastPathComponent).ok)
        let d = try Xipper.verifySignedDocument(out)
        let ts = try #require(d.signatures.first?.timestamp)
        #expect(ts.valid && ts.authority.contains("Xipper Test TSA"))
        #expect(abs(ts.time.timeIntervalSinceNow) < 120)
        // A failing authority means no signature at all, not one without the time.
        #expect(throws: (any Error).self) {
            try Xipper.signDocument(p.dir.url("verbale.txt"), output: p.dir.url("v2.p7m"), signer: try signer(p, "ada"),
                                    timestamp: .custom { _ in throw XipperError.unsupported("down") })
        }
        #expect(!FileManager.default.fileExists(atPath: p.dir.path + "/v2.p7m"))
    }
}
