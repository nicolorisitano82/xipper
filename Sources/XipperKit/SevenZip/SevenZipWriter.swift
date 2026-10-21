import CLZMA
import Darwin
import Foundation

struct SevenZipOptions: Sendable {
    /// 0...9 (liblzma presets); 0 stores without compression.
    var level = 6
    var password: String?
    /// Also encrypt the header, i.e. the file names (STUDIO.md §7: on by default).
    var encryptHeader = true
    /// Maximum content bytes per solid block; 0 = one block per file; nil = automatic.
    var solidBlockSize: Int64?
    /// ARM64 branch filter for arm64 Mach-O and ELF files.
    var executableFilter = true
    /// Files whose extension says they are already compressed (jpg, mp4, zip…) are stored.
    var storeAlreadyCompressed = true
    /// Split into `name.001`, `name.002`, … of this many bytes; nil = one file.
    var volumeSize: Int64?
    var workload: Workload = .interactive
}

/// Writes 7z archives: LZMA2 encoded in parallel (independent chunks joined with dictionary
/// resets, like 7-Zip's multi-threaded LZMA2), solid blocks, ARM64 filter for executables,
/// AES-256 for data and header, CRC-32 for every file.
enum SevenZipWriter {
    /// Group of files sharing coders.
    private enum Group: Int { case normal, executable, stored }

    private struct Member {
        var item: ArchiveItem
        var size: Int64
        /// Symlink target, written as the entry's content (p7zip convention).
        var inline: [UInt8]?
    }

    private struct PlannedFolder {
        var group: Group
        var members: [Member] = []
        var size: Int64 = 0
        // filled while writing
        var crcs: [UInt32] = []
        var packSize: Int64 = 0
        var coderSize: Int64 = 0  // compressed size before encryption
        var iv: [UInt8] = []
        var dictionary: UInt32 = 0
    }

