import CryptoKit
import Foundation
import Testing
@testable import XipperKit

/// XIZ 1.13 (§23): segments signed by a key in this Mac's Secure Enclave, P-256 + ML-DSA-65
/// (algorithm 5), valid only when both halves verify.
@Suite("XIZ Secure Enclave signatures", .enabled(if: XizEnclaveSigningKey.isAvailable))
struct XizEnclaveSignatureTests {
    let helpers = XizAccessTests()

    func signed(_ t: TempDir, key: XizEnclaveSigningKey, password: String? = nil) throws -> URL {
        t.write("src/a.txt", "uno\n")
        t.write("src/dati/b.bin", sampleData(200_000))
        var o = CreateOptions()
        o.format = .xiz
        o.password = password
        o.xizSigner = XizSigner(enclave: key, label: "Mac di Ada")
        let a = t.url("se-\(UUID().uuidString).xiz")
        try Xipper.create(from: [t.url("src")], to: a, options: o)
        return a
    }

    @Test func keysRoundTrip() throws {
        let k = try XizEnclaveSigningKey()
        #expect(k.recordKey.count == 65 + 1952 && k.recordKey[0] == 0x04)
        #expect(k.publicText.hasPrefix("xizsigse1") && k.secretText.hasPrefix("XIZ-SIGNING-KEY-SE-1-"))
        let back = try XizEnclaveSigningKey(secretText: k.fileText)
        #expect(back.recordKey == k.recordKey)
        let s = try XizSigner(secretText: k.secretText, label: "x")
        #expect(s.enclave?.recordKey == k.recordKey && s.publicText == k.publicText)
        #expect(try XizSigner(secretText: XizSigningKey().secretText, label: "x").enclave == nil)
        #expect(XizSigningKey.displayText(k.recordKey).hasPrefix("xizsigse1:") && XizSigningKey.displayText(k.recordKey).count == 10 + 32)
        #expect(throws: XipperError.self) { _ = try XizEnclaveSigningKey(secretText: "XIZ-SIGNING-KEY-SE-1-AAAAAAAA") }
        // Only XIZ segments: not Apple Archive, not other messages.
        #expect(throws: XipperError.self) { _ = try XizSigner(enclave: k, label: "x").sign([1, 2, 3]) }
    }

    @Test func signsChainsAndVerifies() throws {
        let t = TempDir()
        let se = try XizEnclaveSigningKey(), bob = XizSigningKey()
        let a = try signed(t, key: se)
        #expect(try XizArchive(path: a.path).superblock.minor == 13)
        t.write("extra/n.txt", "nuovo\n")
        var b = CreateOptions()
        b.xizSigner = XizSigner(key: bob, label: "Bob")
        try Xipper.edit(a, changes: [.add(t.url("extra/n.txt"), as: "src/n.txt")], options: b)
        var c = CreateOptions()
        c.xizSigner = XizSigner(enclave: se, label: "Mac di Ada")
        try Xipper.edit(a, changes: [.delete("src/n.txt")], options: c)
        let h = try Xipper.xizHistory(a)
        #expect(h.count == 3 && h.allSatisfy { $0.signed && $0.valid && $0.chained }, "\(h.map { ($0.valid, $0.chained) })")
        #expect(h[0].isSecureEnclave && h[0].isPostQuantum && !h[1].isSecureEnclave && h[2].isSecureEnclave)
        #expect(h[0].publicKey == se.recordKey && h[0].publicKeyDisplay.hasPrefix("xizsigse1:"))
        #expect(try Xipper.test(a).isOK)
        // Encrypted: checked without the password.
        let t2 = TempDir()
        let e = try signed(t2, key: se, password: "segreto")
        #expect(try Xipper.xizHistory(e)[0].valid)
        // Proofs carry it too.
        let proof = try Xipper.xizProof(a, path: "src/a.txt")
        let r = try Xipper.xizVerifyProof(proof, file: t.url("src/a.txt"))
        #expect(r.valid && r.signed && r.signerKey.hasPrefix("xizsigse1:"))
    }

