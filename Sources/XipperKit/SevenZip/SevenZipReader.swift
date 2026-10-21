import Foundation
import Synchronization

/// One file of a 7z archive, with where its data lives.
struct SevenZipRecord: Sendable {
    var entry: ArchiveEntry
    var hasStream: Bool
    var isAnti: Bool
    /// Folder holding the data (-1 without a stream), offset and size inside its content.
    var folder: Int
    var offset: Int64
    var size: Int64
    var crc: UInt32?
}

/// Parsed 7z archive (headers in memory, data read on demand).
final class SevenZipArchive: @unchecked Sendable {
    let input: SevenZipInput
    let streams: SZStreamsInfo
    let records: [SevenZipRecord]
    let keys: SevenZipKeyCache?
    /// File names were encrypted (`7z -mhe`).
    let headerEncrypted: Bool
    /// Records with data, grouped by folder, in stream order.
    let folderRecords: [[Int]]
    private let packOffsets: [Int64]

    static let maxHeaderSize: Int64 = 1 << 30

    init(path: String, password: String?) throws {
        input = try SevenZipInput(path: path)
        keys = password.map { SevenZipKeyCache(password: SevenZipAES.passwordBytes($0)) }
        let name = (path as NSString).lastPathComponent
        if input.size < Int64(SevenZip.signatureHeaderSize) { throw XipperError.corrupt("not a 7z archive (too small)") }
        let sig = try input.read(at: 0, count: SevenZip.signatureHeaderSize)
        guard sig.starts(with: SevenZip.signature) else { throw XipperError.corrupt("not a 7z archive") }
        if sig[6] != SevenZip.versionMajor { throw XipperError.unsupported("7z format version \(sig[6]).\(sig[7])") }
        var nextOffset: Int64 = 0, nextSize: Int64 = 0
        var nextCRC: UInt32 = 0
        try sig.withUnsafeBytes { b in
            var r = ByteReader(b, at: 8)
            let startCRC = try r.u32()
            let start = UnsafeRawBufferPointer(rebasing: b[12..<32])
            if start.allSatisfy({ $0 == 0 }) { throw XipperError.corrupt("incomplete 7z archive (the writer was interrupted)") }
            if CRC32.checksum(start) != startCRC { throw XipperError.corrupt("7z start header CRC mismatch") }
            nextOffset = Int64(bitPattern: try r.u64())
            nextSize = Int64(bitPattern: try r.u64())
            nextCRC = try r.u32()
        }
        let headerStart = Int64(SevenZip.signatureHeaderSize) + nextOffset
        if nextOffset < 0 || nextSize < 0 || nextSize > Self.maxHeaderSize || headerStart > input.size - nextSize {
            throw XipperError.corrupt("7z header beyond the end of the archive (truncated, or a volume is missing)")
        }
        if nextSize == 0 {
            // Empty archive.
            streams = SZStreamsInfo()
            records = []
            folderRecords = []
            packOffsets = []
            headerEncrypted = false
            return
        }
        var raw = try input.read(at: headerStart, count: Int(nextSize))
        if CRC32.checksum(raw) != nextCRC { throw XipperError.corrupt("7z header CRC mismatch") }

        var encrypted = false
        var header: SZHeader?
        for _ in 0..<4 {  // an encoded header may itself be encoded; 7-Zip never nests more
            let id = raw.first ?? 0
            if id == SevenZip.ID.header {
                header = try raw.withUnsafeBytes { b in
                    var r = ByteReader(b, at: 1)
                    return try SZHeaderParser.parseHeader(&r)
                }
                break
            }
            guard id == SevenZip.ID.encodedHeader else { throw XipperError.corrupt("unknown 7z header type \(id)") }
            let info = try raw.withUnsafeBytes { b in
                var r = ByteReader(b, at: 1)
                return try SZHeaderParser.parseStreamsInfo(&r)
            }
            guard info.folders.count == 1 else { throw XipperError.corrupt("7z encoded header with \(info.folders.count) folders") }
            let f = info.folders[0]
            encrypted = encrypted || f.isEncrypted
            if f.isEncrypted && keys == nil { throw XipperError.passwordRequired(entry: name) }
            if f.unpackSize > Self.maxHeaderSize { throw XipperError.limitExceeded("7z header of \(f.unpackSize) bytes") }
            var offsets: [Int64] = []
            var off = Int64(SevenZip.signatureHeaderSize) + info.packPos
            for s in info.packSizes { offsets.append(off); off += s }
            let packs = (0..<f.packedStreams.count).map { (offsets[f.firstPackStream + $0], info.packSizes[f.firstPackStream + $0]) }
            do {
                let src = try SZFolderDecoder(folder: f, input: input, packs: packs, keys: keys).open()
                var out = [UInt8](repeating: 0, count: Int(f.unpackSize))
                if !out.isEmpty { _ = try out.withUnsafeMutableBytes { try src.readExactly(into: $0.baseAddress!, count: $0.count) } }
                if let c = f.crc, CRC32.checksum(out) != c { throw XipperError.corrupt("7z header CRC mismatch") }
                raw = out
            } catch let e as XipperError where f.isEncrypted {
                if case .corrupt = e { throw XipperError.wrongPassword(entry: name) }
                throw e
            }
        }
        guard let header else { throw XipperError.corrupt("7z header nested too deeply") }
        headerEncrypted = encrypted
        let streams = header.streams
        self.streams = streams

        var offsets: [Int64] = []
        var off = Int64(SevenZip.signatureHeaderSize) + streams.packPos
        for s in streams.packSizes {
            offsets.append(off)
            off += s
        }
        if off > input.size { throw XipperError.corrupt("7z packed data beyond the end of the archive (truncated, or a volume is missing)") }
        packOffsets = offsets

        // Assign streams to files: files with data take the unpacked streams in order.
        var recs: [SevenZipRecord] = []
        var byFolder = [[Int]](repeating: [], count: streams.folders.count)
        var folder = 0, inFolder = 0, stream = 0
        var offset: Int64 = 0
        for f in header.files {
            var kind: ArchiveEntry.Kind = f.isDirectory ? .directory : .file
            var perm: UInt16?
            if let a = f.attributes, a & SevenZip.Attribute.unixExtension != 0 {
                let mode = UInt16(truncatingIfNeeded: a >> 16)
                perm = mode & 0o7777
                if mode & UInt16(S_IFMT) == UInt16(S_IFLNK) && f.hasStream { kind = .symlink }
            }
            var rec = SevenZipRecord(
                entry: ArchiveEntry(path: Self.cleanPath(f.name), kind: kind, uncompressedSize: 0, compressedSize: 0, modified: f.mtime,
                                    permissions: perm, encryption: .none, method: "", linkTarget: nil),
                hasStream: f.hasStream, isAnti: f.isAnti, folder: -1, offset: 0, size: 0, crc: nil)
            if f.hasStream {
                while folder < streams.folders.count && inFolder >= streams.numUnpackStreams[folder] {
                    folder += 1; inFolder = 0; offset = 0
                }
                guard folder < streams.folders.count, stream < streams.subSizes.count else {
                    throw XipperError.corrupt("7z header lists more files with data than streams")
                }
                let fo = streams.folders[folder]
                rec.folder = folder
                rec.offset = offset
                rec.size = streams.subSizes[stream]
                rec.crc = streams.subCRCs[stream]
                rec.entry.uncompressedSize = rec.size
                rec.entry.compressedSize = inFolder == 0 ? (0..<fo.packedStreams.count).reduce(0) { $0 + streams.packSizes[fo.firstPackStream + $1] } : 0
                rec.entry.method = fo.methodDescription
                rec.entry.encryption = fo.isEncrypted ? .aes(strength: 3, vendorVersion: 0, actualMethod: 0) : .none
                byFolder[folder].append(recs.count)
                offset += rec.size
                inFolder += 1
                stream += 1
            } else if encrypted {
                rec.entry.encryption = .aes(strength: 3, vendorVersion: 0, actualMethod: 0)
            }
            recs.append(rec)
        }
        records = recs
        folderRecords = byFolder
    }

