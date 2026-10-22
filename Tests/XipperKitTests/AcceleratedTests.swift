import CXipShims
import Foundation
import Testing
@testable import XipperKit

/// Accelerated paths against their portable references: same output, byte for byte.
@Suite("Accelerated paths")
struct AcceleratedTests {
    // MARK: PAR2 GF(2^16), NEON

    @Test func gf16NeonMatchesPortableAndLogExp() {
        var rng = SystemRandomNumberGenerator()
        for bytes in [0, 2, 62, 64, 126, 130, 4094, 100_002] {
            for _ in 0..<4 {
                let factor = UInt16.random(in: 1...UInt16.max, using: &rng)
                let src = (0..<(bytes + 1)).map { _ in UInt8.random(in: 0...255, using: &rng) }  // +1: unaligned start
                let dst0 = (0..<bytes).map { _ in UInt8.random(in: 0...255, using: &rng) }
                var tables = [UInt8](repeating: 0, count: 128)
                xs_gf16_tables(factor, &tables)
                var neon = dst0, portable = dst0, reference = dst0
                src.withUnsafeBufferPointer { s in
                    xs_gf16_muladd(&neon, s.baseAddress! + 1, bytes, tables)
                    xs_gf16_muladd_portable(&portable, s.baseAddress! + 1, bytes, tables)
                }
                for i in stride(from: 0, to: bytes - 1, by: 2) {
                    let w = UInt16(src[i + 1]) | UInt16(src[i + 2]) << 8
                    let p = GF16.mul(factor, w)
                    reference[i] ^= UInt8(p & 0xFF)
                    reference[i + 1] ^= UInt8(p >> 8)
                }
                #expect(neon == portable && neon == reference, "\(bytes) bytes, factor \(factor)")
            }
        }
    }

    // MARK: bzip2, parallel blocks

    func decode(_ data: [UInt8], _ t: StreamTransform, piece: Int = 7777) throws -> [UInt8] {
        var out: [UInt8] = []
        let sink: ByteSink = { out += $0 }
        var i = 0
        while i < data.count {
            try data[i..<min(data.count, i + piece)].withUnsafeBytes { try t.process($0, sink) }
            i += piece
        }
        try t.finish(sink)
        return out
    }

    func systemBzip2(_ data: [UInt8], level: Int) throws -> [UInt8] {
        let t = TempDir()
        t.write("in", data)
        #expect(run("/usr/bin/bzip2", ["-\(level)", "-k", t.path + "/in"]).status == 0)
        return try [UInt8](Data(contentsOf: t.url("in.bz2")))
    }

    @Test func bzip2BlocksDecodeInParallelLikeLibbz2() throws {
        let text = Array(String(repeating: "Xipper decomprime i blocchi bzip2 in parallelo. ", count: 120_000).utf8)
        let mixed = text + sampleData(1 << 20, seed: 5) + [UInt8](repeating: 0x41, count: 300_000) + text.prefix(12345)
        var inputs: [[UInt8]] = []
        inputs.append(try systemBzip2(mixed, level: 9))  // one stream, many blocks at arbitrary bit offsets
        inputs.append(try systemBzip2(mixed, level: 1))
        inputs.append(inputs[0] + inputs[1])  // concatenated streams, different block sizes
        inputs.append(try systemBzip2([], level: 9))  // empty stream: no block at all
        let enc = ParallelBzip2Encoder(level: 3, workload: .threads(4), cancel: nil)  // Xipper: one stream per block
        inputs.append(try decode(mixed, enc))
        for (n, input) in inputs.enumerated() {
            let reference = try decode(input, try Bzip2Decoder())
            for window in [64 << 10, 1 << 20, 32 << 20] {
                #expect(try decode(input, ParallelBzip2Decoder(window: window)) == reference, "input \(n), window \(window)")
            }
        }
    }