    @Test func bothHalvesAreRequired() throws {
        let t = TempDir()
        let a = try signed(t, key: try XizEnclaveSigningKey())
        let original = try [UInt8](Data(contentsOf: a))
        let d = try helpers.firstDirectory(original)
        let rec = d.dir + d.sigStart
        #expect(original[rec] == 5)
        let label = rec + 1 + 2017
        let sig = label + 1 + Int(original[label]) + 8 + 32
        for (name, offset) in [("P-256 key", rec + 1 + 20), ("ML-DSA key", rec + 1 + 65 + 700),
                               ("ECDSA signature", sig + 10), ("ECDSA s", sig + 63), ("ML-DSA signature", sig + 64 + 1500)] {
            var b = original
            b[offset] ^= 0x01
            try helpers.refresh(&b, d)
            try Data(b).write(to: a)
            #expect(try Xipper.xizHistory(a)[0].valid == false, "\(name)")
        }
        try Data(original).write(to: a)
        #expect(try Xipper.xizHistory(a)[0].valid)
    }

    /// The halves are bound to algorithm 5: not presentable as algorithm 2 or 4, nor under another context.
    @Test func halvesAreBound() throws {
        let key = try XizEnclaveSigningKey()
        let dir = XizDirectory(groups: [])
        let id = [UInt8](repeating: 7, count: 16)
        var r = XizSignature.Record(algorithm: 5, publicKey: key.recordKey, label: "A", time: 1, previous: [UInt8](repeating: 0, count: 32),
                                    signature: [], token: [])
        let m = XizSignature.message(archiveID: id, segment: 0, directory: dir, previousFooter: 0, r)
        r.signature = try key.recordSignature(m)
        #expect(r.signature.count == 64 + 3309 && r.verify(m))
        #expect(try XizSignature.Record.decode(r.encode()).verify(m))
        var as4 = r
        as4.algorithm = 4
        #expect(!as4.verify(m))
        let pq = try MLDSA65.PublicKey(rawRepresentation: key.recordKey[65...])
        #expect(!pq.isValidSignature(r.signature[64...], for: m, context: Array("XIZ112hybrid".utf8)))
        #expect(pq.isValidSignature(r.signature[64...], for: m, context: Array("XIZ113enclave".utf8)))
    }

    @Test func appleArchiveRefusesIt() throws {
        let t = TempDir()
        t.write("src/a.txt", "uno\n")
        var o = CreateOptions()
        o.format = .appleArchive
        o.xizSigner = XizSigner(enclave: try XizEnclaveSigningKey(), label: "x")
        #expect(throws: (any Error).self) { try Xipper.create(from: [t.url("src")], to: t.url("a.aar"), options: o) }
    }

    static let fixtures = XizHybridSignatureTests.fixtures

    /// libxiz's vectors (XIPPER_WRITE_LIBXIZ_VECTORS=1): two Secure Enclave segments, and the same
    /// with one bit of the ECDSA half flipped.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["XIPPER_WRITE_LIBXIZ_VECTORS"] == "1"))
    func writeLibxizVectors() throws {
        let t = TempDir()
        let key = try XizEnclaveSigningKey()
        let a = try signed(t, key: key)
        t.write("extra/n.txt", "second segment\n")
        var o = CreateOptions()
        o.xizSigner = XizSigner(enclave: key, label: "Mac di Ada")
        try Xipper.edit(a, changes: [.add(t.url("extra/n.txt"), as: "src/n.txt")], options: o)
        let good = try [UInt8](Data(contentsOf: a))
        try Data(good).write(to: URL(fileURLWithPath: Self.fixtures + "/signed-se.xiz"))
        let d = try helpers.firstDirectory(good)
        let label = d.dir + d.sigStart + 1 + 2017
        var bad = good
        bad[label + 1 + Int(good[label]) + 8 + 32 + 20] ^= 0x10
        try helpers.refresh(&bad, d)
        try Data(bad).write(to: URL(fileURLWithPath: Self.fixtures + "/signed-se-tampered.xiz"))
    }

    @Test func libxizVectorsReadAlike() throws {
        let f = Self.fixtures
        guard FileManager.default.fileExists(atPath: f + "/signed-se.xiz") else { return }
        let good = try Xipper.xizHistory(URL(fileURLWithPath: f + "/signed-se.xiz"))
        #expect(good.count == 2 && good.allSatisfy { $0.valid && $0.chained && $0.isSecureEnclave })
        let bad = try Xipper.xizHistory(URL(fileURLWithPath: f + "/signed-se-tampered.xiz"))
        #expect(!bad[0].valid && bad[1].valid && !bad[1].chained)
    }
}
