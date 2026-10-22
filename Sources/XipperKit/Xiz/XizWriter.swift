import CryptoKit
import Foundation
import Synchronization

/// Writes XIZ 1.0 (docs/XIZ_SPEC.md):
/// 1. every file is hashed in parallel; files of 8 MiB or more are also cut into content-defined
///    chunks (FastCDC: 16 KiB min, 64 KiB average, 256 KiB max);
/// 2. identical files and chunks seen before point at the first copy, everything else is packed
///    into frames of 4 MiB (small files share frames, big ones are split);
/// 3. frames are compressed (and encrypted) in parallel windows and written in order.
/// With a password, a random file key is wrapped by Argon2id and every frame, the catalog and the
/// digests are keyed by it; the chunker's gear table is derived from it too, so chunk boundaries
/// reveal nothing about the content.
enum XizWriter {
    /// Files from this size on are deduplicated chunk by chunk, not only as a whole.
    static let chunkedFrom: Int64 = 8 << 20
    /// Big files are chunked in regions of this size, in parallel.
    static let regionSize: Int64 = 32 << 20

    /// One piece of a source file inside a frame.
    private struct Segment {
        var item: Int
        var fileOffset: Int64
        var length: Int
    }

    private struct Hashed {
        var digest: [UInt8]
        /// Content-defined chunks of a big file: offset, length, digest.
        var chunks: [(Int64, Int, [UInt8])] = []
    }

    static func write(items: [ArchiveItem], to path: String, level: Int, password: String?, kdf: XizKeys.KDF = .standard,
                      extendedAttributes: Bool, dictionaryThreshold: Int64 = XizDictionary.minimumSmallBytes,
                      workload: Workload, overwrite: Bool, progress: ProgressHandler?, cancel: CancellationToken?) throws -> WriteReport {
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        let tracker = ProgressTracker(totalBytes: total, totalEntries: items.count, handler: progress)
        var archiveID = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&archiveID, 16)

        // The dictionary is decided before the superblock, which declares it (1.2).
        var superblock = Xiz.Superblock(archiveID: archiveID)
        let dictionary = level >= XizDictionary.minimumLevel ? try trainDictionary(items, threshold: dictionaryThreshold, cancel: cancel) : nil
        if dictionary != nil {
            superblock.required.insert(.dictionaries)
            superblock.minor = 2
        }

