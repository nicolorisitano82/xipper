import CryptoKit
import Foundation
import Synchronization

/// XIZ 1.10 forensic profile (docs/XIZ_SPEC.md §20): disk and volume images with the source's
/// hashes, a SHA-256 of every frame, unreadable-sector maps, case, device and acquisition records,
/// and custody segments that anyone in the chain can append and sign without the content's keys.
/// Used by xipper-forensic (docs/XIPPER_FORENSIC.md); the Xipper app reads such archives but never writes them.
public enum XizForensic {
    static let maxBlock = 64 << 20
    static let magic: [UInt8] = Array("XFOR".utf8)
    static let critical: UInt16 = 0x8000
    /// Image block size (§20.3): one frame per block.
    public static let blockSize = Xiz.frameData

    public enum RecordType: UInt16, Sendable {
        case frameHashes = 0x8001, caseInfo = 0x0002, device = 0x0003, sourceHashes = 0x8004
        case unreadable = 0x8005, log = 0x0006, custody = 0x0007, acquisition = 0x0008
    }

    public struct Record: Sendable, Equatable {
        public var type: UInt16
        public var value: [UInt8]
        public init(type: UInt16, value: [UInt8]) { self.type = type; self.value = value }
        init(_ t: RecordType, _ v: [UInt8]) { type = t.rawValue; value = v }
        /// JSON records (case, device, custody, acquisition) as a dictionary of strings.
        public var json: [String: String] {
            guard let o = try? JSONSerialization.jsonObject(with: Data(value)) as? [String: Any] else { return [:] }
            return o.compactMapValues { v in (v as? String) ?? (v as? NSNumber)?.stringValue }
        }
        public var text: String { String(decoding: value, as: UTF8.self) }
    }

    /// The forensic block of one segment (§20.2).
    public struct Block: Sendable, Equatable {
        public var segment: UInt32
        public var records: [Record]

        public func records(_ t: RecordType) -> [Record] { records.filter { $0.type == t.rawValue } }

        func encode() -> [UInt8] {
            var w = ByteWriter(capacity: 64 + records.reduce(0) { $0 + 6 + $1.value.count })
            w.append(XizForensic.magic); w.u16(1); w.u32(segment); w.u32(UInt32(records.count))
            for r in records { w.u16(r.type); w.u32(UInt32(r.value.count)); w.append(r.value) }
            w.u32(Xiz.crc32c(w.bytes))
            return w.bytes
        }

