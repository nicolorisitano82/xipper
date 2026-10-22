import CryptoKit
import Foundation
import Synchronization

/// Reads XIZ 1.0 (and 0.1 from the beta). Everything the extractor acts on comes from the catalog,
/// validated up front: frames strictly increasing and non-overlapping, extents inside their frames
/// and summing to the declared size, declared total checked against free space and limits before
/// writing anything. Encrypted archives authenticate the catalog and every frame (AES-256-GCM).
final class XizArchive: @unchecked Sendable {
    let reader: FileReader
    let catalog: Xiz.Catalog
    let footer: Xiz.Footer
    let superblock: Xiz.Superblock
    /// Set for encrypted archives (opened with the right password).
    let keys: XizKeys?
    /// 1 for a single-segment archive; appends add one each (1.1).
    let segments: Int
    /// Where the current footer starts (bytes after it are an interrupted append, ignored).
    var footerOffset: Int64 { footer.catalogOffset + footer.catalogCSize }

    var isEncrypted: Bool { keys != nil }

    static func looksLike(_ head: [UInt8]) -> Bool { head.starts(with: Xiz.superMagic) }

    /// `passwordRequired` for an encrypted archive opened without a password, `wrongPassword` when it does not fit.
    init(path: String, password: String? = nil) throws {
        reader = try FileReader(path: path)
        let size = reader.size
        guard size >= Int64(Xiz.superblockSize + Xiz.footerSize) else { throw XipperError.corrupt("XIZ archive too small") }
        let sbBytes = try reader.read(at: 0, count: Xiz.superblockSize)
        let sb = try Xiz.Superblock.decode(sbBytes)
        superblock = sb
        let dataStart = Int64(Xiz.superblockSize) + Int64(sb.keysLength)
        if sb.required.contains(.encrypted) {
            guard let password else { throw XipperError.passwordRequired(entry: (path as NSString).lastPathComponent) }
            guard dataStart + Int64(Xiz.footerSize) <= size else { throw XipperError.corrupt("XIZ keys block") }
            let block = try reader.read(at: Int64(Xiz.superblockSize), count: Int(sb.keysLength))
            let fileKey: SymmetricKey
            do {
                fileKey = try XizKeys.open(keysBlock: block, superblock: sbBytes, password: password)
            } catch XipperError.wrongPassword {
                throw XipperError.wrongPassword(entry: (path as NSString).lastPathComponent)
            }
            keys = XizKeys(fileKey: fileKey, archiveID: sb.archiveID)
        } else {
            keys = nil
        }

        let (footerStart, footer) = try Self.lastFooter(reader, dataStart: dataStart)
        guard footer.major == sb.major else { throw XipperError.corrupt("XIZ footer does not match the superblock") }
        // Appended segments (1.1): each earlier catalog and footer is a declared gap between frames.
        var gaps: [Int64: Int64] = [:]  // start → end
        var segment: UInt32 = 0
        var prev = Int64(bitPattern: footer.previousFooter)
        var bound = footerStart
        while prev != 0 {
            guard prev >= dataStart, prev + Int64(Xiz.footerSize) <= bound, segment < 65535 else {
                throw XipperError.corrupt("XIZ segment chain")
            }
            let older = try Xiz.Footer.decode(try reader.read(at: prev, count: Xiz.footerSize))
            guard older.catalogOffset >= dataStart, older.catalogOffset + older.catalogCSize == prev else {
                throw XipperError.corrupt("XIZ segment chain")
            }
            gaps[older.catalogOffset] = prev + Int64(Xiz.footerSize)
            bound = older.catalogOffset
            prev = Int64(bitPattern: older.previousFooter)
            segment += 1
        }
        segments = Int(segment) + 1
        guard footer.catalogOffset >= dataStart, footer.catalogCSize > 0,
              footer.catalogCSize <= Int64(Xiz.maxCatalog), footer.catalogUSize <= Int64(Xiz.maxCatalog),
              footer.catalogOffset + footer.catalogCSize == footerStart else {
            throw XipperError.corrupt("invalid XIZ catalog location")
        }
        var packed = try reader.read(at: footer.catalogOffset, count: Int(footer.catalogCSize))
        guard Xiz.sha256(packed) == footer.catalogSHA256 else { throw XipperError.corrupt("XIZ catalog hash mismatch") }
        if let keys { packed = try keys.openCatalog(packed, footer: footer, segment: segment) }
        let raw = try packed.withUnsafeBytes { try Xiz.zstdDecompress($0, size: Int(footer.catalogUSize)) }
        let c = try Xiz.decodeCatalog(raw)
        guard c.frames.count == Int(footer.frameCount), c.entries.count == Int(footer.entryCount) else {
            throw XipperError.corrupt("XIZ catalog does not match its footer")
        }
        // Frames: strictly increasing, non-overlapping, after the keys and before the catalog, bounded.
        let overhead = UInt32(keys == nil ? 0 : Xiz.tagSize)
        var next = dataStart
        func skipGaps() { while let end = gaps[next] { next = end } }
        for f in c.frames {
            skipGaps()
            guard f.offset == next, f.usize <= UInt32(Xiz.maxFrameData), f.csize <= UInt32(Xiz.maxFrameData) + 4096,
                  f.codec != .store || f.csize == f.usize + overhead, f.csize >= overhead else {
                throw XipperError.corrupt("XIZ frames overlap or leave gaps (possible bomb)")
            }
            next = f.offset + Int64(Xiz.frameHeaderSize) + Int64(f.csize)
        }
        skipGaps()
        guard next == footer.catalogOffset else { throw XipperError.corrupt("XIZ frames overlap the catalog") }
        // Entries: extents inside their frames, sizes add up, total as declared.
        var total: UInt64 = 0
        for e in c.entries {
            var sum: UInt64 = 0
            for x in e.extents {
                guard Int(x.frame) < c.frames.count, UInt64(x.offset) + UInt64(x.length) <= UInt64(c.frames[Int(x.frame)].usize) else {
                    throw XipperError.corrupt("XIZ extent outside its frame: \(e.path)")
                }
                sum += UInt64(x.length)
            }
            guard e.type == .file ? sum == e.size : (e.extents.isEmpty && e.size == 0) else {
                throw XipperError.corrupt("XIZ entry size does not match its data: \(e.path)")
            }
            total += e.size
        }
        guard total == footer.totalBytes else { throw XipperError.corrupt("XIZ declared size mismatch") }
        catalog = c
        self.footer = footer
    }

