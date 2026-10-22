import CLZMA
import CXipShims
import Foundation

let lzmaFilterLZMA1: lzma_vli = 0x4000_0000_0000_0001

/// Encoders for ZIP methods 14 (LZMA) and 95 (xz), one shot per entry or chunk.
enum ZipLZMA {
    /// Preset options with the dictionary capped to the input: same output, far less encoder
    /// memory for small entries (xz -9 would otherwise allocate ~700 MB per worker).
    static func options(preset: Int, size: Int64) -> lzma_options_lzma {
        var o = lzma_options_lzma()
        _ = lzma_lzma_preset(&o, UInt32(max(0, min(9, preset))))
        var d: UInt32 = 4096
        while Int64(d) < size && d < o.dict_size { d <<= 1 }
        o.dict_size = min(o.dict_size, d)
        return o
    }

    /// Method 14 prefix: LZMA SDK version (9.20), properties size, 5 property bytes.
    static func header(_ o: inout lzma_options_lzma) -> [UInt8] {
        var props = [UInt8](repeating: 0, count: 5)
        withUnsafeMutablePointer(to: &o) { op in
            var filter = lzma_filter(id: lzmaFilterLZMA1, options: op)
            _ = lzma_properties_encode(&filter, &props)
        }
        return [9, 20, 5, 0] + props
    }

    /// Method 14: header, then raw LZMA1 with the end marker (general purpose bit 1). nil when
    /// the output would not be smaller.
    static func lzma(_ src: UnsafeRawBufferPointer, preset: Int) -> [UInt8]? {
        var o = options(preset: preset, size: Int64(src.count))
        let head = header(&o)
        let cap = src.count + src.count / 16 + 4096
        var pos = 0
        var ret = LZMA_OK
        let body = [UInt8](unsafeUninitializedCapacity: cap) { buf, n in
            withUnsafeMutablePointer(to: &o) { op in
                var filters = [lzma_filter(id: lzmaFilterLZMA1, options: op), lzma_filter(id: lzmaVLIUnknown, options: nil)]
                ret = lzma_raw_buffer_encode(&filters, nil, src.baseAddress?.assumingMemoryBound(to: UInt8.self), src.count,
                                             buf.baseAddress, &pos, cap)
            }
            n = ret == LZMA_OK ? pos : 0
        }
        if ret != LZMA_OK || head.count + body.count >= src.count { return nil }
        return head + body
    }

    /// Method 95: a complete .xz stream (CRC-64). `allowExpansion` for chunks of a big entry,
    /// which can no longer fall back to store.
    static func xz(_ src: UnsafeRawBufferPointer, preset: Int, allowExpansion: Bool = false) -> [UInt8]? {
        var o = options(preset: preset, size: Int64(src.count))
        let cap = lzma_stream_buffer_bound(src.count)
        var pos = 0
        var ret = LZMA_OK
        let out = [UInt8](unsafeUninitializedCapacity: cap) { buf, n in
            withUnsafeMutablePointer(to: &o) { op in
                var filters = [lzma_filter(id: lzmaFilterLZMA2, options: op), lzma_filter(id: lzmaVLIUnknown, options: nil)]
                ret = lzma_stream_buffer_encode(&filters, LZMA_CHECK_CRC64, nil, src.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                                src.count, buf.baseAddress, &pos, cap)
            }
            n = ret == LZMA_OK ? pos : 0
        }
        if ret != LZMA_OK || (!allowExpansion && out.count >= src.count) { return nil }
        return out
    }
}

/// ZIP method 12: one bzip2 stream.
enum ZipBzip2 {
    static func compress(_ src: UnsafeRawBufferPointer, level: Int, allowExpansion: Bool = false) -> [UInt8]? {
        let cap = src.count + src.count / 100 + 600
        let out = [UInt8](unsafeUninitializedCapacity: cap) { buf, n in
            n = xs_bzip2_compress(src.baseAddress?.assumingMemoryBound(to: UInt8.self), src.count, Int32(max(1, min(9, level))),
                                  buf.baseAddress, cap)
        }
        if out.isEmpty || (!allowExpansion && out.count >= src.count) { return nil }
        return out
    }
}

/// Method 95 for big entries: chunks compressed in parallel as .xz blocks, joined into one
/// stream with its own index. Concatenated streams would be valid .xz, but libarchive stops
/// after the first one inside a ZIP entry.
enum ZipXzStream {
    struct Block { var bytes: [UInt8]; var unpadded: lzma_vli; var uncompressed: lzma_vli }

    static func block(_ src: UnsafeRawBufferPointer, preset: Int) -> Block? {
        var o = ZipLZMA.options(preset: preset, size: Int64(src.count))
        let cap = lzma_block_buffer_bound(src.count)
        var pos = 0
        var unpadded: lzma_vli = 0
        var ret = LZMA_OK
        let out = [UInt8](unsafeUninitializedCapacity: cap) { buf, n in
            withUnsafeMutablePointer(to: &o) { op in
                var filters = [lzma_filter(id: lzmaFilterLZMA2, options: op), lzma_filter(id: lzmaVLIUnknown, options: nil)]
                filters.withUnsafeMutableBufferPointer { f in
                    var b = lzma_block()
                    b.version = 0
                    b.check = LZMA_CHECK_CRC64
                    b.filters = f.baseAddress
                    ret = lzma_block_buffer_encode(&b, nil, src.baseAddress?.assumingMemoryBound(to: UInt8.self), src.count,
                                                   buf.baseAddress, &pos, cap)
                    unpadded = lzma_block_unpadded_size(&b)
                }
            }
            n = ret == LZMA_OK ? pos : 0
        }
        if ret != LZMA_OK || unpadded == 0 { return nil }
        return Block(bytes: out, unpadded: unpadded, uncompressed: lzma_vli(src.count))
    }

