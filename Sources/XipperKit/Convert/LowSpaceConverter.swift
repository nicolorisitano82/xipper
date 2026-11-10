import CryptoKit
import Foundation
import Synchronization

/// «Cambia formato» with little free space (3.0): ZIP or 7z → XIZ, a batch at a time. Each batch
/// is unpacked in a work folder, appended to the new archive as a XIZ segment (§11) and made
/// durable; only then are the batch's bytes in the original released with `F_PUNCHHOLE`. The disk
/// never holds both archives whole: at most the new archive, what is left of the original and one
/// batch unpacked.
///
/// A journal next to the original (`<original>.xipper-resume`) records the plan. The new archive
/// itself says which batches are done (their files are in its catalog: a segment is all or
/// nothing), so a conversion interrupted at any point, a power cut included, resumes from there.
/// Until the first bytes are released the original is intact and an error simply drops the new
/// archive; afterwards the original can only be completed by resuming.
public struct LowSpaceConversionStatus: Sendable {
    public var journal: URL
    public var source: URL
    public var target: URL
    public var batches: Int
    public var batchesDone: Int
    /// Bytes of the original already released: the original no longer opens on its own.
    public var released: Bool
    /// The new archive is encrypted: resuming needs its password.
    public var targetEncrypted: Bool
    public var sourceEncrypted: Bool
}

extension Xipper {
    /// Why `source` cannot be converted to `format` with little free space, or nil if it can.
    public static func lowSpaceConversionProblem(_ source: URL, to format: ArchiveFormat, password: String? = nil) -> String? {
        do {
            _ = try LowSpaceConverter.Layout(source: source.standardizedFileURL, format: format, password: password)
            return LowSpaceConverter.spaceProblem(source.standardizedFileURL.path)
        } catch {
            return error.localizedDescription
        }
    }

    /// Converts `source` into `target` (XIZ) a batch at a time, releasing the original's bytes as
    /// they are carried over; the original is removed at the end. If a journal of an interrupted
    /// conversion of `source` exists, it is resumed instead (`options` must match).
    @discardableResult
    public static func convertWithLittleSpace(_ source: URL, to target: URL, password: String? = nil, options: CreateOptions,
                                              progress: ProgressHandler? = nil, cancel: CancellationToken? = nil) throws -> FormatChangeReport {
        let journal = LowSpaceConverter.journalURL(source.standardizedFileURL)
        if FileManager.default.fileExists(atPath: journal.path) {
            return try resumeConversion(journal, password: password, newPassword: options.password, progress: progress, cancel: cancel)
        }
        return try LowSpaceConverter.start(source: source.standardizedFileURL, target: target.standardizedFileURL, password: password,
                                           options: options, progress: progress, cancel: cancel)
    }

    /// The interrupted conversion of `source`, if there is one.
    public static func interruptedConversion(of source: URL) -> LowSpaceConversionStatus? {
        let journal = LowSpaceConverter.journalURL(source.standardizedFileURL)
        return try? LowSpaceConverter.status(journal)
    }

    /// The state of the interrupted conversion recorded in `journal`.
    public static func conversionStatus(_ journal: URL) throws -> LowSpaceConversionStatus {
        try LowSpaceConverter.status(journal)
    }

    /// Resumes the conversion recorded in `journal`. `password`: the original's; `newPassword`:
    /// the new archive's, if it is encrypted.
    @discardableResult
    public static func resumeConversion(_ journal: URL, password: String? = nil, newPassword: String? = nil,
                                        progress: ProgressHandler? = nil, cancel: CancellationToken? = nil) throws -> FormatChangeReport {
        try LowSpaceConverter.resume(journal, password: password, newPassword: newPassword, progress: progress, cancel: cancel)
    }

    /// Gives up an interrupted conversion whose original is still whole (nothing released yet):
    /// the new archive and the journal are removed, the original stays as it was.
    public static func abandonConversion(_ journal: URL) throws {
        try LowSpaceConverter.abandon(journal)
    }
}

enum LowSpaceConverter {
    static let journalSuffix = ".xipper-resume"
    /// Unpacked bytes per batch: at most this, and at most a third of the free space.
    static let maxBatch: Int64 = 4 << 30
    static let minBatch: Int64 = 64 << 20
    static let margin: Int64 = 64 << 20

