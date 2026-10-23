import Foundation
import Testing
@testable import XipperKit

/// PAR2 recovery data (STUDIO.md, ROADMAP v2 §4): create, verify, repair; interoperability with
/// par2cmdline when Homebrew has it.
@Suite("PAR2 recovery")
struct RecoveryTests {
    static let par2 = ["/opt/homebrew/bin/par2", "/usr/local/bin/par2"].first(where: toolExists)

    func archive(_ t: TempDir, size: Int = 3 << 20) throws -> (URL, [UInt8]) {
        let data = sampleData(size, seed: 123)
        t.write("data.zip", data)
        return (t.url("data.zip"), data)
    }

    @Test func fieldArithmetic() throws {
        for a: UInt16 in [1, 2, 3, 0x1234, 0xFFFF] {
            #expect(GF16.mul(a, GF16.inverse(a)) == 1)
            #expect(GF16.pow(a, 3) == GF16.mul(a, GF16.mul(a, a)))
        }
        let c = GF16.inputConstants(6)
        #expect(c == [2, 4, 16, 128, 256, 2048])  // 2^1, 2^2, 2^4, 2^7, 2^8, 2^11
        var m: [[UInt16]] = [[3, 7], [5, 11]]
        let original = m
        let inv = try GF16.invert(&m)
        for i in 0..<2 { for j in 0..<2 {
            let v = (0..<2).reduce(UInt16(0)) { $0 ^ GF16.mul(original[i][$1], inv[$1][j]) }
            #expect(v == (i == j ? 1 : 0))
        } }
    }

    @Test func createVerifyAndRepair() throws {
        let t = TempDir()
        let (zip, original) = try archive(t)
        let written = try PAR2.create(for: [zip], redundancy: 10, targetSlices: 200)
        #expect(written.map(\.lastPathComponent) == ["data.zip.par2", "data.zip.vol00+20.par2"])
        #expect(PAR2.indexFile(for: zip) == written[0])
        let intact = try PAR2.verify(written[0])
        #expect(intact.isIntact && intact.recoverySlices == 20 && intact.files.first?.slices == 200)

        // Damage 12 slices in different places, including the last (short) one.
        var bytes = original
        let slice = intact.sliceSize
        for k in [0, 5, 17, 50, 51, 52, 99, 120, 150, 180, 198, 199] { bytes[min(bytes.count - 1, k * slice + 77)] ^= 0xA5 }
        try Data(bytes).write(to: zip)
        let damaged = try PAR2.verify(written[1])  // any file of the set works
        #expect(damaged.damagedSlices == 12 && damaged.canRepair)
        let repaired = try PAR2.repair(written[0])
        #expect(repaired.isIntact)
        #expect(try [UInt8](Data(contentsOf: zip)) == original)
    }

    @Test func missingAndTruncatedFilesAreRebuilt() throws {
        let t = TempDir()
        let (zip, original) = try archive(t, size: 200_000)
        let written = try PAR2.create(for: [zip], redundancy: 100, targetSlices: 40)
        try Data(original.prefix(150_000)).write(to: zip)  // truncated
        #expect(try PAR2.repair(written[0]).isIntact)
        #expect(try [UInt8](Data(contentsOf: zip)) == original)
        try FileManager.default.removeItem(at: zip)  // gone entirely
        let report = try PAR2.verify(written[0])
        #expect(report.files.first?.missing == true && report.canRepair)
        try PAR2.repair(written[0])
        #expect(try [UInt8](Data(contentsOf: zip)) == original)
    }