    /// 7-Zip on Windows may store "\" separators; ".." and absolute paths stay for the sanitizer to refuse.
    static func cleanPath(_ name: String) -> String {
        var p = name.replacingOccurrences(of: "\\", with: "/")
        while p.hasSuffix("/") { p.removeLast() }
        return p
    }

    var entries: [ArchiveEntry] { records.filter { !$0.isAnti }.map(\.entry) }

    func packedSize(folder i: Int) -> Int64 {
        let f = streams.folders[i]
        return (0..<f.packedStreams.count).reduce(0) { $0 + streams.packSizes[f.firstPackStream + $1] }
    }

    /// Pull stream of folder `i`'s content.
    /// `workers` > 1 lets one folder decode on several threads (LZMA2 with dictionary resets).
    func open(folder i: Int, workers: Int = 1, qos: QualityOfService = .userInitiated, onPackRead: ((Int) -> Void)? = nil) throws -> ByteSource {
        let f = streams.folders[i]
        let packs = (0..<f.packedStreams.count).map { (packOffsets[f.firstPackStream + $0], streams.packSizes[f.firstPackStream + $0]) }
        var d = SZFolderDecoder(folder: f, input: input, packs: packs, keys: keys)
        d.onPackRead = onPackRead
        d.workers = workers
        d.qos = qos
        return try d.open()
    }
}

