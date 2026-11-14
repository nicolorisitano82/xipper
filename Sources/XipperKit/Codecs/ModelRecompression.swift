import COpenZL
import Foundation

/// AI model weights in OpenZL frames (XIZ 1.11, §21): the tensors of `.safetensors` files and of
/// PyTorch checkpoints (`torch.save` zip: `.pt`, `.pth`, `.bin`, `.ckpt`) go into pieces of whole
/// values, each compressed with OpenZL's float graph (sign and exponent apart from the mantissa).
/// On real models: float32 9% and bfloat16 5% smaller than xz -9, at 450–900 MB/s. A piece where
/// that is not smaller than the usual codec is stored the usual way; everything else in the file
/// (headers, metadata) is too.
enum ModelRecompression {
    /// Kinds of `xs_ozl_float_compress`.
    enum Float: Int32, Sendable {
        case float32 = 1, bfloat16 = 2, float16 = 3
        var width: Int64 { self == .float32 ? 4 : 2 }
    }

    /// A piece of a model file: its bytes, and the float kinds worth trying (none: usual codec).
    struct Piece: Equatable, Sendable {
        var range: Range<Int64>
        var floats: [Float]
    }

    static let minimumSize: Int64 = 1 << 20
    static let pieceSize = TableRecompression.pieceSize
    static let extensions: Set<String> = ["safetensors", "pt", "pth", "bin", "ckpt"]

    static func isCandidate(name: String, path: String, size: Int64) -> Bool {
        (try? pieces(name: name, path: path, size: size)).map { $0.contains { !$0.floats.isEmpty } } ?? false
    }

    /// The file cut into pieces, tensors apart; nil when it is not a model this understands.
    static func pieces(name: String, path: String, size: Int64) throws -> [Piece]? {
        let ext = (name as NSString).pathExtension.lowercased()
        guard size >= minimumSize, extensions.contains(ext) else { return nil }
        let r = try FileReader(path: path)
        let tensors: [(Range<Int64>, [Float])]?
        if ext == "safetensors" {
            tensors = try safetensors(r, size: size)
        } else {
            tensors = try pytorch(r, size: size)
        }
        guard let tensors, !tensors.isEmpty else { return nil }
        return cut(tensors, size: size)
    }