    /// The last valid footer: normally the file's last 96 bytes; after an interrupted append, the
    /// one before the incomplete segment (searched backwards, its catalog location must fit).
    private static func lastFooter(_ reader: FileReader, dataStart: Int64) throws -> (Int64, Xiz.Footer) {
        let size = reader.size
        if let f = try? Xiz.Footer.decode(try reader.read(at: size - Int64(Xiz.footerSize), count: Xiz.footerSize)),
           f.catalogOffset + f.catalogCSize == size - Int64(Xiz.footerSize) {
            return (size - Int64(Xiz.footerSize), f)
        }
        let window = 1 << 20
        var end = size - 1
        while end > dataStart + Int64(Xiz.footerSize) {
            let start = max(dataStart, end - Int64(window))
            let chunk = try reader.read(at: start, count: Int(end - start))
            var i = chunk.count - 4
            while i >= 0 {
                if chunk[i] == 0x58, chunk[i + 1] == 0x49, chunk[i + 2] == 0x5A, chunk[i + 3] == 0x21 {  // "XIZ!"
                    let footerAt = start + Int64(i) + 4 - Int64(Xiz.footerSize)
                    if footerAt >= dataStart, let f = try? Xiz.Footer.decode(try reader.read(at: footerAt, count: Xiz.footerSize)),
                       f.catalogOffset + f.catalogCSize == footerAt {
                        return (footerAt, f)
                    }
                }
                i -= 1
            }
            end = start + 3
        }
        throw XipperError.corrupt("XIZ footer not found")
    }

    var entries: [ArchiveEntry] {
        let encryption: EntryEncryption = isEncrypted ? .aes(strength: 3, vendorVersion: 0, actualMethod: 0) : .none
        return catalog.entries.map { e in
            ArchiveEntry(path: e.path, kind: e.type == .directory ? .directory : e.type == .symlink ? .symlink : .file,
                         uncompressedSize: Int64(e.size), compressedSize: 0, modified: e.modified, permissions: e.mode,
                         encryption: e.type == .file ? encryption : .none, method: "xiz", linkTarget: e.type == .symlink ? e.link : nil)
        }
    }

