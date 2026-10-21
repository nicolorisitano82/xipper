import Foundation

/// 7z constants (DOC/7zFormat.txt and DOC/Methods.txt of 7-Zip).
enum SevenZip {
    static let signature: [UInt8] = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]
    static let signatureHeaderSize = 32
    static let versionMajor: UInt8 = 0
    static let versionMinor: UInt8 = 4

    /// Property IDs of the header.
    enum ID {
        static let end: UInt8 = 0x00
        static let header: UInt8 = 0x01
        static let archiveProperties: UInt8 = 0x02
        static let additionalStreamsInfo: UInt8 = 0x03
        static let mainStreamsInfo: UInt8 = 0x04
        static let filesInfo: UInt8 = 0x05
        static let packInfo: UInt8 = 0x06
        static let unpackInfo: UInt8 = 0x07
        static let subStreamsInfo: UInt8 = 0x08
        static let size: UInt8 = 0x09
        static let crc: UInt8 = 0x0A
        static let folder: UInt8 = 0x0B
        static let codersUnpackSize: UInt8 = 0x0C
        static let numUnpackStream: UInt8 = 0x0D
        static let emptyStream: UInt8 = 0x0E
        static let emptyFile: UInt8 = 0x0F
        static let anti: UInt8 = 0x10
        static let name: UInt8 = 0x11
        static let cTime: UInt8 = 0x12
        static let aTime: UInt8 = 0x13
        static let mTime: UInt8 = 0x14
        static let winAttributes: UInt8 = 0x15
        static let comment: UInt8 = 0x16
        static let encodedHeader: UInt8 = 0x17
        static let startPos: UInt8 = 0x18
        static let dummy: UInt8 = 0x19
    }

    /// Codec IDs (big-endian bytes read as one number).
    enum Method {
        static let copy: UInt64 = 0x00
        static let delta: UInt64 = 0x03
        static let arm64: UInt64 = 0x0A
        static let riscv: UInt64 = 0x0B
        static let lzma2: UInt64 = 0x21
        static let lzma: UInt64 = 0x03_0101
        static let ppmd: UInt64 = 0x03_0401
        static let bcj: UInt64 = 0x0303_0103
        static let bcj2: UInt64 = 0x0303_011B
        static let ppc: UInt64 = 0x0303_0205
        static let ia64: UInt64 = 0x0303_0401
        static let arm: UInt64 = 0x0303_0501
        static let armThumb: UInt64 = 0x0303_0701
        static let sparc: UInt64 = 0x0303_0805
        static let deflate: UInt64 = 0x04_0108
        static let deflate64: UInt64 = 0x04_0109
        static let bzip2: UInt64 = 0x04_0202
        /// zstd as written by 7-Zip ZS and NanaZip.
        static let zstd: UInt64 = 0x04F7_1101
        static let aes: UInt64 = 0x06F1_0701

        static func name(_ m: UInt64) -> String {
            switch m {
            case copy: return "Copy"
            case delta: return "Delta"
            case arm64: return "ARM64"
            case riscv: return "RISCV"
            case lzma2: return "LZMA2"
            case lzma: return "LZMA"
            case ppmd: return "PPMD"
            case bcj: return "BCJ"
            case bcj2: return "BCJ2"
            case ppc: return "PPC"
            case ia64: return "IA64"
            case arm: return "ARM"
            case armThumb: return "ARMT"
            case sparc: return "SPARC"
            case deflate: return "Deflate"
            case deflate64: return "Deflate64"
            case bzip2: return "BZip2"
            case zstd: return "ZSTD"
            case aes: return "7zAES"
            default: return String(format: "method %llX", m)
            }
        }
    }

    /// Windows attributes; the high 16 bits carry the Unix mode when `unixExtension` is set (p7zip convention).
    enum Attribute {
        static let readOnly: UInt32 = 0x01
        static let directory: UInt32 = 0x10
        static let archive: UInt32 = 0x20
        static let unixExtension: UInt32 = 0x8000
    }

    /// FILETIME (100 ns ticks since 1601-01-01 UTC).
    static func date(fileTime t: UInt64) -> Date {
        Date(timeIntervalSince1970: Double(t) / 1e7 - 11_644_473_600)
    }

    static func fileTime(_ d: Date) -> UInt64 {
        UInt64(max(0, (d.timeIntervalSince1970 + 11_644_473_600) * 1e7))
    }
}

