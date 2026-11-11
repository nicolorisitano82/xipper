import CryptoKit
import CXipShims
import Foundation
import XipperKit

/// Expert Witness Format (E01, EWF version 1 as EnCase 6 and libewf write it): an exchange format for
/// courts and tools that do not read XIZ. Written and read here without external code; checked against
/// libewf (`ewfverify`) and The Sleuth Kit in scripts/e01-check.sh.
///
/// A set of segment files NAME.E01, NAME.E02, …: file header, then sections with a 76-byte descriptor
/// (type, next offset, size, Adler-32). The image is cut in 32 KiB chunks, each zlib-compressed or stored
/// with its Adler-32; `table` sections give each chunk's offset; `digest` and `hash` carry MD5 and SHA-1;
/// `error2` lists unreadable sectors.
public enum EWF {
    static let signature: [UInt8] = [0x45, 0x56, 0x46, 0x09, 0x0D, 0x0A, 0xFF, 0x00]
    static let sectorsPerChunk: UInt32 = 64
    static let chunksPerTable = 16375
    /// Segment files of about 1.4 GiB, as EnCase.
    public static let defaultSegmentSize: UInt64 = 1_500_000_000

    public struct Info: Sendable {
        /// Case fields (header): case_number, evidence_number, description, examiner, notes, …
        public var caseInfo: [String: String] = [:]
        public var model = ""
        public var serial = ""
        public var acquired = Date()
        public var bytesPerSector: UInt32 = 512
        public var sectors: UInt64 = 0
        public var removable = false
        public var physical = true
        public var md5: [UInt8]?
        public var sha1: [UInt8]?
        /// Unreadable sector ranges (error2): byte offsets and lengths.
        public var unreadable: [XizForensic.Unreadable.Range] = []
        public var segments: [URL] = []
        public var size: UInt64 { sectors * UInt64(bytesPerSector) }
        public init() {}
    }

    public enum Problem: LocalizedError {
        case notSectorAligned(UInt64, UInt32), notEWF(String), corrupt(String), hashMismatch(String)
        public var errorDescription: String? {
            switch self {
            case let .notSectorAligned(s, b): "the image (\(s) bytes) is not a whole number of \(b)-byte sectors: E01 cannot hold it, export it raw"
            case let .notEWF(p): "\(p) is not an E01 (EWF) segment file"
            case let .corrupt(m): "E01 damaged: \(m)"
            case let .hashMismatch(m): "E01 hash differs: \(m)"
            }
        }
    }

    // MARK: writing

    /// Writes the image streamed by `feed` as NAME.E01, NAME.E02… next to `base` (its extension is replaced).
    /// `feed` calls its argument with the image bytes in order. Returns the segment files and MD5/SHA-1.
    public static func write(to base: URL, info: Info, segmentSize: UInt64 = defaultSegmentSize, level: Int32 = 1,
                             feed: ((UnsafeRawBufferPointer) throws -> Void) throws -> Void) throws -> Info {
        guard info.size > 0 else { throw Problem.notSectorAligned(0, info.bytesPerSector) }
        let w = try Writer(base: base.deletingPathExtension(), info: info, segmentSize: segmentSize, level: level)
        try feed { try w.add($0) }
        return try w.finish()
    }

    final class Writer {
        let base: URL
        var info: Info
        let segmentSize: UInt64
        let level: Int32
        let chunkSize: Int
        let chunks: Int
        let guid: [UInt8]
        var md5 = Insecure.MD5()
        var sha1 = Insecure.SHA1()
        var pending: [UInt8] = []
        var written: UInt64 = 0
        var chunkIndex = 0
        // current segment
        var segment = 0
        var file: FileHandle?
        var offset: UInt64 = 0
        var sectorsStart: UInt64 = 0
        var table: [UInt32] = []
        var segments: [URL] = []