    /// The digest stored for file content: SHA-256, or HMAC-SHA-256 under the archive's key.
    func digest(_ chunks: [UnsafeRawBufferPointer]) -> [UInt8] {
        if let keys {
            var h = keys.fileDigest()
            for c in chunks { h.update(data: c) }
            return Array(h.finalize())
        }
        var h = SHA256()
        for c in chunks { h.update(bufferPointer: c) }
        return Array(h.finalize())
    }

    /// One frame's data, checked against the catalog (header fields, CRC-32C, authentication,
    /// exact decompressed size).
    func frameData(_ index: Int) throws -> [UInt8] {
        let f = catalog.frames[index]
        let header = try reader.read(at: f.offset, count: Xiz.frameHeaderSize)
        let expected = Xiz.frameHeader(index: UInt32(index), f)
        guard header == expected else { throw XipperError.corrupt("XIZ frame \(index) header does not match the catalog") }
        var payload = try reader.read(at: f.offset + Int64(Xiz.frameHeaderSize), count: Int(f.csize))
        let crc = Xiz.crc32c(payload)
        guard crc == f.crc else {
            throw XipperError.checksumMismatch(entry: "frame \(index)", expected: f.crc, actual: crc)
        }
        if let keys { payload = try keys.openFrame(payload, index: UInt32(index), f) }
        switch f.codec {
        case .store:
            guard payload.count == Int(f.usize) else { throw XipperError.corrupt("XIZ frame \(index) size") }
            return payload
        case .zstd: return try payload.withUnsafeBytes { try Xiz.zstdDecompress($0, size: Int(f.usize)) }
        }
    }
}

/// Keeps decoded frames while files still need them; decodes ahead in parallel.
final class FrameCache: @unchecked Sendable {
    private let archive: XizArchive
    private let workload: Workload
    private let cancel: CancellationToken?
    private var frames: [Int: [UInt8]] = [:]
    private let lock = NSLock()

    init(_ archive: XizArchive, workload: Workload, cancel: CancellationToken?) {
        self.archive = archive
        self.workload = workload
        self.cancel = cancel
    }

    func prefetch(_ indices: [Int]) throws {
        let missing = lock.withLock { indices.filter { frames[$0] == nil } }
        let decoded = Mutex<[Int: [UInt8]]>([:])
        try parallelFor(missing.count, workload: workload, cancel: cancel) { k in
            let data = try self.archive.frameData(missing[k])
            decoded.withLock { $0[missing[k]] = data }
        }
        let d = decoded.withLock { $0 }
        lock.withLock { frames.merge(d) { a, _ in a } }
    }

    func frame(_ i: Int) throws -> [UInt8] {
        if let f = lock.withLock({ frames[i] }) { return f }
        let f = try archive.frameData(i)
        lock.withLock { frames[i] = f }
        return f
    }

    func evict(_ i: Int) { _ = lock.withLock { frames.removeValue(forKey: i) } }
}

