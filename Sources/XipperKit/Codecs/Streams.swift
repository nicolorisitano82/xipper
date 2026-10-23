import CLZMA
import CXipShims
import CZstd
import Foundation

// liblzma constants defined through UINT32_C/LZMA_VLI_C macros, which Swift does not import.
private let lzmaConcatenated: UInt32 = 0x08
private let lzmaFilterLZMA1EXT: lzma_vli = 0x4000_0000_0000_0002
private let lzmaLZMA1EXTAllowEOPM: UInt32 = 0x01
let lzmaFilterLZMA2: lzma_vli = 0x21
let lzmaVLIUnknown: lzma_vli = .max

typealias ByteSink = (UnsafeRawBufferPointer) throws -> Void

/// A push-style codec: feed input with `process`, end with `finish`.
/// Output is delivered to the sink in pieces of at most `outputChunk` bytes.
protocol StreamTransform: AnyObject {
    func process(_ input: UnsafeRawBufferPointer, _ sink: ByteSink) throws
    func finish(_ sink: ByteSink) throws
    /// Input bytes accepted but not yet compressed. Multi-threaded encoders buffer whole blocks
    /// (xz -9: 128 MiB per thread), so progress counted on input alone stalls, then jumps.
    var backlog: Int64 { get }
    /// Called between codec calls (at most every 250 ms) while a multi-threaded encoder waits
    /// for its workers, so progress can move without output; nil to stop.
    func onIdle(_ f: (() -> Void)?)
}

extension StreamTransform {
    var backlog: Int64 { 0 }
    func onIdle(_ f: (() -> Void)?) {}
}

private let outputChunk = 1 << 20

/// Scratch output buffer owned by one codec instance.
private final class OutBuffer {
    let ptr = UnsafeMutableRawPointer.allocate(byteCount: outputChunk, alignment: 64)
    deinit { ptr.deallocate() }
    func emit(_ n: Int, _ sink: ByteSink) throws {
        if n > 0 { try sink(UnsafeRawBufferPointer(start: ptr, count: n)) }
    }
}

// MARK: - Store

final class PassthroughTransform: StreamTransform {
    func process(_ input: UnsafeRawBufferPointer, _ sink: ByteSink) throws { if !input.isEmpty { try sink(input) } }
    func finish(_ sink: ByteSink) throws {}
}

// MARK: - Deflate64 (ZIP method 9, read only)

final class Deflate64Decoder: StreamTransform {
    private let s: OpaquePointer
    /// Input the decoder has not taken yet (it waits for a whole symbol or block header).
    private var pending: [UInt8] = []
    private let out = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 20)
    private var ended = false

    init() throws {
        guard let s = xs_inflate64_new() else { throw XipperError.codec("Deflate64") }
        self.s = s
    }

    deinit {
        xs_inflate64_free(s)
        out.deallocate()
    }

    func process(_ input: UnsafeRawBufferPointer, _ sink: ByteSink) throws {
        pending.append(contentsOf: input)
        try run(final: false, sink)
    }

    func finish(_ sink: ByteSink) throws {
        try run(final: true, sink)
        if !ended { throw XipperError.corrupt("Deflate64 data ends early") }
    }

    private func run(final: Bool, _ sink: ByteSink) throws {
        var consumed = 0
        defer { pending.removeFirst(consumed) }
        while !ended {
            var used = 0, produced = 0
            let status = pending.withUnsafeBufferPointer { p in
                xs_inflate64_run(s, p.baseAddress.map { $0 + consumed }, p.count - consumed, &used, out, 1 << 20, &produced, final ? 1 : 0)
            }
            consumed += used
            if produced > 0 { try sink(UnsafeRawBufferPointer(start: out, count: produced)) }
            switch Int(status) {
            case XS_INFLATE64_END: ended = true
            case XS_INFLATE64_OUTPUT_FULL: continue
            case XS_INFLATE64_NEED_INPUT: return
            default: throw XipperError.corrupt("invalid Deflate64 data")
            }
        }
    }
}

// MARK: - Inflate (raw deflate / gzip)

final class InflateDecoder: StreamTransform {
    private let z: OpaquePointer
    private let out = OutBuffer()
    private let gzip: Bool
    private var ended = false

    /// `gzip`: expect gzip framing and accept concatenated members (pigz, `cat a.gz b.gz`).
    init(gzip: Bool) throws {
        guard let z = xs_inflate_new(gzip ? 1 : 0) else { throw XipperError.codec("inflate init") }
        self.z = z
        self.gzip = gzip
    }
    deinit { xs_inflate_free(z) }

