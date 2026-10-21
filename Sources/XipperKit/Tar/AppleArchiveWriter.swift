import AppleArchive
import Darwin
import Foundation
import System

/// Writes Apple Archive (`.aar`) through the system AppleArchive framework: LZ4 / LZFSE / LZMA by
/// level, extended attributes (XAT), and with a password an encrypted AEA archive (scrypt +
/// AES-CTR + HMAC, profile `hkdf_sha256_aesctr_hmac__scrypt__none`) that macOS opens natively.
public enum AppleArchiveWriter {
    /// AEA rejects shorter passwords ("Password is too short", also with `aea encrypt`).
    public static let minimumPasswordLength = 20

    /// Level 0–2 → LZ4, 3–6 → LZFSE, 7–9 → LZMA.
    static func compression(level: Int) -> ArchiveCompression {
        level <= 2 ? .lz4 : level <= 6 ? .lzfse : .lzma
    }

    static func write(items: [ArchiveItem], to path: String, level: Int, password: String?, extendedAttributes: Bool,
                      overwrite: Bool, progress: ProgressHandler?, cancel: CancellationToken?) throws -> WriteReport {
        if !overwrite && FileManager.default.fileExists(atPath: path) { throw XipperError.alreadyExists(path: path) }
        let tracker = ProgressTracker(totalBytes: items.reduce(0) { $0 + $1.size }, totalEntries: items.count, handler: progress)
        let tmp = (path as NSString).deletingLastPathComponent + "/.\((path as NSString).lastPathComponent).xiptmp-\(UInt32.random(in: 0...UInt32.max))"
        var committed = false
        defer { if !committed { unlink(tmp) } }

        guard let file = ArchiveByteStream.fileStream(path: FilePath(tmp), mode: .writeOnly, options: [.create, .truncate],
                                                      permissions: FilePermissions(rawValue: 0o644)) else {
            throw XipperError.posix("create", tmp)
        }
        let algorithm = compression(level: level)
        let middle: ArchiveByteStream?
        if let password {
            guard password.utf8.count >= minimumPasswordLength else {
                try? file.close()
                throw XipperError.invalidArgument("Apple Archive (AEA) passwords must be at least \(minimumPasswordLength) bytes")
            }
            let context = ArchiveEncryptionContext(profile: .hkdf_sha256_aesctr_hmac__scrypt__none, compressionAlgorithm: algorithm)
            do { try context.setPassword(password) } catch { try? file.close(); throw XipperError.codec("AEA password") }
            middle = ArchiveByteStream.encryptionStream(writingTo: file, encryptionContext: context)
        } else {
            middle = ArchiveByteStream.compressionStream(using: algorithm, writingTo: file)
        }
        guard let middle, let encoder = ArchiveStream.encodeStream(writingTo: middle) else {
            try? file.close()
            throw XipperError.codec("Apple Archive encoder")
        }
        var closed = false
        func closeAll() throws {
            guard !closed else { return }
            closed = true
            do {
                try encoder.close()
                try middle.close()
                try file.close()
            } catch {
                throw XipperError.codec("Apple Archive write")
            }
        }
        defer { try? closeAll() }

        let piece = UnsafeMutableRawBufferPointer.allocate(byteCount: 4 << 20, alignment: 16384)
        defer { piece.deallocate() }
        for item in items {
            try cancel?.check()
            let header = ArchiveHeader()
            let type: ArchiveHeader.EntryType
            switch item.kind {
            case .file: type = .regularFile
            case .directory: type = .directory
            case .symlink: type = .link
            }
            header.append(.uint(key: ArchiveHeader.FieldKey("TYP"), value: UInt64(type.rawValue)))
            header.append(.string(key: ArchiveHeader.FieldKey("PAT"), value: item.name))
            if case let .symlink(target) = item.kind { header.append(.string(key: ArchiveHeader.FieldKey("LNK"), value: target)) }
            header.append(.uint(key: ArchiveHeader.FieldKey("UID"), value: UInt64(item.uid)))
            header.append(.uint(key: ArchiveHeader.FieldKey("GID"), value: UInt64(item.gid)))
            header.append(.uint(key: ArchiveHeader.FieldKey("MOD"), value: UInt64(item.permissions)))
            let t = item.modified.timeIntervalSince1970
            header.append(.timespec(key: ArchiveHeader.FieldKey("MTM"),
                                    value: timespec(tv_sec: Int(t.rounded(.down)), tv_nsec: Int((t - t.rounded(.down)) * 1e9))))
            // Attributes go before the data: readers get them before writing the file.
            var xat: [UInt8] = []
            if extendedAttributes {
                let attrs: [(name: String, value: [UInt8])]
                if case .symlink = item.kind { attrs = [] } else { attrs = ExtendedAttributes.read(item.sourcePath) }
                if !attrs.isEmpty {
                    let blob = ArchiveHeader.EntryXATBlob()
                    for (name, value) in attrs { blob.append(.init(key: name, data: ContiguousArray(value))) }
                    xat = blob.withAAEncodedData { Array($0) }
                    header.append(.blob(key: ArchiveHeader.FieldKey("XAT"), size: UInt64(xat.count)))
                }
            }
            var reader: FileReader?
            var size: Int64 = 0
            if case .file = item.kind {
                let r = try FileReader(path: item.sourcePath)
                reader = r
                size = r.size
                header.append(.blob(key: ArchiveHeader.FieldKey("DAT"), size: UInt64(size)))
            }
            do {
                try encoder.writeHeader(header)
                if !xat.isEmpty { try xat.withUnsafeBytes { try encoder.writeBlob(key: ArchiveHeader.FieldKey("XAT"), from: $0) } }
            } catch {
                throw XipperError.codec("Apple Archive header for \(item.name)")
            }
            if let reader {
                var off: Int64 = 0
                while off < size {
                    try cancel?.check()
                    let n = Int(min(Int64(piece.count), size - off))
                    try reader.read(at: off, into: piece.baseAddress!, count: n)
                    do { try encoder.writeBlob(key: ArchiveHeader.FieldKey("DAT"), from: UnsafeRawBufferPointer(rebasing: piece[0..<n])) } catch {
                        throw XipperError.codec("Apple Archive data for \(item.name)")
                    }
                    off += Int64(n)
                    tracker.add(bytes: Int64(n), current: item.name)
                }
            }
            tracker.add(bytes: 0, entries: 1)
        }
        try closeAll()
        if rename(tmp, path) != 0 { throw XipperError.posix("rename", path) }
        committed = true
        tracker.finish()
        let outSize = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value ?? 0
        return WriteReport(entries: items.count, inputBytes: items.reduce(0) { $0 + $1.size }, outputBytes: outSize,
                           elapsed: tracker.elapsed)
    }
}

