import CoreFoundation
import Foundation

/// Parsed ZIP archive (central directory). Entry data is read on demand with `pread`.
final class ZipArchive: @unchecked Sendable {
    let reader: FileReader
    let records: [ZipEntryRecord]
    /// Offset added to stored offsets when data was prepended to the archive (self-extractors).
    private let bias: Int64
    private let centralStart: Int64

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
        var eocd = -1
        tail.withUnsafeBytes { t in
            var i = tailLen - 22
            while i >= 0 {
                if t.loadUnaligned(fromByteOffset: i, as: UInt32.self).littleEndian == Zip.endSignature {
                    let commentLen = Int(t.loadUnaligned(fromByteOffset: i + 20, as: UInt16.self).littleEndian)
                    if i + 22 + commentLen <= tailLen { eocd = i; return }
                }
                i -= 1
            }
        }
        if eocd < 0 { throw XipperError.corrupt("end of central directory not found (not a ZIP, or truncated)") }

        var entryCount: Int64 = 0, cdSize: Int64 = 0, cdOffset: Int64 = 0
        var eocdAbs = tailStart + Int64(eocd)
        try tail.withUnsafeBytes { t in
            var r = ByteReader(t, at: eocd + 4)
            _ = try r.u16()  // this disk
            let cdDisk = try r.u16()
            _ = try r.u16()
            entryCount = Int64(try r.u16())
            cdSize = Int64(try r.u32())
            cdOffset = Int64(try r.u32())
            if cdDisk != 0xFFFF { cdOffset += try Self.partStart(Int(cdDisk), starts) }
        }

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
                    entryCount = Int64(try r.u64())
                    cdSize = Int64(try r.u64())
                    cdOffset = Int64(try r.u64()) + (try Self.partStart(cdDisk, starts))
                }
                eocdAbs = min(eocdAbs, at)
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
        try cd.withUnsafeBytes { buf in
            var r = ByteReader(buf)
            while r.remaining >= 46 {
                let sig = try r.u32()
                if sig != Zip.centralSignature { break }
                records.append(try Self.parseCentral(&r, bias: shift, partStarts: starts))
            }
        }
        if records.isEmpty && entryCount > 0 { throw XipperError.corrupt("central directory has no entries") }
        self.records = records
        try checkOverlaps()
    }

    /// Start of disk `n` in the joined stream; a plain archive has only disk 0.
    private static func partStart(_ n: Int, _ starts: [Int64]) throws -> Int64 {
        if starts.count == 1 { return 0 }  // single file (or `.001` pieces): offsets are already global
        guard n < starts.count else { throw XipperError.corrupt("split archive: part \(n + 1) is missing") }
        return starts[n]
    }

    private static func parseCentral(_ r: inout ByteReader, bias: Int64, partStarts: [Int64]) throws -> ZipEntryRecord {
        let madeBy = try r.u16()
        _ = try r.u16()  // version needed
        let flags = try r.u16()
        let method = try r.u16()
        let dosTime = try r.u16(), dosDate = try r.u16()
        let crc = try r.u32()
        var csize = Int64(try r.u32()), usize = Int64(try r.u32())
        let nameLen = Int(try r.u16()), extraLen = Int(try r.u16()), commentLen = Int(try r.u16())
        var disk = Int(try r.u16())
        _ = try r.u16()  // internal attributes
        let external = try r.u32()
        var offset = Int64(try r.u32())
        let rawName = Array(try r.bytes(nameLen))
        let extra = try r.bytes(extraLen)
        try r.skip(commentLen)

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

        var name = unicodeName ?? decodeName(rawName, utf8Flag: flags & Zip.Flag.utf8 != 0)
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
        let entry = ArchiveEntry(path: name, kind: kind, uncompressedSize: usize, compressedSize: csize,
                                 modified: mtime ?? DOSDateTime.decode(time: dosTime, date: dosDate),
                                 permissions: unixMode != 0 ? unixMode & 0o7777 : nil,
                                 encryption: encryption, method: zipMethodName(actualMethod), linkTarget: nil)
        return ZipEntryRecord(entry: entry, rawName: rawName, method: method, flags: flags, crc: crc,
                              compressedSize: csize, uncompressedSize: usize,
                              localHeaderOffset: offset + (try partStart(disk, partStarts)) + bias,
                              dosTime: dosTime, hostSystem: host)
    }

    /// Names without the UTF-8 flag: valid non-ASCII UTF-8 is taken as UTF-8 (what macOS and Linux
    /// tools write), anything else as IBM PC code page 437 (the ZIP default).
    static func decodeName(_ raw: [UInt8], utf8Flag: Bool) -> String {
        if utf8Flag || raw.allSatisfy({ $0 < 0x80 }) { return String(decoding: raw, as: UTF8.self) }
        if let s = String(bytes: raw, encoding: .utf8) { return s }
        let cp437 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue))
        return String(data: Data(raw), encoding: String.Encoding(rawValue: cp437)) ?? String(decoding: raw, as: UTF8.self)
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

    /// Absolute offset of an entry's data, read from its local header.
    func dataOffset(_ rec: ZipEntryRecord) throws -> Int64 {
        let h = try reader.read(at: rec.localHeaderOffset, count: 30)
        let (sig, n, e) = h.withUnsafeBytes {
            ($0.loadUnaligned(as: UInt32.self).littleEndian,
             Int64($0.loadUnaligned(fromByteOffset: 26, as: UInt16.self).littleEndian),
             Int64($0.loadUnaligned(fromByteOffset: 28, as: UInt16.self).littleEndian))
        }
        if sig != Zip.localSignature { throw XipperError.corrupt("bad local header for \(rec.entry.path)") }
        let start = rec.localHeaderOffset + 30 + n + e
        if start + rec.compressedSize > centralStart { throw XipperError.corrupt("entry \(rec.entry.path) is truncated") }
        return start
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

        // Fast path: unencrypted deflate of moderate size.
        if method == Zip.Method.deflate.rawValue && aes == nil && zipCrypto == nil && expected <= wholeBufferLimit {
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
            case .bzip2: decoder = try Bzip2Decoder()
            case .zstd: decoder = try ZstdDecoder()
            case .xz: decoder = try LZMACoder.xzDecoder(threads: 1)
            case .lzma: decoder = nil  // created from the first piece (properties header)
            case .deflate64: throw XipperError.unsupported("Deflate64 compression (\(name))")
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