    static func write(items: [ArchiveItem], to path: String, options o: SevenZipOptions, overwrite: Bool,
                      progress: ProgressHandler?, cancel: CancellationToken?) throws -> WriteReport {
        let password = o.password.map(SevenZipAES.passwordBytes)
        if let p = password, p.isEmpty { throw XipperError.invalidArgument("empty password") }
        if let v = o.volumeSize, v < 64 << 10 { throw XipperError.invalidArgument("7z volumes must be at least 64 KiB") }
        let level = max(0, min(9, o.level))
        let keys = password.map { SevenZipKeyCache(password: $0) }
        let key = keys?.key(salt: [], cyclesPower: SevenZipAES.defaultCyclesPower)

        // 1. Plan: empty entries, then folders by group, each cut at the solid block size.
        var presetOpts = lzma_options_lzma()
        if lzma_lzma_preset(&presetOpts, UInt32(max(1, level))) != 0 { throw XipperError.codec("lzma preset") }
        let dict = presetOpts.dict_size
        let blockLimit = o.solidBlockSize ?? max(Int64(dict) * 64, 64 << 20)
        var empties: [ArchiveItem] = []
        var groups: [Group: [Member]] = [:]
        for item in items {
            switch item.kind {
            case .directory:
                empties.append(item)
            case let .symlink(target):
                groups[.normal, default: []].append(Member(item: item, size: Int64(target.utf8.count), inline: Array(target.utf8)))
            case let .file(size):
                if size == 0 { empties.append(item); continue }
                let g: Group
                if level == 0 || (o.storeAlreadyCompressed && AlreadyCompressed.matches(item.name)) {
                    g = .stored
                } else if o.executableFilter && isARM64Executable(item.sourcePath) {
                    g = .executable
                } else {
                    g = .normal
                }
                groups[g, default: []].append(Member(item: item, size: size, inline: nil))
            }
        }
        var folders: [PlannedFolder] = []
        for g in [Group.normal, .executable, .stored] {
            for m in groups[g] ?? [] {
                if folders.last?.group != g || blockLimit == 0 || folders.last!.size + m.size > blockLimit && !folders.last!.members.isEmpty {
                    folders.append(PlannedFolder(group: g))
                }
                folders[folders.count - 1].members.append(m)
                folders[folders.count - 1].size += m.size
            }
        }
        for i in folders.indices {
            // The decoder allocates the declared dictionary: no bigger than the content.
            let need = UInt32(min(Int64(dict), max(4096, folders[i].size)))
            folders[i].dictionary = UInt32(SZLZMA2.dictionarySize(SZLZMA2.prop(forDictionary: need)))
        }

        let total = folders.reduce(Int64(0)) { $0 + $1.size }
        let tracker = ProgressTracker(totalBytes: total, totalEntries: items.count, handler: progress)
        let out = try VolumeWriter(path: path, volumeSize: o.volumeSize)
        try out.write([UInt8](repeating: 0, count: SevenZip.signatureHeaderSize))

        // 2. Data: chunks of every folder are compressed in parallel batches and written in order.
        let chunk = chunkSize(level: level, dictionary: dict)
        let workers = workerCount(o.workload, level: level, chunk: chunk)
        let batchCapacity = chunk * workers
        let batch = UnsafeMutableRawPointer.allocate(byteCount: batchCapacity, alignment: 16384)
        defer { batch.deallocate() }
        struct Unit { var folder: Int; var offset: Int64; var start: Int; var count: Int; var last: Bool }
        var units: [Unit] = []
        var filled = 0
        var encryptor: AESCBCCoder?
        var encryptorFolder = -1

        func flush() throws {
            let results = Slots<[UInt8]>(units.count)
            let base = batch
            let snapshot = units
            try parallelFor(snapshot.count, workload: .threads(workers), cancel: cancel) { i in
                let u = snapshot[i]
                let data = UnsafeMutableRawBufferPointer(start: base + u.start, count: u.count)
                let f = folders[u.folder]
                if f.group == .executable { BranchFilter.convert(.arm64, encoding: true, data, startOffset: UInt32(truncatingIfNeeded: u.offset)) }
                if f.group == .stored {
                    results[i] = Array(data)
                } else {
                    let unitDict = UInt32(min(Int64(f.dictionary), max(4096, Int64(u.count))))
                    var packed = try LZMA2Chunk.encode(UnsafeRawBufferPointer(data), preset: level, dictionary: unitDict, cancel: cancel)
                    if !u.last {
                        // Independent chunks are joined by dropping each end marker: the next chunk starts with a dictionary reset.
                        guard packed.last == 0 else { throw XipperError.codec("unexpected LZMA2 end") }
                        packed.removeLast()
                    }
                    results[i] = packed
                }
            }
            for (i, u) in snapshot.enumerated() {
                var packed = results.take(i)!
                folders[u.folder].coderSize += Int64(packed.count)
                if let key {
                    if encryptorFolder != u.folder {
                        var iv = [UInt8](repeating: 0, count: 16)
                        arc4random_buf(&iv, 16)
                        folders[u.folder].iv = iv
                        encryptor = try AESCBCCoder(key: key, iv: iv, encrypt: true)
                        encryptorFolder = u.folder
                    }
                    var cipher: [UInt8] = []
                    cipher.reserveCapacity(packed.count + 16)
                    try packed.withUnsafeBytes { try encryptor!.process($0) { cipher.append(contentsOf: $0) } }
                    if u.last { try encryptor!.finish { cipher.append(contentsOf: $0) } }
                    packed = cipher
                }
                try out.write(packed)
                folders[u.folder].packSize += Int64(packed.count)
            }
            units.removeAll(keepingCapacity: true)
            filled = 0
        }

        var unitStart = 0
        var unitOffset: Int64 = 0
        var offset: Int64 = 0
        // A unit can always grow to a full chunk inside the batch, so units of executable
        // folders stay multiples of 4 bytes (the ARM64 filter works on aligned words).
        func beginUnit() throws {
            if batchCapacity - filled < chunk { try flush() }
            unitStart = filled
            unitOffset = offset
        }
        for fi in folders.indices {
            offset = 0
            try beginUnit()
            for m in folders[fi].members {
                try cancel?.check()
                var crc: UInt32 = 0
                var reader: FileReader?
                if m.inline == nil {
                    reader = try FileReader(path: m.item.sourcePath)
                    if reader!.size != m.size {
                        throw XipperError.io("read (file changed while archiving)", path: m.item.sourcePath, errno: EAGAIN)
                    }
                }
                var done: Int64 = 0
                while done < m.size {
                    let n = Int(min(Int64(min(chunk - (filled - unitStart), 4 << 20)), m.size - done))
                    let dst = batch + filled
                    if let inline = m.inline {
                        inline.withUnsafeBytes { dst.copyMemory(from: $0.baseAddress! + Int(done), byteCount: n) }
                    } else {
                        try reader!.read(at: done, into: dst, count: n)
                    }
                    crc = CRC32.update(crc, UnsafeRawBufferPointer(start: dst, count: n))
                    filled += n
                    done += Int64(n)
                    offset += Int64(n)
                    tracker.add(bytes: Int64(n), current: m.item.name)
                    if filled - unitStart == chunk && offset < folders[fi].size {
                        units.append(Unit(folder: fi, offset: unitOffset, start: unitStart, count: chunk, last: false))
                        try beginUnit()
                    }
                    try cancel?.check()
                }
                folders[fi].crcs.append(crc)
                tracker.add(bytes: 0, entries: 1)
            }
            units.append(Unit(folder: fi, offset: unitOffset, start: unitStart, count: filled - unitStart, last: true))
        }
        if !units.isEmpty { try flush() }
        for i in folders.indices where folders[i].packSize == 0 && folders[i].size > 0 {
            throw XipperError.codec("7z folder \(i) was not written")
        }

        // 3. Header.
        var h = SZHeader()
        h.streams.packPos = 0
        h.streams.packSizes = folders.map(\.packSize)
        for (i, f) in folders.enumerated() {
            h.streams.folders.append(folderInfo(f, encrypted: key != nil, firstPack: i))
            h.streams.numUnpackStreams.append(f.members.count)
            h.streams.subSizes.append(contentsOf: f.members.map(\.size))
            h.streams.subCRCs.append(contentsOf: f.crcs)
        }
        for item in empties { h.files.append(fileRecord(item, hasStream: false)) }
        for f in folders { for m in f.members { h.files.append(fileRecord(m.item, hasStream: true)) } }
        tracker.add(bytes: 0, entries: empties.count)

        let plain = SZHeaderWriter.writeHeader(h)
        var next = plain
        let dataEnd = out.position
        // Compressed (and, with a password, encrypted) like 7-Zip's defaults; tiny headers stay plain.
        let encryptHeader = key != nil && o.encryptHeader
        if plain.count > 128 || encryptHeader {
            var packed = try plain.withUnsafeBytes { try LZMA2Chunk.encode($0, preset: max(level, 5), dictionary: UInt32(max(4096, min(plain.count, 1 << 24))), cancel: cancel) }
            var coders = [SZCoder(method: SevenZip.Method.lzma2, props: [SZLZMA2.prop(forDictionary: UInt32(max(4096, min(plain.count, 1 << 24))))])]
            var sizes = [Int64(plain.count)]
            var binds: [(inIndex: Int, outIndex: Int)] = []
            if encryptHeader, let key {
                var iv = [UInt8](repeating: 0, count: 16)
                arc4random_buf(&iv, 16)
                let enc = try AESCBCCoder(key: key, iv: iv, encrypt: true)
                var cipher: [UInt8] = []
                try packed.withUnsafeBytes { try enc.process($0) { cipher.append(contentsOf: $0) } }
                try enc.finish { cipher.append(contentsOf: $0) }
                coders.insert(SZCoder(method: SevenZip.Method.aes, props: SevenZipAES.encodeProps(cyclesPower: SevenZipAES.defaultCyclesPower, iv: iv)), at: 0)
                sizes.insert(Int64(packed.count), at: 0)
                binds = [(1, 0)]
                packed = cipher
            }
            try out.write(packed)
            var info = SZStreamsInfo()
            info.packPos = dataEnd - Int64(SevenZip.signatureHeaderSize)
            info.packSizes = [Int64(packed.count)]
            var f = SZFolder(coders: coders, bindPairs: binds, packedStreams: [0], unpackSizes: sizes, crc: CRC32.checksum(plain))
            f.firstPackStream = 0
            info.folders = [f]
            info.numUnpackStreams = [1]
            var w = ByteWriter()
            w.u8(SevenZip.ID.encodedHeader)
            SZHeaderWriter.writeStreamsInfo(info, &w)
            next = w.bytes
        }
        let headerOffset = out.position - Int64(SevenZip.signatureHeaderSize)
        try out.write(next)

        var start = ByteWriter()
        start.u64(UInt64(headerOffset))
        start.u64(UInt64(next.count))
        start.u32(CRC32.checksum(next))
        var sig = ByteWriter()
        sig.append(SevenZip.signature)
        sig.u8(SevenZip.versionMajor)
        sig.u8(SevenZip.versionMinor)
        sig.u32(CRC32.checksum(start.bytes))
        sig.append(start.bytes)
        try out.patchStart(sig.bytes)
        try out.commit(overwrite: overwrite)
        tracker.finish()
        return WriteReport(entries: items.count, inputBytes: total, outputBytes: out.position, elapsed: tracker.elapsed)
    }

