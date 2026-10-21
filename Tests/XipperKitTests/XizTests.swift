import CryptoKit
import Foundation
import Testing
@testable import XipperKit

@Suite("XIZ 1.0")
struct XizTests {
    func tree(_ t: TempDir) {
        t.write("src/text.txt", String(repeating: "Xipper XIZ ", count: 40_000))
        t.write("src/big.bin", sampleData(9 << 20, seed: 41))  // spans three frames
        t.write("src/copy/big.bin", sampleData(9 << 20, seed: 41))  // identical: stored once
        t.write("src/empty", "")
        for i in 0..<200 { t.write("src/small/f\(i).txt", "file \(i)\n") }
        t.symlink("src/link", to: "text.txt")
        let v = Array("Blu".utf8)
        _ = v.withUnsafeBytes { setxattr(t.path + "/src/text.txt", "app.xipper.xiz", $0.baseAddress, v.count, 0, 0) }
    }

    func create(_ t: TempDir, _ name: String = "a.xiz", password: String? = nil) throws -> WriteReport {
        var o = CreateOptions()
        o.format = .xiz
        o.password = password
        return try Xipper.create(from: [t.url("src")], to: t.url(name), options: o)
    }

    @Test func roundTripWithDedupAndAttributes() throws {
        let t = TempDir()
        tree(t)
        let r = try create(t)
        #expect(try ArchiveFormat.detect(t.url("a.xiz")) == .xiz)
        // The 9 MiB duplicate is stored once (random data does not compress).
        #expect(r.outputBytes < (9 << 20) + (2 << 20))
        let bytes = try [UInt8](Data(contentsOf: t.url("a.xiz")))
        #expect(Array(bytes[8..<10]) == [1, 0])  // version 1.0
        let report = try Xipper.test(t.url("a.xiz"), digests: true)
        #expect(report.isOK)
        #expect(report.digests["src/big.bin"] == report.digests["src/copy/big.bin"])
        t.mkdir("out")
        try Xipper.extract(t.url("a.xiz"), to: t.url("out"), mode: .into)
        #expect(treesEqual(t.path + "/src", t.path + "/out/src").0)
        #expect(ExtendedAttributes.read(t.path + "/out/src/text.txt").first { $0.name == "app.xipper.xiz" }?.value == Array("Blu".utf8))
        let preview = try Xipper.readEntry(t.url("a.xiz"), path: "src/text.txt", maxBytes: 11)
        #expect(String(decoding: preview.data, as: UTF8.self) == "Xipper XIZ " && preview.truncated)
        // Selection extracts only what is asked.
        t.mkdir("sel")
        var x = ExtractOptions()
        x.selection = ["src/small"]
        try Xipper.extract(t.url("a.xiz"), to: t.url("sel"), mode: .into, options: x)
        #expect(FileManager.default.fileExists(atPath: t.path + "/sel/src/small/f199.txt"))
        #expect(!FileManager.default.fileExists(atPath: t.path + "/sel/src/big.bin"))
    }

    @Test func damagedFrameIsDetectedAndNothingWrongIsWritten() throws {
        let t = TempDir()
        tree(t)
        _ = try create(t)
        var bytes = try [UInt8](Data(contentsOf: t.url("a.xiz")))
        bytes[Xiz.superblockSize + Xiz.frameHeaderSize + 1000] ^= 0x55  // inside the first frame's payload
        try Data(bytes).write(to: t.url("bad.xiz"))
        let r = try Xipper.test(t.url("bad.xiz"))
        #expect(!r.isOK)
        #expect(r.failures.contains { if case .checksumMismatch = $0.problem { true } else { false } })
        t.mkdir("out")
        #expect(throws: XipperError.self) { try Xipper.extract(t.url("bad.xiz"), to: t.url("out")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.path + "/out").isEmpty)  // smart mode cleaned up
        // Truncation and a damaged catalog are refused before anything else.
        try Data(bytes.prefix(bytes.count - 10)).write(to: t.url("short.xiz"))
        #expect(throws: XipperError.self) { _ = try Xipper.list(t.url("short.xiz")) }
    }

