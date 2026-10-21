import Darwin
import Foundation

public enum ArchiveFormat: String, Sendable, CaseIterable, Identifiable {
    public var id: String { rawValue }

    case zip
    case tar
    case tarGzip = "tar.gz"
    case tarBzip2 = "tar.bz2"
    case tarXz = "tar.xz"
    case tarZstd = "tar.zst"
    /// Single file compressed without tar.
    case gzip = "gz"
    /// Blocked gzip (bgzip): gunzip-compatible, indexable; the standard for VCF/BED/FASTA and BAM/BCF.
    case bgzf
    case bzip2 = "bz2"
    case xz
    case zstd = "zst"
    /// 7z: LZMA2 (multi-threaded), solid blocks, ARM64 filter for executables, AES-256 with encrypted names.
    case sevenZip = "7z"
    // Read-only formats (STUDIO.md §4.2): extracted, listed and verified, never created.
    case tarLz4 = "tar.lz4"
    case lz4
    case tarBrotli = "tar.br"
    case brotli = "br"
    /// cpio (newc, crc and odc headers), also inside any supported compression.
    case cpio
    /// Apple Archive (`.aar`), read through the system AppleArchive framework.
    case appleArchive = "aar"
    /// XIZ v0, Xipper's own format (BETA): independent zstd frames, catalog at the end,
    /// whole-file dedup, Mac metadata. Not stable yet: the layout may change before v1.
    case xiz

    public var fileExtension: String { self == .bgzf ? "gz" : rawValue }

    public var isTar: Bool { [.tar, .tarGzip, .tarBzip2, .tarXz, .tarZstd, .tarLz4, .tarBrotli].contains(self) }
    public var isSingleFile: Bool { [.gzip, .bgzf, .bzip2, .xz, .zstd, .lz4, .brotli].contains(self) }
    /// Formats Xipper can write.
    public var canCreate: Bool { ![.tarLz4, .lz4, .tarBrotli, .brotli].contains(self) }
    public var supportsPassword: Bool { self == .zip || self == .sevenZip || self == .appleArchive }

    var compression: StreamCompression {
        switch self {
        case .zip, .tar, .sevenZip, .cpio, .appleArchive, .xiz: return .none
        case .tarLz4, .lz4: return .lz4
        case .tarBrotli, .brotli: return .brotli
        case .tarGzip, .gzip: return .gzip
        case .bgzf: return .bgzf
        case .tarBzip2, .bzip2: return .bzip2
        case .tarXz, .xz: return .xz
        case .tarZstd, .zstd: return .zstd
        }
    }

    /// Default level per format: zip/gzip 6, bzip2 9, xz 6, zstd 3 (the multi-thread sweet spot, SPIKE_FASE0.md §2).
    public var defaultLevel: Int {
        switch compression {
        case .bzip2: return 9
        case .zstd: return 3
        default: return 6
        }
    }

    /// Infers the format from a file name (".tar.gz", ".tgz", ".zip", …).
    public static func inferred(fromFileName name: String) -> ArchiveFormat? {
        let n = name.lowercased()
        let table: [(String, ArchiveFormat)] = [
            (".tar.gz", .tarGzip), (".tgz", .tarGzip), (".tar.bz2", .tarBzip2), (".tbz2", .tarBzip2), (".tbz", .tarBzip2),
            (".tar.xz", .tarXz), (".txz", .tarXz), (".tar.zst", .tarZstd), (".tzst", .tarZstd),
            (".7z", .sevenZip), (".7z.001", .sevenZip), (".tar.lz4", .tarLz4), (".tlz4", .tarLz4), (".lz4", .lz4),
            (".tar.br", .tarBrotli), (".br", .brotli), (".cpio", .cpio), (".aar", .appleArchive), (".xiz", .xiz), (".zip", .zip), (".tar", .tar), (".bgz", .bgzf), (".bam", .bgzf), (".bcf", .bgzf), (".gz", .gzip), (".bz2", .bzip2), (".xz", .xz), (".zst", .zstd),
        ]
        return table.first { n.hasSuffix($0.0) }?.1
    }

