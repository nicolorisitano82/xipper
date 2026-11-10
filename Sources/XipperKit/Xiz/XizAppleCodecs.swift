import Compression
import Foundation

// XIZ 1.8 (docs/XIZ_SPEC.md §18): frames compressed with Apple's LZRAVEN (ratio of LZMA2, decoding
// about 3× faster) or LZMESH (ratio of zstd 9 at the speed of zstd 3). Both exist only in the
// Compression framework of macOS 27 and later, buffer API only.

extension Xiz {
    /// Whether this Mac has the codecs (macOS 27 or later).
    static var hasAppleCodecs: Bool {
        if #available(macOS 27, *) { true } else { false }
    }

    @available(macOS 27, *)
    private static func algorithm(_ codec: Codec) -> compression_algorithm {
        codec == .lzraven ? COMPRESSION_LZRAVEN : COMPRESSION_LZMESH
    }

    /// The payload of a frame; nil when it would not be smaller than the data (or the codec is missing).
    static func appleCompress(_ src: UnsafeRawBufferPointer, codec: Codec) -> [UInt8]? {
        guard #available(macOS 27, *), src.count > 1 else { return nil }
        let out = [UInt8](unsafeUninitializedCapacity: src.count - 1) { buf, n in
            n = compression_encode_buffer(buf.baseAddress!, buf.count, src.baseAddress!.assumingMemoryBound(to: UInt8.self), src.count,
                                          nil, algorithm(codec))
        }
        return out.isEmpty ? nil : out
    }

    /// Decodes exactly `size` bytes: the buffer has room for one more, so a stream that decodes
    /// to more than declared is caught.
    static func appleDecompress(_ src: UnsafeRawBufferPointer, size: Int, codec: Codec) throws -> [UInt8] {
        guard #available(macOS 27, *) else {
            throw XipperError.unsupported("XIZ frames compressed with \(codec == .lzraven ? "LZRAVEN" : "LZMESH") need macOS 27 or later")
        }
        guard src.count > 0 else { throw XipperError.corrupt("XIZ \(codec) frame empty") }
        var out = [UInt8](unsafeUninitializedCapacity: size + 1) { buf, n in
            n = compression_decode_buffer(buf.baseAddress!, buf.count, src.baseAddress!.assumingMemoryBound(to: UInt8.self), src.count,
                                          nil, algorithm(codec))
        }
        guard out.count == size else { throw XipperError.corrupt("XIZ frame decodes to \(out.count) bytes, \(size) declared") }
        out.reserveCapacity(size)
        return out
    }
}
