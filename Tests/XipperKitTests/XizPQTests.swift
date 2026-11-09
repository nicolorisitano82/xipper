import CryptoKit
import Foundation
import Testing
@testable import XipperKit

/// XIZ 1.7 (§17): post-quantum recipients and custodians with X-Wing (ML-KEM-768 + X25519).
@Suite("XIZ post-quantum recipients", .serialized)
struct XizPQTests {
    func tree(_ t: TempDir) {
        t.write("src/indice.txt", "indice del caso\n")
        t.write("src/referti/r1.txt", "referto uno\n")
        t.write("src/dati/g.bin", sampleData(300_000, seed: 3))
    }

    func paths(_ a: URL, password: String? = nil) throws -> Set<String> {
        Set(try Xipper.list(a, password: password).filter { $0.kind == .file }.map(\.path))
    }

    @Test func keyTexts() throws {
        let k = XizIdentity(postQuantum: true)
        #expect(k.isPostQuantum && k.publicKey.count == 1216)
        #expect(k.publicText.hasPrefix("xizpq1") && k.secretText.hasPrefix("XIZ-SECRET-KEY-PQ-1-"))
        let back = try XizIdentity(secretText: k.fileText)
        #expect(back.isPostQuantum && back.publicKey == k.publicKey)
        #expect(try XizIdentity.publicKey(fromText: k.publicText) == k.publicKey)
        let classic = XizIdentity()
        #expect(!classic.isPostQuantum && classic.publicText.hasPrefix("xizpk1"))
        #expect(try XizIdentity.publicKey(fromText: classic.publicText).count == 32)
        #expect(throws: XipperError.self) { _ = try XizIdentity.publicKey(fromText: String(k.publicText.dropLast(4))) }
        #expect(throws: XipperError.self) { _ = try XizIdentity.publicKey(fromText: "xizpq1" + Base64URL.encode(classic.publicKey)) }
    }

    @Test func recipientsAndCustodians() throws {
        XizCredentials.shared.removeAll()
        defer { XizCredentials.shared.removeAll() }
        let t = TempDir()
        tree(t)
        let lab = XizIdentity(postQuantum: true), dpo = XizIdentity(postQuantum: true), it = XizIdentity(postQuantum: true)
        let classic = XizIdentity()
        var o = CreateOptions()
        o.format = .xiz
        o.xizKDF = .minimum
        o.xizAccess = XizAccess(
            groups: [.init(name: "referti", prefixes: ["src/referti"]), .init(name: "dati", prefixes: ["src/dati"])],
            recipients: [.init(label: "Laboratorio", credential: .publicKey(lab.publicKey)),
                         .init(label: "Ricerca", credential: .publicKey(classic.publicKey), groups: [""])],
            thresholds: [.init(label: "Dati", k: 2, custodians: [
                .init(label: "DPO", credential: .publicKey(dpo.publicKey)), .init(label: "IT", credential: .publicKey(it.publicKey)),
                .init(label: "Direttore", credential: .password("dir"))], groups: ["dati"])])
        let a = t.url("pq.xiz")
        try Xipper.create(from: [t.url("src")], to: a, options: o)
        let sb = try Xiz.Superblock.decode(try FileReader(path: a.path).read(at: 0, count: 64))
        #expect(sb.minor == 7 && sb.required == [.encrypted, .directory])

        let all: Set = ["src/indice.txt", "src/referti/r1.txt", "src/dati/g.bin"]
        XizCredentials.shared.add(identity: lab)
        #expect(try paths(a) == all)
        #expect(try Xipper.test(a).isOK)
        t.mkdir("out")
        try Xipper.extract(a, to: t.url("out"), mode: .into, options: ExtractOptions())
        #expect(treesEqual(t.path + "/src", t.path + "/out/src").0)
        XizCredentials.shared.removeAll()

        // The X25519 recipient next to the X-Wing ones: its group only.
        XizCredentials.shared.add(identity: classic)
        #expect(try paths(a) == ["src/indice.txt"])
        XizCredentials.shared.removeAll()

        // Two post-quantum custodians, or one with the password custodian.
        XizCredentials.shared.add(identity: dpo)
        #expect(throws: XipperError.self) { _ = try Xipper.list(a) }
        XizCredentials.shared.add(identity: it)
        #expect(try paths(a) == ["src/dati/g.bin"])
        XizCredentials.shared.removeAll()
        XizCredentials.shared.add(identity: it)
        #expect(try paths(a, password: "dir") == ["src/dati/g.bin"])
        XizCredentials.shared.removeAll()

        // Another X-Wing key, even with a matching-looking archive, opens nothing.
        XizCredentials.shared.add(identity: XizIdentity(postQuantum: true))
        #expect(throws: XipperError.self) { _ = try Xipper.list(a) }
        XizCredentials.shared.removeAll()

        // Public description: labels and key ids, without any key.
        let info = try Xipper.xizInfo(a)
        #expect(info.recipients.map(\.label) == ["Laboratorio", "Ricerca", "Dati", "DPO", "IT", "Direttore"])
        #expect(info.matches(publicKeys: [lab.publicText]) && info.matches(publicKeys: [it.publicText]))
        #expect(!info.matches(publicKeys: [XizIdentity(postQuantum: true).publicText]))

        // Appending keeps 1.7 and the keys block.
        XizCredentials.shared.add(identity: lab)
        t.write("extra/r2.txt", "referto due\n")
        try Xipper.edit(a, changes: [.add(t.url("extra/r2.txt"), as: "src/referti/r2.txt")])
        #expect(try paths(a).contains("src/referti/r2.txt"))
        #expect(try Xipper.test(a).isOK)
    }

    /// A ciphertext changed in the keys block: the block's CRC, then AES-GCM over the header.
    @Test func alteredStanzasDoNotOpen() throws {
        XizCredentials.shared.removeAll()
        defer { XizCredentials.shared.removeAll() }
        let t = TempDir()
        tree(t)
        let lab = XizIdentity(postQuantum: true)
        var o = CreateOptions()
        o.format = .xiz
        o.xizAccess = XizAccess(recipients: [.init(label: "Lab", credential: .publicKey(lab.publicKey))])
        try Xipper.create(from: [t.url("src")], to: t.url("a.xiz"), options: o)
        let superblock = try FileReader(path: t.path + "/a.xiz").read(at: 0, count: 64)
        let keys = try FileReader(path: t.path + "/a.xiz").read(at: 64, count: Int(try Xiz.Superblock.decode(superblock).keysLength))
        #expect(try XizAccessKeys.open(keys, superblock: superblock, passwords: [], identities: [lab]).groupKeys.count == 1)
        for at in [4 + 2 + 3 + 10, 4 + 2 + 3 + 1119, 4 + 2 + 3 + 1125] {  // ciphertext, its last byte, key id
            var b = keys
            b[at] ^= 0x40
            let crc = Xiz.crc32c(Array(b[..<(b.count - 4)]))
            withUnsafeBytes(of: crc.littleEndian) { b.replaceSubrange((b.count - 4)..., with: $0) }
            #expect(try XizAccessKeys.open(b, superblock: superblock, passwords: [], identities: [lab]).groupKeys.isEmpty)
        }
    }
}
