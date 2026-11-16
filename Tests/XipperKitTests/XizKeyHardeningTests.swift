import CryptoKit
import Foundation
import Testing
@testable import XipperKit

/// XIZ 1.14 (§24) and the password checks of 3.5 (docs/STUDIO_XIZ_ATTACCHI.md): key commitment,
/// NFC passwords, passwords bound to a second factor; zxcvbn strength and Diceware passphrases.
@Suite("XIZ 1.14: commitment, NFC, factors; password strength", .serialized)
struct XizKeyHardeningTests {
    func create(_ t: TempDir, _ name: String, password: String, factor: XizFactor? = nil, access: XizAccess? = nil) throws -> URL {
        t.write("src/a.txt", "riservato\n")
        t.write("src/b.bin", sampleData(50_000, seed: 4))
        var o = CreateOptions()
        o.format = .xiz
        o.password = password
        o.xizKDF = .minimum
        o.xizPasswordFactor = factor?.bytes
        o.xizAccess = access
        let url = t.url(name)
        try Xipper.create(from: [t.url("src")], to: url, options: o)
        return url
    }

    /// Superblock and keys block of an archive.
    func keys(_ url: URL) throws -> (sb: [UInt8], block: [UInt8]) {
        let d = Array(try Data(contentsOf: url))
        let sb = Array(d[0..<Xiz.superblockSize])
        let len = Int(try Xiz.Superblock.decode(sb).keysLength)
        return (sb, Array(d[Xiz.superblockSize..<(Xiz.superblockSize + len)]))
    }

    /// The keys block's stanzas.
    func stanzas(_ block: [UInt8]) -> [(type: UInt8, body: [UInt8])] {
        var out: [(UInt8, [UInt8])] = []
        var p = 6
        for _ in 0..<Int(UInt16(block[4]) | UInt16(block[5]) << 8) {
            let len = Int(UInt16(block[p + 1]) | UInt16(block[p + 2]) << 8)
            out.append((block[p], Array(block[(p + 3)..<(p + 3 + len)])))
            p += 3 + len
        }
        return out
    }

    /// A keys block from stanzas, CRC included.
    func block(_ s: [(type: UInt8, body: [UInt8])]) -> [UInt8] {
        var w = ByteWriter(capacity: 256)
        w.append(Xiz.keysMagic); w.u16(UInt16(s.count))
        for (t, b) in s { w.u8(t); w.u16(UInt16(b.count)); w.append(b) }
        w.u32(Xiz.crc32c(w.bytes))
        return w.bytes
    }

    @Test func passwordArchivesCarryACommitment() throws {
        let t = TempDir()
        let a = try create(t, "p.xiz", password: "una password lunga abbastanza")
        let (sb, b) = try keys(a)
        #expect(try Xiz.Superblock.decode(sb).minor == 14)
        let s = stanzas(b)
        #expect(s.map(\.type) == [1, 9])
        #expect(try XizKeys.open(keysBlock: b, superblock: sb, password: "una password lunga abbastanza").withUnsafeBytes { $0.count } == 32)
        // A different commitment: refused, not opened.
        var bad = s
        bad[1].body[5] ^= 1
        #expect(throws: XipperError.self) { _ = try XizKeys.open(keysBlock: block(bad), superblock: sb, password: "una password lunga abbastanza") }
        // Without the stanza a 1.14 archive is refused; a 1.13 one (no commitment then) opens.
        #expect(throws: XipperError.self) { _ = try XizKeys.open(keysBlock: block([s[0]]), superblock: sb, password: "una password lunga abbastanza") }
    }

    /// "Invisible salamanders": two recipients whose stanzas unwrap different group keys. The
    /// commitment matches one of them; the other is refused.
    @Test func differentKeysForDifferentRecipientsAreRefused() throws {
        let id = [UInt8](repeating: 7, count: 16)
        var sb = Xiz.Superblock(archiveID: id)
        sb.minor = 14
        sb.required = [.encrypted, .directory]
        let k1 = SymmetricKey(size: .bits256), k2 = SymmetricKey(size: .bits256)
        var policyA = XizAccess(), policyB = XizAccess()
        policyA.recipients = [.init(label: "A", credential: .password("alfa"))]
        policyB.recipients = [.init(label: "B", credential: .password("beta"))]
        let a = try XizAccessKeys.prepare(policyA, groupIDs: [XizAccess.defaultGroup: 0], groupKeys: [0: k1], archiveID: id, kdf: .minimum)
        let b = try XizAccessKeys.prepare(policyB, groupIDs: [XizAccess.defaultGroup: 0], groupKeys: [0: k2], archiveID: id, kdf: .minimum)
        // A's recipient and commitment, B's recipient (made for another key).
        let stanzasList = [a[0], b[0], a[1]]
        sb.keysLength = UInt32(XizAccessKeys.size(stanzasList))
        let sbBytes = sb.encode()
        let blk = try XizAccessKeys.seal(stanzasList, superblock: sbBytes)
        #expect(try XizAccessKeys.open(blk, superblock: sbBytes, passwords: ["alfa"], identities: []).groupKeys.count == 1)
        #expect(throws: XipperError.self) { _ = try XizAccessKeys.open(blk, superblock: sbBytes, passwords: ["beta"], identities: []) }
    }