    static func header() -> [UInt8] {
        var flags = lzma_stream_flags()
        flags.check = LZMA_CHECK_CRC64
        var h = [UInt8](repeating: 0, count: 12)
        _ = lzma_stream_header_encode(&flags, &h)
        return h
    }

    /// Index and stream footer for the blocks written after `header()`.
    static func trailer(_ blocks: [(unpadded: lzma_vli, uncompressed: lzma_vli)]) throws -> [UInt8] {
        guard let idx = lzma_index_init(nil) else { throw XipperError.codec("xz index") }
        defer { lzma_index_end(idx, nil) }
        for b in blocks where lzma_index_append(idx, nil, b.unpadded, b.uncompressed) != LZMA_OK {
            throw XipperError.codec("xz index")
        }
        let size = Int(lzma_index_size(idx))
        var out = [UInt8](repeating: 0, count: size + 12)
        var pos = 0
        guard lzma_index_buffer_encode(idx, &out, &pos, size) == LZMA_OK else { throw XipperError.codec("xz index") }
        var flags = lzma_stream_flags()
        flags.check = LZMA_CHECK_CRC64
        flags.backward_size = lzma_vli(size)
        let ok = out.withUnsafeMutableBufferPointer { lzma_stream_footer_encode(&flags, $0.baseAddress! + size) == LZMA_OK }
        guard ok else { throw XipperError.codec("xz footer") }
        return out
    }
}

/// Method 12 for big entries: chunks compressed in parallel as one-block bzip2 streams, joined
/// bit by bit into one stream (as lbzip2 does): 7-Zip and libarchive stop after the first
/// stream inside a ZIP entry. Blocks are not byte-aligned, so leftover bits carry over.
struct Bzip2Joiner {
    /// Input per chunk that always fits one block: RLE1 expands runs of 4 by 5/4 at most.
    static func chunkSize(level: Int) -> Int { (max(1, min(9, level)) * 100_000 - 19) * 4 / 5 }

    private var acc: UInt32 = 0
    private var pending = 0
    private var crc: UInt32 = 0
    private var started = false
    private var out: [UInt8] = []

    private static let blockMagic: UInt64 = 0x3141_5926_5359
    private static let endMagic: UInt64 = 0x1772_4538_5090

    private static func bits(_ s: [UInt8], _ at: Int, _ n: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in at..<(at + n) { v = v << 1 | UInt64(s[i >> 3] >> (7 - UInt8(i & 7)) & 1) }
        return v
    }

    private mutating func put(_ value: UInt64, _ n: Int) {
        for i in stride(from: n - 1, through: 0, by: -1) { putBit(UInt32(value >> UInt64(i) & 1)) }
    }

    private mutating func putBit(_ b: UInt32) {
        acc = acc << 1 | b
        pending += 1
        if pending == 8 { out.append(UInt8(acc & 0xFF)); acc = 0; pending = 0 }
    }

    private mutating func putByte(_ b: UInt8) {
        if pending == 0 { out.append(b); return }
        let v = acc << 8 | UInt32(b)
        out.append(UInt8(truncatingIfNeeded: v >> UInt32(pending)))
        acc = v & ((1 << UInt32(pending)) - 1)
    }

    /// Appends the block of a one-block stream; returns the bytes completed so far.
    mutating func append(_ s: [UInt8]) throws -> [UInt8] {
        guard s.count >= 24, s[0] == 0x42, s[1] == 0x5A, s[2] == 0x68, Self.bits(s, 32, 48) == Self.blockMagic else {
            throw XipperError.codec("bzip2 join: bad stream")
        }
        let blockCRC = UInt32(Self.bits(s, 80, 32))
        let total = s.count * 8
        guard let end = (0..<8).map({ total - $0 - 80 })
            .first(where: { $0 > 112 && Self.bits(s, $0, 48) == Self.endMagic && UInt32(Self.bits(s, $0 + 48, 32)) == blockCRC })
        else { throw XipperError.codec("bzip2 join: not a single block") }
        if !started { out.append(contentsOf: s[0..<4]); started = true }
        for i in 4..<(end >> 3) { putByte(s[i]) }
        for i in (end & ~7)..<end { putBit(UInt32(s[i >> 3] >> (7 - UInt8(i & 7)) & 1)) }
        crc = (crc << 1 | crc >> 31) ^ blockCRC
        defer { out.removeAll(keepingCapacity: true) }
        return out
    }

    /// End-of-stream marker, combined CRC and padding.
    mutating func finish() -> [UInt8] {
        put(Self.endMagic, 48)
        put(UInt64(crc), 32)
        while pending != 0 { putBit(0) }
        return out
    }
}