    func process(_ input: UnsafeRawBufferPointer, _ sink: ByteSink) throws {
        var rest = input
        while true {
            if ended {
                // Another gzip member may follow; raw deflate ignores trailing bytes (ZIP padding).
                guard gzip, !rest.isEmpty else { return }
                if rest.allSatisfy({ $0 == 0 }) { return }  // zero padding after the last member
                xs_inflate_reset(z)
                ended = false
            }
            var used = 0, produced = 0
            let r = xs_inflate_run(z, rest.baseAddress?.assumingMemoryBound(to: UInt8.self), rest.count, &used,
                                   out.ptr.assumingMemoryBound(to: UInt8.self), outputChunk, &produced)
            try out.emit(produced, sink)
            rest = UnsafeRawBufferPointer(rebasing: rest[used...])
            switch r {
            case Z_STREAM_END: ended = true
            case Z_OK, Z_BUF_ERROR:
                if rest.isEmpty && produced < outputChunk { return }
                if used == 0 && produced == 0 { return }
            default: throw XipperError.corrupt("invalid deflate data (zlib \(r))")
            }
        }
    }

    func finish(_ sink: ByteSink) throws {
        // Drain anything zlib still holds.
        while !ended {
            var used = 0, produced = 0
            let r = xs_inflate_run(z, nil, 0, &used, out.ptr.assumingMemoryBound(to: UInt8.self), outputChunk, &produced)
            try out.emit(produced, sink)
            if r == Z_STREAM_END { ended = true; break }
            if produced == 0 { break }
        }
        if !ended { throw XipperError.corrupt("truncated deflate stream") }
    }
}

// MARK: - bzip2

final class Bzip2Decoder: StreamTransform {
    private let b: OpaquePointer
    private let out = OutBuffer()
    private var ended = false

    init() throws {
        guard let b = xs_bunzip_new() else { throw XipperError.codec("bzip2 init") }
        self.b = b
    }
    deinit { xs_bunzip_free(b) }

    func process(_ input: UnsafeRawBufferPointer, _ sink: ByteSink) throws {
        var rest = input
        while true {
            if ended {
                // Parallel bzip2 output is a concatenation of independent streams.
                guard !rest.isEmpty else { return }
                if xs_bunzip_reset(b) != BZ_OK { throw XipperError.codec("bzip2 reset") }
                ended = false
            }
            var used = 0, produced = 0
            let r = xs_bunzip_run(b, rest.baseAddress?.assumingMemoryBound(to: UInt8.self), rest.count, &used,
                                  out.ptr.assumingMemoryBound(to: UInt8.self), outputChunk, &produced)
            try out.emit(produced, sink)
            rest = UnsafeRawBufferPointer(rebasing: rest[used...])
            switch r {
            case BZ_STREAM_END: ended = true
            case BZ_OK:
                if rest.isEmpty && produced < outputChunk { return }
                if used == 0 && produced == 0 { return }
            default: throw XipperError.corrupt("invalid bzip2 data (\(r))")
            }
        }
    }

    func finish(_ sink: ByteSink) throws {
        while !ended {
            var used = 0, produced = 0
            let r = xs_bunzip_run(b, nil, 0, &used, out.ptr.assumingMemoryBound(to: UInt8.self), outputChunk, &produced)
            try out.emit(produced, sink)
            if r == BZ_STREAM_END { ended = true; break }
            if produced == 0 || r != BZ_OK { break }
        }
        if !ended { throw XipperError.corrupt("truncated bzip2 stream") }
    }
}

/// bzip2 decoded block by block in parallel, as lbzip2 does: the 48-bit block magics are found at
/// any bit offset (CXipShims/bzip2par.c), each block is decoded as a stream of its own with its
/// CRC checked, and the stream CRC is checked against the blocks' CRCs. A magic that is really
/// data makes its block fail, and the block is retried merged with the next one.
/// Single-threaded libbz2 decodes ~40 MB/s; this scales with the cores.
final class ParallelBzip2Decoder: StreamTransform {
    private var buf: [UInt8] = []
    private var pos = 0  // bit position in `buf` of the next header or magic
    private var level = 0  // 0: expecting a stream header
    private var combined: UInt32 = 0
    private var streams = 0
    private let window: Int