    /// §24.2: the same password composed (NFC) or decomposed (NFD) opens the archive.
    @Test func nfcAndNfdPasswordsAgree() throws {
        let t = TempDir()
        let nfd = "citta\u{0300} perduta e\u{0301}terna"
        let nfc = nfd.precomposedStringWithCanonicalMapping
        #expect(nfd.utf8.count != nfc.utf8.count)
        let a = try create(t, "n.xiz", password: nfd)
        #expect(try Xipper.test(a, password: nfc).isOK)
        #expect(try Xipper.test(a, password: nfd).isOK)
        // Access archives (type 2 stanzas) too.
        var acc = XizAccess()
        acc.recipients = [.init(label: "x", credential: .password(nfc))]
        let b = try create(t, "g.xiz", password: nfd, access: acc)
        #expect(try Xipper.test(b, password: nfd).isOK)
        #expect(XizKeys.passwordForms(nfd).map { Array($0.utf8) } == [Array(nfd.utf8), Array(nfc.utf8)] && XizKeys.passwordForms(nfc).count == 1)
    }

    @Test func passwordWithFactor() throws {
        let t = TempDir()
        defer { XizCredentials.shared.removeAll() }
        let f = XizFactor()
        #expect(try XizFactor(text: "commento\n" + f.text + "\n") == f)
        let file = t.url("k.xizfactor")
        try f.write(to: file)
        #expect(try XizFactor(contentsOf: file) == f)
        #expect(throws: XipperError.self) { try f.write(to: file) }  // never replaced
        let a = try create(t, "f.xiz", password: "corta", factor: f)
        #expect(XizFactor.required(by: a) == [f.id])
        let (sb, b) = try keys(a)
        #expect(try Xiz.Superblock.decode(sb).minor == 14)
        #expect(stanzas(b).map(\.type) == [8, 9])
        // Without the factor: a clear error, not "wrong password".
        do {
            _ = try Xipper.list(a, password: "corta")
            Issue.record("opened without the factor")
        } catch let XipperError.invalidArgument(m) {
            #expect(m.contains("factor"))
        }
        XizCredentials.shared.add(factor: XizFactor().bytes)  // another factor: still missing
        #expect(throws: XipperError.self) { _ = try Xipper.list(a, password: "corta") }
        XizCredentials.shared.add(factor: f.bytes)
        #expect(throws: XipperError.wrongPassword(entry: "f.xiz")) { _ = try Xipper.list(a, password: "lunga") }
        #expect(try Xipper.test(a, password: "corta").isOK)
        let out = t.url("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var x = ExtractOptions()
        x.password = "corta"
        try Xipper.extract(a, to: out, mode: .into, options: x)
        #expect(try String(contentsOf: out.appendingPathComponent("src/a.txt"), encoding: .utf8) == "riservato\n")
        // Custodians cannot be factor passwords.
        var acc = XizAccess()
        acc.thresholds = [.init(label: "t", k: 2, custodians: [.init(label: "1", credential: .passwordWithFactor("x", factor: f.bytes)),
                                                                 .init(label: "2", credential: .password("y"))])]
        #expect(throws: XipperError.self) { _ = try create(t, "c.xiz", password: "z", access: acc) }
    }

    /// Phase B (3.5): weak parameters are reported; rekey rewraps in place, with a new password
    /// or stronger parameters, keeping content, other recipients and the recovery record.
    @Test func rekeyInPlace() throws {
        let t = TempDir()
        let a = try create(t, "r.xiz", password: "vecchia frase lunga")
        let weak = try #require(try Xipper.xizInfo(a).weakKDF)
        #expect(weak.memoryKiB == 19 << 10 && weak.iterations == 1)
        _ = try Xipper.addXizRecovery(a, redundancy: 10)
        let size = try FileManager.default.attributesOfItem(atPath: a.path)[.size] as? Int
        #expect(throws: XipperError.wrongPassword(entry: "r.xiz")) { try Xipper.xizRekey(a, password: "sbagliata") }
        #expect(try Xipper.xizRekey(a, password: "vecchia frase lunga", newPassword: "nuova frase lunga") == 1)
        let info = try Xipper.xizInfo(a)
        #expect(info.weakKDF == nil && info.passwordKDFs.map(\.profile) == [.standard])
        #expect(try FileManager.default.attributesOfItem(atPath: a.path)[.size] as? Int == size)
        #expect(throws: XipperError.self) { _ = try Xipper.list(a, password: "vecchia frase lunga") }
        #expect(try Xipper.test(a, password: "nuova frase lunga").isOK)
        #expect(try Xipper.scrubXiz(a).damagedRanges.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: a.path + ".keys-backup"))
        // NFD given, NFC stored: both open after a rekey.
        let nfd = "citta\u{0300} nuova e\u{0301}terna"
        try Xipper.xizRekey(a, password: "nuova frase lunga", newPassword: nfd)
        #expect(try Xipper.test(a, password: nfd.precomposedStringWithCanonicalMapping).isOK)
    }

    @Test func rekeyAccessArchives() throws {
        let t = TempDir()
        defer { XizCredentials.shared.removeAll() }
        var acc = XizAccess()
        acc.recipients = [.init(label: "anna", credential: .password("password di anna"))]
        let a = try create(t, "g.xiz", password: "password principale", access: acc)
        #expect(try Xipper.xizInfo(a).passwordKDFs.count == 2)
        #expect(try Xipper.xizRekey(a, password: "password di anna", newPassword: "nuova di anna") == 1)
        #expect(try Xipper.test(a, password: "password principale").isOK)
        #expect(try Xipper.test(a, password: "nuova di anna").isOK)
        #expect(Set(try Xipper.xizInfo(a).passwordKDFs.map(\.isWeak)) == [false, true])
        // A password bound to a key file: rewrapped only with the file.
        let f = XizFactor()
        let b = try create(t, "f.xiz", password: "corta", factor: f)
        #expect(throws: XipperError.self) { try Xipper.xizRekey(b, password: "corta") }
        XizCredentials.shared.add(factor: f.bytes)
        #expect(try Xipper.xizRekey(b, password: "corta", newPassword: "ancora corta") == 1)
        #expect(try Xipper.test(b, password: "ancora corta").isOK)
    }

    /// A rekey cut short after the backup: the next one puts the old block back if the one on
    /// disk does not check.
    @Test func interruptedRekeyIsRecovered() throws {
        let t = TempDir()
        let a = try create(t, "i.xiz", password: "frase di prova lunga")
        let (sb, old) = try keys(a)
        _ = sb
        try Data(old).write(to: URL(fileURLWithPath: a.path + ".keys-backup"))
        let h = try FileHandle(forUpdating: a)
        try h.seek(toOffset: UInt64(Xiz.superblockSize + 20)); try h.write(contentsOf: Data([0xFF, 0x00, 0xAA])); try h.close()
        #expect(throws: XipperError.self) { _ = try Xipper.list(a, password: "frase di prova lunga") }
        try Xipper.xizRekey(a, password: "frase di prova lunga")
        #expect(try Xipper.test(a, password: "frase di prova lunga").isOK)
        #expect(!FileManager.default.fileExists(atPath: a.path + ".keys-backup"))
    }

    @Test func strengthEstimates() {
        #expect(PasswordStrength.estimate("Password2026!").isWeak)
        #expect(PasswordStrength.estimate("Estate2026!").isWeak)
        #expect(PasswordStrength.estimate("pässwörd").isWeak)  // diacritics do not help
        #expect(PasswordStrength.estimate("").bits == 0)
        let strong = PasswordStrength.estimate("polli-fresco-unisci-au-rigori-alzavo")
        #expect(!strong.isWeak && strong.level == .excellent)
        // A word of the context (the archive's name) counts as a dictionary word.
        #expect(PasswordStrength.estimate("bilancio2026", userWords: ["bilancio"]).bits < PasswordStrength.estimate("bilancio2026").bits + 0.01)
        #expect(PasswordStrength.estimate("Estate2026!").crackSeconds < 3600)
    }

    @Test func passphrases() throws {
        for lang in Passphrase.Language.allCases {
            let list = try #require(Passphrase.wordList(lang))
            #expect(list.count == 7776 && Set(list).count == 7776)
            let p = try #require(Passphrase.generate(words: 6, language: lang))
            let words = p.split(separator: "-").map(String.init)
            #expect(words.count == 6 && words.allSatisfy(Set(list).contains))
            #expect(Passphrase.generate(words: 6, language: lang) != p)
        }
        #expect(Int(Passphrase.bits(words: 6)) == 77)
    }

    /// The app bundles the same lists as Vendor/wordlists.
    @Test func bundledListsMatchVendor() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["eff_large_wordlist.txt", "word_list_diceware_it-IT-4.txt"] {
            #expect(try Data(contentsOf: root.appendingPathComponent("Vendor/wordlists/" + name))
                    == Data(contentsOf: root.appendingPathComponent("App/Xipper/Wordlists/" + name)))
        }
    }
}