// MARK: - Structures

struct SZCoder: Sendable, Equatable {
    var method: UInt64
    var numInStreams = 1
    var numOutStreams = 1
    var props: [UInt8] = []
}

/// A folder: a graph of coders whose packed streams decode to one unpacked stream
/// holding the data of one or more files (several = solid).
///
/// Stream numbering (7zFormat.txt): "in" streams are the packed side of each coder,
/// "out" streams the unpacked side, both counted across the coders in order.
struct SZFolder: Sendable {
    var coders: [SZCoder] = []
    /// (in stream, out stream feeding it)
    var bindPairs: [(inIndex: Int, outIndex: Int)] = []
    /// In streams read from the archive's packed streams, in pack-stream order.
    var packedStreams: [Int] = []
    /// One size per out stream.
    var unpackSizes: [Int64] = []
    var crc: UInt32?
    /// Index of the folder's first packed stream in the archive.
    var firstPackStream = 0

    var numInStreams: Int { coders.reduce(0) { $0 + $1.numInStreams } }
    var numOutStreams: Int { coders.reduce(0) { $0 + $1.numOutStreams } }

    /// The out stream not bound to any coder input: the folder's content.
    var mainOutStream: Int {
        (0..<numOutStreams).first { o in !bindPairs.contains { $0.outIndex == o } } ?? 0
    }

    var unpackSize: Int64 { unpackSizes.isEmpty ? 0 : unpackSizes[mainOutStream] }

    var isEncrypted: Bool { coders.contains { $0.method == SevenZip.Method.aes } }

    /// (coder, first in stream, first out stream) for each coder.
    func streamBases() -> [(inBase: Int, outBase: Int)] {
        var i = 0, o = 0
        return coders.map { c in
            defer { i += c.numInStreams; o += c.numOutStreams }
            return (i, o)
        }
    }

    /// Coder owning out stream `out`.
    func coder(forOutStream out: Int) -> Int? {
        var o = 0
        for (i, c) in coders.enumerated() {
            if out < o + c.numOutStreams { return i }
            o += c.numOutStreams
        }
        return nil
    }

    /// "LZMA2:24 ARM64 7zAES", from the content side to the packed side, like `7zz l -slt`.
    var methodDescription: String {
        var parts: [String] = []
        var visited = Set<Int>()
        func walk(_ out: Int) {
            guard let ci = coder(forOutStream: out), visited.insert(ci).inserted else { return }
            let c = coders[ci]
            var s = SevenZip.Method.name(c.method)
            if c.method == SevenZip.Method.lzma2, c.props.count == 1 {
                s += ":\(SZLZMA2.dictionaryBits(c.props[0]))"
            } else if c.method == SevenZip.Method.lzma, c.props.count == 5 {
                let d = UInt32(c.props[1]) | UInt32(c.props[2]) << 8 | UInt32(c.props[3]) << 16 | UInt32(c.props[4]) << 24
                s += d != 0 && d & (d - 1) == 0 ? ":\(d.trailingZeroBitCount)" : ":\(d >> 10)k"
            } else if c.method == SevenZip.Method.ppmd, c.props.count == 5 {
                s += ":o\(c.props[0])"
            }
            parts.append(s)
            let base = streamBases()[ci].inBase
            for k in 0..<c.numInStreams {
                if let bp = bindPairs.first(where: { $0.inIndex == base + k }) { walk(bp.outIndex) }
            }
        }
        walk(mainOutStream)
        return parts.joined(separator: " ")
    }
}

enum SZLZMA2 {
    /// Dictionary size encoded in the LZMA2 property byte.
    static func dictionarySize(_ prop: UInt8) -> UInt64 {
        if prop >= 40 { return 0xFFFF_FFFF }
        return UInt64(2 | (UInt32(prop) & 1)) << (UInt32(prop) / 2 + 11)
    }

    static func dictionaryBits(_ prop: UInt8) -> Int { Int(prop) / 2 + 12 }

