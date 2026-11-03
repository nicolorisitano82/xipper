import CryptoKit
import Darwin
import Foundation

/// The recovery record at the end of a XIZ archive (spec §15).
public struct XizRecoveryInfo: Sendable, Equatable {
    public var sliceSize: Int
    public var dataSlices: Int
    public var recoverySlices: Int
    /// The archive proper: everything before the record.
    public var protectedLength: Int64
    public var recordBytes: Int64
    /// Recovery slices per data slice, in percent.
    public var redundancy: Double { Double(recoverySlices) * 100 / Double(dataSlices) }
}

/// What a scrub found (and, with repair, fixed).
public struct XizScrubReport: Sendable {
    /// nil: the archive has no recovery record.
    public var info: XizRecoveryInfo?
    /// Byte ranges of the archive found damaged (one per damaged slice).
    public var damagedRanges: [Range<Int64>] = []
    public var damagedRecoverySlices = 0
    /// Damaged copies of the record's header and table, and a damaged trailer.
    public var damagedMetadata = 0
    /// The damaged data slices are no more than the intact recovery slices.
    public var repairable = false
    public var repaired = false
    public var isClean: Bool { damagedRanges.isEmpty && damagedRecoverySlices == 0 && damagedMetadata == 0 }
}

extension Xipper {
    /// Appends a recovery record to a XIZ archive (replacing any it has): `redundancy` percent of
    /// recovery slices, at least one.
    @discardableResult
    public static func addXizRecovery(_ archive: URL, redundancy: Double = 10, progress: ProgressHandler? = nil,
                                      cancel: CancellationToken? = nil) throws -> XizRecoveryInfo {
        try XizRecovery.add(archive.path, redundancy: redundancy, progress: progress, cancel: cancel)
    }

    /// Removes the recovery record; false when there was none.
    @discardableResult
    public static func removeXizRecovery(_ archive: URL) throws -> Bool { try XizRecovery.remove(archive.path) }

    /// The archive's recovery record, if it has a readable one.
    public static func xizRecoveryInfo(_ archive: URL) -> XizRecoveryInfo? {
        guard let r = try? FileReader(path: archive.path), let loc = XizRecovery.locate(r) else { return nil }
        return loc.header.info
    }

    /// Checks every byte of the archive against its recovery record; with `repair`, rebuilds the
    /// damaged bytes in place (and the record's own damage) when the record suffices.
    public static func scrubXiz(_ archive: URL, repair: Bool = false, progress: ProgressHandler? = nil,
                                cancel: CancellationToken? = nil) throws -> XizScrubReport {
        try XizRecovery.scrub(archive.path, repair: repair, progress: progress, cancel: cancel)
    }
}

/// Cauchy Reed–Solomon over GF(2^16) (the PAR2 field and NEON kernel, `GF16`) on fixed slices of
/// the whole archive. The record follows the last footer, so readers that know nothing of it
/// find the footer as after an interrupted append (§11).
enum XizRecovery {
    static let headerMagic: [UInt8] = Array("XIZR".utf8)
    static let trailerMagic: [UInt8] = Array("XIZT".utf8)
    static let trailerTail: [UInt8] = Array("XZR!".utf8)
    static let headerSize = 64
    static let trailerSize = 64
    static let hashSize = 16
    static let targetSlices = 2000
    static let maxDataSlices = 32768

    struct Header: Equatable {
        var archiveID: [UInt8]
        var protectedLength: Int64
        var sliceSize: Int
        var dataSlices: Int
        var recoverySlices: Int
        var tableHash: [UInt8]

        var tableBytes: Int { hashSize * (dataSlices + recoverySlices) }
        /// Where the recovery slices start.
        var recoveryOffset: Int64 { (protectedLength + Int64(headerSize + tableBytes) + 4095) & ~4095 }
        var headerB: Int64 { recoveryOffset + Int64(recoverySlices) * Int64(sliceSize) }
        var end: Int64 { headerB + Int64(headerSize + tableBytes + trailerSize) }
        var info: XizRecoveryInfo {
            XizRecoveryInfo(sliceSize: sliceSize, dataSlices: dataSlices, recoverySlices: recoverySlices,
                            protectedLength: protectedLength, recordBytes: end - protectedLength)
        }

        func encode() -> [UInt8] {
            var w = ByteWriter(capacity: headerSize)
            w.append(headerMagic); w.u16(1); w.u16(0)
            w.append(archiveID); w.u64(UInt64(protectedLength))
            w.u32(UInt32(sliceSize)); w.u32(UInt32(dataSlices)); w.u32(UInt32(recoverySlices))
            w.append(tableHash)
            w.u32(Xiz.crc32c(w.bytes))
            return w.bytes
        }