    // MARK: encryption

    @Test func argon2idMatchesTheReferenceVector() throws {
        // phc-winner-argon2 src/test.c: Argon2id v1.3, t=2, m=2^16 KiB, p=1, "password", "somesalt".
        let key = try XizKeys.argon2id("password", salt: Array("somesalt".utf8),
                                       XizKeys.KDF(memoryKiB: 1 << 16, iterations: 2, parallelism: 1))
        let hex = key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
        #expect(hex == "09316115d5cf24ed5a15a31a3ba326e5cf32edc24702987c02b6566f61913cf7")
    }

    @Test func encryptedArchiveHidesNamesAndContent() throws {
        let t = TempDir()
        tree(t)
        _ = try create(t, password: "una password")
        let bytes = try Data(contentsOf: t.url("a.xiz"))
        #expect(bytes.range(of: Data("small/f1".utf8)) == nil && bytes.range(of: Data("text.txt".utf8)) == nil)
        #expect(bytes.range(of: Data("Xipper XIZ Xipper".utf8)) == nil)
        #expect(throws: XipperError.passwordRequired(entry: "a.xiz")) { _ = try Xipper.list(t.url("a.xiz")) }
        #expect(throws: XipperError.wrongPassword(entry: "a.xiz")) { _ = try Xipper.list(t.url("a.xiz"), password: "sbagliata") }
        #expect(throws: XipperError.wrongPassword(entry: "a.xiz")) { _ = try Xipper.test(t.url("a.xiz"), password: "sbagliata") }

        let list = try Xipper.list(t.url("a.xiz"), password: "una password")
        #expect(list.contains { $0.path == "src/small/f199.txt" && $0.isEncrypted })
        let report = try Xipper.test(t.url("a.xiz"), password: "una password", digests: true)
        #expect(report.isOK && report.digests["src/big.bin"] == report.digests["src/copy/big.bin"])
        t.mkdir("out")
        var x = ExtractOptions()
        x.password = "una password"
        try Xipper.extract(t.url("a.xiz"), to: t.url("out"), mode: .into, options: x)
        #expect(treesEqual(t.path + "/src", t.path + "/out/src").0)
        var tail = [UInt8]()
        try Xipper.streamEntry(t.url("a.xiz"), path: "src/text.txt", password: "una password", from: 439_989) { tail += $0 }
        #expect(String(decoding: tail, as: UTF8.self) == "Xipper XIZ ")
    }

