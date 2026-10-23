import Foundation
import Testing
@testable import XipperKit

/// Mutation fuzzing of every reader (STUDIO.md §7.6): valid archives get random byte flips,
/// truncations and splices, then go through detect, list, test and extract. Any outcome is
/// fine except a crash, a hang, or a write outside the destination.
/// Deterministic (seeded); XIPPER_FUZZ_ITERATIONS raises the count for long runs.
@Suite("Fuzzing", .serialized)
struct FuzzTests {
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static var iterations: Int { Int(ProcessInfo.processInfo.environment["XIPPER_FUZZ_ITERATIONS"] ?? "") ?? 60 }

    func mutate(_ input: [UInt8], _ rng: inout SplitMix) -> [UInt8] {
        var b = input
        switch Int.random(in: 0..<5, using: &rng) {
        case 0:  // flip a few bytes
            for _ in 0..<Int.random(in: 1...8, using: &rng) where !b.isEmpty {
                b[Int.random(in: 0..<b.count, using: &rng)] ^= UInt8.random(in: 1...255, using: &rng)
            }
        case 1:  // truncate
            b = Array(b.prefix(Int.random(in: 0..<max(1, b.count), using: &rng)))
        case 2:  // overwrite a run with 0xFF / 0x00 (sizes and counts become extreme)
            if b.count > 8 {
                let at = Int.random(in: 0..<(b.count - 8), using: &rng)
                let v: UInt8 = Bool.random(using: &rng) ? 0xFF : 0x00
                for i in at..<(at + Int.random(in: 1...8, using: &rng)) { b[i] = v }
            }
        case 3:  // duplicate a slice (repeated headers, overlapping data)
            if b.count > 16 {
                let from = Int.random(in: 0..<(b.count - 16), using: &rng)
                let len = Int.random(in: 1...min(512, b.count - from), using: &rng)
                b.insert(contentsOf: b[from..<(from + len)], at: Int.random(in: 0...b.count, using: &rng))
            }
        default:  // delete a slice
            if b.count > 16 {
                let from = Int.random(in: 0..<(b.count - 16), using: &rng)
                b.removeSubrange(from..<min(b.count, from + Int.random(in: 1...256, using: &rng)))
            }
        }
        return b
    }

    @Test(arguments: [ArchiveFormat.zip, .sevenZip, .xiz, .tar, .tarGzip, .tarBzip2, .tarXz, .tarZstd, .gzip, .bgzf, .xz, .zstd])
    func mutatedArchivesNeverCrashOrEscape(format: ArchiveFormat) throws {
        let t = TempDir()
        t.write("src/a.txt", String(repeating: "Xipper fuzz ", count: 300))
        t.write("src/sub/b.bin", sampleData(20 << 10, seed: 5))
        t.symlink("src/link", to: "a.txt")
        var o = CreateOptions()
        o.format = format
        try fuzz(format, o, password: nil, t)
    }

    /// Encrypted XIZ: the keys block, the STREAM catalog and the AEAD frames under mutation.
    @Test func mutatedEncryptedXizNeverCrashesOrEscapes() throws {
        let t = TempDir()
        t.write("src/a.txt", String(repeating: "Xipper fuzz ", count: 300))
        t.write("src/sub/b.bin", sampleData(20 << 10, seed: 5))
        t.symlink("src/link", to: "a.txt")
        var o = CreateOptions()
        o.format = .xiz
        o.password = "fuzz"
        o.xizKDF = .minimum
        try fuzz(.xiz, o, password: "fuzz", t)
    }

    /// XIZ with an appended segment (1.1): gaps between frames and the footer chain under mutation.
    @Test func mutatedAppendedXizNeverCrashesOrEscapes() throws {
        let t = TempDir()
        t.write("src/a.txt", String(repeating: "Xipper fuzz ", count: 300))
        t.write("src/sub/b.bin", sampleData(20 << 10, seed: 5))
        t.write("more.txt", "appended\n")
        var o = CreateOptions()
        o.format = .xiz
        try fuzz(.xiz, o, password: nil, t) { a in
            try Xipper.edit(a, changes: [.delete("src/a.txt"), .add(t.url("more.txt"), as: "src/more.txt")])
        }
    }

    /// RAR (read only, libarchive's readers): libarchive's own test vectors under mutation.
    @Test(arguments: ["rar_compress_normal.rar", "rar5_multiple_files_solid.rar", "rar5_compressed.rar", "rar_unicode.rar"])
    func mutatedRarNeverCrashesOrEscapes(name: String) throws {
        let t = TempDir()
        let bytes = try [UInt8](Data(contentsOf: RarTests.url(name)))
        var rng = SplitMix(state: UInt64(bytes.count) &* 31)
        var limits = ExtractionLimits()
        limits.maxTotalBytes = 64 << 20
        for i in 0..<Self.iterations {
            let sample = t.url("m\(i).rar")
            try Data(mutate(bytes, &rng)).write(to: sample)
            _ = try? Xipper.list(sample)
            _ = try? Xipper.test(sample, workload: .threads(2))
            t.mkdir("out\(i)")
            var options = ExtractOptions()
            options.limits = limits
            _ = try? Xipper.extract(sample, to: t.url("out\(i)"), mode: .into, options: options)
            let stray = try FileManager.default.contentsOfDirectory(atPath: t.path).filter { !$0.hasPrefix("out") && !$0.hasPrefix("m") }
            #expect(stray.isEmpty, "iteration \(i) wrote \(stray)")
            try? FileManager.default.removeItem(at: sample)
            try? FileManager.default.removeItem(at: t.url("out\(i)"))
        }
    }

    func fuzz(_ format: ArchiveFormat, _ o: CreateOptions, password: String?, _ t: TempDir,
              prepare: ((URL) throws -> Void)? = nil) throws {
        let source = format.isSingleFile ? t.url("src/a.txt") : t.url("src")
        let original = t.url("orig." + format.fileExtension)
        try Xipper.create(from: [source], to: original, options: o)
        try prepare?(original)
        let bytes = try [UInt8](Data(contentsOf: original))

        var rng = SplitMix(state: UInt64(abs(format.rawValue.hashValue % 1_000_003)) &+ (password == nil ? 17 : 29))
        var limits = ExtractionLimits()
        limits.maxTotalBytes = 64 << 20  // a mutated size field must not fill the disk
        for i in 0..<Self.iterations {
            let sample = t.url("m\(i)." + format.fileExtension)
            try Data(mutate(bytes, &rng)).write(to: sample)
            _ = try? ArchiveFormat.detect(sample)
            _ = try? Xipper.list(sample, password: password)
            _ = try? Xipper.test(sample, password: password, workload: .threads(2))
            let dest = "out\(i)"
            t.mkdir(dest)
            var options = ExtractOptions()
            options.limits = limits
            options.workload = .threads(2)
            options.password = password
            _ = try? Xipper.extract(sample, to: t.url(dest), mode: .into, options: options)
            // Nothing may appear next to the destination folders (traversal through a mutated name).
            let stray = try FileManager.default.contentsOfDirectory(atPath: t.path)
                .filter { !$0.hasPrefix("out") && !$0.hasPrefix("m") && $0 != "src" && !$0.hasPrefix("orig") }
            #expect(stray.isEmpty, "iteration \(i) wrote \(stray)")
            try? FileManager.default.removeItem(at: sample)
            try? FileManager.default.removeItem(at: t.url(dest))
        }
    }
}
