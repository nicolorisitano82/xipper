import Foundation

public struct CRAMReport: Sendable {
    /// "3.0", "3.1", "2.1"…
    public var version: String
    public var containers: Int
    public var blocks: Int
    public var records: Int64
    public var bases: Int64
    public var hasEOFContainer: Bool
    public var problems: [String]
    public var isOK: Bool { problems.isEmpty }
}

/// Structural CRAM check (CRAM 3.0/3.1 specification §6–§9) without decoding any data:
/// file definition, every container header CRC32, every block CRC32, block sizes that add up to
/// the container length, slice landmarks on slice-header blocks and the final EOF container.
enum CRAMScanner {
    struct Layout {
        var major: Int = 0, minor: Int = 0
        var containers = 0, blocks = 0
        var records: Int64 = 0, bases: Int64 = 0
        var eof = false
        var problems: [String] = []
        /// Container offset → slice landmarks (offsets from the start of the container data).
        var landmarks: [UInt64: [Int]] = [:]
    }

    /// The 38-byte EOF container of CRAM 3.x.
    static let eofContainer: [UInt8] = [
        0x0f, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0x0f, 0xe0, 0x45, 0x4f, 0x46, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
        0x05, 0xbd, 0xd9, 0x4f, 0x00, 0x01, 0x00, 0x06, 0x06, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0xee, 0x63, 0x01, 0x4b,
    ]
    static let eofStart: Int64 = 4_542_278  // "EOF" in the alignment-start field

    static func isCRAM(_ head: [UInt8]) -> Bool { head.starts(with: Array("CRAM".utf8)) }

    struct Cursor {
        let b: [UInt8]
        var pos = 0
        mutating func byte() throws -> UInt8 {
            guard pos < b.count else { throw XipperError.corrupt("truncated") }
            defer { pos += 1 }
            return b[pos]
        }
        mutating func int32() throws -> Int32 {
            guard pos + 4 <= b.count else { throw XipperError.corrupt("truncated") }
            defer { pos += 4 }
            return Int32(bitPattern: UInt32(b[pos]) | UInt32(b[pos + 1]) << 8 | UInt32(b[pos + 2]) << 16 | UInt32(b[pos + 3]) << 24)
        }
        mutating func uint32() throws -> UInt32 { UInt32(bitPattern: try int32()) }
        /// ITF8: 1-5 bytes, the leading 1-bits of the first byte give the extra byte count.
        mutating func itf8() throws -> Int32 {
            let b0 = UInt32(try byte())
            if b0 < 0x80 { return Int32(b0) }
            if b0 < 0xC0 { return Int32((b0 & 0x3F) << 8 | UInt32(try byte())) }
            if b0 < 0xE0 { let x = UInt32(try byte()) << 8 | UInt32(try byte()); return Int32((b0 & 0x1F) << 16 | x) }
            if b0 < 0xF0 {
                let x = UInt32(try byte()) << 16 | UInt32(try byte()) << 8 | UInt32(try byte())
                return Int32(bitPattern: (b0 & 0x0F) << 24 | x)
            }
            let x = UInt32(try byte()) << 20 | UInt32(try byte()) << 12 | UInt32(try byte()) << 4 | UInt32(try byte() & 0x0F)
            return Int32(bitPattern: (b0 & 0x0F) << 28 | x)
        }
        /// LTF8: 1-9 bytes, same scheme over 64 bits.
        mutating func ltf8() throws -> Int64 {
            let b0 = try byte()
            var extra = 0
            while extra < 8 && b0 & (0x80 >> extra) != 0 { extra += 1 }
            var v: UInt64 = extra < 8 ? UInt64(b0 & (0xFF >> (extra + 1))) : 0
            for _ in 0..<extra { v = v << 8 | UInt64(try byte()) }
            return Int64(bitPattern: v)
        }
    }

