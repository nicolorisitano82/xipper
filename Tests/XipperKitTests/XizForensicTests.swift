import CryptoKit
import Foundation
import Testing
@testable import XipperKit

/// XIZ 1.10 forensic profile (§20): images with source hashes and frame hashes, custody segments
/// without keys, verification point by point, tampering detected, editing refused.
@Suite("XIZ forensic profile")
struct XizForensicTests {
    static let examiner = XizSigner(key: XizSigningKey(), label: "Esaminatore")
    static let courier = XizSigner(key: XizSigningKey(), label: "Corriere")

    /// 4 MiB of noise, 4 MiB of zeros, some text, a zero tail shorter than a block.
    func image(_ t: TempDir) -> (String, [UInt8]) {
        var d = sampleData(XizForensic.blockSize, seed: 7)
        d += [UInt8](repeating: 0, count: XizForensic.blockSize)
        d += Array((0..<40_000).map { "settore \($0)\n" }.joined().utf8)
        d += [UInt8](repeating: 0, count: 100_000)
        return (t.write("disk.img", d), d)
    }

    func options(_ f: (inout XizForensic.ImageOptions) -> Void = { _ in }) -> XizForensic.ImageOptions {
        var o = XizForensic.ImageOptions()
        o.caseInfo = ["case_number": "2026-117", "evidence_number": "R01"]
        o.device = ["model": "Test", "serial": "SN1"]
        f(&o)
        return o
    }

    func status(_ r: XizForensic.Report, _ name: String) -> XizForensic.Check.Status? { r.checks.first { $0.name == name }?.status }

    @Test func imageRoundTripsAndVerifies() throws {
        let t = TempDir()
        let (src, data) = image(t)
        let out = t.path + "/r.xiz"
        let r = try XizForensic.acquireImage(from: src, to: out, options: options(), signer: Self.examiner)
        #expect(r.sha256 == Array(SHA256.hash(data: data)))
        #expect(r.md5 == Array(Insecure.MD5.hash(data: data)))
        #expect(r.zeroBlocks == 1)
        let v = try XizForensic.verify(out, expectSHA256: r.sha256)
        #expect(v.passed, "\(v.checks)")
        #expect(status(v, "frame hashes") == .passed)
        #expect(status(v, "expected SHA-256") == .passed)
        // Any XIZ reader sees an ordinary file.
        let x = try Xipper.extract(URL(fileURLWithPath: out), to: t.url(""), options: ExtractOptions())
        #expect(FileManager.default.contents(atPath: x.destination.path + "/image.dd") == Data(data))
        #expect(FileManager.default.fileExists(atPath: x.destination.path + "/forensic/case.json"))
        // Layout (§20.3): one extent per block, the zero block points at the zero frame.
        let a = try XizArchive(path: out)
        let e = try #require(a.catalog.entries.first { $0.image != nil })
        #expect(e.extents.count == 3 && e.extents.allSatisfy { $0.offset == 0 })
    }

    @Test func custodyNeedsNoKeyAndIsSigned() throws {
        let t = TempDir()
        let (src, _) = image(t)
        let out = t.path + "/r.xiz"
        _ = try XizForensic.acquireImage(from: src, to: out, options: options { $0.password = "segreto" }, signer: Self.examiner)
        try XizForensic.appendCustody(to: out, custody: ["from": "Esaminatore", "to": "Laboratorio"], signer: Self.courier)
        try XizForensic.appendCustody(to: out, custody: ["from": "Laboratorio", "to": "Tribunale"], signer: Self.courier)
        let blind = try XizForensic.verify(out)
        #expect(blind.passed, "\(blind.checks)")
        #expect(status(blind, "content") == .skipped)
        #expect(blind.signatures.map(\.label) == ["Esaminatore", "Corriere", "Corriere"])
        #expect(blind.signatures.allSatisfy { $0.valid && $0.chained })
        let full = try XizForensic.verify(out, password: "segreto")
        #expect(full.passed && status(full, "images") == .passed, "\(full.checks)")
        #expect(try XizForensic.blocks(out).last?.records(.custody).first?.json["to"] == "Tribunale")
        _ = try XizArchive(path: out, password: "segreto")  // the reader follows the custody segments
    }