        init(base: URL, info: Info, segmentSize: UInt64, level: Int32) throws {
            self.base = base; self.info = info; self.segmentSize = max(segmentSize, 4 << 20); self.level = level
            chunkSize = Int(EWF.sectorsPerChunk * info.bytesPerSector)
            chunks = Int((info.size + UInt64(chunkSize) - 1) / UInt64(chunkSize))
            guid = (0..<16).map { _ in UInt8.random(in: 0...255) }
            pending.reserveCapacity(chunkSize)
        }

        func add(_ b: UnsafeRawBufferPointer) throws {
            md5.update(bufferPointer: b); sha1.update(bufferPointer: b)
            var p = 0
            while p < b.count {
                let n = min(chunkSize - pending.count, b.count - p)
                pending.append(contentsOf: UnsafeRawBufferPointer(rebasing: b[p..<(p + n)]))
                p += n
                if pending.count == chunkSize { try chunk(pending); pending.removeAll(keepingCapacity: true) }
            }
            written += UInt64(b.count)
        }

        func finish() throws -> Info {
            if !pending.isEmpty { try chunk(pending); pending = [] }
            guard written == info.size, chunkIndex == chunks else {
                throw Problem.corrupt("\(written) bytes written for \(info.size)")
            }
            try closeSectors()
            if segment == 1 { try section("data", volume()) } // as libewf: a copy of volume in the last segment
            if !info.unreadable.isEmpty { try section("error2", error2()) }
            let m = Array(md5.finalize()), s = Array(sha1.finalize())
            try section("digest", m + s + [UInt8](repeating: 0, count: 40), checksum: true)
            try section("hash", m + [UInt8](repeating: 0, count: 16), checksum: true)
            try terminal("done")
            try file?.close()
            info.md5 = m; info.sha1 = s; info.segments = segments
            return info
        }

        // A chunk: zlib when it helps, else stored with its Adler-32.
        func chunk(_ d: [UInt8]) throws {
            if file == nil { try openSegment() }
            if table.isEmpty { try openSectors() }
            var out = [UInt8](repeating: 0, count: xs_zlib_bound(d.count))
            let n = d.withUnsafeBufferPointer { s in out.withUnsafeMutableBufferPointer { xs_zlib_compress(s.baseAddress, d.count, $0.baseAddress, $0.count, level) } }
            let rel = UInt32(offset - sectorsStart)
            if n > 0, n < d.count {
                try put(Array(out[0..<n]))
                table.append(rel | 0x8000_0000)
            } else {
                let a = d.withUnsafeBufferPointer { xs_adler32(1, $0.baseAddress, d.count) }
                try put(d + le32(a))
                table.append(rel)
            }
            chunkIndex += 1
            if table.count == EWF.chunksPerTable || (offset + UInt64(chunkSize) * 2 > segmentSize && chunkIndex < chunks) {
                try closeSectors()
                if offset + UInt64(chunkSize) * 2 > segmentSize, chunkIndex < chunks {
                    try terminal("next")
                    try file?.close()
                    file = nil
                }
            }
        }

        func openSegment() throws {
            segment += 1
            guard segment <= 99 else { throw Problem.corrupt("more than 99 segments: use a larger segment size") }
            let url = base.appendingPathExtension(String(format: "E%02d", segment))
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw XipperError.io("create", path: url.path, errno: errno) }
            file = try FileHandle(forWritingTo: url)
            segments.append(url)
            offset = 0
            try put(EWF.signature + [1] + le16(UInt16(segment)) + le16(0))
            if segment == 1 {
                let h2 = try zlib(header2())
                try section("header2", h2)
                try section("header2", h2)
                try section("header", try zlib(header()))
                try section("volume", volume())
            } else {
                try section("data", volume())
            }
        }

        var sectorsDescriptor: UInt64 = 0
        func openSectors() throws {
            sectorsDescriptor = offset
            try put([UInt8](repeating: 0, count: 76)) // descriptor written when the section closes
            sectorsStart = sectorsDescriptor
        }