    @Test func rollingCRCMatchesTheDirectOne() {
        let data = sampleData(10_000, seed: 9)
        for window in [4, 100, 4096] {
            let roll = RollingCRC32(window: window)
            var crc = CRC32.checksum(Array(data[0..<window]))
            for pos in 1...(data.count - window) {
                crc = roll.slide(crc, out: data[pos - 1], in: data[pos + window - 1])
                if pos % 97 == 0 || pos == data.count - window { #expect(crc == CRC32.checksum(Array(data[pos..<(pos + window)]))) }
            }
        }
    }

    /// Bytes inserted or deleted in the middle shift every later slice: they are found at their
    /// new offset (as par2cmdline does), so 5% of recovery data is enough.
    @Test(arguments: [1000, -333])
    func shiftedSlicesAreFound(shift: Int) throws {
        let t = TempDir()
        let (zip, original) = try archive(t, size: 1 << 20)
        let written = try PAR2.create(for: [zip], redundancy: 5, targetSlices: 100)
        var bytes = original
        let at = 400_123
        if shift > 0 { bytes.insert(contentsOf: sampleData(shift, seed: 4), at: at) } else { bytes.removeSubrange(at..<(at - shift)) }
        try Data(bytes).write(to: zip)
        let r = try PAR2.verify(written[0])
        #expect(!r.isIntact && r.damagedSlices > 50 && r.missingSlices <= 2 && r.canRepair)
        #expect(r.files[0].movedSlices == r.damagedSlices - r.missingSlices)
        #expect(try PAR2.repair(written[0]).isIntact)
        #expect(try [UInt8](Data(contentsOf: zip)) == original)
    }

    /// Garbage appended to the file: nothing to recover, the file is cut back.
    @Test func trailingBytesAreCutWithoutRecoveryData() throws {
        let t = TempDir()
        let (zip, original) = try archive(t, size: 100_000)
        let written = try PAR2.create(for: [zip], redundancy: 1, targetSlices: 10)
        for f in written.dropFirst() { try FileManager.default.removeItem(at: f) }  // no recovery slices at all
        try Data(original + [1, 2, 3]).write(to: zip)
        let r = try PAR2.verify(written[0])
        #expect(!r.isIntact && r.missingSlices == 0 && r.recoverySlices == 0 && r.canRepair)
        #expect(try PAR2.repair(written[0]).isIntact)
        #expect(try [UInt8](Data(contentsOf: zip)) == original)
    }

    @Test func tooMuchDamageIsRefused() throws {
        let t = TempDir()
        let (zip, original) = try archive(t, size: 400_000)
        let written = try PAR2.create(for: [zip], redundancy: 5, targetSlices: 100)
        var bytes = original
        for k in stride(from: 0, to: bytes.count, by: 20_000) { bytes[k] ^= 1 }  // 20 slices, 5 recovery
        try Data(bytes).write(to: zip)
        #expect(!(try PAR2.verify(written[0]).canRepair))
        #expect(throws: XipperError.self) { try PAR2.repair(written[0]) }
        #expect(try [UInt8](Data(contentsOf: zip)) == bytes)  // left untouched
    }

    @Test(.enabled(if: par2 != nil))
    func interoperatesWithPar2cmdline() throws {
        let t = TempDir()
        let (zip, original) = try archive(t, size: 1 << 20)
        // Ours, verified and repaired by par2cmdline.
        let written = try PAR2.create(for: [zip], redundancy: 10, targetSlices: 100)
        #expect(run(Self.par2!, ["verify", written[0].path]).status == 0)
        var bytes = original
        bytes[1000] ^= 0xFF
        try Data(bytes).write(to: zip)
        #expect(run(Self.par2!, ["repair", written[0].path]).status == 0)
        #expect(try [UInt8](Data(contentsOf: zip)) == original)
        // par2cmdline's, verified and repaired by us.
        for f in try FileManager.default.contentsOfDirectory(atPath: t.path) where f.hasSuffix(".par2") || f.contains(".1") {
            try? FileManager.default.removeItem(atPath: t.path + "/" + f)
        }
        #expect(run(Self.par2!, ["create", "-r10", "-n1", "data.zip"], cwd: t.path).status == 0)
        try Data(bytes).write(to: zip)
        #expect(try PAR2.verify(t.url("data.zip.par2")).damagedSlices == 1)
        try PAR2.repair(t.url("data.zip.par2"))
        #expect(try [UInt8](Data(contentsOf: zip)) == original)
    }
}
