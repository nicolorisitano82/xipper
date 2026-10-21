import CDeflate
import CXipShims
import Synchronization

/// Whole-buffer deflate via libdeflate (2.7× zlib at equal ratio, SPIKE_FASE0.md §2),
/// plus pigz-style chunked deflate via zlib for inputs too large for one buffer.
enum Deflate {
    /// Above this size an input is split into chunks compressed in parallel.
    static let chunkSize = 1 << 20
    /// Dictionary carried between chunks (deflate window).
    static let windowSize = 32 << 10

    /// libdeflate compressors are ~1 MB each: keep a small pool per level.
    /// Stored as bit patterns because raw pointers are not Sendable.
    private static let pool = Mutex<[Int32: [UInt]]>([:])

    private static func withCompressor<R>(level: Int32, _ body: (OpaquePointer) throws -> R) rethrows -> R {
        let cached = pool.withLock { $0[level]?.popLast() }
        let c = cached.flatMap { OpaquePointer(bitPattern: $0) } ?? libdeflate_alloc_compressor(level)!
        defer {
            let bits = UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(c)))
            pool.withLock { $0[level, default: []].append(bits) }
        }
        return try body(c)
    }

    /// Raw-deflates `src`. Returns nil if the output would not be smaller than the input.
    static func compress(_ src: UnsafeRawBufferPointer, level: Int) -> [UInt8]? {
        if src.isEmpty { return nil }
        let lvl = Int32(max(1, min(12, level)))
        return withCompressor(level: lvl) { c in
            let bound = libdeflate_deflate_compress_bound(c, src.count)
            var out = [UInt8](unsafeUninitializedCapacity: bound) { buf, initialized in
                initialized = libdeflate_deflate_compress(c, src.baseAddress, src.count, buf.baseAddress, bound)
            }
            if out.isEmpty || out.count >= src.count { return nil }
            out.shrinkToFitIfWasteful()
            return out
        }
    }

    /// Inflates a raw deflate stream whose decompressed size is known exactly.
    static func decompress(_ src: UnsafeRawBufferPointer, into dst: UnsafeMutableRawBufferPointer) throws {
        let d = libdeflate_alloc_decompressor()!
        defer { libdeflate_free_decompressor(d) }
        var actual = 0
        let r = libdeflate_deflate_decompress(d, src.baseAddress, src.count, dst.baseAddress, dst.count, &actual)
        switch r {
        case LIBDEFLATE_SUCCESS where actual == dst.count: return
        case LIBDEFLATE_SUCCESS, LIBDEFLATE_SHORT_OUTPUT: throw XipperError.corrupt("deflate size mismatch")
        case LIBDEFLATE_INSUFFICIENT_SPACE: throw XipperError.corrupt("deflate data larger than declared")
        default: throw XipperError.corrupt("invalid deflate data")
        }
    }

    /// Compresses one chunk of a larger stream (see `xs_deflate_chunk`).
    /// `dict` is the tail of the previous chunk; the output of consecutive chunks concatenates
    /// into one valid raw deflate stream terminated by the chunk with `last == true`.
    static func compressChunk(_ src: UnsafeRawBufferPointer, dict: UnsafeRawBufferPointer?,
                              level: Int, last: Bool) throws -> [UInt8] {
        let bound = xs_deflate_chunk_bound(src.count)
        let out = [UInt8](unsafeUninitializedCapacity: bound) { buf, initialized in
            initialized = xs_deflate_chunk(src.baseAddress?.assumingMemoryBound(to: UInt8.self), src.count,
                                           dict?.baseAddress?.assumingMemoryBound(to: UInt8.self), dict?.count ?? 0,
                                           Int32(max(1, min(9, level))), last ? 1 : 0,
                                           buf.baseAddress, bound)
        }
        if out.isEmpty && !(src.isEmpty && !last) { throw XipperError.codec("deflate chunk failed") }
        return out
    }
}

extension Array where Element == UInt8 {
    /// Releases capacity when an array is much larger than its contents (compressed buffers).
    mutating func shrinkToFitIfWasteful() {
        if capacity > count + count / 4 + 4096 { self = Array(self) }
    }
}
