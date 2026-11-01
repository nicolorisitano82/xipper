import CLzmaSDK
import CoreFoundation
import Foundation

/// Parsed ZIP archive (central directory). Entry data is read on demand with `pread`.
final class ZipArchive: @unchecked Sendable {
    let reader: FileReader
    let records: [ZipEntryRecord]
    /// Offset added to stored offsets when data was prepended to the archive (self-extractors).
    private let bias: Int64
    private let centralStart: Int64
    /// Code page of the names written without the UTF-8 flag (forced or guessed); nil when every
    /// name is Unicode (flag, Info-ZIP Unicode extra, or valid UTF-8).
    let nameEncoding: ZipNameEncoding?

    /// The files of a split archive, in order, or just `path`.
    /// PKZIP/WinZip/Info-ZIP split: `name.z01`, `name.z02`, …, `name.zip` (offsets are per part).
    /// 7-Zip/`split` style: `name.zip.001`, `name.zip.002`, … (plain pieces of one file).
    static func volumes(for path: String) -> [String] {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let stem = url.deletingPathExtension().path
        if ext.count == 3, ext.allSatisfy(\.isNumber), Int(ext) == 1 {
            var parts: [String] = []
            var n = 1
            while case let p = stem + "." + String(format: "%03d", n), fm.fileExists(atPath: p) {
                parts.append(p)
                n += 1
            }
            return parts.isEmpty ? [path] : parts
        }
        let isZPart = ext.count == 3 && ext.hasPrefix("z") && ext.dropFirst().allSatisfy(\.isNumber)
        guard ext == "zip" || isZPart else { return [path] }
        var parts: [String] = []
        var n = 1
        while case let p = stem + ".z" + String(format: "%02d", n), fm.fileExists(atPath: p) {
            parts.append(p)
            n += 1
        }
        let last = stem + ".zip"
        guard !parts.isEmpty, fm.fileExists(atPath: last) else { return [path] }
        return parts + [last]
    }

