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
            tensors = try pytorch(path)
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

    /// The tensor storages of a `torch.save` zip: stored entries under `…/data/`, found through the
    /// central directory with Xipper's strict ZIP reader (torch writes data descriptors, so the
    /// local headers carry no sizes). Their dtype is in the pickle, which is not read: float32 and
    /// bfloat16 are both tried.
    static func pytorch(_ path: String) throws -> [(Range<Int64>, [Float])]? {
        guard let zip = try? ZipArchive(path: path) else { return nil }
        var out: [(Range<Int64>, [Float])] = []
        for rec in zip.records where rec.method == 0 && rec.compressedSize > 0 && rec.entry.path.contains("/data/") {
            let start = try zip.dataOffset(rec)
            out.append((start..<(start + rec.compressedSize), [.float32, .bfloat16]))
        }
        return out.sorted { $0.0.lowerBound < $1.0.lowerBound }
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