    /// Smallest property byte whose dictionary is at least `size`.
    static func prop(forDictionary size: UInt32) -> UInt8 {
        for p: UInt8 in 0..<40 where dictionarySize(p) >= size { return p }
        return 40
    }
}

struct SZStreamsInfo: Sendable {
    var packPos: Int64 = 0
    var packSizes: [Int64] = []
    var folders: [SZFolder] = []
    /// Number of unpacked streams (files) per folder.
    var numUnpackStreams: [Int] = []
    /// Sizes and CRCs of every unpacked stream, folder by folder.
    var subSizes: [Int64] = []
    var subCRCs: [UInt32?] = []
}

/// One file record of the header.
struct SZFile: Sendable {
    var name = ""
    var hasStream = true
    var isDirectory = false
    var isAnti = false
    var mtime: Date?
    var attributes: UInt32?
}

struct SZHeader: Sendable {
    var streams = SZStreamsInfo()
    var files: [SZFile] = []
}

// MARK: - Number encoding

extension ByteReader {
    /// 7z variable-length number: the count of leading 1 bits in the first byte gives the
    /// number of extra little-endian bytes; the rest of the first byte is the high part.
    mutating func number() throws -> UInt64 {
        let first = try u8()
        var mask: UInt8 = 0x80
        var value: UInt64 = 0
        for i in 0..<8 {
            if first & mask == 0 {
                let high = UInt64(first & (mask &- 1))
                return value | high << (8 * UInt64(i))
            }
            value |= UInt64(try u8()) << (8 * UInt64(i))
            mask >>= 1
        }
        return value
    }

    /// A number used as a count or index, bounded to keep hostile headers from allocating wildly.
    mutating func count(max limit: Int) throws -> Int {
        let v = try number()
        if v > UInt64(limit) { throw XipperError.corrupt("7z header value out of range (\(v))") }
        return Int(v)
    }

    mutating func size() throws -> Int64 {
        let v = try number()
        if v > UInt64(Int64.max / 2) { throw XipperError.corrupt("7z size out of range") }
        return Int64(v)
    }

    mutating func bits(_ n: Int) throws -> [Bool] {
        var out = [Bool](repeating: false, count: n)
        var byte: UInt8 = 0
        for i in 0..<n {
            if i % 8 == 0 { byte = try u8() }
            out[i] = byte & (0x80 >> UInt8(i % 8)) != 0
        }
        return out
    }

    /// "AllAreDefined" byte followed by a bit vector when not all are defined.
    mutating func definedBits(_ n: Int) throws -> [Bool] {
        try u8() != 0 ? [Bool](repeating: true, count: n) : bits(n)
    }
}

extension ByteWriter {
    mutating func number(_ v: UInt64) {
        var n = 0
        while n < 8 && v >= (UInt64(1) << (7 * UInt64(n + 1))) { n += 1 }
        if n == 8 {
            u8(0xFF); u64(v); return
        }
        let first = UInt8(truncatingIfNeeded: (0xFF00 >> n) & 0xFF) | UInt8(truncatingIfNeeded: v >> (8 * UInt64(n)))
        u8(first)
        for i in 0..<n { u8(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) }
    }

    mutating func number(_ v: Int) { number(UInt64(v)) }
    mutating func number(_ v: Int64) { number(UInt64(v)) }

    mutating func bits(_ b: [Bool]) {
        var byte: UInt8 = 0
        for (i, v) in b.enumerated() {
            if v { byte |= 0x80 >> UInt8(i % 8) }
            if i % 8 == 7 { u8(byte); byte = 0 }
        }
        if b.count % 8 != 0 { u8(byte) }
    }
}

// MARK: - Parsing

enum SZHeaderParser {
    /// Hard caps for hostile headers (7-Zip itself has similar ones).
    static let maxItems = 1 << 24
    static let maxCoders = 64

