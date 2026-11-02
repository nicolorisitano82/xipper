import Foundation

/// What `Xipper.repairZip` saved and what it could not.
public struct ZipRepairReport: Sendable {
    public var output: URL
    /// Entries in the repaired archive (files and folders).
    public var recovered: Int
    /// Encrypted entries kept without checking their content (no password given).
    public var unverified: [String]
    /// Entries found in the damaged file but left out: truncated, unreadable or failing their CRC.
    public var lost: [String]
    /// Older copies of a name that appears again later in the file (an archive updated in place).
    public var superseded: [String]
    public var elapsed: Double
}

extension Xipper {
    /// Rebuilds a damaged ZIP without recovery data: the central directory is reconstructed from
    /// the local headers (found by scanning the file), every entry is copied without
    /// recompressing it, the new archive is tested and entries failing their CRC are dropped.
    /// The original is never modified; the result goes to `target` (default: "name (riparato).zip"
    /// next to it). Permissions, comments and attributes come from the remains of the old central
    /// directory when they can be matched, otherwise files get 0644 and folders 0755.
    @discardableResult
    public static func repairZip(_ source: URL, to target: URL? = nil, password: String? = nil,
                                 progress: ProgressHandler? = nil, cancel: CancellationToken? = nil) throws -> ZipRepairReport {
        try ZipRepair(source: source, password: password).run(to: target ?? ZipRepair.defaultTarget(for: source),
                                                              progress: progress, cancel: cancel)
    }
}

struct ZipRepair {
    let source: URL
    let password: String?

    /// One entry found in the damaged file.
    struct Found {
        var record: ZipEntryRecord
        /// Offset just past its data (and data descriptor).
        var end: Int64
        var encrypted: Bool { record.flags & Zip.Flag.encrypted != 0 }
    }

