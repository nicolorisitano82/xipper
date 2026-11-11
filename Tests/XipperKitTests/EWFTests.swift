import CryptoKit
import Foundation
import Testing
@testable import ForensicKit
@testable import XipperKit

/// E01 written from a forensic XIZ and read back (our reader; libewf and The Sleuth Kit in
/// scripts/e01-check.sh): hashes, case fields, unreadable sectors, segments, damage detected.
@Suite("E01 (EWF)")
struct EWFTests {
    static let examiner = XizSigner(key: XizSigningKey(), label: "Esaminatore")

    func archive(_ t: TempDir, _ data: [UInt8], unreadable: [XizForensic.Unreadable.Range] = []) throws -> String {
        let src = t.write("disk.img", data)
        var o = XizForensic.ImageOptions()
        o.caseInfo = ["case_number": "2026-117", "evidence_number": "R01", "examiner": "Mario Rossi", "description": "chiavetta"]
        o.device = ["model": "SanDisk Ultra", "serial": "4C53", "removable": "true"]
        o.unreadable = unreadable
        let out = t.path + "/r.xiz"
        _ = try XizForensic.acquireImage(from: src, to: out, options: o, signer: Self.examiner)
        return out
    }

    /// Noise (stored chunks, 9 MiB: several 4 MiB segments), zeros and text (compressed chunks).
    static let noise: [UInt8] = { var b = [UInt8](repeating: 0, count: 9 << 20); arc4random_buf(&b, b.count); return b }()
    var data: [UInt8] { Self.noise + [UInt8](repeating: 0, count: 2 << 20) + Array(String(repeating: "settore\n", count: 131_072).utf8) }

    @Test func roundTripWithFieldsAndErrors() throws {
        let t = TempDir()
        var d = data
        let bad = XizForensic.Unreadable.Range(offset: 1 << 20, length: 4096)
        for i in 0..<4096 { d[(1 << 20) + i] = 0 }
        let a = try archive(t, data, unreadable: [bad])
        let r = try ForensicExport.e01(a, to: t.url("x"), segmentSize: 4 << 20)
        #expect(r.files.count >= 2 && r.files[0].lastPathComponent == "x.E01")
        #expect(r.md5 == Array(Insecure.MD5.hash(data: d)) && r.sha1 == Array(Insecure.SHA1.hash(data: d)))
        let e = try EWF.Reader(r.files[0])
        #expect(e.info.size == UInt64(d.count) && e.info.segments.count == r.files.count && e.info.removable)
        #expect(e.info.caseInfo["case_number"] == "2026-117" && e.info.caseInfo["examiner"] == "Mario Rossi" && e.info.model == "SanDisk Ultra" && e.info.serial == "4C53")
        #expect(e.info.unreadable == [bad])
        let v = try e.verify()
        #expect(v.sha256 == Array(SHA256.hash(data: d)))
        // Import: a new forensic XIZ with the same hashes, the E01's fields and its error map.
        let (er, source) = try ForensicExport.openE01(r.files[0])
        let o = try ForensicExport.importOptions(er, base: .init())
        let imp = try XizForensic.acquireImage(from: source, to: t.path + "/imp.xiz", options: o, signer: Self.examiner)
        try ForensicExport.checkImport(er, imp)
        #expect(imp.sha256 == v.sha256 && imp.unreadableBytes == 4096)
        #expect(try XizForensic.verify(t.path + "/imp.xiz").passed)
        #expect(o.acquisition["e01_case_number"] == "2026-117" && o.acquisition["method"] == "E01 import")
    }

    @Test func rawExportIsTheImage() throws {
        let t = TempDir()
        let a = try archive(t, data)
        let r = try ForensicExport.raw(a, to: t.url("out.dd"))
        #expect(FileManager.default.contents(atPath: t.path + "/out.dd") == Data(data))
        #expect(r.sha256 == Array(SHA256.hash(data: data)))
        #expect(throws: XipperError.self) { _ = try ForensicExport.raw(a, to: t.url("out.dd")) }
    }

    @Test func damageIsDetected() throws {
        let t = TempDir()
        let a = try archive(t, data)
        let r = try ForensicExport.e01(a, to: t.url("x"))
        var bytes = try Array(Data(contentsOf: r.files[0]))
        // A byte inside the first chunk (noise: stored with its Adler-32).
        let at = bytes.count / 4
        bytes[at] ^= 0x40
        try Data(bytes).write(to: r.files[0])
        #expect(throws: (any Error).self) { _ = try EWF.Reader(r.files[0]).verify() }
    }

    @Test func unalignedImageRefused() throws {
        let t = TempDir()
        let a = try archive(t, [UInt8](repeating: 7, count: 1000))
        #expect(throws: EWF.Problem.self) { _ = try ForensicExport.e01(a, to: t.url("x")) }
        #expect(!FileManager.default.fileExists(atPath: t.path + "/x.E01"))
    }
}
