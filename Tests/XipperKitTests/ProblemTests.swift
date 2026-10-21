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

@Suite("SHA256SUMS from a test")
struct DigestTests {
    @Test(arguments: [ArchiveFormat.zip, .tarZstd, .gzip])
    func digestsMatchShasum(format: ArchiveFormat) throws {
        let t = TempDir()
        t.write("src/a.bin", sampleData(3 << 20, seed: 3))
        t.write("src/b.txt", "hello")
        var o = CreateOptions()
        o.format = format
        let source = format == .gzip ? t.url("src/a.bin") : t.url("src")
        let out = t.url("x." + format.fileExtension)
        try Xipper.create(from: [source], to: out, options: o)
        let r = try Xipper.test(out, digests: true)
        #expect(r.isOK)
        let expected = run("/usr/bin/shasum", ["-a", "256", "a.bin"], cwd: t.path + "/src").output.split(separator: " ").first.map(String.init)
        let key = format == .gzip ? "x" : "src/a.bin"  // a single file is named after the archive
        #expect(r.digests[key] == expected)
        #expect(r.sha256sums.contains("  \(key)\n"))
    }
}

@Suite("ZipCrypto writing (compatibility mode)")
struct ZipCryptoWriteTests {
    @Test func readableByUsUnzipAnd7Zip() throws {
        let t = TempDir()
        t.write("src/small.txt", "piccolo")
        t.write("src/big.bin", sampleData(40 << 20, seed: 21))  // chunked (streamed) entry
        var o = CreateOptions()
        o.password = "segreto"
        o.legacyZipCrypto = true
        try Xipper.create(from: [t.url("src")], to: t.url("z.zip"), options: o)
        let entries = try Xipper.list(t.url("z.zip"))
        #expect(entries.filter { $0.kind == .file }.allSatisfy { if case .zipCrypto = $0.encryption { true } else { false } })
        #expect(try Xipper.test(t.url("z.zip"), password: "segreto").isOK)
        let wrong = try Xipper.test(t.url("z.zip"), password: "sbagliata")
        #expect(!wrong.isOK && wrong.failures.allSatisfy { $0.problem == .wrongPassword })
        t.mkdir("ours")
        var x = ExtractOptions()
        x.password = "segreto"
        try Xipper.extract(t.url("z.zip"), to: t.url("ours"), mode: .into, options: x)
        #expect(treesEqual(t.path + "/src", t.path + "/ours/src").0)
        if toolExists("/usr/bin/unzip") {
            #expect(run("/usr/bin/unzip", ["-q", "-P", "segreto", t.path + "/z.zip", "-d", t.path + "/unzip"]).status == 0)
            #expect(treesEqual(t.path + "/src", t.path + "/unzip/src").0)
        }
        if let sevenZip {
            #expect(run(sevenZip, ["t", "-psegreto", t.path + "/z.zip"]).status == 0)
        }
    }
}
