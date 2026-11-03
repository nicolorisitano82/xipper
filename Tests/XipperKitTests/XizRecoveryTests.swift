import Foundation
import Testing
@testable import XipperKit

/// XIZ 1.5 recovery record (spec §15): Cauchy Reed–Solomon over the whole archive, at its end.
@Suite("XIZ recovery record")
struct XizRecoveryTests {
    /// Random content (does not compress), so the archive has a known size and many slices.
    func archive(_ t: TempDir, redundancy: Double = 10, password: String? = nil, bytes: Int = 3_000_000) throws -> URL {
        t.write("src/a.bin", sampleData(bytes / 2, seed: 1))
        t.write("src/b.bin", sampleData(bytes / 2, seed: 2))
        t.write("src/note.txt", "recovery")
        var o = CreateOptions()
        o.format = .xiz
        o.password = password
        o.xizRecovery = redundancy
        try Xipper.create(from: [t.url("src")], to: t.url("a.xiz"), options: o)
        return t.url("a.xiz")
    }

    func bytes(_ u: URL) throws -> [UInt8] { try [UInt8](Data(contentsOf: u)) }

    func damage(_ u: URL, at offsets: [Int], length: Int = 100) throws {
        var b = try bytes(u)
        for o in offsets { for i in o..<min(b.count, o + length) { b[i] ^= 0x5A } }
        try Data(b).write(to: u)
    }

    @Test func layoutAndReaders() throws {
        let t = TempDir()
        let a = try archive(t)
        let info = try #require(Xipper.xizRecoveryInfo(a))
        #expect(info.sliceSize % 4096 == 0)
        #expect(info.recoverySlices == Int((Double(info.dataSlices) / 10).rounded(.up)))
        #expect(Int64(try bytes(a).count) == info.protectedLength + info.recordBytes)
        // The archive proper ends with its footer, right before the record.
        let b = try bytes(a)
        #expect(Array(b[Int(info.protectedLength) - 4..<Int(info.protectedLength)]) == Array("XIZ!".utf8))
        #expect(Array(b.suffix(4)) == Array("XZR!".utf8))
        #expect(try Xipper.test(a).isOK)
        #expect(try Xipper.scrubXiz(a).isClean)
    }

    @Test func repairsDamageAnywhereByteForByte() throws {
        let t = TempDir()
        let a = try archive(t)
        let original = try bytes(a)
        let info = try #require(Xipper.xizRecoveryInfo(a))
        let p = Int(info.protectedLength)
        // Superblock, frames, catalog, footer, the record's header A, a recovery slice and the trailer.
        try damage(a, at: [0, 70_000, p / 2, p - 150, p - 50, p + 10, p + 9000, original.count - 30])
        #expect(throws: (any Error).self) { _ = try Xipper.test(a) }
        let found = try Xipper.scrubXiz(a)
        #expect(!found.isClean && found.repairable && !found.repaired)
        #expect(found.damagedRanges.count >= 4)
        #expect(found.damagedMetadata >= 2)
        let r = try Xipper.scrubXiz(a, repair: true)
        #expect(r.repaired)
        #expect(try bytes(a) == original)
        #expect(try Xipper.test(a).isOK)
        #expect(try Xipper.scrubXiz(a).isClean)
    }

    @Test func exactlyAsManyDamagedSlicesAsRecoverySlices() throws {
        let t = TempDir()
        let a = try archive(t, redundancy: 5)
        let original = try bytes(a)
        let info = try #require(Xipper.xizRecoveryInfo(a))
        let s = info.sliceSize
        let slices = (0..<info.recoverySlices).map { $0 * (info.dataSlices / info.recoverySlices) }
        try damage(a, at: slices.map { $0 * s + 7 }, length: 1)
        #expect(try Xipper.scrubXiz(a).damagedRanges.count == info.recoverySlices)
        #expect(try Xipper.scrubXiz(a, repair: true).repaired)
        #expect(try bytes(a) == original)

        // One more than the record can rebuild: reported, nothing written.
        try damage(a, at: (slices + [1]).map { $0 * s + 7 }, length: 1)
        let before = try bytes(a)
        let r = try Xipper.scrubXiz(a, repair: true)
        #expect(!r.repairable && !r.repaired)
        #expect(try bytes(a) == before)
    }