    /// `window`: compressed bytes buffered before a parallel round (tests use small ones).
    init(window: Int = 32 << 20) { self.window = window }

    func process(_ input: UnsafeRawBufferPointer, _ sink: ByteSink) throws {
        buf.append(contentsOf: input)
        if buf.count - pos / 8 >= window { try drain(final: false, sink) }
    }

    func finish(_ sink: ByteSink) throws {
        try drain(final: true, sink)
        if level != 0 || streams == 0 || (pos + 7) / 8 < buf.count { throw XipperError.corrupt("truncated bzip2 stream") }
    }

    private func bits(_ at: Int, _ n: Int32) -> UInt64 { buf.withUnsafeBufferPointer { xs_bz2_bits($0.baseAddress, at, n) } }

    /// One step of the plan: a block (start magic → next mark) or the end of a stream.
    private enum Item { case block(start: Int, end: Int, level: Int), end(at: Int) }

    private func drain(final: Bool, _ sink: ByteSink) throws {
        let total = buf.count * 8
        // 1. Plan from `pos`, across streams, as far as the buffered input goes.
        var items: [Item] = []
        var p = pos, lvl = level
        plan: while true {
            if lvl == 0 {
                let i = (p + 7) / 8
                if i == buf.count { break }
                guard i + 4 <= buf.count else { break }
                guard Self.isHeader(buf, i) else { throw XipperError.corrupt("invalid bzip2 data") }
                lvl = Int(buf[i + 3] - 0x30)
                p = (i + 4) * 8
                continue
            }
            if p + 80 > total { break }
            let magic = bits(p, 48)
            if magic == 0x1772_4538_5090 {
                items.append(.end(at: p))
                p = (p + 80 + 7) / 8 * 8
                lvl = 0
                continue
            }
            guard magic == 0x3141_5926_5359 else { throw XipperError.corrupt("invalid bzip2 data") }
            // The block ends at the next magic; an end magic counts only if a stream header (or
            // the end of the data) follows it, otherwise it is data.
            var from = p + 48
            while true {
                var kind: Int32 = 0
                let at = buf.withUnsafeBufferPointer { xs_bz2_next_magic($0.baseAddress, $0.count, from, &kind) }
                if at < 0 || at + 80 > total { break plan }
                if kind == 2 {
                    let next = (at + 80 + 7) / 8
                    if next + 4 > buf.count && !final { break plan }
                    if next < buf.count && !(next + 4 <= buf.count && Self.isHeader(buf, next)) { from = at + 1; continue }
                }
                items.append(.block(start: p, end: at, level: lvl))
                p = at
                break
            }
        }

        // 2. Decode every block in parallel.
        let blocks = items.compactMap { if case let .block(s, e, l) = $0 { (s, e, l) } else { nil } }
        var decoded = try decodeBlocks(blocks)

        // 3. In order: emit, fold the block CRCs, check each stream's CRC. A block that fails is
        //    retried joined with the following ones (its end was a magic inside the data).
        var b = 0
        var k = 0
        while k < items.count {
            switch items[k] {
            case .end(let at):
                let stored = UInt32(bits(at + 48, 32))
                guard stored == combined else { throw XipperError.checksumMismatch(entry: "bzip2 stream", expected: stored, actual: combined) }
                pos = (at + 80 + 7) / 8 * 8
                level = 0
                combined = 0
                streams += 1
                k += 1
            case let .block(start, _, lvl):
                var (out, ok) = decoded[b]
                var j = k
                while !ok {
                    j += 1
                    guard j < items.count, case let .block(_, end, _) = items[j] else { break }
                    (out, ok) = try decodeBlocks([(start, end, lvl)])[0]
                }
                guard ok else {
                    if j < items.count || final { throw XipperError.corrupt("invalid bzip2 data") }
                    k = items.count  // the rest of this block is not buffered yet
                    continue
                }
                let crc = UInt32(bits(start + 48, 32))
                combined = (combined << 1 | combined >> 31) ^ crc
                try emit(out, to: sink)
                level = lvl
                if case let .block(_, end, _) = items[j] { pos = end }
                b += j - k + 1
                k = j + 1
            }
        }
        decoded = []
        // Drop what has been consumed.
        let drop = pos / 8
        if drop > 0 { buf.removeSubrange(0..<drop); pos -= drop * 8 }
    }

