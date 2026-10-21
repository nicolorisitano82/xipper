import CryptoKit
import Foundation
import Synchronization

/// Reads XIZ v0. Everything the extractor acts on comes from the catalog, validated up front:
/// frames strictly increasing and non-overlapping, extents inside their frames and summing to the
/// declared size, declared total checked against free space and limits before writing anything.
final class XizArchive: @unchecked Sendable {
    let reader: FileReader
    let catalog: Xiz.Catalog
    let footer: Xiz.Footer

    static func looksLike(_ head: [UInt8]) -> Bool { head.starts(with: Xiz.superMagic) }

    init(path: String) throws {
        reader = try FileReader(path: path)
        let size = reader.size
        guard size >= Int64(Xiz.superblockSize + Xiz.footerSize) else { throw XipperError.corrupt("XIZ archive too small") }
        let sb = try reader.read(at: 0, count: Xiz.superblockSize)
        guard sb.starts(with: Xiz.superMagic) else { throw XipperError.corrupt("not a XIZ archive") }
        let sbCRC = sb.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 60, as: UInt32.self).littleEndian }
        guard sbCRC == Xiz.crc32c(Array(sb[0..<60])) else { throw XipperError.corrupt("XIZ superblock checksum mismatch") }
        let major = sb.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt16.self).littleEndian }
        guard major == Xiz.versionMajor else { throw XipperError.unsupported("XIZ version \(major)") }

        let footerStart = size - Int64(Xiz.footerSize)
        let footer = try Xiz.Footer.decode(try reader.read(at: footerStart, count: Xiz.footerSize))
        guard footer.catalogOffset >= Int64(Xiz.superblockSize), footer.catalogCSize > 0,
              footer.catalogCSize <= Int64(Xiz.maxCatalog), footer.catalogUSize <= Int64(Xiz.maxCatalog),
              footer.catalogOffset + footer.catalogCSize == footerStart else {
            throw XipperError.corrupt("invalid XIZ catalog location")
        }
        let packed = try reader.read(at: footer.catalogOffset, count: Int(footer.catalogCSize))
        guard Xiz.sha256(packed) == footer.catalogSHA256 else { throw XipperError.corrupt("XIZ catalog hash mismatch") }
        let raw = try packed.withUnsafeBytes { try Xiz.zstdDecompress($0, size: Int(footer.catalogUSize)) }
        let c = try Xiz.decodeCatalog(raw)
        guard c.frames.count == Int(footer.frameCount), c.entries.count == Int(footer.entryCount) else {
            throw XipperError.corrupt("XIZ catalog does not match its footer")
        }
        // Frames: strictly increasing, non-overlapping, before the catalog, bounded.
        var next = Int64(Xiz.superblockSize)
        for f in c.frames {
            guard f.offset == next, f.usize <= UInt32(Xiz.maxFrameData), f.csize <= UInt32(Xiz.maxFrameData) + 4096,
                  f.codec != .store || f.csize == f.usize else {
                throw XipperError.corrupt("XIZ frames overlap or leave gaps (possible bomb)")
            }
            next = f.offset + Int64(Xiz.frameHeaderSize) + Int64(f.csize)
        }
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

    var entries: [ArchiveEntry] {
        catalog.entries.map { e in
            ArchiveEntry(path: e.path, kind: e.type == .directory ? .directory : e.type == .symlink ? .symlink : .file,
                         uncompressedSize: Int64(e.size), compressedSize: 0, modified: e.modified, permissions: e.mode,
                         encryption: .none, method: "xiz", linkTarget: e.type == .symlink ? e.link : nil)
        }
    }

    /// One frame's data, checked against the catalog (header fields, CRC-32C, exact size).
    func frameData(_ index: Int) throws -> [UInt8] {
        let f = catalog.frames[index]
        let header = try reader.read(at: f.offset, count: Xiz.frameHeaderSize)
        let expected = Xiz.frameHeader(index: UInt32(index), f)
        guard header == expected else { throw XipperError.corrupt("XIZ frame \(index) header does not match the catalog") }
        let payload = try reader.read(at: f.offset + Int64(Xiz.frameHeaderSize), count: Int(f.csize))
        let crc = Xiz.crc32c(payload)
        guard crc == f.crc else {
            throw XipperError.checksumMismatch(entry: "frame \(index)", expected: f.crc, actual: crc)
        }
        switch f.codec {
        case .store: return payload
        case .zstd: return try payload.withUnsafeBytes { try Xiz.zstdDecompress($0, size: Int(f.usize)) }
        }
    }
}

/// Keeps decoded frames while files still need them; decodes ahead in parallel.
private final class FrameCache: @unchecked Sendable {
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
            if let h = e.sha256, Xiz.sha256(data) != h {
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
        // With digests: assemble each file (frames decoded ahead in parallel).
        let cache = FrameCache(a, workload: workload, cancel: cancel)
        try cache.prefetch(Array(a.catalog.frames.indices))
        for e in entries where e.type == .file {
            try cancel?.check()
            do {
                var h = SHA256()
                for x in e.extents {
                    let f = try cache.frame(Int(x.frame))
                    f.withUnsafeBytes { h.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[Int(x.offset)..<Int(x.offset + x.length)])) }
                }
                let digest = Array(h.finalize())
                if let expected = e.sha256, expected != digest {
                    failures.append(SkippedEntry(path: e.path, error: .integrity(entry: e.path, detail: "SHA-256 mismatch")))
                } else {
                    digests?.add(e.path, h)
                }
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