    @Test func truncatedRecordIsRebuilt() throws {
        let t = TempDir()
        let a = try archive(t)
        let original = try bytes(a)
        let info = try #require(Xipper.xizRecoveryInfo(a))
        // Cut inside the recovery slices: trailer and header B are lost, header A remains.
        let cut = Int(info.protectedLength) + Int(info.recordBytes) / 2
        try Data(original[..<cut]).write(to: a)
        #expect(try Xipper.test(a).isOK)  // the footer is found by the backward search (§11)
        let r = try Xipper.scrubXiz(a, repair: true)
        #expect(r.damagedRecoverySlices > 0 && r.repaired)
        #expect(try bytes(a) == original)
    }

    @Test func lostTrailerDamagedDataStillRepairs() throws {
        let t = TempDir()
        let a = try archive(t)
        let original = try bytes(a)
        try damage(a, at: [original.count - 64, 100_000], length: 64)
        let r = try Xipper.scrubXiz(a, repair: true)
        #expect(r.repaired && r.damagedRanges.count == 1)
        #expect(try bytes(a) == original)
    }

    @Test func encryptedArchiveRepairsWithoutPassword() throws {
        let t = TempDir()
        let a = try archive(t, password: "segreto")
        let original = try bytes(a)
        try damage(a, at: [10, 200, 1_000_000])  // superblock and keys block too
        #expect(try Xipper.scrubXiz(a, repair: true).repaired)
        #expect(try bytes(a) == original)
        #expect(try Xipper.test(a, password: "segreto").isOK)
    }

    @Test func editKeepsTheRecord() throws {
        let t = TempDir()
        let a = try archive(t, redundancy: 20)
        t.write("extra.txt", "added later")
        try Xipper.edit(a, changes: [.add(t.url("extra.txt"), as: "src/extra.txt")])
        let info = try #require(Xipper.xizRecoveryInfo(a))
        #expect(abs(info.redundancy - 20) < 1)
        #expect(try Xipper.list(a).contains { $0.path == "src/extra.txt" })
        #expect(try Xipper.scrubXiz(a).isClean)
        #expect(try Xipper.test(a).isOK)
    }

    @Test func addReplaceRemove() throws {
        let t = TempDir()
        let a = try archive(t, redundancy: 0)
        let plain = try bytes(a)
        #expect(Xipper.xizRecoveryInfo(a) == nil)
        #expect(try Xipper.scrubXiz(a).info == nil)
        try Xipper.addXizRecovery(a, redundancy: 5)
        let five = try #require(Xipper.xizRecoveryInfo(a))
        try Xipper.addXizRecovery(a, redundancy: 30)
        let thirty = try #require(Xipper.xizRecoveryInfo(a))
        #expect(thirty.protectedLength == five.protectedLength && thirty.recoverySlices > five.recoverySlices)
        #expect(try Xipper.removeXizRecovery(a))
        #expect(try bytes(a) == plain)
        #expect(try !Xipper.removeXizRecovery(a))
    }

    @Test func cauchySubmatricesAreInvertible() throws {
        // Any m damaged data slices with any m recovery rows: spot-check random square submatrices.
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let k = Int.random(in: 1...3000, using: &rng), m = Int.random(in: 1...min(k, 40), using: &rng)
            let rows = Array((0..<k).shuffled(using: &rng).prefix(m)).map { $0 % max(1, k / 10 + 1) }
            let cols = Array((0..<k).shuffled(using: &rng).prefix(m))
            guard Set(rows).count == m else { continue }
            var a = rows.map { r in cols.map { XizRecovery.coefficient(r, $0, dataSlices: k) } }
            _ = try GF16.invert(&a)
        }
    }
}