    private static func isHeader(_ b: [UInt8], _ i: Int) -> Bool {
        b[i] == 0x42 && b[i + 1] == 0x5A && b[i + 2] == 0x68 && (0x31...0x39).contains(b[i + 3])
    }

    private func decodeBlocks(_ blocks: [(Int, Int, Int)]) throws -> [([UInt8], Bool)] {
        let results = Slots<([UInt8], Bool)>(blocks.count)
        try buf.withUnsafeBufferPointer { b in
            let base = b.baseAddress!
            try parallelFor(blocks.count, workload: .interactive, cancel: nil) { k in
                let (start, end, level) = blocks[k]
                var cap = level * 100_000 * 2
                while true {
                    var out = [UInt8](unsafeUninitializedCapacity: cap) { _, n in n = cap }
                    var n = cap
                    let r = out.withUnsafeMutableBufferPointer { xs_bz2_decode_block(base, start, end, Int32(level), $0.baseAddress, &n) }
                    // RLE1 can expand a block up to ~52 times.
                    if r == BZ_OUTBUFF_FULL && cap < level * 100_000 * 64 { cap *= 4; continue }
                    if r == BZ_OK { out.removeSubrange(n...); results[k] = (out, true) } else { results[k] = ([], false) }
                    return
                }
            }
        }
        return (0..<blocks.count).map { results.take($0)! }
    }
}

// MARK: - liblzma (xz, ZIP LZMA)

final class LZMACoder: StreamTransform {
    private var strm = lzma_stream()
    private let out = OutBuffer()
    private var ended = false
    private let name: String
    /// LZMA1 with a known size: done once this many bytes came out. The optional end marker
    /// after them is not waited for (liblzma rejects one split across two inputs).
    private var expectedOutput: Int64?
    /// Checked between `lzma_code` calls; with the multi-threaded coders' 250 ms timeout this
    /// bounds how long a cancellation waits, even while workers compress a large block.
    var cancel: CancellationToken?

    private var idle: (() -> Void)?
    func onIdle(_ f: (() -> Void)?) { idle = f }

    private init(name: String) { self.name = name }

    var backlog: Int64 {
        var done: UInt64 = 0, produced: UInt64 = 0
        lzma_get_progress(&strm, &done, &produced)
        return Int64(strm.total_in) - Int64(min(done, strm.total_in))
    }
    deinit { lzma_end(&strm) }

    /// .xz decoder, multi-threaded for multi-block streams, accepting concatenated streams.
    static func xzDecoder(threads: Int) throws -> LZMACoder {
        let c = LZMACoder(name: "xz")
        var mt = lzma_mt()
        mt.threads = UInt32(max(1, threads))
        mt.flags = lzmaConcatenated
        mt.memlimit_threading = UInt64(min(ProcessInfo.processInfo.physicalMemory / 4, 4 << 30))
        mt.memlimit_stop = UInt64.max
        mt.timeout = 250
        try c.check(lzma_stream_decoder_mt(&c.strm, &mt))
        return c
    }

    /// .xz encoder; `threads > 1` splits the input into independently compressed blocks.
    static func xzEncoder(preset: Int, threads: Int, cancel: CancellationToken? = nil) throws -> LZMACoder {
        let c = LZMACoder(name: "xz")
        c.cancel = cancel
        var mt = lzma_mt()
        mt.timeout = 250
        mt.threads = UInt32(max(1, threads))
        mt.preset = UInt32(max(0, min(9, preset)))
        mt.check = LZMA_CHECK_CRC64
        // liblzma's default block is 3× the dictionary (192 MiB at -9): too few blocks to keep the
        // cores busy. Measured on the 468 MB corpus (FASE2.md): -9 with 2× dictionary is both faster
        // and smaller than the default; -7/-8 favour speed with 1× dictionary.
        var opts = lzma_options_lzma()
        if mt.preset >= 7, lzma_lzma_preset(&opts, mt.preset) == 0 {
            mt.block_size = UInt64(opts.dict_size) * (mt.preset == 9 ? 2 : 1)
        }
        // At -9 each thread needs about 1 GB: fewer threads within a quarter of the RAM, as xz -T0 does.
        let budget = ProcessInfo.processInfo.physicalMemory / 4
        while mt.threads > 1 && lzma_stream_encoder_mt_memusage(&mt) > budget { mt.threads -= 1 }
        try c.check(lzma_stream_encoder_mt(&c.strm, &mt))
        return c
    }

