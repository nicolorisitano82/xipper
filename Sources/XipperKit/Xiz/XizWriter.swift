import CryptoKit
import Foundation
import Synchronization

/// Writes XIZ v0: dedup of identical files, small files packed into shared frames, big files split,
/// frames compressed in parallel (windows of 2× the workers) and written in order.
enum XizWriter {
    /// One piece of a source file inside a frame.
    private struct Segment {
        var item: Int
        var fileOffset: Int64
        var length: Int
    }

    static func write(items: [ArchiveItem], to path: String, level: Int, extendedAttributes: Bool, workload: Workload,
                      overwrite: Bool, progress: ProgressHandler?, cancel: CancellationToken?) throws -> WriteReport {
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        let tracker = ProgressTracker(totalBytes: total, totalEntries: items.count, handler: progress)

        // 1. Whole-file dedup: only files whose size occurs more than once are hashed.
        var bySize: [Int64: [Int]] = [:]
        for (i, item) in items.enumerated() where item.size > 0 { if case .file = item.kind { bySize[item.size, default: []].append(i) } }
        let candidates = bySize.values.filter { $0.count > 1 }.flatMap { $0 }
        let hashes = Mutex<[Int: [UInt8]]>([:])
        try parallelFor(candidates.count, workload: workload, cancel: cancel) { k in
            let i = candidates[k]
            let r = try FileReader(path: items[i].sourcePath)
            var h = SHA256()
            let buf = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16384)
            defer { buf.deallocate() }
            var off: Int64 = 0
            while off < r.size {
                let n = try r.readSome(at: off, into: buf, count: 1 << 20)
                if n == 0 { break }
                h.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: n))
                off += Int64(n)
            }
            let digest = Array(h.finalize())
            hashes.withLock { $0[i] = digest }
        }
        let digests = hashes.withLock { $0 }

        // 2. Plan: frames of segments, entries with extents (duplicates point at the first copy).
        var frames: [[Segment]] = []
        var current: [Segment] = []
        var currentSize = 0
        var entries: [Xiz.Entry] = []
        var firstCopy: [[UInt8]: [Xiz.Extent]] = [:]
        func closeFrame() {
            if !current.isEmpty { frames.append(current); current = []; currentSize = 0 }
        }
        for (i, item) in items.enumerated() {
            let t = item.modified.timeIntervalSince1970
            let sec = Int64(t.rounded(.down))
            var e = Xiz.Entry(type: .file, path: item.name, mode: item.permissions, uid: item.uid, gid: item.gid,
                              mtimeSec: sec, mtimeNsec: UInt32(clamping: Int64((t - Double(sec)) * 1e9)), size: 0, link: "",
                              xattrs: [], extents: [], sha256: digests[i])
            switch item.kind {
            case .directory:
                e.type = .directory
            case let .symlink(target):
                e.type = .symlink
                e.link = target
            case let .file(size):
                e.size = UInt64(size)
                if let d = digests[i], let extents = firstCopy[d] {
                    e.extents = extents  // identical content stored once
                } else {
                    var off: Int64 = 0
                    while off < size {
                        if currentSize == Xiz.frameData { closeFrame() }
                        let n = Int(min(Int64(Xiz.frameData - currentSize), size - off))
                        e.extents.append(Xiz.Extent(frame: UInt32(frames.count), offset: UInt32(currentSize), length: UInt32(n)))
                        current.append(Segment(item: i, fileOffset: off, length: n))
                        currentSize += n
                        off += Int64(n)
                    }
                    if let d = digests[i] { firstCopy[d] = e.extents }
                }
            }
            if extendedAttributes, e.type != .symlink { e.xattrs = ExtendedAttributes.read(item.sourcePath) }
            entries.append(e)
        }
        closeFrame()

        // 3. Frames, compressed in parallel windows and written in order.
        if !overwrite && FileManager.default.fileExists(atPath: path) { throw XipperError.alreadyExists(path: path) }
        let out = try OutputFile(path: path)
        try out.write(Xiz.superblock())
        var catalog = Xiz.Catalog()
        let window = max(2, workload.workerCount * 2)
        var start = 0
        while start < frames.count {
            try cancel?.check()
            let end = min(frames.count, start + window)
            let results = Mutex<[Int: (Xiz.Frame, [UInt8])]>([:])
            try parallelFor(end - start, workload: workload, cancel: cancel) { k in
                let idx = start + k
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
                if level > 0, let c = data.withUnsafeBytes({ ZipWriter.zstdCompress($0, level: level) }) {
                    codec = .zstd
                    payload = c
                }
                let f = Xiz.Frame(offset: 0, csize: UInt32(payload.count), usize: UInt32(data.count),
                                  crc: Xiz.crc32c(payload), codec: codec)
                results.withLock { $0[idx] = (f, payload) }
                tracker.add(bytes: Int64(data.count))
            }
            let done = results.withLock { $0 }
            for idx in start..<end {
                guard var (f, payload) = done[idx] else { throw XipperError.codec("missing XIZ frame") }
                f.offset = out.position
                try out.write(Xiz.frameHeader(index: UInt32(idx), f))
                try payload.withUnsafeBytes { try out.write($0) }
                catalog.frames.append(f)
            }
            start = end
        }

        // 4. Catalog (zstd) and footer.
        catalog.entries = entries
        let raw = Xiz.encodeCatalog(catalog)
        let packed = raw.withUnsafeBytes { ZipWriter.zstdCompress($0, level: 9, allowExpansion: true) } ?? raw
        let catalogOffset = out.position
        try packed.withUnsafeBytes { try out.write($0) }
        let footer = Xiz.Footer(catalogOffset: catalogOffset, catalogCSize: Int64(packed.count), catalogUSize: Int64(raw.count),
                                frameCount: UInt32(catalog.frames.count), entryCount: UInt32(entries.count),
                                totalBytes: UInt64(entries.reduce(UInt64(0)) { $0 + $1.size }), catalogSHA256: Xiz.sha256(packed))
        try out.write(footer.encode())
        let size = out.position
        try out.commit(overwrite: overwrite)
        tracker.add(bytes: 0, entries: items.count)
        tracker.finish()
        return WriteReport(entries: items.count, inputBytes: total, outputBytes: size, elapsed: tracker.elapsed)
    }
}
