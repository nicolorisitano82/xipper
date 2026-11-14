import Foundation
import Testing
@testable import XipperKit

/// The exhaustive campaign (scripts/full-test.sh): every XIZ option against every other, a table
/// dialect corpus for OpenZL, forensic archives seen by Xipper. Off by default (minutes, not
/// seconds): XIPPER_EXHAUSTIVE=1. With XIPPER_MATRIX_OUT=DIR the matrix archives, their expected
/// trees and a .case file each are left in DIR, so libxiz can read them back (full-test.sh does).
enum Exhaustive {
    static let enabled = ProcessInfo.processInfo.environment["XIPPER_EXHAUSTIVE"] == "1"
    static let outDir = ProcessInfo.processInfo.environment["XIPPER_MATRIX_OUT"]
    static let password = "matrix password ✓"
}

struct MatrixCase: CustomTestStringConvertible, Sendable {
    /// `pq`: a password and a hybrid Ed25519 + ML-DSA-65 signature (XIZ 1.12).
    enum Security: String, CaseIterable, Sendable { case plain, password, signed, both, pq }
    var codec: XizCodec
    var recompress: Bool
    var security: Security
    var recovery: Bool
    var name: String { "\(codec.rawValue)-\(recompress ? "recompress" : "plain")-\(security.rawValue)\(recovery ? "-recovery" : "")" }
    var testDescription: String { name }

    static var all: [MatrixCase] {
        var out: [MatrixCase] = []
        let codecs: [XizCodec] = XizCodec.appleCodecsAvailable ? [.zstd, .lzma2, .lzmesh, .lzraven] : [.zstd, .lzma2]
        for c in codecs {
            for r in [false, true] {
                for s in Security.allCases {
                    for rec in [false, true] { out.append(MatrixCase(codec: c, recompress: r, security: s, recovery: rec)) }
                }
            }
        }
        return out
    }
}

@Suite("Exhaustive: XIZ option matrix", .enabled(if: Exhaustive.enabled))
struct ExhaustiveXizMatrixTests {
    /// Every kind of content a XIZ writer treats differently.
    static func tree(_ t: TempDir, root: String) throws {
        makeTree(t, root: root, bigSize: 9 << 20)
        t.write("\(root)/data/big-copy.bin", sampleData(9 << 20))  // whole-file deduplication
        var shifted = sampleData(64 << 10, seed: 99) + sampleData(9 << 20)
        shifted.removeLast(1000)
        t.write("\(root)/data/big-shifted.bin", shifted)  // chunk deduplication across an insertion
        for i in 0..<300 { t.write("\(root)/small/\(i % 7)/note-\(i).txt", "nota \(i): " + String(repeating: "parole simili \(i % 13) ", count: 40 + i % 50)) }
        t.write("\(root)/media/photo.jpg", XizJPEGTests.jpeg(seed: 4))
        t.write("\(root)/media/image.png", XizDocumentsTests.png(seed: 5))
        t.write("\(root)/media/doc.pdf", XizDocumentsTests.pdf(pages: 4))
        t.write("\(root)/tables/sensors.csv", XizTablesTests.csv(rows: 40_000, seed: 6))
        t.write("\(root)/tables/regions.tsv", XizTablesTests.csv(rows: 20_000, seed: 7, separator: "\t"))
        t.write("\(root)/models/model.safetensors", XizModelsTests.safetensors([
            ("w0", "F32", XizModelsTests.weights32(200_000, seed: 8)), ("w1", "BF16", XizModelsTests.weights16(300_000, seed: 9))]))
        if let bin = FileManager.default.contents(atPath: "/usr/bin/true") { t.write("\(root)/bin/true", [UInt8](bin), mode: 0o755) }
        t.write("\(root)/a/b/c/d/e/f/g/deep.txt", "deep\n")
        t.write("\(root)/spazi e accenti/perché.txt", "ok\n")
        t.symlink("\(root)/link-to-dir", to: "data")
    }

    static let pqKey = XizSigningKey(postQuantum: true)

    func options(_ c: MatrixCase, signer: XizSigner) -> CreateOptions {
        var o = CreateOptions()
        o.format = .xiz
        o.xizCodec = c.codec
        o.xizJPEG = c.recompress
        o.xizDocuments = c.recompress
        o.xizTables = c.recompress
        o.xizModels = c.recompress
        o.xizRecovery = c.recovery ? 5 : 0
        if c.security == .password || c.security == .both || c.security == .pq { o.password = Exhaustive.password }
        if c.security == .signed || c.security == .both { o.xizSigner = signer }
        if c.security == .pq { o.xizSigner = XizSigner(key: Self.pqKey, label: "Matrix PQ") }
        return o
    }

