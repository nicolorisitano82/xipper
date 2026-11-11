import CryptoKit
import Foundation

extension XizForensic {
    /// The image of a forensic archive, read back for export (raw, E01) or a delivery copy: its records
    /// and its bytes in order. The bytes are checked against the source hashes while streaming.
    public struct StoredImage: Sendable {
        public var name: String
        public var size: UInt64
        public var logicalSector: UInt32
        public var physicalSector: UInt32
        public var volume: Bool
        public var volumeOffset: UInt64
        public var source: SourceHashes?
        public var unreadable: [Unreadable.Range]
        public var caseInfo: [String: String]
        public var device: [String: String]
        public var acquisition: [String: String]
        /// SHA-256 of the archive file, for "derived from" records.
        public var archiveSHA256: [UInt8]
    }

    /// The image entry of `path` with the records of its last segment that names it.
    public static func storedImage(_ path: String, password: String? = nil) throws -> StoredImage {
        let a = try XizArchive(path: path, password: password)
        guard let e = a.catalog.entries.first(where: { $0.image != nil }), let img = e.image else {
            throw XipperError.invalidArgument("\(path) holds no forensic image (a logical acquisition is exported with extract)")
        }
        var source: SourceHashes?, unreadable: [Unreadable.Range] = []
        var caseInfo: [String: String] = [:], device: [String: String] = [:], acquisition: [String: String] = [:]
        for b in try blocks(path) {
            for r in b.records(.sourceHashes) { if let s = try? SourceHashes(r.value), s.path == e.path { source = s } }
            for r in b.records(.unreadable) { if let u = try? Unreadable(r.value), u.path == e.path { unreadable = u.ranges } }
            if let r = b.records(.caseInfo).first, let d = try? ForensicJSON.object(r.value), !d.isEmpty { caseInfo = d }
            if let r = b.records(.device).first, let d = try? ForensicJSON.object(r.value), !d.isEmpty { device = d }
            if let r = b.records(.acquisition).first, let d = try? ForensicJSON.object(r.value), !d.isEmpty { acquisition = d }
        }
        return StoredImage(name: e.path, size: e.size, logicalSector: img.logicalSector, physicalSector: img.physicalSector,
                           volume: img.flags & 1 != 0, volumeOffset: img.offset, source: source, unreadable: unreadable,
                           caseInfo: caseInfo, device: device, acquisition: acquisition, archiveSHA256: try fileSHA256(path))
    }

    /// Streams the image's bytes in order to `body`, in pieces of up to one block. Throws if the SHA-256
    /// of what was streamed differs from the source hash recorded at acquisition.
    public static func streamImage(_ path: String, password: String? = nil, workload: Workload = .interactive,
                                   cancel: CancellationToken? = nil, progress: ProgressHandler? = nil,
                                   _ body: (UnsafeRawBufferPointer) throws -> Void) throws {
        let a = try XizArchive(path: path, password: password)
        guard let e = a.catalog.entries.first(where: { $0.image != nil }) else {
            throw XipperError.invalidArgument("\(path) holds no forensic image")
        }
        let info = try storedImage(path, password: password)
        let tracker = ProgressTracker(totalBytes: Int64(e.size), totalEntries: 1, handler: progress)
        var sha = SHA256()
        let cache = FrameCache(a, workload: workload, cancel: cancel)
        let zeroFrame = e.extents.first { x in e.extents.filter { $0.frame == x.frame }.count > 1 }?.frame
        try XizExtractor.stream(e, from: a, cache: cache, window: max(4, workload.workerCount * 2), evictable: { UInt32($0) != zeroFrame }) { piece in
            try cancel?.check()
            sha.update(bufferPointer: piece)
            try body(piece)
            tracker.add(bytes: Int64(piece.count))
        }
        tracker.finish()
        if let s = info.source, s.sha256 != Array(sha.finalize()) {
            throw XipperError.integrity(entry: e.path, detail: "the image read back differs from the source hash")
        }
    }

    static func fileSHA256(_ path: String) throws -> [UInt8] {
        let r = try FileReader(path: path)
        var h = SHA256()
        var off: Int64 = 0
        let step = 8 << 20
        var buf = [UInt8](repeating: 0, count: step)
        while off < r.size {
            let n = Int(min(Int64(step), r.size - off))
            try buf.withUnsafeMutableBytes { try r.read(at: off, into: $0.baseAddress!, count: n) }
            buf.withUnsafeBytes { h.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
            off += Int64(n)
        }
        return Array(h.finalize())
    }
}

enum ForensicJSON {
    static func object(_ b: [UInt8]) throws -> [String: String] {
        guard let o = try JSONSerialization.jsonObject(with: Data(b)) as? [String: String] else { throw XipperError.corrupt("forensic record") }
        return o
    }
}

extension XizForensic {
    /// The image inside a forensic archive as a source for a new acquisition (a delivery copy): read by
    /// block, each frame checked (CRC, authentication) as it is read.
    public static func imageSource(_ path: String, password: String? = nil) throws -> ImageSource {
        let a = try XizArchive(path: path, password: password)
        guard let e = a.catalog.entries.first(where: { $0.image != nil }), let img = e.image else {
            throw XipperError.invalidArgument("\(path) holds no forensic image")
        }
        let bs = UInt64(img.blockSize)
        final class Cache: @unchecked Sendable { let lock = NSLock(); var last: (Int, [UInt8])? }
        let cache = Cache()
        return ImageSource(name: (path as NSString).lastPathComponent, size: e.size, logicalSector: img.logicalSector,
                           physicalSector: img.physicalSector) { off, dst, n in
            var done = 0
            while done < n {
                let pos = off + UInt64(done)
                let block = Int(pos / bs), inBlock = Int(pos % bs)
                guard block < e.extents.count else { return EIO }
                let x = e.extents[block]
                let data: [UInt8]
                if let c = cache.lock.withLock({ cache.last }), c.0 == block { data = c.1 } else {
                    guard let f = try? a.frameData(Int(x.frame)) else { return EIO }
                    data = Array(f[Int(x.offset)..<Int(x.offset + x.length)])
                    cache.lock.withLock { cache.last = (block, data) }
                }
                let take = min(n - done, data.count - inBlock)
                guard take > 0 else { return EIO }
                data.withUnsafeBytes { (dst + done).copyMemory(from: $0.baseAddress! + inBlock, byteCount: take) }
                done += take
            }
            return nil
        }
    }
}