// MARK: - Extraction, test, single entry

enum SevenZipExtractor {
    static func selected(_ a: SevenZipArchive, _ selection: Set<String>?) -> [Bool] {
        a.records.map { r in
            if r.isAnti { return false }
            guard let selection, !selection.isEmpty else { return true }
            return selection.contains(r.entry.path) || selection.contains { r.entry.path.hasPrefix($0 + "/") }
        }
    }

    static func precheck(_ a: SevenZipArchive, _ chosen: [Bool], limits: ExtractionLimits) throws {
        let count = chosen.filter { $0 }.count
        if count > limits.maxEntries { throw XipperError.limitExceeded("\(count) entries (limit \(limits.maxEntries))") }
        for (i, f) in a.streams.folders.enumerated() where f.unpackSize > limits.ratioCheckThreshold {
            let ratio = Double(f.unpackSize) / Double(max(a.packedSize(folder: i), 1))
            if ratio > limits.maxCompressionRatio {
                let name = a.folderRecords[i].first.map { a.records[$0].entry.path } ?? "folder \(i)"
                throw XipperError.limitExceeded("\(name) expands \(Int(ratio))× (possible zip bomb)")
            }
        }
        if a.keys == nil, let r = a.records.indices.first(where: { chosen[$0] && a.records[$0].hasStream && a.streams.folders[a.records[$0].folder].isEncrypted }) {
            throw XipperError.passwordRequired(entry: a.records[r].entry.path)
        }
    }

    /// Threads for each folder when there are fewer folders than workers (solid archives).
    static func innerWorkers(_ w: Workload, folders: Int) -> Int {
        folders >= w.workerCount ? 1 : max(1, w.workerCount / max(1, folders))
    }

    /// Maps a decoding failure inside an encrypted folder to "wrong password" (7z has no verifier).
    static func translate(_ error: Error, folder: SZFolder, entry: String) -> Error {
        if error is SZNeedsPassword { return XipperError.passwordRequired(entry: entry) }
        guard folder.isEncrypted, let e = error as? XipperError else { return error }
        switch e {
        case .corrupt, .integrity: return XipperError.wrongPassword(entry: entry)
        default: return e
        }
    }

    /// Streams `size` bytes of `src` to `sink`, checking the CRC.
    static func copy(_ src: ByteSource, size: Int64, crc: UInt32?, entry: String, buf: UnsafeMutableRawPointer,
                     cancel: CancellationToken?, _ sink: ByteSink) throws {
        var left = size
        var c: UInt32 = 0
        while left > 0 {
            try cancel?.check()
            let n = try src.read(into: buf, max: Int(min(left, 1 << 20)))
            if n == 0 { throw XipperError.corrupt("7z stream ended early") }
            let chunk = UnsafeRawBufferPointer(start: buf, count: n)
            if crc != nil { c = CRC32.update(c, chunk) }
            try sink(chunk)
            left -= Int64(n)
        }
        if let crc, c != crc { throw XipperError.integrity(entry: entry, detail: "CRC mismatch") }
    }