    init(path: String) throws {
        reader = try FileReader(parts: Self.volumes(for: path))
        let starts = reader.partStarts
        let size = reader.size
        if size < 22 { throw XipperError.corrupt("not a ZIP archive (too small)") }

        // 1. End of central directory: last 22 bytes + up to 64 KiB of comment.
        let tailLen = Int(min(size, 22 + 0xFFFF + 20))
        let tailStart = size - Int64(tailLen)
        let tail = try reader.read(at: tailStart, count: tailLen)
        // The record whose comment reaches exactly the end of the file. Two such records (one hidden
        // in the other's comment) make the archive mean different things to different readers:
        // refused. Without an exact one (bytes appended after the archive), the last plausible one.
        var exact: [Int] = [], loose = -1
        tail.withUnsafeBytes { t in
            var i = tailLen - 22
            while i >= 0 {
                if t.loadUnaligned(fromByteOffset: i, as: UInt32.self).littleEndian == Zip.endSignature {
                    let commentLen = Int(t.loadUnaligned(fromByteOffset: i + 20, as: UInt16.self).littleEndian)
                    if i + 22 + commentLen == tailLen { exact.append(i) }
                    if i + 22 + commentLen <= tailLen && loose < 0 { loose = i }
                }
                i -= 1
            }
        }
        if exact.count > 1 { throw XipperError.corrupt("ambiguous ZIP: several end of central directory records") }
        let eocd = exact.first ?? loose
        if eocd < 0 { throw XipperError.corrupt("end of central directory not found (not a ZIP, or truncated)") }

        var entryCount: Int64 = 0, cdSize: Int64 = 0, cdOffset: Int64 = 0
        var eocdAbs = tailStart + Int64(eocd)
        var raw = (count: UInt16(0), size: UInt32(0), offset: UInt32(0))
        try tail.withUnsafeBytes { t in
            var r = ByteReader(t, at: eocd + 4)
            _ = try r.u16()  // this disk
            let cdDisk = try r.u16()
            _ = try r.u16()
            raw = (try r.u16(), try r.u32(), try r.u32())
            entryCount = Int64(raw.count)
            cdSize = Int64(raw.size)
            cdOffset = Int64(raw.offset)
            if cdDisk != 0xFFFF { cdOffset += try Self.partStart(Int(cdDisk), starts) }
        }
        var zip64 = false

        // 2. ZIP64 locator right before the EOCD.
        if eocdAbs >= 20 {
            let loc = try reader.read(at: eocdAbs - 20, count: 20)
            let isLocator = loc.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian == Zip.zip64LocatorSignature }
            if isLocator {
                let z64Offset = loc.withUnsafeBytes { Int64($0.loadUnaligned(fromByteOffset: 8, as: UInt64.self).littleEndian) }
                // The record may be shifted by prepended data too: it sits right before the locator.
                let expected = eocdAbs - 20 - 56
                let at = (z64Offset >= 0 && z64Offset + 56 <= size) ? z64Offset : expected
                var rec = try reader.read(at: at, count: 56)
                if rec.withUnsafeBytes({ $0.loadUnaligned(as: UInt32.self).littleEndian }) != Zip.zip64EndSignature, expected >= 0 {
                    rec = try reader.read(at: expected, count: 56)
                }
                try rec.withUnsafeBytes { t in
                    var r = ByteReader(t)
                    if try r.u32() != Zip.zip64EndSignature { throw XipperError.corrupt("bad ZIP64 end record") }
                    try r.skip(8 + 2 + 2 + 4)
                    let cdDisk = Int(try r.u32())
                    try r.skip(8)
                    let count = try r.u64(), size = try r.u64(), offset = try r.u64()
                    // A field the classic record does not mark as "see ZIP64" must agree with it.
                    if (raw.count != 0xFFFF && UInt64(raw.count) != count) || (raw.size != 0xFFFF_FFFF && UInt64(raw.size) != size)
                        || (raw.offset != 0xFFFF_FFFF && UInt64(raw.offset) != offset) {
                        throw XipperError.corrupt("ambiguous ZIP: the ZIP64 end record disagrees with the classic one")
                    }
                    entryCount = Int64(bitPattern: count)
                    cdSize = Int64(bitPattern: size)
                    cdOffset = Int64(bitPattern: offset) + (try Self.partStart(cdDisk, starts))
                }
                eocdAbs = min(eocdAbs, at)
                zip64 = true
            }
        }
        if cdSize < 0 || cdSize > size || cdOffset < 0 || entryCount < 0 {
            throw XipperError.corrupt("invalid central directory location")
        }

        // 3. Prepended data: the central directory really ends where the end records start.
        let actualStart = eocdAbs - cdSize
        let shift = actualStart - cdOffset
        bias = shift
        if actualStart < 0 { throw XipperError.corrupt("central directory larger than archive") }
        if cdSize > 2 << 30 { throw XipperError.limitExceeded("central directory over 2 GiB") }
        centralStart = actualStart

