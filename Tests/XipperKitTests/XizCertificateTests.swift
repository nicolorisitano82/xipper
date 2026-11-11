import CryptoKit
import Foundation
import Security
import Testing
@testable import ForensicKit
@testable import XipperKit

/// Certificate signatures (§13.5, algorithms 2 and 3): segments, case log and reports signed with an
/// X.509 identity (EC P-256 and RSA), verified, tampering and a foreign key detected.
@Suite("XIZ certificate signatures")
struct XizCertificateTests {
    /// A key in memory and a self-signed certificate for it (tests only: real ones come from a CA).
    static func identity(rsa: Bool, cn: String, notAfter: Date = Date(timeIntervalSinceNow: 86400 * 365)) throws -> XizCertificateSigner {
        let attrs: [String: Any] = [kSecAttrKeyType as String: rsa ? kSecAttrKeyTypeRSA : kSecAttrKeyTypeECSECPrimeRandom,
                                    kSecAttrKeySizeInBits as String: rsa ? 2048 : 256]
        var err: Unmanaged<CFError>?
        let key = try #require(SecKeyCreateRandomKey(attrs as CFDictionary, &err))
        return try XizCertificateSigner(privateKey: key, chain: [selfSigned(key, rsa: rsa, cn: cn, notAfter: notAfter)])
    }

