import CryptoKit
import Foundation
import Testing
@testable import XipperKit

/// XIZ 1.12 (§22): segments signed with a hybrid Ed25519 + ML-DSA-65 key (algorithm 4), valid
/// only when both halves verify.
@Suite("XIZ hybrid post-quantum signatures")
struct XizHybridSignatureTests {
    let helpers = XizAccessTests()

    func tree(_ t: TempDir) {
        t.write("src/a.txt", "uno\n")
        t.write("src/dati/b.bin", sampleData(200_000))
    }

    func signed(_ t: TempDir, key: XizSigningKey, label: String = "Alice", password: String? = nil) throws -> URL {
        tree(t)
        var o = CreateOptions()
        o.format = .xiz
        o.password = password
        o.xizSigner = XizSigner(key: key, label: label)
        let a = t.url("pq-\(UUID().uuidString).xiz")
        try Xipper.create(from: [t.url("src")], to: a, options: o)
        return a
    }

    @Test func keysRoundTrip() throws {
        let k = XizSigningKey(postQuantum: true)
        #expect(k.isPostQuantum && k.recordKey.count == 32 + 1952 && k.publicKey.count == 32)
        #expect(k.publicText.hasPrefix("xizsigpq1") && k.secretText.hasPrefix("XIZ-SIGNING-KEY-PQ-1-"))
        let back = try XizSigningKey(secretText: k.fileText)
        #expect(back.isPostQuantum && back.recordKey == k.recordKey)
        let classic = XizSigningKey()
        #expect(!classic.isPostQuantum && classic.publicText.hasPrefix("xizsig1") && classic.recordKey == classic.publicKey)
        #expect(try XizSigningKey(secretText: classic.fileText).recordKey == classic.publicKey)
        #expect(XizSigningKey.displayText(k.recordKey).hasPrefix("xizsigpq1:") && XizSigningKey.displayText(k.recordKey).count == 10 + 32)
        #expect(throws: XipperError.self) { _ = try XizSigningKey(secretText: "XIZ-SIGNING-KEY-PQ-1-AAAA") }
    }

    @Test func signsChainsAndVerifies() throws {
        let t = TempDir()
        let alice = XizSigningKey(postQuantum: true), bob = XizSigningKey()
        let a = try signed(t, key: alice)
        #expect(try XizArchive(path: a.path).superblock.minor == 12)
        t.write("extra/n.txt", "nuovo\n")
        var b = CreateOptions()
        b.xizSigner = XizSigner(key: bob, label: "Bob")  // a classic key after a hybrid one
        try Xipper.edit(a, changes: [.add(t.url("extra/n.txt"), as: "src/n.txt")], options: b)
        var c = CreateOptions()
        c.xizSigner = XizSigner(key: alice, label: "Alice")
        try Xipper.edit(a, changes: [.delete("src/n.txt")], options: c)
        let h = try Xipper.xizHistory(a)
        #expect(h.count == 3 && h.allSatisfy { $0.signed && $0.valid && $0.chained }, "\(h.map { ($0.valid, $0.chained) })")
        #expect(h[0].isPostQuantum && !h[1].isPostQuantum && h[2].isPostQuantum)
        #expect(h[0].publicKey == alice.recordKey && h[0].publicKeyDisplay.hasPrefix("xizsigpq1:"))
        #expect(try Xipper.test(a).isOK)
    }

    @Test func encryptedArchiveNeedsNoKeyToCheck() throws {
        let t = TempDir()
        let a = try signed(t, key: XizSigningKey(postQuantum: true), password: "segreto")
        let h = try Xipper.xizHistory(a)
        #expect(h.count == 1 && h[0].valid && h[0].isPostQuantum)
    }

    /// Each half is checked: one altered byte in either signature, or in either key, fails it.
    @Test func bothHalvesAreRequired() throws {
        let t = TempDir()
        let a = try signed(t, key: XizSigningKey(postQuantum: true))
        let original = try [UInt8](Data(contentsOf: a))
        let d = try helpers.firstDirectory(original)
        let rec = d.dir + d.sigStart
        #expect(original[rec] == 4)
        let label = rec + 1 + 1984
        let sig = label + 1 + Int(original[label]) + 8 + 32
        for (name, offset) in [("Ed25519 key", rec + 1 + 5), ("ML-DSA key", rec + 1 + 32 + 700),
                               ("Ed25519 signature", sig + 10), ("ML-DSA signature", sig + 64 + 1500),
                               ("ML-DSA signature end", sig + 64 + 3308)] {
            var b = original
            b[offset] ^= 0x01
            try helpers.refresh(&b, d)
            try Data(b).write(to: a)
            #expect(try Xipper.xizHistory(a)[0].valid == false, "\(name)")
        }
        try Data(original).write(to: a)
        #expect(try Xipper.xizHistory(a)[0].valid)
    }