enum XizExtractor {
    static func extract(_ a: XizArchive, ctx: ExtractionContext, tracker: ProgressTracker, cancel: CancellationToken?) throws {
        let entries = a.catalog.entries
        if entries.count > ctx.options.limits.maxEntries {
            throw XipperError.limitExceeded("\(entries.count) entries (limit \(ctx.options.limits.maxEntries))")
        }
        let selected = entries.indices.filter { i in
            guard let sel = ctx.options.selection, !sel.isEmpty else { return true }
            let p = entries[i].path
            return sel.contains(p) || sel.contains { p.hasPrefix($0 + "/") }
        }
        let declared = selected.reduce(Int64(0)) { $0 + Int64(entries[$1].size) }
        if declared > ctx.maxBytes && !ctx.options.limits.stopAtLimit { throw ctx.overLimit(needed: declared) }
        tracker.setTotals(bytes: declared, entries: selected.count)

        // Directories first, symlinks deferred by the context, files in frame order.
        var files: [Int] = []
        for i in selected {
            let e = entries[i]
            guard let full = ctx.sanitize(e.path) else { continue }
            if ctx.options.flatten && e.type == .directory { continue }
            let comps = ctx.layout(full)
            switch e.type {
            case .directory:
                do { try ctx.makeDirectory(comps, permissions: e.mode, modified: e.modified) } catch let XipperError.unsafeEntry(p, r) {
                    ctx.skip(p, r, .throughSymlink)
                }
                ctx.setAttributes(e.xattrs, onDirectory: comps)
                tracker.add(bytes: 0, entries: 1)
            case .symlink:
                ctx.addSymlink(comps, target: e.link, modified: e.modified)
                tracker.add(bytes: 0, entries: 1)
            case .file:
                files.append(i)
            }
        }
        files.sort { (entries[$0].extents.first?.frame ?? 0) < (entries[$1].extents.first?.frame ?? 0) }
        var lastUse: [Int: Int] = [:]
        for (pos, i) in files.enumerated() { for x in entries[i].extents { lastUse[Int(x.frame)] = pos } }

        let cache = FrameCache(a, workload: ctx.options.workload, cancel: cancel)
        let writes = BackgroundWrites(workload: ctx.options.workload)
        defer { writes.waitIgnoringErrors() }
        let window = max(2, ctx.options.workload.workerCount * 2)
        var prefetched = -1
        for (pos, i) in files.enumerated() {
            try cancel?.check()
            let e = entries[i]
            // Big files are streamed frame by frame instead of being assembled in memory.
            if e.size > streamFrom {
                try writes.wait()
                guard let full = ctx.sanitize(e.path) else { continue }
                do {
                    try ctx.writeFile(ctx.layout(full), permissions: e.mode, modified: e.modified, declaredSize: Int64(e.size),
                                      xattrs: e.xattrs) { sink in
                        try stream(e, from: a, cache: cache, window: window, evictable: { lastUse[$0].map { $0 <= pos } ?? true }) {
                            try sink($0)
                        }
                    }
                } catch let XipperError.unsafeEntry(p, r) {
                    ctx.skip(p, r, .throughSymlink)
                }
                tracker.add(bytes: Int64(e.size), entries: 1, current: e.path)
                continue
            }
            let maxFrame = e.extents.map { Int($0.frame) }.max() ?? -1
            if maxFrame > prefetched {
                let upTo = min(a.catalog.frames.count, maxFrame + window)
                try cache.prefetch(Array((prefetched + 1)..<upTo))
                prefetched = upTo - 1
            }
            guard let full = ctx.sanitize(e.path) else { continue }
            let comps = ctx.layout(full)
            // Gather the bytes now (frames may be evicted), write in the background.
            var data = [UInt8]()
            data.reserveCapacity(Int(e.size))
            for x in e.extents {
                let f = try cache.frame(Int(x.frame))
                data.append(contentsOf: f[Int(x.offset)..<Int(x.offset + x.length)])
            }
            if let h = e.sha256, data.withUnsafeBytes({ a.digest([$0]) }) != h {
                throw XipperError.integrity(entry: e.path, detail: "SHA-256 mismatch")
            }
            for x in e.extents where lastUse[Int(x.frame)] == pos { cache.evict(Int(x.frame)) }
            let content = data, attrs = e.xattrs, mode = e.mode, modified = e.modified, size = Int64(e.size)
            try writes.submit {
                do {
                    try ctx.writeFile(comps, permissions: mode, modified: modified, declaredSize: size, xattrs: attrs) { sink in
                        try content.withUnsafeBytes { try sink($0) }
                    }
                } catch let XipperError.unsafeEntry(p, r) {
                    ctx.skip(p, r, .throughSymlink)
                }
                tracker.add(bytes: size, entries: 1, current: e.path)
            }
        }
        try writes.wait()
        try ctx.finalize()
    }

    /// Files above this size are extracted and hashed as a stream (memory stays at a few frames).
    static let streamFrom: UInt64 = 64 << 20

    /// Passes a file's content to `body` extent by extent, decoding `window` extents' frames ahead
    /// in parallel and dropping frames this file no longer needs (when `evictable` agrees); checks
    /// the stored digest at the end.
    static func stream(_ e: Xiz.Entry, from a: XizArchive, cache: FrameCache, window: Int, evictable: (Int) -> Bool,
                       _ body: (UnsafeRawBufferPointer) throws -> Void) throws {
        var left: [Int: Int] = [:]
        for x in e.extents { left[Int(x.frame), default: 0] += 1 }
        var digest = XizContentDigest(keys: a.keys)
        var k = 0
        while k < e.extents.count {
            let batch = e.extents[k..<min(e.extents.count, k + window)]
            try cache.prefetch(Array(Set(batch.map { Int($0.frame) })).sorted())
            for x in batch {
                let fi = Int(x.frame)
                let f = try cache.frame(fi)
                try f.withUnsafeBytes { raw in
                    let piece = UnsafeRawBufferPointer(rebasing: raw[Int(x.offset)..<Int(x.offset + x.length)])
                    digest.update(piece)
                    try body(piece)
                }
                left[fi]! -= 1
                if left[fi] == 0 && evictable(fi) { cache.evict(fi) }
            }
            k += batch.count
        }
        if let h = e.sha256, digest.finish() != h { throw XipperError.integrity(entry: e.path, detail: "SHA-256 mismatch") }
    }