    @Test func summaryForAnArchiver() throws {
        let t = TempDir()
        let (src, data) = image(t)
        let out = t.path + "/s.xiz"
        let ranges = [XizForensic.Unreadable.Range(offset: 4096, length: 1024)]
        _ = try XizForensic.acquireImage(from: src, to: out, options: options { $0.password = "segreto"; $0.unreadable = ranges },
                                         signer: Self.examiner)
        try XizForensic.appendCustody(to: out, custody: ["from": "Esaminatore", "to": "Laboratorio"], signer: Self.courier)
        let s = try #require(try XizForensic.summary(out))
        #expect(s.caseNumber == "2026-117" && s.evidenceNumber == "R01")
        #expect(s.sources.count == 1 && s.sources[0].size == UInt64(data.count))
        #expect(s.unreadableBytes == 1024)
        #expect(s.handOvers.map(\.to) == ["Laboratorio"] && s.handOvers[0].segment == 1 && !s.handOvers[0].time.isEmpty)
        // An ordinary XIZ has no summary.
        let plain = t.path + "/p.xiz"
        var o = CreateOptions()
        o.format = .xiz
        _ = try Xipper.create(from: [URL(fileURLWithPath: src)], to: URL(fileURLWithPath: plain), options: o)
        #expect(try XizForensic.summary(plain) == nil)
    }

    @Test func unreadableRangesAreZerosAndListed() throws {
        let t = TempDir()
        let (src, data) = image(t)
        let out = t.path + "/r.xiz"
        let ranges = [XizForensic.Unreadable.Range(offset: 1000, length: 512), .init(offset: 9_000_000, length: 4096)]
        let r = try XizForensic.acquireImage(from: src, to: out, options: options { $0.unreadable = ranges }, signer: Self.examiner)
        var zeroed = data
        for x in ranges { for i in Int(x.offset)..<Int(x.offset + x.length) { zeroed[i] = 0 } }
        #expect(r.sha256 == Array(SHA256.hash(data: zeroed)))
        #expect(r.unreadableBytes == 4608)
        let v = try XizForensic.verify(out)
        #expect(v.passed, "\(v.checks)")
        let u = try #require(try XizForensic.blocks(out)[0].records(.unreadable).first)
        #expect(try XizForensic.Unreadable(u.value).ranges == ranges)
    }