    /// `kHeader` content (after the ID byte).
    static func parseHeader(_ r: inout ByteReader) throws -> SZHeader {
        var h = SZHeader()
        var id = try r.u8()
        if id == SevenZip.ID.archiveProperties {
            while try r.u8() != 0 { try r.skip(try r.count(max: r.remaining)) }
            id = try r.u8()
        }
        if id == SevenZip.ID.additionalStreamsInfo {
            _ = try parseStreamsInfo(&r)  // unused by any current writer
            id = try r.u8()
        }
        if id == SevenZip.ID.mainStreamsInfo {
            h.streams = try parseStreamsInfo(&r)
            id = try r.u8()
        }
        if id == SevenZip.ID.filesInfo {
            h.files = try parseFilesInfo(&r)
            id = try r.u8()
        }
        if id != SevenZip.ID.end { throw XipperError.corrupt("unexpected 7z header property \(id)") }
        return h
    }

    static func parseStreamsInfo(_ r: inout ByteReader) throws -> SZStreamsInfo {
        var s = SZStreamsInfo()
        var id = try r.u8()
        if id == SevenZip.ID.packInfo {
            s.packPos = try r.size()
            let n = try r.count(max: maxItems)
            id = try r.u8()
            if id == SevenZip.ID.size {
                s.packSizes = try (0..<n).map { _ in try r.size() }
                id = try r.u8()
            } else {
                s.packSizes = [Int64](repeating: 0, count: n)
            }
            if id == SevenZip.ID.crc {
                _ = try digests(&r, n)
                id = try r.u8()
            }
            if id != SevenZip.ID.end { throw XipperError.corrupt("bad 7z pack info") }
            id = try r.u8()
        }
        if id == SevenZip.ID.unpackInfo {
            guard try r.u8() == SevenZip.ID.folder else { throw XipperError.corrupt("bad 7z unpack info") }
            let n = try r.count(max: maxItems)
            if try r.u8() != 0 { throw XipperError.unsupported("7z external folder data") }
            var pack = 0
            for _ in 0..<n {
                var f = try parseFolder(&r)
                f.firstPackStream = pack
                pack += f.packedStreams.count
                s.folders.append(f)
            }
            if pack > s.packSizes.count { throw XipperError.corrupt("7z folders use more packed streams than exist") }
            guard try r.u8() == SevenZip.ID.codersUnpackSize else { throw XipperError.corrupt("bad 7z unpack sizes") }
            for i in s.folders.indices {
                s.folders[i].unpackSizes = try (0..<s.folders[i].numOutStreams).map { _ in try r.size() }
            }
            id = try r.u8()
            if id == SevenZip.ID.crc {
                let d = try digests(&r, n)
                for i in s.folders.indices { s.folders[i].crc = d[i] }
                id = try r.u8()
            }
            if id != SevenZip.ID.end { throw XipperError.corrupt("bad 7z unpack info end") }
            id = try r.u8()
        }
        s.numUnpackStreams = [Int](repeating: 1, count: s.folders.count)
        if id == SevenZip.ID.subStreamsInfo {
            id = try r.u8()
            if id == SevenZip.ID.numUnpackStream {
                var total = 0
                for i in s.folders.indices {
                    s.numUnpackStreams[i] = try r.count(max: maxItems)
                    total += s.numUnpackStreams[i]
                    if total > maxItems { throw XipperError.limitExceeded("too many 7z streams") }
                }
                id = try r.u8()
            }
            let hasSizes = id == SevenZip.ID.size
            for (i, f) in s.folders.enumerated() {
                let n = s.numUnpackStreams[i]
                if n == 0 { continue }
                var sum: Int64 = 0
                for _ in 1..<n {
                    let v = hasSizes ? try r.size() : 0
                    s.subSizes.append(v)
                    sum += v
                }
                if sum > f.unpackSize { throw XipperError.corrupt("7z file sizes exceed their folder") }
                s.subSizes.append(f.unpackSize - sum)
            }
            if hasSizes { id = try r.u8() }
            // CRCs: one per stream, except single-stream folders that already have a folder CRC.
            var unknown = 0
            for (i, f) in s.folders.enumerated() {
                let n = s.numUnpackStreams[i]
                unknown += (n == 1 && f.crc != nil) ? 0 : n
            }
            var crcs: [UInt32?] = []
            while id != SevenZip.ID.end {
                if id == SevenZip.ID.crc {
                    crcs = try digests(&r, unknown)
                } else {
                    try r.skip(try r.count(max: r.remaining))
                }
                id = try r.u8()
            }
            var k = 0
            for (i, f) in s.folders.enumerated() {
                let n = s.numUnpackStreams[i]
                if n == 1 && f.crc != nil {
                    s.subCRCs.append(f.crc)
                } else {
                    for _ in 0..<n {
                        s.subCRCs.append(k < crcs.count ? crcs[k] : nil)
                        k += 1
                    }
                }
            }
            id = try r.u8()
        } else {
            for f in s.folders {
                s.subSizes.append(f.unpackSize)
                s.subCRCs.append(f.crc)
            }
        }
        if id != SevenZip.ID.end { throw XipperError.corrupt("bad 7z streams info end") }
        return s
    }