    static func selfSigned(_ key: SecKey, rsa: Bool, cn: String, notAfter: Date) throws -> [UInt8] {
        let pub = Array(SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(key)!, nil)! as Data)
        let alg = rsa ? DER.seq(DER.oid([1, 2, 840, 113549, 1, 1, 11]) + [0x05, 0x00]) : DER.seq(DER.oid([1, 2, 840, 10045, 4, 3, 2]))
        let spkiAlg = rsa ? DER.seq(DER.oid([1, 2, 840, 113549, 1, 1, 1]) + [0x05, 0x00])
                          : DER.seq(DER.oid([1, 2, 840, 10045, 2, 1]) + DER.oid([1, 2, 840, 10045, 3, 1, 7]))
        let spki = DER.seq(spkiAlg + DER.tlv(0x03, [0] + pub))
        let name = DER.seq(DER.tlv(0x31, DER.seq(DER.oid([2, 5, 4, 3]) + DER.tlv(0x0C, Array(cn.utf8)))))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyMMddHHmmss'Z'"
        let validity = DER.seq(DER.tlv(0x17, Array(f.string(from: Date(timeIntervalSinceNow: -3600)).utf8)) + DER.tlv(0x17, Array(f.string(from: notAfter).utf8)))
        let tbs = DER.seq(DER.tlv(0xA0, DER.integer([2])) + DER.integer([0x01, 0x23, 0x45]) + alg + name + validity + name + spki)
        let sig = Array(SecKeyCreateSignature(key, rsa ? .rsaSignatureMessagePKCS1v15SHA256 : .ecdsaSignatureMessageX962SHA256, Data(tbs) as CFData, nil)! as Data)
        return DER.seq(tbs + alg + DER.tlv(0x03, [0] + sig))
    }

    func image(_ t: TempDir) -> String { t.write("disk.img", sampleData(3 << 20, seed: 9)) }

    @Test(arguments: [false, true])
    func segmentsSignedWithCertificate(rsa: Bool) throws {
        let t = TempDir()
        let id = try Self.identity(rsa: rsa, cn: "Mario Rossi")
        let signer = XizSigner(key: XizSigningKey(), label: "Mario Rossi", certificate: id)
        let out = t.path + "/r.xiz"
        _ = try XizForensic.acquireImage(from: image(t), to: out, options: .init(), signer: signer)
        try XizForensic.appendCustody(to: out, custody: ["from": "Mario Rossi", "to": "Tribunale"], signer: signer)
        let h = try XizSignature.history(out)
        #expect(h.count == 2 && h.allSatisfy { $0.valid && $0.chained && $0.algorithm == (rsa ? 3 : 2) })
        #expect(h[0].certificate?.subject == "Mario Rossi" && h[0].certificate?.validAtSigning == true)
        #expect(h[0].certificate?.trusted == false)  // self-signed: not a root this Mac trusts
        let v = try XizForensic.verify(out)
        #expect(v.passed, "\(v.checks)")
        #expect(v.checks.first { $0.name == "certificates" }?.status == .warning)
        // A changed signature byte breaks it.
        var bytes = try Array(Data(contentsOf: URL(fileURLWithPath: out)))
        let leaf = id.chain[0]
        let at = try #require(bytes.firstRange(of: leaf)).upperBound + 60
        bytes[at] ^= 1
        try Data(bytes).write(to: URL(fileURLWithPath: out))
        #expect(!(try XizForensic.verify(out).passed))
    }

    /// libxiz (C, BearSSL) checks the same signatures independently.
    @Test(arguments: [false, true])
    func libxizVerifiesCertificateSignatures(rsa: Bool) throws {
        let xiz = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("libxiz/build/xiz").path
        try #require(FileManager.default.isExecutableFile(atPath: xiz), "build libxiz first (cmake --build libxiz/build)")
        let t = TempDir()
        let signer = XizSigner(key: XizSigningKey(), label: "Mario Rossi", certificate: try Self.identity(rsa: rsa, cn: "Mario Rossi"))
        let out = t.path + "/r.xiz"
        _ = try XizForensic.acquireImage(from: image(t), to: out, options: .init(), signer: signer)
        try XizForensic.appendCustody(to: out, custody: ["from": "A", "to": "B"], signer: signer)
        func run(_ args: [String]) throws -> (Int32, String) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: xiz); p.arguments = args
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            try p.run(); let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return (p.terminationStatus, String(decoding: d, as: UTF8.self))
        }
        let (rc, text) = try run(["history", out])
        #expect(rc == 0, "\(text)")
        #expect(text.contains("x509:") && text.components(separatedBy: "signature valid").count == 3, "\(text)")
        let (rcf, textf) = try run(["forensic", out])
        #expect(rcf == 0, "\(textf)")
        // A flipped bit in the signature: libxiz refuses the archive too.
        var bytes = try Array(Data(contentsOf: URL(fileURLWithPath: out)))
        let at = try #require(bytes.firstRange(of: signer.certificate!.chain[0])).upperBound + 60
        bytes[at] ^= 1
        try Data(bytes).write(to: URL(fileURLWithPath: out))
        let (rc2, text2) = try run(["history", out])
        #expect(rc2 != 0, "\(text2)")  // the directory hash in the footer catches it before the signature
    }

    @Test func keyMustMatchCertificate() throws {
        let a = try Self.identity(rsa: false, cn: "A"), b = try Self.identity(rsa: false, cn: "B")
        #expect(throws: XipperError.self) { _ = try XizCertificateSigner(privateKey: a.privateKey, chain: b.chain) }
    }

    @Test func caseLogAndReportsWithCertificate() throws {
        let t = TempDir()
        let signer = XizSigner(key: XizSigningKey(), label: "Mario Rossi", certificate: try Self.identity(rsa: true, cn: "Mario Rossi"))
        let c = try ForensicCase.create(at: t.url("C.xfcase"), info: ["case_number": "1"], signer: signer)
        _ = try c.acquireImage(from: image(t), evidence: "R01", options: .init(), signer: signer)
        let v = try c.verify()
        #expect(v.passed, "\(v.problems)")
        #expect(v.signers.keys.allSatisfy { $0.hasPrefix("x509:") })
        let e = try #require(try c.evidence().first)
        let s = try ForensicReport.verifySignature(e.report)
        #expect(s.valid && s.certificate?.subject == "Mario Rossi")
        let r = try JSONSerialization.jsonObject(with: Data(contentsOf: e.report)) as? [String: Any]
        let seg = (r?["segments"] as? [[String: Any]])?.first
        #expect((seg?["certificate"] as? [String: Any])?["subject"] as? String == "Mario Rossi")
    }
}