    /// Detects the format from the file content (magic bytes), falling back to the name.
    public static func detect(_ url: URL) throws -> ArchiveFormat? {
        // Later volumes of a split 7z (.7z.002…) have no signature of their own.
        if let first = SevenZipInput.firstVolume(url.path), first != url.path, FileManager.default.fileExists(atPath: first) {
            return try detect(URL(fileURLWithPath: first))
        }
        let r = try FileReader(path: url.path)
        let head = try r.read(at: 0, count: Int(min(r.size, 512)))
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) || head.starts(with: [0x50, 0x4B, 0x05, 0x06])
            || head.starts(with: [0x50, 0x4B, 0x07, 0x08]) { return .zip }  // 07 08: first part of a split ZIP
        if head.starts(with: SevenZip.signature) { return .sevenZip }
        if AppleArchiveReader.looksLikeArchive(head) { return .appleArchive }
        if XizArchive.looksLike(head) { return .xiz }
        if Cpio.looksLikeHeader(head) { return .cpio }
        let byName = inferred(fromFileName: url.lastPathComponent)
        switch StreamCompression.detect(head, name: url.lastPathComponent) {
        case .lz4: return byName == .lz4 ? .lz4 : .tarLz4
        case .brotli: return byName == .brotli ? .brotli : .tarBrotli
        case .gzip: return byName == .gzip ? .gzip : .tarGzip
        case .bgzf: return byName == .tarGzip ? .tarGzip : .bgzf
        case .bzip2: return byName == .bzip2 ? .bzip2 : .tarBzip2
        case .xz: return byName == .xz ? .xz : .tarXz
        case .zstd: return byName == .zstd ? .zstd : .tarZstd
        case .none:
            if head.count == 512, head.withUnsafeBytes({ Tar.looksLikeHeader($0) }) { return .tar }
            // Self-extracting or prefixed ZIPs have their signature at the end.
            if (try? ZipArchive(path: url.path)) != nil { return .zip }
            return nil
        }
    }
}

public struct CreateOptions: Sendable {
    public var format: ArchiveFormat = .zip
    /// nil = the format's default level.
    public var level: Int?
    /// ZIP (WinZip AES-256) and 7z (AES-256).
    public var password: String?
    public var zipMethod: ZipMethod = .deflate
    public var storeAlreadyCompressed = true
    /// tar formats: keep macOS extended attributes (Finder tags, resource forks…) as pax `SCHILY.xattr.*`.
    public var storeExtendedAttributes = true
    /// ZIP: also store them as AppleDouble files in `__MACOSX/`, like the Finder's "Compress"
    /// (off by default: Windows users see that folder).
    public var zipAppleDouble = false
    /// ZIP: traditional ZipCrypto instead of AES-256 (weak; only for receivers without AES).
    public var legacyZipCrypto = false
    public var forceZip64 = false
    public var scan = ScanOptions()
    public var workload: Workload = .interactive
    /// Replace an existing archive at the destination.
    public var overwrite = false
    public var memoryBudget = 512 << 20
    /// gzip of VCF/BED/GFF/FASTA/FASTQ/SAM files is written as BGZF (bgzip), which tabix,
    /// bcftools and samtools require. Output stays readable by any gunzip.
    public var genomicsUsesBGZF = true
    /// With BGZF output, also write the `.gzi` index next to it (like `bgzip -i`).
    public var writeBGZFIndex = false
    /// 7z: maximum content bytes per solid block; 0 = not solid (one block per file);
    /// nil = automatic (64× the dictionary, 512 MiB at the default level).
    public var solidBlockSize: Int64?
    /// 7z with a password: also encrypt the header, so file names stay hidden.
    public var encryptFileNames = true
    /// 7z: ARM64 branch filter for arm64 executables (Mach-O, ELF): smaller binaries.
    public var executableFilter = true
    /// 7z: split into volumes of this many bytes (`name.7z.001`, `.002`, …).
    public var volumeSize: Int64?
    public init() {}
}

public enum ExtractionMode: Sendable {
    /// Like Archive Utility: a single top-level item goes next to the archive, otherwise a folder
    /// named after the archive is created; existing names get " 2", " 3"…
    case smart
    /// Extract into an existing folder, merging according to `ExtractOptions.overwrite`.
    case into
}

public struct TestReport: Sendable {
    public var entries: Int
    public var bytes: Int64
    public var failures: [SkippedEntry]
    public var elapsed: Double
    /// SHA-256 (lowercase hex) of each intact file, when requested: entry path → digest.
    public var digests: [String: String] = [:]
    public var isOK: Bool { failures.isEmpty }