/// Writes cpio "newc" archives (the format of `cpio -H newc`, initramfs and RPM payloads).
enum CpioWriter {
    static func write(items: [ArchiveItem], to path: String, overwrite: Bool, progress: ProgressHandler?,
                      cancel: CancellationToken?) throws -> WriteReport {
        let tracker = ProgressTracker(totalBytes: items.reduce(0) { $0 + $1.size }, totalEntries: items.count, handler: progress)
        if !overwrite && FileManager.default.fileExists(atPath: path) { throw XipperError.alreadyExists(path: path) }
        let out = try OutputFile(path: path)
        var written: Int64 = 0
        func emit(_ b: [UInt8]) throws { try out.write(b); written += Int64(b.count) }
        func pad() throws { let p = Int((4 - written % 4) % 4); if p > 0 { try emit([UInt8](repeating: 0, count: p)) } }
        func header(ino: Int, mode: Int, uid: UInt32, gid: UInt32, mtime: Date, size: Int64, name: String) throws {
            let nameBytes = Array(name.utf8) + [0]
            let fields = [ino, mode, Int(uid), Int(gid), 1, Int(max(0, mtime.timeIntervalSince1970)), Int(size), 0, 0, 0, 0, nameBytes.count, 0]
            guard size <= 0xFFFF_FFFF else { throw XipperError.unsupported("cpio newc entries are limited to 4 GiB: \(name)") }
            try emit(Array("070701".utf8) + fields.flatMap { Array(String(format: "%08X", $0).utf8) })
            try emit(nameBytes)
            try pad()
        }
        let piece = UnsafeMutableRawPointer.allocate(byteCount: 4 << 20, alignment: 16384)
        defer { piece.deallocate() }
        for (i, item) in items.enumerated() {
            try cancel?.check()
            switch item.kind {
            case .directory:
                try header(ino: i + 1, mode: 0o040000 | Int(item.permissions), uid: item.uid, gid: item.gid, mtime: item.modified, size: 0, name: item.name)
            case let .symlink(target):
                let t = Array(target.utf8)
                try header(ino: i + 1, mode: 0o120000 | 0o777, uid: item.uid, gid: item.gid, mtime: item.modified, size: Int64(t.count), name: item.name)
                try emit(t)
                try pad()
            case .file:
                let reader = try FileReader(path: item.sourcePath)
                let size = reader.size
                try header(ino: i + 1, mode: 0o100000 | Int(item.permissions), uid: item.uid, gid: item.gid, mtime: item.modified, size: size, name: item.name)
                var off: Int64 = 0
                while off < size {
                    try cancel?.check()
                    let n = Int(min(Int64(4 << 20), size - off))
                    try reader.read(at: off, into: piece, count: n)
                    try out.write(UnsafeRawBufferPointer(start: piece, count: n))
                    written += Int64(n)
                    off += Int64(n)
                    tracker.add(bytes: Int64(n), current: item.name)
                }
                try pad()
            }
            tracker.add(bytes: 0, entries: 1)
        }
        try header(ino: 0, mode: 0, uid: 0, gid: 0, mtime: Date(timeIntervalSince1970: 0), size: 0, name: "TRAILER!!!")
        // Traditional 512-byte block padding, as cpio(1) writes it.
        let tail = Int((512 - written % 512) % 512)
        if tail > 0 { try emit([UInt8](repeating: 0, count: tail)) }
        try out.flush()
        try out.commit(overwrite: overwrite)
        tracker.finish()
        return WriteReport(entries: items.count, inputBytes: items.reduce(0) { $0 + $1.size }, outputBytes: written, elapsed: tracker.elapsed)
    }
}