    func extract(_ archive: URL, _ t: TempDir, password: String?) throws -> String {
        let dest = t.url("x-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var o = ExtractOptions()
        o.password = password
        _ = try Xipper.extract(archive, to: dest, mode: .into, options: o)
        return dest.path
    }

    @Test(arguments: MatrixCase.all)
    func roundTripEditAndHistory(_ c: MatrixCase) throws {
        let t = TempDir()
        try Self.tree(t, root: "src")
        let signer = XizSigner(key: XizSigningKey(), label: "Matrix")
        let o = options(c, signer: signer)
        let pw = o.password
        let archive = t.url("\(c.name).xiz")
        try Xipper.create(from: [t.url("src")], to: archive, options: o)

        // 1. Verified, extracted identical.
        #expect(try Xipper.test(archive, password: pw).isOK, "\(c.name): test")
        let (same, diff) = treesEqual(t.path + "/src", try extract(archive, t, password: pw) + "/src")
        #expect(same, "\(c.name): \(diff)")

        // 2. The features the options ask for, and only those.
        let a = try XizArchive(path: archive.path, password: pw)
        let required = a.superblock.required
        #expect(required.contains(.encrypted) == (pw != nil))
        #expect(required.contains(.directory) == (o.xizSigner != nil))
        #expect(required.contains(.tables) == c.recompress)
        #expect(required.contains(.jpeg) == c.recompress)
        #expect(required.contains(.deflate) == c.recompress)
        let codecs = Set(a.catalog.frames.map(\.codec))
        if c.recompress {
            #expect(codecs.contains(.openzl) && codecs.contains(.jpeg) && codecs.contains(.preflate), "\(c.name): \(codecs)")
        } else {
            #expect(codecs.isDisjoint(with: [.openzl, .jpeg, .preflate]))
        }

        // 3. An edit: a table added, a file deleted, a folder renamed; signed when the archive is.
        t.write("added/new.csv", XizTablesTests.csv(rows: 30_000, seed: 8))
        try Xipper.edit(archive, changes: [.add(t.url("added/new.csv"), as: "src/tables/new.csv"),
                                          .delete("src/readme.txt"),
                                          .rename("src/small", to: "src/piccoli")],
                        password: pw, options: o)
        try FileManager.default.copyItem(atPath: t.path + "/src", toPath: t.path + "/expected")
        try FileManager.default.removeItem(atPath: t.path + "/expected/readme.txt")
        try FileManager.default.moveItem(atPath: t.path + "/expected/small", toPath: t.path + "/expected/piccoli")
        try FileManager.default.copyItem(atPath: t.path + "/added/new.csv", toPath: t.path + "/expected/tables/new.csv")
        #expect(try Xipper.test(archive, password: pw).isOK, "\(c.name): test after edit")
        let (same2, diff2) = treesEqual(t.path + "/expected", try extract(archive, t, password: pw) + "/src")
        #expect(same2, "\(c.name) after edit: \(diff2)")
        if c.recompress {
            #expect(try XizArchive(path: archive.path, password: pw).catalog.frames.filter { $0.codec == .openzl }.count >= 3,
                    "\(c.name): the added table in OpenZL")
        }

        // 4. Signed history: two segments, both valid and chained.
        if o.xizSigner != nil {
            let h = try Xipper.xizHistory(archive)
            #expect(h.count == 2 && h.allSatisfy { $0.signed && $0.valid && $0.chained }, "\(c.name): \(h.map { ($0.valid, $0.chained) })")
            #expect(h.allSatisfy { $0.isPostQuantum == (c.security == .pq) })
        }

        // 5. Left for libxiz.
        if let out = Exhaustive.outDir {
            let base = out + "/" + c.name
            try? FileManager.default.removeItem(atPath: base + ".xiz")
            try? FileManager.default.removeItem(atPath: base + ".expected")
            try FileManager.default.copyItem(atPath: archive.path, toPath: base + ".xiz")
            try FileManager.default.copyItem(atPath: t.path + "/expected", toPath: base + ".expected")
            let info = "password=\(pw != nil ? 1 : 0)\nsigned=\(o.xizSigner != nil ? 1 : 0)\napple=\(c.codec.appleFrameCodec != nil ? 1 : 0)\n"
            try info.write(toFile: base + ".case", atomically: true, encoding: .utf8)
        }
    }

    /// Damage inside the archive: refused by test, then repaired from the recovery record.
    @Test(arguments: MatrixCase.all.filter { $0.recovery && $0.security != .signed })
    func damageIsDetectedAndRepaired(_ c: MatrixCase) throws {
        let t = TempDir()
        try Self.tree(t, root: "src")
        let o = options(c, signer: XizSigner(key: XizSigningKey(), label: "Matrix"))
        let archive = t.url("d.xiz")
        try Xipper.create(from: [t.url("src")], to: archive, options: o)
        let h = try FileHandle(forUpdating: archive)
        try h.seek(toOffset: 200_000)
        try h.write(contentsOf: Data(repeating: 0xA5, count: 64))
        try h.close()
        #expect((try? Xipper.test(archive, password: o.password))?.isOK != true, "\(c.name): damage not detected")
        #expect(try Xipper.scrubXiz(archive, repair: true).repaired, "\(c.name): not repaired")
        #expect(try Xipper.test(archive, password: o.password).isOK, "\(c.name): test after repair")
        let (same, diff) = treesEqual(t.path + "/src", try extract(archive, t, password: o.password) + "/src")
        #expect(same, "\(c.name) after repair: \(diff)")
    }
}
