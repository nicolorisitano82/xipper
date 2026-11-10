import CBrunsli
import Darwin
import Foundation
import Synchronization

/// Lossless JPEG recompression with brunsli (XIZ 1.6, docs/XIZ_SPEC.md §16): about 20% smaller,
/// and decoding gives back the original file byte for byte. brunsli aborts on its internal checks,
/// so encoding and decoding run in the `xipper-decoder` helper when there is one (a crafted JPEG or
/// payload then crashes the helper, not Xipper); in process only where the helper cannot start
/// (sandboxed extensions, builds without it).
enum JPEGRecompression {
    /// Files below this size are not worth a frame of their own.
    static let minimumSize: Int64 = 4096
    /// Smaller than this fraction of the original, or stored the usual way.
    static let worthIt = 0.97

    /// A JPEG by name and content: a JPEG extension and the SOI marker followed by another marker.
    static func isCandidate(name: String, path: String, size: Int64) -> Bool {
        guard size >= minimumSize, size <= Int64(Xiz.maxFrameData),
              ["jpg", "jpeg", "jpe", "jfif"].contains((name as NSString).pathExtension.lowercased()),
              let r = try? FileReader(path: path), let head = try? r.read(at: 0, count: 3) else { return false }
        return head == [0xFF, 0xD8, 0xFF]
    }

    // MARK: in process

    private final class Sink {
        var bytes: [UInt8] = []
        let limit: Int
        init(limit: Int) { self.limit = limit }
    }

    private static let collect: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Int = { ctx, buf, n in
        let s = Unmanaged<Sink>.fromOpaque(ctx!).takeUnretainedValue()
        guard s.bytes.count + n <= s.limit, let buf else { return 0 }  // anything else stops brunsli with an error
        s.bytes.append(contentsOf: UnsafeBufferPointer(start: buf, count: n))
        return n
    }

    /// The brunsli stream of `jpeg`, or nil when brunsli does not take it (unusual JPEG, not a JPEG).
    static func encodeInProcess(_ jpeg: UnsafeRawBufferPointer) -> [UInt8]? {
        let sink = Sink(limit: jpeg.count + (1 << 20))
        let ok = withExtendedLifetime(sink) {
            EncodeBrunsli(jpeg.count, jpeg.baseAddress?.assumingMemoryBound(to: UInt8.self), Unmanaged.passUnretained(sink).toOpaque(), collect)
        }
        return ok == 1 ? sink.bytes : nil
    }

    /// The JPEG back from a brunsli stream; exactly `size` bytes or an error.
    static func decodeInProcess(_ payload: UnsafeRawBufferPointer, size: Int) throws -> [UInt8] {
        let sink = Sink(limit: size)
        sink.bytes.reserveCapacity(size)
        let ok = withExtendedLifetime(sink) {
            DecodeBrunsli(payload.count, payload.baseAddress?.assumingMemoryBound(to: UInt8.self), Unmanaged.passUnretained(sink).toOpaque(), collect)
        }
        guard ok == 1, sink.bytes.count == size else { throw XipperError.corrupt("damaged JPEG recompression data") }
        return sink.bytes
    }

    // MARK: through the helper

    /// Recompressed and checked: the stream is decoded again and compared with `jpeg` here, so a
    /// helper that lies or a brunsli bug never reaches the archive. Nil: store the JPEG as usual.
    static func encode(_ jpeg: [UInt8]) -> [UInt8]? {
        let packed: [UInt8]?
        if let pool = JPEGCoderPool.shared {
            packed = try? pool.run(.jpegEncode, jpeg)
        } else {
            packed = jpeg.withUnsafeBytes { encodeInProcess($0) }
        }
        guard let packed, Double(packed.count) < Double(jpeg.count) * worthIt,
              (try? decode(packed, size: jpeg.count)) == jpeg else { return nil }
        return packed
    }

    static func decode(_ payload: [UInt8], size: Int) throws -> [UInt8] {
        guard let pool = JPEGCoderPool.shared else { return try payload.withUnsafeBytes { try decodeInProcess($0, size: size) } }
        var w = IsolatedDecoder.Writer()
        w.u32(UInt32(size))
        w.bytes += payload
        let out = try pool.run(.jpegDecode, w.bytes)
        guard let out, out.count == size else { throw XipperError.corrupt("damaged JPEG recompression data") }
        return out
    }
}

/// Helpers in recompression mode (brunsli for JPEG, preflate for Deflate streams), shared by the
/// whole process: one per file coded at the same time, reused.
final class JPEGCoderPool: @unchecked Sendable {
    static let shared: JPEGCoderPool? = IsolatedDecoder.helperPath.map(JPEGCoderPool.init)
    private let helper: String
    private let idle = Mutex<[DecoderProcess]>([])
    /// Requests and results: at most a frame with room for the brunsli overhead, or a preflate split form.
    static let maxPayload = max(Xiz.maxFrameData + (2 << 20), DeflateRecompression.maxSplit + 16)
    static let chunk = 1 << 20