    /// Checks every frame (header, CRC-32C, decompression to the exact size) and, with `digests`,
    /// the SHA-256 of every file.
    static func test(_ a: XizArchive, workload: Workload, tracker: ProgressTracker, digests: DigestCollector?,
                     cancel: CancellationToken?) throws -> [SkippedEntry] {
        let entries = a.catalog.entries
        tracker.setTotals(bytes: Int64(a.footer.totalBytes), entries: entries.count)
        let failedFrames = Mutex<[Int: XipperError]>([:])
        if digests == nil {
            try parallelFor(a.catalog.frames.count, workload: workload, cancel: cancel) { i in
                do {
                    let d = try a.frameData(i)
                    tracker.add(bytes: Int64(d.count))
                } catch let e as XipperError where e != .cancelled {
                    failedFrames.withLock { $0[i] = e }
                }
            }
        }
        var failures: [SkippedEntry] = []
        let bad = failedFrames.withLock { $0 }
        if digests == nil {
            for e in entries where e.type == .file {
                if let x = e.extents.first(where: { bad[Int($0.frame)] != nil }), let err = bad[Int(x.frame)] {
                    failures.append(SkippedEntry(path: e.path, error: err))
                }
                tracker.add(bytes: 0, entries: 1, current: e.path)
            }
            return failures
        }
        // With digests: each file streams through (frames decoded ahead in parallel, a window at a time).
        let cache = FrameCache(a, workload: workload, cancel: cancel)
        let window = max(2, workload.workerCount * 2)
        var lastUse: [Int: Int] = [:]
        let fileEntries = entries.filter { $0.type == .file }
        for (pos, e) in fileEntries.enumerated() { for x in e.extents { lastUse[Int(x.frame)] = pos } }
        for (pos, e) in fileEntries.enumerated() {
            try cancel?.check()
            do {
                var h = SHA256()
                try stream(e, from: a, cache: cache, window: window, evictable: { lastUse[$0].map { $0 <= pos } ?? true }) {
                    h.update(bufferPointer: $0)
                }
                digests?.add(e.path, h)
            } catch let err as XipperError where err != .cancelled {
                failures.append(SkippedEntry(path: e.path, error: err))
            }
            tracker.add(bytes: Int64(e.size), entries: 1, current: e.path)
        }
        return failures
    }

    /// The beginning of one entry (Quick Look, inspector preview).
    static func read(_ a: XizArchive, path: String, maxBytes: Int) throws -> EntryContent {
        guard let i = a.catalog.entries.firstIndex(where: { $0.path == path }) else {
            throw XipperError.invalidArgument("no entry named \(path)")
        }
        let e = a.catalog.entries[i]
        if e.type == .symlink { return EntryContent(entry: a.entries[i], data: Array(e.link.utf8), truncated: false) }
        var data: [UInt8] = []
        for x in e.extents where data.count < maxBytes {
            let f = try a.frameData(Int(x.frame))
            data.append(contentsOf: f[Int(x.offset)..<Int(x.offset + x.length)].prefix(maxBytes - data.count))
        }
        return EntryContent(entry: a.entries[i], data: data, truncated: UInt64(data.count) < e.size)
    }
}

/// SHA-256 of file content, or HMAC-SHA-256 under the archive's key when encrypted, computed as
/// the content streams by.
struct XizContentDigest {
    private var plain: SHA256?
    private var keyed: HMAC<SHA256>?

    init(keys: XizKeys?) {
        if let keys { keyed = keys.fileDigest() } else { plain = SHA256() }
    }

    mutating func update(_ b: UnsafeRawBufferPointer) {
        if keyed != nil { keyed!.update(data: b) } else { plain!.update(bufferPointer: b) }
    }

    func finish() -> [UInt8] { keyed.map { Array($0.finalize()) } ?? Array(plain!.finalize()) }
}
