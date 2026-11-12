import COpenZL
import Foundation

/// Delimited tables (CSV, TSV, BED…) compressed with OpenZL's CSV profile in XIZ 1.11 (§21):
/// columns are split and each gets its own transforms (numbers parsed, deltas, string
/// dictionaries), which on numeric tables makes them 10–30% smaller than xz -9 and decodes
/// 4–6 times faster. A table is stored in pieces of whole rows, one OpenZL frame per XIZ frame;
/// a piece where OpenZL is not smaller than the usual codec is stored the usual way.
enum TableRecompression {
    /// Smaller tables are not worth frames of their own.
    static let minimumSize: Int64 = 64 << 10
    /// Rows go into pieces of at most this size (one XIZ frame each, under Xiz.maxFrameData).
    static let pieceSize = 16 << 20
    static let extensions: [String: UInt8] = [
        "csv": 0, "tsv": UInt8(ascii: "\t"), "tab": UInt8(ascii: "\t"), "bed": UInt8(ascii: "\t"),
        "psv": UInt8(ascii: "|"),
    ]

    /// A table by name and content: a table extension, text without NUL bytes in its first
    /// 64 KiB, and a separator found on every line there (0 for csv: sniffed).
    static func separator(name: String, path: String, size: Int64) -> UInt8? {
        guard size >= minimumSize, let declared = extensions[(name as NSString).pathExtension.lowercased()],
              let r = try? FileReader(path: path), let head = try? r.read(at: 0, count: Int(min(size, 64 << 10))) else { return nil }
        return separator(in: head, declared: declared)
    }

    static func isCandidate(name: String, path: String, size: Int64) -> Bool {
        separator(name: name, path: path, size: size) != nil
    }

    /// The separator that appears the same number of times on every complete line of `head`.
    static func separator(in head: [UInt8], declared: UInt8) -> UInt8? {
        guard !head.contains(0) else { return nil }
        var lines = head.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).dropLast()
        lines = lines.prefix(200)
        guard lines.count >= 2 else { return nil }
        let candidates = declared != 0 ? [declared] : [UInt8(ascii: ","), UInt8(ascii: ";"), UInt8(ascii: "\t"), UInt8(ascii: "|")]
        var best: (UInt8, Int)?
        for c in candidates {
            // Quoted fields may hold separators: count outside quotes.
            let counts = lines.map { line -> Int in
                var n = 0, quoted = false
                for b in line {
                    if b == UInt8(ascii: "\"") { quoted.toggle() } else if b == c && !quoted { n += 1 }
                }
                return n
            }
            guard let first = counts.first, first > 0 else { continue }
            let same = counts.filter { $0 == first }.count
            if same * 10 >= counts.count * 9, first > (best?.1 ?? 0) { best = (c, first) }
        }
        return best?.0
    }

    /// Where the pieces of a table of `size` bytes end: after a newline, at most `pieceSize` apart.
    static func pieces(path: String, size: Int64) throws -> [Range<Int64>] {
        let r = try FileReader(path: path)
        var out: [Range<Int64>] = []
        var start: Int64 = 0
        while start < size {
            var end = min(size, start + Int64(pieceSize))
            if end < size {
                // Back to the last newline in the final MiB of the piece; none: cut where it is.
                let look = Int64(1 << 20)
                let tail = try r.read(at: end - look, count: Int(look))
                if let nl = tail.lastIndex(of: UInt8(ascii: "\n")) { end = end - look + Int64(nl) + 1 }
            }
            out.append(start..<end)
            start = end
        }
        return out
    }

    /// OpenZL's level for an archive level: the strongest for xz-like settings.
    static func level(for level: Int, lzma2: Bool) -> Int32 { lzma2 || level >= 10 ? 19 : 15 }

    /// The OpenZL frame of one piece, checked to decode back to it; nil when OpenZL cannot
    /// parse it as a table.
    static func encode(_ piece: [UInt8], separator: UInt8, header: Bool, level: Int32) -> [UInt8]? {
        let cap = xs_ozl_bound(piece.count)
        var out = [UInt8](repeating: 0, count: cap)
        let n = piece.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                xs_ozl_csv_compress(src.baseAddress, src.count, dst.baseAddress, cap, CChar(bitPattern: separator), header ? 1 : 0, level)
            }
        }
        guard n > 0 else { return nil }
        out.removeSubrange(n...)
        guard let back = try? decode(out, size: piece.count), back == piece else { return nil }
        return out
    }

    /// The piece back from an OpenZL frame: exactly `size` bytes or an error.
    static func decode(_ payload: [UInt8], size: Int) throws -> [UInt8] {
        guard size <= Xiz.maxFrameData else { throw XipperError.corrupt("XIZ table frame size") }
        let declared = payload.withUnsafeBytes { xs_ozl_decompressed_size($0.baseAddress, $0.count) }
        guard declared == size else { throw XipperError.corrupt("XIZ table frame size") }
        var out = [UInt8](repeating: 0, count: size)
        let n = payload.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in xs_ozl_decompress(dst.baseAddress, size, src.baseAddress, src.count) }
        }
        guard n == size else { throw XipperError.corrupt("XIZ table frame") }
        return out
    }
}