    /// ZIP method 14: 4-byte version/size header, 5 property bytes, then raw LZMA1.
    /// `knownSize` is the entry's uncompressed size (the EOS marker is optional).
    static func zipLZMADecoder(header: UnsafeRawBufferPointer, knownSize: Int64) throws -> LZMACoder {
        guard header.count >= 9, header[2] == 5, header[3] == 0 else { throw XipperError.corrupt("bad ZIP LZMA header") }
        let c = LZMACoder(name: "lzma")
        var filter = lzma_filter(id: lzmaFilterLZMA1EXT, options: nil)
        let props = UnsafeRawBufferPointer(rebasing: header[4..<9])
        try c.check(lzma_properties_decode(&filter, nil, props.baseAddress?.assumingMemoryBound(to: UInt8.self), 5))
        let opts = filter.options!.assumingMemoryBound(to: lzma_options_lzma.self)
        opts.pointee.ext_flags = lzmaLZMA1EXTAllowEOPM
        c.expectedOutput = knownSize
        opts.pointee.ext_size_low = UInt32(truncatingIfNeeded: knownSize)
        opts.pointee.ext_size_high = UInt32(truncatingIfNeeded: knownSize >> 32)
        var filters = [filter, lzma_filter(id: lzmaVLIUnknown, options: nil)]
        let r = lzma_raw_decoder(&c.strm, &filters)
        free(filter.options)
        try c.check(r)
        return c
    }

    /// ZIP method 14 encoder for entries too big for one shot: raw LZMA1 with the end marker.
    /// Returns the coder and the 9-byte header that precedes its output.
    static func zipLZMAEncoder(preset: Int, size: Int64, cancel: CancellationToken?) throws -> (LZMACoder, [UInt8]) {
        let c = LZMACoder(name: "lzma")
        c.cancel = cancel
        var o = ZipLZMA.options(preset: preset, size: size)
        let head = ZipLZMA.header(&o)
        try withUnsafeMutablePointer(to: &o) { op in
            var filters = [lzma_filter(id: lzmaFilterLZMA1, options: op), lzma_filter(id: lzmaVLIUnknown, options: nil)]
            try c.check(lzma_raw_encoder(&c.strm, &filters))
        }
        return (c, head)
    }

    /// 7z LZMA (030101): 5 property bytes, raw LZMA1, end marker optional.
    /// The dictionary is capped to the output size: no match can reach further back.
    static func sevenZipLZMADecoder(props: [UInt8], unpackSize: Int64) throws -> LZMACoder {
        guard props.count == 5 else { throw XipperError.corrupt("bad 7z LZMA properties") }
        let c = LZMACoder(name: "lzma")
        var filter = lzma_filter(id: lzmaFilterLZMA1EXT, options: nil)
        try c.check(lzma_properties_decode(&filter, nil, props, 5))
        let opts = filter.options!.assumingMemoryBound(to: lzma_options_lzma.self)
        opts.pointee.dict_size = UInt32(max(4096, min(Int64(opts.pointee.dict_size), unpackSize)))
        opts.pointee.ext_flags = lzmaLZMA1EXTAllowEOPM
        c.expectedOutput = unpackSize
        opts.pointee.ext_size_low = UInt32(truncatingIfNeeded: unpackSize)
        opts.pointee.ext_size_high = UInt32(truncatingIfNeeded: unpackSize >> 32)
        var filters = [filter, lzma_filter(id: lzmaVLIUnknown, options: nil)]
        let r = lzma_raw_decoder(&c.strm, &filters)
        free(filter.options)
        try c.check(r)
        return c
    }

    /// 7z LZMA2 (21): one property byte (dictionary size).
    static func sevenZipLZMA2Decoder(prop: UInt8, unpackSize: Int64) throws -> LZMACoder {
        if prop > 40 { throw XipperError.corrupt("bad 7z LZMA2 properties") }
        let c = LZMACoder(name: "lzma2")
        var opts = lzma_options_lzma()
        let declared = Int64(SZLZMA2.dictionarySize(prop))
        opts.dict_size = UInt32(max(4096, min(declared, unpackSize, Int64(UInt32.max))))
        try withUnsafeMutablePointer(to: &opts) { o in
            var filters = [lzma_filter(id: lzmaFilterLZMA2, options: o), lzma_filter(id: lzmaVLIUnknown, options: nil)]
            try c.check(lzma_raw_decoder(&c.strm, &filters))
        }
        return c
    }