    @Test func tamperingIsDetected() throws {
        let t = TempDir()
        let (src, _) = image(t)
        let out = t.path + "/r.xiz"
        _ = try XizForensic.acquireImage(from: src, to: out, options: options(), signer: Self.examiner)
        let original = try Data(contentsOf: URL(fileURLWithPath: out))

        // A byte of frame 0's payload, with the frame's CRC corrected: only the frame hash sees it.
        var d = [UInt8](original)
        let csize = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 64 + 12, as: UInt32.self).littleEndian })
        d[64 + 32 + 10] ^= 0x40
        let crc = Xiz.crc32c(Array(d[(64 + 32)..<(64 + 32 + csize)]))
        withUnsafeBytes(of: crc.littleEndian) { for i in 0..<4 { d[64 + 20 + i] = $0[i] } }
        try Data(d).write(to: t.url("frame.xiz"))
        let v1 = try XizForensic.verify(t.path + "/frame.xiz")
        #expect(!v1.passed && status(v1, "frame hashes") == .failed)

        // A byte of the forensic block (the case record).
        var c = [UInt8](original)
        let at = try #require(c.indices.first { c[$0...].starts(with: Array("2026-117".utf8)) && $0 > csize })
        c[at] = UInt8(ascii: "9")
        try Data(c).write(to: t.url("case.xiz"))
        #expect(!(try XizForensic.verify(t.path + "/case.xiz")).passed)

        // The expected SHA-256 from the report does not match another image.
        let other = try XizForensic.verify(out, expectSHA256: [UInt8](repeating: 1, count: 32))
        #expect(status(other, "expected SHA-256") == .failed)
    }

    @Test func forensicArchivesAreNeverEdited() throws {
        let t = TempDir()
        let (src, _) = image(t)
        let out = t.path + "/r.xiz"
        _ = try XizForensic.acquireImage(from: src, to: out, options: options(), signer: Self.examiner)
        #expect(throws: XipperError.self) {
            try Xipper.edit(URL(fileURLWithPath: out), changes: [.makeDirectory("nuova")])
        }
        #expect(try XizForensic.verify(out).passed)
    }

    /// The test vectors libxiz checks (libxiz/tests/make_forensic_fixtures.sh) verify here too.
    @Test func libxizVectorsVerify() throws {
        let f = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("libxiz/tests/fixtures").path
        let sha = try String(contentsOfFile: f + "/forensic.sha256", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = stride(from: 0, to: sha.count, by: 2).map { i -> UInt8 in
            let a = sha.index(sha.startIndex, offsetBy: i)
            return UInt8(sha[a..<sha.index(a, offsetBy: 2)], radix: 16)!
        }
        let v = try XizForensic.verify(f + "/forensic.xiz", expectSHA256: expected)
        #expect(v.passed && status(v, "expected SHA-256") == .passed, "\(v.checks)")
        #expect(v.signatures.map(\.label) == ["Esaminatore", "Corriere"])
        #expect(try XizForensic.verify(f + "/forensic-password.xiz", password: "correct horse battery staple").passed)
        #expect(!(try XizForensic.verify(f + "/forensic-damaged.xiz")).passed)
        let logical = try XizForensic.verify(f + "/forensic-logical.xiz")
        #expect(logical.passed && status(logical, "files") == .passed, "\(logical.checks)")
    }

    @Test func sourceTimesKeepMilliseconds() throws {
        let t = TempDir()
        let (src, _) = image(t)
        let out = t.path + "/r.xiz"
        let when = Date(timeIntervalSince1970: 1_794_301_200.123)
        _ = try XizForensic.acquireImage(from: src, to: out, options: options { $0.now = when }, signer: Self.examiner)
        let r = try #require(try XizForensic.blocks(out)[0].records(.sourceHashes).first)
        let s = try XizForensic.SourceHashes(r.value)
        #expect(abs(s.started.timeIntervalSince1970 - 1_794_301_200.123) < 0.0005)
        #expect(abs(s.finished.timeIntervalSince1970 - 1_794_301_200.123) < 0.0005)
    }

    @Test func blockRefusesUnknownCriticalRecords() throws {
        let ok = XizForensic.Block(segment: 0, records: [.init(type: 0x0F00, value: [1, 2])]).encode()
        #expect(try XizForensic.Block.decode(ok).records.count == 1)
        let critical = XizForensic.Block(segment: 0, records: [.init(type: 0x8F00, value: [1])]).encode()
        #expect(throws: XipperError.self) { try XizForensic.Block.decode(critical) }
    }
}

/// The SHA-256 in the written record is usually the archive file's (as the app tells the examiner),
/// taken at acquisition or at a hand-over: it must match the file as it was then, and expose a cut.
@Suite("XIZ forensic: SHA-256 from the record")
struct XizRecordHashTests {
    @Test func archiveHashAtAnySegment() throws {
        let t = TempDir()
        let signer = XizSigner(key: XizSigningKey(), label: "E")
        let out = t.path + "/r.xiz"
        _ = try XizForensic.acquireImage(from: t.write("d.img", sampleData(2 << 20, seed: 1)), to: out, options: .init(), signer: signer)
        let atAcquisition = Array(SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: out))))
        let original = try Data(contentsOf: URL(fileURLWithPath: out))
        try XizForensic.appendCustody(to: out, custody: ["from": "E", "to": "T"], signer: signer)
        let atHandOver = Array(SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: out))))
        let a = try XizForensic.verify(out, expectSHA256: atAcquisition)
        #expect(a.passed && a.checks.last?.detail.contains("at segment 0") == true, "\(a.checks)")
        let b = try XizForensic.verify(out, expectSHA256: atHandOver)
        #expect(b.passed && b.checks.last?.detail.contains("as recorded") == true)
        // Cut back to the first segment: the hand-over's hash exposes it.
        try original.write(to: URL(fileURLWithPath: out))
        let c = try XizForensic.verify(out, expectSHA256: atHandOver)
        #expect(!c.passed && c.checks.last?.status == .failed)
        #expect(try XizForensic.verify(out, expectSHA256: atAcquisition).passed)
    }
}