    static func parseFolder(_ r: inout ByteReader) throws -> SZFolder {
        var f = SZFolder()
        let numCoders = try r.count(max: maxCoders)
        if numCoders == 0 { throw XipperError.corrupt("7z folder without coders") }
        for _ in 0..<numCoders {
            let flags = try r.u8()
            if flags & 0x80 != 0 { throw XipperError.unsupported("7z alternative coder methods") }
            let idSize = Int(flags & 0x0F)
            if idSize > 8 { throw XipperError.corrupt("7z codec id too long") }
            var c = SZCoder(method: 0)
            for b in try r.bytes(idSize) { c.method = c.method << 8 | UInt64(b) }
            if flags & 0x10 != 0 {
                c.numInStreams = try r.count(max: maxCoders)
                c.numOutStreams = try r.count(max: maxCoders)
                if c.numOutStreams != 1 { throw XipperError.unsupported("7z coder with \(c.numOutStreams) outputs") }
            }
            if flags & 0x20 != 0 {
                c.props = Array(try r.bytes(try r.count(max: 1 << 16)))
            }
            f.coders.append(c)
        }
        let outs = f.numOutStreams, ins = f.numInStreams
        if outs == 0 || ins > maxCoders * 4 { throw XipperError.corrupt("bad 7z coder streams") }
        for _ in 0..<(outs - 1) {
            let i = try r.count(max: ins - 1), o = try r.count(max: outs - 1)
            f.bindPairs.append((i, o))
        }
        let numPacked = ins - (outs - 1)
        if numPacked < 1 { throw XipperError.corrupt("7z folder without packed streams") }
        if numPacked == 1 {
            guard let p = (0..<ins).first(where: { i in !f.bindPairs.contains { $0.inIndex == i } }) else {
                throw XipperError.corrupt("7z folder: every input is bound")
            }
            f.packedStreams = [p]
        } else {
            f.packedStreams = try (0..<numPacked).map { _ in try r.count(max: ins - 1) }
        }
        // Every in stream must be fed exactly once, and the graph must be a tree.
        var fed = [Int](repeating: 0, count: ins)
        for bp in f.bindPairs { fed[bp.inIndex] += 1 }
        for p in f.packedStreams { fed[p] += 1 }
        if fed.contains(where: { $0 != 1 }) { throw XipperError.corrupt("7z folder streams are not bound correctly") }
        if Set(f.bindPairs.map(\.outIndex)).count != f.bindPairs.count { throw XipperError.corrupt("7z folder binds an output twice") }
        try checkAcyclic(f)
        return f
    }

    private static func checkAcyclic(_ f: SZFolder) throws {
        var state = [Int](repeating: 0, count: f.coders.count)  // 0 new, 1 visiting, 2 done
        let bases = f.streamBases()
        func visit(_ out: Int) throws {
            guard let ci = f.coder(forOutStream: out) else { throw XipperError.corrupt("7z bind to missing stream") }
            if state[ci] == 1 { throw XipperError.corrupt("7z coder graph has a cycle") }
            if state[ci] == 2 { return }
            state[ci] = 1
            for k in 0..<f.coders[ci].numInStreams {
                if let bp = f.bindPairs.first(where: { $0.inIndex == bases[ci].inBase + k }) { try visit(bp.outIndex) }
            }
            state[ci] = 2
        }
        try visit(f.mainOutStream)
        if state.contains(0) { throw XipperError.corrupt("7z folder has unused coders") }
    }

    static func digests(_ r: inout ByteReader, _ n: Int) throws -> [UInt32?] {
        let defined = try r.definedBits(n)
        return try defined.map { $0 ? try r.u32() : nil }
    }