    private func check(_ r: lzma_ret) throws {
        switch r {
        case LZMA_OK, LZMA_STREAM_END: return
        case LZMA_MEM_ERROR, LZMA_MEMLIMIT_ERROR: throw XipperError.limitExceeded("\(name): memory limit")
        case LZMA_FORMAT_ERROR, LZMA_DATA_ERROR, LZMA_BUF_ERROR: throw XipperError.corrupt("invalid \(name) data")
        case LZMA_OPTIONS_ERROR: throw XipperError.unsupported("\(name) options")
        default: throw XipperError.codec("\(name) error \(r.rawValue)")
        }
    }

    private func run(_ input: UnsafeRawBufferPointer, action: lzma_action, _ sink: ByteSink) throws {
        strm.next_in = input.baseAddress?.assumingMemoryBound(to: UInt8.self)
        strm.avail_in = input.count
        while true {
            try cancel?.check()
            idle?()
            strm.next_out = out.ptr.assumingMemoryBound(to: UInt8.self)
            strm.avail_out = outputChunk
            let r = lzma_code(&strm, action)
            let produced = outputChunk - strm.avail_out
            try out.emit(produced, sink)
            if r == LZMA_STREAM_END { ended = true; return }
            if let e = expectedOutput {
                expectedOutput = e - Int64(produced)
                if e - Int64(produced) <= 0 && (r == LZMA_OK || r == LZMA_BUF_ERROR || r == LZMA_DATA_ERROR) { ended = true; return }
            }
            if r == LZMA_BUF_ERROR && action == LZMA_FINISH { throw XipperError.corrupt("truncated \(name) stream") }
            if r != LZMA_OK && r != LZMA_BUF_ERROR { try check(r) }
            if strm.avail_in == 0 && strm.avail_out != 0 && action == LZMA_RUN { return }
        }
    }

    func process(_ input: UnsafeRawBufferPointer, _ sink: ByteSink) throws {
        if ended || input.isEmpty { return }
        try run(input, action: LZMA_RUN, sink)
    }

    func finish(_ sink: ByteSink) throws {
        if !ended { try run(UnsafeRawBufferPointer(start: nil, count: 0), action: LZMA_FINISH, sink) }
    }
}

// MARK: - zstd

final class ZstdDecoder: StreamTransform {
    private let d: OpaquePointer
    private let out = OutBuffer()
    private var frameOpen = false

    init() throws {
        guard let d = ZSTD_createDCtx() else { throw XipperError.codec("zstd init") }
        // 256 MiB window: covers `--long` archives up to windowLog 28 while bounding memory.
        ZSTD_DCtx_setParameter(d, ZSTD_d_windowLogMax, 28)
        self.d = d
    }
    deinit { ZSTD_freeDCtx(d) }

    func process(_ input: UnsafeRawBufferPointer, _ sink: ByteSink) throws {
        var inb = ZSTD_inBuffer(src: input.baseAddress, size: input.count, pos: 0)
        while true {
            var outb = ZSTD_outBuffer(dst: out.ptr, size: outputChunk, pos: 0)
            let r = ZSTD_decompressStream(d, &outb, &inb)
            if ZSTD_isError(r) != 0 { throw XipperError.corrupt("invalid zstd data: \(String(cString: ZSTD_getErrorName(r)))") }
            try out.emit(outb.pos, sink)
            if r == 0 {
                // Frame complete and flushed. Calling again without input would look like the start
                // of a new frame (non-zero hint), so stop here unless more input (another frame) follows.
                frameOpen = false
                if inb.pos == inb.size { return }
                continue
            }
            frameOpen = true
            if inb.pos == inb.size && outb.pos < outb.size { return }
        }
    }

    func finish(_ sink: ByteSink) throws {
        if frameOpen { throw XipperError.corrupt("truncated zstd stream") }
    }
}

final class ZstdEncoder: StreamTransform {
    private let c: OpaquePointer
    private let out = OutBuffer()
    private let cancel: CancellationToken?

    private var idle: (() -> Void)?
    func onIdle(_ f: (() -> Void)?) { idle = f }

    var backlog: Int64 {
        let p = ZSTD_getFrameProgression(c)
        return Int64(p.ingested) - Int64(min(p.consumed, p.ingested))
    }