    /// The Ed25519 half alone, presented as a classic signature, does not verify: the message
    /// carries the algorithm and the whole key.
    @Test func cannotBeStrippedToEd25519() throws {
        let key = XizSigningKey(postQuantum: true)
        let dir = XizDirectory(groups: [])
        var r = XizSignature.Record(algorithm: 4, publicKey: key.recordKey, label: "A", time: 1, previous: [UInt8](repeating: 0, count: 32),
                                    signature: [], token: [])
        let id = [UInt8](repeating: 7, count: 16)
        let m = XizSignature.message(archiveID: id, segment: 0, directory: dir, previousFooter: 0, r)
        r.signature = try key.recordSignature(m)
        #expect(r.signature.count == 64 + 3309 && r.verify(m))
        #expect(try XizSignature.Record.decode(r.encode()).verify(m))
        let stripped = XizSignature.Record(algorithm: 1, publicKey: key.publicKey, label: "A", time: 1, previous: r.previous,
                                           signature: Array(r.signature[0..<64]), token: [])
        let m1 = XizSignature.message(archiveID: id, segment: 0, directory: dir, previousFooter: 0, stripped)
        #expect(!stripped.verify(m1))
        // Neither half verifies under another context (the ML-DSA half is bound to "XIZ112hybrid").
        let pq = try MLDSA65.PublicKey(rawRepresentation: key.recordKey[32...])
        #expect(!pq.isValidSignature(r.signature[64...], for: m))
        #expect(pq.isValidSignature(r.signature[64...], for: m, context: Array("XIZ112hybrid".utf8)))
    }

    /// An algorithm this reader does not know: reported as signed and not verified, never as unsigned.
    @Test func unknownAlgorithmIsReportedAsSuch() throws {
        let t = TempDir()
        let a = try signed(t, key: XizSigningKey(postQuantum: true))
        var b = try [UInt8](Data(contentsOf: a))
        let d = try helpers.firstDirectory(b)
        b[d.dir + d.sigStart] = 9
        try helpers.refresh(&b, d)
        try Data(b).write(to: a)
        let h = try Xipper.xizHistory(a)
        #expect(h[0].signed && !h[0].valid && h[0].isUnknownAlgorithm && h[0].algorithm == 9)
    }

    @Test func proofsVerifyWithHybridAndCertificateSignatures() throws {
        let t = TempDir()
        let a = try signed(t, key: XizSigningKey(postQuantum: true))
        let proof = try Xipper.xizProof(a, path: "src/a.txt")
        let r = try Xipper.xizVerifyProof(proof, file: t.url("src/a.txt"))
        #expect(r.valid && r.signed && r.signerKey.hasPrefix("xizsigpq1:"))
    }

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("libxiz/tests/fixtures").path

    /// Writes libxiz's vectors (XIPPER_WRITE_LIBXIZ_VECTORS=1): a hybrid-signed archive with two
    /// segments, the same with one bit of the ML-DSA half flipped, and with an unknown algorithm.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["XIPPER_WRITE_LIBXIZ_VECTORS"] == "1"))
    func writeLibxizVectors() throws {
        let t = TempDir()
        let key = XizSigningKey(postQuantum: true)
        let a = try signed(t, key: key, label: "Hybrid Signer")
        t.write("extra/n.txt", "second segment\n")
        var o = CreateOptions()
        o.xizSigner = XizSigner(key: key, label: "Hybrid Signer")
        try Xipper.edit(a, changes: [.add(t.url("extra/n.txt"), as: "src/n.txt")], options: o)
        let good = try [UInt8](Data(contentsOf: a))
        try Data(good).write(to: URL(fileURLWithPath: Self.fixtures + "/signed-pq.xiz"))
        let d = try helpers.firstDirectory(good)
        let rec = d.dir + d.sigStart
        let label = rec + 1 + 1984
        var bad = good
        bad[label + 1 + Int(good[label]) + 8 + 32 + 64 + 2000] ^= 0x10
        try helpers.refresh(&bad, d)
        try Data(bad).write(to: URL(fileURLWithPath: Self.fixtures + "/signed-pq-tampered.xiz"))
        var unknown = good
        unknown[rec] = 9
        try helpers.refresh(&unknown, d)
        try Data(unknown).write(to: URL(fileURLWithPath: Self.fixtures + "/signed-pq-unknown.xiz"))
    }

    /// The vectors libxiz checks read the same way here.
    @Test func libxizVectorsReadAlike() throws {
        let f = Self.fixtures
        guard FileManager.default.fileExists(atPath: f + "/signed-pq.xiz") else { return }
        let good = try Xipper.xizHistory(URL(fileURLWithPath: f + "/signed-pq.xiz"))
        #expect(good.count == 2 && good.allSatisfy { $0.valid && $0.chained && $0.isPostQuantum })
        let bad = try Xipper.xizHistory(URL(fileURLWithPath: f + "/signed-pq-tampered.xiz"))
        #expect(!bad[0].valid && bad[1].valid && !bad[1].chained)
        let unknown = try Xipper.xizHistory(URL(fileURLWithPath: f + "/signed-pq-unknown.xiz"))
        #expect(unknown[0].isUnknownAlgorithm && unknown[1].valid && !unknown[1].chained)
    }
}