        func closeSectors() throws {
            guard !table.isEmpty, let f = file else { return }
            let end = offset
            try f.seek(toOffset: sectorsDescriptor)
            try f.write(contentsOf: descriptor("sectors", next: end, size: end - sectorsDescriptor))
            try f.seek(toOffset: end)
            // Entries are relative to the base offset: the sectors section's descriptor.
            var head = le32(UInt32(table.count)) + le32(0) + le64(sectorsStart) + le32(0)
            head += le32(adler(head))
            var entries: [UInt8] = []
            entries.reserveCapacity(table.count * 4)
            for t in table { entries += le32(t) }
            let body = head + entries + le32(adler(entries))
            try section("table", body)
            try section("table2", body)
            table = []
        }

        func section(_ type: String, _ body: [UInt8], checksum: Bool = false) throws {
            var b = body
            if checksum { b += le32(adler(b)) }
            try put(descriptor(type, next: offset + 76 + UInt64(b.count), size: 76 + UInt64(b.count)) + b)
        }

        /// `next` and `done`: the last section of a segment points at itself.
        func terminal(_ type: String) throws { try put(descriptor(type, next: offset, size: 0)) }

        func put(_ b: [UInt8]) throws {
            try file!.write(contentsOf: b)
            offset += UInt64(b.count)
        }

        func volume() -> [UInt8] {
            var v = [UInt8](repeating: 0, count: 1048)
            v[0] = info.removable ? 0x00 : 0x01
            put32(&v, 4, UInt32(chunks)); put32(&v, 8, EWF.sectorsPerChunk); put32(&v, 12, info.bytesPerSector)
            put64(&v, 16, info.sectors)
            v[36] = info.physical ? 0x03 : 0x01
            v[52] = UInt8(clamping: level > 0 ? 1 : 0)
            put32(&v, 56, EWF.sectorsPerChunk) // error granularity
            v.replaceSubrange(64..<80, with: guid)
            return v + le32(adler(v))
        }

        func error2() -> [UInt8] {
            let bps = UInt64(info.bytesPerSector)
            var head = le32(UInt32(info.unreadable.count)) + [UInt8](repeating: 0, count: 512)
            head += le32(adler(head))
            var entries: [UInt8] = []
            for r in info.unreadable {
                let first = r.offset / bps, last = (r.offset + r.length + bps - 1) / bps
                entries += le32(UInt32(clamping: first)) + le32(UInt32(clamping: last - first))
            }
            return head + entries + le32(adler(entries))
        }

        func field(_ k: String) -> String {
            (info.caseInfo[k] ?? "").replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        }

        var tool: String { "Xipper Forensic \(ForensicReport.toolVersion)" }

        func header2() -> [UInt8] {
            let t = String(Int(info.acquired.timeIntervalSince1970))
            let main = [field("description"), field("case_number"), field("evidence_number"), field("examiner"), field("notes"),
                        info.model.replacingOccurrences(of: "\t", with: " "), info.serial.replacingOccurrences(of: "\t", with: " "),
                        tool, "Darwin", t, t, "0", ""]
            let text = "3\nmain\na\tc\tn\te\tt\tmd\tsn\tav\tov\tm\tu\tp\tdc\n" + main.joined(separator: "\t") + "\n\n"
                + "srce\n0\t1\np\tn\tid\tev\ttb\tlo\tpo\tah\tgu\taq\n0\t0\n\t\t\t\t\t-1\t-1\t\t\t\n\n"
                + "sub\n0\t1\np\tn\tid\tnu\tco\tgu\n0\t0\n\t\t\t\t1\t\n\n"
            return [0xFF, 0xFE] + text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        }