        // Keys first: the digests and the chunker depend on them.
        var keysBlock: [UInt8] = []
        var keys: XizKeys?
        if let password {
            let fileKey = SymmetricKey(size: .bits256)
            superblock.required.insert(.encrypted)
            superblock.keysLength = UInt32(XizKeys.keysBlockSize)
            keysBlock = try XizKeys.keysBlock(password: password, fileKey: fileKey, superblock: superblock.encode(), kdf: kdf)
            precondition(keysBlock.count == XizKeys.keysBlockSize)
            keys = XizKeys(fileKey: fileKey, archiveID: archiveID)
        }
        if !overwrite && FileManager.default.fileExists(atPath: path) { throw XipperError.alreadyExists(path: path) }
        let out = try OutputFile(path: path)
        try out.write(superblock.encode())
        if !keysBlock.isEmpty { try keysBlock.withUnsafeBytes { try out.write($0) } }
        let (frames, entries) = try writeData(items, to: out, startFrame: 0, known: [:], keys: keys, level: level,
                                              dictionary: dictionary.map { (XizDictionary.id, $0, true) },
                                              extendedAttributes: extendedAttributes, workload: workload, tracker: tracker, cancel: cancel)
        try writeCatalog(Xiz.Catalog(frames: frames, entries: entries), to: out, keys: keys, segment: 0, previousFooter: 0)
        let size = out.position
        try out.commit(overwrite: overwrite)
        tracker.add(bytes: total - tracker.completedBytes, entries: items.count)  // deduplicated bytes count as done
        tracker.finish()
        return WriteReport(entries: items.count, inputBytes: total, outputBytes: size, elapsed: tracker.elapsed)
    }

    /// A dictionary for the small files, when there are enough of them to pay for it: trained on
    /// up to 100× its size of whole files, taken evenly across the archive.
    static func trainDictionary(_ items: [ArchiveItem], threshold: Int64, cancel: CancellationToken?) throws -> [UInt8]? {
        let small = items.filter {
            if case let .file(size) = $0.kind { size > 0 && size < XizDictionary.smallFile && !AlreadyCompressed.matches($0.name) } else { false }
        }
        let total = small.reduce(Int64(0)) { $0 + $1.size }
        guard total >= threshold, !small.isEmpty else { return nil }
        let budget = Int64(XizDictionary.capacity * 100)
        let stride = max(1, Int((total + budget - 1) / budget))
        var samples: [[UInt8]] = []
        for k in Swift.stride(from: 0, to: small.count, by: stride) {
            try cancel?.check()
            if let r = try? FileReader(path: small[k].sourcePath), let b = try? r.read(at: 0, count: Int(r.size)) { samples.append(b) }
        }
        return XizDictionary.train(samples)
    }

    /// Indexes of the items in the order their data is stored: extension, file name, size, path.
    static func similarityOrder(_ items: [ArchiveItem]) -> [Int] {
        let keys = items.map { item -> (String, String, Int64, String) in
            let name = (item.name as NSString).lastPathComponent
            return ((name as NSString).pathExtension.lowercased(), name, item.size, item.name)
        }
        return items.indices.sorted { keys[$0] < keys[$1] }
    }

    /// The chunker's gear table: derived from the archive key when encrypted.
    static func gear(_ keys: XizKeys?) -> [UInt64] {
        FastCDC.gearTable(seed: keys.map { k in
            k.fileMAC.withUnsafeBytes { Array(HMAC<SHA256>.authenticationCode(for: Data("xiz/1/chunker".utf8), using: SymmetricKey(data: $0))) }
        })
    }

    /// Writes the frames holding `items` (deduplicated against themselves and against `known`
    /// content: digest → extents already in the archive) and returns them with the items' entries.
    /// `dictionary`: used by frames made mostly of small files; written first when new (1.2).
    static func writeData(_ items: [ArchiveItem], to out: XizOutput, startFrame: Int, known: [[UInt8]: [Xiz.Extent]], keys: XizKeys?,
                          level: Int, dictionary: (id: UInt16, bytes: [UInt8], isNew: Bool)? = nil,
                          extendedAttributes: Bool, workload: Workload, tracker: ProgressTracker,
                          cancel: CancellationToken?) throws -> ([Xiz.Frame], [Xiz.Entry]) {
        let gear = gear(keys)
        func newDigest() -> Digest { keys.map { .keyed($0.fileDigest()) } ?? .plain(SHA256()) }

        // 1. Hash every file and chunk the big ones, in parallel: a big file is one task for its
        //    whole-file digest (sequential by nature) plus one task per 32 MiB region for its
        //    chunks, so a single large file keeps every core busy. Regions start a new chunk
        //    (fixed offsets: shifted data still deduplicates, except right at the borders).
        enum Work { case whole(Int), region(Int, Int64, Int64) }
        let files = items.indices.filter { if case .file = items[$0].kind { items[$0].size > 0 } else { false } }
        var work: [Work] = []
        for i in files {
            work.append(.whole(i))
            let size = items[i].size
            if size >= chunkedFrom {
                var start: Int64 = 0
                while start < size {
                    work.append(.region(i, start, min(size, start + regionSize)))
                    start += regionSize
                }
            }
        }
        // Largest tasks first: whole-file digests of big files start right away.
        func cost(_ w: Work) -> Int64 {
            switch w {
            case let .whole(i): items[i].size
            case let .region(_, a, b): b - a
            }
        }
        work.sort { cost($0) > cost($1) }
        let wholes = Mutex<[Int: [UInt8]]>([:])
        let regions = Mutex<[Int: [Int64: [(Int64, Int, [UInt8])]]]>([:])
        try parallelFor(work.count, workload: workload, cancel: cancel) { k in
            let buf = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16384)
            defer { buf.deallocate() }
            switch work[k] {
            case let .whole(i):
                let r = try FileReader(path: items[i].sourcePath)
                var whole = newDigest()
                var off: Int64 = 0
                while off < r.size {
                    try cancel?.check()
                    let n = try r.readSome(at: off, into: buf, count: 1 << 20)
                    if n == 0 { break }
                    whole.update(UnsafeRawBufferPointer(start: buf, count: n))
                    off += Int64(n)
                }
                let d = whole.finish()
                wholes.withLock { $0[i] = d }
            case let .region(i, from, to):
                let r = try FileReader(path: items[i].sourcePath)
                let chunker = FastCDC(gear: gear)
                var chunks: [(Int64, Int, [UInt8])] = []
                var chunkStart = from
                var chunkDigest = newDigest()
                var off = from
                while off < to {
                    try cancel?.check()
                    let n = try r.readSome(at: off, into: buf, count: Int(min(Int64(1 << 20), to - off)))
                    if n == 0 { break }
                    let block = UnsafeRawBufferPointer(start: buf, count: n)
                    var p = 0
                    while p < n {
                        let (used, cut) = chunker.feed(UnsafeRawBufferPointer(rebasing: block[p...]))
                        chunkDigest.update(UnsafeRawBufferPointer(rebasing: block[p..<(p + used)]))
                        p += used
                        if cut {
                            let end = off + Int64(p)
                            chunks.append((chunkStart, Int(end - chunkStart), chunkDigest.finish()))
                            chunkStart = end
                            chunkDigest = newDigest()
                        }
                    }
                    off += Int64(n)
                }
                if chunkStart < off { chunks.append((chunkStart, Int(off - chunkStart), chunkDigest.finish())) }
                regions.withLock { $0[i, default: [:]][from] = chunks }
            }
        }
        let allWholes = wholes.withLock { $0 }
        let allRegions = regions.withLock { $0 }
        var hashedFiles: [Int: Hashed] = [:]
        for i in files {
            guard let d = allWholes[i] else { continue }
            let chunks = (allRegions[i] ?? [:]).sorted { $0.key < $1.key }.flatMap(\.value)
            hashedFiles[i] = Hashed(digest: d, chunks: chunks)
        }
        let digests = hashedFiles

        // 2. Plan: frames of segments, entries with extents; repeated files and chunks point at the first copy.
        //    A new dictionary takes the first frame index.
        let base = startFrame + (dictionary?.isNew == true ? 1 : 0)
        var frames: [[Segment]] = []
        var current: [Segment] = []
        var currentSize = 0
        var entries: [Xiz.Entry] = []
        var seenFiles = known
        var seenChunks: [[UInt8]: [Xiz.Extent]] = [:]
        func closeFrame() {
            if !current.isEmpty { frames.append(current); current = []; currentSize = 0 }
        }
        /// Places `length` bytes of item `i` from `offset` into frames; returns their extents.
        func place(_ i: Int, from offset: Int64, length: Int64) -> [Xiz.Extent] {
            var extents: [Xiz.Extent] = []
            var off = offset
            let end = offset + length
            while off < end {
                if currentSize == Xiz.frameData { closeFrame() }
                let n = Int(min(Int64(Xiz.frameData - currentSize), end - off))
                extents.append(Xiz.Extent(frame: UInt32(base + frames.count), offset: UInt32(currentSize), length: UInt32(n)))
                current.append(Segment(item: i, fileOffset: off, length: n))
                currentSize += n
                off += Int64(n)
            }
            return extents
        }
        // Data goes into frames sorted by type (extension, name, size, path), as 7-Zip's "sort by
        // type": similar files end up next to each other in the same frame. On 20,000 source
        // files this makes the archive 16% smaller at zstd 3 (docs/BENCHMARK.md). Only the order
        // of the data changes; the catalog keeps the entries in their own order.
        var placed: [Int: [Xiz.Extent]] = [:]
        for i in Self.similarityOrder(items) {
            guard case let .file(size) = items[i].kind, let h = digests[i] else { continue }
            var extents: [Xiz.Extent] = []
            if let copy = seenFiles[h.digest] {
                extents = copy  // identical content stored once
            } else if h.chunks.isEmpty {
                extents = place(i, from: 0, length: size)
            } else {
                for (off, len, d) in h.chunks {
                    if let copy = seenChunks[d] {
                        extents += copy
                    } else {
                        let p = place(i, from: off, length: Int64(len))
                        seenChunks[d] = p
                        extents += p
                    }
                }
                extents = Self.merged(extents)
            }
            seenFiles[h.digest] = extents
            placed[i] = extents
        }
        for (i, item) in items.enumerated() {
            let t = item.modified.timeIntervalSince1970
            let sec = Int64(t.rounded(.down))
            var e = Xiz.Entry(type: .file, path: item.name, mode: item.permissions, uid: item.uid, gid: item.gid,
                              mtimeSec: sec, mtimeNsec: UInt32(clamping: Int64((t - Double(sec)) * 1e9)), size: 0, link: "",
                              xattrs: [], extents: [], sha256: nil)
            switch item.kind {
            case .directory:
                e.type = .directory
            case let .symlink(target):
                e.type = .symlink
                e.link = target
            case let .file(size):
                e.size = UInt64(size)
                e.sha256 = digests[i]?.digest  // nil: empty file
                e.extents = placed[i] ?? []
            }
            if extendedAttributes, e.type != .symlink { e.xattrs = ExtendedAttributes.read(item.sourcePath) }
            entries.append(e)
        }
        closeFrame()

        // 3. Frames, compressed (and sealed) in parallel windows and written in order, numbered from `startFrame`.
        var written: [Xiz.Frame] = []
        let contexts = ZstdContextPool()
        if let dictionary, dictionary.isNew {
            var payload = dictionary.bytes
            var f = Xiz.Frame(offset: 0, csize: 0, usize: UInt32(payload.count), crc: 0, codec: .store,
                              flags: Xiz.dictionaryFrame, dictionary: dictionary.id)
            if let c = payload.withUnsafeBytes({ ZipWriter.zstdCompress($0, level: 19) }) { payload = c; f.codec = .zstd }
            if let keys { payload = try keys.sealFrame(payload, index: UInt32(startFrame), f) }
            f.csize = UInt32(payload.count)
            f.crc = Xiz.crc32c(payload)
            f.offset = out.position
            try out.write(Xiz.frameHeader(index: UInt32(startFrame), f))
            try payload.withUnsafeBytes { try out.write($0) }
            written.append(f)
        }
        let window = max(2, workload.workerCount * 2)
        var start = 0
        while start < frames.count {
            try cancel?.check()
            let end = min(frames.count, start + window)
            let results = Mutex<[Int: (Xiz.Frame, [UInt8])]>([:])
            try parallelFor(end - start, workload: workload, cancel: cancel) { k in
                let idx = start + k
                let global = base + idx
                var data = [UInt8]()
                data.reserveCapacity(frames[idx].reduce(0) { $0 + $1.length })
                for s in frames[idx] {
                    let r = try FileReader(path: items[s.item].sourcePath)
                    if r.size != items[s.item].size {
                        throw XipperError.io("read (file changed while archiving)", path: items[s.item].sourcePath, errno: EAGAIN)
                    }
                    data.append(contentsOf: try r.read(at: s.fileOffset, count: s.length))
                }
                var codec = Xiz.Codec.store
                var payload = data
                var dictID: UInt16 = 0
                let small = frames[idx].reduce(0) { $0 + (items[$1.item].size < XizDictionary.smallFile ? $1.length : 0) }
                if level > 0, let dictionary, small * 2 >= data.count,
                   let c = data.withUnsafeBytes({ Xiz.zstdCompress($0, level: level, dictionary: dictionary.bytes, pool: contexts) }) {
                    codec = .zstd
                    payload = c
                    dictID = dictionary.id
                } else if level > 0, let c = data.withUnsafeBytes({ ZipWriter.zstdCompress($0, level: level, pool: contexts) }) {
                    codec = .zstd
                    payload = c
                }
                var f = Xiz.Frame(offset: 0, csize: 0, usize: UInt32(data.count), crc: 0, codec: codec, dictionary: dictID)
                if let keys { payload = try keys.sealFrame(payload, index: UInt32(global), f) }
                f.csize = UInt32(payload.count)
                f.crc = Xiz.crc32c(payload)
                results.withLock { $0[idx] = (f, payload) }
                tracker.add(bytes: Int64(frames[idx].reduce(0) { $0 + $1.length }))
            }
            let done = results.withLock { $0 }
            for idx in start..<end {
                guard var (f, payload) = done[idx] else { throw XipperError.codec("missing XIZ frame") }
                f.offset = out.position
                try out.write(Xiz.frameHeader(index: UInt32(base + idx), f))
                try payload.withUnsafeBytes { try out.write($0) }
                written.append(f)
            }
            start = end
        }

        return (written, entries)
    }

    /// The catalog (zstd, then sealed with the segment's nonces) and the footer.
    static func writeCatalog(_ catalog: Xiz.Catalog, to out: XizOutput, keys: XizKeys?, segment: UInt32, previousFooter: UInt64) throws {
        let raw = Xiz.encodeCatalog(catalog)
        var packed = raw.withUnsafeBytes { ZipWriter.zstdCompress($0, level: 9, allowExpansion: true) } ?? raw
        var footer = Xiz.Footer(catalogOffset: out.position, catalogCSize: 0, catalogUSize: Int64(raw.count),
                                frameCount: UInt32(catalog.frames.count), entryCount: UInt32(catalog.entries.count),
                                totalBytes: UInt64(catalog.entries.reduce(UInt64(0)) { $0 + $1.size }), catalogSHA256: [])
        footer.previousFooter = previousFooter
        if previousFooter != 0 { footer.minor = 1 }  // appended segments: XIZ 1.1
        if let keys { packed = try keys.sealCatalog(packed, footer: footer, segment: segment) }
        footer.catalogCSize = Int64(packed.count)
        footer.catalogSHA256 = Xiz.sha256(packed)
        try packed.withUnsafeBytes { try out.write($0) }
        try out.write(footer.encode())
    }

    /// Joins extents that continue each other in the same frame.
    static func merged(_ extents: [Xiz.Extent]) -> [Xiz.Extent] {
        var out: [Xiz.Extent] = []
        out.reserveCapacity(extents.count)
        for x in extents {
            if let last = out.last, last.frame == x.frame, last.offset + last.length == x.offset {
                out[out.count - 1].length += x.length
            } else {
                out.append(x)
            }
        }
        return out
    }

    /// SHA-256, or HMAC-SHA-256 under the archive's key when encrypted.
    private enum Digest {
        case plain(SHA256)
        case keyed(HMAC<SHA256>)

        mutating func update(_ b: UnsafeRawBufferPointer) {
            switch self {
            case var .plain(h): h.update(bufferPointer: b); self = .plain(h)
            case var .keyed(h): h.update(data: b); self = .keyed(h)
            }
        }

        func finish() -> [UInt8] {
            switch self {
            case let .plain(h): Array(h.finalize())
            case let .keyed(h): Array(h.finalize())
            }
        }
    }
}