    /// `shasum -a 256` / `sha256sum` format, sorted by path.
    public var sha256sums: String {
        digests.sorted { $0.key < $1.key }.map { "\($0.value)  \($0.key)\n" }.joined()
    }
}

/// XipperKit entry point. All calls are synchronous and thread-safe: run them off the main thread.
public enum Xipper {
    // MARK: create

    @discardableResult
    /// Adds `__MACOSX/<dir>/._<name>` items for the entries that have extended attributes.
    private static func appendAppleDouble(_ items: [ArchiveItem]) throws -> ([ArchiveItem], URL?) {
        var extra: [ArchiveItem] = []
        var folder: URL?
        for item in items {
            if case .symlink = item.kind { continue }
            let attrs = ExtendedAttributes.read(item.sourcePath)
            guard !attrs.isEmpty else { continue }
            if folder == nil {
                folder = FileManager.default.temporaryDirectory.appendingPathComponent("xipper-ad-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: folder!, withIntermediateDirectories: true)
            }
            let file = folder!.appendingPathComponent("\(extra.count)")
            let data = AppleDouble.encode(attrs)
            try Data(data).write(to: file)
            let dir = (item.name as NSString).deletingLastPathComponent
            let name = "__MACOSX/" + (dir.isEmpty ? "" : dir + "/") + "._" + (item.name as NSString).lastPathComponent
            extra.append(ArchiveItem(name: name, sourcePath: file.path, kind: .file(size: Int64(data.count)),
                                     permissions: 0o644, modified: item.modified, uid: item.uid, gid: item.gid))
        }
        return (items + extra, folder)
    }

    public static func create(from sources: [URL], to archive: URL, options: CreateOptions = CreateOptions(),
                              progress: ProgressHandler? = nil, cancel: CancellationToken? = nil) throws -> WriteReport {
        if sources.isEmpty { throw XipperError.invalidArgument("nothing to archive") }
        if options.password != nil && !options.format.supportsPassword {
            throw XipperError.invalidArgument("\(options.format.rawValue) does not support passwords (use zip or 7z)")
        }
        if options.volumeSize != nil && options.format != .sevenZip {
            throw XipperError.invalidArgument("only 7z archives can be split into volumes")
        }
        var items = try SourceScanner.scan(sources, options: options.scan)
        var sidecars: URL?
        defer { if let sidecars { try? FileManager.default.removeItem(at: sidecars) } }
        if options.format == .zip && options.zipAppleDouble {
            (items, sidecars) = try appendAppleDouble(items)
        }
        let level = options.level ?? (options.format == .zip && options.zipMethod == .zstd ? 3 : options.format.defaultLevel)
        let path = archive.standardizedFileURL.path
        if items.contains(where: { $0.sourcePath == path }) { throw XipperError.invalidArgument("the archive cannot contain itself") }
        switch options.format {
        case .zip:
            var z = ZipOptions()
            z.method = options.zipMethod
            z.level = level
            z.password = options.password
            z.legacyZipCrypto = options.legacyZipCrypto
            z.storeAlreadyCompressed = options.storeAlreadyCompressed
            z.forceZip64 = options.forceZip64
            z.memoryBudget = options.memoryBudget
            z.workload = options.workload
            return try ZipWriter.write(items: items, to: path, options: z, overwrite: options.overwrite, progress: progress, cancel: cancel)
        case .tar, .tarGzip, .tarBzip2, .tarXz, .tarZstd:
            return try TarWriter.write(items: items, to: path, compression: options.format.compression, level: level,
                                       workload: options.workload, overwrite: options.overwrite,
                                       extendedAttributes: options.storeExtendedAttributes, progress: progress, cancel: cancel)
        case .sevenZip:
            var z = SevenZipOptions()
            z.level = level
            z.password = options.password
            z.encryptHeader = options.encryptFileNames
            z.solidBlockSize = options.solidBlockSize
            z.executableFilter = options.executableFilter
            z.storeAlreadyCompressed = options.storeAlreadyCompressed
            z.volumeSize = options.volumeSize
            z.workload = options.workload
            return try SevenZipWriter.write(items: items, to: path, options: z, overwrite: options.overwrite, progress: progress, cancel: cancel)
        case .appleArchive:
            return try AppleArchiveWriter.write(items: items, to: path, level: level, password: options.password,
                                                extendedAttributes: options.storeExtendedAttributes, overwrite: options.overwrite,
                                                progress: progress, cancel: cancel)
        case .cpio:
            return try CpioWriter.write(items: items, to: path, overwrite: options.overwrite, progress: progress, cancel: cancel)
        case .xiz:
            if options.password != nil { throw XipperError.unsupported("XIZ encryption is not available in the beta") }
            return try XizWriter.write(items: items, to: path, level: options.level ?? 3, extendedAttributes: options.storeExtendedAttributes,
                                       workload: options.workload, overwrite: options.overwrite, progress: progress, cancel: cancel)
        case .tarLz4, .lz4, .tarBrotli, .brotli:
            throw XipperError.unsupported("\(options.format.rawValue) archives can be read but not created")
        case .gzip, .bgzf, .bzip2, .xz, .zstd:
            guard items.count == 1 else { throw XipperError.invalidArgument("\(options.format.rawValue) compresses a single file; use a tar format for folders") }
            var compression = options.format.compression
            // Genomics preference: text formats indexed by tabix/samtools must be BGZF, not plain gzip.
            if compression == .gzip && options.genomicsUsesBGZF && Genomics.prefersBGZF(items[0].name) { compression = .bgzf }
            let index = compression == .bgzf && options.writeBGZFIndex ? path + ".gzi" : nil
            return try TarWriter.compressSingle(items[0], to: path, compression: compression, level: level,
                                                workload: options.workload, overwrite: options.overwrite, indexPath: index,
                                                progress: progress, cancel: cancel)
        }
    }

    // MARK: extract

    @discardableResult
    public static func extract(_ archive: URL, to directory: URL? = nil, mode: ExtractionMode = .smart,
                               options: ExtractOptions = ExtractOptions(), progress: ProgressHandler? = nil,
                               cancel: CancellationToken? = nil) throws -> ExtractReport {
        let archivePath = archive.standardizedFileURL.path
        guard let format = try ArchiveFormat.detect(archive) else { throw XipperError.unsupported("not a recognized archive") }
        let lower = archive.lastPathComponent.lowercased()
        if format == .bgzf && (lower.hasSuffix(".bam") || lower.hasSuffix(".bcf")) {
            throw XipperError.unsupported("BAM/BCF files are BGZF containers read directly by samtools/bcftools; use test to verify them")
        }
        let parent = (directory ?? archive.deletingLastPathComponent()).standardizedFileURL.path
        let tracker = ProgressTracker(totalBytes: 0, totalEntries: 0, handler: progress)

        let root: String
        switch mode {
        case .into:
            root = parent
        case .smart:
            root = parent + "/.xipper-\(UUID().uuidString.prefix(8)).partial"
            if mkdir(root, 0o755) != 0 { throw XipperError.posix("create folder", root) }
        }
        do {
            let ctx = try ExtractionContext(root: root, archivePath: archivePath, options: options)
            if format == .zip {
                let zip = try ZipArchive(path: archivePath)
                try ZipExtractor.extract(zip, ctx: ctx, password: options.password.map(ZipWriter.passwordBytes), tracker: tracker, cancel: cancel)
            } else if format == .sevenZip {
                let a = try SevenZipArchive(path: archivePath, password: options.password)
                try SevenZipExtractor.extract(a, ctx: ctx, tracker: tracker, cancel: cancel)
            } else if format == .xiz {
                try XizExtractor.extract(try XizArchive(path: archivePath), ctx: ctx, tracker: tracker, cancel: cancel)
            } else {
                try TarExtractor.extract(archivePath, ctx: ctx, tracker: tracker, cancel: cancel)
            }
            let destination = mode == .smart ? try promote(staging: root, parent: parent, archiveName: archive.lastPathComponent) : URL(fileURLWithPath: root)
            tracker.finish()
            let s = ctx.stats
            return ExtractReport(destination: destination, files: s.files, directories: s.dirs, symlinks: s.links,
                                 bytes: ctx.bytesWritten, skipped: ctx.skipped, elapsed: tracker.elapsed)
        } catch {
            if mode == .smart { try? FileManager.default.removeItem(atPath: root) }
            throw error
        }
    }

    /// Moves the staging folder's content into place (see `ExtractionMode.smart`).
    private static func promote(staging: String, parent: String, archiveName: String) throws -> URL {
        let top = try FileManager.default.contentsOfDirectory(atPath: staging)
        if top.count == 1 {
            let dest = try uniqueRename(staging + "/" + top[0], into: parent, name: top[0])
            try? FileManager.default.removeItem(atPath: staging)
            return dest
        }
        return try uniqueRename(staging, into: parent, name: baseName(archiveName))
    }

    private static func uniqueRename(_ from: String, into parent: String, name: String) throws -> URL {
        let (stem, ext) = ExtractionContext.split(name)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: from, isDirectory: &isDir)
        for n in 1...10_000 {
            let candidate = n == 1 ? name : (isDir.boolValue ? "\(name) \(n)" : "\(stem) \(n)\(ext)")
            let dest = parent + "/" + candidate
            if renamex_np(from, dest, UInt32(RENAME_EXCL)) == 0 { return URL(fileURLWithPath: dest) }
            if errno != EEXIST { throw XipperError.posix("rename", dest) }
        }
        throw XipperError.alreadyExists(path: parent + "/" + name)
    }