    @Test func damagedOrTruncatedBzip2IsRefused() throws {
        let good = try systemBzip2(Array(String(repeating: "riservato ", count: 200_000).utf8) + sampleData(500_000, seed: 2), level: 9)
        var flipped = good
        flipped[good.count / 2] ^= 0x10
        #expect(throws: XipperError.self) { _ = try decode(flipped, ParallelBzip2Decoder(window: 1 << 20)) }
        #expect(throws: XipperError.self) { _ = try decode(Array(good.prefix(good.count - 7)), ParallelBzip2Decoder()) }
        #expect(throws: XipperError.self) { _ = try decode(good + Array("garbage".utf8), ParallelBzip2Decoder()) }
    }

    @Test func bzip2MagicIsFoundAtEveryBitOffset() {
        for shift in 0..<8 {
            var buf = [UInt8](repeating: 0, count: 32)
            var bit = 8 * 5 + shift
            for k in stride(from: 47, through: 0, by: -1) {
                if (UInt64(0x3141_5926_5359) >> UInt64(k)) & 1 == 1 { buf[bit >> 3] |= UInt8(0x80 >> (bit & 7)) }
                bit += 1
            }
            var kind: Int32 = 0
            #expect(xs_bz2_next_magic(buf, buf.count, 0, &kind) == 8 * 5 + shift && kind == 1)
            #expect(xs_bz2_next_magic(buf, buf.count, 8 * 5 + shift + 1, &kind) == -1)  // SIZE_MAX
        }
    }

    // MARK: xz with the LZMA SDK's ARM64 decoder

    static let xz = ["/opt/homebrew/bin/xz", "/usr/local/bin/xz"].first(where: toolExists)

    func xzTool(_ data: [UInt8], _ args: [String]) throws -> [UInt8] {
        let t = TempDir()
        t.write("in", data)
        let r = run(Self.xz!, args + ["-k", "-f", t.path + "/in"])
        #expect(r.status == 0, "\(r.output)")
        return try [UInt8](Data(contentsOf: t.url("in.xz")))
    }

    @Test(.enabled(if: xz != nil)) func xzAsmDecoderMatchesLiblzma() throws {
        let text = Array(String(repeating: "Xipper decodifica xz con l'assembler ARM64 di 7-Zip. ", count: 90_000).utf8)
        let data = text + sampleData(700_000, seed: 8) + text.prefix(99_999)
        var inputs: [[UInt8]] = []
        inputs.append(try xzTool(data, ["-T1", "-6"]))  // one block, sizes not declared: streamed
        inputs.append(try xzTool(data, ["-T4", "-1", "--block-size=500000"]))  // declared sizes: parallel
        inputs.append(try xzTool(data, ["-T1", "--check=crc32"]))
        inputs.append(try xzTool(data, ["-T1", "--check=sha256"]))
        inputs.append(try xzTool(data, ["-T1", "--check=none"]))
        inputs.append(try xzTool(data, ["-T1", "--arm64", "--lzma2=preset=6"]))  // BCJ filter: liblzma
        inputs.append(try xzTool([], ["-T1"]))  // no block
        inputs.append(inputs[0] + [0, 0, 0, 0] + inputs[1])  // concatenated, with stream padding
        let enc = try LZMACoder.xzEncoder(preset: 6, threads: 4)  // Xipper's own encoder
        inputs.append(try decode(data, enc))
        for (n, input) in inputs.enumerated() {
            let reference = try decode(input, try LZMACoder.xzDecoder(threads: 1))
            for window in [64 << 10, 32 << 20] {
                #expect(try decode(input, XzDecoder(threads: 4, window: window)) == reference, "input \(n), window \(window)")
            }
        }
        var bad = inputs[1]
        bad[bad.count / 2] ^= 0x04
        #expect(throws: XipperError.self) { _ = try decode(bad, XzDecoder(threads: 4)) }
        #expect(throws: XipperError.self) { _ = try decode(Array(inputs[0].dropLast(5)), XzDecoder(threads: 1)) }
        #expect(throws: XipperError.self) { _ = try decode(inputs[0] + [1, 2, 3, 4], XzDecoder(threads: 1)) }
    }
}
