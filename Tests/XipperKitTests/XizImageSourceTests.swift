import CryptoKit
import Darwin
import Foundation
import Testing
@testable import XipperKit

/// Reading a damaged source: failed reads are retried, narrowed down to the bad pieces, zeroed and mapped;
/// a source that disappears stops the acquisition instead of being mapped as unreadable.
@Suite("Forensic image source")
struct XizImageSourceTests {
    static let examiner = XizSigner(key: XizSigningKey(), label: "Esaminatore")

    /// Every read that touches [bad, bad+len) fails with EIO; counts the reads of each sector.
    final class Faults: @unchecked Sendable {
        let bad: [(UInt64, UInt64)]
        let healAfter: Int
        var reads: [UInt64: Int] = [:]
        let lock = NSLock()
        init(_ bad: [(UInt64, UInt64)], healAfter: Int = .max) { self.bad = bad; self.healAfter = healAfter }
        func check(_ off: UInt64, _ n: Int) -> Int32? {
            let hit = bad.first { off < $0.0 + $0.1 && $0.0 < off + UInt64(n) }
            guard let hit else { return nil }
            return lock.withLock {
                reads[hit.0, default: 0] += 1
                return reads[hit.0]! > healAfter ? nil : EIO
            }
        }
    }

    func source(_ t: TempDir, _ data: [UInt8], _ faults: Faults) throws -> XizForensic.ImageSource {
        let s = try XizForensic.ImageSource(path: t.write("disk.img", data))
        s.fault = { faults.check($0, $1) }
        return s
    }

    var data: [UInt8] { sampleData(XizForensic.blockSize * 2 + 300_000, seed: 3) }

    func acquire(_ s: XizForensic.ImageSource, _ out: String, _ errors: XizForensic.ReadErrors) throws -> (XizForensic.ImageReport, [XizForensic.Unreadable.Range]) {
        var o = XizForensic.ImageOptions()
        o.readErrors = errors
        final class Seen: @unchecked Sendable { var list: [XizForensic.Unreadable.Range] = [] }
        let seen = Seen()
        o.onUnreadable = { r in seen.list.append(r) }
        let r = try XizForensic.acquireImage(from: s, to: out, options: o, signer: Self.examiner)
        return (r, seen.list)
    }

    @Test func badSectorsAreMappedExactly() throws {
        let t = TempDir()
        var d = data
        // One bad sector inside the first block, three in a row across the block boundary.
        let a: UInt64 = 1_000 * 512, b = UInt64(XizForensic.blockSize) - 512
        let s = try source(t, d, Faults([(a, 512), (b, 3 * 512)]))
        let (r, seen) = try acquire(s, t.path + "/r.xiz", .standard)
        #expect(r.unreadableBytes == 4 * 512)
        for (o, n) in [(a, 512), (b, 3 * 512)] { for i in 0..<n { d[Int(o) + i] = 0 } }
        #expect(r.sha256 == Array(SHA256.hash(data: d)))
        #expect(seen.map(\.offset) == [a, b, UInt64(XizForensic.blockSize)])
        let v = try XizForensic.verify(t.path + "/r.xiz")
        #expect(v.passed, "\(v.checks)")
        let map = try #require(XizForensic.blocks(t.path + "/r.xiz").first?.records(.unreadable).first)
        let u = try XizForensic.Unreadable(map.value)
        // Ranges across blocks are joined in the map.
        #expect(u.ranges.map(\.offset) == [a, b] && u.ranges.map(\.length) == [512, 3 * 512])
        #expect(u.ranges.allSatisfy { $0.error == EIO && $0.attempts == 2 })
    }

    @Test func retriesRecoverAFlakySector() throws {
        let t = TempDir()
        let faults = Faults([(4096, 512)], healAfter: 3)
        let s = try source(t, data, faults)
        let (r, _) = try acquire(s, t.path + "/r.xiz", .exhaustive)
        #expect(r.unreadableBytes == 0)
        #expect(r.sha256 == Array(SHA256.hash(data: data)))
    }

    @Test func fastModeGivesUpWholePieces() throws {
        let t = TempDir()
        let faults = Faults([(70_000, 512)])
        let s = try source(t, data, faults)
        let (r, _) = try acquire(s, t.path + "/r.xiz", .fast)
        #expect(r.unreadableBytes == 64 << 10)
        // Fast: the 4 MiB block, one 64 KiB piece; no retries.
        #expect(faults.reads[70_000] == 2)
    }

    @Test func vanishedSourceStops() throws {
        let t = TempDir()
        let s = try XizForensic.ImageSource(path: t.write("disk.img", data))
        s.fault = { off, _ in off >= UInt64(XizForensic.blockSize) ? ENXIO : nil }
        #expect(throws: XipperError.self) { _ = try acquire(s, t.path + "/r.xiz", .standard) }
        #expect(!FileManager.default.fileExists(atPath: t.path + "/r.xiz"))
    }

    @Test func writableDescriptorRefused() throws {
        let t = TempDir()
        let fd = open(t.write("disk.img", [1, 2, 3]), O_RDWR)
        #expect(throws: XipperError.self) { _ = try XizForensic.ImageSource(fd: fd, name: "disk.img") }
    }
}
