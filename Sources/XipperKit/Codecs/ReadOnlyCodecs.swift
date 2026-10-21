import Compression
import Foundation

// Read-only codecs from the format matrix (STUDIO.md §4.2): brotli and the LZ4 frame format.

/// Brotli (`.br`, `.tar.br`), decoded by the system Compression framework.
final class BrotliDecoder: StreamTransform {
    private var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
    private let out = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 20)
    private var ended = false

    init() throws {
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_BROTLI) == COMPRESSION_STATUS_OK else {
            throw XipperError.codec("brotli init")
        }
    }

    deinit {
        compression_stream_destroy(&stream)
        out.deallocate()
    }

    private func run(_ input: UnsafeRawBufferPointer, flags: Int32, _ sink: ByteSink) throws {
        guard !ended else {
            if !input.isEmpty { throw XipperError.corrupt("data after the end of the brotli stream") }
            return
        }
        stream.src_ptr = input.baseAddress?.assumingMemoryBound(to: UInt8.self) ?? UnsafePointer(bitPattern: 1)!
        stream.src_size = input.count
        while true {
            stream.dst_ptr = out
            stream.dst_size = 1 << 20
            let status = compression_stream_process(&stream, flags)
            let produced = (1 << 20) - stream.dst_size
            if produced > 0 { try sink(UnsafeRawBufferPointer(start: out, count: produced)) }
            switch status {
            case COMPRESSION_STATUS_END:
                ended = true
                if stream.src_size > 0 { throw XipperError.corrupt("data after the end of the brotli stream") }
                return
            case COMPRESSION_STATUS_OK:
                // More output may be pending only when the buffer was filled.
                if stream.src_size == 0 && produced < (1 << 20) { return }
            default:
                throw XipperError.corrupt("invalid brotli data")
            }
        }
    }

    func process(_ input: UnsafeRawBufferPointer, _ sink: ByteSink) throws { try run(input, flags: 0, sink) }

    func finish(_ sink: ByteSink) throws {
        try run(UnsafeRawBufferPointer(start: nil, count: 0), flags: Int32(COMPRESSION_STREAM_FINALIZE.rawValue), sink)
        if !ended { throw XipperError.corrupt("truncated brotli stream") }
    }
}

/// LZ4 frame format (`.lz4`, `.tar.lz4`): frames, skippable frames, independent or linked
/// blocks, block and content checksums (xxHash32). Our own decoder, so linked blocks can see
/// the previous 64 KiB.
final class LZ4FrameDecoder: StreamTransform {
    private static let magic: UInt32 = 0x184D_2204
    private static let window = 64 << 10

    private var buf: [UInt8] = []  // pending compressed input
    private var history: [UInt8] = []  // last decoded bytes (window for linked blocks)
    private enum State { case frameStart, blocks, contentChecksum, skippable(Int) }
    private var state = State.frameStart
    private var blockChecksum = false, contentChecksum = false, linked = false
    private var maxBlock = 4 << 20
    private var contentHash = XXH32()
    private var sawFrame = false

    func process(_ input: UnsafeRawBufferPointer, _ sink: ByteSink) throws {
        buf.append(contentsOf: input)
        var pos = 0
        defer { buf.removeFirst(pos) }
        func le32(_ at: Int) -> UInt32 {
            UInt32(buf[at]) | UInt32(buf[at + 1]) << 8 | UInt32(buf[at + 2]) << 16 | UInt32(buf[at + 3]) << 24
        }
        while true {
            switch state {
            case .frameStart:
                guard buf.count - pos >= 7 else { return }
                let m = le32(pos)
                if m & 0xFFFF_FFF0 == 0x184D_2A50 {  // skippable frame
                    guard buf.count - pos >= 8 else { return }
                    state = .skippable(Int(le32(pos + 4)))
                    pos += 8
                    continue
                }
                guard m == Self.magic else { throw XipperError.corrupt("not an LZ4 frame") }
                let flg = buf[pos + 4], bd = buf[pos + 5]
                guard flg >> 6 == 1 else { throw XipperError.unsupported("LZ4 frame version \(flg >> 6)") }
                let hasSize = flg & 0x08 != 0, hasDict = flg & 0x01 != 0
                let headerLen = 4 + 2 + (hasSize ? 8 : 0) + (hasDict ? 4 : 0) + 1
                guard buf.count - pos >= headerLen else { return }
                if hasDict { throw XipperError.unsupported("LZ4 frames with an external dictionary") }
                linked = flg & 0x20 == 0
                blockChecksum = flg & 0x10 != 0
                contentChecksum = flg & 0x04 != 0
                let sizeID = Int(bd >> 4) & 7
                guard sizeID >= 4 else { throw XipperError.corrupt("invalid LZ4 block size") }
                maxBlock = 1 << (8 + 2 * sizeID)
                contentHash = XXH32()
                history.removeAll(keepingCapacity: true)
                pos += headerLen
                sawFrame = true
                state = .blocks
            case let .skippable(left):
                let n = min(left, buf.count - pos)
                pos += n
                if n < left { state = .skippable(left - n); return }
                state = .frameStart
            case .blocks:
                guard buf.count - pos >= 4 else { return }
                let word = le32(pos)
                if word == 0 {
                    pos += 4
                    state = contentChecksum ? .contentChecksum : .frameStart
                    continue
                }
                let size = Int(word & 0x7FFF_FFFF)
                guard size <= maxBlock else { throw XipperError.corrupt("LZ4 block larger than its declared maximum") }
                let total = 4 + size + (blockChecksum ? 4 : 0)
                guard buf.count - pos >= total else { return }
                let data = pos + 4
                if blockChecksum {
                    var h = XXH32()
                    buf.withUnsafeBytes { h.update(UnsafeRawBufferPointer(rebasing: $0[data..<(data + size)])) }
                    guard h.digest() == le32(data + size) else { throw XipperError.integrity(entry: "LZ4 block", detail: "xxHash32 mismatch") }
                }
                let block: [UInt8]
                if word & 0x8000_0000 != 0 {
                    block = Array(buf[data..<(data + size)])
                } else {
                    block = try buf.withUnsafeBytes { try Self.decodeBlock(UnsafeRawBufferPointer(rebasing: $0[data..<(data + size)]),
                                                                            history: linked ? history : [], limit: maxBlock) }
                }
                pos += total
                block.withUnsafeBytes { contentHash.update($0) }
                if linked {
                    history.append(contentsOf: block)
                    if history.count > Self.window { history.removeFirst(history.count - Self.window) }
                }
                try block.withUnsafeBytes { try sink($0) }
            case .contentChecksum:
                guard buf.count - pos >= 4 else { return }
                guard contentHash.digest() == le32(pos) else { throw XipperError.integrity(entry: "LZ4 frame", detail: "content xxHash32 mismatch") }
                pos += 4
                state = .frameStart
            }
        }
    }