    init(level: Int, threads: Int, longDistance: Bool = false, checksum: Bool = true, cancel: CancellationToken? = nil) throws {
        self.cancel = cancel
        guard let c = ZSTD_createCCtx() else { throw XipperError.codec("zstd init") }
        self.c = c
        ZSTD_CCtx_setParameter(c, ZSTD_c_compressionLevel, Int32(max(1, min(22, level))))
        ZSTD_CCtx_setParameter(c, ZSTD_c_checksumFlag, checksum ? 1 : 0)
        if threads > 1 { ZSTD_CCtx_setParameter(c, ZSTD_c_nbWorkers, Int32(threads)) }
        if longDistance {
            ZSTD_CCtx_setParameter(c, ZSTD_c_enableLongDistanceMatching, 1)
            ZSTD_CCtx_setParameter(c, ZSTD_c_windowLog, 27)
        }
    }
    deinit { ZSTD_freeCCtx(c) }

    private func run(_ input: UnsafeRawBufferPointer, _ mode: ZSTD_EndDirective, _ sink: ByteSink) throws {
        var inb = ZSTD_inBuffer(src: input.baseAddress, size: input.count, pos: 0)
        while true {
            try cancel?.check()
            idle?()
            var outb = ZSTD_outBuffer(dst: out.ptr, size: outputChunk, pos: 0)
            let remaining = ZSTD_compressStream2(c, &outb, &inb, mode)
            if ZSTD_isError(remaining) != 0 { throw XipperError.codec("zstd: \(String(cString: ZSTD_getErrorName(remaining)))") }
            try out.emit(outb.pos, sink)
            if mode == ZSTD_e_end ? remaining == 0 : inb.pos == inb.size { return }
        }
    }

    func process(_ input: UnsafeRawBufferPointer, _ sink: ByteSink) throws { try run(input, ZSTD_e_continue, sink) }
    func finish(_ sink: ByteSink) throws { try run(UnsafeRawBufferPointer(start: nil, count: 0), ZSTD_e_end, sink) }
}

// MARK: - Parallel chunked encoders (gzip à la pigz, bzip2 à la pbzip2)

/// Buffers input into fixed-size chunks and compresses a batch of chunks in parallel,
/// emitting results in order. Subclasses define the per-chunk codec and framing.
class ParallelChunkEncoder: StreamTransform {
    let chunkSize: Int
    let workload: Workload
    let cancel: CancellationToken?
    private let batchCapacity: Int
    private var buffer: UnsafeMutableRawPointer
    private var filled = 0
    private var startedOutput = false

    init(chunkSize: Int, workload: Workload, cancel: CancellationToken?, chunksPerWorker: Int = 2) {
        self.chunkSize = chunkSize
        self.workload = workload
        self.cancel = cancel
        batchCapacity = chunkSize * max(1, workload.workerCount) * max(2, chunksPerWorker)
        buffer = .allocate(byteCount: batchCapacity, alignment: 16384)
    }
    deinit { buffer.deallocate() }

    // Subclass hooks
    func header() -> [UInt8] { [] }
    func compressChunk(_ chunk: UnsafeRawBufferPointer, previous: UnsafeRawBufferPointer?, last: Bool) throws -> [UInt8] { fatalError("abstract") }
    func chunkDone(_ chunk: UnsafeRawBufferPointer, crc: UInt32) {}
    /// Called in output order with the size of each chunk before and after compression.
    func chunkWritten(input: Int, output: Int) {}
    func trailer() -> [UInt8] { [] }
    var needsCRC: Bool { false }

    /// Tail of the previous batch's last chunk, used as dictionary for the next batch's first chunk.
    private var carry: [UInt8] = []

    func process(_ input: UnsafeRawBufferPointer, _ sink: ByteSink) throws {
        var rest = input
        while !rest.isEmpty {
            let n = min(rest.count, batchCapacity - filled)
            (buffer + filled).copyMemory(from: rest.baseAddress!, byteCount: n)
            filled += n
            rest = UnsafeRawBufferPointer(rebasing: rest[n...])
            // Keep the last (possibly partial) chunk back so `finish` can mark it final.
            if filled == batchCapacity { try flushBatch(keepLast: true, sink) }
        }
    }

    func finish(_ sink: ByteSink) throws {
        try flushBatch(keepLast: false, sink)
        try emit(trailer(), to: sink)
    }