    static func defaultTarget(for source: URL) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent, dir = source.deletingLastPathComponent()
        var url = dir.appendingPathComponent("\(stem) (riparato).zip")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(stem) (riparato) \(n).zip")
            n += 1
        }
        return url
    }

    static let methods: Set<UInt16> = [0, 1, 6, 8, 9, 12, 14, 93, 95, 96, 97, 98, 99]

    func run(to target: URL, progress: ProgressHandler?, cancel: CancellationToken?) throws -> ZipRepairReport {
        let start = Date()
        let target = target.standardizedFileURL
        guard target.path != source.standardizedFileURL.path else { throw XipperError.invalidArgument("the repaired archive needs another name") }
        if FileManager.default.fileExists(atPath: target.path) { throw XipperError.alreadyExists(path: target.path) }
        let reader = try FileReader(path: source.path)
        let tracker = ProgressTracker(totalBytes: reader.size * 2, totalEntries: 0, handler: progress)
        var (found, lost) = try scan(reader, tracker: tracker, cancel: cancel)
        let centrals = try centralRemains(reader, cancel: cancel)

        // The same name more than once: an archive updated by appending. The last copy wins.
        var superseded: [String] = []
        var last: [String: Int] = [:]
        for (i, f) in found.enumerated() { last[Self.key(f.record.rawName)] = i }
        found = found.enumerated().filter { i, f in
            if last[Self.key(f.record.rawName)] == i { return true }
            superseded.append(f.record.entry.path)
            return false
        }.map(\.element)
        for i in found.indices {
            if let c = centrals[found[i].record.localHeaderOffset], c.rawName == found[i].record.rawName {
                found[i].record.central = c.central
                found[i].record.hostSystem = c.hostSystem
            }
        }
        guard !found.isEmpty else { throw XipperError.corrupt("no ZIP entries could be found in \(source.lastPathComponent)") }

        // Written next to the target, tested, and given its name only when clean.
        let dir = target.deletingLastPathComponent()
        let staged = dir.appendingPathComponent(".xipper-repair-\(getpid())-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: staged) }
        var unverified: [String] = []
        for attempt in 0..<3 {
            try cancel?.check()
            try write(found, from: reader, to: staged)
            let test = try Xipper.test(staged, password: password, cancel: cancel)
            tracker.add(bytes: attempt == 0 ? reader.size : 0)
            let written = try ZipArchive(path: staged.path)
            var rawByPath: [String: [UInt8]] = [:]
            for r in written.records { rawByPath[r.entry.path] = r.rawName }
            var drop = Set<[UInt8]>()
            unverified = []
            for failure in test.failures {
                guard let raw = rawByPath[failure.path], let f = found.first(where: { $0.record.rawName == raw }) else { continue }
                if f.encrypted && password == nil { unverified.append(failure.path) } else { drop.insert(raw) }
            }
            if drop.isEmpty { break }
            lost += found.filter { drop.contains($0.record.rawName) }.map(\.record.entry.path)
            found.removeAll { drop.contains($0.record.rawName) }
            guard !found.isEmpty else { throw XipperError.corrupt("no entry of \(source.lastPathComponent) passes its check") }
            if attempt == 2 { throw XipperError.corrupt("the repaired archive still does not verify") }
        }
        if renamex_np(staged.path, target.path, UInt32(RENAME_EXCL)) != 0 {
            if errno == EEXIST { throw XipperError.alreadyExists(path: target.path) }
            throw XipperError.posix("rename", target.path)
        }
        let dirFD = open(dir.path, O_RDONLY)
        if dirFD >= 0 { _ = OutputFile.fullSync(dirFD); close(dirFD) }
        tracker.finish()
        return ZipRepairReport(output: target, recovered: found.count, unverified: unverified, lost: lost, superseded: superseded,
                               elapsed: Date().timeIntervalSince(start))
    }

    private static func key(_ raw: [UInt8]) -> String { String(decoding: raw, as: UTF8.self).precomposedStringWithCanonicalMapping }

    // MARK: scanning

    /// Every plausible local header, in file order. An entry whose end is known is skipped over
    /// (its data may hold signatures: a stored ZIP inside the ZIP); one whose end cannot be
    /// found is lost and the scan goes on right after its header.
    func scan(_ r: FileReader, tracker: ProgressTracker, cancel: CancellationToken?) throws -> ([Found], [String]) {
        var found: [Found] = []
        var lost: [String] = []
        var at: Int64 = 0
        var reported: Int64 = 0
        while let o = try Self.find([Zip.localSignature], in: r, from: at, cancel: cancel)?.offset {
            if o > reported { tracker.add(bytes: o - reported); reported = o }
            guard let (rec, dataStart) = try parseLocal(r, at: o) else { at = o + 4; continue }
            if let end = try dataEnd(r, rec: rec, dataStart: dataStart, cancel: cancel) {
                var record = rec.record
                record.dataOffset = dataStart
                found.append(Found(record: record, end: end))
                if end > reported { tracker.add(bytes: end - reported); reported = end }
                at = end
            } else {
                lost.append(rec.record.entry.path)
                at = dataStart
            }
        }
        if r.size > reported { tracker.add(bytes: r.size - reported) }
        return (found, lost)
    }

    struct Local {
        var record: ZipEntryRecord
        /// Sizes declared in the header (0 with a data descriptor), and whether it is ZIP64.
        var zip64: Bool
    }

    private func parseLocal(_ r: FileReader, at o: Int64) throws -> (Local, Int64)? {
        guard o + 30 <= r.size else { return nil }
        let h = try r.read(at: o, count: 30)
        func u16(_ i: Int) -> UInt16 { UInt16(h[i]) | UInt16(h[i + 1]) << 8 }
        func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
        let version = u16(4), flags = u16(6), method = u16(8)
        let nameLen = Int(u16(26)), extraLen = Int(u16(28))
        guard version & 0xFF <= 90, Self.methods.contains(method), nameLen > 0, flags & Zip.Flag.strongEncryption == 0,
              o + 30 + Int64(nameLen + extraLen) <= r.size else { return nil }
        let rawName = try r.read(at: o + 30, count: nameLen)
        guard !rawName.contains(0) else { return nil }
        let extra = try r.read(at: o + 30 + Int64(nameLen), count: extraLen)
        var csize = Int64(u32(18)), usize = Int64(u32(22))
        var zip64 = false
        if csize == 0xFFFF_FFFF || usize == 0xFFFF_FFFF, let z = Self.field(extra, Zip.Extra.zip64), z.count >= 16 {
            func u64(_ i: Int) -> Int64 { (0..<8).reduce(Int64(0)) { $0 | Int64(z[i + $1]) << (8 * $1) } }
            usize = u64(0); csize = u64(8)
            zip64 = true
        }
        let utf8 = flags & Zip.Flag.utf8 != 0
        let path = utf8 ? String(decoding: rawName, as: UTF8.self) : (String(bytes: rawName, encoding: .isoLatin1) ?? "?")
        let isDir = rawName.last == UInt8(ascii: "/")
        var central = ZipEntryRecord.CentralFields()
        central.versionMadeBy = Zip.versionMadeBy
        central.versionNeeded = version
        central.dosDate = u16(12)
        central.externalAttributes = isDir ? (0o040755 << 16 | 0x10) : 0o100644 << 16
        central.extra = extra
        let entry = ArchiveEntry(path: path, kind: isDir ? .directory : .file, uncompressedSize: usize, compressedSize: csize,
                                 modified: nil, permissions: nil, encryption: .none, method: "", linkTarget: nil)
        let record = ZipEntryRecord(entry: entry, rawName: rawName, method: method, flags: flags, crc: u32(14),
                                    compressedSize: csize, uncompressedSize: usize, localHeaderOffset: o, dosTime: u16(10),
                                    hostSystem: 3, central: central)
        return (Local(record: record, zip64: zip64), o + 30 + Int64(nameLen + extraLen))
    }

    /// Where the entry's data (and descriptor) ends. With a data descriptor the sizes are not in
    /// the header: the descriptor is searched for, and accepted only where its compressed size is
    /// exactly the distance from the data start.
    private func dataEnd(_ r: FileReader, rec l: Local, dataStart: Int64, cancel: CancellationToken?) throws -> Int64? {
        let rec = l.record
        if rec.flags & Zip.Flag.dataDescriptor == 0 {
            let end = dataStart + rec.compressedSize
            return end <= r.size ? end : nil
        }
        let signatures: [UInt32] = [Zip.dataDescriptorSignature, Zip.localSignature, Zip.centralSignature, Zip.endSignature]
        var from = dataStart
        while let hit = try Self.find(signatures, in: r, from: from, cancel: cancel) {
            let p = hit.offset
            func u32(_ b: [UInt8], _ i: Int) -> Int64 { Int64(b[i]) | Int64(b[i + 1]) << 8 | Int64(b[i + 2]) << 16 | Int64(b[i + 3]) << 24 }
            // Signed descriptor at p: crc, csize, usize (32 or 64 bits).
            if hit.signature == Zip.dataDescriptorSignature, p + 16 <= r.size {
                let d = try r.read(at: p, count: Int(min(24, r.size - p)))
                if u32(d, 8) == p - dataStart { return p + 16 }
                if d.count >= 24, u32(d, 8) | u32(d, 12) << 32 == p - dataStart { return p + 24 }
            }
            // Unsigned descriptor right before the next signature.
            for size in [12, 20] where p - Int64(size) >= dataStart {
                let d = try r.read(at: p - Int64(size), count: size)
                let csize = size == 12 ? u32(d, 4) : u32(d, 4) | u32(d, 8) << 32
                if csize == p - Int64(size) - dataStart { return p }
            }
            from = p + 1
        }
        return nil
    }

    /// Central directory records still in the file, by the local header offset they point to:
    /// they hold what local headers lack (permissions, symlinks, comments).
    private func centralRemains(_ r: FileReader, cancel: CancellationToken?) throws -> [Int64: ZipEntryRecord] {
        var out: [Int64: ZipEntryRecord] = [:]
        var at: Int64 = 0
        while let o = try Self.find([Zip.centralSignature], in: r, from: at, cancel: cancel)?.offset {
            at = o + 4
            guard o + 46 <= r.size else { break }
            let h = try r.read(at: o, count: 46)
            func u16(_ i: Int) -> UInt16 { UInt16(h[i]) | UInt16(h[i + 1]) << 8 }
            func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
            let n = Int(u16(28)), e = Int(u16(30)), c = Int(u16(32))
            guard n > 0, o + 46 + Int64(n + e + c) <= r.size else { continue }
            let rawName = try r.read(at: o + 46, count: n)
            let extra = try r.read(at: o + 46 + Int64(n), count: e)
            let comment = try r.read(at: o + 46 + Int64(n + e), count: c)
            var offset = Int64(u32(42))
            if offset == 0xFFFF_FFFF, let z = Self.field(extra, Zip.Extra.zip64) {
                // The offset is the last of the ZIP64 values present.
                var i = 0
                if u32(24) == 0xFFFF_FFFF { i += 8 }
                if u32(20) == 0xFFFF_FFFF { i += 8 }
                if z.count >= i + 8 { offset = (0..<8).reduce(Int64(0)) { $0 | Int64(z[i + $1]) << (8 * $1) } }
            }
            var central = ZipEntryRecord.CentralFields()
            central.versionMadeBy = u16(4)
            central.versionNeeded = u16(6)
            central.dosDate = u16(14)
            central.internalAttributes = u16(36)
            central.externalAttributes = u32(38)
            central.extra = extra
            central.comment = comment
            let entry = ArchiveEntry(path: "", kind: .file, uncompressedSize: 0, compressedSize: 0, modified: nil, permissions: nil,
                                     encryption: .none, method: "", linkTarget: nil)
            out[offset] = ZipEntryRecord(entry: entry, rawName: rawName, method: u16(10), flags: u16(8), crc: u32(16),
                                         compressedSize: 0, uncompressedSize: 0, localHeaderOffset: offset, dosTime: u16(12),
                                         hostSystem: UInt8(u16(4) >> 8), central: central)
        }
        return out
    }

    // MARK: writing

    private func write(_ found: [Found], from r: FileReader, to staged: URL) throws {
        let out = try OutputFile(path: staged.path)
        var central = ByteWriter(capacity: 1 << 16)
        for f in found {
            var rec = f.record
            if rec.flags & Zip.Flag.dataDescriptor != 0 {
                // CRC and sizes from the descriptor (copied as is after the data).
                let descriptorAt = try descriptorOffset(f, r)
                let d = try r.read(at: descriptorAt, count: Int(min(24, r.size - descriptorAt)))
                func u32(_ i: Int) -> Int64 { Int64(d[i]) | Int64(d[i + 1]) << 8 | Int64(d[i + 2]) << 16 | Int64(d[i + 3]) << 24 }
                let signed = u32(0) == Int64(Zip.dataDescriptorSignature)
                let b = signed ? 4 : 0
                rec.crc = UInt32(u32(b))
                rec.compressedSize = descriptorAt - f.record.dataOffset
                let wide = f.end - descriptorAt - Int64(b) == 20
                rec.uncompressedSize = wide ? u32(b + 12) | u32(b + 16) << 32 : u32(b + 8)
            }
            rec.entry.compressedSize = rec.compressedSize
            rec.entry.uncompressedSize = rec.uncompressedSize
            try ZipEditor.copy(rec, read: { try r.read(at: $0, count: $1) }, name: rec.entry.path, renamed: false,
                               rawName: rec.rawName, to: out, central: &central)
        }
        try ZipEditor.finish(out, central: central.bytes, count: found.count, forceZip64: false)
        try out.commit(overwrite: true)
    }

    /// The descriptor of an entry whose end was found: its last 12/16/20/24 bytes.
    private func descriptorOffset(_ f: Found, _ r: FileReader) throws -> Int64 {
        for size in [16, 24, 12, 20] {
            let at = f.end - Int64(size)
            guard at >= f.record.dataOffset else { continue }
            let d = try r.read(at: at, count: size)
            func u32(_ i: Int) -> Int64 { Int64(d[i]) | Int64(d[i + 1]) << 8 | Int64(d[i + 2]) << 16 | Int64(d[i + 3]) << 24 }
            let signed = size == 16 || size == 24
            if signed && u32(0) != Int64(Zip.dataDescriptorSignature) { continue }
            let b = signed ? 4 : 0
            let csize = size == 16 || size == 12 ? u32(b + 4) : u32(b + 4) | u32(b + 8) << 32
            if csize == at - f.record.dataOffset { return at }
        }
        throw XipperError.corrupt("data descriptor of \(f.record.entry.path)")
    }

    // MARK: helpers

    static func field(_ extra: [UInt8], _ id: UInt16) -> ArraySlice<UInt8>? {
        var i = 0
        while i + 4 <= extra.count {
            let fid = UInt16(extra[i]) | UInt16(extra[i + 1]) << 8
            let len = Int(UInt16(extra[i + 2]) | UInt16(extra[i + 3]) << 8)
            guard i + 4 + len <= extra.count else { return nil }
            if fid == id { return extra[(i + 4)..<(i + 4 + len)] }
            i += 4 + len
        }
        return nil
    }

    /// The first of `signatures` (little-endian u32) at or after `from`.
    static func find(_ signatures: [UInt32], in r: FileReader, from: Int64, cancel: CancellationToken?) throws -> (offset: Int64, signature: UInt32)? {
        let window = 8 << 20
        var at = max(0, from)
        while at + 4 <= r.size {
            try cancel?.check()
            let n = Int(min(Int64(window), r.size - at))
            let b = try r.read(at: at, count: n)
            var i = 0
            while i + 4 <= b.count {
                if b[i] == 0x50 && b[i + 1] == 0x4B {
                    let sig = UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
                    if signatures.contains(sig) { return (at + Int64(i), sig) }
                }
                i += 1
            }
            if n < 4 { break }
            at += Int64(n - 3)
            if n < window { break }
        }
        return nil
    }
}