        // 4. Central directory records.
        let cd = try reader.read(at: actualStart, count: Int(cdSize))
        var records: [ZipEntryRecord] = []
        records.reserveCapacity(Int(min(entryCount, 1 << 20)))
        var trailing = 0
        func parseAll(_ legacy: ZipNameEncoding) throws {
            records.removeAll(keepingCapacity: true)
            try cd.withUnsafeBytes { buf in
                var r = ByteReader(buf)
                while r.remaining >= 46 {
                    if buf.loadUnaligned(fromByteOffset: r.pos, as: UInt32.self).littleEndian != Zip.centralSignature { break }
                    try r.skip(4)
                    records.append(try Self.parseCentral(&r, bias: shift, partStarts: starts, legacy: legacy))
                }
                // Only the optional digital signature record may follow the last entry.
                if r.remaining >= 4, buf.loadUnaligned(fromByteOffset: r.pos, as: UInt32.self).littleEndian == 0x0505_4B50 { trailing = 0 }
                else { trailing = r.remaining }
            }
        }
        try parseAll(.cp437)
        // Names in a legacy code page: guessed from all of them together, unless forced.
        let legacyNames = records.filter(Self.hasLegacyName).map(\.rawName)
        if legacyNames.isEmpty {
            nameEncoding = nil
        } else {
            let chosen = Xipper.zipNameEncodingOverride(path) ?? ZipNameEncoding.guess(legacyNames)
            nameEncoding = chosen
            if chosen != .cp437 { try parseAll(chosen) }
        }
        if records.isEmpty && entryCount > 0 { throw XipperError.corrupt("central directory has no entries") }
        // Entries a reader would see only by trusting the count, or by scanning past it, differ
        // between readers. Old writers wrap the 16-bit count past 65535 entries without ZIP64.
        let countOK = Int64(records.count) == entryCount || (!zip64 && Int64(records.count & 0xFFFF) == entryCount)
        if !countOK || trailing != 0 {
            throw XipperError.corrupt("ambiguous ZIP: the central directory holds \(records.count) entries, the end record says \(entryCount)")
        }
        self.records = records
        try checkOverlaps()
        try checkNames()
    }

    /// Start of disk `n` in the joined stream; a plain archive has only disk 0.
    private static func partStart(_ n: Int, _ starts: [Int64]) throws -> Int64 {
        if starts.count == 1 { return 0 }  // single file (or `.001` pieces): offsets are already global
        guard n < starts.count else { throw XipperError.corrupt("split archive: part \(n + 1) is missing") }
        return starts[n]
    }

    /// A name without the UTF-8 flag nor a Unicode extra, that is not valid UTF-8 either.
    static func hasLegacyName(_ r: ZipEntryRecord) -> Bool {
        r.flags & Zip.Flag.utf8 == 0 && r.rawName.contains { $0 >= 0x80 } && String(bytes: r.rawName, encoding: .utf8) == nil
            && !ZipExtraFields.contains(r.central.extra, Zip.Extra.unicodePath)
    }

    private static func parseCentral(_ r: inout ByteReader, bias: Int64, partStarts: [Int64],
                                     legacy: ZipNameEncoding = .cp437) throws -> ZipEntryRecord {
        let madeBy = try r.u16()
        let needed = try r.u16()
        let flags = try r.u16()
        let method = try r.u16()
        let dosTime = try r.u16(), dosDate = try r.u16()
        let crc = try r.u32()
        var csize = Int64(try r.u32()), usize = Int64(try r.u32())
        let nameLen = Int(try r.u16()), extraLen = Int(try r.u16()), commentLen = Int(try r.u16())
        var disk = Int(try r.u16())
        let internalAttributes = try r.u16()
        let external = try r.u32()
        var offset = Int64(try r.u32())
        let rawName = Array(try r.bytes(nameLen))
        let extra = try r.bytes(extraLen)
        let comment = Array(try r.bytes(commentLen))

        var mtime: Date?
        var unicodeName: String?
        var encryption: EntryEncryption = flags & Zip.Flag.encrypted != 0 ? .zipCrypto : .none
        var x = ByteReader(extra)
        while x.remaining >= 4 {
            let id = try x.u16(), len = Int(try x.u16())
            guard len <= x.remaining else { break }  // tolerate sloppy padding
            var f = ByteReader(try x.bytes(len))
            switch id {
            case Zip.Extra.zip64:
                if usize == 0xFFFF_FFFF, f.remaining >= 8 { usize = Int64(bitPattern: try f.u64()) }
                if csize == 0xFFFF_FFFF, f.remaining >= 8 { csize = Int64(bitPattern: try f.u64()) }
                if offset == 0xFFFF_FFFF, f.remaining >= 8 { offset = Int64(bitPattern: try f.u64()) }
                if disk == 0xFFFF, f.remaining >= 4 { disk = Int(try f.u32()) }
            case Zip.Extra.extendedTimestamp:
                if f.remaining >= 5, try f.u8() & 1 != 0 { mtime = Date(timeIntervalSince1970: Double(try f.u32())) }
            case Zip.Extra.unicodePath:
                if f.remaining > 5, try f.u8() == 1 {
                    let nameCRC = try f.u32()
                    let utf = Array(try f.bytes(f.remaining))
                    if nameCRC == CRC32.checksum(rawName) { unicodeName = String(bytes: utf, encoding: .utf8) }
                }
            case Zip.Extra.aes:
                if f.remaining >= 7 {
                    let version = try f.u16()
                    _ = try f.u16()  // "AE"
                    let strength = try f.u8()
                    let actual = try f.u16()
                    encryption = .aes(strength: strength, vendorVersion: version, actualMethod: actual)
                }
            default:
                break
            }
        }
        if flags & Zip.Flag.strongEncryption != 0 { encryption = .zipCrypto }  // reported as unsupported on read

        if rawName.contains(0) { throw XipperError.corrupt("ambiguous ZIP: a name contains a NUL byte") }
        let plainName = decodeName(rawName, utf8Flag: flags & Zip.Flag.utf8 != 0, legacy: legacy)
        // With the UTF-8 flag the name is already Unicode: a different Info-ZIP Unicode name would
        // give the entry two names, depending on the reader.
        if flags & Zip.Flag.utf8 != 0, let unicodeName, unicodeName != plainName {
            throw XipperError.corrupt("ambiguous ZIP: \(plainName) also has a different Unicode name")
        }
        var name = unicodeName ?? plainName
        let host = UInt8(madeBy >> 8)
        let unixMode = (host == Zip.Host.unix.rawValue || host == Zip.Host.osx.rawValue) ? UInt16(external >> 16) : 0
        var kind: ArchiveEntry.Kind = .file
        switch unixMode & 0o170000 {
        case 0o040000: kind = .directory
        case 0o120000: kind = .symlink
        default: if name.hasSuffix("/") || (unixMode == 0 && external & 0x10 != 0) { kind = .directory }
        }
        if name.hasSuffix("/") { kind = .directory }
        if host == Zip.Host.msdos.rawValue || host == Zip.Host.ntfs.rawValue || host == Zip.Host.vfat.rawValue {
            name = name.replacingOccurrences(of: "\\", with: "/")
        }
        while name.hasSuffix("/") { name.removeLast() }

        let actualMethod: UInt16 = if case let .aes(_, _, m) = encryption { m } else { method }
        // AE-2 entries hide the CRC (stored as 0).
        let storedCRC: UInt32? = kind == .file && !(crc == 0 && usize > 0) ? crc : nil
        let entry = ArchiveEntry(path: name, kind: kind, uncompressedSize: usize, compressedSize: csize,
                                 modified: mtime ?? DOSDateTime.decode(time: dosTime, date: dosDate),
                                 permissions: unixMode != 0 ? unixMode & 0o7777 : nil,
                                 encryption: encryption, method: zipMethodName(actualMethod), linkTarget: nil, crc32: storedCRC)
        var rec = ZipEntryRecord(entry: entry, rawName: rawName, method: method, flags: flags, crc: crc,
                                 compressedSize: csize, uncompressedSize: usize,
                                 localHeaderOffset: offset + (try partStart(disk, partStarts)) + bias,
                                 dosTime: dosTime, hostSystem: host)
        rec.central = .init(versionMadeBy: madeBy, versionNeeded: needed, dosDate: dosDate, internalAttributes: internalAttributes,
                            externalAttributes: external, extra: Array(extra), comment: comment)
        return rec
    }

    /// Names without the UTF-8 flag: valid non-ASCII UTF-8 is taken as UTF-8 (what macOS and Linux
    /// tools write), anything else in the archive's legacy code page (CP437, the ZIP default,
    /// unless another one was guessed or forced: ZipNameEncoding).
    static func decodeName(_ raw: [UInt8], utf8Flag: Bool, legacy: ZipNameEncoding = .cp437) -> String {
        if utf8Flag || raw.allSatisfy({ $0 < 0x80 }) { return String(decoding: raw, as: UTF8.self) }
        if let s = String(bytes: raw, encoding: .utf8) { return s }
        return legacy.decode(raw) ?? ZipNameEncoding.cp437.decode(raw) ?? String(decoding: raw, as: UTF8.self)
    }

    /// Rejects entries whose data ranges overlap or exceed the archive: the "overlapping files"
    /// zip-bomb technique reuses one compressed stream for many entries.
    private func checkOverlaps() throws {
        let sorted = records.filter { $0.compressedSize > 0 }.sorted { $0.localHeaderOffset < $1.localHeaderOffset }
        for (i, r) in sorted.enumerated() {
            let end = r.localHeaderOffset + 30 + Int64(r.rawName.count) + r.compressedSize
            if r.localHeaderOffset < 0 || end > centralStart + 1 {
                throw XipperError.corrupt("entry \(r.entry.path) extends past the end of the data")
            }
            if i + 1 < sorted.count && sorted[i + 1].localHeaderOffset < end - Int64(r.rawName.count) {
                throw XipperError.corrupt("overlapping entries (possible zip bomb): \(r.entry.path)")
            }
        }
    }

    /// Two entries with the same path (NFC, as APFS sees it): readers keep the first, the last or
    /// both, so what is extracted depends on the tool. A folder entry repeated is harmless.
    private func checkNames() throws {
        var seen: [String: ArchiveEntry.Kind] = [:]
        for r in records {
            let key = r.entry.path.precomposedStringWithCanonicalMapping
            if let k = seen[key], k != .directory || r.entry.kind != .directory {
                throw XipperError.corrupt("ambiguous ZIP: two entries named \(r.entry.path)")
            }
            seen[key] = r.entry.kind
        }
    }

    /// Absolute offset of an entry's data, read from its local header. The local header must
    /// describe the same entry as the central directory (name, method, encryption and, without a
    /// data descriptor, CRC and sizes): streaming readers use only the local one.
    func dataOffset(_ rec: ZipEntryRecord) throws -> Int64 {
        let h = try reader.read(at: rec.localHeaderOffset, count: 30 + rec.rawName.count)
        let (sig, flags, method, crc, csize, usize, n, e) = h.withUnsafeBytes {
            ($0.loadUnaligned(as: UInt32.self).littleEndian, $0.loadUnaligned(fromByteOffset: 6, as: UInt16.self).littleEndian,
             $0.loadUnaligned(fromByteOffset: 8, as: UInt16.self).littleEndian, $0.loadUnaligned(fromByteOffset: 14, as: UInt32.self).littleEndian,
             $0.loadUnaligned(fromByteOffset: 18, as: UInt32.self).littleEndian, $0.loadUnaligned(fromByteOffset: 22, as: UInt32.self).littleEndian,
             Int64($0.loadUnaligned(fromByteOffset: 26, as: UInt16.self).littleEndian),
             Int64($0.loadUnaligned(fromByteOffset: 28, as: UInt16.self).littleEndian))
        }
        let path = rec.entry.path
        if sig != Zip.localSignature { throw XipperError.corrupt("bad local header for \(path)") }
        func differs(_ what: String) -> XipperError { .corrupt("ambiguous ZIP: local header and central directory disagree on the \(what) of \(path)") }
        if n != Int64(rec.rawName.count) || !h[30...].elementsEqual(rec.rawName) { throw differs("name") }
        if method != rec.method { throw differs("method") }
        if (flags ^ rec.flags) & Zip.Flag.encrypted != 0 { throw differs("encryption") }
        if flags & Zip.Flag.dataDescriptor == 0 {
            if crc != rec.crc { throw differs("CRC") }
            if csize != 0xFFFF_FFFF && Int64(csize) != rec.compressedSize { throw differs("compressed size") }
            if usize != 0xFFFF_FFFF && Int64(usize) != rec.uncompressedSize { throw differs("size") }
        }
        let start = rec.localHeaderOffset + 30 + n + e
        if start + rec.compressedSize > centralStart { throw XipperError.corrupt("entry \(path) is truncated") }
        return start
    }

    /// Local headers no central directory entry points to, in the gaps between entries: a
    /// streaming reader (or a scanner) sees files that Xipper does not. Reads every local header,
    /// so it runs when testing, not when opening.
    func concealedEntries() throws -> Int64? {
        let sorted = records.sorted { $0.localHeaderOffset < $1.localHeaderOffset }
        for (i, r) in sorted.enumerated() {
            let gapStart = try dataOffset(r) + r.compressedSize
            let gapEnd = i + 1 < sorted.count ? sorted[i + 1].localHeaderOffset : centralStart
            guard gapEnd - gapStart >= 30 else { continue }  // room for a data descriptor only
            let gap = try reader.read(at: gapStart, count: Int(min(gapEnd - gapStart, 1 << 20)))
            let found = gap.withUnsafeBytes { b in
                (0...(b.count - 4)).first { b.loadUnaligned(fromByteOffset: $0, as: UInt32.self).littleEndian == Zip.localSignature }
            }
            if let found { return gapStart + Int64(found) }
        }
        return nil
    }
}