    static func parseFilesInfo(_ r: inout ByteReader) throws -> [SZFile] {
        let n = try r.count(max: maxItems)
        var files = [SZFile](repeating: SZFile(), count: n)
        var emptyStream = [Bool](repeating: false, count: n)
        var emptyFile: [Bool] = []
        var anti: [Bool] = []
        while true {
            let type = try r.u8()
            if type == SevenZip.ID.end { break }
            let size = try r.count(max: r.remaining)
            var p = ByteReader(try r.bytes(size))
            switch type {
            case SevenZip.ID.emptyStream:
                emptyStream = try p.bits(n)
            case SevenZip.ID.emptyFile:
                emptyFile = try p.bits(emptyStream.filter { $0 }.count)
            case SevenZip.ID.anti:
                anti = try p.bits(emptyStream.filter { $0 }.count)
            case SevenZip.ID.name:
                if try p.u8() != 0 { throw XipperError.unsupported("7z external names") }
                let units = p.remaining / 2
                var start = 0
                var idx = 0
                var buf = [UInt16](repeating: 0, count: units)
                for i in 0..<units { buf[i] = try p.u16() }
                for i in 0..<units where buf[i] == 0 {
                    if idx < n { files[idx].name = String(decoding: buf[start..<i], as: UTF16.self) }
                    idx += 1
                    start = i + 1
                }
                if idx != n { throw XipperError.corrupt("7z name count mismatch") }
            case SevenZip.ID.mTime:
                let defined = try p.definedBits(n)
                if try p.u8() != 0 { throw XipperError.unsupported("7z external times") }
                for i in 0..<n where defined[i] { files[i].mtime = SevenZip.date(fileTime: try p.u64()) }
            case SevenZip.ID.winAttributes:
                let defined = try p.definedBits(n)
                if try p.u8() != 0 { throw XipperError.unsupported("7z external attributes") }
                for i in 0..<n where defined[i] { files[i].attributes = try p.u32() }
            default:
                break  // cTime, aTime, startPos, dummy, comment: not used
            }
        }
        var e = 0
        for i in 0..<n where emptyStream[i] {
            files[i].hasStream = false
            files[i].isDirectory = e < emptyFile.count ? !emptyFile[e] : true
            files[i].isAnti = e < anti.count && anti[e]
            e += 1
        }
        for i in 0..<n {
            if let a = files[i].attributes {
                if a & SevenZip.Attribute.directory != 0 { files[i].isDirectory = true }
                if a & SevenZip.Attribute.unixExtension != 0 && (a >> 16) & UInt32(S_IFMT) == UInt32(S_IFDIR) {
                    files[i].isDirectory = true
                }
            }
            if files[i].hasStream { files[i].isDirectory = false }
        }
        return files
    }
}

// MARK: - Writing

enum SZHeaderWriter {
    static func writeFolder(_ f: SZFolder, _ w: inout ByteWriter) {
        w.number(f.coders.count)
        for c in f.coders {
            var idBytes: [UInt8] = []
            var m = c.method
            repeat { idBytes.insert(UInt8(m & 0xFF), at: 0); m >>= 8 } while m != 0
            let complex = c.numInStreams != 1 || c.numOutStreams != 1
            var flags = UInt8(idBytes.count)
            if complex { flags |= 0x10 }
            if !c.props.isEmpty { flags |= 0x20 }
            w.u8(flags)
            w.append(idBytes)
            if complex { w.number(c.numInStreams); w.number(c.numOutStreams) }
            if !c.props.isEmpty { w.number(c.props.count); w.append(c.props) }
        }
        for bp in f.bindPairs { w.number(bp.inIndex); w.number(bp.outIndex) }
        if f.packedStreams.count > 1 { for p in f.packedStreams { w.number(p) } }
    }