    @Test func tamperedEncryptedArchivesAreRefused() throws {
        let t = TempDir()
        t.write("src/a.txt", String(repeating: "riservato ", count: 5000))
        _ = try create(t, password: "pw")
        let good = try [UInt8](Data(contentsOf: t.url("a.xiz")))
        let keys = Xiz.superblockSize + XizKeys.keysBlockSize
        // A flipped bit anywhere that matters: superblock, keys block, frame payload, catalog, footer.
        for (i, offset) in [12, Xiz.superblockSize + 40, keys + Xiz.frameHeaderSize + 7, good.count - Xiz.footerSize - 5, good.count - 30].enumerated() {
            var bad = good
            bad[offset] ^= 0x01
            try Data(bad).write(to: t.url("bad\(i).xiz"))
            let opened = (try? Xipper.test(t.url("bad\(i).xiz"), password: "pw"))?.isOK
            #expect(opened != true, "flip at \(offset)")
        }
        // The frame's CRC fixed up by an attacker: the AEAD tag still refuses it.
        var bad = good
        let payload = keys + Xiz.frameHeaderSize
        let csize = bad.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: keys + 12, as: UInt32.self).littleEndian) }
        bad[payload + 3] ^= 0x80
        var crc = Xiz.crc32c(Array(bad[payload..<(payload + csize)])).littleEndian
        withUnsafeBytes(of: &crc) { bad.replaceSubrange((keys + 24)..<(keys + 28), with: $0) }
        try Data(bad).write(to: t.url("crcfix.xiz"))
        let r = try Xipper.test(t.url("crcfix.xiz"), password: "pw")
        #expect(!r.isOK)
        #expect(r.failures.contains { $0.reason.contains("authentication") || $0.reason.contains("catalog") })
    }

    // MARK: chunk-level dedup, extensibility, the beta format

    @Test func contentDefinedChunksDeduplicateShiftedData() throws {
        let t = TempDir()
        let base = sampleData(12 << 20, seed: 9)
        t.write("src/v1.bin", base)
        // Same file with 1000 bytes inserted in the middle: whole-file dedup sees nothing in common.
        t.write("src/v2.bin", Array(base[..<(5 << 20)]) + sampleData(1000, seed: 10) + Array(base[(5 << 20)...]))
        let r = try create(t)
        #expect(r.outputBytes < (14 << 20), "\(r.outputBytes)")  // not 24 MiB
        t.mkdir("out")
        try Xipper.extract(t.url("a.xiz"), to: t.url("out"), mode: .into)
        #expect(treesEqual(t.path + "/src", t.path + "/out/src").0)
        #expect(try Xipper.test(t.url("a.xiz")).isOK)
    }

    @Test func unknownRequiredFeaturesAreRefusedCleanly() throws {
        let t = TempDir()
        t.write("src/a.txt", "x")
        _ = try create(t)
        var bytes = try [UInt8](Data(contentsOf: t.url("a.xiz")))
        bytes[12] |= 0x08  // a required feature this reader does not know
        var crc = Xiz.crc32c(Array(bytes[0..<60])).littleEndian
        withUnsafeBytes(of: &crc) { bytes.replaceSubrange(60..<64, with: $0) }
        try Data(bytes).write(to: t.url("future.xiz"))
        #expect {
            _ = try Xipper.list(t.url("future.xiz"))
        } throws: { e in
            if case let .unsupported(m)? = e as? XipperError { return m.contains("newer Xipper") }
            return false
        }
    }

    /// Archive written by Xipper 0.9.0-beta4 (XIZ 0.1): src/a.txt "ciao v0\n", src/sub/b.txt "beta\n".
    static let beta = "WElaAA0KGgoAAAEAAAAAAN4d9FEOKVaH3X/aKBZvBM4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAApXfhR1hGUjEAAAAAAAAAAA0AAAANAAAAt6pfKQAAAAAAAAAAY2lhbyB2MApiZXRhCii1L/1gAwC9AwC0BFhDQVQAAAEAAABAAA23ql8pAAQAAAABAwBzcmPtAfYBnTnZajy05w0ACS9hLnR4dKQICukNCAEBB3N1YnaN6g0vYjbrDQUFAAAAABEAcwgAJOQOFal6GSRuDndCaL1T2IthwHhWzULFMty8FZYThcMuiwEkAVhJWkYAAAEAbQAAAAAAAACBAAAAAAAAAAMBAAAAAAAAAQAAAAQAAAANAAAAAAAAAPu5j83bzOkXjKdzVqbIZ1MkqQLsV3G2NxzgBH8c8SBtAAAAAAAAAABRJ1WJWElaIQ=="

    @Test func betaArchivesAreStillRead() throws {
        let t = TempDir()
        try Data(base64Encoded: Self.beta)!.write(to: t.url("beta.xiz"))
        #expect(try Xipper.test(t.url("beta.xiz")).isOK)
        #expect(Set(try Xipper.list(t.url("beta.xiz")).map(\.path)).isSuperset(of: ["src/a.txt", "src/sub/b.txt"]))
        t.mkdir("out")
        try Xipper.extract(t.url("beta.xiz"), to: t.url("out"), mode: .into)
        #expect(try String(contentsOfFile: t.path + "/out/src/a.txt", encoding: .utf8) == "ciao v0\n")
        #expect(try String(contentsOfFile: t.path + "/out/src/sub/b.txt", encoding: .utf8) == "beta\n")
    }
}
