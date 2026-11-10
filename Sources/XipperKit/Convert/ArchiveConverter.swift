import CryptoKit
import CZstd
import Foundation

/// What converting an archive to another format will do, entry by entry (`Xipper.conversionPlan`).
public struct ConversionPlan: Sendable {
    public enum Action: String, Sendable, Codable {
        /// Compressed bytes copied as they are into the new format (same codec on both sides).
        case copied
        /// Decompressed and compressed again with the target's settings.
        case recompressed
    }

    /// Something the new archive will not have.
    public enum Loss: Sendable, Equatable, Codable {
        /// XIZ signed history or access groups, Apple Archive signature.
        case signatures
        case accessGroups
        /// PAR2 files next to the source protect the old bytes only.
        case recoveryData(String)
        /// The target has no password, the source had one.
        case encryption
    }

    public struct Item: Sendable, Codable {
        public var path: String
        public var action: Action
        /// Uncompressed size; for copied entries also the compressed bytes moved.
        public var size: Int64
        public var compressedSize: Int64
        /// Why an entry is recompressed (method not in the target, encrypted, solid block…).
        public var reason: String?
    }

    public var source: URL
    public var sourceFormat: ArchiveFormat
    public var format: ArchiveFormat
    /// Files with data, in archive order (folders, links and empty files are always rewritten).
    public var items: [Item]
    public var losses: [Loss]
    /// Recompressed entries go straight from the source into the new archive, without being
    /// unpacked on disk first (tar targets).
    public var streamed = false
    /// Size of the source archive: the estimate of the new one when entries have no compressed size of their own (tar, XIZ).
    public var sourceBytes: Int64 = 0

    public var copied: Int { items.filter { $0.action == .copied }.count }
    public var recompressed: Int { items.filter { $0.action == .recompressed }.count }
    public var bytesCopied: Int64 { items.filter { $0.action == .copied }.reduce(0) { $0 + $1.compressedSize } }
    public var bytesRecompressed: Int64 { items.filter { $0.action == .recompressed }.reduce(0) { $0 + $1.size } }
    /// Extra disk space the conversion needs next to the target: the recompressed entries
    /// unpacked once (not when streamed), plus the new archive (estimated from the source's
    /// compressed sizes).
    public var spaceNeeded: Int64 {
        (streamed ? 0 : bytesRecompressed) + max(sourceBytes, items.reduce(0) { $0 + $1.compressedSize })
    }
}

public struct FormatChangeReport: Sendable {
    public var plan: ConversionPlan
    public var output: URL
    public var outputBytes: Int64
    public var elapsed: Double
    /// The original moved to the Trash after the new archive was verified.
    public var originalTrashed: Bool
    /// Little free space: the original was released into the new archive as it was converted,
    /// and removed at the end.
    public var originalReleased = false
}

extension Xipper {
    /// The plan for converting `source` to `format` with `options` (its password and method):
    /// which entries keep their compressed bytes and which are recompressed, and what is lost.
    public static func conversionPlan(_ source: URL, to format: ArchiveFormat, password: String? = nil,
                                      options: CreateOptions = CreateOptions()) throws -> ConversionPlan {
        try ArchiveConverter(source: source, format: format, password: password, options: options).plan
    }

    /// Converts `source` into a new archive at `target` in `options.format`. Entries whose codec
    /// the target also has are copied without recompressing them (ZIP ↔ 7z: store, Deflate,
    /// Deflate64, bzip2, LZMA; 7z LZMA2 → ZIP xz; ZIP Deflate/bzip2/zstd/xz → tar.gz/.bz2/.zst/.xz;
    /// ZIP zstd → XIZ); the others are unpacked once in a work folder next to the target and
    /// compressed again. The new archive is written under a temporary name, verified (test plus
    /// the same entries, sizes and CRCs as the source) and only then given its name; with
    /// `trashOriginal` the source then goes to the Trash. Nothing of the source is changed before.
    @discardableResult
    public static func convert(_ source: URL, to target: URL, password: String? = nil, options: CreateOptions,
                               trashOriginal: Bool = false, progress: ProgressHandler? = nil,
                               cancel: CancellationToken? = nil) throws -> FormatChangeReport {
        try ArchiveConverter(source: source, format: options.format, password: password, options: options)
            .run(to: target, trashOriginal: trashOriginal, progress: progress, cancel: cancel)
    }
}

struct ArchiveConverter {
    let source: URL
    let format: ArchiveFormat
    let password: String?
    let options: CreateOptions
    let sourceFormat: ArchiveFormat
    let entries: [ArchiveEntry]
    let plan: ConversionPlan
    /// ZIP source: what is carried per raw-copied path. 7z source: the same for folders.
    private var zipRaw: [String: ZipCarry] = [:]
    private var sevenZipRaw: [String: SevenZipCarry] = [:]

