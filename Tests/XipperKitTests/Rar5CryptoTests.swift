import Foundation
import Testing
@testable import XipperKit

/// Encrypted RAR5 (AES-256), on libarchive's test vectors: four files a.txt…d.txt, "This is from
/// <name>"; all encrypted with "password" when solid or with encrypted names, otherwise a.txt and
/// c.txt plain, b.txt with "password" and d.txt with "password2".
@Suite("RAR5 encryption")
struct Rar5CryptoTests {
    static func url(_ name: String) -> URL { RarTests.url(name) }

    /// The decrypted stream is a plain RAR5 archive the system bsdtar (libarchive) reads.
    @Test(arguments: ["rar5_solid_encrypted.rar", "rar5_solid_encrypted_filenames.rar"])
    func plainStreamIsAValidArchive(name: String) throws {
        let t = TempDir()
        let s = try Rar5PlainStream(path: Self.url(name).path, password: "password")
        var out: [UInt8] = []
        while true { let c = try s.next(); if c.isEmpty { break }; out += c }
        try Data(out).write(to: t.url("plain.rar"))
        t.mkdir("x")
        let r = run("/usr/bin/tar", ["-xf", t.path + "/plain.rar", "-C", t.path + "/x"])
        #expect(r.status == 0, "\(r.output)")
    }

    func text(_ a: URL, _ p: String, _ pw: String?) throws -> String {
        String(decoding: try Xipper.readEntry(a, path: p, password: pw).data, as: UTF8.self)
    }

    @Test(arguments: ["rar5_solid_encrypted.rar", "rar5_solid_encrypted_filenames.rar", "rar5_encrypted_filenames.rar"])
    func allFilesWithOnePassword(name: String) throws {
        let a = Self.url(name)
        #expect(try Set(Xipper.list(a, password: "password").map(\.path)) == ["a.txt", "b.txt", "c.txt", "d.txt"])
        for f in ["a.txt", "b.txt", "c.txt", "d.txt"] { #expect(try text(a, f, "password") == "This is from \(f)") }
        #expect(try Xipper.test(a, password: "password").isOK)
        let t = TempDir()
        var x = ExtractOptions()
        x.password = "password"
        try Xipper.extract(a, to: t.url(""), mode: .into, options: x)
        #expect(try String(contentsOfFile: t.path + "/c.txt", encoding: .utf8) == "This is from c.txt")
        if name.contains("filenames") {
            // Encrypted names: nothing without the password, and a wrong one is reported as such.
            #expect(throws: XipperError.passwordRequired(entry: name)) { try Xipper.list(a) }
            #expect(throws: XipperError.wrongPassword(entry: name)) { try Xipper.list(a, password: "nope") }
        } else {
            #expect(try Xipper.list(a).count == 4)  // names are readable
            #expect(throws: XipperError.self) { try text(a, "b.txt", nil) }
            #expect(throws: XipperError.self) { try text(a, "b.txt", "nope") }
        }
    }

    /// Non-solid: a.txt and c.txt plain, b.txt with "password", d.txt with "password2".
    @Test func filesWithDifferentPasswords() throws {
        let a = Self.url("rar5_encrypted.rar")
        #expect(try Xipper.list(a).map(\.path).sorted() == ["a.txt", "b.txt", "c.txt", "d.txt"])
        #expect(try text(a, "a.txt", nil) == "This is from a.txt")
        #expect(throws: XipperError.passwordRequired(entry: "rar5_encrypted.rar")) { try text(a, "b.txt", nil) }
        #expect(try text(a, "b.txt", "password") == "This is from b.txt")
        #expect(try text(a, "c.txt", "password") == "This is from c.txt")
        #expect(throws: XipperError.wrongPassword(entry: "rar5_encrypted.rar")) { try text(a, "d.txt", "password") }
        #expect(try text(a, "d.txt", "password2") == "This is from d.txt")
    }

    /// Key derivation and tweaked checksums on fixed inputs (cross-checked with the vectors above,
    /// whose password checks and header CRCs only pass with the right keys).
    @Test func checkValueAndTweakAreStable() throws {
        let k = try Rar5Crypto.keys(password: "password", salt: Array(repeating: 1, count: 16), log2Count: 4)
        let k2 = try Rar5Crypto.keys(password: "password", salt: Array(repeating: 1, count: 16), log2Count: 4)
        #expect(k.key == k2.key && k.key != k.hashKey && k.check.count == 8)
        #expect(Rar5Crypto.tweak(crc: 0x1234_5678, hashKey: k.hashKey) != 0x1234_5678)
        #expect(throws: XipperError.self) { _ = try Rar5Crypto.keys(password: "p", salt: [], log2Count: 30) }
    }
}
