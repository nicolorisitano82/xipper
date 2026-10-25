import CryptoKit
import CZstd
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
    /// Dictionary frames (1.2): ID → frame index.
    let dictionaries: [UInt16: Int]
    /// Keys per access group (1.3); a 1.0–1.2 encrypted archive has group 0 only.
    let groupKeys: [UInt16: XizKeys]
    /// 1.3: groups this reader has no key for (their entries are not listed).
    let hiddenGroups: Int
    /// 1.3: name and folders of each group it opened.
    let groupInfo: [UInt16: (name: String, prefixes: [String])]
    /// 1.3: the current segment's directory.
    let directory: XizDirectory?
    private var ddicts: [UInt16: OpaquePointer] = [:]
    private let ddictLock = NSLock()

    deinit { for d in ddicts.values { ZSTD_freeDDict(d) } }

    /// Where the current footer starts (bytes after it are an interrupted append, ignored).
    var footerOffset: Int64 { footer.catalogOffset + footer.catalogCSize }

    var isEncrypted: Bool { keys != nil }

    static func looksLike(_ head: [UInt8]) -> Bool { head.starts(with: Xiz.superMagic) }

    /// XIZ 1.3 with a directory (access groups or signatures).
    static func hasDirectory(_ path: String) throws -> Bool {
        let r = try FileReader(path: path)
        return try Xiz.Superblock.decode(try r.read(at: 0, count: Xiz.superblockSize)).required.contains(.directory)
    }

    /// `passwordRequired` for an encrypted archive opened without a password, `wrongPassword` when it does not fit.
    init(path: String, password: String? = nil) throws {
        reader = try FileReader(path: path)
        let size = reader.size
        guard size >= Int64(Xiz.superblockSize + Xiz.footerSize) else { throw XipperError.corrupt("XIZ archive too small") }
        let sbBytes = try reader.read(at: 0, count: Xiz.superblockSize)
        let sb = try Xiz.Superblock.decode(sbBytes)
        superblock = sb
        let dataStart = Int64(Xiz.superblockSize) + Int64(sb.keysLength)
        if sb.required.contains(.directory) {
            let l = try Self.loadDirectory(reader, sb: sb, sbBytes: sbBytes, dataStart: dataStart, password: password,
                                           name: (path as NSString).lastPathComponent)
            catalog = l.catalog
            footer = l.footer
            keys = l.groupKeys[0] ?? l.groupKeys.values.first
            groupKeys = l.groupKeys
            segments = l.segments
            dictionaries = [:]
            hiddenGroups = l.hidden
            groupInfo = l.info
            directory = l.directory
            return
        }
        groupInfo = [:]
        hiddenGroups = 0
        directory = nil
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
        groupKeys = keys.map { [0: $0] } ?? [:]

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
        // Dictionaries (1.2): declared by the superblock, each defined once and before its users.
        var dicts: [UInt16: Int] = [:]
        for (i, f) in c.frames.enumerated() where f.flags != 0 || f.dictionary != 0 {
            guard sb.required.contains(.dictionaries), f.dictionary != 0 else { throw XipperError.corrupt("XIZ frame \(i): dictionary not declared") }
            if f.flags & Xiz.dictionaryFrame != 0 {
                guard dicts[f.dictionary] == nil, f.usize <= UInt32(Xiz.maxDictionary) else {
                    throw XipperError.corrupt("XIZ dictionary \(f.dictionary) defined twice or too big")
                }
                dicts[f.dictionary] = i
            } else {
                guard f.codec == .zstd, dicts[f.dictionary] != nil else {
                    throw XipperError.corrupt("XIZ frame \(i) uses dictionary \(f.dictionary), not defined before it")
                }
            }
        }
        // Entries: extents inside their frames, sizes add up, total as declared.
        var total: UInt64 = 0
        for e in c.entries {
            var sum: UInt64 = 0
            for x in e.extents {
                guard Int(x.frame) < c.frames.count, c.frames[Int(x.frame)].flags & Xiz.dictionaryFrame == 0, UInt64(x.offset) + UInt64(x.length) <= UInt64(c.frames[Int(x.frame)].usize) else {
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
        dictionaries = dicts
        self.footer = footer
    }

    struct Loaded {
        var catalog: Xiz.Catalog
        var footer: Xiz.Footer
        var groupKeys: [UInt16: XizKeys]
        var segments: Int
        var hidden: Int
        var info: [UInt16: (name: String, prefixes: [String])]
        var directory: XizDirectory
    }

    /// 1.3 (§13): group keys from the stanzas the credentials open, the directory, the catalogs of
    /// the groups held, and the same layout checks as for 1.0–1.2.
    private static func loadDirectory(_ reader: FileReader, sb: Xiz.Superblock, sbBytes: [UInt8], dataStart: Int64,
                                      password: String?, name: String) throws -> Loaded {
        var groupKeys: [UInt16: XizKeys] = [:]
        if sb.required.contains(.encrypted) {
            let passwords = (password.map { [$0] } ?? []) + XizCredentials.shared.passwords
            let identities = XizCredentials.shared.identities
            guard !passwords.isEmpty || !identities.isEmpty else { throw XipperError.passwordRequired(entry: name) }
            guard dataStart + Int64(Xiz.footerSize) <= reader.size else { throw XipperError.corrupt("XIZ keys block") }
            let block = try reader.read(at: Int64(Xiz.superblockSize), count: Int(sb.keysLength))
            let opened = try XizAccessKeys.open(block, superblock: sbBytes, passwords: passwords, identities: identities)
            guard !opened.groupKeys.isEmpty else {
                if let t = opened.thresholds.first(where: { $0.opened > 0 && $0.opened < $0.k }) {
                    throw XipperError.invalidArgument("\(name): \(t.label) needs \(t.k) custodians, \(t.opened) unlocked")
                }
                throw XipperError.wrongPassword(entry: name)
            }
            for (g, k) in opened.groupKeys { groupKeys[g] = XizKeys(fileKey: k, archiveID: sb.archiveID) }
        }
        let (footerStart, footer) = try lastFooter(reader, dataStart: dataStart)
        guard footer.major == sb.major, footer.catalogCSize >= 16, footer.catalogCSize <= Int64(Xiz.maxCatalog),
              footer.catalogOffset + footer.catalogCSize == footerStart else { throw XipperError.corrupt("invalid XIZ directory location") }
        let dirBytes = try reader.read(at: footer.catalogOffset, count: Int(footer.catalogCSize))
        guard Xiz.sha256(dirBytes) == footer.catalogSHA256 else { throw XipperError.corrupt("XIZ directory hash mismatch") }
        let directory = try XizDirectory.decode(dirBytes)

        // Earlier segments: from their first group catalog to the end of their footer is a declared gap.
        var gaps: [Int64: Int64] = [:]
        var segment: UInt32 = 0
        var prev = Int64(bitPattern: footer.previousFooter)
        var bound = footer.catalogOffset
        while prev != 0 {
            guard prev >= dataStart, prev + Int64(Xiz.footerSize) <= bound, segment < 65535 else { throw XipperError.corrupt("XIZ segment chain") }
            let older = try Xiz.Footer.decode(try reader.read(at: prev, count: Xiz.footerSize))
            guard older.catalogOffset >= dataStart, older.catalogOffset + older.catalogCSize == prev, older.catalogCSize <= Int64(Xiz.maxCatalog) else {
                throw XipperError.corrupt("XIZ segment chain")
            }
            let od = try XizDirectory.decode(try reader.read(at: older.catalogOffset, count: Int(older.catalogCSize)))
            let start = od.groups.map(\.offset).min()!
            guard start >= dataStart, start <= older.catalogOffset else { throw XipperError.corrupt("XIZ segment chain") }
            gaps[start] = prev + Int64(Xiz.footerSize)
            bound = start
            prev = Int64(bitPattern: older.previousFooter)
            segment += 1
        }

        // Group catalogs: contiguous, right before the directory; those held are opened.
        var next = directory.groups[0].offset
        let catalogsStart = next
        var frames: [Xiz.Frame]?
        var entries: [Xiz.Entry] = []
        var info: [UInt16: (name: String, prefixes: [String])] = [:]
        var hidden = 0
        for g in directory.groups {
            guard g.offset == next, g.csize > 0, g.usize > 0, g.usize <= Int64(Xiz.maxCatalog), g.segment == segment else {
                throw XipperError.corrupt("XIZ group catalogs out of place")
            }
            next = g.offset + g.csize
            let k = groupKeys[g.group]
            if sb.required.contains(.encrypted) && k == nil { hidden += 1; continue }
            var packed = try reader.read(at: g.offset, count: Int(g.csize))
            guard Xiz.sha256(packed) == g.sha256 else { throw XipperError.corrupt("XIZ group catalog hash mismatch") }
            if let k {
                let aad = XizKeys.groupCatalogAAD(archiveID: sb.archiveID, group: g.group, segment: g.segment, usize: g.usize,
                                                  frameCount: footer.frameCount)
                packed = try k.openCatalog(packed, aad: aad, segment: g.segment)
            }
            let raw = try packed.withUnsafeBytes { try Xiz.zstdDecompress($0, size: Int(g.usize)) }
            var c = try Xiz.decodeCatalog(raw)
            guard let gi = c.group, c.frames.count == Int(footer.frameCount) else { throw XipperError.corrupt("XIZ group catalog") }
            if let frames, frames != c.frames { throw XipperError.corrupt("XIZ group catalogs disagree on the frames") }
            frames = c.frames
            info[g.group] = gi
            for i in c.entries.indices { c.entries[i].group = g.group }
            entries += c.entries
        }
        guard next == footer.catalogOffset else { throw XipperError.corrupt("XIZ group catalogs do not reach the directory") }
        // A reader holding no group catalog still knows the frame table from the footer only by count.
        let c = Xiz.Catalog(frames: frames ?? [], entries: entries)
        if frames != nil {
            let overhead = UInt32(sb.required.contains(.encrypted) ? Xiz.tagSize : 0)
            var at = dataStart
            func skipGaps() { while let end = gaps[at] { at = end } }
            for f in c.frames {
                skipGaps()
                guard f.offset == at, f.usize <= UInt32(Xiz.maxFrameData), f.csize <= UInt32(Xiz.maxFrameData) + 4096,
                      f.codec != .store || f.csize == f.usize + overhead, f.csize >= overhead, f.flags == 0, f.dictionary == 0,
                      directory.groups.contains(where: { $0.group == f.group }) else {
                    throw XipperError.corrupt("XIZ frames overlap or leave gaps (possible bomb)")
                }
                at = f.offset + Int64(Xiz.frameHeaderSize) + Int64(f.csize)
            }
            skipGaps()
            guard at == catalogsStart else { throw XipperError.corrupt("XIZ frames overlap the catalogs") }
        }
        var total: UInt64 = 0
        for e in c.entries {
            var sum: UInt64 = 0
            for x in e.extents {
                guard Int(x.frame) < c.frames.count, c.frames[Int(x.frame)].group == e.group,
                      UInt64(x.offset) + UInt64(x.length) <= UInt64(c.frames[Int(x.frame)].usize) else {
                    throw XipperError.corrupt("XIZ extent outside its frame or its group: \(e.path)")
                }
                sum += UInt64(x.length)
            }
            guard e.type == .file ? sum == e.size : (e.extents.isEmpty && e.size == 0) else {
                throw XipperError.corrupt("XIZ entry size does not match its data: \(e.path)")
            }
            total += e.size
        }
        if hidden == 0 {
            guard total == footer.totalBytes, c.entries.count == Int(footer.entryCount) else { throw XipperError.corrupt("XIZ declared size mismatch") }
        } else {
            guard total <= footer.totalBytes, c.entries.count <= Int(footer.entryCount) else { throw XipperError.corrupt("XIZ declared size mismatch") }
        }
        return Loaded(catalog: c, footer: footer, groupKeys: groupKeys, segments: Int(segment) + 1, hidden: hidden, info: info,
                      directory: directory)
    }

    /// The last valid footer: normally the file's last 96 bytes; after an interrupted append, the
    /// one before the incomplete segment (searched backwards, its catalog location must fit).
    static func lastFooter(_ reader: FileReader, dataStart: Int64) throws -> (Int64, Xiz.Footer) {
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

    /// The keys that open frame `index` (its group's), nil when not encrypted or not held.
    func frameKeys(_ index: Int) -> XizKeys? {
        directory == nil ? keys : groupKeys[catalog.frames[index].group]
    }

    /// The keys of an entry's group (its digest is keyed with them).
    func entryKeys(_ e: Xiz.Entry) -> XizKeys? { directory == nil ? keys : groupKeys[e.group] }

    /// Frames this reader can decode (all, unless groups are hidden from it).
    func canOpen(frame index: Int) -> Bool { !superblock.required.contains(.encrypted) || frameKeys(index) != nil }

    /// The digest stored for file content: SHA-256, or HMAC-SHA-256 under the entry's group key.
    func digest(_ chunks: [UnsafeRawBufferPointer], for e: Xiz.Entry) -> [UInt8] {
        if let keys = entryKeys(e) {
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
        if let k = frameKeys(index) { payload = try k.openFrame(payload, index: UInt32(index), f) }
        else if superblock.required.contains(.encrypted) { throw XipperError.passwordRequired(entry: "frame \(index)") }
        switch f.codec {
        case .store:
            guard payload.count == Int(f.usize) else { throw XipperError.corrupt("XIZ frame \(index) size") }
            return payload
        case .zstd:
            let dict = f.dictionary != 0 && f.flags & Xiz.dictionaryFrame == 0 ? try ddict(f.dictionary) : nil
            return try payload.withUnsafeBytes { try Xiz.zstdDecompress($0, size: Int(f.usize), dictionary: dict) }
        }
    }

    /// A dictionary ready for decoding, built once (ZSTD_DDict is read-only, shared by threads).
    private func ddict(_ id: UInt16) throws -> OpaquePointer {
        if let d = ddictLock.withLock({ ddicts[id] }) { return d }
        guard let index = dictionaries[id] else { throw XipperError.corrupt("XIZ dictionary \(id) missing") }
        let d = try XizDictionary.ddict(try frameData(index), id: id)
        return ddictLock.withLock {
            if let existing = ddicts[id] { ZSTD_freeDDict(d); return existing }
            ddicts[id] = d
            return d
        }
    }

    /// The dictionary an append reuses: ID and content.
    func dictionary() throws -> (UInt16, [UInt8])? {
        guard let (id, index) = dictionaries.min(by: { $0.key < $1.key }) else { return nil }
        return (id, try frameData(index))
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
            if let h = e.sha256, data.withUnsafeBytes({ a.digest([$0], for: e) }) != h {
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
        var digest = XizContentDigest(keys: a.entryKeys(e))
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
                guard a.canOpen(frame: i) else { return }  // a group this reader cannot open
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