    /// A ZIP entry whose compressed bytes go into the target as they are.
    struct ZipCarry {
        var record: ZipEntryRecord
        /// Where the codec's own data starts and how long it is (ZIP LZMA: after its 9-byte header).
        var offset: Int64
        var size: Int64
        /// 7z target: the coder (with its properties) that reads those bytes.
        var coder = SZCoder(method: 0)
    }

    /// A one-file 7z folder whose packed stream becomes a ZIP entry, between `prefix` and `suffix`
    /// (ZIP LZMA header; xz container around LZMA2).
    struct SevenZipCarry {
        var folder: Int
        var method: UInt16
        var prefix: [UInt8] = []
        var suffix: [UInt8] = []
    }
    private var zip: ZipArchive?
    /// AppleDouble entries (`._name`, `__MACOSX/`): unpacked with their files so they merge into them.
    private var appleDoublePaths: [String] = []
    private var sevenZip: SevenZipArchive?

    /// ZIP method ↔ 7z coder for the codecs both formats share (7-Zip's Methods.txt).
    static let shared: [(zip: UInt16, sevenZip: UInt64)] = [
        (Zip.Method.store.rawValue, SevenZip.Method.copy), (Zip.Method.deflate.rawValue, SevenZip.Method.deflate),
        (Zip.Method.deflate64.rawValue, SevenZip.Method.deflate64), (Zip.Method.bzip2.rawValue, SevenZip.Method.bzip2),
        (Zip.Method.lzma.rawValue, SevenZip.Method.lzma),
    ]

    /// ZIP method whose data is a complete member of the compressed stream of these tar formats:
    /// a raw Deflate stream inside a gzip member, a whole bzip2, zstd or xz stream.
    static let tarMembers: [ArchiveFormat: UInt16] = [
        .tarGzip: Zip.Method.deflate.rawValue, .tarBzip2: Zip.Method.bzip2.rawValue,
        .tarZstd: Zip.Method.zstd.rawValue, .tarXz: Zip.Method.xz.rawValue,
    ]

    /// ZIP LZMA (method 14) header: LZMA SDK version 9.20, properties size 5, then the 5 properties.
    static func zipLZMAHeader(_ props: [UInt8]) -> [UInt8] { [9, 20, 5, 0] + props }