    /// "photos.tar.gz" → "photos" (name of the folder an archive extracts into).
    public static func baseName(_ archiveName: String) -> String {
        let lower = archiveName.lowercased()
        for ext in [".7z.001", ".7z", ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tgz", ".tbz2", ".tbz", ".txz", ".tzst", ".zip", ".tar", ".gz", ".bz2", ".xz", ".zst"]
            where lower.hasSuffix(ext) && lower.count > ext.count {
            return String(archiveName.dropLast(ext.count))
        }
        return archiveName + " (extracted)"
    }

    // MARK: test / list

    /// Verifies every entry without writing anything. With `digests`, also computes the SHA-256
    /// of each file's content (for a SHA256SUMS manifest) in the same pass.
    public static func test(_ archive: URL, password: String? = nil, workload: Workload = .interactive, digests: Bool = false,
                            progress: ProgressHandler? = nil, cancel: CancellationToken? = nil) throws -> TestReport {
        guard let format = try ArchiveFormat.detect(archive) else { throw XipperError.unsupported("not a recognized archive") }
        let tracker = ProgressTracker(totalBytes: 0, totalEntries: 0, handler: progress)
        let path = archive.standardizedFileURL.path
        let failures: [SkippedEntry]
        var entries = 0
        let sums: DigestCollector? = digests ? DigestCollector() : nil
        if format == .bgzf {
            (_, failures) = try BGZFVerifier.verify(path, workload: workload, tracker: tracker, cancel: cancel)
            entries = 1
        } else if format == .zip {
            let zip = try ZipArchive(path: path)
            entries = zip.records.count
            if password == nil, let enc = zip.records.first(where: { $0.entry.isEncrypted && $0.entry.kind == .file }) {
                throw XipperError.passwordRequired(entry: enc.entry.path)
            }
            failures = try ZipExtractor.test(zip, password: password.map(ZipWriter.passwordBytes), workload: workload, tracker: tracker,
                                             digests: sums, cancel: cancel)
        } else if format == .xiz {
            do {
                let a = try XizArchive(path: path)
                entries = a.catalog.entries.count
                failures = try XizExtractor.test(a, workload: workload, tracker: tracker, digests: sums, cancel: cancel)
            } catch let e as XipperError where e != .cancelled {
                // A catalog that cannot be read or validated fails the whole archive.
                entries = max(entries, 1)
                failures = [SkippedEntry(path: archive.lastPathComponent, error: e)]
            }
        } else if format == .sevenZip {
            do {
                let a = try SevenZipArchive(path: path, password: password)
                entries = a.entries.count
                failures = try SevenZipExtractor.test(a, workload: workload, tracker: tracker, cancel: cancel)
            } catch let e as XipperError {
                // Headers that cannot be read (truncation, wrong header password) fail the whole archive.
                switch e {
                case .passwordRequired, .cancelled, .unsupported, .io: throw e
                default:
                    entries = max(entries, 1)
                    failures = [SkippedEntry(path: archive.lastPathComponent, error: e)]
                }
            }
        } else {
            (entries, failures) = try TarExtractor.test(path, workload: workload, tracker: tracker, digests: sums, password: password, cancel: cancel)
        }
        tracker.finish()
        var report = TestReport(entries: entries, bytes: tracker.completedBytes, failures: failures, elapsed: tracker.elapsed)
        if let sums {
            let damaged = Set(failures.map(\.path))
            report.digests = sums.all.filter { !damaged.contains($0.key) }
        }
        return report
    }

    /// `password` is needed only for 7z archives with encrypted names.
    public static func list(_ archive: URL, password: String? = nil, workload: Workload = .interactive) throws -> [ArchiveEntry] {
        guard let format = try ArchiveFormat.detect(archive) else { throw XipperError.unsupported("not a recognized archive") }
        if format == .zip { return try ZipArchive(path: archive.standardizedFileURL.path).records.map(\.entry) }
        if format == .sevenZip { return try SevenZipArchive(path: archive.standardizedFileURL.path, password: password).entries }
        if format == .xiz { return try XizArchive(path: archive.standardizedFileURL.path).entries }
        return try TarExtractor.list(archive.standardizedFileURL.path, workload: workload, password: password)
    }
}

public struct EntryContent: Sendable {
    public var entry: ArchiveEntry
    /// At most the requested number of bytes.
    public var data: [UInt8]
    /// True when the entry is longer than what was returned.
    public var truncated: Bool
}

/// Thrown internally to stop decoding once enough bytes were collected.
private struct EnoughBytes: Error {}

extension Xipper {
    /// Reads the beginning (up to `maxBytes`) of one entry without extracting the archive.
    /// For single-file compressed streams (gz, BGZF, bz2, xz, zst) `path` is ignored.
    public static func readEntry(_ archive: URL, path: String, password: String? = nil, maxBytes: Int = 64 << 10,
                                 workload: Workload = .interactive) throws -> EntryContent {
        var data: [UInt8] = []
        var truncated = false
        var entry: ArchiveEntry?
        do {
            entry = try streamEntry(archive, path: path, password: password, workload: workload) { chunk in
                let room = maxBytes - data.count
                data.append(contentsOf: chunk.prefix(room))
                if chunk.count > room { truncated = true; throw EnoughBytes() }
            }
        } catch let stop as EntryStopped {
            entry = stop.entry
        }
        return EntryContent(entry: entry!, data: data, truncated: truncated)
    }

