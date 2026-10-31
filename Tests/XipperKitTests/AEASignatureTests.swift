import CryptoKit
import Foundation
import Testing
@testable import XipperKit

@Suite("Signed Apple Archives")
struct AEASignatureTests {
    static func signed(_ t: TempDir, label: String = "Lab", key: XizSigningKey = XizSigningKey()) throws -> (URL, XizSigningKey) {
        t.write("src/a.txt", "hello")
        t.write("src/sub/b.bin", sampleData(200_000))
        var o = CreateOptions()
        o.format = .appleArchive
        o.xizSigner = XizSigner(key: key, label: label)
        let out = t.url("signed.aar")
        _ = try Xipper.create(from: [t.url("src")], to: out, options: o)
        return (out, key)
    }

    @Test func signedArchiveRoundTripsAndNamesItsSigner() throws {
        let t = TempDir()
        let (aar, key) = try Self.signed(t)
        #expect(!AppleArchiveReader.isEncrypted(aar.path))
        let h = try Xipper.xizHistory(aar)
        #expect(h.count == 1)
        #expect(h[0].signed && h[0].valid && h[0].label == "Lab" && h[0].publicKey == key.publicKey)
        #expect(try Xipper.test(aar).isOK)
        t.mkdir("x")
        _ = try Xipper.extract(aar, to: t.url("x"), mode: .into)
        #expect(try String(contentsOf: t.url("x/src/a.txt"), encoding: .utf8) == "hello")
    }

    @Test func derivedKeyIsStable() {
        let k = XizSigningKey()
        #expect(AEASignature.p256(for: k).rawRepresentation == AEASignature.p256(for: k).rawRepresentation)
        #expect(AEASignature.p256(for: k).rawRepresentation != AEASignature.p256(for: XizSigningKey()).rawRepresentation)
    }

    @Test func macOSToolVerifiesTheSignature() throws {
        let t = TempDir()
        let (aar, key) = try Self.signed(t)
        t.write("pub.pem", AEASignature.p256(for: key).publicKey.pemRepresentation)
        t.write("other.pem", P256.Signing.PrivateKey().publicKey.pemRepresentation)
        #expect(run("/usr/bin/aea", ["decrypt", "-i", aar.path, "-o", t.path + "/plain.aar", "-sign-pub", t.path + "/pub.pem"]).status == 0)
        #expect(run("/usr/bin/aea", ["decrypt", "-i", aar.path, "-o", t.path + "/plain2.aar", "-sign-pub", t.path + "/other.pem"]).status != 0)
    }

    @Test func tamperedContentIsRefused() throws {
        let t = TempDir()
        let (aar, _) = try Self.signed(t)
        var bytes = try [UInt8](Data(contentsOf: aar))
        bytes[bytes.count - 100] ^= 0x01
        try Data(bytes).write(to: aar)
        let report = try? Xipper.test(aar)
        #expect(report?.isOK != true)
    }

    @Test func borrowedIdentityIsNotValid() throws {
        // A forger signs with their own key but claims the victim's Ed25519 key and label.
        let t = TempDir()
        let victim = XizSigningKey(), forger = XizSigningKey()
        let (aar, _) = try Self.signed(t, label: "Forger", key: forger)
        var bytes = try [UInt8](Data(contentsOf: aar))
        // The auth data sits in the signed header: swapping the Ed25519 key breaks the binding,
        // and AEA's own header signature, so neither the history nor reading accept it.
        if let r = bytes.firstRange(of: forger.publicKey) { bytes.replaceSubrange(r, with: victim.publicKey) }
        try Data(bytes).write(to: aar)
        let h = try Xipper.xizHistory(aar)
        #expect(h.first?.valid == false)
        #expect(throws: (any Error).self) { _ = try Xipper.list(aar) }
    }

    @Test func passwordAndSignatureTogetherAreRefused() {
        let t = TempDir()
        t.write("src/a.txt", "x")
        var o = CreateOptions()
        o.format = .appleArchive
        o.password = "long enough password"
        o.xizSigner = XizSigner(key: XizSigningKey(), label: "x")
        #expect(throws: XipperError.self) { _ = try Xipper.create(from: [t.url("src")], to: t.url("o.aar"), options: o) }
    }

    @Test func editingKeepsOrRefusesTheSignature() throws {
        let t = TempDir()
        let (aar, key) = try Self.signed(t)
        #expect(throws: XipperError.self) { _ = try Xipper.edit(aar, changes: [.delete("src/a.txt")]) }
        var o = CreateOptions()
        o.xizSigner = XizSigner(key: key, label: "Lab")
        _ = try Xipper.edit(aar, changes: [.delete("src/a.txt")], options: o)
        #expect(try Xipper.xizHistory(aar).first?.valid == true)
        #expect(try !Xipper.list(aar).contains { $0.path == "src/a.txt" })
    }
}
