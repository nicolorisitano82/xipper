import Foundation
import Testing
@testable import XipperKit

/// The hash tool: BLAKE3 (our C), XXH3, SHA-3 and the others, lists and their verification.
@Suite("Hash tool")
struct HashTests {
    /// BLAKE3 input of the official test vectors: byte i is i mod 251.
    static func pattern(_ n: Int) -> [UInt8] { (0..<n).map { UInt8($0 % 251) } }

    func digest(_ bytes: [UInt8], _ a: ChecksumAlgorithm, more: Bool = false) -> String {
        let h = MultiHasher([a])
        bytes.withUnsafeBytes { h.update($0, more: more) }
        return h.finalize()[a]!
    }

    @Test func knownVectors() {
        let abc = Array("abc".utf8)
        #expect(digest([], .blake3) == "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262")
        #expect(digest(abc, .blake3) == "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85")
        #expect(digest(Self.pattern(1024), .blake3) == "42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7")
        #expect(digest(abc, .sha3_256) == "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532")
        #expect(digest([], .xxh3) == "2d06800538d394c2")
        #expect(digest([], .xxh128) == "99aa06d3014798d86001c324468d497f")
        #expect(digest(abc, .crc32) == "352441c2")
        #expect(digest(abc, .sha256) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// Checked against an independent implementation (the tree defined recursively, in Python),
    /// across chunk and NEON 4-chunk boundaries.
    @Test(arguments: [
        (2049, "5f4d72f40d7a5f82b15ca2b2e44b1de3c2ef86c426c95c1af0b6879522563030"),
        (8193, "bab6c09cb8ce8cf459261398d2e7aef35700bf488116ceb94a36d0f5f1b7bc3b"),
        (102_400, "bc3e3d41a1146b069abffad3c0d44860cf664390afce4d9661f7902e7943e085"),
    ])
    func blake3AcrossChunks(length: Int, expected: String) {
        #expect(digest(Self.pattern(length), .blake3) == expected)
        // Fed in odd pieces: the same.
        let h = MultiHasher([.blake3])
        let data = Self.pattern(length)
        var i = 0
        while i < data.count {
            let n = min(777, data.count - i)
            data[i..<(i + n)].withUnsafeBytes { h.update($0) }
            i += n
        }
        #expect(h.finalize()[.blake3] == expected)
    }

    /// The parallel path (1 MiB subtrees on all cores) gives the same digest.
    @Test func blake3ParallelSubtrees() throws {
        let t = TempDir()
        let unit = (0..<256).map { UInt8($0 % 251) }
        var big = [UInt8]()
        for _ in 0..<((16 << 20) / 256) { big += unit }
        big.append(0)
        t.write("big.bin", big)
        let r = try Xipper.hashFiles([t.url("big.bin")], algorithms: [.blake3])
        #expect(r.first?.checksums[.blake3] == "ee48985fc9d223a9efa6fea4fb4abca4d9e0fb6243ac8256362bc52da3908300")
    }

    @Test func listsRoundTripAndCatchChanges() throws {
        let t = TempDir()
        makeTree(t, bigSize: 1 << 20)
        for a in [ChecksumAlgorithm.blake3, .xxh128, .sha3_256] {
            let list = t.url("src/" + a.listName)
            try Xipper.createManifest(of: [t.url("src")], to: list, algorithms: [a], overwrite: true)
            #expect(try Xipper.verifyManifest(list).isOK, "\(a)")  // algorithm found from the list's name
        }
        t.write("src/readme.txt", "changed\n")
        let r = try Xipper.verifyManifest(t.url("src/B3SUMS"))
        #expect(r.mismatches.map(\.path) == ["readme.txt"])
    }

    @Test func shasumReadsOurListsAndWeReadBSDLines() throws {
        let t = TempDir()
        makeTree(t, bigSize: 1 << 20)
        try Xipper.createManifest(of: [t.url("src")], to: t.url("src/SHA256SUMS"), algorithms: [.sha256])
        #expect(run("/usr/bin/shasum", ["-a", "256", "-c", "SHA256SUMS"], cwd: t.path + "/src").status == 0)
        let entries = try Xipper.hashFiles([t.url("src/readme.txt"), t.url("src/data/small.bin")], algorithms: [.sha256, .blake3],
                                           relativeTo: t.url("src"))
        let bsd = Xipper.checksumLines(entries, algorithms: [.sha256, .blake3])
        #expect(bsd.contains("BLAKE3 (readme.txt) = ") && bsd.contains("SHA256 (data/small.bin) = "))
        t.write("src/both.txt", bsd)
        #expect(try Xipper.verifyManifest(t.url("src/both.txt")).checked == 2)
    }

    @Test(arguments: [ArchiveFormat.zip, .sevenZip, .xiz, .tarZstd])
    func contentsOfArchivesMatchTheFiles(format: ArchiveFormat) throws {
        let t = TempDir()
        makeTree(t, bigSize: 2 << 20)
        var o = CreateOptions()
        o.format = format
        try Xipper.create(from: [t.url("src")], to: t.url("a." + format.fileExtension), options: o)
        let inside = try Xipper.hashContents(t.url("a." + format.fileExtension), algorithms: [.blake3, .xxh128])
        let onDisk = try Xipper.hashFiles([t.url("src")], algorithms: [.blake3, .xxh128], relativeTo: t.url(""))
        let disk = Dictionary(uniqueKeysWithValues: onDisk.map { ($0.path, $0.checksums) })
        #expect(inside.count >= 5)
        for e in inside where e.size ?? 0 > 0 { #expect(disk[e.path] == e.checksums, "\(e.path)") }
    }
}