        static func decode(_ b: [UInt8]) throws -> Block {
            guard b.count >= 18, b.count <= XizForensic.maxBlock, b.starts(with: XizForensic.magic) else {
                throw XipperError.corrupt("XIZ forensic block")
            }
            let crc = b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: b.count - 4, as: UInt32.self).littleEndian }
            guard crc == Xiz.crc32c(Array(b[..<(b.count - 4)])) else { throw XipperError.corrupt("XIZ forensic block checksum mismatch") }
            return try b.withUnsafeBytes { raw in
                var r = ByteReader(UnsafeRawBufferPointer(rebasing: raw[..<(raw.count - 4)]), at: 4)
                guard try r.u16() == 1 else { throw XipperError.unsupported("XIZ forensic block version") }
                let segment = try r.u32()
                let n = Int(try r.u32())
                guard n <= r.remaining / 6 else { throw XipperError.corrupt("XIZ forensic record count") }
                var records: [Record] = []
                for _ in 0..<n {
                    let type = try r.u16(), len = Int(try r.u32())
                    guard len <= r.remaining else { throw XipperError.corrupt("XIZ forensic record length") }
                    let value = Array(try r.bytes(len))
                    if RecordType(rawValue: type) == nil && type & XizForensic.critical != 0 {
                        throw XipperError.unsupported("XIZ forensic record 0x\(String(type, radix: 16)) (made by a newer xipper-forensic)")
                    }
                    records.append(Record(type: type, value: value))
                }
                guard r.remaining == 0 else { throw XipperError.corrupt("XIZ forensic block trailing data") }
                return Block(segment: segment, records: records)
            }
        }
    }

    // MARK: typed records

    /// 0x8001: SHA-256 of (frame header ‖ payload as written) of the frames a segment writes.
    public struct FrameHashes: Sendable, Equatable {
        public var first: UInt32
        public var hashes: [[UInt8]]
        public var root: [UInt8]

        static func hash(header: [UInt8], payload: [UInt8]) -> [UInt8] {
            var h = SHA256()
            h.update(data: header); h.update(data: payload)
            return Array(h.finalize())
        }

        /// RFC 6962 root over leaves `u32(index) ‖ hash`, in index order.
        static func root(first: UInt32, _ hashes: [[UInt8]]) -> [UInt8] {
            let leaves = hashes.enumerated().map { i, h -> [UInt8] in
                var w = ByteWriter(capacity: 36)
                w.u32(first + UInt32(i)); w.append(h)
                return MerkleTree.leafHash(w.bytes)
            }
            return MerkleTree.root(leaves[...])
        }

        init(first: UInt32, hashes: [[UInt8]]) {
            self.first = first
            self.hashes = hashes
            root = Self.root(first: first, hashes)
        }

        var encoded: [UInt8] {
            var w = ByteWriter(capacity: 40 + hashes.count * 32)
            w.u32(first); w.u32(UInt32(hashes.count))
            for h in hashes { w.append(h) }
            w.append(root)
            return w.bytes
        }

        init(_ b: [UInt8]) throws {
            guard b.count >= 40, (b.count - 40) % 32 == 0 else { throw XipperError.corrupt("XIZ frame hashes") }
            first = b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian }
            let n = Int(b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian })
            guard b.count == 40 + n * 32 else { throw XipperError.corrupt("XIZ frame hashes") }
            hashes = (0..<n).map { Array(b[(8 + $0 * 32)..<(40 + $0 * 32)]) }
            root = Array(b[(8 + n * 32)...])
        }
    }

    /// 0x8004: hashes of the source as it was read.
    public struct SourceHashes: Sendable, Equatable {
        public var path: String
        public var size: UInt64
        public var md5: [UInt8]?
        public var sha1: [UInt8]?
        public var sha256: [UInt8]
        public var started: Date
        public var finished: Date

        var encoded: [UInt8] {
            var w = ByteWriter(capacity: 120 + path.utf8.count)
            let p = Array(path.utf8); w.u16(UInt16(p.count)); w.append(p)
            w.u64(size)
            w.u8((md5 == nil ? 0 : 1) | (sha1 == nil ? 0 : 2) | 4)
            w.append(md5 ?? [UInt8](repeating: 0, count: 16)); w.append(sha1 ?? [UInt8](repeating: 0, count: 20)); w.append(sha256)
            w.u64(UInt64(bitPattern: Int64(started.timeIntervalSince1970))); w.u64(UInt64(bitPattern: Int64(finished.timeIntervalSince1970)))
            return w.bytes
        }

        init(path: String, size: UInt64, md5: [UInt8]?, sha1: [UInt8]?, sha256: [UInt8], started: Date, finished: Date) {
            self.path = path; self.size = size; self.md5 = md5; self.sha1 = sha1; self.sha256 = sha256
            self.started = started; self.finished = finished
        }

        init(_ b: [UInt8]) throws {
            try self = b.withUnsafeBytes { raw in
                var r = ByteReader(raw)
                let path = String(decoding: try r.bytes(Int(try r.u16())), as: UTF8.self)
                let size = try r.u64(), which = try r.u8()
                let md5 = Array(try r.bytes(16)), sha1 = Array(try r.bytes(20)), sha256 = Array(try r.bytes(32))
                let s = Int64(bitPattern: try r.u64()), f = Int64(bitPattern: try r.u64())
                guard r.remaining == 0, which & 4 != 0 else { throw XipperError.corrupt("XIZ source hashes") }
                return SourceHashes(path: path, size: size, md5: which & 1 != 0 ? md5 : nil, sha1: which & 2 != 0 ? sha1 : nil, sha256: sha256,
                                    started: Date(timeIntervalSince1970: Double(s)), finished: Date(timeIntervalSince1970: Double(f)))
            }
        }
    }

    /// 0x8005: ranges of an image that could not be read (zeros in the image).
    public struct Unreadable: Sendable, Equatable {
        public struct Range: Sendable, Equatable {
            public var offset: UInt64
            public var length: UInt64
            public var error: Int32
            public var attempts: UInt16
            public init(offset: UInt64, length: UInt64, error: Int32 = EIO, attempts: UInt16 = 1) {
                self.offset = offset; self.length = length; self.error = error; self.attempts = attempts
            }
        }
        public var path: String
        public var ranges: [Range]

        var encoded: [UInt8] {
            var w = ByteWriter(capacity: 8 + path.utf8.count + ranges.count * 24)
            let p = Array(path.utf8); w.u16(UInt16(p.count)); w.append(p)
            w.u32(UInt32(ranges.count))
            for x in ranges { w.u64(x.offset); w.u64(x.length); w.u32(UInt32(bitPattern: x.error)); w.u16(x.attempts); w.u16(0) }
            return w.bytes
        }

        init(path: String, ranges: [Range]) { self.path = path; self.ranges = ranges }

        init(_ b: [UInt8]) throws {
            try self = b.withUnsafeBytes { raw in
                var r = ByteReader(raw)
                let path = String(decoding: try r.bytes(Int(try r.u16())), as: UTF8.self)
                let n = Int(try r.u32())
                guard n * 24 == r.remaining else { throw XipperError.corrupt("XIZ unreadable sectors") }
                var ranges: [Range] = []
                for _ in 0..<n {
                    ranges.append(Range(offset: try r.u64(), length: try r.u64(), error: Int32(bitPattern: try r.u32()), attempts: try r.u16()))
                    _ = try r.u16()
                }
                return Unreadable(path: path, ranges: ranges)
            }
        }
    }

    static func json(_ d: [String: String]) -> [UInt8] {
        Array((try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8))
    }

    static func timestamp(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    static func logLine(_ event: String, _ fields: [String: String] = [:], at date: Date = Date()) -> String {
        var d = fields
        d["t"] = timestamp(date)
        d["event"] = event
        return String(decoding: json(d), as: UTF8.self)
    }

    // MARK: acquisition of an image (from a file; devices go through the same path in xipper-forensic)

    public struct ImageOptions: Sendable {
        /// Path of the image inside the archive.
        public var name = "image.dd"
        public var logicalSector: UInt32 = 512
        public var physicalSector: UInt32 = 512
        public var volume = false
        public var volumeOffset: UInt64 = 0
        /// zstd level; 0 stores the blocks.
        public var level = 3
        public var md5 = true
        public var sha1 = true
        public var password: String?
        /// Recipients (public keys, more passwords); access groups are not used in images.
        public var access: XizAccess?
        public var caseInfo: [String: String] = [:]
        public var device: [String: String] = [:]
        public var acquisition: [String: String] = [:]
        /// Ranges the source could not read: zeros in the image, listed in the unreadable map.
        public var unreadable: [Unreadable.Range] = []
        /// Fixed time for reproducible test vectors; the clock otherwise.
        public var now: Date?
        public init() {}
    }

    public struct ImageReport: Sendable {
        public var size: UInt64
        public var archiveBytes: Int64
        public var sha256: [UInt8]
        public var md5: [UInt8]?
        public var sha1: [UInt8]?
        public var frames: Int
        public var zeroBlocks: Int
        public var unreadableBytes: UInt64
    }

    /// Writes a forensic XIZ holding the image of `source` (a file or a raw device opened by the caller).
    public static func acquireImage(from source: String, to path: String, options o: ImageOptions, signer: XizSigner,
                                    workload: Workload = .interactive, progress: ProgressHandler? = nil,
                                    cancel: CancellationToken? = nil) throws -> ImageReport {
        let reader = try FileReader(path: source)
        let size = UInt64(reader.size)
        let started = o.now ?? Date()
        let tracker = ProgressTracker(totalBytes: Int64(size), totalEntries: 1, handler: progress)
        let ranges = o.unreadable.sorted { $0.offset < $1.offset }
        for (i, x) in ranges.enumerated() {
            guard x.length > 0, x.offset + x.length <= size, i == 0 || ranges[i - 1].offset + ranges[i - 1].length <= x.offset else {
                throw XipperError.invalidArgument("unreadable ranges must be inside the source and not overlap")
            }
        }

        var archiveID = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&archiveID, 16)
        var superblock = Xiz.Superblock(archiveID: archiveID)
        superblock.required.formUnion([.directory, .forensic])
        superblock.minor = 10
        var policy = o.access ?? XizAccess()
        guard policy.groups.isEmpty, !policy.erasable else { throw XipperError.invalidArgument("forensic images use no access groups and no erasable files") }
        if let pw = o.password { policy.recipients.insert(XizAccess.Recipient(label: "", credential: .password(pw)), at: 0) }
        let encrypted = !policy.recipients.isEmpty || !policy.thresholds.isEmpty
        var keys: XizKeys?
        var keysBlock: [UInt8] = []
        if encrypted {
            let k = SymmetricKey(size: .bits256)
            keys = XizKeys(fileKey: k, archiveID: archiveID)
            let stanzas = try XizAccessKeys.prepare(policy, groupIDs: [XizAccess.defaultGroup: 0], groupKeys: [0: k], archiveID: archiveID, kdf: .standard)
            let n = XizAccessKeys.size(stanzas)
            guard n <= Xiz.maxKeysBlock else { throw XipperError.limitExceeded("too many recipients for one XIZ archive") }
            superblock.required.insert(.encrypted)
            superblock.keysLength = UInt32(n)
            keysBlock = try XizAccessKeys.seal(stanzas, superblock: superblock.encode())
        }
        if FileManager.default.fileExists(atPath: path) { throw XipperError.alreadyExists(path: path) }
        let out = try OutputFile(path: path)
        try out.write(superblock.encode())
        if !keysBlock.isEmpty { try out.write(keysBlock) }

        var frames: [Xiz.Frame] = []
        var hashes: [[UInt8]] = []
        func writeFrame(_ data: UnsafeRawBufferPointer, compressed: [UInt8]?) throws -> UInt32 {
            let index = UInt32(frames.count)
            var f = Xiz.Frame(offset: 0, csize: 0, usize: UInt32(data.count), crc: 0, codec: compressed == nil ? .store : .zstd)
            var payload = compressed ?? Array(data)
            if let keys { payload = try keys.sealFrame(payload, index: index, f) }
            f.csize = UInt32(payload.count)
            f.crc = Xiz.crc32c(payload)
            f.offset = out.position
            let header = Xiz.frameHeader(index: index, f)
            try out.write(header)
            try out.write(payload)
            frames.append(f)
            hashes.append(FrameHashes.hash(header: header, payload: payload))
            return index
        }
        func compress(_ b: UnsafeRawBufferPointer) -> [UInt8]? {
            o.level > 0 ? ZipWriter.zstdCompress(b, level: o.level) : nil
        }

        var md5 = o.md5 ? Insecure.MD5() : nil
        var sha1 = o.sha1 ? Insecure.SHA1() : nil
        var sha256 = SHA256()
        var digest = XizContentDigest(keys: keys)
        var extents: [Xiz.Extent] = []
        var zeroFrame: UInt32?
        var zeroBlocks = 0
        let block = blockSize
        let blocks = Int((size + UInt64(block) - 1) / UInt64(block))
        let batch = max(2, workload.workerCount * 2)
        var nextRange = 0
        var b = 0
        while b < blocks {
            try cancel?.check()
            let count = min(batch, blocks - b)
            // Read sequentially (a device reads best in order), zero the unreadable ranges, hash.
            var datas: [[UInt8]] = []
            for k in 0..<count {
                let off = UInt64(b + k) * UInt64(block)
                let n = Int(min(UInt64(block), size - off))
                var d = try reader.read(at: Int64(off), count: n)
                while nextRange < ranges.count, ranges[nextRange].offset + ranges[nextRange].length <= off { nextRange += 1 }
                var j = nextRange
                while j < ranges.count, ranges[j].offset < off + UInt64(n) {
                    let lo = max(ranges[j].offset, off), hi = min(ranges[j].offset + ranges[j].length, off + UInt64(n))
                    for p in Int(lo - off)..<Int(hi - off) { d[p] = 0 }
                    j += 1
                }
                d.withUnsafeBytes { r in
                    md5?.update(bufferPointer: r); sha1?.update(bufferPointer: r); sha256.update(bufferPointer: r); digest.update(r)
                }
                datas.append(d)
            }
            let zero = datas.map { d in d.withUnsafeBytes { r in r.allSatisfy { $0 == 0 } } }
            let packed = Mutex<[Int: [UInt8]]>([:])
            try parallelFor(count, workload: workload, cancel: cancel) { k in
                guard !zero[k] else { return }
                if let c = datas[k].withUnsafeBytes({ compress($0) }) { packed.withLock { $0[k] = c } }
            }
            let p = packed.withLock { $0 }
            for k in 0..<count {
                let n = UInt32(datas[k].count)
                if zero[k] {
                    if zeroFrame == nil {
                        let zeros = [UInt8](repeating: 0, count: block)
                        zeroFrame = try zeros.withUnsafeBytes { try writeFrame($0, compressed: compress($0)) }
                    }
                    extents.append(Xiz.Extent(frame: zeroFrame!, offset: 0, length: n))
                    zeroBlocks += 1
                } else {
                    let i = try datas[k].withUnsafeBytes { try writeFrame($0, compressed: p[k]) }
                    extents.append(Xiz.Extent(frame: i, offset: 0, length: n))
                }
                tracker.add(bytes: Int64(n))
            }
            b += count
        }
        let finished = o.now ?? Date()
        let sourceSHA = Array(sha256.finalize())
        let md5Out = md5.map { Array($0.finalize()) }, sha1Out = sha1.map { Array($0.finalize()) }
        let unreadableBytes = ranges.reduce(UInt64(0)) { $0 + $1.length }

        // Records, also stored as ordinary files under "forensic/" so any XIZ reader extracts them.
        var acquisition = o.acquisition
        acquisition["tool"] = acquisition["tool"] ?? "xipper-forensic"
        acquisition["method"] = acquisition["method"] ?? (o.volume ? "volume" : "physical")
        acquisition["started"] = timestamp(started)
        acquisition["finished"] = timestamp(finished)
        acquisition["source_size"] = String(size)
        var log = [logLine("acquisition started", ["source": (source as NSString).lastPathComponent, "size": String(size)], at: started)]
        for x in ranges { log.append(logLine("unreadable", ["offset": String(x.offset), "length": String(x.length), "error": String(x.error)], at: finished)) }
        log.append(logLine("acquisition finished", ["sha256": hex(sourceSHA), "unreadable_bytes": String(unreadableBytes)], at: finished))
        let logText = Array((log.joined(separator: "\n") + "\n").utf8)
        var device = o.device
        device["path"] = o.name
        let files: [(String, [UInt8])] = [("forensic/case.json", json(o.caseInfo)), ("forensic/device.json", json(device)),
                                          ("forensic/acquisition.json", json(acquisition)), ("forensic/log.jsonl", logText)]
        let meta = files.flatMap(\.1)
        let metaFrame = try meta.withUnsafeBytes { try writeFrame($0, compressed: compress($0)) }

        let mtime = Int64(finished.timeIntervalSince1970)
        var image = Xiz.Entry(type: .file, path: o.name, mode: 0o444, uid: 0, gid: 0, mtimeSec: mtime, mtimeNsec: 0, size: size,
                              link: "", xattrs: [], extents: extents, sha256: digest.finish())
        image.proof = (XizLeaf.randomSalt(), sourceSHA)
        image.image = Xiz.Image(logicalSector: o.logicalSector, physicalSector: o.physicalSector, flags: o.volume ? 1 : 0, offset: o.volumeOffset)
        var entries = [image,
                       Xiz.Entry(type: .directory, path: "forensic", mode: 0o755, uid: 0, gid: 0, mtimeSec: mtime, mtimeNsec: 0, size: 0,
                                 link: "", xattrs: [], extents: [], sha256: nil)]
        var at: UInt32 = 0
        for (name, bytes) in files {
            var d = XizContentDigest(keys: keys)
            bytes.withUnsafeBytes { d.update($0) }
            var e = Xiz.Entry(type: .file, path: name, mode: 0o444, uid: 0, gid: 0, mtimeSec: mtime, mtimeNsec: 0, size: UInt64(bytes.count),
                              link: "", xattrs: [], extents: bytes.isEmpty ? [] : [Xiz.Extent(frame: metaFrame, offset: at, length: UInt32(bytes.count))],
                              sha256: d.finish())
            e.proof = (XizLeaf.randomSalt(), Xiz.sha256(bytes))
            entries.append(e)
            at += UInt32(bytes.count)
        }

        var records = [Record(.frameHashes, FrameHashes(first: 0, hashes: hashes).encoded),
                       Record(.caseInfo, json(o.caseInfo)), Record(.device, json(device)),
                       Record(.sourceHashes, SourceHashes(path: o.name, size: size, md5: md5Out, sha1: sha1Out, sha256: sourceSHA,
                                                          started: started, finished: finished).encoded)]
        if !ranges.isEmpty { records.append(Record(.unreadable, Unreadable(path: o.name, ranges: ranges).encoded)) }
        records += [Record(.acquisition, json(acquisition)), Record(.log, logText)]
        let block0 = Block(segment: 0, records: records).encode()
        try XizWriter.writeDirectorySegment(groups: [(0, XizAccess.defaultGroup, [])], frames: frames, entries: [0: entries],
                                            keys: keys.map { [0: $0] } ?? [:], archiveID: archiveID, segment: 0, previousFooter: 0,
                                            signer: signer, previousSignature: [UInt8](repeating: 0, count: 32),
                                            forensicBlock: block0, to: out)
        let written = out.position
        try out.commit(overwrite: false)
        tracker.finish()
        return ImageReport(size: size, archiveBytes: written, sha256: sourceSHA, md5: md5Out, sha1: sha1Out, frames: frames.count,
                           zeroBlocks: zeroBlocks, unreadableBytes: unreadableBytes)
    }

    // MARK: segments

    struct Segment {
        var footerOffset: Int64
        var footer: Xiz.Footer
        var directory: XizDirectory
        var block: Block
    }

    /// Every segment, oldest first, with its directory and forensic block (no key needed).
    static func segments(_ reader: FileReader) throws -> (Xiz.Superblock, [Segment]) {
        let sb = try Xiz.Superblock.decode(try reader.read(at: 0, count: Xiz.superblockSize))
        guard sb.required.contains(.forensic) else { throw XipperError.invalidArgument("not a forensic XIZ archive (XIZ 1.10 profile)") }
        let dataStart = Int64(Xiz.superblockSize) + Int64(sb.keysLength)
        var at = try XizArchive.lastFooter(reader, dataStart: dataStart).0
        var out: [Segment] = []
        while true {
            let f = try Xiz.Footer.decode(try reader.read(at: at, count: Xiz.footerSize))
            guard f.catalogOffset >= dataStart, f.catalogOffset + f.catalogCSize == at, f.catalogCSize <= Int64(Xiz.maxCatalog) else {
                throw XipperError.corrupt("XIZ segment chain")
            }
            let bytes = try reader.read(at: f.catalogOffset, count: Int(f.catalogCSize))
            guard Xiz.sha256(bytes) == f.catalogSHA256 else { throw XipperError.corrupt("XIZ directory hash mismatch") }
            let d = try XizDirectory.decode(bytes)
            guard d.version == 3, d.forensicLength <= UInt32(maxBlock), d.forensicOffset >= dataStart,
                  d.forensicOffset + Int64(d.forensicLength) == f.catalogOffset else { throw XipperError.corrupt("XIZ forensic block out of place") }
            let raw = try reader.read(at: d.forensicOffset, count: Int(d.forensicLength))
            guard Xiz.sha256(raw) == d.forensicSHA256 else { throw XipperError.corrupt("XIZ forensic block altered") }
            out.append(Segment(footerOffset: at, footer: f, directory: d, block: try Block.decode(raw)))
            guard f.previousFooter != 0, out.count < 65536 else { break }
            guard Int64(f.previousFooter) < d.forensicOffset else { throw XipperError.corrupt("XIZ segment chain") }
            at = Int64(f.previousFooter)
        }
        out.reverse()
        for (i, s) in out.enumerated() where s.block.segment != UInt32(i) {
            throw XipperError.corrupt("XIZ forensic block of segment \(i) names segment \(s.block.segment)")
        }
        return (sb, out)
    }

    /// The forensic blocks of every segment, oldest first.
    public static func blocks(_ path: String) throws -> [Block] {
        try segments(try FileReader(path: path)).1.map(\.block)
    }

    // MARK: custody

    /// Appends a custody segment (§20.1): who handed the archive to whom, signed by `signer`.
    /// Needs no key to the content. A recovery record at the end of the file is removed (§15.4).
    public static func appendCustody(to path: String, custody: [String: String], signer: XizSigner, now: Date? = nil) throws {
        let reader = try FileReader(path: path)
        let (sb, segs) = try segments(reader)
        guard let last = segs.last else { throw XipperError.corrupt("XIZ segment chain") }
        let segment = UInt32(segs.count)
        let previous = XizSignature.chainDigest(archiveID: sb.archiveID, segment: segment - 1, directory: last.directory,
                                                previousFooter: last.footer.previousFooter)
        let date = now ?? Date()
        var c = custody
        c["time"] = c["time"] ?? timestamp(date)
        let log = Array((logLine("custody", c.filter { $0.key != "time" }, at: date) + "\n").utf8)
        let block = Block(segment: segment, records: [Record(.custody, json(c)), Record(.log, log)]).encode()
        let end = last.footerOffset + Int64(Xiz.footerSize)
        var d = last.directory
        d.flags |= XizDirectory.custodyFlag
        d.forensicOffset = end
        d.forensicLength = UInt32(block.count)
        d.forensicSHA256 = Xiz.sha256(block)
        d.signature = []
        d.signature = try XizSignature.sign(signer, archiveID: sb.archiveID, segment: segment, directory: d, previousFooter: UInt64(end - Int64(Xiz.footerSize)),
                                            previous: previous).encode()
        let dir = d.encode()
        var footer = last.footer
        footer.minor = 10
        footer.catalogOffset = end + Int64(block.count)
        footer.catalogCSize = Int64(dir.count)
        footer.catalogUSize = Int64(dir.count)
        footer.catalogSHA256 = Xiz.sha256(dir)
        footer.previousFooter = UInt64(last.footerOffset)
        let tail = block + dir + footer.encode()

        let fd = open(path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { throw XipperError.posix("open", path) }
        defer { close(fd) }
        // Bytes after the last footer (a recovery record, an interrupted append) go first.
        guard ftruncate(fd, end) == 0 else { throw XipperError.posix("truncate", path) }
        var done = 0
        try tail.withUnsafeBytes { b in
            while done < b.count {
                let n = pwrite(fd, b.baseAddress! + done, b.count - done, end + Int64(done))
                if n < 0 { if errno == EINTR { continue }; throw XipperError.posix("write", path) }
                done += n
            }
        }
        guard OutputFile.fullSync(fd) else { throw XipperError.posix("fsync", path) }
    }

    // MARK: verification (§20.4)

    public struct Check: Sendable {
        public enum Status: String, Sendable { case passed, warning, failed, skipped }
        public var name: String
        public var status: Status
        public var detail: String
    }

    public struct Report: Sendable {
        public var checks: [Check]
        public var signatures: [XizSegmentSignature]
        public var blocks: [Block]
        public var passed: Bool { !checks.contains { $0.status == .failed } }
    }

    /// Checks a forensic archive point by point. Without the password (encrypted archives) the
    /// structure, the frame hashes and the signatures are still checked; the images' content is not.
    public static func verify(_ path: String, password: String? = nil, expectSHA256: [UInt8]? = nil,
                              workload: Workload = .interactive, cancel: CancellationToken? = nil) throws -> Report {
        var checks: [Check] = []
        func add(_ name: String, _ s: Check.Status, _ d: String) { checks.append(Check(name: name, status: s, detail: d)) }
        let reader = try FileReader(path: path)
        let sb: Xiz.Superblock, segs: [Segment]
        do {
            (sb, segs) = try segments(reader)
        } catch {
            add("structure", .failed, "\(error)")
            return Report(checks: checks, signatures: [], blocks: [])
        }
        let dataStart = Int64(Xiz.superblockSize) + Int64(sb.keysLength)
        let frameCount = Int(segs.last!.footer.frameCount)

        // 1. Segments: profile rules, custody segments repeat their predecessor.
        var problems: [String] = []
        if !sb.required.isDisjoint(with: [.dictionaries, .lzma2, .jpeg, .apple, .deflate]) { problems.append("codec features not allowed") }
        for (i, s) in segs.enumerated() {
            if s.directory.flags & XizDirectory.erasableFlag != 0 { problems.append("segment \(i): erasable") }
            guard s.directory.isCustody else { continue }
            guard i > 0 else { problems.append("segment 0 is a custody segment"); continue }
            let p = segs[i - 1]
            if p.directory.groups != s.directory.groups || p.directory.leafOffset != s.directory.leafOffset
                || p.directory.leafCount != s.directory.leafCount || p.directory.merkleRoot != s.directory.merkleRoot
                || p.footer.frameCount != s.footer.frameCount || p.footer.entryCount != s.footer.entryCount
                || p.footer.totalBytes != s.footer.totalBytes || s.directory.forensicOffset != p.footerOffset + Int64(Xiz.footerSize) {
                problems.append("segment \(i): custody segment differs from segment \(i - 1)")
            }
            if !s.block.records(.frameHashes).isEmpty { problems.append("segment \(i): custody segment with frame hashes") }
        }
        if segs.first?.block.records(.caseInfo).isEmpty ?? true { problems.append("no case record in segment 0") }
        add("segments", problems.isEmpty ? .passed : .failed,
            problems.isEmpty ? "\(segs.count) segments, \(segs.filter(\.directory.isCustody).count) of custody" : problems.joined(separator: "; "))

        // 2. Every frame against its signed hash (no key needed: the hash covers what is written).
        var table = [[UInt8]?](repeating: nil, count: frameCount)
        var hashProblems: [String] = []
        for (i, s) in segs.enumerated() {
            let recs = s.block.records(.frameHashes)
            if !s.directory.isCustody && recs.count != 1 { hashProblems.append("segment \(i): \(recs.count) frame hash records") }
            for r in recs {
                guard let fh = try? FrameHashes(r.value) else { hashProblems.append("segment \(i): frame hashes unreadable"); continue }
                if FrameHashes.root(first: fh.first, fh.hashes) != fh.root { hashProblems.append("segment \(i): Merkle root") }
                for (k, h) in fh.hashes.enumerated() {
                    let idx = Int(fh.first) + k
                    guard idx < frameCount, table[idx] == nil else { hashProblems.append("frame \(idx) hashed twice or out of range"); continue }
                    table[idx] = h
                }
            }
        }
        if let missing = table.firstIndex(where: { $0 == nil }) { hashProblems.append("frame \(missing) has no hash") }
        // Walk the frames from the data start, skipping earlier segments' regions.
        var gaps: [Int64: Int64] = [:]
        for s in segs.dropLast() {
            let start = s.directory.isCustody ? s.directory.forensicOffset : (s.directory.groups.map(\.offset).min() ?? s.directory.forensicOffset)
            gaps[start] = s.footerOffset + Int64(Xiz.footerSize)
        }
        var at = dataStart
        var bad: [Int] = []
        for idx in 0..<frameCount {
            try cancel?.check()
            while let e = gaps[at] { at = e }
            guard let header = try? reader.read(at: at, count: Xiz.frameHeaderSize), header.starts(with: Xiz.frameMagic) else {
                hashProblems.append("frame \(idx): no frame header at \(at)"); break
            }
            let csize = Int(header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian })
            let index = Int(header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian })
            guard index == idx, csize <= Xiz.maxFrameData + 4096 else { hashProblems.append("frame \(idx): header"); break }
            let payload = try reader.read(at: at + Int64(Xiz.frameHeaderSize), count: csize)
            if let want = table[idx], FrameHashes.hash(header: header, payload: payload) != want { bad.append(idx) }
            at += Int64(Xiz.frameHeaderSize + csize)
        }
        if !bad.isEmpty { hashProblems.append("\(bad.count) frames altered (first: \(bad.prefix(5).map(String.init).joined(separator: ", ")))") }
        add("frame hashes", hashProblems.isEmpty ? .passed : .failed,
            hashProblems.isEmpty ? "\(frameCount) frames match their signed SHA-256" : hashProblems.joined(separator: "; "))

        // 3. Signatures, chain, time-stamps.
        let sigs = (try? XizSignature.history(path)) ?? []
        let unsigned = sigs.filter { !$0.signed }.map(\.segment), invalid = sigs.filter { $0.signed && !$0.valid }.map(\.segment)
        let broken = sigs.filter { $0.signed && $0.valid && !$0.chained }.map(\.segment)
        if sigs.count != segs.count || !invalid.isEmpty || !broken.isEmpty || !unsigned.isEmpty {
            var d: [String] = []
            if sigs.count != segs.count { d.append("signatures unreadable") }
            if !unsigned.isEmpty { d.append("unsigned segments \(unsigned)") }
            if !invalid.isEmpty { d.append("invalid signatures in segments \(invalid)") }
            if !broken.isEmpty { d.append("chain broken at segments \(broken)") }
            add("signatures", .failed, d.joined(separator: "; "))
        } else {
            add("signatures", .passed, sigs.map { "\($0.segment): \($0.label)" }.joined(separator: ", "))
        }
        let stamped = sigs.filter { $0.timestamp != nil }
        add("time-stamps", stamped.isEmpty ? .skipped : stamped.allSatisfy { $0.timestamp?.trusted ?? false } ? .passed : .warning,
            stamped.isEmpty ? "none requested" : "\(stamped.count) of \(sigs.count) segments")

        // 4. Images: layout, content against the source hashes, unreadable sectors.
        let blocks = segs.map(\.block)
        var sources: [String: SourceHashes] = [:]
        var unreadable: [String: Unreadable] = [:]
        for b in blocks {
            for r in b.records(.sourceHashes) { if let s = try? SourceHashes(r.value) { sources[s.path] = s } }
            for r in b.records(.unreadable) { if let u = try? Unreadable(r.value) { unreadable[u.path] = u } }
        }
        if sb.required.contains(.encrypted) && password == nil && XizCredentials.shared.passwords.isEmpty && XizCredentials.shared.identities.isEmpty {
            add("images", .skipped, "encrypted: the content needs the password or a recipient key")
        } else {
            do {
                let a = try XizArchive(path: path, password: password)
                let images = a.catalog.entries.filter { $0.image != nil }
                var lines: [String] = [], fails: [String] = []
                for e in images {
                    let r = try checkImage(e, a, source: sources[e.path], unreadable: unreadable[e.path], workload: workload, cancel: cancel)
                    if r.failures.isEmpty { lines.append("\(e.path): SHA-256 \(hex(r.sha256))") } else { fails += r.failures.map { "\(e.path): \($0)" } }
                    if let x = expectSHA256, x == r.sha256 { lines.append("\(e.path) matches the expected SHA-256") }
                }
                if images.isEmpty { add("images", .skipped, "no image (logical acquisition)") }
                else { add("images", fails.isEmpty ? .passed : .failed, fails.isEmpty ? lines.joined(separator: "; ") : fails.joined(separator: "; ")) }
                if let x = expectSHA256 {
                    let ok = images.contains { sources[$0.path]?.sha256 == x }
                    add("expected SHA-256", ok ? .passed : .failed, ok ? hex(x) : "\(hex(x)) is not the SHA-256 of any image")
                }
            } catch {
                add("images", .failed, "\(error)")
            }
        }
        return Report(checks: checks, signatures: sigs, blocks: blocks)
    }

    static func checkImage(_ e: Xiz.Entry, _ a: XizArchive, source: SourceHashes?, unreadable: Unreadable?,
                           workload: Workload, cancel: CancellationToken?) throws -> (sha256: [UInt8], failures: [String]) {
        var failures: [String] = []
        let bs = UInt64(e.image!.blockSize)
        guard bs == UInt64(blockSize) else { return ([], ["block size \(bs)"]) }
        // Layout (§20.3): one extent per block, offset 0; each frame its own, or the zero frame.
        let expected = Int((e.size + bs - 1) / bs)
        var uses: [UInt32: Int] = [:]
        for x in a.catalog.entries.flatMap(\.extents) { uses[x.frame, default: 0] += 1 }
        var zeroFrame: UInt32?
        if e.extents.count != expected { failures.append("\(e.extents.count) extents for \(expected) blocks") }
        for (i, x) in e.extents.enumerated() {
            let want = UInt32(min(bs, e.size - UInt64(i) * bs))
            if x.offset != 0 || x.length != want { failures.append("block \(i): extent"); break }
            if uses[x.frame] != 1 {
                if zeroFrame == nil, a.catalog.frames[Int(x.frame)].usize == UInt32(bs), try a.frameData(Int(x.frame)).allSatisfy({ $0 == 0 }) {
                    zeroFrame = x.frame
                } else if zeroFrame != x.frame {
                    failures.append("block \(i): frame \(x.frame) shared but not the zero frame"); break
                }
            }
        }
        // Content: SHA-256 (and MD5/SHA-1 when recorded), unreadable ranges are zeros.
        var sha = SHA256(), md5 = source?.md5 != nil ? Insecure.MD5() : nil, sha1 = source?.sha1 != nil ? Insecure.SHA1() : nil
        let ranges = unreadable?.ranges ?? []
        var pos: UInt64 = 0, ri = 0, nonZero = false
        let cache = FrameCache(a, workload: workload, cancel: cancel)
        try XizExtractor.stream(e, from: a, cache: cache, window: max(4, workload.workerCount * 2), evictable: { UInt32($0) != zeroFrame }) { piece in
            sha.update(bufferPointer: piece); md5?.update(bufferPointer: piece); sha1?.update(bufferPointer: piece)
            let end = pos + UInt64(piece.count)
            while ri < ranges.count, ranges[ri].offset < end {
                let lo = max(ranges[ri].offset, pos), hi = min(ranges[ri].offset + ranges[ri].length, end)
                if lo < hi, !UnsafeRawBufferPointer(rebasing: piece[Int(lo - pos)..<Int(hi - pos)]).allSatisfy({ $0 == 0 }) { nonZero = true }
                if ranges[ri].offset + ranges[ri].length <= end { ri += 1 } else { break }
            }
            pos = end
        }
        let digest = Array(sha.finalize())
        if let s = source {
            if s.size != e.size { failures.append("source size \(s.size), image \(e.size)") }
            if s.sha256 != digest { failures.append("SHA-256 differs from the source's") }
            if let m = md5, Array(m.finalize()) != s.md5 { failures.append("MD5 differs from the source's") }
            if let h = sha1, Array(h.finalize()) != s.sha1 { failures.append("SHA-1 differs from the source's") }
        } else {
            failures.append("no source hashes record")
        }
        for (i, x) in ranges.enumerated() where x.length == 0 || x.offset + x.length > e.size || (i > 0 && ranges[i - 1].offset + ranges[i - 1].length > x.offset) {
            failures.append("unreadable range \(i) out of order or outside the image")
        }
        if nonZero { failures.append("unreadable ranges hold data") }
        return (digest, failures)
    }

    public static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
}