    init(source: URL, format: ArchiveFormat, password: String?, options: CreateOptions) throws {
        self.source = source.standardizedFileURL
        self.format = format
        self.password = password
        self.options = options
        guard let sf = try ArchiveFormat.detect(source) else { throw XipperError.unsupported("not a recognized archive") }
        sourceFormat = sf
        guard format.canCreate, !format.isSingleFile else { throw XipperError.unsupported("Xipper cannot write \(format.rawValue) archives") }
        if sf.isSingleFile || sf == .bgzf { throw XipperError.unsupported("\(sf.rawValue) holds a single file, not an archive: compress the file instead") }
        if options.volumeSize != nil { throw XipperError.unsupported("converting into volumes: convert first, then split") }
        let path = self.source.path
        entries = try Xipper.list(source, password: password).filter { !$0.isAppleDoubleMetadata }
        // Paths with AppleDouble companions: their metadata is merged on extraction, so they go
        // through extraction too, or a copied entry would lose its resource fork and tags.
        let all = try Xipper.list(source, password: password)
        appleDoublePaths = all.filter(\.isAppleDoubleMetadata).map(\.path)
        var sidecars = Set<String>()
        for e in all where e.isAppleDoubleMetadata {
            var p = e.path
            if p.hasPrefix("__MACOSX/") { p.removeFirst(9) }
            let dir = (p as NSString).deletingLastPathComponent, name = (p as NSString).lastPathComponent
            if name.hasPrefix("._") { sidecars.insert(dir.isEmpty ? String(name.dropFirst(2)) : dir + "/" + name.dropFirst(2)) }
        }

        var reasons: [String: String] = [:]
        let rawAllowed = options.password == nil
        // ZIP → XIZ: zstd entries up to a frame's limit become one frame each.
        let tarMethod = format == .xiz ? (options.xizCodec == .zstd ? Zip.Method.zstd.rawValue : nil) : Self.tarMembers[format]
        if sf == .zip && (format == .sevenZip || tarMethod != nil) && ZipArchive.volumes(for: path).count == 1 {
            let z = try ZipArchive(path: path)
            zip = z
            let target = format == .sevenZip ? "7z" : format.rawValue
            for r in z.records where r.entry.kind == .file && r.entry.uncompressedSize > 0 {
                let method = r.entry.encryption == .none ? r.method : UInt16.max
                let coder = Self.shared.first(where: { $0.zip == method })?.sevenZip
                if !rawAllowed { reasons[r.entry.path] = "the new archive is encrypted" }
                else if r.entry.encryption != .none { reasons[r.entry.path] = "encrypted entry" }
                else if tarMethod.map({ $0 != method }) ?? (coder == nil) { reasons[r.entry.path] = "\(r.entry.method) is not a \(target) codec Xipper copies" }
                else if r.entry.crc32 == nil { reasons[r.entry.path] = "no CRC" }
                else if sidecars.contains(r.entry.path) { reasons[r.entry.path] = "has macOS metadata to merge" }
                else if format == .xiz && (r.uncompressedSize > Xiz.maxFrameData || r.compressedSize > Xiz.maxFrameData) {
                    reasons[r.entry.path] = "larger than a XIZ frame (64 MiB)"
                } else {
                    var c = ZipCarry(record: r, offset: try z.dataOffset(r), size: r.compressedSize)
                    if let coder { c.coder = SZCoder(method: coder) }
                    if tarMethod == nil && method == Zip.Method.lzma.rawValue {
                        // 7z keeps the 5 LZMA properties in the coder, ZIP before the data.
                        let h = r.compressedSize > 9 ? try z.reader.read(at: c.offset, count: 9) : []
                        guard h.count == 9, h[2] == 5, h[3] == 0 else { reasons[r.entry.path] = "unusual LZMA header"; continue }
                        c.coder.props = Array(h[4..<9])
                        c.offset += 9
                        c.size -= 9
                    }
                    zipRaw[r.entry.path] = c
                }
            }
        } else if sf == .sevenZip && format == .zip {
            let a = try SevenZipArchive(path: path, password: password)
            sevenZip = a
            if a.input.volumes.count == 1 {
                for (fi, members) in a.folderRecords.enumerated() {
                    let f = a.streams.folders[fi]
                    for m in members {
                        let r = a.records[m]
                        guard r.entry.kind == .file, r.size > 0 else { continue }
                        if !rawAllowed { reasons[r.entry.path] = "the new archive is encrypted" }
                        else if f.isEncrypted { reasons[r.entry.path] = "encrypted folder" }
                        else if members.count != 1 { reasons[r.entry.path] = "solid block of \(members.count) files" }
                        else if r.crc == nil { reasons[r.entry.path] = "no CRC" }
                        else if let c = try Self.zipCarry(a, folder: fi, crc: r.crc!, size: r.size) { sevenZipRaw[r.entry.path] = c }
                        else {
                            reasons[r.entry.path] = "\(f.coders.map { SevenZip.Method.name($0.method) }.joined(separator: "+")) is not a ZIP method Xipper copies"
                        }
                    }
                }
            }
        }

        var losses: [ConversionPlan.Loss] = []
        if sf == .xiz, try XizArchive.hasDirectory(path) { losses += [.signatures, .accessGroups] }
        if sf == .appleArchive && AppleArchiveReader.isAEA(path) && !AppleArchiveReader.isEncrypted(path) { losses.append(.signatures) }
        if password != nil && options.password == nil { losses.append(.encryption) }
        let dir = self.source.deletingLastPathComponent(), stem = self.source.deletingPathExtension().lastPathComponent
        if let par2 = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .first(where: { $0.hasPrefix(stem) && $0.lowercased().hasSuffix(".par2") }) {
            losses.append(.recoveryData(par2))
        }
        let copiedPaths = Set(zipRaw.keys).union(sevenZipRaw.keys)
        let items = entries.filter { $0.kind == .file && $0.uncompressedSize > 0 }.map { e -> ConversionPlan.Item in
            let copied = copiedPaths.contains(e.path)
            return ConversionPlan.Item(path: e.path, action: copied ? .copied : .recompressed, size: e.uncompressedSize,
                                       compressedSize: max(0, e.compressedSize),
                                       reason: copied ? nil : reasons[e.path] ?? "\(sf.rawValue) → \(format.rawValue) has no shared codec")
        }
        var plan = ConversionPlan(source: self.source, sourceFormat: sf, format: format, items: items, losses: losses)
        // Streaming needs a sequential target, and nothing that only exists once unpacked:
        // AppleDouble companions merge on disk, hard links point at files on disk.
        plan.streamed = Self.streamTargets.contains(format) && sidecars.isEmpty && !entries.contains { $0.kind == .hardlink }
        plan.sourceBytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        self.plan = plan
    }

    static let streamTargets: Set<ArchiveFormat> = [.tar, .tarGzip, .tarBzip2, .tarXz, .tarZstd, .tarLz4, .tarBrotli]

