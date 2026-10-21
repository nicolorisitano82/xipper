import CLZMA
import Foundation
import Testing
@testable import XipperKit

/// The LZMA SDK decoder (7-Zip's ARM64 assembly loop) against liblzma, the portable path.
@Suite("LZMA decoders: assembly vs portable")
struct LZMADecoderTests {
    static let inputs: [(String, [UInt8])] = [
        ("empty-ish", [42]),
        ("text", Array(String(repeating: "the quick brown fox jumps over the lazy dog 0123456789\n", count: 40_000).utf8)),
        ("mixed", sampleData(3 << 20, seed: 11)),
        ("random", (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 13 ^ $0) }),
        ("zeros", [UInt8](repeating: 0, count: 5 << 20)),
    ]

    /// Raw LZMA1 with liblzma (end marker optional, as in 7z).
    func lzma1(_ data: [UInt8], preset: UInt32, endMarker: Bool) throws -> (props: [UInt8], packed: [UInt8]) {
        var opts = lzma_options_lzma()
        #expect(lzma_lzma_preset(&opts, preset) == 0)
        opts.dict_size = UInt32(max(4096, min(data.count, 1 << 22)))
        var strm = lzma_stream()
        defer { lzma_end(&strm) }
        let id: lzma_vli = endMarker ? 0x4000_0000_0000_0001 : 0x4000_0000_0000_0002  // LZMA1, LZMA1EXT
        if !endMarker { opts.ext_size_low = UInt32(truncatingIfNeeded: data.count); opts.ext_size_high = UInt32(truncatingIfNeeded: data.count >> 32) }
        var props = [UInt8](repeating: 0, count: 5)
        try withUnsafeMutablePointer(to: &opts) { o in
            var filters = [lzma_filter(id: id, options: o), lzma_filter(id: .max, options: nil)]
            if lzma_raw_encoder(&strm, &filters) != LZMA_OK { throw XipperError.codec("init") }
            var f = lzma_filter(id: 0x4000_0000_0000_0001, options: o)
            _ = lzma_properties_encode(&f, &props)
        }
        var out = [UInt8](repeating: 0, count: data.count + data.count / 2 + 4096)
        var produced = 0
        data.withUnsafeBufferPointer { i in
            out.withUnsafeMutableBufferPointer { o in
                strm.next_in = i.baseAddress
                strm.avail_in = i.count
                strm.next_out = o.baseAddress
                strm.avail_out = o.count
                _ = lzma_code(&strm, LZMA_FINISH)
                produced = o.count - strm.avail_out
            }
        }
        return (props, Array(out[0..<produced]))
    }

    /// Feeds `packed` in pieces of `piece` bytes; nil if the decoder rejected the data.
    func decode(_ t: StreamTransform, _ packed: [UInt8], piece: Int) -> [UInt8]? {
        var out: [UInt8] = []
        do {
            var i = 0
            while i < packed.count {
                let n = min(piece, packed.count - i)
                try packed[i..<(i + n)].withUnsafeBytes { try t.process($0) { out.append(contentsOf: $0) } }
                i += n
            }
            try t.finish { out.append(contentsOf: $0) }
        } catch { return nil }
        return out
    }

    @Test(arguments: inputs)
    func lzma2Agrees(name: String, data: [UInt8]) throws {
        for preset in [1, 6] {
            // Two independent chunks joined with a dictionary reset, as the 7z writer does.
            let half = data.count / 2
            var packed: [UInt8] = []
            if half > 0 {
                packed = try data[0..<half].withUnsafeBytes { try LZMA2Chunk.encode($0, preset: preset, dictionary: 1 << 22) }
                packed.removeLast()
            }
            packed += try data[half...].withUnsafeBytes { try LZMA2Chunk.encode($0, preset: preset, dictionary: 1 << 22) }
            let prop = SZLZMA2.prop(forDictionary: 1 << 22)
            for piece in [1, 4093, 1 << 20] where piece > 1 || data.count < 100_000 {
                let asm = decode(try SZLZMA.decoder2(prop: prop, unpackSize: Int64(data.count), assembly: true), packed, piece: piece)
                let portable = decode(try SZLZMA.decoder2(prop: prop, unpackSize: Int64(data.count), assembly: false), packed, piece: piece)
                #expect(asm == data, "\(name) preset \(preset) piece \(piece): \(asm?.count ?? -1) bytes")
                #expect(portable == data, "\(name) preset \(preset) piece \(piece): \(portable?.count ?? -1) bytes")
            }
        }
    }

    @Test(arguments: inputs)
    func lzma1Agrees(name: String, data: [UInt8]) throws {
        for endMarker in [false, true] {
            let (props, packed) = try lzma1(data, preset: 6, endMarker: endMarker)
            for piece in [7, 65536] {
                let asm = decode(try SZLZMA.decoder(props: props, unpackSize: Int64(data.count), assembly: true), packed, piece: piece)
                let portable = decode(try SZLZMA.decoder(props: props, unpackSize: Int64(data.count), assembly: false), packed, piece: piece)
                #expect(asm == data, "\(name) marker \(endMarker) piece \(piece): \(asm?.count ?? -1) bytes")
                #expect(portable == data, "\(name) marker \(endMarker) piece \(piece): \(portable?.count ?? -1) bytes")
            }
        }
    }

    /// Damaged and truncated streams: never a crash; when both decoders accept, same bytes.
    @Test func damagedStreams() throws {
        let data = sampleData(1 << 20, seed: 3)
        let packed = try data.withUnsafeBytes { try LZMA2Chunk.encode($0, preset: 6, dictionary: 1 << 20) }
        let prop = SZLZMA2.prop(forDictionary: 1 << 20)
        var x: UInt64 = 0x1234_5678
        for round in 0..<60 {
            var bad = packed
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            if round % 3 == 0 {
                bad = Array(bad[0..<Int(x % UInt64(bad.count))])
            } else {
                bad[Int(x % UInt64(bad.count))] ^= UInt8(truncatingIfNeeded: x >> 40) | 1
            }
            let asm = decode(try SZLZMA.decoder2(prop: prop, unpackSize: Int64(data.count), assembly: true), bad, piece: 50_000)
            let portable = decode(try SZLZMA.decoder2(prop: prop, unpackSize: Int64(data.count), assembly: false), bad, piece: 50_000)
            if let asm, let portable { #expect(asm == portable, "round \(round): \(asm.count) vs \(portable.count) bytes") }
            if round % 3 == 0 { #expect(asm == nil && portable == nil, "truncation accepted, round \(round)") }
        }
    }

    /// 7-Zip's own LZMA and LZMA2 archives through both decoders (whole archive test).
    @Test func sevenZipArchivesWithBothDecoders() throws {
        guard let sevenZip else { return }
        let t = TempDir()
        makeTree(t, bigSize: 3 << 20)
        for m in ["-m0=LZMA", "-m0=LZMA2", "-mf=BCJ2"] {
            let a = t.path + "/a\(m.hash).7z"
            #expect(run(sevenZip, ["a", "-bd", "-snl", m, a, "src"], cwd: t.path).status == 0)
            let archive = try SevenZipArchive(path: a, password: nil)
            for fi in archive.streams.folders.indices {
                let f = archive.streams.folders[fi]
                for c in f.coders where c.method == SevenZip.Method.lzma || c.method == SevenZip.Method.lzma2 {
                    _ = c  // the folder pipeline picks the global choice; compare whole-folder output instead
                }
                let reference = try readAll(archive.open(folder: fi))
                let saved = SZLZMA.useAssembly
                defer { SZLZMA.useAssembly = saved }
                SZLZMA.useAssembly = !saved
                let other = try readAll(archive.open(folder: fi))
                #expect(reference == other, "\(m) folder \(fi): \(reference.count) vs \(other.count) bytes")
            }
        }
    }

    func readAll(_ s: ByteSource) throws -> [UInt8] {
        var out: [UInt8] = []
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 1 << 16, alignment: 16)
        defer { buf.deallocate() }
        while case let n = try s.read(into: buf, max: 1 << 16), n > 0 { out.append(contentsOf: UnsafeRawBufferPointer(start: buf, count: n)) }
        return out
    }
}