    static func writeStreamsInfo(_ s: SZStreamsInfo, _ w: inout ByteWriter) {
        if !s.packSizes.isEmpty {
            w.u8(SevenZip.ID.packInfo)
            w.number(s.packPos)
            w.number(s.packSizes.count)
            w.u8(SevenZip.ID.size)
            for p in s.packSizes { w.number(p) }
            w.u8(SevenZip.ID.end)
        }
        if !s.folders.isEmpty {
            w.u8(SevenZip.ID.unpackInfo)
            w.u8(SevenZip.ID.folder)
            w.number(s.folders.count)
            w.u8(0)
            for f in s.folders { writeFolder(f, &w) }
            w.u8(SevenZip.ID.codersUnpackSize)
            for f in s.folders { for u in f.unpackSizes { w.number(u) } }
            let folderCRCs = s.folders.allSatisfy { $0.crc != nil }
            if folderCRCs {
                w.u8(SevenZip.ID.crc)
                w.u8(1)
                for f in s.folders { w.u32(f.crc!) }
            }
            w.u8(SevenZip.ID.end)

            // Substreams: only needed when some folder holds more (or fewer) than one file,
            // or when file CRCs are not folder CRCs.
            let needsSub = s.numUnpackStreams.contains { $0 != 1 } || !folderCRCs
            if needsSub {
                w.u8(SevenZip.ID.subStreamsInfo)
                if s.numUnpackStreams.contains(where: { $0 != 1 }) {
                    w.u8(SevenZip.ID.numUnpackStream)
                    for n in s.numUnpackStreams { w.number(n) }
                }
                var k = 0
                var sizes = ByteWriter()
                var crcs: [UInt32] = []
                var anySize = false
                for i in s.folders.indices {
                    let n = s.numUnpackStreams[i]
                    for j in 0..<n {
                        if j < n - 1 { sizes.number(s.subSizes[k]); anySize = true }
                        if !(n == 1 && folderCRCs) { crcs.append(s.subCRCs[k] ?? 0) }
                        k += 1
                    }
                }
                if anySize { w.u8(SevenZip.ID.size); w.append(sizes.bytes) }
                if !crcs.isEmpty {
                    w.u8(SevenZip.ID.crc)
                    w.u8(1)
                    for c in crcs { w.u32(c) }
                }
                w.u8(SevenZip.ID.end)
            }
        }
        w.u8(SevenZip.ID.end)
    }

    static func writeHeader(_ h: SZHeader) -> [UInt8] {
        var w = ByteWriter(capacity: 256 + h.files.count * 64)
        w.u8(SevenZip.ID.header)
        if !h.streams.folders.isEmpty {
            w.u8(SevenZip.ID.mainStreamsInfo)
            writeStreamsInfo(h.streams, &w)
        }
        if !h.files.isEmpty {
            w.u8(SevenZip.ID.filesInfo)
            let n = h.files.count
            w.number(n)
            func property(_ id: UInt8, _ body: (inout ByteWriter) -> Void) {
                var p = ByteWriter()
                body(&p)
                w.u8(id)
                w.number(p.bytes.count)
                w.append(p.bytes)
            }
            let empty = h.files.map { !$0.hasStream }
            if empty.contains(true) {
                property(SevenZip.ID.emptyStream) { $0.bits(empty) }
                let emptyFiles = h.files.filter { !$0.hasStream }.map { !$0.isDirectory }
                if emptyFiles.contains(true) { property(SevenZip.ID.emptyFile) { $0.bits(emptyFiles) } }
            }
            property(SevenZip.ID.name) { p in
                p.u8(0)
                for f in h.files {
                    for u in f.name.utf16 { p.u16(u) }
                    p.u16(0)
                }
            }
            let times = h.files.map { $0.mtime != nil }
            if times.contains(true) {
                property(SevenZip.ID.mTime) { p in
                    if times.allSatisfy({ $0 }) { p.u8(1) } else { p.u8(0); p.bits(times) }
                    p.u8(0)
                    for f in h.files { if let t = f.mtime { p.u64(SevenZip.fileTime(t)) } }
                }
            }
            let attrs = h.files.map { $0.attributes != nil }
            if attrs.contains(true) {
                property(SevenZip.ID.winAttributes) { p in
                    if attrs.allSatisfy({ $0 }) { p.u8(1) } else { p.u8(0); p.bits(attrs) }
                    p.u8(0)
                    for f in h.files { if let a = f.attributes { p.u32(a) } }
                }
            }
            w.u8(SevenZip.ID.end)
        }
        w.u8(SevenZip.ID.end)
        return w.bytes
    }
}
