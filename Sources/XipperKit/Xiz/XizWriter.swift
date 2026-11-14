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
/// A file whose zstd frame comes from elsewhere («Cambia formato»: a ZIP zstd entry of at most
/// 64 MiB) and becomes one XIZ frame as it is. Not encrypted, not deduplicated.
struct XizCarriedFrame {
    var item: ArchiveItem
    /// One zstd frame that decompresses to exactly `item.size` bytes.
    var payload: [UInt8]
    /// SHA-256 of the content (the caller decoded it once).
    var sha256: [UInt8]
}

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

    static func write(items: [ArchiveItem], to path: String, level: Int, lzma2: Bool = false, appleCodec: Xiz.Codec? = nil, jpeg: Bool = false,
                      deflate: Bool = false, tables: Bool = false, models: Bool = false, password: String?, kdf: XizKeys.KDF = .standard,
                      extendedAttributes: Bool, dictionaryThreshold: Int64 = XizDictionary.minimumSmallBytes,
                      access: XizAccess? = nil, signer: XizSigner? = nil, carried: [XizCarriedFrame] = [],
                      declareRecompression: Bool = false,
                      workload: Workload, overwrite: Bool, progress: ProgressHandler?, cancel: CancellationToken?) throws -> WriteReport {
        guard carried.isEmpty || (password == nil && access == nil && signer == nil) else {
            throw XipperError.invalidArgument("copied zstd frames go only into plain XIZ archives")
        }
        if access != nil || signer != nil {
            return try writeWithDirectory(items: items, to: path, level: level, lzma2: lzma2, appleCodec: appleCodec, jpeg: jpeg, deflate: deflate, tables: tables, models: models, password: password, kdf: kdf,
                                          extendedAttributes: extendedAttributes, access: access, signer: signer,
                                          workload: workload, overwrite: overwrite, progress: progress, cancel: cancel)
        }
        let total = (items + carried.map(\.item)).reduce(Int64(0)) { $0 + $1.size }
        let tracker = ProgressTracker(totalBytes: total, totalEntries: items.count + carried.count, handler: progress)
        var archiveID = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&archiveID, 16)

        // The dictionary is decided before the superblock, which declares it (1.2).
        var superblock = Xiz.Superblock(archiveID: archiveID)
        // LZMA2 and Apple frames take no zstd dictionary; the codec is declared there too (1.4, 1.8).
        let appleCodec = level > 0 ? appleCodec : nil
        if appleCodec != nil && !Xiz.hasAppleCodecs { throw XipperError.unsupported("LZRAVEN and LZMESH need macOS 27 or later") }
        let lzma2 = lzma2 && level > 0 && appleCodec == nil
        let dictionary = !lzma2 && appleCodec == nil && level >= XizDictionary.minimumLevel
            ? try trainDictionary(items, threshold: dictionaryThreshold, cancel: cancel) : nil
        if dictionary != nil {
            superblock.required.insert(.dictionaries)
            superblock.minor = 2
        }
        if lzma2 {
            superblock.required.insert(.lzma2)
            superblock.minor = 4
        }
        let jpeg = jpeg && level > 0 && (declareRecompression || items.contains(where: Self.isJPEG))
        if jpeg {
            superblock.required.insert(.jpeg)
            superblock.minor = 6
        }
        if appleCodec != nil {
            superblock.required.insert(.apple)
            superblock.minor = 8
        }
        let deflate = deflate && level > 0 && (declareRecompression || items.contains(where: Self.isDeflateDocument))
        if deflate {
            superblock.required.insert(.deflate)
            superblock.minor = 9
        }
        let tables = tables && level > 0 && (declareRecompression || items.contains(where: Self.isTable))
        let models = models && level > 0 && (declareRecompression || items.contains(where: Self.isModel))
        if tables || models {
            superblock.required.insert(.tables)
            superblock.minor = 11
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
        let (frames, entries) = try writeData(items, to: out, startFrame: 0, known: [:], keys: keys, level: level, lzma2: lzma2, appleCodec: appleCodec, jpeg: jpeg, deflate: deflate, tables: tables, models: models,
                                              dictionary: dictionary.map { (XizDictionary.id, $0, true) }, carried: carried,
                                              extendedAttributes: extendedAttributes, workload: workload, tracker: tracker, cancel: cancel)
        try writeCatalog(Xiz.Catalog(frames: frames, entries: entries), to: out, keys: keys, segment: 0, previousFooter: 0)
        let size = out.position
        try out.commit(overwrite: overwrite)
        tracker.add(bytes: total - tracker.completedBytes, entries: items.count + carried.count)  // deduplicated bytes count as done
        tracker.finish()
        return WriteReport(entries: items.count + carried.count, inputBytes: total, outputBytes: size, elapsed: tracker.elapsed)
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

    /// A file whose Deflate streams preflate splits when the archive allows it (1.9).
    static func isDeflateDocument(_ item: ArchiveItem) -> Bool {
        guard case let .file(size) = item.kind else { return false }
        return DeflateRecompression.isCandidate(name: item.name, path: item.sourcePath, size: size)
    }

    /// A delimited table compressed with OpenZL when the archive allows it (1.11).
    static func isTable(_ item: ArchiveItem) -> Bool {
        guard case let .file(size) = item.kind else { return false }
        return TableRecompression.isCandidate(name: item.name, path: item.sourcePath, size: size)
    }

    /// AI model weights compressed with OpenZL when the archive allows it (1.11).
    static func isModel(_ item: ArchiveItem) -> Bool {
        guard case let .file(size) = item.kind else { return false }
        return ModelRecompression.isCandidate(name: item.name, path: item.sourcePath, size: size)
    }

    /// A file recompressed with brunsli when the archive allows it (1.6).
    static func isJPEG(_ item: ArchiveItem) -> Bool {
        guard case let .file(size) = item.kind else { return false }
        return JPEGRecompression.isCandidate(name: item.name, path: item.sourcePath, size: size)
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
                          group: UInt16 = 0, proofs: Bool = false, level: Int, lzma2: Bool = false, appleCodec: Xiz.Codec? = nil, jpeg: Bool = false, deflate: Bool = false, tables: Bool = false, models: Bool = false,
                          dictionary: (id: UInt16, bytes: [UInt8], isNew: Bool)? = nil, carried: [XizCarriedFrame] = [],
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
        // JPEG files (1.6) get a frame each, recompressed whole: deduplicated as whole files only.
        let jpegs = jpeg && level > 0 ? Set(files.filter { Self.isJPEG(items[$0]) }) : []
        // PNG, PDF and Office documents (1.9) likewise, with their Deflate streams split by preflate.
        let documents = deflate && level > 0 ? Set(files.filter { !jpegs.contains($0) && Self.isDeflateDocument(items[$0]) }) : []
        // Delimited tables (1.11): pieces of whole rows, a frame each, deduplicated as whole files only.
        var tableSeparators: [Int: UInt8] = [:]
        if tables && level > 0 {
            for i in files where !jpegs.contains(i) && !documents.contains(i) {
                if let sep = TableRecompression.separator(name: items[i].name, path: items[i].sourcePath, size: items[i].size) { tableSeparators[i] = sep }
            }
        }
        // AI model weights (1.11, §21): tensors in pieces of whole values, the rest around them.
        var modelPieces: [Int: [ModelRecompression.Piece]] = [:]
        if models && level > 0 {
            for i in files where !jpegs.contains(i) && !documents.contains(i) && tableSeparators[i] == nil {
                if let p = try? ModelRecompression.pieces(name: items[i].name, path: items[i].sourcePath, size: items[i].size),
                   p.contains(where: { !$0.floats.isEmpty }) { modelPieces[i] = p }
            }
        }
        let recompressed = jpegs.union(documents).union(tableSeparators.keys).union(modelPieces.keys)
        var work: [Work] = []
        for i in files {
            work.append(.whole(i))
            let size = items[i].size
            if size >= chunkedFrom && !recompressed.contains(i) {
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
        let plains = Mutex<[Int: [UInt8]]>([:])  // plain SHA-256 for proofs, when the digest is keyed
        let regions = Mutex<[Int: [Int64: [(Int64, Int, [UInt8])]]]>([:])
        try parallelFor(work.count, workload: workload, cancel: cancel) { k in
            let buf = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16384)
            defer { buf.deallocate() }
            switch work[k] {
            case let .whole(i):
                let r = try FileReader(path: items[i].sourcePath)
                var whole = newDigest()
                var plain: SHA256? = proofs && keys != nil ? SHA256() : nil
                var off: Int64 = 0
                while off < r.size {
                    try cancel?.check()
                    let n = try r.readSome(at: off, into: buf, count: 1 << 20)
                    if n == 0 { break }
                    whole.update(UnsafeRawBufferPointer(start: buf, count: n))
                    plain?.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: n))
                    off += Int64(n)
                }
                let d = whole.finish()
                wholes.withLock { $0[i] = d }
                if let plain { let p = Array(plain.finalize()); plains.withLock { $0[i] = p } }
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
        let allPlains = plains.withLock { $0 }
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
        var pendingJPEGs: [Int] = []
        for i in Self.similarityOrder(items) {
            guard case let .file(size) = items[i].kind, let h = digests[i] else { continue }
            var extents: [Xiz.Extent] = []
            if let copy = seenFiles[h.digest] {
                extents = copy  // identical content stored once
            } else if recompressed.contains(i) {
                pendingJPEGs.append(i)  // after the shared frames, which are still being filled
                continue
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
        closeFrame()
        var jpegFrames: [Int: Xiz.Codec] = [:]  // frame → .jpeg or .preflate
        var tableFrames: [Int: (separator: UInt8, header: Bool)] = [:]
        var modelFrames: [Int: [ModelRecompression.Float]] = [:]
        for i in pendingJPEGs {
            guard let h = digests[i] else { continue }
            if let copy = seenFiles[h.digest] { placed[i] = copy; continue }
            if let pieces = modelPieces[i] {
                var extents: [Xiz.Extent] = []
                for piece in pieces {
                    frames.append([Segment(item: i, fileOffset: piece.range.lowerBound, length: Int(piece.range.count))])
                    if !piece.floats.isEmpty { modelFrames[frames.count - 1] = piece.floats }
                    extents.append(Xiz.Extent(frame: UInt32(base + frames.count - 1), offset: 0, length: UInt32(piece.range.count)))
                }
                seenFiles[h.digest] = extents
                placed[i] = extents
                continue
            }
            if let sep = tableSeparators[i] {
                var extents: [Xiz.Extent] = []
                for piece in try TableRecompression.pieces(path: items[i].sourcePath, size: items[i].size) {
                    frames.append([Segment(item: i, fileOffset: piece.lowerBound, length: Int(piece.count))])
                    tableFrames[frames.count - 1] = (sep, piece.lowerBound == 0)
                    extents.append(Xiz.Extent(frame: UInt32(base + frames.count - 1), offset: 0, length: UInt32(piece.count)))
                }
                seenFiles[h.digest] = extents
                placed[i] = extents
                continue
            }
            frames.append([Segment(item: i, fileOffset: 0, length: Int(items[i].size))])
            jpegFrames[frames.count - 1] = jpegs.contains(i) ? .jpeg : .preflate
            let extents = [Xiz.Extent(frame: UInt32(base + frames.count - 1), offset: 0, length: UInt32(items[i].size))]
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
                if proofs { e.proof = (XizLeaf.randomSalt(), size == 0 ? Xiz.sha256([]) : (allPlains[i] ?? digests[i]?.digest ?? Xiz.sha256([]))) }
            }
            if extendedAttributes, e.type != .symlink { e.xattrs = ExtendedAttributes.read(item.sourcePath) }
            entries.append(e)
        }
        closeFrame()

        // 3. Frames, compressed (and sealed) in parallel windows and written in order, numbered from `startFrame`.
        // LZMA2 (1.4): frames that are mostly arm64 executables go through the ARM64 branch filter.
        let executables = lzma2 && level > 0 ? Set(items.indices.filter { i in
            guard case .file = items[i].kind, SevenZipWriter.mayBeExecutable(items[i]) else { return false }
            return SevenZipWriter.isARM64Executable(items[i].sourcePath)
        }) : []
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
                if let whole = jpegFrames[idx],
                   let p = whole == .jpeg ? JPEGRecompression.encode(data)
                       : DeflateRecompression.encode(data, name: items[frames[idx][0].item].name, level: level, lzma2: lzma2) {
                    codec = whole  // checked: decodes back to `data`
                    payload = p
                } else if level > 0, let appleCodec, let c = data.withUnsafeBytes({ Xiz.appleCompress($0, codec: appleCodec) }) {
                    codec = appleCodec
                    payload = c
                } else if level > 0, lzma2 {
                    let exe = frames[idx].reduce(0) { $0 + (executables.contains($1.item) ? $1.length : 0) }
                    if let c = try data.withUnsafeBytes({ try Xiz.lzma2Compress($0, arm64: exe * 2 >= data.count) }) {
                        codec = exe * 2 >= data.count ? .lzma2ARM64 : .lzma2
                        payload = c
                    }
                } else if level > 0, let dictionary, small * 2 >= data.count,
                   let c = data.withUnsafeBytes({ Xiz.zstdCompress($0, level: level, dictionary: dictionary.bytes, pool: contexts) }) {
                    codec = .zstd
                    payload = c
                    dictID = dictionary.id
                } else if level > 0, let c = data.withUnsafeBytes({ ZipWriter.zstdCompress($0, level: level, pool: contexts) }) {
                    codec = .zstd
                    payload = c
                }
                // A table piece (1.11) in OpenZL when that is smaller than the usual codec.
                if let t = tableFrames[idx],
                   let p = TableRecompression.encode(data, separator: t.separator, header: t.header,
                                                     level: TableRecompression.level(for: level, lzma2: lzma2)),
                   p.count < payload.count {
                    codec = .openzl
                    payload = p
                    dictID = 0
                }
                // A piece of model weights in OpenZL's float graph, likewise.
                if let kinds = modelFrames[idx], let p = ModelRecompression.encode(data, floats: kinds), p.count < payload.count {
                    codec = .openzl
                    payload = p
                    dictID = 0
                }
                var f = Xiz.Frame(offset: 0, csize: 0, usize: UInt32(data.count), crc: 0, codec: codec, dictionary: dictID, group: group)
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

        // 4. Frames copied from elsewhere, one per file, after the others.
        for (k, c) in carried.enumerated() {
            try cancel?.check()
            let index = UInt32(base + frames.count + k)
            var f = Xiz.Frame(offset: out.position, csize: UInt32(c.payload.count), usize: UInt32(c.item.size),
                              crc: Xiz.crc32c(c.payload), codec: .zstd, group: group)
            if c.item.size == 0 || c.payload.count > Xiz.maxFrameData { throw XipperError.invalidArgument("copied XIZ frame size") }
            f.offset = out.position
            try out.write(Xiz.frameHeader(index: index, f))
            try c.payload.withUnsafeBytes { try out.write($0) }
            written.append(f)
            let t = c.item.modified.timeIntervalSince1970
            let sec = Int64(t.rounded(.down))
            entries.append(Xiz.Entry(type: .file, path: c.item.name, mode: c.item.permissions, uid: c.item.uid, gid: c.item.gid,
                                     mtimeSec: sec, mtimeNsec: UInt32(clamping: Int64((t - Double(sec)) * 1e9)), size: UInt64(c.item.size),
                                     link: "", xattrs: [], extents: [Xiz.Extent(frame: index, offset: 0, length: UInt32(c.item.size))],
                                     sha256: c.sha256))
            tracker.add(bytes: c.item.size, entries: 1)
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

    // MARK: 1.3: directory, access groups, signed segments (§13)

    /// An archive with a directory: each access group's data is written as if it were an archive of
    /// its own (frames sealed with the group's key, deduplication inside the group), then one
    /// catalog per group, the directory (signed when there is a signer) and the footer.
    static func writeWithDirectory(items: [ArchiveItem], to path: String, level: Int, lzma2: Bool, appleCodec: Xiz.Codec? = nil, jpeg: Bool = false,
                                   deflate: Bool = false, tables: Bool = false, models: Bool = false, password: String?, kdf: XizKeys.KDF,
                                   extendedAttributes: Bool, access: XizAccess?, signer: XizSigner?,
                                   workload: Workload, overwrite: Bool, progress: ProgressHandler?, cancel: CancellationToken?) throws -> WriteReport {
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        let tracker = ProgressTracker(totalBytes: total, totalEntries: items.count, handler: progress)
        var archiveID = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&archiveID, 16)
        var superblock = Xiz.Superblock(archiveID: archiveID)
        superblock.required.insert(.directory)
        superblock.minor = 3
        let appleCodec = level > 0 ? appleCodec : nil
        if appleCodec != nil && !Xiz.hasAppleCodecs { throw XipperError.unsupported("LZRAVEN and LZMESH need macOS 27 or later") }
        let lzma2 = lzma2 && level > 0 && appleCodec == nil
        if lzma2 {
            superblock.required.insert(.lzma2)
            superblock.minor = 4
        }
        let jpeg = jpeg && level > 0 && items.contains(where: Self.isJPEG)
        if jpeg {
            superblock.required.insert(.jpeg)
            superblock.minor = 6
        }
        if appleCodec != nil {
            superblock.required.insert(.apple)
            superblock.minor = 8
        }
        let deflate = deflate && level > 0 && items.contains(where: Self.isDeflateDocument)
        if deflate {
            superblock.required.insert(.deflate)
            superblock.minor = 9
        }
        let tables = tables && level > 0 && items.contains(where: Self.isTable)
        let models = models && level > 0 && items.contains(where: Self.isModel)
        if tables || models {
            superblock.required.insert(.tables)
            superblock.minor = 11
        }
        let map = try XizGroupMap(access)

        // The password of the call, if any, is one more recipient that opens every group.
        var policy = access ?? XizAccess()
        if let password { policy.recipients.insert(XizAccess.Recipient(label: "", credential: .password(password)), at: 0) }
        let encrypted = !policy.recipients.isEmpty || !policy.thresholds.isEmpty
        if XizAccessKeys.hasPostQuantum(policy) { superblock.minor = max(superblock.minor, 7) }  // X-Wing stanzas (§17): no feature bit
        // Hybrid Ed25519 + ML-DSA-65 signatures (§22): no feature bit either.
        if let signer, signer.certificate == nil, signer.key.isPostQuantum { superblock.minor = max(superblock.minor, 12) }
        // Secure Enclave signatures (§23): no feature bit.
        if let signer, signer.certificate == nil, signer.enclave != nil { superblock.minor = max(superblock.minor, 13) }
        guard encrypted || map.groups.count == 1 else {
            throw XipperError.invalidArgument("access groups need recipients (a password or a public key)")
        }
        var groupKeys: [UInt16: XizKeys] = [:]
        var keysBlock: [UInt8] = []
        if encrypted {
            var raw: [UInt16: SymmetricKey] = [:]
            for g in map.groups {
                raw[g.id] = SymmetricKey(size: .bits256)
                groupKeys[g.id] = XizKeys(fileKey: raw[g.id]!, archiveID: archiveID)
            }
            let stanzas = try XizAccessKeys.prepare(policy, groupIDs: map.ids, groupKeys: raw, archiveID: archiveID, kdf: kdf)
            let size = XizAccessKeys.size(stanzas)
            guard size <= Xiz.maxKeysBlock else { throw XipperError.limitExceeded("too many recipients for one XIZ archive") }
            superblock.required.insert(.encrypted)
            superblock.keysLength = UInt32(size)
            keysBlock = try XizAccessKeys.seal(stanzas, superblock: superblock.encode())
        }
        if !overwrite && FileManager.default.fileExists(atPath: path) { throw XipperError.alreadyExists(path: path) }
        let out = try OutputFile(path: path)
        try out.write(superblock.encode())
        if !keysBlock.isEmpty { try out.write(keysBlock) }

        var byGroup: [UInt16: [ArchiveItem]] = [:]
        for item in items { byGroup[map.group(of: MountedArchive.normalize(item.name) ?? item.name), default: []].append(item) }
        let erasable = access?.erasable ?? false
        guard !erasable || encrypted else { throw XipperError.invalidArgument("erasable files need encryption (a password or recipients)") }
        var frames: [Xiz.Frame] = []
        var entries: [UInt16: [Xiz.Entry]] = [:]
        var slots: [[UInt8]] = []
        for g in map.groups {
            if erasable {
                let (f, e, s) = try writeErasable(byGroup[g.id] ?? [], to: out, startFrame: frames.count, group: groupKeys[g.id]!, groupID: g.id,
                                                  segment: 0, firstSlot: UInt32(slots.count), level: level,
                                                  extendedAttributes: extendedAttributes, tracker: tracker, cancel: cancel)
                frames += f
                entries[g.id] = e
                slots += s
            } else {
                let (f, e) = try writeData(byGroup[g.id] ?? [], to: out, startFrame: frames.count, known: [:], keys: groupKeys[g.id],
                                           group: g.id, proofs: true, level: level, lzma2: lzma2, appleCodec: appleCodec, jpeg: jpeg, deflate: deflate, tables: tables, models: models, extendedAttributes: extendedAttributes, workload: workload,
                                           tracker: tracker, cancel: cancel)
                frames += f
                entries[g.id] = e
            }
        }
        try writeDirectorySegment(groups: map.groups, frames: frames, entries: entries, keys: groupKeys, archiveID: archiveID,
                                  segment: 0, previousFooter: 0, signer: signer, previousSignature: [UInt8](repeating: 0, count: 32),
                                  newSlots: slots, olderSlotTables: [], erasable: erasable, to: out)
        let size = out.position
        try out.commit(overwrite: overwrite)
        tracker.add(bytes: total - tracker.completedBytes, entries: items.count)
        tracker.finish()
        return WriteReport(entries: items.count, inputBytes: total, outputBytes: size, elapsed: tracker.elapsed)
    }

    /// The end of a 1.3 segment: one catalog per group (every frame of the archive, the group's
    /// entries, its name and folders; sealed with the group's key when encrypted), the directory
    /// (signed by `signer`, chained to `previousSignature`) and the footer.
    static func writeDirectorySegment(groups: [(id: UInt16, name: String, prefixes: [String])], frames: [Xiz.Frame],
                                      entries: [UInt16: [Xiz.Entry]], keys: [UInt16: XizKeys], archiveID: [UInt8], segment: UInt32,
                                      previousFooter: UInt64, signer: XizSigner?, previousSignature: [UInt8],
                                      newSlots: [[UInt8]] = [], olderSlotTables: [XizDirectory.SlotTable] = [], erasable: Bool = false,
                                      forensicBlock: [UInt8]? = nil, to out: XizOutput) throws {
        var directory = XizDirectory(flags: erasable ? XizDirectory.erasableFlag : 0, groups: [])
        directory.slotTables = olderSlotTables
        if !newSlots.isEmpty {
            directory.slotTables.append(XizDirectory.SlotTable(segment: segment, offset: out.position, count: UInt32(newSlots.count)))
            for s in newSlots { try out.write(s) }
        }
        var entryCount = 0
        var totalBytes: UInt64 = 0
        var leaves: [[UInt8]] = []
        for g in groups {
            // Proof data for entries that have none yet (folders, links, new folders of an edit).
            let list = (entries[g.id] ?? []).map { e -> Xiz.Entry in
                var e = e
                if e.proof == nil && e.sealedProof == nil {
                    e.proof = (XizLeaf.randomSalt(), e.type == .symlink ? Xiz.sha256(Array(e.link.utf8)) : [UInt8](repeating: 0, count: 32))
                }
                return e
            }
            leaves += list.map { XizLeaf.hash($0, entryKey: $0.secret) }
            entryCount += list.count
            totalBytes += list.reduce(UInt64(0)) { $0 + $1.size }
            let raw = Xiz.encodeCatalog(Xiz.Catalog(frames: frames, entries: list, group: (g.name, g.prefixes)))
            var packed = raw.withUnsafeBytes { ZipWriter.zstdCompress($0, level: 9, allowExpansion: true) } ?? raw
            if let k = keys[g.id] {
                let aad = XizKeys.groupCatalogAAD(archiveID: archiveID, group: g.id, segment: segment, usize: Int64(raw.count),
                                                  frameCount: UInt32(frames.count))
                packed = try k.sealCatalog(packed, aad: aad, segment: segment)
            }
            directory.groups.append(XizDirectory.GroupCatalog(group: g.id, segment: segment, offset: out.position, csize: Int64(packed.count),
                                                              usize: Int64(raw.count), sha256: Xiz.sha256(packed)))
            try out.write(packed)
        }
        leaves.sort { $0.lexicographicallyPrecedes($1) }
        directory.leafOffset = out.position
        directory.leafCount = UInt32(leaves.count)
        directory.merkleRoot = MerkleTree.root(leaves[...])
        for l in leaves { try out.write(l) }
        if let forensicBlock {  // 1.10 (§20.1): the forensic block, between the leaves and the directory
            directory.version = 3
            directory.forensicOffset = out.position
            directory.forensicLength = UInt32(forensicBlock.count)
            directory.forensicSHA256 = Xiz.sha256(forensicBlock)
            try out.write(forensicBlock)
        }
        if let signer {
            let record = try XizSignature.sign(signer, archiveID: archiveID, segment: segment, directory: directory,
                                               previousFooter: previousFooter, previous: previousSignature)
            directory.signature = record.encode()
        }
        let dir = directory.encode()
        var footer = Xiz.Footer(catalogOffset: out.position, catalogCSize: Int64(dir.count), catalogUSize: Int64(dir.count),
                                frameCount: UInt32(frames.count), entryCount: UInt32(entryCount), totalBytes: totalBytes,
                                catalogSHA256: Xiz.sha256(dir))
        footer.minor = forensicBlock == nil ? 3 : 10
        footer.previousFooter = previousFooter
        try out.write(dir)
        try out.write(footer.encode())
    }

    /// Erasable files (§13.7): each file gets a random entry key, frames of its own sealed with it,
    /// a key slot (sealed with the group's slot key) and its proof data sealed with the entry key.
    static func writeErasable(_ items: [ArchiveItem], to out: XizOutput, startFrame: Int, group: XizKeys, groupID: UInt16, segment: UInt32,
                              firstSlot: UInt32, level: Int, extendedAttributes: Bool, tracker: ProgressTracker,
                              cancel: CancellationToken?) throws -> ([Xiz.Frame], [Xiz.Entry], [[UInt8]]) {
        var frames: [Xiz.Frame] = []
        var entries: [Xiz.Entry] = []
        var slots: [[UInt8]] = []
        let contexts = ZstdContextPool()
        for item in items {
            try cancel?.check()
            let t = item.modified.timeIntervalSince1970
            let sec = Int64(t.rounded(.down))
            var e = Xiz.Entry(type: .file, path: item.name, mode: item.permissions, uid: item.uid, gid: item.gid,
                              mtimeSec: sec, mtimeNsec: UInt32(clamping: Int64((t - Double(sec)) * 1e9)), size: 0, link: "",
                              xattrs: [], extents: [], sha256: nil)
            switch item.kind {
            case .directory: e.type = .directory
            case let .symlink(target): e.type = .symlink; e.link = target
            case let .file(size):
                let entryKey = SymmetricKey(size: .bits256)
                let keys = XizKeys(fileKey: entryKey, archiveID: group.archiveID)
                var keyed = keys.fileDigest()
                var plain = SHA256()
                let r = try FileReader(path: item.sourcePath)
                guard r.size == size else { throw XipperError.io("read (file changed while archiving)", path: item.sourcePath, errno: EAGAIN) }
                var off: Int64 = 0
                while off < size {
                    let n = Int(min(Int64(Xiz.frameData), size - off))
                    let data = try r.read(at: off, count: n)
                    keyed.update(data: data)
                    plain.update(data: data)
                    let index = UInt32(startFrame + frames.count)
                    var payload = data
                    var f = Xiz.Frame(offset: 0, csize: 0, usize: UInt32(n), crc: 0, codec: .store, flags: Xiz.entryKeyFrame, group: groupID)
                    if level > 0, let c = data.withUnsafeBytes({ ZipWriter.zstdCompress($0, level: level, pool: contexts) }) {
                        payload = c
                        f.codec = .zstd
                    }
                    payload = try keys.sealFrame(payload, index: index, f)
                    f.csize = UInt32(payload.count)
                    f.crc = Xiz.crc32c(payload)
                    f.offset = out.position
                    try out.write(Xiz.frameHeader(index: index, f))
                    try out.write(payload)
                    frames.append(f)
                    e.extents.append(Xiz.Extent(frame: index, offset: 0, length: UInt32(n)))
                    off += Int64(n)
                    tracker.add(bytes: Int64(n))
                }
                e.size = UInt64(size)
                e.sha256 = size > 0 ? Array(keyed.finalize()) : nil
                let index = firstSlot + UInt32(slots.count)
                let slot = try XizSlots.seal(entryKey, group: group, segment: segment, index: index)
                slots.append(slot)
                e.slot = (segment, index, Xiz.sha256(slot))
                e.sealedProof = try XizLeaf.sealProof(salt: XizLeaf.randomSalt(), sha256: Array(plain.finalize()), entryKey: entryKey)
                e.secret = entryKey
            }
            if extendedAttributes, e.type != .symlink { e.xattrs = ExtendedAttributes.read(item.sourcePath) }
            entries.append(e)
        }
        return (frames, entries, slots)
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