    /// Coders from the packed side: [AES] → LZMA2 or Copy → [ARM64] (7-Zip's order).
    private static func folderInfo(_ f: PlannedFolder, encrypted: Bool, firstPack: Int) -> SZFolder {
        var coders: [SZCoder] = []
        var sizes: [Int64] = []
        if encrypted {
            coders.append(SZCoder(method: SevenZip.Method.aes, props: SevenZipAES.encodeProps(cyclesPower: SevenZipAES.defaultCyclesPower, iv: f.iv)))
            sizes.append(f.coderSize)
        }
        if f.group != .stored || !encrypted {
            coders.append(f.group == .stored ? SZCoder(method: SevenZip.Method.copy)
                                             : SZCoder(method: SevenZip.Method.lzma2, props: [SZLZMA2.prop(forDictionary: f.dictionary)]))
            sizes.append(f.size)
        }
        if f.group == .executable {
            coders.append(SZCoder(method: SevenZip.Method.arm64))
            sizes.append(f.size)
        }
        var folder = SZFolder(coders: coders, packedStreams: [0], unpackSizes: sizes)
        folder.bindPairs = (1..<max(1, coders.count)).map { ($0, $0 - 1) }
        folder.firstPackStream = firstPack
        return folder
    }

    private static func fileRecord(_ item: ArchiveItem, hasStream: Bool) -> SZFile {
        var f = SZFile()
        f.name = item.name
        f.hasStream = hasStream
        f.mtime = item.modified
        var type: UInt32
        var attr: UInt32
        switch item.kind {
        case .directory:
            f.isDirectory = true
            type = UInt32(S_IFDIR)
            attr = SevenZip.Attribute.directory
        case .symlink:
            type = UInt32(S_IFLNK)
            attr = SevenZip.Attribute.archive
        case .file:
            type = UInt32(S_IFREG)
            attr = SevenZip.Attribute.archive
        }
        if item.permissions & 0o222 == 0 { attr |= SevenZip.Attribute.readOnly }
        f.attributes = attr | SevenZip.Attribute.unixExtension | (type | UInt32(item.permissions & 0o7777)) << 16
        return f
    }