    static func journalURL(_ source: URL) -> URL { URL(fileURLWithPath: source.path + journalSuffix) }
    static func stagedURL(_ target: URL) -> URL {
        target.deletingLastPathComponent().appendingPathComponent("." + target.lastPathComponent + ".xipper-partial")
    }

    /// Test hook: `XIPPER_LOWSPACE_CRASH=<step>` kills the process right after that step
    /// ("batch2-written", "batch2-released", "verified", "renamed"), to test resuming.
    static func checkpoint(_ step: String) throws {
        if let s = ProcessInfo.processInfo.environment["XIPPER_LOWSPACE_CRASH"], s == step { kill(getpid(), SIGKILL) }
        if testStop.withLock({ $0 }) == step { throw XipperError.cancelled }
    }

    /// Tests: stop with `cancelled` right after this step; batch size in unpacked bytes.
    static let testStop = Mutex<String?>(nil)
    static let testBatchLimit = Mutex<Int64?>(nil)

    // MARK: journal

    struct Journal: Codable {
        var version = 1
        var source: String
        var target: String
        var format: String
        var device: Int64
        var inode: UInt64
        var size: Int64
        /// SHA-256 of the original from `tailStart` to its end (ZIP central directory, 7z header),
        /// never released: the same original when resuming.
        var tailStart: Int64
        var tail: String
        /// Byte ranges per batch, and the paths each batch adds (files and links, normalized).
        var batches: [[Range]]
        var paths: [[String]]
        var phase: String = "converting"
        // What the new archive is made with.
        var level: Int?
        var codec: String
        var jpeg: Bool
        var documents: Bool
        var recovery: Double
        var dictionary: Bool
        var extendedAttributes: Bool
        var encrypted: Bool
        var sourceEncrypted: Bool
    }

    struct Range: Codable, Hashable {
        var start: Int64
        var end: Int64
    }

