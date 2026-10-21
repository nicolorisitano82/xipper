import Darwin
import Foundation

public enum ArchiveFormat: String, Sendable, CaseIterable {
    case zip
    case tar
    case tarGzip = "tar.gz"
    case tarBzip2 = "tar.bz2"
    case tarXz = "tar.xz"
    case tarZstd = "tar.zst"
    /// Single file compressed without tar.
    case gzip = "gz"
    case bzip2 = "bz2"
    case xz
    case zstd = "zst"

    public var fileExtension: String { rawValue }

    public var isTar: Bool { [.tar, .tarGzip, .tarBzip2, .tarXz, .tarZstd].contains(self) }
    public var isSingleFile: Bool { [.gzip, .bzip2, .xz, .zstd].contains(self) }
    public var supportsPassword: Bool { self == .zip }

    var compression: StreamCompression {
        switch self {
        case .zip, .tar: return .none
        case .tarGzip, .gzip: return .gzip
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
            (".zip", .zip), (".tar", .tar), (".gz", .gzip), (".bz2", .bzip2), (".xz", .xz), (".zst", .zstd),
        ]
        return table.first { n.hasSuffix($0.0) }?.1
    }

    /// Detects the format from the file content (magic bytes), falling back to the name.
    public static func detect(_ url: URL) throws -> ArchiveFormat? {
        let r = try FileReader(path: url.path)
        let head = try r.read(at: 0, count: Int(min(r.size, 512)))
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) || head.starts(with: [0x50, 0x4B, 0x05, 0x06]) { return .zip }
        let byName = inferred(fromFileName: url.lastPathComponent)
        switch StreamCompression.detect(head) {
        case .gzip: return byName == .gzip ? .gzip : .tarGzip
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
    public var forceZip64 = false
    public var scan = ScanOptions()
    public var workload: Workload = .interactive
    /// Replace an existing archive at the destination.
    public var overwrite = false
    public var memoryBudget = 512 << 20
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
    public var isOK: Bool { failures.isEmpty }
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
                                       workload: options.workload, overwrite: options.overwrite, progress: progress, cancel: cancel)
        case .gzip, .bzip2, .xz, .zstd:
            guard items.count == 1 else { throw XipperError.invalidArgument("\(options.format.rawValue) compresses a single file; use a tar format for folders") }
            return try TarWriter.compressSingle(items[0], to: path, compression: options.format.compression, level: level,
                                                workload: options.workload, overwrite: options.overwrite, progress: progress, cancel: cancel)
        }
    }

    // MARK: extract

    @discardableResult
    public static func extract(_ archive: URL, to directory: URL? = nil, mode: ExtractionMode = .smart,
                               options: ExtractOptions = ExtractOptions(), progress: ProgressHandler? = nil,
                               cancel: CancellationToken? = nil) throws -> ExtractReport {
        let archivePath = archive.standardizedFileURL.path
        guard let format = try ArchiveFormat.detect(archive) else { throw XipperError.unsupported("not a recognized archive") }
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

    /// "photos.tar.gz" → "photos".
    static func baseName(_ archiveName: String) -> String {
        let lower = archiveName.lowercased()
        for ext in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tgz", ".tbz2", ".tbz", ".txz", ".tzst", ".zip", ".tar", ".gz", ".bz2", ".xz", ".zst"]
            where lower.hasSuffix(ext) && lower.count > ext.count {
            return String(archiveName.dropLast(ext.count))
        }
        return archiveName + " (extracted)"
    }

    // MARK: test / list

    public static func test(_ archive: URL, password: String? = nil, workload: Workload = .interactive,
                            progress: ProgressHandler? = nil, cancel: CancellationToken? = nil) throws -> TestReport {
        guard let format = try ArchiveFormat.detect(archive) else { throw XipperError.unsupported("not a recognized archive") }
        let tracker = ProgressTracker(totalBytes: 0, totalEntries: 0, handler: progress)
        let path = archive.standardizedFileURL.path
        let failures: [SkippedEntry]
        var entries = 0
        if format == .zip {
            let zip = try ZipArchive(path: path)
            entries = zip.records.count
            if password == nil, let enc = zip.records.first(where: { $0.entry.isEncrypted && $0.entry.kind == .file }) {
                throw XipperError.passwordRequired(entry: enc.entry.path)
            }
            failures = try ZipExtractor.test(zip, password: password.map(ZipWriter.passwordBytes), workload: workload, tracker: tracker, cancel: cancel)
        } else {
            (entries, failures) = try TarExtractor.test(path, workload: workload, tracker: tracker, cancel: cancel)
        }
        tracker.finish()
        return TestReport(entries: entries,
                          bytes: tracker.completedBytes, failures: failures, elapsed: tracker.elapsed)
    }

    public static func list(_ archive: URL, workload: Workload = .interactive) throws -> [ArchiveEntry] {
        guard let format = try ArchiveFormat.detect(archive) else { throw XipperError.unsupported("not a recognized archive") }
        if format == .zip { return try ZipArchive(path: archive.standardizedFileURL.path).records.map(\.entry) }
        return try TarExtractor.list(archive.standardizedFileURL.path, workload: workload)
    }
}