    func finish(_ sink: ByteSink) throws {
        guard sawFrame, case .frameStart = state, buf.isEmpty else { throw XipperError.corrupt("truncated LZ4 stream") }
    }

    /// One LZ4 block (sequences of literals and matches); matches may reach into `history`.
    static func decodeBlock(_ src: UnsafeRawBufferPointer, history: [UInt8], limit: Int) throws -> [UInt8] {
        var out = history
        let base = history.count
        out.reserveCapacity(base + limit)
        var i = 0
        let n = src.count
        func length(_ initial: Int) throws -> Int {
            var len = initial
            if initial == 15 {
                while true {
                    guard i < n else { throw XipperError.corrupt("truncated LZ4 block") }
                    let b = Int(src[i]); i += 1
                    len += b
                    if b != 255 { break }
                }
            }
            return len
        }
        while i < n {
            let token = Int(src[i]); i += 1
            let lit = try length(token >> 4)
            guard lit <= n - i, out.count - base + lit <= limit else { throw XipperError.corrupt("invalid LZ4 literal run") }
            out.append(contentsOf: src[i..<(i + lit)])
            i += lit
            if i == n { break }  // last sequence has literals only
            guard n - i >= 2 else { throw XipperError.corrupt("truncated LZ4 block") }
            let offset = Int(src[i]) | Int(src[i + 1]) << 8
            i += 2
            let matchLen = try length(token & 15) + 4
            guard offset > 0, offset <= out.count, out.count - base + matchLen <= limit else {
                throw XipperError.corrupt("invalid LZ4 match")
            }
            let start = out.count - offset
            if offset >= matchLen {
                out.append(contentsOf: out[start..<(start + matchLen)])
            } else {
                for k in 0..<matchLen { out.append(out[start + k]) }  // overlapping copy
            }
        }
        return Array(out[base...])
    }
}

/// xxHash32 (seed 0), used by the LZ4 frame format.
struct XXH32 {
    private static let p1: UInt32 = 2_654_435_761, p2: UInt32 = 2_246_822_519, p3: UInt32 = 3_266_489_917
    private static let p4: UInt32 = 668_265_263, p5: UInt32 = 374_761_393
    private var v = (p1 &+ p2, p2, UInt32(0), 0 &- p1)
    private var total = 0
    private var tail: [UInt8] = []

    private static func round(_ acc: UInt32, _ input: UInt32) -> UInt32 {
        ((acc &+ input &* p2) << 13 | (acc &+ input &* p2) >> 19) &* p1
    }

    private static func read32(_ p: UnsafeRawBufferPointer, _ at: Int) -> UInt32 {
        p.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian
    }

    mutating func update(_ data: UnsafeRawBufferPointer) {
        total += data.count
        var input = tail + Array(data)
        var i = 0
        input.withUnsafeBytes { p in
            while input.count - i >= 16 {
                v.0 = Self.round(v.0, Self.read32(p, i))
                v.1 = Self.round(v.1, Self.read32(p, i + 4))
                v.2 = Self.round(v.2, Self.read32(p, i + 8))
                v.3 = Self.round(v.3, Self.read32(p, i + 12))
                i += 16
            }
        }
        input.removeFirst(i)
        tail = input
    }

    func digest() -> UInt32 {
        var h: UInt32
        if total >= 16 {
            h = (v.0 << 1 | v.0 >> 31) &+ (v.1 << 7 | v.1 >> 25) &+ (v.2 << 12 | v.2 >> 20) &+ (v.3 << 18 | v.3 >> 14)
        } else {
            h = Self.p5
        }
        h = h &+ UInt32(truncatingIfNeeded: total)
        var i = 0
        tail.withUnsafeBytes { p in
            while tail.count - i >= 4 {
                h = h &+ Self.read32(p, i) &* Self.p3
                h = (h << 17 | h >> 15) &* Self.p4
                i += 4
            }
        }
        while i < tail.count {
            h = h &+ UInt32(tail[i]) &* Self.p5
            h = (h << 11 | h >> 21) &* Self.p1
            i += 1
        }
        h ^= h >> 15; h = h &* Self.p2
        h ^= h >> 13; h = h &* Self.p3
        h ^= h >> 16
        return h
    }
}