    static func write(_ j: Journal, to url: URL) throws {
        let data = try JSONEncoder().encode(j)
        let tmp = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw XipperError.posix("create", tmp.path) }
        let ok = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) == $0.count } && OutputFile.fullSync(fd)
        close(fd)
        guard ok else { unlink(tmp.path); throw XipperError.posix("write", tmp.path) }
        guard rename(tmp.path, url.path) == 0 else { unlink(tmp.path); throw XipperError.posix("rename", url.path) }
        syncDirectory(url.deletingLastPathComponent())
    }

    static func read(_ url: URL) throws -> Journal {
        guard let data = FileManager.default.contents(atPath: url.path) else { throw XipperError.posix("open", url.path) }
        guard let j = try? JSONDecoder().decode(Journal.self, from: data), j.version == 1 else {
            throw XipperError.corrupt("not a Xipper conversion journal: \(url.lastPathComponent)")
        }
        return j
    }

    static func syncDirectory(_ dir: URL) {
        let fd = open(dir.path, O_RDONLY)
        if fd >= 0 { _ = OutputFile.fullSync(fd); close(fd) }
    }

    // MARK: layout of the original

    /// The original's entries grouped into units that are released together (a ZIP entry, a 7z
    /// folder, with their macOS metadata companions), in file order.
    struct Layout {
        struct Unit {
            var ranges: [Range]
            var paths: [String]  // archive paths to unpack (companions included)
            var bytes: Int64     // unpacked
        }
        var units: [Unit]
        /// Entries without data (folders, empty files): unpacked or created in the first batch.
        var bare: [ArchiveEntry]
        var entries: [ArchiveEntry]
        var tailStart: Int64
        var size: Int64

        init(source: URL, format: ArchiveFormat, password: String?) throws {
            guard format == .xiz else { throw XipperError.unsupported("with little free space Xipper converts only into XIZ") }
            guard let sf = try ArchiveFormat.detect(source), sf == .zip || sf == .sevenZip else {
                throw XipperError.unsupported("with little free space Xipper converts only ZIP and 7z archives")
            }
            let path = source.path
            let all = try Xipper.list(source, password: password)
            entries = all.filter { !$0.isAppleDoubleMetadata }
            if entries.contains(where: { $0.kind == .hardlink }) { throw XipperError.unsupported("archives with hard links need the usual conversion") }
            size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            // Companion `._name` → the path it describes.
            func owner(_ companion: String) -> String? {
                var p = companion
                if p.hasPrefix("__MACOSX/") { p.removeFirst(9) }
                let dir = (p as NSString).deletingLastPathComponent, name = (p as NSString).lastPathComponent
                guard name.hasPrefix("._") else { return nil }
                return dir.isEmpty ? String(name.dropFirst(2)) : dir + "/" + name.dropFirst(2)
            }
            var units: [Unit] = []
            var unitOf: [String: Int] = [:]
            var companions: [(path: String, range: Range?, owner: String?)] = []
            var bare: [ArchiveEntry] = []
            var tail = size
            if sf == .zip {
                guard ZipArchive.volumes(for: path).count == 1 else { throw XipperError.unsupported("ZIP volumes need the usual conversion") }
                let z = try ZipArchive(path: path)
                for r in z.records {
                    let end = r.localHeaderOffset + 30 + Int64(r.rawName.count) + r.compressedSize
                    let range = r.compressedSize > 0 ? Range(start: r.localHeaderOffset, end: end) : nil
                    if r.entry.isAppleDoubleMetadata { companions.append((r.entry.path, range, owner(r.entry.path))); continue }
                    if let range {
                        unitOf[r.entry.path] = units.count
                        units.append(Unit(ranges: [range], paths: [r.entry.path], bytes: r.uncompressedSize))
                    } else {
                        bare.append(r.entry)
                    }
                }
                tail = z.records.map { $0.localHeaderOffset + 30 + Int64($0.rawName.count) + $0.compressedSize }.max() ?? 0
            } else {
                let a = try SevenZipArchive(path: path, password: password)
                guard a.input.volumes.count == 1 else { throw XipperError.unsupported("7z volumes need the usual conversion") }
                for (fi, members) in a.folderRecords.enumerated() {
                    let f = a.streams.folders[fi]
                    let ranges = (0..<f.packedStreams.count).map { k -> Range in
                        let p = f.firstPackStream + k
                        return Range(start: a.packOffsets[p], end: a.packOffsets[p] + a.streams.packSizes[p])
                    }
                    var u = Unit(ranges: ranges, paths: [], bytes: 0)
                    for m in members {
                        let r = a.records[m]
                        if r.entry.isAppleDoubleMetadata { companions.append((r.entry.path, nil, owner(r.entry.path))) }
                        u.paths.append(r.entry.path)
                        u.bytes += r.size
                        unitOf[r.entry.path] = units.count
                    }
                    units.append(u)
                }
                for r in a.records where !r.hasStream {
                    if r.entry.isAppleDoubleMetadata { companions.append((r.entry.path, nil, owner(r.entry.path))) } else { bare.append(r.entry) }
                }
                tail = zip(a.packOffsets, a.streams.packSizes).map { $0 + $1 }.max() ?? 32
            }
            // Companions travel with what they describe (merged into it when unpacked).
            for c in companions {
                if let o = c.owner, let u = unitOf[o] {
                    if let r = c.range { units[u].ranges.append(r) }
                    if !units[u].paths.contains(c.path) { units[u].paths.append(c.path) }
                } else if let r = c.range {
                    // Describes a folder or an empty file: unpacked in the first batch.
                    units.append(Unit(ranges: [r], paths: [c.path], bytes: 0))
                }
            }
            self.units = units.sorted { ($0.ranges.map(\.start).min() ?? 0) < ($1.ranges.map(\.start).min() ?? 0) }
            self.bare = bare
            tailStart = max(tail, 0)
        }

        /// Units in order, cut into batches of about `limit` unpacked bytes.
        func batches(limit: Int64) -> [[Unit]] {
            var out: [[Unit]] = [[]]
            var bytes: Int64 = 0
            for u in units {
                if !out[out.count - 1].isEmpty && bytes + u.bytes > limit { out.append([]); bytes = 0 }
                out[out.count - 1].append(u)
                bytes += u.bytes
            }
            return out
        }
    }

    /// Why releasing the original's bytes would not free space: APFS clones sharing its blocks,
    /// or snapshots holding them. nil if it would.
    static func spaceProblem(_ path: String) -> String? {
        if let shared = sharedBytes(path), shared > 1 << 20 {
            return "the original shares \(ByteCountFormatter.string(fromByteCount: shared, countStyle: .file)) with a copy (APFS clone): releasing them would free nothing"
        }
        if let snap = snapshotHolding(path) {
            return "an APFS snapshot (\(snap)) holds the original: releasing its bytes would free nothing until the snapshot is deleted"
        }
        return nil
    }

    /// Bytes of the file shared with clones (size minus private size), if APFS tells.
    static func sharedBytes(_ path: String) -> Int64? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        var buf = [UInt8](repeating: 0, count: 32)
        guard getattrlist(path, &list, &buf, buf.count, UInt32(FSOPT_ATTR_CMN_EXTENDED)) == 0 else { return nil }
        let privateSize = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return max(0, Int64(st.st_blocks) * 512 - privateSize)
    }

    /// The name or date of a snapshot of the original's volume taken after the file was created.
    static func snapshotHolding(_ path: String) -> String? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let mount = withUnsafeBytes(of: fs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        let born = Date(timeIntervalSince1970: TimeInterval(st.st_birthtimespec.tv_sec))
        // `diskutil apfs listSnapshots` names every snapshot; Time Machine ones carry their date.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["apfs", "listSnapshots", "-plist", mount]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(from: out, format: nil) as? [String: Any],
              let snaps = plist["Snapshots"] as? [[String: Any]] else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        for s in snaps {
            let name = s["SnapshotName"] as? String ?? s["Name"] as? String ?? "\(s)"
            // com.apple.TimeMachine.2026-11-10-101010.local
            if let r = name.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression), let d = f.date(from: String(name[r])) {
                if d > born { return name }
            } else {
                return name  // no date: assume it holds the file
            }
        }
        return nil
    }

    // MARK: running

    static func start(source: URL, target: URL, password: String?, options: CreateOptions,
                      progress: ProgressHandler?, cancel: CancellationToken?) throws -> FormatChangeReport {
        guard options.format == .xiz else { throw XipperError.unsupported("with little free space Xipper converts only into XIZ") }
        guard options.xizAccess == nil, options.xizSigner == nil else {
            throw XipperError.unsupported("access groups and signatures need the usual conversion")
        }
        if target.path == source.path { throw XipperError.invalidArgument("the new archive needs another name than the original") }
        if FileManager.default.fileExists(atPath: target.path) { throw XipperError.alreadyExists(path: target.path) }
        if let p = spaceProblem(source.path) { throw XipperError.unsupported(p) }
        let layout = try Layout(source: source, format: options.format, password: password)
        let free = freeSpace(target.deletingLastPathComponent().path)
        let limit = testBatchLimit.withLock { $0 } ?? ProcessInfo.processInfo.environment["XIPPER_LOWSPACE_BATCH"].flatMap { Int64($0) }
            ?? max(minBatch, min(maxBatch, (free - margin) / 3))
        let biggest = layout.units.map(\.bytes).max() ?? 0
        if biggest + margin > free {
            throw XipperError.insufficientSpace(needed: biggest + margin, available: free)
        }
        var st = stat()
        guard stat(source.path, &st) == 0 else { throw XipperError.posix("stat", source.path) }
        let batches = layout.batches(limit: limit)
        let journal = Journal(source: source.path, target: target.path, format: options.format.rawValue, device: Int64(st.st_dev),
                              inode: UInt64(st.st_ino), size: layout.size, tailStart: layout.tailStart,
                              tail: try tailDigest(source.path, from: layout.tailStart, size: layout.size),
                              batches: batches.map { $0.flatMap(\.ranges) },
                              paths: batches.map { $0.flatMap(\.paths).filter { !isAppleDouble($0) }.map(key) },
                              level: options.level, codec: options.xizCodec.rawValue, jpeg: options.xizJPEG, documents: options.xizDocuments,
                              recovery: options.xizRecovery, dictionary: options.xizDictionary,
                              extendedAttributes: options.storeExtendedAttributes, encrypted: options.password != nil,
                              sourceEncrypted: password != nil)
        let url = journalURL(source)
        try write(journal, to: url)
        return try run(journal, url: url, layout: layout, batches: batches, password: password, newPassword: options.password,
                       workload: options.workload, kdf: options.xizKDF, progress: progress, cancel: cancel)
    }

    static func status(_ url: URL) throws -> LowSpaceConversionStatus {
        let j = try read(url)
        let staged = stagedURL(URL(fileURLWithPath: j.target))
        var done = 0
        if FileManager.default.fileExists(atPath: staged.path), let a = try? XizArchive(path: staged.path, password: nil) {
            done = doneBatches(j, catalog: Set(a.catalog.entries.map { key($0.path) }))
        } else if FileManager.default.fileExists(atPath: staged.path) {
            done = -1  // encrypted: unknown until the password is given
        }
        let released = done != 0 || j.phase != "converting"
        return LowSpaceConversionStatus(journal: url, source: URL(fileURLWithPath: j.source), target: URL(fileURLWithPath: j.target),
                                        batches: j.batches.count, batchesDone: max(done, 0), released: released,
                                        targetEncrypted: j.encrypted, sourceEncrypted: j.sourceEncrypted)
    }

    static func abandon(_ url: URL) throws {
        let j = try read(url)
        let staged = stagedURL(URL(fileURLWithPath: j.target))
        if j.phase == "converting", FileManager.default.fileExists(atPath: staged.path) {
            throw XipperError.invalidArgument("part of the original was already released into the new archive: the conversion can only be resumed")
        }
        if j.phase != "converting" { throw XipperError.invalidArgument("the new archive is complete: resume to finish") }
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.removeItem(at: url)
    }

    static func resume(_ url: URL, password: String?, newPassword: String?, progress: ProgressHandler?,
                       cancel: CancellationToken?) throws -> FormatChangeReport {
        let j = try read(url)
        let source = URL(fileURLWithPath: j.source)
        if j.encrypted && newPassword == nil { throw XipperError.passwordRequired(entry: URL(fileURLWithPath: j.target).lastPathComponent) }
        if j.phase != "converting" {
            return try finish(j, url: url, entries: nil, newPassword: newPassword, start: Date())
        }
        var st = stat()
        guard stat(source.path, &st) == 0 else { throw XipperError.posix("stat", source.path) }
        let size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard Int64(st.st_dev) == j.device, UInt64(st.st_ino) == j.inode, size == j.size,
              try tailDigest(source.path, from: j.tailStart, size: j.size) == j.tail else {
            throw XipperError.integrity(entry: source.lastPathComponent, detail: "not the original this conversion started from")
        }
        let layout = try Layout(source: source, format: .xiz, password: password)
        // The same batches as planned: units are matched by their ranges.
        var byRange: [Range: Layout.Unit] = [:]
        for u in layout.units { byRange[u.ranges[0]] = u }
        var batches: [[Layout.Unit]] = []
        var seen = Set<Range>()
        for ranges in j.batches {
            var b: [Layout.Unit] = []
            for r in ranges where !seen.contains(r) {
                guard let u = byRange[r] else { continue }
                u.ranges.forEach { seen.insert($0) }
                b.append(u)
            }
            batches.append(b)
        }
        guard seen.count == layout.units.reduce(0, { $0 + $1.ranges.count }) else {
            throw XipperError.integrity(entry: source.lastPathComponent, detail: "the original no longer matches the conversion plan")
        }
        return try run(j, url: url, layout: layout, batches: batches, password: password, newPassword: newPassword,
                       workload: .interactive, progress: progress, cancel: cancel)
    }

    static func freeSpace(_ path: String) -> Int64 { ExtractionContext.volumeSpace(path, fd: -1)?.free ?? 0 }

    static func isAppleDouble(_ p: String) -> Bool {
        p == "__MACOSX" || p.hasPrefix("__MACOSX/") || (p as NSString).lastPathComponent.hasPrefix("._")
    }

    /// Normalized archive path, as compared between the original and the new archive.
    static func key(_ p: String) -> String { (MountedArchive.normalize(p) ?? p).precomposedStringWithCanonicalMapping }

    /// Batches whose files are all in the new archive's catalog (a prefix: they are appended in order).
    static func doneBatches(_ j: Journal, catalog: Set<String>) -> Int {
        var done = 0
        for (i, paths) in j.paths.enumerated() {
            if i == 0 || paths.allSatisfy(catalog.contains) { done = i + 1 } else { break }
        }
        return done
    }

    static func tailDigest(_ path: String, from: Int64, size: Int64) throws -> String {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw XipperError.posix("open", path) }
        defer { close(fd) }
        var h = SHA256()
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        var off = from
        while off < size {
            let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, Int(min(Int64($0.count), size - off)), off) }
            guard n > 0 else { throw XipperError.posix("read", path) }
            h.update(data: buf[0..<n])
            off += Int64(n)
        }
        // The first block too (7z start header, the first ZIP local header's block).
        let head = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, 32, 0) }
        if head > 0 { h.update(data: buf[0..<head]) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Releases the blocks lying wholly inside `ranges` (merged first, so blocks spanning two
    /// released ranges go too), then makes it durable.
    static func release(_ path: String, ranges: [Range], tailStart: Int64) throws {
        let fd = open(path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { throw XipperError.posix("open", path) }
        defer { close(fd) }
        var fs = statfs()
        let block = fstatfs(fd, &fs) == 0 ? Int64(fs.f_bsize) : 4096
        var merged: [Range] = []
        for r in ranges.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, r.start <= last.end { merged[merged.count - 1].end = max(last.end, r.end) } else { merged.append(r) }
        }
        for r in merged {
            // Never block 0 (format header) nor the tail kept for resuming.
            let start = max(block, (r.start + block - 1) / block * block)
            let end = min(r.end, tailStart) / block * block
            guard end > start else { continue }
            var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(start), fp_length: off_t(end - start))
            if fcntl(fd, F_PUNCHHOLE, &hole) != 0 { throw XipperError.posix("release space in", path) }
        }
        guard OutputFile.fullSync(fd) else { throw XipperError.posix("fsync", path) }
    }

    static func options(_ j: Journal, password: String?, workload: Workload) -> CreateOptions {
        var o = CreateOptions()
        o.format = .xiz
        o.level = j.level
        o.xizCodec = XizCodec(rawValue: j.codec) ?? .zstd
        o.xizJPEG = j.jpeg
        o.xizDocuments = j.documents
        o.xizRecovery = j.recovery
        o.xizDictionary = j.dictionary
        o.storeExtendedAttributes = j.extendedAttributes
        o.password = password
        o.workload = workload
        return o
    }

    private static func run(_ journal: Journal, url: URL, layout: Layout, batches: [[Layout.Unit]], password: String?, newPassword: String?,
                            workload: Workload, kdf: XizKeys.KDF = .standard, progress: ProgressHandler?,
                            cancel: CancellationToken?) throws -> FormatChangeReport {
        let begin = Date()
        let source = URL(fileURLWithPath: journal.source), target = URL(fileURLWithPath: journal.target)
        let staged = stagedURL(target)
        var o = options(journal, password: newPassword, workload: workload)
        o.xizKDF = kdf
        var done = 0
        if FileManager.default.fileExists(atPath: staged.path) {
            let a = try XizArchive(path: staged.path, password: newPassword)
            done = doneBatches(journal, catalog: Set(a.catalog.entries.map { key($0.path) }))
        }
        // Batches already in the new archive: their bytes go (again: releasing twice is harmless).
        if done > 0 { try release(source.path, ranges: journal.batches[0..<done].flatMap { $0 }, tailStart: journal.tailStart) }

        let parent = target.deletingLastPathComponent()
        ArchiveConverter.removeAbandonedWork(in: parent)
        removeLeftovers(staged)
        let total = batches.reduce(Int64(0)) { $0 + $1.reduce(0) { $0 + $1.bytes } }
        var completed = batches[0..<done].reduce(Int64(0)) { $0 + $1.reduce(0) { $0 + $1.bytes } }
        // Declared up front: later batches append into the superblock written with the first.
        let jpegNames = o.xizJPEG && layout.entries.contains { ["jpg", "jpeg", "jpe", "jfif"].contains(($0.path as NSString).pathExtension.lowercased()) }
        let documentNames = o.xizDocuments && layout.entries.contains { DeflateRecompression.kind(name: $0.path) != nil }
        do {
            for b in done..<batches.count {
                try cancel?.check()
                let units = batches[b]
                let bytes = units.reduce(Int64(0)) { $0 + $1.bytes }
                let work = parent.appendingPathComponent(".xipper-convert-\(getpid())-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: work) }
                if case let free = freeSpace(work.path), free < bytes * 2 + margin {
                    throw XipperError.insufficientSpace(needed: bytes * 2 + margin, available: free)
                }
                let tree = work.appendingPathComponent("tree", isDirectory: true)
                try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
                var selection = units.flatMap(\.paths)
                if b == 0 { selection += layout.bare.filter { $0.kind != .directory }.map(\.path) }
                if !selection.isEmpty {
                    var x = ExtractOptions()
                    x.password = password
                    x.selection = Set(selection)
                    x.overwrite = .replace
                    x.propagateQuarantine = false
                    x.symlinks = .allowAll  // re-archived, never followed
                    x.workload = workload
                    // The space was checked above; extraction's own 1 GiB reserve would refuse every
                    // batch on a nearly full disk, which is the point of this mode.
                    x.limits.maxTotalBytes = max(bytes, 1) + (1 << 20)
                    x.limits.minFreeFraction = 0
                    let base = completed
                    let unpacking: ProgressHandler? = progress.map { p in
                        { @Sendable (s: ProgressSnapshot) in
                            var s = s
                            s.totalBytes = total
                            s.completedBytes = base + s.completedBytes / 2
                            p(s)
                        }
                    }
                    _ = try Xipper.extract(source, to: tree, mode: .into, options: x, progress: unpacking, cancel: cancel)
                }
                if b == 0 {
                    for e in layout.entries where e.kind == .directory {
                        guard let rel = MountedArchive.normalize(e.path), !rel.isEmpty else { continue }
                        let d = tree.appendingPathComponent(rel)
                        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                        var attrs: [FileAttributeKey: Any] = [:]
                        if let p = e.permissions { attrs[.posixPermissions] = Int(p | 0o700) }
                        if let m = e.modified { attrs[.modificationDate] = m }
                        try? FileManager.default.setAttributes(attrs, ofItemAtPath: d.path)
                    }
                }
                var scan = o.scan
                scan.excludeMacMetadata = false
                let top = try FileManager.default.contentsOfDirectory(at: tree, includingPropertiesForKeys: nil)
                let items = top.isEmpty ? [] : try SourceScanner.scan(top, options: scan)
                let base = completed
                let batchProgress: ProgressHandler? = progress.map { p in
                    { @Sendable (s: ProgressSnapshot) in
                        var s = s
                        s.totalBytes = total
                        s.completedBytes = base + bytes / 2 + s.completedBytes / 2
                        p(s)
                    }
                }
                if b == 0 {
                    var oo = o
                    oo.overwrite = true
                    _ = try XizWriter.write(items: items, to: staged.path, level: oo.level ?? 3, lzma2: oo.xizCodec == .lzma2,
                                            appleCodec: oo.xizCodec.appleFrameCodec, jpeg: jpegNames, deflate: documentNames,
                                            password: oo.password, kdf: oo.xizKDF, extendedAttributes: oo.storeExtendedAttributes,
                                            dictionaryThreshold: oo.xizDictionary ? XizDictionary.minimumSmallBytes : .max,
                                            declareRecompression: true, workload: workload, overwrite: true,
                                            progress: batchProgress, cancel: cancel)
                    syncDirectory(parent)
                } else {
                    try append(items, to: staged.path, options: o, progress: batchProgress, cancel: cancel)
                }
                try checkpoint("batch\(b)-written")
                // Durable in the new archive: the original's bytes can go.
                try release(source.path, ranges: journal.batches[0...b].flatMap { $0 }, tailStart: journal.tailStart)
                try checkpoint("batch\(b)-released")
                completed += bytes
            }
        } catch {
            // Nothing released yet: the original is whole, the half-made archive goes.
            if done == 0, !journalReleasedAnything(journal, staged: staged, password: newPassword) {
                try? FileManager.default.removeItem(at: staged)
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
        return try finish(journal, url: url, entries: layout.entries, newPassword: newPassword, start: begin)
    }

    /// The first segment of a run killed while writing it: its temporary file (OutputFile).
    static func removeLeftovers(_ staged: URL) {
        let parent = staged.deletingLastPathComponent(), prefix = "." + staged.lastPathComponent + ".xiptmp-"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [] where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
        }
    }

    /// Whether any batch made it into the new archive (and so may have been released).
    static func journalReleasedAnything(_ j: Journal, staged: URL, password: String?) -> Bool {
        guard FileManager.default.fileExists(atPath: staged.path) else { return false }
        guard let a = try? XizArchive(path: staged.path, password: password) else { return true }
        return doneBatches(j, catalog: Set(a.catalog.entries.map { key($0.path) })) > 0
    }

    /// Recovery data, verification, the new archive's name, the original removed, the journal removed.
    static func finish(_ journal: Journal, url: URL, entries: [ArchiveEntry]?, newPassword: String?, start: Date) throws -> FormatChangeReport {
        var j = journal
        let source = URL(fileURLWithPath: j.source), target = URL(fileURLWithPath: j.target)
        let staged = stagedURL(target)
        removeLeftovers(staged)
        if j.phase == "converting" {
            if j.recovery > 0 { _ = try XizRecovery.add(staged.path, redundancy: j.recovery, progress: nil, cancel: nil) }
            try verify(staged, entries: entries ?? [], paths: Set(j.paths.flatMap { $0 }), password: newPassword)
            j.phase = "verified"
            try write(j, to: url)
            try checkpoint("verified")
        }
        if FileManager.default.fileExists(atPath: staged.path) {
            if renamex_np(staged.path, target.path, UInt32(RENAME_EXCL)) != 0 {
                throw errno == EEXIST ? XipperError.alreadyExists(path: target.path) : XipperError.posix("rename", target.path)
            }
            syncDirectory(target.deletingLastPathComponent())
        }
        try checkpoint("renamed")
        // What is left of the original holds nothing the new archive does not.
        if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.removeItem(at: source) }
        try? FileManager.default.removeItem(at: url)
        syncDirectory(source.deletingLastPathComponent())
        let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
        let plan = ConversionPlan(source: source, sourceFormat: .zip, format: .xiz, items: [], losses: [])
        var r = FormatChangeReport(plan: plan, output: target, outputBytes: size, elapsed: Date().timeIntervalSince(start), originalTrashed: false)
        r.originalReleased = true
        return r
    }

    /// The new archive tests clean and holds every file of the original with its size and CRC.
    static func verify(_ staged: URL, entries: [ArchiveEntry], paths: Set<String>, password: String?) throws {
        let test = try Xipper.test(staged, password: password)
        if let f = test.failures.first { throw XipperError.integrity(entry: f.path, detail: "the converted archive does not verify: \(f.reason)") }
        var got: [String: ArchiveEntry] = [:]
        for e in try Xipper.list(staged, password: password) where !e.isAppleDoubleMetadata { got[key(e.path)] = e }
        for p in paths where got[p] == nil { throw XipperError.integrity(entry: p, detail: "missing from the converted archive") }
        for e in entries {
            guard let g = got[key(e.path)] else {
                if e.kind == .directory || key(e.path).isEmpty { continue }
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

    /// One more segment (§11): the batch's files, deduplicated against the archive; folders
    /// already in it keep their entry.
    static func append(_ items: [ArchiveItem], to path: String, options o: CreateOptions, progress: ProgressHandler?,
                       cancel: CancellationToken?) throws {
        let a = try XizArchive(path: path, password: o.password)
        var have = Set<String>()
        var known: [[UInt8]: [Xiz.Extent]] = [:]
        for e in a.catalog.entries {
            have.insert(key(e.path))
            if let d = e.sha256, e.type == .file, known[d] == nil { known[d] = e.extents }
        }
        let fresh = items.filter { item in
            if case .directory = item.kind { return !have.contains(key(item.name)) }
            return true
        }
        let out = try AppendFile(path: path, at: a.footerOffset + Int64(Xiz.footerSize))
        defer { out.close() }
        let tracker = ProgressTracker(totalBytes: fresh.reduce(0) { $0 + $1.size }, totalEntries: fresh.count, handler: progress)
        let dictionary = try a.dictionary().map { (id: $0.0, bytes: $0.1, isNew: false) }
        let sb = a.superblock.required
        let (frames, written) = try XizWriter.writeData(fresh, to: out, startFrame: a.catalog.frames.count, known: known, keys: a.keys,
                                                        level: o.level ?? 3, lzma2: sb.contains(.lzma2),
                                                        appleCodec: sb.contains(.apple) ? o.xizCodec.appleFrameCodec : nil,
                                                        jpeg: sb.contains(.jpeg), deflate: sb.contains(.deflate), dictionary: dictionary,
                                                        extendedAttributes: o.storeExtendedAttributes, workload: o.workload,
                                                        tracker: tracker, cancel: cancel)
        // A file of this batch replaces nothing: paths are unique in the original.
        let newPaths = Set(written.map { key($0.path) })
        let entries = a.catalog.entries.filter { !newPaths.contains(key($0.path)) } + written
        try XizWriter.writeCatalog(Xiz.Catalog(frames: a.catalog.frames + frames, entries: entries), to: out, keys: a.keys,
                                   segment: UInt32(a.segments), previousFooter: UInt64(a.footerOffset))
        try out.sync()
        tracker.finish()
    }
}