    /// arm64 Mach-O (thin or universal) and AArch64 ELF.
    static func isARM64Executable(_ path: String) -> Bool {
        guard let r = try? FileReader(path: path), r.size >= 64, let h = try? r.read(at: 0, count: 64) else { return false }
        func le32(_ o: Int) -> UInt32 { UInt32(h[o]) | UInt32(h[o + 1]) << 8 | UInt32(h[o + 2]) << 16 | UInt32(h[o + 3]) << 24 }
        func be32(_ o: Int) -> UInt32 { UInt32(h[o]) << 24 | UInt32(h[o + 1]) << 16 | UInt32(h[o + 2]) << 8 | UInt32(h[o + 3]) }
        let arm64CPU: UInt32 = 0x0100_000C
        if le32(0) == 0xFEED_FACF { return le32(4) == arm64CPU }
        if be32(0) == 0xCAFE_BABE {
            // Universal binary: any arm64 slice (fat headers are big-endian).
            let n = min(Int(be32(4)), 2)
            return (0..<n).contains { be32(8 + $0 * 20) == arm64CPU }
        }
        if h.starts(with: [0x7F, 0x45, 0x4C, 0x46]) { return h[18] == 183 && h[19] == 0 }
        return false
    }

    /// Independent LZMA2 chunk size: 3× the dictionary (liblzma's default block), 1× from preset 7
    /// and 2× at 9 (measurements of FASE2.md for xz), at least 1 MiB.
    static func chunkSize(level: Int, dictionary: UInt32) -> Int {
        if level == 0 { return 4 << 20 }
        let factor = level >= 9 ? 2 : (level >= 7 ? 1 : 3)
        return max(1 << 20, Int(dictionary) * factor)
    }