    private func flushBatch(keepLast: Bool, _ sink: ByteSink) throws {
        if !startedOutput { startedOutput = true; try emit(header(), to: sink) }
        let total = keepLast ? filled - chunkSize : filled
        // Number of chunks to emit now; when finishing, always emit at least one (possibly empty) final chunk.
        let count = keepLast ? total / chunkSize : max(1, (total + chunkSize - 1) / chunkSize)
        let results = Slots<([UInt8], UInt32)>(count)
        let base = UnsafeRawPointer(buffer)
        let carrySnapshot = carry
        let crcNeeded = needsCRC
        try carrySnapshot.withUnsafeBytes { carryBytes in
            try parallelFor(count, workload: workload, cancel: cancel) { i in
                let start = i * self.chunkSize
                let len = min(self.chunkSize, total - start)
                let chunk = UnsafeRawBufferPointer(start: base + start, count: max(0, len))
                let prev: UnsafeRawBufferPointer? = i > 0
                    ? UnsafeRawBufferPointer(start: base + start - min(self.chunkSize, Deflate.windowSize), count: min(self.chunkSize, Deflate.windowSize))
                    : (carryBytes.isEmpty ? nil : carryBytes)
                let last = !keepLast && i == count - 1
                let out = try self.compressChunk(chunk, previous: prev, last: last)
                results[i] = (out, crcNeeded ? CRC32.checksum(chunk) : 0)
            }
        }
        for i in 0..<count {
            let (out, crc) = results.take(i)!
            let start = i * chunkSize
            let inputCount = max(0, min(chunkSize, total - start))
            chunkDone(UnsafeRawBufferPointer(start: base + start, count: inputCount), crc: crc)
            chunkWritten(input: inputCount, output: out.count)
            try emit(out, to: sink)
        }
        let consumed = count * chunkSize
        if keepLast {
            let tail = min(Deflate.windowSize, consumed)
            carry = Array(UnsafeRawBufferPointer(start: base + consumed - tail, count: tail))
            let left = filled - consumed
            buffer.copyMemory(from: base + consumed, byteCount: left)
            filled = left
        } else {
            filled = 0
        }
    }
}

final class ParallelGzipEncoder: ParallelChunkEncoder {
    private let level: Int
    private var crc: UInt32 = 0
    private var size: UInt64 = 0

    init(level: Int, workload: Workload, cancel: CancellationToken?) {
        self.level = level
        super.init(chunkSize: Deflate.chunkSize, workload: workload, cancel: cancel)
    }

    override var needsCRC: Bool { true }
    // ID1 ID2 CM=deflate FLG=0 MTIME=0 XFL=0 OS=3 (Unix)
    override func header() -> [UInt8] { [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3] }

    override func compressChunk(_ chunk: UnsafeRawBufferPointer, previous: UnsafeRawBufferPointer?, last: Bool) throws -> [UInt8] {
        try Deflate.compressChunk(chunk, dict: previous, level: level, last: last)
    }

    override func chunkDone(_ chunk: UnsafeRawBufferPointer, crc c: UInt32) {
        crc = size == 0 ? c : CRC32.combine(crc, c, lengthB: Int64(chunk.count))
        size += UInt64(chunk.count)
    }

    override func trailer() -> [UInt8] {
        var w = ByteWriter()
        w.u32(crc)
        w.u32(UInt32(truncatingIfNeeded: size))
        return w.bytes
    }
}

final class ParallelBzip2Encoder: ParallelChunkEncoder {
    private let level: Int

    init(level: Int, workload: Workload, cancel: CancellationToken?) {
        self.level = max(1, min(9, level))
        // One independent bzip2 stream per block-sized chunk (decoders concatenate streams).
        super.init(chunkSize: self.level * 100_000, workload: workload, cancel: cancel)
    }

    override func compressChunk(_ chunk: UnsafeRawBufferPointer, previous: UnsafeRawBufferPointer?, last: Bool) throws -> [UInt8] {
        if chunk.isEmpty { return [] }
        let cap = chunk.count + chunk.count / 100 + 600
        let out = [UInt8](unsafeUninitializedCapacity: cap) { buf, n in
            n = xs_bzip2_compress(chunk.baseAddress?.assumingMemoryBound(to: UInt8.self), chunk.count, Int32(level), buf.baseAddress, cap)
        }
        if out.isEmpty { throw XipperError.codec("bzip2 compress failed") }
        return out
    }
}

func emit(_ b: [UInt8], to sink: ByteSink) throws {
    if !b.isEmpty { try b.withUnsafeBytes { try sink($0) } }
}
