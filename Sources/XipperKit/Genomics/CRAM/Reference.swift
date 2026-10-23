import CryptoKit
import Foundation
import Synchronization

/// Reference sequences from an uncompressed FASTA file, located through its `.fai` index (built
/// in memory with one pass when there is none). Sequences are upper-cased with everything but
/// letters dropped, which is the form CRAM compares against and hashes (`@SQ M5`, CRAMv3 §11).
final class ReferenceSet: @unchecked Sendable {
    struct Entry { var length: Int; var offset: Int64; var lineBases: Int; var lineWidth: Int }

    let url: URL
    private(set) var order: [String] = []
    private var entries: [String: Entry] = [:]
    private let cache = Mutex<[(String, [UInt8])]>([])
    private let reader: FileReader

    init(fasta url: URL) throws {
        self.url = url
        reader = try FileReader(path: url.path)
        let head = try reader.read(at: 0, count: Int(min(2, reader.size)))
        if head.count == 2 && head[0] == 0x1F && head[1] == 0x8B {
            throw XipperError.unsupported("compressed FASTA reference: decompress it first (or use the .fa file next to its .fai)")
        }
        let fai = URL(fileURLWithPath: url.path + ".fai")
        if let text = try? String(contentsOf: fai, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let f = line.split(separator: "\t")
                guard f.count >= 5, let len = Int(f[1]), let off = Int64(f[2]), let lb = Int(f[3]), let lw = Int(f[4]) else {
                    throw XipperError.corrupt("invalid FASTA index \(fai.lastPathComponent)")
                }
                order.append(String(f[0]))
                entries[String(f[0])] = Entry(length: len, offset: off, lineBases: lb, lineWidth: lw)
            }
        } else {
            try scan()
        }
    }

    /// Builds the index as `samtools faidx` would (uniform line lengths are assumed for reads).
    private func scan() throws {
        var name: String?
        var e = Entry(length: 0, offset: 0, lineBases: 0, lineWidth: 0)
        var pos: Int64 = 0
        var line: [UInt8] = []
        func endLine() {
            guard !line.isEmpty || name != nil else { return }
            if line.first == UInt8(ascii: ">") {
                if let n = name { order.append(n); entries[n] = e }
                let title = line.dropFirst().split(whereSeparator: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }).first ?? []
                name = String(decoding: title, as: UTF8.self)
                e = Entry(length: 0, offset: pos, lineBases: 0, lineWidth: 0)
            } else if name != nil {
                let bases = line.filter { $0 != 0x0D }.count
                if e.lineBases == 0 { e.lineBases = bases; e.lineWidth = line.count + 1 }
                e.length += bases
            }
        }
        let chunk = 4 << 20
        while pos < reader.size {
            let data = try reader.read(at: pos, count: Int(min(Int64(chunk), reader.size - pos)))
            var start = 0
            for (i, b) in data.enumerated() where b == 0x0A {
                line.append(contentsOf: data[start..<i])
                let lineEnd = pos + Int64(i) + 1
                let saved = pos
                pos = lineEnd
                endLine()
                pos = saved
                line.removeAll(keepingCapacity: true)
                start = i + 1
            }
            line.append(contentsOf: data[start...])
            pos += Int64(data.count)
        }
        endLine()
        if let n = name { order.append(n); entries[n] = e }
    }

    func contains(_ name: String) -> Bool { entries[name] != nil }
    func length(_ name: String) -> Int? { entries[name]?.length }

    /// The whole sequence, upper case (two most recent kept in memory).
    func sequence(_ name: String) throws -> [UInt8] {
        if let hit = cache.withLock({ $0.first { $0.0 == name }?.1 }) { return hit }
        guard let e = entries[name] else { throw XipperError.invalidArgument("reference sequence \(name) not in \(url.lastPathComponent)") }
        let lines = e.lineBases > 0 ? (e.length + e.lineBases - 1) / e.lineBases : 0
        let span = e.lineWidth > 0 ? Int64(max(0, lines - 1)) * Int64(e.lineWidth) + Int64(e.length - max(0, lines - 1) * e.lineBases) : 0
        let raw = try reader.read(at: e.offset, count: Int(min(span + 1, reader.size - e.offset)))
        var seq = [UInt8]()
        seq.reserveCapacity(e.length)
        for b in raw where (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == UInt8(ascii: "*") || b == UInt8(ascii: "-") {
            seq.append(b >= 97 ? b - 32 : b)
            if seq.count == e.length { break }
        }
        guard seq.count == e.length else { throw XipperError.corrupt("reference \(name): \(seq.count) bases, the index says \(e.length)") }
        cache.withLock { c in
            c.insert((name, seq), at: 0)
            if c.count > 2 { c.removeLast() }
        }
        return seq
    }

    static func md5Hex<C: Collection>(_ bases: C) -> String where C.Element == UInt8 {
        Insecure.MD5.hash(data: Array(bases)).map { String(format: "%02x", $0) }.joined()
    }
}