        func header() -> [UInt8] {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(identifier: "UTC")!
            let d = c.dateComponents([.year, .month, .day, .hour, .minute, .second], from: info.acquired)
            let t = "\(d.year!) \(d.month!) \(d.day!) \(d.hour!) \(d.minute!) \(d.second!)"
            let main = [field("case_number"), field("evidence_number"), field("description"), field("examiner"), field("notes"),
                        tool, "Darwin", t, t, "0"]
            let text = "1\r\nmain\r\nc\tn\ta\te\tt\tav\tov\tm\tu\tp\r\n" + main.joined(separator: "\t") + "\r\n\r\n"
            // EnCase reads this one as Windows-1252: keep it ASCII.
            return Array(text.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false)?
                .unicodeScalars.map { $0.isASCII ? Character($0) : "?" }.map(String.init).joined().utf8 ?? text.utf8)
        }

        func zlib(_ b: [UInt8]) throws -> [UInt8] {
            var out = [UInt8](repeating: 0, count: xs_zlib_bound(b.count))
            let n = b.withUnsafeBufferPointer { s in out.withUnsafeMutableBufferPointer { xs_zlib_compress(s.baseAddress, b.count, $0.baseAddress, $0.count, 9) } }
            guard n > 0 else { throw Problem.corrupt("zlib") }
            return Array(out[0..<n])
        }
    }

    static func descriptor(_ type: String, next: UInt64, size: UInt64) -> [UInt8] {
        var d = Array(type.utf8) + [UInt8](repeating: 0, count: 16 - type.utf8.count)
        d += le64(next) + le64(size) + [UInt8](repeating: 0, count: 40)
        return d + le32(adler(d))
    }

    static func adler(_ b: [UInt8]) -> UInt32 { b.withUnsafeBufferPointer { xs_adler32(1, $0.baseAddress, b.count) } }
    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> ($0 * 8)) & 0xFF) } }
    static func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> ($0 * 8)) & 0xFF) } }
    static func put32(_ b: inout [UInt8], _ at: Int, _ v: UInt32) { b.replaceSubrange(at..<(at + 4), with: le32(v)) }
    static func put64(_ b: inout [UInt8], _ at: Int, _ v: UInt64) { b.replaceSubrange(at..<(at + 8), with: le64(v)) }
    static func u32(_ b: [UInt8], _ at: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[at + $1]) << ($1 * 8) } }
    static func u64(_ b: [UInt8], _ at: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[at + $1]) << ($1 * 8) } }

    // MARK: reading

    /// An E01 set opened for reading: chunk offsets from the tables, any chunk on demand.
    public final class Reader: @unchecked Sendable {
        public private(set) var info = Info()
        struct Chunk { var file: Int; var offset: UInt64; var compressed: Bool; var size: Int }
        var chunks: [Chunk] = []
        var files: [FileHandle] = []
        var chunkSize = 32768
        let lock = NSLock()

        /// Opens NAME.E01 and the segments after it (NAME.E02…).
        public init(_ first: URL) throws {
            var url = first
            var n = 1
            var headerText = "", header2Text = ""
            while FileManager.default.fileExists(atPath: url.path) {
                let h = try FileHandle(forReadingFrom: url)
                files.append(h)
                info.segments.append(url)
                let size = try h.seekToEnd()
                func read(_ at: UInt64, _ count: Int) throws -> [UInt8] {
                    try h.seek(toOffset: at)
                    let d = try h.read(upToCount: count) ?? Data()
                    guard d.count == count else { throw Problem.corrupt("\(url.lastPathComponent) truncated") }
                    return Array(d)
                }
                let fh = try read(0, 13)
                guard Array(fh[0..<8]) == EWF.signature else { throw Problem.notEWF(url.path) }
                guard Int(UInt16(fh[9]) | UInt16(fh[10]) << 8) == n else { throw Problem.corrupt("\(url.lastPathComponent) is segment \(fh[9]), expected \(n)") }
                var off: UInt64 = 13
                var last = ""
                var seenSectors = false
                while off + 76 <= size {
                    let d = try read(off, 76)
                    guard EWF.adler(Array(d[0..<72])) == EWF.u32(d, 72) else { throw Problem.corrupt("section at \(off) in \(url.lastPathComponent): checksum") }
                    let type = String(decoding: d[0..<16].prefix { $0 != 0 }, as: UTF8.self)
                    let next = EWF.u64(d, 16), len = EWF.u64(d, 24)
                    last = type
                    let body = len > 76 ? try read(off + 76, Int(len - 76)) : []
                    switch type {
                    case "header": headerText = String(decoding: try EWF.inflate(body), as: UTF8.self)
                    case "header2":
                        let raw = try EWF.inflate(body)
                        let units = stride(from: 2, to: raw.count - 1, by: 2).map { UInt16(raw[$0]) | UInt16(raw[$0 + 1]) << 8 }
                        header2Text = String(decoding: units, as: UTF16.self)
                    case "volume", "disk", "data":
                        guard body.count >= 1052 else { throw Problem.corrupt("volume section") }
                        guard EWF.adler(Array(body[0..<1048])) == EWF.u32(body, 1048) else { throw Problem.corrupt("volume section checksum") }
                        info.removable = body[0] == 0
                        chunkSize = Int(EWF.u32(body, 8) * EWF.u32(body, 12))
                        info.bytesPerSector = EWF.u32(body, 12)
                        info.sectors = EWF.u64(body, 16)
                        info.physical = body[36] & 0x02 != 0
                    case "sectors": seenSectors = true
                    case "table":
                        guard body.count >= 24, EWF.adler(Array(body[0..<20])) == EWF.u32(body, 20) else { throw Problem.corrupt("table header checksum") }
                        let count = Int(EWF.u32(body, 0)), base = EWF.u64(body, 8)
                        guard body.count >= 24 + count * 4 else { throw Problem.corrupt("table entries") }
                        let entries = Array(body[24..<(24 + count * 4)])
                        if body.count >= 28 + count * 4, EWF.adler(entries) != EWF.u32(body, 24 + count * 4) { throw Problem.corrupt("table entries checksum") }
                        var offs: [(UInt64, Bool)] = []
                        for i in 0..<count {
                            let e = EWF.u32(entries, i * 4)
                            offs.append((base + UInt64(e & 0x7FFF_FFFF), e & 0x8000_0000 != 0))
                        }
                        // A chunk ends where the next starts; the last one where the sectors section ends (this table).
                        for (i, (o, c)) in offs.enumerated() {
                            let end = i + 1 < offs.count ? offs[i + 1].0 : off
                            chunks.append(Chunk(file: files.count - 1, offset: o, compressed: c, size: Int(end - o)))
                        }
                    case "digest":
                        if body.count >= 36 { info.md5 = Array(body[0..<16]); info.sha1 = Array(body[16..<36]) }
                    case "hash":
                        if info.md5 == nil, body.count >= 16 { info.md5 = Array(body[0..<16]) }
                    case "error2":
                        guard body.count >= 520 else { break }
                        let count = Int(EWF.u32(body, 0))
                        let bps = UInt64(info.bytesPerSector)
                        for i in 0..<count where 520 + i * 8 + 8 <= body.count {
                            let s = UInt64(EWF.u32(body, 520 + i * 8)), c = UInt64(EWF.u32(body, 524 + i * 8))
                            info.unreadable.append(.init(offset: s * bps, length: c * bps))
                        }
                    default: break
                    }
                    if type == "done" || type == "next" || next == off { break }
                    guard next > off else { throw Problem.corrupt("section chain in \(url.lastPathComponent)") }
                    off = next
                }
                _ = seenSectors
                if last == "done" { break }
                n += 1
                url = first.deletingPathExtension().appendingPathExtension(String(format: "E%02d", n))
            }
            guard last(info) else { throw Problem.corrupt("no volume section") }
            guard chunks.count == Int((info.size + UInt64(chunkSize) - 1) / UInt64(chunkSize)) else {
                throw Problem.corrupt("\(chunks.count) chunks for \(info.size) bytes (missing segment?)")
            }
            info.caseInfo = EWF.parseHeader(header2: header2Text, header: headerText)
            info.model = info.caseInfo.removeValue(forKey: "model") ?? ""
            info.serial = info.caseInfo.removeValue(forKey: "serial") ?? ""
        }

        private func last(_ i: Info) -> Bool { i.sectors > 0 }

        /// The bytes of chunk `i` (zlib inflated, or stored with its Adler-32 checked).
        public func chunk(_ i: Int) throws -> [UInt8] {
            let c = chunks[i]
            let raw: [UInt8] = try lock.withLock {
                try files[c.file].seek(toOffset: c.offset)
                return Array(try files[c.file].read(upToCount: c.size) ?? Data())
            }
            guard raw.count == c.size else { throw Problem.corrupt("chunk \(i) truncated") }
            let want = Int(min(UInt64(chunkSize), info.size - UInt64(i) * UInt64(chunkSize)))
            if c.compressed {
                var out = [UInt8](repeating: 0, count: chunkSize)
                let n = raw.withUnsafeBufferPointer { s in out.withUnsafeMutableBufferPointer { xs_zlib_uncompress(s.baseAddress, raw.count, $0.baseAddress, $0.count) } }
                guard n == want else { throw Problem.corrupt("chunk \(i) does not inflate") }
                return Array(out[0..<want])
            }
            guard raw.count >= want + 4 else { throw Problem.corrupt("chunk \(i) size") }
            let data = Array(raw[0..<want])
            guard EWF.adler(data) == EWF.u32(raw, want) else { throw Problem.corrupt("chunk \(i) checksum") }
            return data
        }

        /// Reads `count` bytes at `offset` into `dst`.
        public func read(at offset: UInt64, into dst: UnsafeMutableRawPointer, count: Int) throws {
            var done = 0
            while done < count {
                let pos = offset + UInt64(done)
                let i = Int(pos / UInt64(chunkSize)), inChunk = Int(pos % UInt64(chunkSize))
                let c = try chunk(i)
                let n = min(count - done, c.count - inChunk)
                c.withUnsafeBytes { (dst + done).copyMemory(from: $0.baseAddress! + inChunk, byteCount: n) }
                done += n
            }
        }

        /// Reads everything in order, compares MD5 and SHA-1 with the stored ones; returns (MD5, SHA-1, SHA-256).
        public func verify(progress: ((UInt64) -> Void)? = nil) throws -> (md5: [UInt8], sha1: [UInt8], sha256: [UInt8]) {
            var m = Insecure.MD5(), s = Insecure.SHA1(), h = SHA256()
            var pos: UInt64 = 0
            for i in 0..<chunks.count {
                let c = try chunk(i)
                c.withUnsafeBytes { m.update(bufferPointer: $0); s.update(bufferPointer: $0); h.update(bufferPointer: $0) }
                pos += UInt64(c.count)
                progress?(pos)
            }
            let r = (Array(m.finalize()), Array(s.finalize()), Array(h.finalize()))
            if let x = info.md5, x != r.0 { throw Problem.hashMismatch("MD5 stored \(XizForensic.hex(x)), computed \(XizForensic.hex(r.0))") }
            if let x = info.sha1, x != r.1 { throw Problem.hashMismatch("SHA-1 stored \(XizForensic.hex(x)), computed \(XizForensic.hex(r.1))") }
            return r
        }
    }

    static func inflate(_ b: [UInt8]) throws -> [UInt8] {
        var cap = max(4096, b.count * 8)
        while cap <= 64 << 20 {
            var out = [UInt8](repeating: 0, count: cap)
            let n = b.withUnsafeBufferPointer { s in out.withUnsafeMutableBufferPointer { xs_zlib_uncompress(s.baseAddress, b.count, $0.baseAddress, $0.count) } }
            if n >= 0 { return Array(out[0..<n]) }
            cap *= 4
        }
        throw Problem.corrupt("header does not inflate")
    }

    /// Case fields from header2 (preferred, UTF-16) or header.
    static func parseHeader(header2: String, header: String) -> [String: String] {
        let names = ["a": "description", "c": "case_number", "n": "evidence_number", "e": "examiner", "t": "notes",
                     "md": "model", "sn": "serial", "av": "acquiry_software", "ov": "acquiry_os"]
        for text in [header2, header] where !text.isEmpty {
            let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            guard let i = lines.firstIndex(of: "main"), i + 2 < lines.count else { continue }
            let keys = lines[i + 1].components(separatedBy: "\t"), values = lines[i + 2].components(separatedBy: "\t")
            var out: [String: String] = [:]
            for (k, v) in zip(keys, values) where !v.isEmpty { if let n = names[k] { out[n] = v } }
            return out
        }
        return [:]
    }
}