    /// How a one-file 7z folder becomes a ZIP entry without recompressing it, if it can: shared
    /// codecs as they are, LZMA behind the ZIP LZMA header, LZMA2 inside an xz container (method 95)
    /// whose CRC-32 check is the file's CRC.
    static func zipCarry(_ a: SevenZipArchive, folder fi: Int, crc: UInt32, size: Int64) throws -> SevenZipCarry? {
        let f = a.streams.folders[fi]
        guard f.coders.count == 1, f.packedStreams.count == 1 else { return nil }
        let coder = f.coders[0]
        if coder.method == SevenZip.Method.lzma {
            guard coder.props.count == 5 else { return nil }
            return SevenZipCarry(folder: fi, method: Zip.Method.lzma.rawValue, prefix: zipLZMAHeader(coder.props))
        }
        if coder.method == SevenZip.Method.lzma2 {
            // xz needs the LZMA2 end marker as the last byte.
            let pack = f.firstPackStream, packSize = a.streams.packSizes[pack]
            guard coder.props.count == 1, coder.props[0] <= 40, packSize > 0,
                  try a.input.read(at: a.packOffsets[pack] + packSize - 1, count: 1) == [0] else { return nil }
            let (prefix, suffix) = try XzContainer.wrapLZMA2(prop: coder.props[0], packedSize: packSize, size: size, crc: crc)
            return SevenZipCarry(folder: fi, method: Zip.Method.xz.rawValue, prefix: prefix, suffix: suffix)
        }
        guard let method = shared.first(where: { $0.sevenZip == coder.method })?.zip else { return nil }
        return SevenZipCarry(folder: fi, method: method)
    }

    /// Whether an LZMA stream of known size ends with an end marker. Decoded as if one more byte
    /// were due: with the marker the stream ends at `size`, without it the input runs out there.
    static func lzmaHasEndMarker(props: [UInt8], size: Int64, packSize: Int64, read: (Int64, Int) throws -> [UInt8],
                                 cancel: CancellationToken?) throws -> Bool {
        let d = try SDKLZMADecoder(props: props, unpackSize: size + 1)
        var produced: Int64 = 0
        let sink: ByteSink = { produced += Int64($0.count) }
        var off: Int64 = 0
        while off < packSize {
            try cancel?.check()
            let n = Int(min(Int64(4 << 20), packSize - off))
            try read(off, n).withUnsafeBytes { try d.process($0, sink) }
            off += Int64(n)
        }
        let marked = (try? d.finish(sink)) != nil
        guard produced == size else { throw XipperError.corrupt("7z LZMA stream size") }
        return marked
    }

    // MARK: running