        static func decode(_ b: [UInt8]) -> Header? {
            guard b.count == headerSize, b.starts(with: headerMagic), u32(b, 60) == Xiz.crc32c(Array(b[0..<60])),
                  u16(b, 4) == 1, u16(b, 6) == 0 else { return nil }
            let h = Header(archiveID: Array(b[8..<24]), protectedLength: Int64(bitPattern: u64(b, 24)), sliceSize: Int(u32(b, 32)),
                           dataSlices: Int(u32(b, 36)), recoverySlices: Int(u32(b, 40)), tableHash: Array(b[44..<60]))
            guard h.sliceSize >= 4096, h.sliceSize % 4096 == 0, h.dataSlices >= 1, h.dataSlices <= maxDataSlices,
                  h.recoverySlices >= 1, h.recoverySlices <= h.dataSlices,
                  h.protectedLength > Int64(Xiz.superblockSize + Xiz.footerSize),
                  (h.protectedLength + Int64(h.sliceSize) - 1) / Int64(h.sliceSize) == Int64(h.dataSlices) else { return nil }
            return h
        }
    }

    struct Trailer {
        var archiveID: [UInt8]
        var headerA: Int64
        var recoveryOffset: Int64
        var headerB: Int64

        func encode() -> [UInt8] {
            var w = ByteWriter(capacity: trailerSize)
            w.append(trailerMagic); w.u16(1); w.u16(0)
            w.append(archiveID); w.u64(UInt64(headerA)); w.u64(UInt64(recoveryOffset)); w.u64(UInt64(headerB)); w.u64(0)
            w.u32(Xiz.crc32c(w.bytes))
            w.append(trailerTail)
            return w.bytes
        }

        static func decode(_ b: [UInt8]) -> Trailer? {
            guard b.count == trailerSize, b.starts(with: trailerMagic), Array(b[60..<64]) == trailerTail,
                  u32(b, 56) == Xiz.crc32c(Array(b[0..<56])), u16(b, 4) == 1 else { return nil }
            return Trailer(archiveID: Array(b[8..<24]), headerA: Int64(bitPattern: u64(b, 24)),
                           recoveryOffset: Int64(bitPattern: u64(b, 32)), headerB: Int64(bitPattern: u64(b, 40)))
        }
    }