    /// One worker per core, fewer if the encoders' memory would exceed a quarter of RAM.
    static func workerCount(_ w: Workload, level: Int, chunk: Int) -> Int {
        var opts = lzma_options_lzma()
        _ = lzma_lzma_preset(&opts, UInt32(max(1, level)))
        let perWorker = withUnsafeMutablePointer(to: &opts) { p -> UInt64 in
            var filters = [lzma_filter(id: lzmaFilterLZMA2, options: p), lzma_filter(id: lzmaVLIUnknown, options: nil)]
            let m = lzma_raw_encoder_memusage(&filters)
            return m == UInt64.max ? 128 << 20 : m
        } + UInt64(chunk) * 2
        let budget = ProcessInfo.processInfo.physicalMemory / 4
        return max(1, min(w.workerCount, Int(budget / max(perWorker, 1))))
    }
}

/// Raw LZMA2 encoding of one independent chunk (starts with a dictionary reset, ends with the end marker).
enum LZMA2Chunk {
    static func encode(_ input: UnsafeRawBufferPointer, preset: Int, dictionary: UInt32, cancel: CancellationToken?) throws -> [UInt8] {
        var opts = lzma_options_lzma()
        if lzma_lzma_preset(&opts, UInt32(max(1, min(9, preset)))) != 0 { throw XipperError.codec("lzma preset") }
        opts.dict_size = max(4096, dictionary)
        var strm = lzma_stream()
        defer { lzma_end(&strm) }
        let r = withUnsafeMutablePointer(to: &opts) { p -> lzma_ret in
            var filters = [lzma_filter(id: lzmaFilterLZMA2, options: p), lzma_filter(id: lzmaVLIUnknown, options: nil)]
            return lzma_raw_encoder(&strm, &filters)
        }
        if r == LZMA_MEM_ERROR { throw XipperError.limitExceeded("lzma2: memory") }
        if r != LZMA_OK { throw XipperError.codec("lzma2 encoder init (\(r.rawValue))") }
        // Worst case: 3 bytes of header per 64 KiB uncompressed chunk, plus the end marker.
        var out = [UInt8](repeating: 0, count: input.count + input.count / 65536 * 3 + 64)
        var produced = 0
        try out.withUnsafeMutableBytes { o in
            var consumed = 0
            while true {
                try cancel?.check()
                let n = min(1 << 20, input.count - consumed)
                strm.next_in = input.baseAddress.map { $0.assumingMemoryBound(to: UInt8.self) + consumed }
                strm.avail_in = n
                strm.next_out = o.baseAddress!.assumingMemoryBound(to: UInt8.self) + produced
                strm.avail_out = o.count - produced
                let action = consumed + n == input.count ? LZMA_FINISH : LZMA_RUN
                let before = strm.avail_out
                let r = lzma_code(&strm, action)
                produced += before - strm.avail_out
                consumed += n - strm.avail_in
                if r == LZMA_STREAM_END { break }
                if r != LZMA_OK { throw XipperError.codec("lzma2 encoder (\(r.rawValue))") }
                if strm.avail_out == 0 { throw XipperError.codec("lzma2 output larger than expected") }
            }
        }
        out.removeSubrange(produced...)
        return out
    }
}

/// The archive file, or its volumes. Bytes 0..<32 of the first volume are patched at the end.
final class VolumeWriter {
    private let path: String
    private let volumeSize: Int64?
    private var files: [OutputFile] = []
    private(set) var position: Int64 = 0

    init(path: String, volumeSize: Int64?) throws {
        self.path = path
        self.volumeSize = volumeSize
        try open()
    }

    private func volumePath(_ n: Int) -> String {
        volumeSize == nil ? path : path + "." + String(format: "%03d", n)
    }

    private func open() throws {
        let p = volumePath(files.count + 1)
        files.append(try OutputFile(path: p))
    }

    func write(_ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { b in
            var rest = b
            while !rest.isEmpty {
                var room = rest.count
                if let v = volumeSize {
                    let used = files.last!.position
                    if used == v { try open() }
                    room = Int(min(Int64(rest.count), v - files.last!.position))
                }
                try files.last!.write(UnsafeRawBufferPointer(rebasing: rest[0..<room]))
                position += Int64(room)
                rest = UnsafeRawBufferPointer(rebasing: rest[room...])
            }
        }
    }

    func patchStart(_ bytes: [UInt8]) throws { try files[0].patch(at: 0, bytes) }

    func commit(overwrite: Bool) throws {
        for f in files { try f.commit(overwrite: overwrite) }
    }
}
