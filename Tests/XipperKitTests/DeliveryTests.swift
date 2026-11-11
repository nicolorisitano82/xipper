import CryptoKit
import Foundation
import Testing
@testable import ForensicKit
@testable import XipperKit

/// Copies for a recipient: the copy (XIZ for a key or a password, raw, E01, files with proofs), the
/// signed receipt, the custody segment on the original, the case log.
@Suite("Delivery")
struct DeliveryTests {
    static let examiner = XizSigner(key: XizSigningKey(), label: "Mario Rossi")

    func caseWithImage(_ t: TempDir) throws -> (ForensicCase, [UInt8]) {
        let c = try ForensicCase.create(at: t.url("C.xfcase"), info: ["case_number": "2026-117"], signer: Self.examiner)
        let data = sampleData(5 << 20, seed: 4) + [UInt8](repeating: 0, count: 1 << 20)
        var o = XizForensic.ImageOptions()
        o.device = ["model": "SanDisk", "serial": "42"]
        o.unreadable = [.init(offset: 1 << 20, length: 512)]
        _ = try c.acquireImage(from: t.write("disk.img", data), evidence: "R01", options: o, signer: Self.examiner)
        var d = data
        for i in 0..<512 { d[(1 << 20) + i] = 0 }
        return (c, d)
    }

    @Test func xizCopyForARecipientKey() throws {
        let t = TempDir()
        let (c, data) = try caseWithImage(t)
        let who = XizIdentity()
        var o = Delivery.Options(recipient: "Procura di Milano")
        o.recipientKeys = [who.publicText]
        o.reason = "consulenza tecnica"
        let r = try c.deliver(evidence: "R01", options: o, signer: Self.examiner)
        let copy = r.files[0].0.path
        // Without the key the structure, signatures and hashes still verify; with it, the image too.
        XizCredentials.shared.add(identity: who)
        defer { XizCredentials.shared.removeAll() }
        let v = try XizForensic.verify(copy)
        #expect(v.passed, "\(v.checks)")
        let info = try XizForensic.storedImage(copy)
        #expect(info.source?.sha256 == Array(SHA256.hash(data: data)) && info.unreadable.count == 1)
        #expect(info.acquisition["method"] == "delivery copy" && info.acquisition["recipient"] == "Procura di Milano")
        #expect(info.caseInfo["delivered_to"] == "Procura di Milano")
        // Receipt signed; original has the custody segment; the case log verifies.
        #expect(try ForensicReport.verifySignature(r.receipt).valid)
        let e = try #require(try c.evidence().first)
        let custody = try XizForensic.blocks(e.archive.path).flatMap { $0.records(.custody) }
        #expect(custody.count == 1 && String(decoding: custody[0].value, as: UTF8.self).contains("Procura di Milano"))
        let cv = try c.verify()
        #expect(cv.passed, "\(cv.problems)")
        #expect(try c.entries().contains { $0.event == "evidence delivered" })
    }

    @Test func rawAndE01Copies() throws {
        let t = TempDir()
        let (c, data) = try caseWithImage(t)
        let raw = try c.deliver(evidence: "R01", options: { var o = Delivery.Options(recipient: "Avv. Bianchi"); o.format = .raw; return o }(), signer: Self.examiner)
        #expect(FileManager.default.contents(atPath: raw.files[0].0.path) == Data(data))
        #expect(try String(contentsOf: raw.files[1].0, encoding: .utf8).contains(XizForensic.hex(Array(SHA256.hash(data: data)))))
        let e01 = try c.deliver(evidence: "R01", options: { var o = Delivery.Options(recipient: "CTU"); o.format = .e01; return o }(), signer: Self.examiner)
        #expect(try EWF.Reader(e01.files[0].0).verify().sha256 == Array(SHA256.hash(data: data)))
        #expect(try XizForensic.blocks(try c.evidence()[0].archive.path).flatMap { $0.records(.custody) }.count == 2)
    }

    @Test func filesWithProofsFromALogicalAcquisition() throws {
        let t = TempDir()
        let c = try ForensicCase.create(at: t.url("C.xfcase"), info: ["case_number": "1"], signer: Self.examiner)
        let dir = t.url("Docs")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("lettera".utf8).write(to: dir.appendingPathComponent("lettera.txt"))
        try Data("segreto".utf8).write(to: dir.appendingPathComponent("altro.txt"))
        let (e, _) = try c.acquireLogical([dir], evidence: "R01", options: .init(), signer: Self.examiner)
        let paths = try Xipper.list(e.archive).map(\.path).filter { $0.hasSuffix("lettera.txt") }
        var o = Delivery.Options(recipient: "Parte")
        o.format = .files
        o.files = paths
        let r = try c.deliver(evidence: "R01", options: o, signer: Self.examiner)
        #expect(r.files.count == 2)
        let file = r.files[0].0, proof = r.files[1].0
        let p = try Xipper.xizVerifyProof(try Data(contentsOf: proof), file: file)
        #expect(p.contentMatches && p.inTree && p.signed)
        #expect(!FileManager.default.fileExists(atPath: r.folder.appendingPathComponent("files/Docs/altro.txt").path))
        // An image cannot go out as files, a logical acquisition not as raw.
        #expect(throws: XipperError.self) { _ = try c.deliver(evidence: "R01", options: { var o = Delivery.Options(recipient: "X"); o.format = .raw; return o }(), signer: Self.examiner) }
    }
}
