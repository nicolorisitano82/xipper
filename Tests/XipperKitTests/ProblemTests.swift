import Foundation
import Testing
@testable import XipperKit

@Suite("Structured problems and extraction caps")
struct ProblemTests {
    /// A stored (uncompressed) ZIP whose first entry's data has one flipped byte.
    func corruptedZip(_ t: TempDir) throws -> URL {
        t.write("src/a.txt", Array(repeating: UInt8(ascii: "a"), count: 4096))
        t.write("src/b.txt", "ok")
        var o = CreateOptions()
        o.zipMethod = .store
        let zip = t.url("c.zip")
        try Xipper.create(from: [t.url("src")], to: zip, options: o)
        var bytes = try [UInt8](Data(contentsOf: zip))
        let run = [UInt8](repeating: UInt8(ascii: "a"), count: 64)
        let i = try #require((0..<(bytes.count - 64)).first { Array(bytes[$0..<$0 + 64]) == run }) + 100
        bytes[i] = UInt8(ascii: "b")
        try Data(bytes).write(to: zip)
        return zip
    }

    @Test func crcMismatchCarriesBothValues() throws {
        let t = TempDir()
        let r = try Xipper.test(try corruptedZip(t))
        #expect(r.failures.count == 1)
        guard case let .checksumMismatch(expected, actual)? = r.failures.first?.problem else {
            Issue.record("expected a checksum problem, got \(String(describing: r.failures.first?.problem))")
            return
        }
        #expect(expected != actual)
        #expect(r.failures[0].reason.contains("CRC-32 mismatch (expected"))
    }

    @Test func blockedEntriesAreSecurityProblems() {
        #expect(SkippedEntry.Problem.escapesDestination.isSecurityBlock)
        #expect(SkippedEntry.Problem.symlinkOutside(target: "/etc").isSecurityBlock)
        #expect(!SkippedEntry.Problem.alreadyExists.isSecurityBlock)
        #expect(SkippedEntry(path: "x", error: .truncated(entry: "x", read: 1, expected: 2)).problem == .truncated(read: 1, expected: 2))
    }

    /// "Extract anyway" with a cap: writing starts, stops at the cap and leaves nothing behind.
    @Test func stopAtLimitDiscardsPartialOutput() throws {
        let t = TempDir()
        for i in 0..<4 { t.write("src/f\(i).bin", sampleData(1 << 20, seed: UInt64(i + 1))) }
        try Xipper.create(from: [t.url("src")], to: t.url("a.zip"))
        t.mkdir("dest")
        var o = ExtractOptions()
        o.limits.maxTotalBytes = 3 << 19
        o.limits.stopAtLimit = true
        #expect(throws: XipperError.self) { try Xipper.extract(t.url("a.zip"), to: t.url("dest"), options: o) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.path + "/dest").isEmpty)
    }
}