// MARK: - Entry decoding

enum ZipEntryDecoder {
    /// Below this size deflate entries are inflated in one libdeflate call (fastest path).
    static let wholeBufferLimit: Int64 = 64 << 20
    static let pieceSize = 4 << 20

    /// Streams the decrypted, decompressed and verified content of `rec` into `sink`.
    static func decode(_ rec: ZipEntryRecord, in archive: ZipArchive, password: [UInt8]?,
                       cancel: CancellationToken?, sink: ByteSink) throws {
        try withoutActuallyEscaping(sink) { sink in
            try decodeEscaping(rec, in: archive, password: password, cancel: cancel, sink: sink)
        }
    }

    private static func decodeEscaping(_ rec: ZipEntryRecord, in archive: ZipArchive, password: [UInt8]?,
                                       cancel: CancellationToken?, sink: @escaping ByteSink) throws {
        let name = rec.entry.path
        if rec.flags & Zip.Flag.strongEncryption != 0 { throw XipperError.unsupported("PKWARE strong encryption (\(name))") }
        var start = try archive.dataOffset(rec)
        var end = start + rec.compressedSize
        let reader = archive.reader

        // Encryption layer.
        var aes: WinZipAESDecryptor?
        var zipCrypto: ZipCryptoDecryptor?
        var method = rec.method
        var checkCRC = true
        switch rec.entry.encryption {
        case .none: break
        case let .aes(strengthRaw, version, actual):
            guard let password else { throw XipperError.passwordRequired(entry: name) }
            guard let strength = WinZipAES.Strength(rawValue: strengthRaw) else { throw XipperError.unsupported("AES strength \(strengthRaw)") }
            let hl = strength.saltLength + WinZipAES.verifierLength
            if rec.compressedSize < Int64(hl + WinZipAES.macLength) { throw XipperError.corrupt("encrypted entry too short: \(name)") }
            let head = try reader.read(at: start, count: hl)
            aes = try WinZipAESDecryptor(password: password, salt: Array(head[..<strength.saltLength]),
                                         verifier: Array(head[strength.saltLength...]), strength: strength, entry: name)
            start += Int64(hl)
            end -= Int64(WinZipAES.macLength)
            method = actual
            checkCRC = version != 2
        case .zipCrypto:
            guard let password else { throw XipperError.passwordRequired(entry: name) }
            if rec.compressedSize < 12 { throw XipperError.corrupt("encrypted entry too short: \(name)") }
            let head = try reader.read(at: start, count: 12)
            let check = rec.flags & Zip.Flag.dataDescriptor != 0 ? UInt8(rec.dosTime >> 8) : UInt8(rec.crc >> 24)
            zipCrypto = try head.withUnsafeBytes { try ZipCryptoDecryptor(password: password, header: $0, check: check, entry: name) }
            start += 12
        }

        // Verification layer: CRC and exact size (an entry may never produce more than declared).
        var crc: UInt32 = 0
        var produced: Int64 = 0
        let expected = rec.uncompressedSize
        let verifying: ByteSink = { chunk in
            produced += Int64(chunk.count)
            if produced > expected { throw XipperError.corrupt("\(name) is larger than declared (possible zip bomb)") }
            crc = CRC32.update(crc, chunk)
            try sink(chunk)
        }

        if method == Zip.Method.ppmd.rawValue {
            // PPMd decodes by pulling its input: a source over the entry's (decrypted) bytes.
            let source = ZipEntrySource(reader: reader, from: start, to: end, aes: aes, zipCrypto: zipCrypto, cancel: cancel)
            let ppmd = try ZipPPMdSource(source, size: expected, entry: name)
            let piece = UnsafeMutableRawPointer.allocate(byteCount: pieceSize, alignment: 16)
            defer { piece.deallocate() }
            while true {
                let n = try ppmd.read(into: piece, max: pieceSize)
                if n == 0 { break }
                try verifying(UnsafeRawBufferPointer(start: piece, count: n))
            }
        } else if method == Zip.Method.deflate.rawValue && aes == nil && zipCrypto == nil && expected <= wholeBufferLimit {
            let src = try reader.read(at: start, count: Int(end - start))
            let out = UnsafeMutableRawBufferPointer.allocate(byteCount: max(Int(expected), 1), alignment: 16)
            defer { out.deallocate() }
            let dst = UnsafeMutableRawBufferPointer(rebasing: out[0..<Int(expected)])
            try src.withUnsafeBytes { try Deflate.decompress($0, into: dst) }
            try verifying(UnsafeRawBufferPointer(dst))
        } else {
            var decoder: StreamTransform?
            switch Zip.Method(rawValue: method) {
            case .store: decoder = PassthroughTransform()
            case .deflate: decoder = try InflateDecoder(gzip: false)
            case .bzip2: decoder = ParallelBzip2Decoder()
            case .zstd: decoder = try ZstdDecoder()
            case .xz: decoder = XzDecoder(threads: 1)
            case .lzma: decoder = nil  // created from the first piece (properties header)
            case .deflate64: decoder = try Deflate64Decoder()
            default: throw XipperError.unsupported("compression method \(method) (\(name))")
            }
            let piece = UnsafeMutableRawPointer.allocate(byteCount: pieceSize, alignment: 16384)
            defer { piece.deallocate() }
            var pos = start
            while pos < end {
                try cancel?.check()
                let n = Int(min(Int64(pieceSize), end - pos))
                try reader.read(at: pos, into: piece, count: n)
                let buf = UnsafeMutableRawBufferPointer(start: piece, count: n)
                aes?.decrypt(buf)
                zipCrypto?.decrypt(buf)
                var data = UnsafeRawBufferPointer(buf)
                if decoder == nil {
                    if data.count < 9 { throw XipperError.corrupt("LZMA header truncated (\(name))") }
                    decoder = try LZMACoder.zipLZMADecoder(header: UnsafeRawBufferPointer(rebasing: data[0..<9]), knownSize: expected)
                    data = UnsafeRawBufferPointer(rebasing: data[9...])
                }
                try decoder!.process(data, verifying)
                pos += Int64(n)
            }
            if decoder == nil {
                if expected != 0 { throw XipperError.corrupt("LZMA data missing (\(name))") }
            } else if method == Zip.Method.lzma.rawValue {
                try? decoder!.finish(verifying)  // raw LZMA1 with known size may end without an end marker
            } else {
                try decoder!.finish(verifying)
            }
        }

        if let aes {
            let mac = try reader.read(at: end, count: WinZipAES.macLength)
            try mac.withUnsafeBytes { try aes.verify($0, entry: name) }
        }
        if produced < expected { throw XipperError.truncated(entry: name, read: produced, expected: expected) }
        if produced != expected { throw XipperError.corrupt("\(name): expected \(expected) bytes, got \(produced)") }
        if checkCRC && crc != rec.crc { throw XipperError.checksumMismatch(entry: name, expected: rec.crc, actual: crc) }
    }
}

