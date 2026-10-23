import CArchive
import Foundation

/// RAR 1.5–4.x and RAR5 archives, read only (STUDIO.md §4.2), through libarchive's RAR readers
/// (BSD-2-Clause, vendored in Vendor/libarchive; RAR's own unrar code is never used). Entries
/// come out as tar headers, so they go through Xipper's safe extraction, listing and verification.
/// Multi-volume archives (`name.part1.rar`… or `name.rar`, `name.r00`…) are read from any part.
/// libarchive checks each file's CRC-32 (RAR 4) or CRC-32/BLAKE2sp (RAR5) at the end of its data.
/// Encrypted RAR5 archives (one volume) are read through `Rar5PlainStream` (Rar5Crypto.swift).
final class RarReader: EntryStreamReader {
    private let a: OpaquePointer
    private let name: String
    private var pendingData = false
    /// Encrypted RAR5: the decrypting stream libarchive reads from, and the index of the current file.
    private var plain: PlainSource?
    private var fileIndex = -1

    /// Owns the chunk handed to libarchive until its next read.
    private final class PlainSource {
        let stream: Rar5PlainStream
        var buffer = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 16)
        var capacity = 1
        var error: Error?
        init(_ s: Rar5PlainStream) { stream = s }
        deinit { buffer.deallocate() }
    }

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
        let r: Int32
        if files.count == 1, Self.isRAR5(path),
           Rar5PlainStream.headersEncrypted(path) || (password != nil && Rar5PlainStream.isEncrypted(path)) {
            // Failures below leave `a` to deinit: a throwing init of a fully initialized class still runs it.
            guard let password else { throw XipperError.passwordRequired(entry: name) }
            let source = PlainSource(try Rar5PlainStream(path: path, password: password))
            plain = source
            r = archive_read_open(a, Unmanaged.passUnretained(source).toOpaque(), nil, { _, ctx, out in
                let src = Unmanaged<PlainSource>.fromOpaque(ctx!).takeUnretainedValue()
                do {
                    let chunk = try src.stream.next()
                    if chunk.count > src.capacity {
                        src.buffer.deallocate()
                        src.buffer = .allocate(byteCount: chunk.count, alignment: 16)
                        src.capacity = chunk.count
                    }
                    chunk.withUnsafeBytes { if let b = $0.baseAddress { src.buffer.copyMemory(from: b, byteCount: $0.count) } }
                    out!.pointee = UnsafeRawPointer(src.buffer)
                    return la_ssize_t(chunk.count)
                } catch {
                    src.error = error
                    return -1
                }
            }, nil)
        } else {
            // NULL-terminated C array of the volume paths.
            let cStrings = files.map { strdup($0) }
            defer { cStrings.forEach { free($0) } }
            var argv: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) } + [nil]
            r = argv.withUnsafeMutableBufferPointer { archive_read_open_filenames(a, $0.baseAddress, 1 << 20) }
        }
        if let e = plain?.error { throw e }
        if r != ARCHIVE_OK {
            throw Self.error(Self.message(a), name: name)
        }
    }

    static func isRAR5(_ path: String) -> Bool {
        guard let r = try? FileReader(path: path), let head = try? r.read(at: 0, count: Int(min(r.size, 8))) else { return false }
        return head.starts(with: signature5)
    }

    /// A failure while reading: the decrypting stream's own error (wrong password…) comes first.
    private func failure() -> XipperError {
        if let e = plain?.error as? XipperError { return e }
        return Self.error(Self.message(a), name: name)
    }

    deinit { archive_read_free(a) }

    private static func message(_ a: OpaquePointer) -> String {
        archive_error_string(a).map { String(cString: $0) } ?? "unknown error"
    }

    private static func error(_ message: String, name: String) -> XipperError {
        let m = message.lowercased()
        if m.contains("encrypt") || m.contains("passphrase") {
            return .unsupported("\(name): encrypted RAR 4 archives are not supported yet (RAR5 ones are)")
        }
        if m.contains("crc") || m.contains("checksum") { return .corrupt("\(name): \(message)") }
        return .corrupt("\(name): invalid RAR data (\(message))")
    }

    func next() throws -> TarReader.Entry? { try Self.withUTF8 { try nextEntry() } }

    private func nextEntry() throws -> TarReader.Entry? {
        var e: OpaquePointer?
        let r = archive_read_next_header(a, &e)
        if r == ARCHIVE_EOF {
            if let e = plain?.error { throw e }  // libarchive may end quietly when the stream fails
            return nil
        }
        guard r == ARCHIVE_OK || r == ARCHIVE_WARN, let e else { throw failure() }
        fileIndex += 1
        let encrypted = archive_entry_is_data_encrypted(e) != 0
        if archive_entry_is_metadata_encrypted(e) != 0 { throw XipperError.passwordRequired(entry: name) }
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

    private static func isRAR5Format(_ a: OpaquePointer) -> Bool { archive_format(a) == ARCHIVE_FORMAT_RAR_V5 }

    func readData(cancel: CancellationToken?, _ sink: ByteSink) throws { try Self.withUTF8 { try readEntryData(cancel: cancel, sink) } }

    private func readEntryData(cancel: CancellationToken?, _ sink: ByteSink) throws {
        if encryptedEntry {
            if plain?.stream.wrongPassword.contains(fileIndex) == true { throw XipperError.wrongPassword(entry: name) }
            if Self.isRAR5Format(a) { throw XipperError.passwordRequired(entry: name) }
            throw XipperError.unsupported("\(name): encrypted RAR 4 entries are not supported yet")
        }
        guard pendingData else { return }
        pendingData = false
        // Checksums tweaked with the password: libarchive cannot check them, Xipper does.
        let expected = plain.flatMap { fileIndex < $0.stream.expected.count ? $0.stream.expected[fileIndex] : nil }
        var crc: UInt32 = 0
        var blake = expected?.blake2 != nil ? blake2sp_state() : nil
        if blake != nil { _ = __archive_blake2sp_init(&blake!, 32) }
        let chunk = 1 << 20
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16384)
        defer { buf.deallocate() }
        while true {
            try cancel?.check()
            let n = archive_read_data(a, buf, chunk)
            if n == 0 { break }
            if n < 0 { throw failure() }
            let piece = UnsafeRawBufferPointer(start: buf, count: n)
            if expected != nil {
                crc = CRC32.update(crc, piece)
                if blake != nil { _ = __archive_blake2sp_update(&blake!, buf, n) }
            }
            try sink(piece)
        }
        guard let expected else { return }
        if let want = expected.crc, Rar5Crypto.tweak(crc: crc, hashKey: expected.hashKey) != want {
            throw XipperError.integrity(entry: name, detail: "CRC-32 mismatch (or wrong password)")
        }
        if let want = expected.blake2, var b = blake {
            var digest = [UInt8](repeating: 0, count: 32)
            _ = __archive_blake2sp_final(&b, &digest, 32)
            if Rar5Crypto.hmac(expected.hashKey, digest) != want {
                throw XipperError.integrity(entry: name, detail: "BLAKE2sp mismatch (or wrong password)")
            }
        }
    }
}