    init(helper: String) { self.helper = helper }

    /// The helper's answer: the bytes, or nil when it does not take the JPEG (encoding only).
    func run(_ op: IsolatedDecoder.Op, _ payload: [UInt8]) throws -> [UInt8]? {
        let p = try idle.withLock { $0.popLast() } ?? spawn()
        try p.send(op, payload)
        var out: [UInt8] = []
        while true {
            let (type, n) = try p.header()
            switch type {
            case IsolatedDecoder.Reply.chunk.rawValue:
                guard n <= Self.chunk, out.count + n <= Self.maxPayload else { throw XipperError.corrupt("decoder helper: malformed reply") }
                let start = out.count
                out.append(contentsOf: repeatElement(0, count: n))
                try out.withUnsafeMutableBytes { try p.read(into: $0.baseAddress! + start, n) }
            case IsolatedDecoder.Reply.dataEnd.rawValue:
                idle.withLock { $0.append(p) }
                return out
            case IsolatedDecoder.Reply.end.rawValue:
                idle.withLock { $0.append(p) }
                return nil
            case IsolatedDecoder.Reply.error.rawValue:
                let e = try IsolatedDecoder.decodeError(try p.payload(n))
                idle.withLock { $0.append(p) }
                throw e
            default:
                throw XipperError.corrupt("decoder helper: unexpected reply")
            }
        }
    }

    private func spawn() throws -> DecoderProcess {
        let p = try DecoderProcess(helper: helper, volumes: [], name: "JPEG")
        try p.send(.jpeg)
        let (type, _) = try p.receive()
        guard type == IsolatedDecoder.Reply.opened.rawValue else { throw XipperError.corrupt("decoder helper: unexpected reply") }
        return p
    }

    // MARK: helper side

    /// The recompression loop of `xipper-decoder`: one JPEG or one Deflate document per request.
    static func serve(input: Int32, output: Int32) -> Int32 {
        guard IsolatedDecoder.frame(output, IsolatedDecoder.Reply.opened.rawValue) else { return 1 }
        while let (op, n) = IsolatedDecoder.readHeader(input) {
            guard n <= maxPayload + 4 else { return 2 }
            var b = [UInt8](repeating: 0, count: n)
            guard n == 0 || b.withUnsafeMutableBytes({ IsolatedDecoder.readAll(input, $0.baseAddress!, n) }) else { return 2 }
            let result: [UInt8]?
            do {
                switch IsolatedDecoder.Op(rawValue: op) {
                case .jpegEncode?:
                    result = b.withUnsafeBytes { JPEGRecompression.encodeInProcess($0) }
                case .jpegDecode?:
                    guard b.count >= 4 else { throw XipperError.corrupt("decoder helper: malformed request") }
                    let size = Int(UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
                    guard size <= Xiz.maxFrameData else { throw XipperError.corrupt("decoder helper: malformed request") }
                    result = try b.withUnsafeBytes { try JPEGRecompression.decodeInProcess(UnsafeRawBufferPointer(rebasing: $0[4...]), size: size) }
                case .deflateSplit?:
                    guard let k = b.first.flatMap(DeflateRecompression.kind(code:)) else { throw XipperError.corrupt("decoder helper: malformed request") }
                    result = DeflateRecompression.splitInProcess(Array(b[1...]), kind: k)
                case .deflateRebuild?:
                    guard b.count >= 4 else { throw XipperError.corrupt("decoder helper: malformed request") }
                    let size = Int(UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
                    guard size <= Xiz.maxFrameData else { throw XipperError.corrupt("decoder helper: malformed request") }
                    result = try DeflateRecompression.rebuild(Array(b[4...]), size: size)
                case .crash?:
                    abort()
                default:
                    return 2
                }
            } catch {
                guard IsolatedDecoder.frame(output, IsolatedDecoder.Reply.error.rawValue, IsolatedDecoder.encode(error)) else { return 1 }
                continue
            }
            guard let result else {
                guard IsolatedDecoder.frame(output, IsolatedDecoder.Reply.end.rawValue) else { return 1 }
                continue
            }
            var off = 0
            while off < result.count {
                let k = min(chunk, result.count - off)
                guard result.withUnsafeBytes({ IsolatedDecoder.frame(output, IsolatedDecoder.Reply.chunk.rawValue, UnsafeRawBufferPointer(rebasing: $0[off..<(off + k)])) }) else { return 1 }
                off += k
            }
            guard IsolatedDecoder.frame(output, IsolatedDecoder.Reply.dataEnd.rawValue) else { return 1 }
        }
        return 0
    }
}