/// An entry's stored bytes, decrypted, as a pull source (for PPMd).
final class ZipEntrySource: ByteSource {
    private let reader: FileReader
    private var pos: Int64
    private let end: Int64
    private let aes: WinZipAESDecryptor?
    private let zipCrypto: ZipCryptoDecryptor?
    private let cancel: CancellationToken?

    init(reader: FileReader, from: Int64, to: Int64, aes: WinZipAESDecryptor?, zipCrypto: ZipCryptoDecryptor?, cancel: CancellationToken?) {
        self.reader = reader
        pos = from
        end = to
        self.aes = aes
        self.zipCrypto = zipCrypto
        self.cancel = cancel
    }

    func read(into buf: UnsafeMutableRawPointer, max: Int) throws -> Int {
        try cancel?.check()
        let n = Int(min(Int64(max), end - pos))
        if n <= 0 { return 0 }
        try reader.read(at: pos, into: buf, count: n)
        let b = UnsafeMutableRawBufferPointer(start: buf, count: n)
        aes?.decrypt(b)
        zipCrypto?.decrypt(b)
        pos += Int64(n)
        return n
    }
}

/// ZIP method 98: PPMd variant I rev. 1. The data starts with two property bytes (APPNOTE 5.10):
/// model order − 1 (4 bits), memory in MiB − 1 (8 bits), restoration method (4 bits).
final class ZipPPMdSource: ByteSource {
    private let input: ByteSource
    private var decoder: OpaquePointer?
    private var left: Int64
    private var inputError: Error?
    private let entry: String