    /// The tensor ranges in a safetensors file: u64 header length, JSON header, data.
    static func safetensors(_ r: FileReader, size: Int64) throws -> [(Range<Int64>, [Float])]? {
        let lengthBytes = try r.read(at: 0, count: 8)
        let n = lengthBytes.withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(as: Int64.self)) }
        guard n > 1, n <= 100 << 20, 8 + n <= size else { return nil }
        guard let header = try? JSONSerialization.jsonObject(with: Data(try r.read(at: 8, count: Int(n)))) as? [String: Any] else { return nil }
        let base = 8 + n
        var out: [(Range<Int64>, [Float])] = []
        for (name, value) in header where name != "__metadata__" {
            guard let t = value as? [String: Any], let dtype = t["dtype"] as? String,
                  let offsets = t["data_offsets"] as? [NSNumber], offsets.count == 2 else { return nil }
            let a = base + offsets[0].int64Value, b = base + offsets[1].int64Value
            guard a >= base, b >= a, b <= size else { return nil }
            let kind: Float? = switch dtype { case "F32": .float32; case "BF16": .bfloat16; case "F16": .float16; default: nil }
            if let kind, b > a { out.append((a..<b, [kind])) }
        }
        return out.sorted { $0.0.lowerBound < $1.0.lowerBound }
    }

    /// The tensor storages of a `torch.save` zip: stored entries under `…/data/`, read from the
    /// local headers in order (their dtype is in the pickle: float32 and bfloat16 are both tried).
    static func pytorch(_ r: FileReader, size: Int64) throws -> [(Range<Int64>, [Float])]? {
        var out: [(Range<Int64>, [Float])] = []
        var at: Int64 = 0
        var entries = 0
        while at + 30 <= size {
            let h = try r.read(at: at, count: 30)
            func u16(_ o: Int) -> Int64 { Int64(h[o]) | Int64(h[o + 1]) << 8 }
            func u32(_ o: Int) -> Int64 { u16(o) | u16(o + 2) << 16 }
            guard u32(0) == 0x0403_4B50 else { break }  // central directory reached
            let flags = u16(6), method = u16(8)
            var csize = u32(18)
            let nameLength = u16(26), extraLength = u16(28)
            guard flags & 8 == 0, at + 30 + nameLength + extraLength <= size else { return nil }
            let name = String(decoding: try r.read(at: at + 30, count: Int(nameLength)), as: UTF8.self)
            if csize == 0xFFFF_FFFF {
                // ZIP64: the sizes are in the extra field 0x0001 (uncompressed, then compressed).
                let extra = try r.read(at: at + 30 + nameLength, count: Int(extraLength))
                var i = 0
                csize = -1
                while i + 4 <= extra.count {
                    let id = Int(extra[i]) | Int(extra[i + 1]) << 8, len = Int(extra[i + 2]) | Int(extra[i + 3]) << 8
                    if id == 1, len >= 16, i + 4 + 16 <= extra.count {
                        csize = extra[(i + 12)..<(i + 20)].reversed().reduce(Int64(0)) { $0 << 8 | Int64($1) }
                    }
                    i += 4 + len
                }
                guard csize >= 0 else { return nil }
            }
            let data = at + 30 + nameLength + extraLength
            guard data + csize <= size else { return nil }
            if method == 0, csize > 0, name.contains("/data/") { out.append((data..<(data + csize), [.float32, .bfloat16])) }
            at = data + csize
            entries += 1
        }
        guard entries > 0, reachesCentralDirectory(at, r, size) else { return nil }
        return out
    }

    /// After the local entries: the central directory (a real zip, not something else ending in .bin).
    private static func reachesCentralDirectory(_ at: Int64, _ r: FileReader, _ size: Int64) -> Bool {
        guard at + 4 <= size, let b = try? r.read(at: at, count: 4) else { return false }
        return b == [0x50, 0x4B, 0x01, 0x02] || b == [0x50, 0x4B, 0x06, 0x06]
    }

    /// The whole file as pieces of at most `pieceSize`: tensors in pieces of whole values,
    /// the rest (headers, other dtypes, padding) in pieces for the usual codec.
    static func cut(_ tensors: [(Range<Int64>, [Float])], size: Int64) -> [Piece] {
        var out: [Piece] = []
        func plain(_ a: Int64, _ b: Int64) {
            var s = a
            while s < b { let e = min(b, s + Int64(pieceSize)); out.append(Piece(range: s..<e, floats: [])); s = e }
        }
        var at: Int64 = 0
        for (range, kinds) in tensors where range.lowerBound >= at {
            plain(at, range.lowerBound)
            let width = kinds.map(\.width).max() ?? 4
            let step = Int64(pieceSize) / width * width
            var s = range.lowerBound
            let whole = range.lowerBound + (range.upperBound - range.lowerBound) / width * width
            while s < whole { let e = min(whole, s + step); out.append(Piece(range: s..<e, floats: kinds)); s = e }
            at = whole
        }
        plain(at, size)
        // Small leftovers merge with their neighbours only when both are plain.
        var merged: [Piece] = []
        for p in out {
            if let last = merged.last, last.floats.isEmpty, p.floats.isEmpty, last.range.count + p.range.count <= pieceSize {
                merged[merged.count - 1].range = last.range.lowerBound..<p.range.upperBound
            } else {
                merged.append(p)
            }
        }
        return merged
    }

    /// The smallest OpenZL frame among the kinds tried, checked to decode back to `piece`; nil if none works.
    static func encode(_ piece: [UInt8], floats: [Float]) -> [UInt8]? {
        var best: [UInt8]?
        for kind in floats where Int64(piece.count) % kind.width == 0 {
            let cap = xs_ozl_bound(piece.count)
            var out = [UInt8](repeating: 0, count: cap)
            let n = piece.withUnsafeBytes { src in
                out.withUnsafeMutableBytes { dst in xs_ozl_float_compress(src.baseAddress, src.count, dst.baseAddress, cap, kind.rawValue) }
            }
            guard n > 0, n < (best?.count ?? Int.max) else { continue }
            out.removeSubrange(n...)
            guard let back = try? TableRecompression.decode(out, size: piece.count), back == piece else { continue }
            best = out
        }
        return best
    }
}
