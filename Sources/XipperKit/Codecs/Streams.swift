import CLZMA
import CXipShims
import CZstd
import Foundation

// liblzma constants defined through UINT32_C/LZMA_VLI_C macros, which Swift does not import.
private let lzmaConcatenated: UInt32 = 0x08
private let lzmaFilterLZMA1EXT: lzma_vli = 0x4000_0000_0000_0002
private let lzmaLZMA1EXTAllowEOPM: UInt32 = 0x01
private let lzmaVLIUnknown: lzma_vli = .max

typealias ByteSink = (UnsafeRawBufferPointer) throws -> Void

/// A push-style codec: feed input with `process`, end with `finish`.
/// Output is delivered to the sink in pieces of at most `outputChunk` bytes.
protocol StreamTransform: AnyObject {
    func process(_ input: UnsafeRawBufferPointer, _ sink: ByteSink) throws
    func finish(_ sink: ByteSink) throws
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

// MARK: - liblzma (xz, ZIP LZMA)

final class LZMACoder: StreamTransform {
    private var strm = lzma_stream()
    private let out = OutBuffer()
    private var ended = false
    private let name: String

    private init(name: String) { self.name = name }
    deinit { lzma_end(&strm) }

    /// .xz decoder, multi-threaded for multi-block streams, accepting concatenated streams.
    static func xzDecoder(threads: Int) throws -> LZMACoder {
        let c = LZMACoder(name: "xz")
        var mt = lzma_mt()
        mt.threads = UInt32(max(1, threads))
        mt.flags = lzmaConcatenated
        mt.memlimit_threading = UInt64(min(ProcessInfo.processInfo.physicalMemory / 4, 4 << 30))
        mt.memlimit_stop = UInt64.max
        try c.check(lzma_stream_decoder_mt(&c.strm, &mt))
        return c
    }

    /// .xz encoder; `threads > 1` splits the input into independently compressed blocks.
    static func xzEncoder(preset: Int, threads: Int) throws -> LZMACoder {
        let c = LZMACoder(name: "xz")
        var mt = lzma_mt()
        mt.threads = UInt32(max(1, threads))
        mt.preset = UInt32(max(0, min(9, preset)))
        mt.check = LZMA_CHECK_CRC64
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
        opts.pointee.ext_size_low = UInt32(truncatingIfNeeded: knownSize)
        opts.pointee.ext_size_high = UInt32(truncatingIfNeeded: knownSize >> 32)
        var filters = [filter, lzma_filter(id: lzmaVLIUnknown, options: nil)]
        let r = lzma_raw_decoder(&c.strm, &filters)
        free(filter.options)
        try c.check(r)
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
            strm.next_out = out.ptr.assumingMemoryBound(to: UInt8.self)
            strm.avail_out = outputChunk
            let r = lzma_code(&strm, action)
            try out.emit(outputChunk - strm.avail_out, sink)
            if r == LZMA_STREAM_END { ended = true; return }
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

    init(level: Int, threads: Int, longDistance: Bool = false, checksum: Bool = true) throws {
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