    func run(to target: URL, trashOriginal: Bool, progress: ProgressHandler?, cancel: CancellationToken?) throws -> FormatChangeReport {
        let start = Date()
        let target = target.standardizedFileURL
        if target.path == source.path { throw XipperError.invalidArgument("the new archive needs another name than the original") }
        if !options.overwrite && FileManager.default.fileExists(atPath: target.path) { throw XipperError.alreadyExists(path: target.path) }
        // Work folder next to the target: same volume, so the final rename is atomic and the
        // space check counts the right disk.
        let parent = target.deletingLastPathComponent()
        Self.removeAbandonedWork(in: parent)
        let work = parent.appendingPathComponent(".xipper-convert-\(getpid())-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        if let free = ExtractionContext.volumeSpace(work.path, fd: -1)?.free, free < plan.spaceNeeded + (64 << 20) {
            throw XipperError.insufficientSpace(needed: plan.spaceNeeded, available: free)
        }
        let staged = work.appendingPathComponent("new." + format.fileExtension)
        var o = options
        o.overwrite = true

        if plan.streamed {
            try runStreamed(to: staged, options: o, progress: progress, cancel: cancel)
        } else {
            try runUnpacked(work: work, to: staged, options: o, progress: progress, cancel: cancel)
        }

        // 3. Verified before it gets its name.
        try verify(staged)
        let flags: UInt32 = options.overwrite ? 0 : UInt32(RENAME_EXCL)
        if renamex_np(staged.path, target.path, flags) != 0 {
            if errno == EEXIST { throw XipperError.alreadyExists(path: target.path) }
            throw XipperError.posix("rename", target.path)
        }
        let dirFD = open(target.deletingLastPathComponent().path, O_RDONLY)
        if dirFD >= 0 { _ = OutputFile.fullSync(dirFD); close(dirFD) }
        var trashed = false
        if trashOriginal {
            try FileManager.default.trashItem(at: source, resultingItemURL: nil)
            trashed = true
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
        return FormatChangeReport(plan: plan, output: target, outputBytes: size, elapsed: Date().timeIntervalSince(start), originalTrashed: trashed)
    }

    /// Tar targets: the source's extractor writes each entry straight into the new tar
    /// (TarStream), copied entries are added as members; nothing is unpacked on disk.
    private func runStreamed(to staged: URL, options o: CreateOptions, progress: ProgressHandler?, cancel: CancellationToken?) throws {
        let total = plan.items.reduce(Int64(0)) { $0 + $1.size }
        let tracker = ProgressTracker(totalBytes: total, totalEntries: entries.count, handler: progress)
        let stream = try TarStream(path: staged.path, compression: format.compression, level: o.level ?? format.defaultLevel,
                                   workload: o.workload, tracker: tracker, cancel: cancel)
        let copied = Set(zipRaw.keys)
        // Only files and links are selected: selecting a folder selects everything in it.
        let rest = entries.filter { $0.kind != .directory && !copied.contains($0.path) }
        if !rest.isEmpty {
            var x = ExtractOptions()
            x.password = password
            x.selection = Set(rest.map(\.path))
            x.propagateQuarantine = false
            x.symlinks = .allowAll  // re-archived, never followed
            x.mergeAppleDouble = false
            x.workload = o.workload
            x.restoreExtendedAttributes = o.storeExtendedAttributes
            let ctx = try ExtractionContext(root: staged.deletingLastPathComponent().path, archivePath: source.path, options: x, redirect: stream)
            try Xipper.runExtractor(sourceFormat, source.path, ctx: ctx, tracker: ProgressTracker(totalBytes: 0, totalEntries: 0, handler: nil),
                                    cancel: cancel)
            if let s = ctx.skipped.first { throw XipperError.integrity(entry: s.path, detail: "not carried over: \(s.reason)") }
        }
        if let zip {
            let read: (Int64, Int) throws -> [UInt8] = { try zip.reader.read(at: $0, count: $1) }
            for e in entries {
                guard let c = zipRaw[e.path] else { continue }
                let r = c.record
                let member = format == .tarGzip
                    ? TarCarriedMember.gzip(offset: c.offset, size: c.size, crc: r.crc, length: r.uncompressedSize, read: read)
                    : TarCarriedMember(offset: c.offset, size: c.size, read: read)
                try stream.carried(ArchiveItem(name: MountedArchive.normalize(e.path) ?? e.path, sourcePath: "", kind: .file(size: r.uncompressedSize),
                                               permissions: e.permissions ?? 0o644, modified: e.modified ?? Date(), uid: getuid(), gid: getgid()),
                                   member)
            }
        }
        // Folders as entries (empty ones included), with their dates and permissions.
        for e in entries where e.kind == .directory {
            guard let rel = MountedArchive.normalize(e.path), !rel.isEmpty else { continue }
            try stream.directory(rel, permissions: e.permissions, modified: e.modified, xattrs: [])
        }
        try stream.finish()
        tracker.finish()
    }

    /// Other targets: what is not copied is unpacked once in the work folder, then archived.
    private func runUnpacked(work: URL, to staged: URL, options o: CreateOptions, progress: ProgressHandler?, cancel: CancellationToken?) throws {
        // 1. Everything not copied: unpacked once (files, links, folders, empty files).
        let tree = work.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        let copied = Set(zipRaw.keys).union(sevenZipRaw.keys)
        let unpack = entries.filter { $0.kind != .directory && !copied.contains($0.path) }.map(\.path)
        if !unpack.isEmpty {
            var x = ExtractOptions()
            x.password = password
            x.selection = Set(unpack + appleDoublePaths)
            x.overwrite = .replace
            x.propagateQuarantine = false
            x.symlinks = .allowAll  // re-archived, never followed
            _ = try Xipper.extract(source, to: tree, mode: .into, options: x, progress: progress, cancel: cancel)
        }
        // Folders as entries (empty ones included), with their dates and permissions.
        for e in entries where e.kind == .directory {
            guard let rel = MountedArchive.normalize(e.path), !rel.isEmpty else { continue }
            let d = tree.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            var attrs: [FileAttributeKey: Any] = [:]
            if let p = e.permissions { attrs[.posixPermissions] = Int(p | 0o700) }
            if let m = e.modified { attrs[.modificationDate] = m }
            try? FileManager.default.setAttributes(attrs, ofItemAtPath: d.path)
        }
        var scan = o.scan
        scan.excludeMacMetadata = false  // what the source holds, including .DS_Store
        let top = try FileManager.default.contentsOfDirectory(at: tree, includingPropertiesForKeys: nil)
        let items = top.isEmpty ? [] : try SourceScanner.scan(top, options: scan)

        // 2. The new archive.
        if !zipRaw.isEmpty, let zip, format == .xiz {
            try writeXiz(items: items, raw: zip, to: staged, options: o, progress: progress, cancel: cancel)
        } else if !zipRaw.isEmpty, let zip, Self.tarMembers[format] != nil {
            try writeTar(items: items, raw: zip, to: staged, options: o, progress: progress, cancel: cancel)
        } else if !zipRaw.isEmpty, let zip {
            try writeSevenZip(items: items, raw: zip, to: staged, options: o, progress: progress, cancel: cancel)
        } else if !sevenZipRaw.isEmpty, let sevenZip {
            try writeZip(items: items, raw: sevenZip, work: work, to: staged, options: o, progress: progress, cancel: cancel)
        } else {
            guard !top.isEmpty else { throw XipperError.invalidArgument("the archive is empty") }
            _ = try Xipper.create(from: top.sorted { $0.lastPathComponent < $1.lastPathComponent }, to: staged, options: o,
                                  progress: progress, cancel: cancel)
        }
    }

    /// Work folders of conversions whose process is gone (killed, crashed, power cut): the
    /// source was never touched, the half-written archive never got its name, so they only hold
    /// temporary files. A live process keeps its own.
    static func removeAbandonedWork(in dir: URL) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(".xipper-convert-") {
            let pidText = name.dropFirst(".xipper-convert-".count).prefix { $0.isNumber }
            guard let pid = pid_t(pidText), pid != getpid(), kill(pid, 0) != 0, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// ZIP → 7z: each copied entry becomes a one-coder, non-solid folder holding its bytes.
    private func writeSevenZip(items: [ArchiveItem], raw zip: ZipArchive, to staged: URL, options o: CreateOptions,
                               progress: ProgressHandler?, cancel: CancellationToken?) throws {
        var carried: [SevenZipCarriedFolder] = []
        for e in entries {
            guard let c = zipRaw[e.path] else { continue }
            let r = c.record
            var folder = SZFolder()
            folder.coders = [c.coder]
            folder.packedStreams = [0]
            folder.unpackSizes = [r.uncompressedSize]
            let item = ArchiveItem(name: MountedArchive.normalize(e.path) ?? e.path, sourcePath: "", kind: .file(size: r.uncompressedSize),
                                   permissions: e.permissions ?? 0o644, modified: e.modified ?? Date(), uid: getuid(), gid: getgid())
            carried.append(SevenZipCarriedFolder(read: { try zip.reader.read(at: $0, count: $1) }, folder: folder,
                                                 packs: [(c.offset, c.size)], subSizes: [r.uncompressedSize],
                                                 subCRCs: [r.crc], files: [SevenZipWriter.fileRecord(item, hasStream: true)]))
        }
        var z = SevenZipOptions()
        z.level = o.level ?? ArchiveFormat.sevenZip.defaultLevel
        z.password = o.password
        z.encryptHeader = o.password != nil && o.encryptFileNames
        z.solidBlockSize = o.solidBlockSize
        z.executableFilter = o.executableFilter
        z.storeAlreadyCompressed = o.storeAlreadyCompressed
        z.workload = o.workload
        _ = try SevenZipWriter.write(items: items, to: staged.path, options: z, overwrite: true, carried: carried,
                                     progress: progress, cancel: cancel)
    }

    /// ZIP zstd → XIZ: each copied entry's zstd frame becomes a XIZ frame as it is. The entry is
    /// decoded once, for the SHA-256 XIZ keeps and to check it against the ZIP CRC; an entry made
    /// of several zstd frames (XIZ wants one) is compressed again from that decoded copy.
    private func writeXiz(items: [ArchiveItem], raw zip: ZipArchive, to staged: URL, options o: CreateOptions,
                          progress: ProgressHandler?, cancel: CancellationToken?) throws {
        var carried: [XizCarriedFrame] = []
        for e in entries {
            guard let c = zipRaw[e.path] else { continue }
            try cancel?.check()
            let r = c.record
            var payload = try zip.reader.read(at: c.offset, count: Int(c.size))
            let size = Int(r.uncompressedSize)
            let data = try payload.withUnsafeBytes { try Xiz.zstdDecompress($0, size: size) }
            guard data.withUnsafeBytes({ CRC32.checksum($0) }) == r.crc else {
                throw XipperError.checksumMismatch(entry: e.path, expected: r.crc, actual: data.withUnsafeBytes { CRC32.checksum($0) })
            }
            if payload.withUnsafeBytes({ ZSTD_findFrameCompressedSize($0.baseAddress, $0.count) }) != payload.count {
                payload = data.withUnsafeBytes { ZipWriter.zstdCompress($0, level: o.level ?? 3, allowExpansion: true) } ?? []
            }
            let item = ArchiveItem(name: MountedArchive.normalize(e.path) ?? e.path, sourcePath: "", kind: .file(size: r.uncompressedSize),
                                   permissions: e.permissions ?? 0o644, modified: e.modified ?? Date(), uid: getuid(), gid: getgid())
            carried.append(XizCarriedFrame(item: item, payload: payload, sha256: Array(SHA256.hash(data: data))))
        }
        _ = try XizWriter.write(items: items, to: staged.path, level: o.level ?? 3, lzma2: o.xizCodec == .lzma2, appleCodec: o.xizCodec.appleFrameCodec, password: nil,
                                extendedAttributes: o.storeExtendedAttributes, carried: carried, workload: o.workload,
                                overwrite: true, progress: progress, cancel: cancel)
    }

    /// ZIP → tar.gz/.bz2/.zst/.xz: each copied entry's data becomes one member of the stream,
    /// right after the member that ends with its tar header.
    private func writeTar(items: [ArchiveItem], raw zip: ZipArchive, to staged: URL, options o: CreateOptions,
                          progress: ProgressHandler?, cancel: CancellationToken?) throws {
        var all = items
        var carried: [Int: TarCarriedMember] = [:]
        let read: (Int64, Int) throws -> [UInt8] = { try zip.reader.read(at: $0, count: $1) }
        for e in entries {
            guard let c = zipRaw[e.path] else { continue }
            let r = c.record
            carried[all.count] = format == .tarGzip
                ? .gzip(offset: c.offset, size: c.size, crc: r.crc, length: r.uncompressedSize, read: read)
                : TarCarriedMember(offset: c.offset, size: c.size, read: read)
            all.append(ArchiveItem(name: MountedArchive.normalize(e.path) ?? e.path, sourcePath: "", kind: .file(size: r.uncompressedSize),
                                   permissions: e.permissions ?? 0o644, modified: e.modified ?? Date(), uid: getuid(), gid: getgid()))
        }
        _ = try TarWriter.write(items: all, to: staged.path, compression: format.compression, level: o.level ?? format.defaultLevel,
                                workload: o.workload, overwrite: true, extendedAttributes: o.storeExtendedAttributes, carried: carried,
                                progress: progress, cancel: cancel)
    }

    /// 7z → ZIP: copied folders become entries with the same bytes; the rest is written by
    /// ZipWriter into a side archive whose entries are then copied in.
    private func writeZip(items: [ArchiveItem], raw a: SevenZipArchive, work: URL, to staged: URL, options o: CreateOptions,
                          progress: ProgressHandler?, cancel: CancellationToken?) throws {
        var side: ZipArchive?
        if !items.isEmpty {
            let path = work.appendingPathComponent("side.zip").path
            var z = ZipOptions()
            z.method = o.zipMethod
            z.level = o.level ?? o.zipMethod.defaultLevel
            z.storeAlreadyCompressed = o.storeAlreadyCompressed
            z.workload = o.workload
            _ = try ZipWriter.write(items: items, to: path, options: z, overwrite: true, progress: progress, cancel: cancel)
            side = try ZipArchive(path: path)
        }
        let out = try OutputFile(path: staged.path)
        var central = ByteWriter(capacity: 1 << 16)
        var count = 0
        for e in entries {
            try cancel?.check()
            guard let c = sevenZipRaw[e.path], let rec = a.folderRecords[c.folder].first.map({ a.records[$0] }) else { continue }
            let packIndex = a.streams.folders[c.folder].firstPackStream
            let packSize = a.streams.packSizes[packIndex], packOffset = a.packOffsets[packIndex]
            // ZIP LZMA declares an end marker (flag bit 1); 7z does not say, so the stream is decoded once to see.
            var flags: UInt16 = 0
            if c.method == Zip.Method.lzma.rawValue,
               try Self.lzmaHasEndMarker(props: a.streams.folders[c.folder].coders[0].props, size: rec.size, packSize: packSize,
                                         read: { try a.input.read(at: packOffset + $0, count: $1) }, cancel: cancel) {
                flags = Zip.Flag.lzmaEndMarker
            }
            try ZipRawEntry(name: MountedArchive.normalize(e.path) ?? e.path, method: c.method, crc: rec.crc!,
                            compressedSize: packSize, size: rec.size, modified: e.modified ?? Date(),
                            permissions: e.permissions ?? 0o644, prefix: c.prefix, suffix: c.suffix, flags: flags)
                .write(to: out, central: &central, from: a.packOffsets[packIndex]) { try a.input.read(at: $0, count: $1) }
            count += 1
        }
        for r in side?.records ?? [] {
            try ZipEditor.copy(r, from: side!, name: String(decoding: r.rawName, as: UTF8.self), renamed: false, to: out, central: &central)
            count += 1
        }
        try ZipEditor.finish(out, central: central.bytes, count: count, forceZip64: o.forceZip64)
        try out.commit(overwrite: true)
    }

    /// The new archive tests clean and holds what the source holds: every path, kind and size,
    /// and the same CRC where both formats keep one.
    private func verify(_ staged: URL) throws {
        let test = try Xipper.test(staged, password: options.password)
        if let f = test.failures.first { throw XipperError.integrity(entry: f.path, detail: "the converted archive does not verify: \(f.reason)") }
        func key(_ p: String) -> String { (MountedArchive.normalize(p) ?? p).precomposedStringWithCanonicalMapping }
        var got: [String: ArchiveEntry] = [:]
        for e in try Xipper.list(staged, password: options.password) where !e.isAppleDoubleMetadata {
            if got[key(e.path)] != nil && e.kind != .directory {
                throw XipperError.integrity(entry: e.path, detail: "twice in the converted archive")
            }
            got[key(e.path)] = e
        }
        for e in entries {
            guard let g = got[key(e.path)] else {
                if e.kind == .directory || key(e.path).isEmpty { continue }  // some formats keep folders implicit
                throw XipperError.integrity(entry: e.path, detail: "missing from the converted archive")
            }
            if e.kind == .file && g.kind == .file {
                if g.uncompressedSize != e.uncompressedSize {
                    throw XipperError.integrity(entry: e.path, detail: "size \(g.uncompressedSize) instead of \(e.uncompressedSize)")
                }
                if let a = e.crc32, let b = g.crc32, a != b { throw XipperError.checksumMismatch(entry: e.path, expected: a, actual: b) }
            }
        }
    }
}

/// A ZIP entry written from compressed bytes taken elsewhere (a 7z folder): local header, the
/// bytes streamed, central record. ZIP64 fields where sizes or the offset overflow.
struct ZipRawEntry {
    var name: String
    var method: UInt16
    var crc: UInt32
    var compressedSize: Int64
    var size: Int64
    var modified: Date
    var permissions: UInt16
    /// Written before and after the copied bytes, counted in the entry's compressed size.
    var prefix: [UInt8] = []
    var suffix: [UInt8] = []
    /// Method-specific general purpose flags (ZIP LZMA: end marker).
    var flags: UInt16 = 0

    func write(to out: OutputFile, central: inout ByteWriter, from offset: Int64,
               read: (Int64, Int) throws -> [UInt8]) throws {
        let nameBytes = Array(name.utf8)
        let flags: UInt16 = (nameBytes.contains { $0 >= 0x80 } ? Zip.Flag.utf8 : 0) | self.flags
        let (time, date) = DOSDateTime.encode(modified)
        let copied = compressedSize
        let compressedSize = copied + Int64(prefix.count + suffix.count)
        let big = UInt64(size) >= Zip.max32 || UInt64(compressedSize) >= Zip.max32
        let needed: UInt16 = switch method {
        case Zip.Method.lzma.rawValue, Zip.Method.xz.rawValue: 63
        case Zip.Method.bzip2.rawValue: 46
        default: big ? 45 : 20
        }
        var ts = ByteWriter(capacity: 9)
        ts.u16(Zip.Extra.extendedTimestamp); ts.u16(5); ts.u8(1); ts.u32(UInt32(clamping: Int64(modified.timeIntervalSince1970)))
        let headerOffset = out.position
        var local = ByteWriter(capacity: 64 + nameBytes.count)
        var localExtra = ts.bytes
        if big {
            var e = ByteWriter(capacity: 20)
            e.u16(Zip.Extra.zip64); e.u16(16); e.u64(UInt64(size)); e.u64(UInt64(compressedSize))
            localExtra = e.bytes + localExtra
        }
        local.u32(Zip.localSignature); local.u16(needed); local.u16(flags); local.u16(method); local.u16(time); local.u16(date)
        local.u32(crc); local.u32(big ? UInt32.max : UInt32(compressedSize)); local.u32(big ? UInt32.max : UInt32(size))
        local.u16(UInt16(nameBytes.count)); local.u16(UInt16(localExtra.count)); local.append(nameBytes); local.append(localExtra)
        try out.write(local.bytes)
        if !prefix.isEmpty { try out.write(prefix) }
        var done: Int64 = 0
        while done < copied {
            let n = Int(min(Int64(4 << 20), copied - done))
            try out.write(try read(offset + done, n))
            done += Int64(n)
        }
        if !suffix.isEmpty { try out.write(suffix) }
        let bigO = UInt64(headerOffset) >= Zip.max32
        var z64 = ByteWriter(capacity: 24)
        if big { z64.u64(UInt64(size)); z64.u64(UInt64(compressedSize)) }
        if bigO { z64.u64(UInt64(headerOffset)) }
        var extra = ts.bytes
        if !z64.bytes.isEmpty {
            var e = ByteWriter(capacity: 4 + z64.bytes.count)
            e.u16(Zip.Extra.zip64); e.u16(UInt16(z64.bytes.count)); e.append(z64.bytes)
            extra = e.bytes + extra
        }
        central.u32(Zip.centralSignature); central.u16(Zip.versionMadeBy); central.u16(needed); central.u16(flags)
        central.u16(method); central.u16(time); central.u16(date); central.u32(crc)
        central.u32(big ? UInt32.max : UInt32(compressedSize)); central.u32(big ? UInt32.max : UInt32(size))
        central.u16(UInt16(nameBytes.count)); central.u16(UInt16(extra.count)); central.u16(0); central.u16(0); central.u16(0)
        central.u32(UInt32(0o100000 | UInt32(permissions & 0o7777)) << 16)
        central.u32(bigO ? UInt32.max : UInt32(headerOffset))
        central.append(nameBytes); central.append(extra)
    }
}