    init(_ input: ByteSource, size: Int64, entry: String) throws {
        self.input = input
        self.entry = entry
        left = size
        var props = [UInt8](repeating: 0, count: 2)
        guard try props.withUnsafeMutableBytes({ try input.read(into: $0.baseAddress!, max: 2) }) == 2 else {
            throw XipperError.corrupt("PPMd properties missing (\(entry))")
        }
        let v = UInt16(props[0]) | UInt16(props[1]) << 8
        let order = UInt32(v & 0x0F) + 1, mem = (UInt32(v >> 4) & 0xFF) + 1, restore = UInt32(v >> 12)
        let fill: xs_ppmd_fill = { ctx, buf, cap in
            let me = Unmanaged<ZipPPMdSource>.fromOpaque(ctx!).takeUnretainedValue()
            do { return try me.input.read(into: buf!, max: cap) } catch {
                me.inputError = error
                return 0
            }
        }
        guard size > 0 else { return }
        guard let d = xs_ppmd8_dec_new(order, mem << 20, restore, fill, Unmanaged.passUnretained(self).toOpaque()) else {
            throw XipperError.unsupported("PPMd order \(order), \(mem) MiB, restoration \(restore) (\(entry))")
        }
        decoder = d
    }

    deinit { xs_ppmd8_dec_free(decoder) }

    func read(into buf: UnsafeMutableRawPointer, max: Int) throws -> Int {
        let n = Int(min(Int64(max), left))
        if n == 0 { return 0 }
        let r = xs_ppmd8_dec_read(decoder, buf.assumingMemoryBound(to: UInt8.self), n)
        if let e = inputError { throw e }
        if r == -2 { throw XipperError.truncated(entry: entry, read: 0, expected: left) }
        if r != 0 { throw XipperError.corrupt("invalid PPMd data (\(entry))") }
        left -= Int64(n)
        return n
    }
}

enum ZipExtraFields {
    static func contains(_ extra: [UInt8], _ id: UInt16) -> Bool {
        var i = 0
        while i + 4 <= extra.count {
            let fid = UInt16(extra[i]) | UInt16(extra[i + 1]) << 8
            let len = Int(UInt16(extra[i + 2]) | UInt16(extra[i + 3]) << 8)
            if fid == id { return true }
            i += 4 + len
        }
        return false
    }
}
