import CArchive
import Foundation

/// RAR 1.5–4.x and RAR5 archives, read only (STUDIO.md §4.2), through libarchive's RAR readers
/// (BSD-2-Clause, vendored in Vendor/libarchive; RAR's own unrar code is never used). Entries
/// come out as tar headers, so they go through Xipper's safe extraction, listing and verification.
/// Multi-volume archives (`name.part1.rar`… or `name.rar`, `name.r00`…) are read from any part.
/// libarchive checks each file's CRC-32 (RAR 4) or CRC-32/BLAKE2sp (RAR5) at the end of its data.
final class RarReader: EntryStreamReader {
    private let a: OpaquePointer
    private let name: String
    private var pendingData = false

    static let signature4: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]  // "Rar!" 1A 07 00
    static let signature5: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]

    static func looksLikeArchive(_ head: [UInt8]) -> Bool { head.starts(with: signature4) || head.starts(with: signature5) }

    static func isRAR(_ path: String) -> Bool {
        guard let r = try? FileReader(path: path), let head = try? r.read(at: 0, count: Int(min(r.size, 8))) else { return false }
        return looksLikeArchive(head)
    }

    /// Every volume of the archive `path` belongs to, in order (just `path` for a single file).
    static func volumes(for path: String) -> [String] {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent().path
        let file = url.lastPathComponent
        let fm = FileManager.default
        // New naming: name.part1.rar, name.part01.rar, …
        if let r = file.range(of: #"\.part[0-9]+\.rar$"#, options: [.regularExpression, .caseInsensitive]) {
            let base = String(file[..<r.lowerBound])
            let digits = file[r].filter(\.isNumber).count
            var out: [String] = []
            var n = 1
            while true {
                let candidate = dir + "/" + base + ".part" + String(format: "%0\(digits)d", n) + ".rar"
                guard fm.fileExists(atPath: candidate) else { break }
                out.append(candidate)
                n += 1
            }
            return out.contains(path) || out.isEmpty ? (out.isEmpty ? [path] : out) : [path]
        }
        // Old naming: name.rar, name.r00, name.r01, …
        let ext = url.pathExtension.lowercased()
        if ext == "rar" || (ext.count == 3 && ext.first == "r" && ext.dropFirst().allSatisfy(\.isNumber)) {
            let base = dir + "/" + url.deletingPathExtension().lastPathComponent
            let first = [base + ".rar", base + ".RAR"].first { fm.fileExists(atPath: $0) }
            guard let first else { return [path] }
            var out = [first]
            var n = 0
            while true {
                let candidate = [base + String(format: ".r%02d", n), base + String(format: ".R%02d", n)].first { fm.fileExists(atPath: $0) }
                guard let candidate else { break }
                out.append(candidate)
                n += 1
            }
            return out
        }
        return [path]
    }

    /// libarchive converts RAR's UTF-16 names "to the current locale": in a process with the C
    /// locale every non-ASCII name would fail. Every call runs with a UTF-8 locale on its thread.
    nonisolated(unsafe) private static let utf8Locale = newlocale(LC_CTYPE_MASK, "UTF-8", nil)

    private static func withUTF8<R>(_ body: () throws -> R) rethrows -> R {
        let old = uselocale(utf8Locale)
        defer { uselocale(old) }
        return try body()
    }

    init(path: String, password: String? = nil) throws {
        let old = uselocale(Self.utf8Locale)
        defer { uselocale(old) }
        name = (path as NSString).lastPathComponent
        guard let a = archive_read_new() else { throw XipperError.codec("libarchive") }
        self.a = a
        archive_read_support_format_rar(a)
        archive_read_support_format_rar5(a)
        if let password { archive_read_add_passphrase(a, password) }
        let files = Self.volumes(for: path)
        // NULL-terminated C array of the volume paths.
        let cStrings = files.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var argv: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) } + [nil]
        let r = argv.withUnsafeMutableBufferPointer { archive_read_open_filenames(a, $0.baseAddress, 1 << 20) }
        if r != ARCHIVE_OK {
            let message = Self.message(a)
            archive_read_free(a)
            throw Self.error(message, name: name)
        }
    }

    deinit { archive_read_free(a) }

    private static func message(_ a: OpaquePointer) -> String {
        archive_error_string(a).map { String(cString: $0) } ?? "unknown error"
    }

    private static func error(_ message: String, name: String) -> XipperError {
        let m = message.lowercased()
        if m.contains("encrypt") || m.contains("passphrase") {
            return .unsupported("\(name): encrypted RAR archives are not supported yet")
        }
        if m.contains("crc") || m.contains("checksum") { return .corrupt("\(name): \(message)") }
        return .corrupt("\(name): invalid RAR data (\(message))")
    }

    func next() throws -> TarReader.Entry? { try Self.withUTF8 { try nextEntry() } }

    private func nextEntry() throws -> TarReader.Entry? {
        var e: OpaquePointer?
        let r = archive_read_next_header(a, &e)
        if r == ARCHIVE_EOF { return nil }
        guard r == ARCHIVE_OK || r == ARCHIVE_WARN, let e else { throw Self.error(Self.message(a), name: name) }
        let encrypted = archive_entry_is_data_encrypted(e) != 0
        if archive_entry_is_metadata_encrypted(e) != 0 { throw XipperError.unsupported("\(name): RAR archives with encrypted names are not supported yet") }
        var path = (archive_entry_pathname_utf8(e) ?? archive_entry_pathname(e)).map { String(cString: $0) } ?? ""
        path = path.replacingOccurrences(of: "\\", with: "/")
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasSuffix("/") { path.removeLast() }
        // A name libarchive could not convert is an error, never a silently skipped entry.
        guard !path.isEmpty else { throw XipperError.corrupt("\(name): an entry name cannot be read (\(Self.message(a)))") }
        let filetype = UInt32(archive_entry_filetype(e))
        let hardlink = archive_entry_hardlink_utf8(e).map { String(cString: $0) }
        let symlink = archive_entry_symlink_utf8(e).map { String(cString: $0) }
        let type: UInt8
        let kind: ArchiveEntry.Kind
        // AE_IFDIR and AE_IFLNK (libarchive's cast macros are not imported into Swift).
        switch filetype {
        case 0o040000: type = Tar.TypeFlag.directory.rawValue; kind = .directory
        case 0o120000: type = Tar.TypeFlag.symlink.rawValue; kind = .symlink
        default:
            if let hardlink, !hardlink.isEmpty {
                type = Tar.TypeFlag.hardlink.rawValue; kind = .hardlink
            } else {
                type = Tar.TypeFlag.file.rawValue; kind = .file
            }
        }
        let size = kind == .file ? Int64(archive_entry_size(e)) : 0
        let mtime = Date(timeIntervalSince1970: Double(archive_entry_mtime(e)) + Double(archive_entry_mtime_nsec(e)) / 1e9)
        let perm = UInt16(truncatingIfNeeded: archive_entry_perm(e)) & 0o7777
        let link = kind == .symlink ? symlink ?? "" : kind == .hardlink ? hardlink ?? "" : ""
        let header = Tar.Header(path: path, type: type, size: size, mode: perm == 0 ? (kind == .directory ? 0o755 : 0o644) : perm,
                                uid: 0, gid: 0, mtime: mtime, linkTarget: link)
        pendingData = kind == .file
        if encrypted && kind == .file { pendingData = false }
        let method = archive_format(a) == ARCHIVE_FORMAT_RAR_V5 ? "rar5" : "rar"
        let entry = ArchiveEntry(path: path, kind: kind, uncompressedSize: size, compressedSize: 0, modified: mtime, permissions: header.mode,
                                 encryption: encrypted ? .aes(strength: 3, vendorVersion: 0, actualMethod: 0) : .none, method: method,
                                 linkTarget: kind == .symlink || kind == .hardlink ? link : nil)
        encryptedEntry = encrypted
        return TarReader.Entry(header: header, entry: entry)
    }

    private var encryptedEntry = false

    func readData(cancel: CancellationToken?, _ sink: ByteSink) throws { try Self.withUTF8 { try readEntryData(cancel: cancel, sink) } }

    private func readEntryData(cancel: CancellationToken?, _ sink: ByteSink) throws {
        if encryptedEntry { throw XipperError.unsupported("\(name): encrypted RAR entries are not supported yet") }
        guard pendingData else { return }
        pendingData = false
        let chunk = 1 << 20
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16384)
        defer { buf.deallocate() }
        while true {
            try cancel?.check()
            let n = archive_read_data(a, buf, chunk)
            if n == 0 { return }
            if n < 0 { throw Self.error(Self.message(a), name: name) }
            try sink(UnsafeRawBufferPointer(start: buf, count: n))
        }
    }
}