    static func scan(_ file: FileReader, cancel: CancellationToken? = nil, progress: ((Int64) -> Void)? = nil) throws -> Layout {
        var l = Layout()
        guard file.size >= 26 else { throw XipperError.corrupt("too short for a CRAM file") }
        let def = try file.read(at: 0, count: 26)
        guard isCRAM(def) else { throw XipperError.corrupt("not a CRAM file (no CRAM magic)") }
        l.major = Int(def[4]); l.minor = Int(def[5])
        guard (2...3).contains(l.major) else {
            l.problems.append("CRAM \(l.major).\(l.minor) is not supported (2.x and 3.x are)")
            return l
        }
        let crcs = l.major >= 3
        var off: Int64 = 26
        var lastWasEOF = false
        while off < file.size {
            try cancel?.check()
            let at = off
            func fail(_ m: String) { l.problems.append("container at offset \(at): \(m)") }
            // Container header: at most 4 + 5·4 + 9·2 + 5 + landmarks + 4 bytes.
            var head = try file.read(at: off, count: Int(min(file.size - off, 4096)))
            var c = Cursor(b: head)
            var length: Int32 = 0, refID: Int32 = 0, start: Int32 = 0, nrec: Int32 = 0, nblocks: Int32 = 0
            var marks: [Int] = []
            do {
                length = try c.int32()
                refID = try c.itf8(); start = try c.itf8(); _ = try c.itf8()
                nrec = try c.itf8()
                _ = try c.ltf8()
                l.bases += try c.ltf8()
                nblocks = try c.itf8()
                let nmarks = Int(try c.itf8())
                guard (0...1_000_000).contains(nmarks) else { fail("invalid landmark count \(nmarks)"); break }
                if 6 * nmarks + c.pos > head.count && off + Int64(head.count) < file.size {
                    head = try file.read(at: off, count: Int(min(file.size - off, Int64(c.pos + 5 * nmarks + 8))))
                    c = Cursor(b: head, pos: c.pos)
                }
                for _ in 0..<nmarks { marks.append(Int(try c.itf8())) }
                if crcs {
                    let headerEnd = c.pos
                    let stored = try c.uint32()
                    let actual = CRC32.checksum(Array(head[0..<headerEnd]))
                    if stored != actual { fail("header CRC32 mismatch (stored \(hex(stored)), computed \(hex(actual)))"); break }
                }
            } catch {
                fail("truncated container header")
                break
            }
            let headerSize = c.pos
            guard length >= 0, nblocks >= 0 else { fail("negative length or block count"); break }
            guard off + Int64(headerSize) + Int64(length) <= file.size else {
                fail("truncated: container needs \(length) bytes, \(file.size - off - Int64(headerSize)) left")
                break
            }
            guard length <= 1 << 30 else { fail("container larger than 1 GiB (\(length) bytes)"); break }
            let body = try file.read(at: off + Int64(headerSize), count: Int(length))
            var bc = Cursor(b: body)
            var blockStarts: [Int: UInt8] = [:]
            var ok = true
            for k in 0..<Int(nblocks) {
                let bstart = bc.pos
                do {
                    _ = try bc.byte()
                    let ctype = try bc.byte()
                    _ = try bc.itf8()
                    let size = Int(try bc.itf8())
                    _ = try bc.itf8()
                    guard size >= 0, bc.pos + size + (crcs ? 4 : 0) <= body.count else {
                        fail("block \(k) (\(size) bytes) overruns the container"); ok = false; break
                    }
                    bc.pos += size
                    if crcs {
                        let dataEnd = bc.pos
                        let stored = try bc.uint32()
                        let actual = body.withUnsafeBytes { CRC32.checksum(UnsafeRawBufferPointer(rebasing: $0[bstart..<dataEnd])) }
                        if stored != actual { fail("block \(k) CRC32 mismatch (stored \(hex(stored)), computed \(hex(actual)))"); ok = false }
                    }
                    blockStarts[bstart] = ctype
                } catch {
                    fail("block \(k) header truncated"); ok = false; break
                }
            }
            l.blocks += Int(nblocks)
            let isEOF = refID == -1 && Int64(start) == eofStart && nrec == 0 && nblocks <= 1
            if ok && bc.pos != body.count && l.containers > 0 && !isEOF {
                fail("\(body.count - bc.pos) unexplained bytes after the last block")
            }
            if ok && nrec > 0 {
                if blockStarts[0] != 1 { fail("first block is not a compression header") }
                for m in marks where blockStarts[m] != 2 { fail("landmark \(m) is not on a slice header block") }
            }
            l.landmarks[UInt64(off)] = marks
            l.records += Int64(nrec)
            l.containers += 1
            lastWasEOF = isEOF
            off += Int64(headerSize) + Int64(length)
            progress?(off)
        }
        l.eof = lastWasEOF
        if l.major >= 3 && !lastWasEOF && l.problems.isEmpty {
            l.problems.append("EOF container missing: the file is probably truncated")
        } else if l.major >= 3 && lastWasEOF {
            let tail = try file.read(at: file.size - 38, count: 38)
            if tail != eofContainer { l.problems.append("EOF container is not the standard 38-byte one") }
        }
        return l
    }

    private static func hex(_ v: UInt32) -> String { String(format: "%08x", v) }
}

extension Xipper {
    /// Verifies the structure of a CRAM 3.0/3.1 file without decoding it (CRCs, sizes, EOF container).
    public static func checkCRAM(_ url: URL, progress: ProgressHandler? = nil, cancel: CancellationToken? = nil) throws -> CRAMReport {
        let file = try FileReader(path: url.standardizedFileURL.path)
        let tracker = ProgressTracker(totalBytes: file.size, totalEntries: 1, handler: progress)
        var last: Int64 = 0
        let l = try CRAMScanner.scan(file, cancel: cancel) { off in tracker.add(bytes: off - last); last = off }
        tracker.finish()
        return CRAMReport(version: "\(l.major).\(l.minor)", containers: l.containers, blocks: l.blocks, records: l.records,
                          bases: l.bases, hasEOFContainer: l.eof, problems: l.problems)
    }
}