    /// Streams the content of one entry to `body`, in order, from byte `offset` on: the archive is
    /// never extracted to disk and only one chunk is in memory at a time (mounted archives, 7.x).
    /// XIZ jumps straight to the frame holding `offset`; the other formats decode and discard what
    /// comes before it. Symlinks give their target. For single-file compressed streams (gz, BGZF,
    /// bz2, xz, zst) `path` is ignored. Returns the entry (size -1 when the stream does not say).
    @discardableResult
    public static func streamEntry(_ archive: URL, path: String, password: String? = nil, from offset: Int64 = 0,
                                   workload: Workload = .interactive, cancel: CancellationToken? = nil,
                                   _ body: (UnsafeRawBufferPointer) throws -> Void) throws -> ArchiveEntry {
        guard let format = try ArchiveFormat.detect(archive) else { throw XipperError.unsupported("not a recognized archive") }
        let archivePath = archive.standardizedFileURL.path
        return try withoutActuallyEscaping(body) { body in
            var skip = max(0, offset)
            let sink: (UnsafeRawBufferPointer) throws -> Void = { chunk in
                if skip >= Int64(chunk.count) { skip -= Int64(chunk.count); return }
                let rest = UnsafeRawBufferPointer(rebasing: chunk[Int(skip)...])
                skip = 0
                try cancel?.check()
                try body(rest)
            }
            // A caller that stops early (EnoughBytes) still learns which entry it read.
            func run(_ entry: ArchiveEntry, _ work: () throws -> Void) throws -> ArchiveEntry {
                do { try work() } catch is EnoughBytes { throw EntryStopped(entry: entry) }
                return entry
            }
            if format == .zip {
                let zip = try ZipArchive(path: archivePath)
                guard let rec = zip.records.first(where: { $0.entry.path == path }) else {
                    throw XipperError.invalidArgument("no entry named \(path)")
                }
                guard rec.entry.kind == .file || rec.entry.kind == .symlink else { throw XipperError.invalidArgument("\(path) is a \(rec.entry.kind)") }
                return try run(rec.entry) {
                    try ZipEntryDecoder.decode(rec, in: zip, password: password.map(ZipWriter.passwordBytes), cancel: cancel, sink: sink)
                }
            }
            if format == .xiz {
                let a = try XizArchive(path: archivePath)
                guard let i = a.catalog.entries.firstIndex(where: { $0.path == path }) else {
                    throw XipperError.invalidArgument("no entry named \(path)")
                }
                let e = a.catalog.entries[i]
                return try run(a.entries[i]) {
                    if e.type == .symlink { return try Array(e.link.utf8).withUnsafeBytes(sink) }
                    var start: Int64 = 0
                    for x in e.extents {
                        let end = start + Int64(x.length)
                        defer { start = end }
                        if end <= offset { continue }  // random access: the frame is never read
                        let f = try a.frameData(Int(x.frame))
                        skip = max(0, offset - start)
                        try f[Int(x.offset)..<Int(x.offset + x.length)].withUnsafeBytes(sink)
                    }
                }
            }
            if format == .sevenZip {
                let a = try SevenZipArchive(path: archivePath, password: password)
                guard let rec = a.records.first(where: { $0.entry.path == path && !$0.isAnti }) else {
                    throw XipperError.invalidArgument("no entry named \(path)")
                }
                guard rec.entry.kind == .file || rec.entry.kind == .symlink else { throw XipperError.invalidArgument("\(path) is a \(rec.entry.kind)") }
                return try run(rec.entry) { try SevenZipExtractor.read(a, record: rec, sink: sink) }
            }
            // Entry streams: Apple Archive has its own reader, tar and cpio share the pipeline below.
            func stream(_ reader: EntryStreamReader) throws -> ArchiveEntry {
                while let e = try reader.next() {
                    try cancel?.check()
                    guard e.entry.path == path else { continue }
                    return try run(e.entry) {
                        if e.entry.kind == .symlink || e.entry.kind == .hardlink {
                            try Array((e.entry.linkTarget ?? "").utf8).withUnsafeBytes(sink)
                        } else {
                            try reader.readData(cancel: cancel, sink)
                        }
                    }
                }
                throw XipperError.invalidArgument("no entry named \(path)")
            }
            if format == .appleArchive { return try stream(try AppleArchiveReader(path: archivePath, password: password)) }
            let (pipe, source, isTar, _) = try TarExtractor.open(archivePath, workload: workload)
            defer { pipe.close() }
            if !isTar {
                let entry = ArchiveEntry(path: TarExtractor.singleFileName(archivePath), kind: .file, uncompressedSize: -1,
                                         compressedSize: 0, modified: nil, permissions: nil, encryption: .none,
                                         method: format.rawValue, linkTarget: nil)
                return try run(entry) {
                    let buf = UnsafeMutableRawPointer.allocate(byteCount: 1 << 16, alignment: 16)
                    defer { buf.deallocate() }
                    while true {
                        let n = try source.read(into: buf, max: 1 << 16)
                        if n == 0 { break }
                        try sink(UnsafeRawBufferPointer(start: buf, count: n))
                    }
                }
            }
            return try stream(Cpio.reader(for: source, head: source.head))
        }
    }
}

/// Carries the entry out of `streamEntry` when the caller stopped early.
private struct EntryStopped: Error { var entry: ArchiveEntry }

extension Xipper {
    /// Entries (files and links) whose destination already exists when extracting `archive` into
    /// `directory` (mode `.into`): lets the UI say "apply to the other N conflicts".
    public static func plannedConflicts(_ archive: URL, into directory: URL, selection: Set<String>? = nil,
                                        flatten: Bool = false, password: String? = nil) throws -> [String] {
        let root = directory.standardizedFileURL.path
        return try list(archive, password: password).filter { e in
            guard e.kind != .directory else { return false }
            if let selection, !selection.isEmpty,
               !(selection.contains(e.path) || selection.contains { e.path.hasPrefix($0 + "/") }) { return false }
            let rel = flatten ? (e.path as NSString).lastPathComponent : e.path
            return FileManager.default.fileExists(atPath: root + "/" + rel)
        }.map(\.path)
    }
}
