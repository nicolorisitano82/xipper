import CryptoKit
import Foundation
import Testing
@testable import XipperKit

/// XIZ 1.3 (§13): access groups, recipients, k-of-n custodians, signed and time-stamped changes.
@Suite("XIZ access groups and signatures", .serialized)
struct XizAccessTests {
    func tree(_ t: TempDir) {
        t.write("src/indice.txt", "indice del caso\n")
        t.write("src/referti/r1.txt", "referto uno\n")
        t.write("src/referti/r2.txt", "referto due\n")
        t.write("src/dati/grezzi/g1.bin", sampleData(300_000, seed: 1))
        t.write("src/dati/grezzi/g2.bin", sampleData(5 << 20, seed: 2))  // more than one frame
        t.write("src/dati/note.txt", "note\n")
    }

    func paths(_ a: URL, password: String? = nil) throws -> Set<String> {
        Set(try Xipper.list(a, password: password).filter { $0.kind == .file }.map(\.path))
    }

    @Test func shamirAnyKOfN() {
        var secret = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&secret, 32)
        let shares = Shamir.split(secret, k: 3, n: 5)
        for pick in [[0, 1, 2], [4, 2, 0], [1, 3, 4], [0, 1, 2, 3, 4]] {
            #expect(Shamir.combine(pick.map { (UInt8($0 + 1), shares[$0]) }) == secret)
        }
        #expect(Shamir.combine([(1, shares[0]), (2, shares[1])]) != secret)  // two of three: nothing
    }

    @Test func groupsRecipientsAndCustodians() throws {
        XizCredentials.shared.removeAll()
        defer { XizCredentials.shared.removeAll() }
        let t = TempDir()
        tree(t)
        let researcher = XizIdentity()
        var o = CreateOptions()
        o.format = .xiz
        o.xizKDF = .minimum
        o.xizAccess = XizAccess(
            groups: [.init(name: "referti", prefixes: ["src/referti"]), .init(name: "grezzi", prefixes: ["src/dati/grezzi"])],
            recipients: [.init(label: "Laboratorio", credential: .password("lab-pass")),
                         .init(label: "Clinico", credential: .password("clin-pass"), groups: ["referti"]),
                         .init(label: "Ricerca", credential: .publicKey(researcher.publicKey), groups: [XizAccess.defaultGroup])],
            thresholds: [.init(label: "Dati grezzi", k: 2, custodians: [
                .init(label: "DPO", credential: .password("dpo")), .init(label: "Direttore", credential: .password("dir")),
                .init(label: "IT", credential: .password("it"))], groups: ["grezzi"])])
        let a = t.url("caso.xiz")
        try Xipper.create(from: [t.url("src")], to: a, options: o)

        let all: Set = ["src/indice.txt", "src/referti/r1.txt", "src/referti/r2.txt", "src/dati/grezzi/g1.bin", "src/dati/grezzi/g2.bin", "src/dati/note.txt"]
        #expect(try paths(a, password: "lab-pass") == all)
        #expect(try Xipper.test(a, password: "lab-pass").isOK)
        t.mkdir("lab")
        var x = ExtractOptions()
        x.password = "lab-pass"
        try Xipper.extract(a, to: t.url("lab"), mode: .into, options: x)
        #expect(treesEqual(t.path + "/src", t.path + "/lab/src").0)

        // The clinician sees the reports only; the rest is not even listed.
        #expect(try paths(a, password: "clin-pass") == ["src/referti/r1.txt", "src/referti/r2.txt"])
        #expect(try Xipper.xizAccess(a, password: "clin-pass").hidden == 2)
        #expect(try Xipper.test(a, password: "clin-pass").isOK)
        #expect(try String(decoding: Xipper.readEntry(a, path: "src/referti/r2.txt", password: "clin-pass").data, as: UTF8.self) == "referto due\n")

        // The researcher's key opens the main group.
        XizCredentials.shared.add(identity: researcher)
        #expect(try paths(a) == ["src/indice.txt", "src/dati/note.txt"])
        XizCredentials.shared.removeAll()

        // Custodians: one is not enough, two are.
        #expect(throws: XipperError.self) { _ = try Xipper.list(a, password: "dpo") }
        XizCredentials.shared.add(password: "it")
        #expect(try paths(a, password: "dpo") == ["src/dati/grezzi/g1.bin", "src/dati/grezzi/g2.bin"])
        XizCredentials.shared.removeAll()

        #expect(throws: XipperError.wrongPassword(entry: "caso.xiz")) { _ = try Xipper.list(a, password: "nope") }
        #expect(throws: XipperError.passwordRequired(entry: "caso.xiz")) { _ = try Xipper.list(a) }

        // Changes: whoever holds every group appends; files land in the group of their folder.
        t.write("extra/r3.txt", "referto tre\n")
        try Xipper.edit(a, changes: [.add(t.url("extra/r3.txt"), as: "src/referti/r3.txt")], password: "lab-pass")
        #expect(try paths(a, password: "clin-pass").contains("src/referti/r3.txt"))
        #expect(throws: XipperError.self) { try Xipper.edit(a, changes: [.delete("src/referti/r1.txt")], password: "clin-pass") }
        #expect(throws: XipperError.self) {
            try Xipper.edit(a, changes: [.rename("src/referti/r1.txt", to: "src/dati/grezzi/r1.txt")], password: "lab-pass")
        }
        #expect(try Xipper.test(a, password: "lab-pass").isOK)
    }

    @Test func signedHistoryIsChainedAndTamperEvident() throws {
        let t = TempDir()
        tree(t)
        let alice = XizSigningKey(), bob = XizSigningKey()
        var o = CreateOptions()
        o.format = .xiz
        o.xizSigner = XizSigner(key: alice, label: "Alice")
        let a = t.url("firmato.xiz")
        try Xipper.create(from: [t.url("src")], to: a, options: o)
        t.write("extra/n.txt", "nuovo\n")
        var b = CreateOptions()
        b.xizSigner = XizSigner(key: bob, label: "Bob")
        try Xipper.edit(a, changes: [.add(t.url("extra/n.txt"), as: "src/n.txt")], options: b)
        try Xipper.edit(a, changes: [.delete("src/dati/note.txt")])  // unsigned change
        try Xipper.edit(a, changes: [.delete("src/n.txt")], options: b)

        let h = try Xipper.xizHistory(a)
        #expect(h.map(\.signed) == [true, true, false, true])
        #expect(h[0].label == "Alice" && h[0].publicKey == alice.publicKey && h[0].valid && h[0].chained)
        #expect(h[1].label == "Bob" && h[1].valid && h[1].chained)
        #expect(h[3].valid && h[3].chained)  // after an unsigned segment the chain restarts from zeros
        #expect(try Xipper.test(a).isOK)
        #expect(try paths(a).contains("src/referti/r1.txt"))

        // Rewriting the first signer's name (and every checksum around it) breaks the signature.
        var bytes = try [UInt8](Data(contentsOf: a))
        let first = try firstDirectory(bytes)
        let label = first.dir + first.sigStart + 1 + 32 + 1
        #expect(bytes[label] == UInt8(ascii: "A"))
        bytes[label] = UInt8(ascii: "E")
        try refresh(&bytes, first)
        try Data(bytes).write(to: a)
        let after = try Xipper.xizHistory(a)
        #expect(!after[0].valid && after[1].valid && !after[1].chained)
    }

    /// The first segment's directory: offset in the file, where its signature starts, its footer.
    func firstDirectory(_ b: [UInt8]) throws -> (dir: Int, len: Int, sigStart: Int, footer: Int) {
        var at = b.count - Xiz.footerSize
        while true {
            let f = try Xiz.Footer.decode(Array(b[at..<(at + Xiz.footerSize)]))
            if f.previousFooter == 0 {
                let dir = Int(f.catalogOffset), len = Int(f.catalogCSize)
                func u16(_ o: Int) -> Int { Int(UInt16(b[dir + o]) | UInt16(b[dir + o + 1]) << 8) }
                // Version 2: magic, version, flags, groups, slot tables, leaf table, then the signature.
                let groups = u16(8)
                let tables = u16(10 + groups * 62)
                return (dir, len, 10 + groups * 62 + 2 + tables * 16 + 44 + 4, at)
            }
            at = Int(f.previousFooter)
        }
    }

    func refresh(_ b: inout [UInt8], _ d: (dir: Int, len: Int, sigStart: Int, footer: Int)) throws {
        let crc = Xiz.crc32c(Array(b[d.dir..<(d.dir + d.len - 4)]))
        withUnsafeBytes(of: crc.littleEndian) { b.replaceSubrange((d.dir + d.len - 4)..<(d.dir + d.len), with: $0) }
        var f = try Xiz.Footer.decode(Array(b[d.footer..<(d.footer + Xiz.footerSize)]))
        f.catalogSHA256 = Xiz.sha256(Array(b[d.dir..<(d.dir + d.len)]))
        b.replaceSubrange(d.footer..<(d.footer + Xiz.footerSize), with: f.encode())
    }

    static let openssl = ["/opt/homebrew/opt/openssl@3/bin/openssl", "/usr/local/opt/openssl@3/bin/openssl"].first(where: toolExists)

    /// RFC 3161 against a local authority made with OpenSSL: our request is accepted, the token
    /// verifies, its imprint and time are read back.
    @Test(.enabled(if: openssl != nil))
    func rfc3161TokenFromLocalAuthority() throws {
        let t = TempDir()
        let ossl = Self.openssl!
        t.write("tsa.cnf", """
            [ req ]
            distinguished_name = dn
            prompt = no
            [ dn ]
            CN = Xipper Test TSA
            [ ext ]
            basicConstraints = CA:FALSE
            keyUsage = critical, digitalSignature
            extendedKeyUsage = critical, timeStamping
            [ tsa ]
            default_tsa = tsa1
            [ tsa1 ]
            dir = .
            serial = ./serial
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
        t.write("serial", "01\n")
        #expect(run(ossl, ["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes", "-keyout", "tsa.key",
                           "-out", "tsa.pem", "-days", "2", "-config", "tsa.cnf", "-extensions", "ext"], cwd: t.path).status == 0)
        let signature = (0..<64).map { UInt8($0) }
        let imprint = Xiz.sha256(signature)
        try Data(RFC3161.requestDER(imprint: imprint, nonce: [0x12, 0x34, 0x56])).write(to: t.url("q.tsq"))
        let r = run(ossl, ["ts", "-reply", "-queryfile", "q.tsq", "-signer", "tsa.pem", "-inkey", "tsa.key", "-config", "tsa.cnf",
                           "-section", "tsa1", "-out", "r.tsr"], cwd: t.path)
        #expect(r.status == 0, "\(r.output)")
        let token = try RFC3161.tokenFromResponse([UInt8](Data(contentsOf: t.url("r.tsr"))))
        let ts = try RFC3161.verify(token, imprint: imprint)
        #expect(ts.valid && !ts.trusted)  // a self-made authority is not a trusted root
        #expect(abs(ts.time.timeIntervalSinceNow) < 120)
        #expect(ts.authority.contains("Xipper Test TSA"))
        #expect(!(try RFC3161.verify(token, imprint: Xiz.sha256([1, 2, 3]))).valid)  // another signature
    }

    // MARK: inclusion proofs (§13.6)

    @Test func proofsBindOneFileToTheSignedArchive() throws {
        let t = TempDir()
        tree(t)
        var o = CreateOptions()
        o.format = .xiz
        o.xizKDF = .minimum
        o.xizAccess = XizAccess(groups: [.init(name: "referti", prefixes: ["src/referti"])],
                                recipients: [.init(label: "Lab", credential: .password("lab")),
                                             .init(label: "Clinico", credential: .password("clin"), groups: ["referti"])])
        let signer = XizSigner(key: XizSigningKey(), label: "Laboratorio")
        o.xizSigner = signer
        let a = t.url("p.xiz")
        try Xipper.create(from: [t.url("src")], to: a, options: o)

        // The clinician, who sees only the reports, proves one of them.
        let proof = try Xipper.xizProof(a, path: "src/referti/r1.txt", password: "clin")
        let ok = try Xipper.xizVerifyProof(proof, file: t.url("src/referti/r1.txt"))
        #expect(ok.valid && ok.signerLabel == "Laboratorio" && ok.path == "src/referti/r1.txt")
        // Another content, or a rigged index, does not pass.
        t.write("fake.txt", "referto falso\n")
        #expect(!(try Xipper.xizVerifyProof(proof, file: t.url("fake.txt"))).contentMatches)
        var doc = try JSONSerialization.jsonObject(with: proof) as! [String: Any]
        doc["index"] = ((doc["index"] as! Int) + 1) % (doc["tree_size"] as! Int)
        #expect(!(try Xipper.xizVerifyProof(try JSONSerialization.data(withJSONObject: doc), file: t.url("src/referti/r1.txt"))).inTree)
        // A big file, from the main group.
        let big = try Xipper.xizVerifyProof(try Xipper.xizProof(a, path: "src/dati/grezzi/g2.bin", password: "lab"), file: t.url("src/dati/grezzi/g2.bin"))
        #expect(big.valid)
        // After a rename, the new name proves; the old proof still checks against its own segment.
        var b = CreateOptions()
        b.xizSigner = signer
        try Xipper.edit(a, changes: [.rename("src/referti/r1.txt", to: "src/referti/primo.txt")], password: "lab", options: b)
        #expect(try Xipper.xizVerifyProof(try Xipper.xizProof(a, path: "src/referti/primo.txt", password: "lab"), file: t.url("src/referti/r1.txt")).valid)
        #expect(try Xipper.xizVerifyProof(proof, file: t.url("src/referti/r1.txt")).valid)
        // Unsigned archives: the tree holds, nobody vouches for it.
        var u = CreateOptions()
        u.format = .xiz
        u.xizAccess = XizAccess()
        u.password = "x"
        u.xizKDF = .minimum
        try Xipper.create(from: [t.url("src")], to: t.url("u.xiz"), options: u)
        let r = try Xipper.xizVerifyProof(try Xipper.xizProof(t.url("u.xiz"), path: "src/indice.txt", password: "x"), file: t.url("src/indice.txt"))
        #expect(r.contentMatches && r.inTree && !r.signed && !r.valid)
    }

    // MARK: erasable entries (§13.7)

    @Test func erasedFilesCannotBeReadEvenFromOlderSegments() throws {
        let t = TempDir()
        tree(t)
        t.write("src/referti/copia.txt", "referto uno\n")  // same content as r1: not shared (one key per file)
        var o = CreateOptions()
        o.format = .xiz
        o.xizKDF = .minimum
        o.xizAccess = XizAccess(groups: [.init(name: "referti", prefixes: ["src/referti"])],
                                recipients: [.init(label: "Lab", credential: .password("lab"))], erasable: true)
        let signer = XizSigner(key: XizSigningKey(), label: "DPO")
        o.xizSigner = signer
        let a = t.url("e.xiz")
        try Xipper.create(from: [t.url("src")], to: a, options: o)
        #expect(try Xipper.test(a, password: "lab").isOK)
        #expect(try String(decoding: Xipper.readEntry(a, path: "src/referti/r1.txt", password: "lab").data, as: UTF8.self) == "referto uno\n")
        let firstSegmentEnd = try Data(contentsOf: a).count
        let proof = try Xipper.xizProof(a, path: "src/indice.txt", password: "lab")

        // Erase r1 and the big file: gone from the listing, the archive still verifies.
        var b = CreateOptions()
        b.xizSigner = signer
        #expect(try Xipper.xizErase(a, paths: ["src/referti/r1.txt", "src/dati/grezzi/g2.bin"], password: "lab", options: b) == 2)
        let left = try paths(a, password: "lab")
        #expect(!left.contains("src/referti/r1.txt") && !left.contains("src/dati/grezzi/g2.bin") && left.contains("src/referti/copia.txt"))
        #expect(try Xipper.test(a, password: "lab").isOK)
        #expect(try String(decoding: Xipper.readEntry(a, path: "src/referti/copia.txt", password: "lab").data, as: UTF8.self) == "referto uno\n")

        // The first segment, cut out of the erased file, still lists r1 in its catalog, but the
        // slot is zeroed: the entry is reported erased, never readable.
        let bytes = try Data(contentsOf: a)
        try bytes.prefix(firstSegmentEnd).write(to: t.url("old.xiz"))
        let old = try XizArchive(path: t.path + "/old.xiz", password: "lab")
        #expect(old.erasedEntries == 2 && !old.catalog.entries.contains { $0.path == "src/referti/r1.txt" })
        #expect(throws: XipperError.self) { _ = try Xipper.readEntry(t.url("old.xiz"), path: "src/referti/r1.txt", password: "lab") }

        // History and the proofs of other files stay valid.
        #expect(try Xipper.xizHistory(a).allSatisfy { $0.valid && $0.chained })
        #expect(try Xipper.xizVerifyProof(proof, file: t.url("src/indice.txt")).valid)
        // Files added later are erasable too.
        t.write("extra/nuovo.txt", "nuovo\n")
        try Xipper.edit(a, changes: [.add(t.url("extra/nuovo.txt"), as: "src/referti/nuovo.txt")], password: "lab", options: b)
        #expect(try Xipper.xizErase(a, paths: ["src/referti/nuovo.txt"], password: "lab") == 1)
        #expect(!(try paths(a, password: "lab")).contains("src/referti/nuovo.txt"))
        #expect(try Xipper.test(a, password: "lab").isOK)

        // A non-erasable archive refuses.
        var n = CreateOptions()
        n.format = .xiz
        n.password = "x"
        n.xizKDF = .minimum
        n.xizSigner = signer
        try Xipper.create(from: [t.url("src")], to: t.url("n.xiz"), options: n)
        #expect(throws: XipperError.self) { try Xipper.xizErase(t.url("n.xiz"), paths: ["src/indice.txt"], password: "x") }
    }
}