    /// A record found in a file, with how many of its three metadata pieces were damaged.
    struct Located {
        var header: Header
        var table: [UInt8]
        var damagedMetadata: Int
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[o + $1]) << (8 * $1) } }
    private static func u64(_ b: [UInt8], _ o: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(b[o + $1]) << (8 * $1) } }

    static func prefixHash(_ p: UnsafeRawBufferPointer) -> [UInt8] { Array(SHA256.hash(data: p).prefix(hashSize)) }

    /// GF(2^16) coefficient of data slice `d` in recovery slice `r`: 1 / ((K + r) ⊕ d).
    static func coefficient(_ r: Int, _ d: Int, dataSlices k: Int) -> UInt16 { GF16.inverse(UInt16(k + r) ^ UInt16(d)) }

    /// The protected end of a trailer-located record, for readers: the footer is right before it.
    static func trailerProtectedEnd(_ reader: FileReader) -> Int64? {
        guard reader.size >= Int64(trailerSize + Xiz.footerSize + Xiz.superblockSize),
              let t = Trailer.decode((try? reader.read(at: reader.size - Int64(trailerSize), count: trailerSize)) ?? []),
              t.headerA < reader.size else { return nil }
        return t.headerA
    }

    // MARK: locate

    /// The header at `offset` with its table, when both check out and the offset is one of the
    /// two places this header puts its copies.
    private static func candidate(_ reader: FileReader, at offset: Int64) -> (Header, [UInt8])? {
        guard offset >= 0, offset + Int64(headerSize) <= reader.size,
              let h = Header.decode((try? reader.read(at: offset, count: headerSize)) ?? []),
              offset == h.protectedLength || offset == h.headerB,
              offset + Int64(headerSize + h.tableBytes) <= reader.size,
              let table = try? reader.read(at: offset + Int64(headerSize), count: h.tableBytes),
              Array(SHA256.hash(data: table).prefix(hashSize)) == h.tableHash else { return nil }
        return (h, table)
    }

    static func locate(_ reader: FileReader) -> Located? {
        let size = reader.size
        var found: (Header, [UInt8])?
        var trailerOK = false
        if size >= Int64(trailerSize), let t = Trailer.decode((try? reader.read(at: size - Int64(trailerSize), count: trailerSize)) ?? []) {
            trailerOK = true
            found = candidate(reader, at: t.headerA) ?? candidate(reader, at: t.headerB)
            if let h = found?.0, h.headerB != t.headerB || h.protectedLength != t.headerA || h.end != size { trailerOK = false }
        }
        if found == nil {
            found = scanBackwards(reader)
            trailerOK = false
        }
        guard let (h, table) = found.map({ ($0.0, $0.1) }) else { return nil }
        var damaged = trailerOK ? 0 : 1
        for at in [h.protectedLength, h.headerB] where candidate(reader, at: at).map({ $0.0 != h || $0.1 != table }) ?? true { damaged += 1 }
        return Located(header: h, table: table, damagedMetadata: damaged)
    }

    /// The last header with a valid table, searched from the end (trailer lost).
    private static func scanBackwards(_ reader: FileReader) -> (Header, [UInt8])? {
        let window = 1 << 20
        var end = reader.size
        while end > Int64(Xiz.superblockSize) {
            let start = max(0, end - Int64(window))
            guard let chunk = try? reader.read(at: start, count: Int(end - start)) else { return nil }
            var i = chunk.count - 4
            while i >= 0 {
                if chunk[i] == 0x58, chunk[i + 1] == 0x49, chunk[i + 2] == 0x5A, chunk[i + 3] == 0x52,  // "XIZR"
                   let c = candidate(reader, at: start + Int64(i)) {
                    return c
                }
                i -= 1
            }
            if start == 0 { break }
            end = start + 3
        }
        return nil
    }

    // MARK: add, remove

    /// Slice size and counts for `protected` bytes: about `targetSlices` slices of 4 KiB multiples.
    static func plan(protected p: Int64, redundancy: Double) -> (size: Int, data: Int, recovery: Int) {
        var size = Int(((p + Int64(targetSlices) - 1) / Int64(targetSlices) + 4095) & ~4095)
        size = max(4096, size)
        while (p + Int64(size) - 1) / Int64(size) > Int64(maxDataSlices) { size *= 2 }
        let k = Int((p + Int64(size) - 1) / Int64(size))
        let m = max(1, min(k, Int((Double(k) * redundancy / 100).rounded(.up))))
        return (size, k, m)
    }

    /// The end of the archive proper: before the record, or after the last valid footer.
    static func protectedEnd(_ reader: FileReader) throws -> (end: Int64, archiveID: [UInt8]) {
        let sb = try Xiz.Superblock.decode(try reader.read(at: 0, count: Xiz.superblockSize))
        let dataStart = Int64(Xiz.superblockSize) + Int64(sb.keysLength)
        let (footerStart, _) = try XizArchive.lastFooter(reader, dataStart: dataStart)
        return (footerStart + Int64(Xiz.footerSize), sb.archiveID)
    }

    static func add(_ path: String, redundancy: Double, progress: ProgressHandler?, cancel: CancellationToken?) throws -> XizRecoveryInfo {
        guard redundancy > 0, redundancy <= 100 else { throw XipperError.invalidArgument("redundancy must be between 1 and 100%") }
        let reader = try FileReader(path: path)
        let (p, id) = try protectedEnd(reader)
        let (s, k, m) = plan(protected: p, redundancy: redundancy)
        let fd = open(path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { throw XipperError.posix("open", path) }
        defer { close(fd) }
        // The old record goes first: an interrupted run leaves the archive as it was without one.
        guard ftruncate(fd, off_t(p)) == 0 else { throw XipperError.posix("truncate", path) }
        let tracker = ProgressTracker(totalBytes: p * 2, totalEntries: 1, handler: progress)
        var header = Header(archiveID: id, protectedLength: p, sliceSize: s, dataSlices: k, recoverySlices: m, tableHash: [])
        let dataHashes = try hashDataSlices(reader, header, tracker: tracker, cancel: cancel)
        let recovery = try encode(reader, fd: fd, header, rows: Array(0..<m), tracker: tracker, cancel: cancel)
        let table = (dataHashes + recovery).flatMap { $0 }
        header.tableHash = Array(SHA256.hash(data: table).prefix(hashSize))
        try writeMetadata(fd, path: path, header, table: table)
        tracker.finish()
        return header.info
    }

    static func remove(_ path: String) throws -> Bool {
        let reader = try FileReader(path: path)
        guard let loc = locate(reader) else { return false }
        let p = loc.header.protectedLength
        // The footer must be right before it: never cut an archive at a header found by chance.
        guard try protectedEnd(reader).end == p else { throw XipperError.corrupt("the recovery record does not follow the archive's footer") }
        guard truncate(path, off_t(p)) == 0 else { throw XipperError.posix("truncate", path) }
        return true
    }

    /// Both header and table copies and the trailer, then F_FULLFSYNC.
    private static func writeMetadata(_ fd: Int32, path: String, _ h: Header, table: [UInt8]) throws {
        let copy = h.encode() + table
        let pad = [UInt8](repeating: 0, count: Int(h.recoveryOffset - h.protectedLength) - copy.count)
        try pwriteAll(fd, copy + pad, at: h.protectedLength, path: path)
        let trailer = Trailer(archiveID: h.archiveID, headerA: h.protectedLength, recoveryOffset: h.recoveryOffset, headerB: h.headerB)
        try pwriteAll(fd, copy + trailer.encode(), at: h.headerB, path: path)
        guard ftruncate(fd, off_t(h.end)) == 0 else { throw XipperError.posix("truncate", path) }
        guard OutputFile.fullSync(fd) else { throw XipperError.posix("fsync", path) }
    }

    private static func pwriteAll(_ fd: Int32, _ bytes: [UInt8], at offset: Int64, path: String) throws {
        try bytes.withUnsafeBytes { try pwriteAll(fd, $0, at: offset, path: path) }
    }

    private static func pwriteAll(_ fd: Int32, _ b: UnsafeRawBufferPointer, at offset: Int64, path: String) throws {
        var done = 0
        while done < b.count {
            let n = pwrite(fd, b.baseAddress! + done, min(b.count - done, 1 << 30), off_t(offset + Int64(done)))
            if n < 0 { if errno == EINTR { continue }; throw XipperError.posix("write", path) }
            done += n
        }
    }

    // MARK: coding

    /// Reads `count` bytes of data slice `d` from `lo`, zero past the protected end or the file's end.
    private static func readPiece(_ reader: FileReader, _ h: Header, slice d: Int, from lo: Int, into buf: UnsafeMutableRawBufferPointer) throws {
        buf.initializeMemory(as: UInt8.self, repeating: 0)
        let start = Int64(d) * Int64(h.sliceSize) + Int64(lo)
        let limit = min(h.protectedLength, reader.size)
        guard start < limit else { return }
        let n = Int(min(Int64(buf.count), limit - start))
        var done = 0
        while done < n {
            let got = try reader.readSome(at: start + Int64(done), into: buf.baseAddress! + done, count: n - done)
            if got == 0 { break }
            done += got
        }
    }

    /// SHA-256 prefixes of the (padded) data slices, in parallel.
    private static func hashDataSlices(_ reader: FileReader, _ h: Header, tracker: ProgressTracker?, cancel: CancellationToken?) throws -> [[UInt8]] {
        let out = Slots<[UInt8]>(h.dataSlices)
        try parallelFor(h.dataSlices, workload: .interactive, cancel: cancel) { d in
            let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: h.sliceSize, alignment: 64)
            defer { buf.deallocate() }
            try readPiece(reader, h, slice: d, from: 0, into: buf)
            out[d] = prefixHash(UnsafeRawBufferPointer(buf))
            tracker?.add(bytes: h.protectedLength / Int64(h.dataSlices))
        }
        return (0..<h.dataSlices).map { out.take($0)! }
    }

    /// Recovery slices `rows`, written in place at their offsets; returns their SHA-256 prefixes.
    /// The data is read once, by windows of the slices' byte range small enough that every row's
    /// window stays within ~256 MiB; each row takes a batch of ~32 MiB of pieces on one thread.
    private static func encode(_ reader: FileReader, fd: Int32, _ h: Header, rows: [Int], tracker: ProgressTracker?,
                               cancel: CancellationToken?) throws -> [[UInt8]] {
        guard !rows.isEmpty else { return [] }
        let s = h.sliceSize, k = h.dataSlices
        let window = max(64, min(s, ((256 << 20) / rows.count) & ~63))
        var hashers = rows.map { _ in SHA256() }
        let bufs = rows.map { _ in UnsafeMutableRawBufferPointer.allocate(byteCount: window, alignment: 64) }
        defer { bufs.forEach { $0.deallocate() } }
        let batchCap = max(1, (32 << 20) / window)
        let pieces = (0..<min(batchCap, k)).map { _ in UnsafeMutableRawBufferPointer.allocate(byteCount: window, alignment: 64) }
        defer { pieces.forEach { $0.deallocate() } }
        var lo = 0
        while lo < s {
            let w = min(window, s - lo)
            for b in bufs { b.initializeMemory(as: UInt8.self, repeating: 0) }
            var d0 = 0
            while d0 < k {
                try cancel?.check()
                let n = min(pieces.count, k - d0)
                for i in 0..<n { try readPiece(reader, h, slice: d0 + i, from: lo, into: UnsafeMutableRawBufferPointer(rebasing: pieces[i][0..<w])) }
                let first = d0
                try parallelFor(rows.count, workload: .interactive, cancel: cancel) { j in
                    let dst = UnsafeMutableRawBufferPointer(rebasing: bufs[j][0..<w])
                    for i in 0..<n {
                        GF16.mulAdd(dst, UnsafeRawBufferPointer(rebasing: pieces[i][0..<w]), coefficient(rows[j], first + i, dataSlices: k))
                    }
                }
                tracker?.add(bytes: Int64(n) * Int64(w) * h.protectedLength / (Int64(s) * Int64(k)))
                d0 += n
            }
            for (j, r) in rows.enumerated() {
                let piece = UnsafeRawBufferPointer(rebasing: bufs[j][0..<w])
                hashers[j].update(bufferPointer: piece)
                try pwriteAll(fd, piece, at: h.recoveryOffset + Int64(r) * Int64(s) + Int64(lo), path: reader.path)
            }
            lo += w
        }
        return hashers.map { Array($0.finalize().prefix(hashSize)) }
    }

    // MARK: scrub and repair

    static func scrub(_ path: String, repair: Bool, progress: ProgressHandler?, cancel: CancellationToken?) throws -> XizScrubReport {
        var reader = try FileReader(path: path)
        var report = XizScrubReport()
        guard let loc = locate(reader) else { return report }
        let h = loc.header, table = loc.table
        report.info = h.info
        report.damagedMetadata = loc.damagedMetadata
        let tracker = ProgressTracker(totalBytes: h.protectedLength + Int64(h.recoverySlices) * Int64(h.sliceSize), totalEntries: 1, handler: progress)
        func expected(_ i: Int) -> ArraySlice<UInt8> { table[(i * hashSize)..<((i + 1) * hashSize)] }

        // Every slice against the table; a slice cut by the end of the file is damaged.
        let total = h.dataSlices + h.recoverySlices
        let bad = Slots<Bool>(total)
        try parallelFor(total, workload: .interactive, cancel: cancel) { i in
            let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: h.sliceSize, alignment: 64)
            defer { buf.deallocate() }
            if i < h.dataSlices {
                try readPiece(reader, h, slice: i, from: 0, into: buf)
                let end = min(Int64(i + 1) * Int64(h.sliceSize), h.protectedLength)
                bad[i] = reader.size < end || prefixHash(UnsafeRawBufferPointer(buf))[...] != expected(i)
            } else {
                let at = h.recoveryOffset + Int64(i - h.dataSlices) * Int64(h.sliceSize)
                if at + Int64(h.sliceSize) > reader.size { bad[i] = true; return }
                try reader.read(at: at, into: buf.baseAddress!, count: h.sliceSize)
                bad[i] = prefixHash(UnsafeRawBufferPointer(buf))[...] != expected(i)
            }
            tracker.add(bytes: Int64(h.sliceSize))
        }
        let badData = (0..<h.dataSlices).filter { bad[$0] == true }
        let badRows = (0..<h.recoverySlices).filter { bad[h.dataSlices + $0] == true }
        let goodRows = (0..<h.recoverySlices).filter { bad[h.dataSlices + $0] != true }
        report.damagedRanges = badData.map { Int64($0) * Int64(h.sliceSize)..<min(Int64($0 + 1) * Int64(h.sliceSize), h.protectedLength) }
        report.damagedRecoverySlices = badRows.count
        report.repairable = badData.count <= goodRows.count
        guard repair, !report.isClean, report.repairable else { tracker.finish(); return report }

        let fd = open(path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { throw XipperError.posix("open", path) }
        defer { close(fd) }
        if !badData.isEmpty {
            try rebuild(reader, fd: fd, h, missing: badData, rows: Array(goodRows.prefix(badData.count)), cancel: cancel)
            reader = try FileReader(path: path)
            // Checked against the table before anything else is trusted.
            for d in badData {
                let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: h.sliceSize, alignment: 64)
                defer { buf.deallocate() }
                try readPiece(reader, h, slice: d, from: 0, into: buf)
                guard prefixHash(UnsafeRawBufferPointer(buf))[...] == expected(d) else {
                    throw XipperError.corrupt("the rebuilt bytes do not match the recovery record")
                }
            }
        }
        if !badRows.isEmpty {
            if reader.size < h.end {
                guard ftruncate(fd, off_t(h.end)) == 0 else { throw XipperError.posix("truncate", path) }
                reader = try FileReader(path: path)
            }
            let hashes = try encode(reader, fd: fd, h, rows: badRows, tracker: nil, cancel: cancel)
            for (r, hash) in zip(badRows, hashes) where hash[...] != expected(h.dataSlices + r) {
                throw XipperError.corrupt("the rebuilt recovery slices do not match the recovery record")
            }
        }
        try writeMetadata(fd, path: path, h, table: table)
        report.repaired = true
        tracker.finish()
        return report
    }

    /// Rebuilds data slices `missing` from recovery slices `rows` (as many) and the intact data:
    /// B_j = R_j ⊕ Σ_{intact d} c(r_j, d)·D_d, then D_missing = C⁻¹ · B, by windows, written in place.
    private static func rebuild(_ reader: FileReader, fd: Int32, _ h: Header, missing: [Int], rows: [Int], cancel: CancellationToken?) throws {
        let s = h.sliceSize, k = h.dataSlices, m = missing.count
        var a = (0..<m).map { j in (0..<m).map { i in coefficient(rows[j], missing[i], dataSlices: k) } }
        let inv = try GF16.invert(&a)
        let missingSet = Set(missing)
        let intact = (0..<k).filter { !missingSet.contains($0) }
        let window = max(64, min(s, ((128 << 20) / m) & ~63))
        let b = (0..<m).map { _ in UnsafeMutableRawBufferPointer.allocate(byteCount: window, alignment: 64) }
        let out = (0..<m).map { _ in UnsafeMutableRawBufferPointer.allocate(byteCount: window, alignment: 64) }
        defer { (b + out).forEach { $0.deallocate() } }
        let batchCap = max(1, (32 << 20) / window)
        let pieces = (0..<min(batchCap, max(1, intact.count))).map { _ in UnsafeMutableRawBufferPointer.allocate(byteCount: window, alignment: 64) }
        defer { pieces.forEach { $0.deallocate() } }
        var lo = 0
        while lo < s {
            let w = min(window, s - lo)
            for (j, r) in rows.enumerated() {
                try reader.read(at: h.recoveryOffset + Int64(r) * Int64(s) + Int64(lo), into: b[j].baseAddress!, count: w)
            }
            var i0 = 0
            while i0 < intact.count {
                try cancel?.check()
                let n = min(pieces.count, intact.count - i0)
                for i in 0..<n { try readPiece(reader, h, slice: intact[i0 + i], from: lo, into: UnsafeMutableRawBufferPointer(rebasing: pieces[i][0..<w])) }
                let first = i0
                try parallelFor(m, workload: .interactive, cancel: cancel) { j in
                    let dst = UnsafeMutableRawBufferPointer(rebasing: b[j][0..<w])
                    for i in 0..<n {
                        GF16.mulAdd(dst, UnsafeRawBufferPointer(rebasing: pieces[i][0..<w]), coefficient(rows[j], intact[first + i], dataSlices: k))
                    }
                }
                i0 += n
            }
            try parallelFor(m, workload: .interactive, cancel: cancel) { i in
                let dst = UnsafeMutableRawBufferPointer(rebasing: out[i][0..<w])
                dst.initializeMemory(as: UInt8.self, repeating: 0)
                for j in 0..<m { GF16.mulAdd(dst, UnsafeRawBufferPointer(rebasing: b[j][0..<w]), inv[i][j]) }
            }
            for (i, d) in missing.enumerated() {
                let start = Int64(d) * Int64(s) + Int64(lo)
                guard start < h.protectedLength else { continue }
                let n = Int(min(Int64(w), h.protectedLength - start))
                try pwriteAll(fd, UnsafeRawBufferPointer(rebasing: out[i][0..<n]), at: start, path: reader.path)
            }
            lo += w
        }
        guard OutputFile.fullSync(fd) else { throw XipperError.posix("fsync", reader.path) }
    }
}
