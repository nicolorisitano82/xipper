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

    public var fileExtension: String { self == .bgzf ? "gz" : rawValue }

    public var isTar: Bool { [.tar, .tarGzip, .tarBzip2, .tarXz, .tarZstd].contains(self) }
    public var isSingleFile: Bool { [.gzip, .bgzf, .bzip2, .xz, .zstd].contains(self) }
    public var supportsPassword: Bool { self == .zip }

    var compression: StreamCompression {
        switch self {
        case .zip, .tar: return .none
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
            (".zip", .zip), (".tar", .tar), (".bgz", .bgzf), (".bam", .bgzf), (".bcf", .bgzf), (".gz", .gzip), (".bz2", .bzip2), (".xz", .xz), (".zst", .zstd),
        ]
        return table.first { n.hasSuffix($0.0) }?.1
    }

    /// Detects the format from the file content (magic bytes), falling back to the name.
    public static func detect(_ url: URL) throws -> ArchiveFormat? {
        let r = try FileReader(path: url.path)
        let head = try r.read(at: 0, count: Int(min(r.size, 512)))
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) || head.starts(with: [0x50, 0x4B, 0x05, 0x06])
            || head.starts(with: [0x50, 0x4B, 0x07, 0x08]) { return .zip }  // 07 08: first part of a split ZIP
        let byName = inferred(fromFileName: url.lastPathComponent)
        switch StreamCompression.detect(head) {
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
    /// ZIP only (WinZip AES-256).
    public var password: String?
    public var zipMethod: ZipMethod = .deflate
    public var storeAlreadyCompressed = true
    /// tar formats: keep macOS extended attributes (Finder tags, resource forks…) as pax `SCHILY.xattr.*`.
    public var storeExtendedAttributes = true
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
    public static func create(from sources: [URL], to archive: URL, options: CreateOptions = CreateOptions(),
                              progress: ProgressHandler? = nil, cancel: CancellationToken? = nil) throws -> WriteReport {
        if sources.isEmpty { throw XipperError.invalidArgument("nothing to archive") }
        if options.password != nil && !options.format.supportsPassword {
            throw XipperError.invalidArgument("\(options.format.rawValue) does not support passwords (use zip)")
        }
        let items = try SourceScanner.scan(sources, options: options.scan)
        let level = options.level ?? (options.format == .zip && options.zipMethod == .zstd ? 3 : options.format.defaultLevel)
        let path = archive.standardizedFileURL.path
        if items.contains(where: { $0.sourcePath == path }) { throw XipperError.invalidArgument("the archive cannot contain itself") }
        switch options.format {
        case .zip:
            var z = ZipOptions()
            z.method = options.zipMethod
            z.level = level
            z.password = options.password
            z.storeAlreadyCompressed = options.storeAlreadyCompressed
            z.forceZip64 = options.forceZip64
            z.memoryBudget = options.memoryBudget
            z.workload = options.workload
            return try ZipWriter.write(items: items, to: path, options: z, overwrite: options.overwrite, progress: progress, cancel: cancel)
        case .tar, .tarGzip, .tarBzip2, .tarXz, .tarZstd:
            return try TarWriter.write(items: items, to: path, compression: options.format.compression, level: level,
                                       workload: options.workload, overwrite: options.overwrite,
                                       extendedAttributes: options.storeExtendedAttributes, progress: progress, cancel: cancel)
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
        for ext in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tgz", ".tbz2", ".tbz", ".txz", ".tzst", ".zip", ".tar", ".gz", ".bz2", ".xz", ".zst"]
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
        } else {
            (entries, failures) = try TarExtractor.test(path, workload: workload, tracker: tracker, digests: sums, cancel: cancel)
        }
        tracker.finish()
        var report = TestReport(entries: entries, bytes: tracker.completedBytes, failures: failures, elapsed: tracker.elapsed)
        if let sums {
            let damaged = Set(failures.map(\.path))
            report.digests = sums.all.filter { !damaged.contains($0.key) }
        }
        return report
    }

    public static func list(_ archive: URL, workload: Workload = .interactive) throws -> [ArchiveEntry] {
        guard let format = try ArchiveFormat.detect(archive) else { throw XipperError.unsupported("not a recognized archive") }
        if format == .zip { return try ZipArchive(path: archive.standardizedFileURL.path).records.map(\.entry) }
        return try TarExtractor.list(archive.standardizedFileURL.path, workload: workload)
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
        guard let format = try ArchiveFormat.detect(archive) else { throw XipperError.unsupported("not a recognized archive") }
        let archivePath = archive.standardizedFileURL.path
        var data: [UInt8] = []
        var truncated = false
        let collect: (UnsafeRawBufferPointer) throws -> Void = { chunk in
            let room = maxBytes - data.count
            data.append(contentsOf: chunk.prefix(room))
            if chunk.count > room { truncated = true; throw EnoughBytes() }
        }
        if format == .zip {
            let zip = try ZipArchive(path: archivePath)
            guard let rec = zip.records.first(where: { $0.entry.path == path }) else {
                throw XipperError.invalidArgument("no entry named \(path)")
            }
            guard rec.entry.kind == .file || rec.entry.kind == .symlink else { throw XipperError.invalidArgument("\(path) is a \(rec.entry.kind)") }
            do {
                try ZipEntryDecoder.decode(rec, in: zip, password: password.map(ZipWriter.passwordBytes), cancel: nil, sink: collect)
            } catch is EnoughBytes {}
            return EntryContent(entry: rec.entry, data: data, truncated: truncated)
        }
        let (pipe, source, isTar, _) = try TarExtractor.open(archivePath, workload: workload)
        defer { pipe.close() }
        if !isTar {
            do {
                let buf = UnsafeMutableRawPointer.allocate(byteCount: 1 << 16, alignment: 16)
                defer { buf.deallocate() }
                while true {
                    let n = try source.read(into: buf, max: 1 << 16)
                    if n == 0 { break }
                    try collect(UnsafeRawBufferPointer(start: buf, count: n))
                }
            } catch is EnoughBytes {}
            let entry = ArchiveEntry(path: TarExtractor.singleFileName(archivePath), kind: .file, uncompressedSize: -1,
                                     compressedSize: 0, modified: nil, permissions: nil, encryption: .none,
                                     method: format.rawValue, linkTarget: nil)
            return EntryContent(entry: entry, data: data, truncated: truncated)
        }
        let reader = TarReader(source: source)
        while let e = try reader.next() {
            guard e.entry.path == path else { continue }
            if e.entry.kind == .symlink || e.entry.kind == .hardlink {
                return EntryContent(entry: e.entry, data: Array((e.entry.linkTarget ?? "").utf8), truncated: false)
            }
            do { try reader.readData(cancel: nil, collect) } catch is EnoughBytes {}
            return EntryContent(entry: e.entry, data: data, truncated: truncated)
        }
        throw XipperError.invalidArgument("no entry named \(path)")
    }
}

extension Xipper {
    /// Entries (files and links) whose destination already exists when extracting `archive` into
    /// `directory` (mode `.into`): lets the UI say "apply to the other N conflicts".
    public static func plannedConflicts(_ archive: URL, into directory: URL, selection: Set<String>? = nil,
                                        flatten: Bool = false) throws -> [String] {
        let root = directory.standardizedFileURL.path
        return try list(archive).filter { e in
            guard e.kind != .directory else { return false }
            if let selection, !selection.isEmpty,
               !(selection.contains(e.path) || selection.contains { e.path.hasPrefix($0 + "/") }) { return false }
            let rel = flatten ? (e.path as NSString).lastPathComponent : e.path
            return FileManager.default.fileExists(atPath: root + "/" + rel)
        }.map(\.path)
    }
}
