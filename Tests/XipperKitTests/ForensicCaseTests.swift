import CryptoKit
import ForensicKit
import Foundation
import Testing
@testable import XipperKit

/// xipper-forensic P2: logical acquisition with its signed inventory, the case folder with its
/// signed hash-chained log, the signed report.
@Suite("Forensic cases and logical acquisition")
struct ForensicCaseTests {
    static let examiner = XizSigner(key: XizSigningKey(), label: "Esaminatore")
    static let courier = XizSigner(key: XizSigningKey(), label: "Corriere")

    func tree(_ t: TempDir) -> URL {
        t.write("src/Mail/1.eml", "primo")
        t.write("src/Mail/2.eml", Array(sampleData(300_000, seed: 3)))
        t.write("src/Docs/a.txt", "documento")
        t.symlink("src/Docs/link", to: "../Mail")
        _ = t.write("src/Docs/chiuso.txt", Array("segreto".utf8), mode: 0)
        mkfifo(t.path + "/src/Docs/pipe", 0o644)
        setxattr(t.path + "/src/Mail/1.eml", "com.apple.metadata:kMDItemWhereFroms", "http://esempio", 14, 0, 0)
        return t.url("src")
    }

    @Test func logicalAcquisitionListsEverythingAndVerifies() throws {
        let t = TempDir()
        let src = tree(t)
        let out = t.path + "/r.xiz"
        var o = XizForensic.LogicalOptions()
        o.caseInfo = ["case_number": "C1"]
        let r = try XizForensic.acquireLogical([src], to: out, options: o, signer: Self.examiner)
        #expect(r.files == 3 && r.links == 1)
        #expect(Set(r.skipped.map(\.path)) == ["evidence/src/Docs/chiuso.txt", "evidence/src/Docs/pipe"])
        let v = try XizForensic.verify(out)
        #expect(v.passed && v.checks.first { $0.name == "files" }?.status == .passed, "\(v.checks)")
        // The inventory has every item, with the SHA-256 of what was acquired.
        let x = try Xipper.extract(URL(fileURLWithPath: out), to: t.url(""), options: ExtractOptions())
        let inv = try String(contentsOfFile: x.destination.path + "/forensic/inventory.jsonl", encoding: .utf8)
        #expect(inv.contains(XizForensic.hex(Array(SHA256.hash(data: Data("primo".utf8))))))
        #expect(inv.contains("\"status\":\"unreadable\"") && inv.contains("\"kind\":\"fifo\""))
        #expect(XizForensic.hex(Array(SHA256.hash(data: Data(inv.utf8)))) == XizForensic.hex(r.inventorySHA256))
        // Extended attributes are kept.
        var buf = [UInt8](repeating: 0, count: 64)
        let n = getxattr(x.destination.path + "/evidence/src/Mail/1.eml", "com.apple.metadata:kMDItemWhereFroms", &buf, 64, 0, 0)
        #expect(n == 14)
    }

    @Test func caseLogIsSignedAndChained() throws {
        let t = TempDir()
        let c = try ForensicCase.create(at: t.url("c.xfcase"), info: ["case_number": "2026/1", "examiner": "E"], signer: Self.examiner)
        try c.log("note", ["text": "sopralluogo"], signer: Self.examiner)
        try c.update(info: ["case_number": "2026/1", "examiner": "E", "notes": "x"], signer: Self.examiner)
        #expect(try c.verify().passed)
        #expect(try c.entries().map(\.event) == ["case created", "note", "case updated"])

        // A changed line breaks its signature and the next line's chain.
        let log = t.path + "/c.xfcase/case.log"
        let original = try String(contentsOfFile: log, encoding: .utf8)
        try original.replacingOccurrences(of: "sopralluogo", with: "perquisizione").write(toFile: log, atomically: true, encoding: .utf8)
        #expect(try c.verify().problems.count == 2)
        // A removed line breaks the chain.
        let lines = original.split(separator: "\n")
        try (lines.dropFirst(2).isEmpty ? "" : ([lines[0]] + lines.dropFirst(2)).joined(separator: "\n") + "\n").write(toFile: log, atomically: true, encoding: .utf8)
        #expect(!(try c.verify().passed))
        // A case record changed outside the log.
        try original.write(toFile: log, atomically: true, encoding: .utf8)
        try Data("{\"case_number\":\"altro\"}".utf8).write(to: t.url("c.xfcase/case.json"))
        #expect(try c.verify().problems == ["case.json differs from the version recorded in the log"])
    }

    @Test func caseAcquisitionCustodyAndReport() throws {
        let t = TempDir()
        let src = tree(t)
        t.write("disk.img", sampleData(5_000_000, seed: 9))
        let c = try ForensicCase.create(at: t.url("c.xfcase"), info: ["case_number": "2026/2", "examiner": "E"], signer: Self.examiner)
        let (e1, _) = try c.acquireLogical([src], evidence: c.nextEvidenceID(), options: XizForensic.LogicalOptions(), signer: Self.examiner)
        let (e2, img) = try c.acquireImage(from: t.path + "/disk.img", evidence: c.nextEvidenceID(), options: XizForensic.ImageOptions(), signer: Self.examiner)
        #expect(e1.id == "R01" && e2.id == "R02")
        #expect(img.sha256 == Array(SHA256.hash(data: Data(sampleData(5_000_000, seed: 9)))))
        try c.custody(evidence: "R02", from: "E", to: "Laboratorio", signer: Self.courier)
        let v = try c.verify()
        #expect(v.passed, "\(v.problems)")
        #expect(Set(v.signers.values) == ["Esaminatore", "Corriere"])

        // The report: built from the archive, case fields from the case record, signed.
        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: e2.report)) as! [String: Any]
        #expect(report["passed"] as? Bool == true)
        #expect((report["case"] as? [String: String])?["case_number"] == "2026/2")
        #expect((report["custody"] as? [[String: String]])?.first?["to"] == "Laboratorio")
        #expect(((report["source_hashes"] as? [[String: Any]])?.first?["sha256"] as? String) == XizForensic.hex(img.sha256))
        #expect(try ForensicReport.verifySignature(e2.report).valid)
        try Data("{}".utf8).write(to: e2.report)
        #expect(!(try ForensicReport.verifySignature(e2.report)).valid)

        // An archive replaced after it was logged.
        try FileManager.default.removeItem(at: e1.archive)
        try FileManager.default.copyItem(at: e2.archive, to: e1.archive)
        #expect(try c.verify().problems.contains("evidence/R01/R01.xiz: SHA-256 differs from the last one logged"))
    }
}