/// FastCDC content-defined chunking (Xia et al., USENIX ATC 2016 / ToS 2020) with normalized
/// chunking: a stricter mask before the average size, a looser one after it.
final class FastCDC {
    static let minSize = 16 << 10, averageSize = 64 << 10, maxSize = 256 << 10
    // Masks on the high bits of the gear hash (they depend on the last 64 bytes): 18 bits before
    // the average (harder to cut), 14 after (easier).
    private static let maskSmall: UInt64 = 0xFFFF_C000_0000_0000
    private static let maskLarge: UInt64 = 0xFFFC_0000_0000_0000

    private let gear: [UInt64]
    private var hash: UInt64 = 0
    private var length = 0

    init(gear: [UInt64]) { self.gear = gear }

    /// The gear table: fixed for plain archives, derived from the archive key when encrypted.
    static func gearTable(seed: [UInt8]?) -> [UInt64] {
        var state: UInt64 = 0x5849_5A31_4344_4321  // "XIZ1CDC!"
        if let seed { for (i, b) in seed.enumerated() { state ^= UInt64(b) << UInt64((i % 8) * 8); state = state &* 0x9E37_79B9_7F4A_7C15 } }
        return (0..<256).map { _ in  // SplitMix64
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Consumes bytes until a chunk boundary or the end of `bytes`: (bytes used, boundary found).
    /// The gear hash only depends on the last 64 bytes, so the first `minSize − 64` bytes of a
    /// chunk are skipped without hashing: same boundaries, a quarter less work.
    func feed(_ bytes: UnsafeRawBufferPointer) -> (Int, Bool) {
        let n = bytes.count
        var i = 0
        let skipTo = Self.minSize - 64
        if length < skipTo {
            let skip = min(n, skipTo - length)
            length += skip
            i = skip
            hash = 0
        }
        guard i < n, let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return (i, false) }
        return gear.withUnsafeBufferPointer { g in
            var h = hash, len = length
            while i < n {
                h = (h << 1) &+ g[Int(base[i])]
                len += 1
                i += 1
                let mask = len < Self.averageSize ? Self.maskSmall : Self.maskLarge
                if len >= Self.minSize && (h & mask == 0 || len >= Self.maxSize) {
                    hash = 0
                    length = 0
                    return (i, true)
                }
            }
            hash = h
            length = len
            return (i, false)
        }
    }
}

/// Where XIZ data goes: a new file (OutputFile) or the end of an existing archive (append).
protocol XizOutput: AnyObject {
    var position: Int64 { get }
    func write(_ src: UnsafeRawBufferPointer) throws
    func write(_ bytes: [UInt8]) throws
}

extension OutputFile: XizOutput {}