    static func extract(_ a: SevenZipArchive, ctx: ExtractionContext, tracker: ProgressTracker, cancel: CancellationToken?) throws {
        let chosen = selected(a, ctx.options.selection)
        try precheck(a, chosen, limits: ctx.options.limits)
        let declared = a.records.indices.reduce(Int64(0)) { $0 + (chosen[$1] ? a.records[$1].size : 0) }
        if declared > ctx.maxBytes { throw ctx.overLimit(needed: declared) }
        tracker.setTotals(bytes: declared, entries: chosen.filter { $0 }.count)

        // Paths without data first: folders and empty files.
        var layouts = [[String]?](repeating: nil, count: a.records.count)
        for (i, r) in a.records.enumerated() where chosen[i] {
            guard let full = ctx.sanitize(r.entry.path, backslashIsSeparator: true) else { continue }
            if ctx.options.flatten && r.entry.kind == .directory { continue }
            let comps = ctx.layout(full)
            layouts[i] = comps
            guard !r.hasStream else { continue }
            do {
                if r.entry.kind == .directory {
                    try ctx.makeDirectory(comps, permissions: r.entry.permissions, modified: r.entry.modified)
                } else {
                    try ctx.writeFile(comps, permissions: r.entry.permissions, modified: r.entry.modified, declaredSize: 0) { _ in }
                }
            } catch let XipperError.unsafeEntry(p, reason) { ctx.skip(p, reason) }
            tracker.add(bytes: 0, entries: 1, current: r.entry.path)
        }

        // Folders decode in parallel (largest first); inside a solid folder files come in order,
        // and small ones are handed to a pool so file creation overlaps with decoding.
        let folders = a.folderRecords.indices.filter { fi in a.folderRecords[fi].contains { chosen[$0] && layouts[$0] != nil } }
            .sorted { a.streams.folders[$0].unpackSize > a.streams.folders[$1].unpackSize }
        let writes = BackgroundWrites(workload: ctx.options.workload)
        defer { writes.waitIgnoringErrors() }
        let perFolder = innerWorkers(ctx.options.workload, folders: folders.count)
        try parallelFor(folders.count, workload: ctx.options.workload, cancel: cancel) { k in
            let fi = folders[k]
            let folder = a.streams.folders[fi]
            let members = a.folderRecords[fi]
            guard let lastWanted = members.lastIndex(where: { chosen[$0] && layouts[$0] != nil }) else { return }
            let buf = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16384)
            defer { buf.deallocate() }
            var current = a.records[members[0]].entry.path
            do {
                let src = try a.open(folder: fi, workers: perFolder, qos: ctx.options.workload == .background ? .utility : .userInitiated)
                for m in members[...lastWanted] {
                    let r = a.records[m]
                    current = r.entry.path
                    guard chosen[m], let comps = layouts[m] else {
                        try src.skip(r.size)
                        continue
                    }
                    if r.entry.kind == .symlink {
                        if r.size > 4096 { try src.skip(r.size); ctx.skip(r.entry.path, "symlink target too long"); continue }
                        var target: [UInt8] = []
                        try copy(src, size: r.size, crc: r.crc, entry: r.entry.path, buf: buf, cancel: cancel) { target.append(contentsOf: $0) }
                        ctx.addSymlink(comps, target: String(decoding: target, as: UTF8.self), modified: r.entry.modified)
                        tracker.add(bytes: r.size)
                    } else if r.size <= BackgroundWrites.inlineLimit {
                        var data = [UInt8]()
                        data.reserveCapacity(Int(r.size))
                        try copy(src, size: r.size, crc: r.crc, entry: r.entry.path, buf: buf, cancel: cancel) { data.append(contentsOf: $0) }
                        tracker.add(bytes: r.size)
                        let content = data
                        try writes.submit {
                            do {
                                try ctx.writeFile(comps, permissions: r.entry.permissions, modified: r.entry.modified, declaredSize: r.size) { sink in
                                    try content.withUnsafeBytes { try sink($0) }
                                }
                            } catch let XipperError.unsafeEntry(p, reason) { ctx.skip(p, reason) }
                        }
                    } else {
                        do {
                            try ctx.writeFile(comps, permissions: r.entry.permissions, modified: r.entry.modified, declaredSize: r.size) { sink in
                                try copy(src, size: r.size, crc: r.crc, entry: r.entry.path, buf: buf, cancel: cancel) { chunk in
                                    try sink(chunk)
                                    tracker.add(bytes: Int64(chunk.count))
                                }
                            }
                        } catch let XipperError.unsafeEntry(p, reason) {
                            // The data still has to be consumed to reach the next file.
                            ctx.skip(p, reason)
                            try src.skip(r.size)
                        }
                    }
                    tracker.add(bytes: 0, entries: 1, current: r.entry.path)
                }
            } catch {
                throw translate(error, folder: folder, entry: current)
            }
        }
        try writes.wait()
        try ctx.finalize()
    }

    /// Decodes everything and checks every CRC; returns the entries that failed.
    static func test(_ a: SevenZipArchive, workload: Workload, tracker: ProgressTracker, cancel: CancellationToken?) throws -> [SkippedEntry] {
        if a.keys == nil, let r = a.records.first(where: { $0.hasStream && a.streams.folders[$0.folder].isEncrypted }) {
            throw XipperError.passwordRequired(entry: r.entry.path)
        }
        let order = a.folderRecords.indices.sorted { a.streams.folders[$0].unpackSize > a.streams.folders[$1].unpackSize }
        tracker.setTotals(bytes: a.streams.folders.reduce(0) { $0 + $1.unpackSize }, entries: a.records.count)
        tracker.add(bytes: 0, entries: a.records.filter { !$0.hasStream }.count)
        let failures = Mutex<[SkippedEntry]>([])
        let perFolder = innerWorkers(workload, folders: order.count)
        try parallelFor(order.count, workload: workload, cancel: cancel) { k in
            let fi = order[k]
            let folder = a.streams.folders[fi]
            let buf = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16384)
            defer { buf.deallocate() }
            var current = a.folderRecords[fi].first.map { a.records[$0].entry.path } ?? "folder \(fi)"
            do {
                let src = try a.open(folder: fi, workers: perFolder, qos: workload == .background ? .utility : .userInitiated)
                var folderCRC: UInt32 = 0
                for m in a.folderRecords[fi] {
                    let r = a.records[m]
                    current = r.entry.path
                    try copy(src, size: r.size, crc: r.crc, entry: r.entry.path, buf: buf, cancel: cancel) { chunk in
                        if folder.crc != nil { folderCRC = CRC32.update(folderCRC, chunk) }
                        tracker.add(bytes: Int64(chunk.count))
                    }
                    tracker.add(bytes: 0, entries: 1, current: r.entry.path)
                }
                if let c = folder.crc, a.folderRecords[fi].count > 1, folderCRC != c {
                    throw XipperError.integrity(entry: current, detail: "folder CRC mismatch")
                }
            } catch XipperError.cancelled {
                throw XipperError.cancelled
            } catch {
                let e = translate(error, folder: folder, entry: current)
                failures.withLock { $0.append(SkippedEntry(path: current, reason: "\(e)")) }
            }
        }
        return failures.withLock { $0 }.sorted { $0.path < $1.path }
    }

    /// Streams one entry's content to `sink` (which may stop early by throwing).
    static func read(_ a: SevenZipArchive, record r: SevenZipRecord, sink: ByteSink) throws {
        guard r.hasStream else { return }
        let folder = a.streams.folders[r.folder]
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16384)
        defer { buf.deallocate() }
        do {
            let src = try a.open(folder: r.folder)
            try src.skip(r.offset)
            try copy(src, size: r.size, crc: r.crc, entry: r.entry.path, buf: buf, cancel: nil, sink)
        } catch let e as XipperError {
            throw translate(e, folder: folder, entry: r.entry.path)
        } catch is SZNeedsPassword {
            throw XipperError.passwordRequired(entry: r.entry.path)
        }
    }
}
