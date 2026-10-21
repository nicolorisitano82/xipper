import CryptoKit
import Foundation
import Synchronization

// MARK: - Writing

enum TarWriter {
    /// Writes a (compressed) tar. Compression runs in parallel inside the encoder:
    /// zstd and xz with their own worker threads, gzip/bzip2 with chunked parallel encoders.
    static func write(items: [ArchiveItem], to path: String, compression: StreamCompression, level: Int,
                      workload: Workload, overwrite: Bool, extendedAttributes: Bool = true, progress: ProgressHandler?,
                      cancel: CancellationToken?) throws -> WriteReport {
        let tracker = ProgressTracker(totalBytes: items.reduce(0) { $0 + $1.size }, totalEntries: items.count, handler: progress)
        let out = try OutputFile(path: path)
        let encoder = try compression.encoder(level: level, workload: workload, cancel: cancel)
        // Progress follows what the encoder has compressed, not what it has buffered.
        var fed: Int64 = 0, reported: Int64 = 0
        var current: String?
        func report() {
            let done = max(reported, fed - encoder.backlog)
            if done > reported { tracker.add(bytes: done - reported, current: current); reported = done }
        }
        let sink: ByteSink = { try out.write($0); report() }
        encoder.onIdle { report() }
        defer { encoder.onIdle(nil) }  // the closure holds the encoder
        var written: Int64 = 0
        func emit(_ bytes: [UInt8]) throws {
            try bytes.withUnsafeBytes { try encoder.process($0, sink) }
            written += Int64(bytes.count)
        }

        let piece = UnsafeMutableRawPointer.allocate(byteCount: 4 << 20, alignment: 16384)
        defer { piece.deallocate() }
        for item in items {
            try cancel?.check()
            if case let .file(size) = item.kind {
                // Re-check the size: a tar header promises an exact byte count.
                let reader = try FileReader(path: item.sourcePath)
                if reader.size != size {
                    throw XipperError.io("read (file changed while archiving)", path: item.sourcePath, errno: EAGAIN)
                }
                try emit(Tar.headerBlocks(for: item, xattrs: extendedAttributes ? ExtendedAttributes.read(item.sourcePath) : []))
                var off: Int64 = 0
                while off < size {
                    let n = Int(min(Int64(4 << 20), size - off))
                    try reader.read(at: off, into: piece, count: n)
                    try encoder.process(UnsafeRawBufferPointer(start: piece, count: n), sink)
                    off += Int64(n)
                    written += Int64(n)
                    fed += Int64(n)
                    current = item.name
                    report()
                    try cancel?.check()
                }
                try emit([UInt8](repeating: 0, count: Tar.padding(size)))
            } else {
                let isLink = if case .symlink = item.kind { true } else { false }
                try emit(Tar.headerBlocks(for: item, xattrs: extendedAttributes && !isLink ? ExtendedAttributes.read(item.sourcePath) : []))
            }
            tracker.add(bytes: 0, entries: 1)
        }
        // End of archive: two zero blocks, then pad to a full record.
        let end = written + Int64(2 * Tar.block)
        let pad = Int((Int64(Tar.record) - end % Int64(Tar.record)) % Int64(Tar.record))
        try emit([UInt8](repeating: 0, count: 2 * Tar.block + pad))
        try encoder.finish(sink)
        tracker.add(bytes: fed - reported)
        try out.flush()
        try out.commit(overwrite: overwrite)
        tracker.finish()
        return WriteReport(entries: items.count, inputBytes: tracker.completedBytes, outputBytes: out.position, elapsed: tracker.elapsed)
    }

    /// Single file compressed without tar (file.gz, file.zst, …).
    /// `indexPath`: for BGZF, also write a `.gzi` index there (htslib format).
    static func compressSingle(_ item: ArchiveItem, to path: String, compression: StreamCompression, level: Int,
                               workload: Workload, overwrite: Bool, indexPath: String? = nil, progress: ProgressHandler?,
                               cancel: CancellationToken?) throws -> WriteReport {
        guard case let .file(size) = item.kind else { throw XipperError.invalidArgument("only a single file can be compressed without tar") }
        let tracker = ProgressTracker(totalBytes: size, totalEntries: 1, handler: progress)
        let out = try OutputFile(path: path)
        let encoder = try compression.encoder(level: level, workload: workload, cancel: cancel)
        let sink: ByteSink = { try out.write($0) }
        let reader = try FileReader(path: item.sourcePath)
        let piece = UnsafeMutableRawPointer.allocate(byteCount: 4 << 20, alignment: 16384)
        defer { piece.deallocate() }
        var off: Int64 = 0
        while true {
            try cancel?.check()
            let n = try reader.readSome(at: off, into: piece, count: 4 << 20)
            if n == 0 { break }
            try encoder.process(UnsafeRawBufferPointer(start: piece, count: n), sink)
            off += Int64(n)
            tracker.add(bytes: Int64(n), current: item.name)
        }
        try encoder.finish(sink)
        try out.flush()
        try out.commit(overwrite: overwrite)
        if let indexPath, let bgzf = encoder as? BGZFEncoder {
            let idx = try OutputFile(path: indexPath)
            try idx.write(BGZFLayout.gziBytes(bgzf.index))
            try idx.commit(overwrite: true)
        }
        tracker.add(bytes: 0, entries: 1)
        tracker.finish()
        return WriteReport(entries: 1, inputBytes: off, outputBytes: out.position, elapsed: tracker.elapsed)
    }
}

// MARK: - Reading

/// Sequential tar parser over a (decompressing) byte source.
final class TarReader {
    struct Entry {
        var header: Tar.Header
        var entry: ArchiveEntry
    }

    private let source: ByteSource
    private let block = UnsafeMutableRawPointer.allocate(byteCount: Tar.block, alignment: 16)
    private var pendingData: Int64 = 0
    private var pendingPad = 0

    init(source: ByteSource) { self.source = source }
    deinit { block.deallocate() }

    /// Next real entry (pax/GNU metadata records are folded in), or nil at end of archive.
    func next() throws -> Entry? {
        try skipData()
        var pax: [String: String] = [:]
        var paxRaw: [String: [UInt8]] = [:]
        var longName: String?
        var longLink: String?
        while true {
            guard try source.readExactly(into: block, count: Tar.block, allowEOF: true) else { return nil }
            guard var h = try Tar.parseHeader(UnsafeRawBufferPointer(start: block, count: Tar.block)) else {
                return nil  // zero block: end of archive (the second one and record padding are not needed)
            }
            switch h.type {
            case Tar.TypeFlag.paxLocal.rawValue, Tar.TypeFlag.gnuLongName.rawValue, Tar.TypeFlag.gnuLongLink.rawValue,
                 Tar.TypeFlag.paxGlobal.rawValue:
                if h.size > 16 << 20 { throw XipperError.limitExceeded("tar metadata record over 16 MiB") }
                var data = [UInt8](repeating: 0, count: Int(h.size))
                if h.size > 0 { _ = try data.withUnsafeMutableBytes { try source.readExactly(into: $0.baseAddress!, count: Int(h.size)) } }
                try source.skip(Int64(Tar.padding(h.size)))
                switch h.type {
                case Tar.TypeFlag.paxLocal.rawValue:
                    let raw = Tar.parsePaxRaw(data)
                    paxRaw.merge(raw) { $1 }
                    pax.merge(raw.mapValues { String(decoding: $0, as: UTF8.self) }) { $1 }
                case Tar.TypeFlag.gnuLongName.rawValue: longName = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
                case Tar.TypeFlag.gnuLongLink.rawValue: longLink = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
                default: break  // global pax headers carry nothing Xipper uses
                }
                continue
            default:
                break
            }
            if let p = pax["path"] ?? longName { h.path = p }
            if let l = pax["linkpath"] ?? longLink { h.linkTarget = l }
            if let s = pax["size"], let v = Int64(s) { h.size = v }
            if let m = pax["mtime"], let v = Double(m) { h.mtime = Date(timeIntervalSince1970: v) }
            if let u = pax["uid"], let v = UInt32(u) { h.uid = v }
            if let g = pax["gid"], let v = UInt32(g) { h.gid = v }
            for (key, value) in paxRaw.sorted(by: { $0.key < $1.key }) {
                if key.hasPrefix("SCHILY.xattr.") {
                    h.xattrs.append((String(key.dropFirst("SCHILY.xattr.".count)), value))
                } else if key.hasPrefix("LIBARCHIVE.xattr."),
                          let name = String(key.dropFirst("LIBARCHIVE.xattr.".count)).removingPercentEncoding,
                          case let text = String(decoding: value, as: UTF8.self),
                          let decoded = Data(base64Encoded: text + String(repeating: "=", count: (4 - text.count % 4) % 4)) {
                    if !h.xattrs.contains(where: { $0.name == name }) { h.xattrs.append((name, [UInt8](decoded))) }
                }
            }
            if h.size < 0 { throw XipperError.corrupt("negative tar entry size") }

            if h.path.hasSuffix("/") && h.type == Tar.TypeFlag.file.rawValue { h.type = Tar.TypeFlag.directory.rawValue }
            let kind: ArchiveEntry.Kind
            switch h.type {
            case Tar.TypeFlag.directory.rawValue: kind = .directory
            case Tar.TypeFlag.symlink.rawValue: kind = .symlink
            case Tar.TypeFlag.hardlink.rawValue: kind = .hardlink
            default: kind = .file
            }
            var path = h.path
            while path.hasSuffix("/") { path.removeLast() }
            // Links carry no data whatever their size field says; anything else is skipped if unused.
            pendingData = (kind == .symlink || kind == .hardlink) ? 0 : h.size
            pendingPad = Tar.padding(pendingData)
            let entry = ArchiveEntry(path: path, kind: kind, uncompressedSize: kind == .file ? h.size : 0, compressedSize: 0,
                                     modified: h.mtime, permissions: h.mode, encryption: .none, method: "tar",
                                     linkTarget: (kind == .symlink || kind == .hardlink) ? h.linkTarget : nil)
            return Entry(header: h, entry: entry)
        }
    }

    /// Streams the current entry's data.
    func readData(cancel: CancellationToken?, _ sink: ByteSink) throws {
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16384)
        defer { buf.deallocate() }
        while pendingData > 0 {
            try cancel?.check()
            let n = try source.read(into: buf, max: Int(min(pendingData, 1 << 20)))
            if n == 0 { throw XipperError.corrupt("tar entry truncated") }
            pendingData -= Int64(n)
            try sink(UnsafeRawBufferPointer(start: buf, count: n))
        }
        try source.skip(Int64(pendingPad))
        pendingPad = 0
    }

    func skipData() throws {
        if pendingData > 0 || pendingPad > 0 {
            try source.skip(pendingData + Int64(pendingPad))
            pendingData = 0
            pendingPad = 0
        }
    }
}

/// Peeks at a decompressed stream to tell a tar archive from a single compressed file.
final class PeekSource: ByteSource {
    private let inner: ByteSource
    private var peeked: [UInt8]
    private var pos = 0

    init(_ inner: ByteSource, peek count: Int) throws {
        self.inner = inner
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        try buf.withUnsafeMutableBytes { b in
            while got < count {
                let n = try inner.read(into: b.baseAddress! + got, max: count - got)
                if n == 0 { break }
                got += n
            }
        }
        peeked = Array(buf[0..<got])
    }

    var head: [UInt8] { peeked }

    func read(into buf: UnsafeMutableRawPointer, max: Int) throws -> Int {
        if pos < peeked.count {
            let n = min(max, peeked.count - pos)
            peeked.withUnsafeBytes { buf.copyMemory(from: $0.baseAddress! + pos, byteCount: n) }
            pos += n
            return n
        }
        return try inner.read(into: buf, max: max)
    }
}

enum TarExtractor {
    /// Opens `path` as a possibly-compressed stream; reports whether it holds a tar archive.
    static func open(_ path: String, workload: Workload) throws -> (pipe: DecodingPipe, source: PeekSource, isTar: Bool, compression: StreamCompression) {
        let file = try FileReader(path: path)
        let magic = try file.read(at: 0, count: Int(min(file.size, Int64(StreamCompression.detectLength))))
        let compression = StreamCompression.detect(magic, name: (path as NSString).lastPathComponent)
        let pipe = try DecodingPipe(file: file, compression: compression, threads: workload.workerCount,
                                    qos: workload == .background ? .utility : .userInitiated)
        let peek = try PeekSource(pipe, peek: Tar.block)
        // "Tar" here means an archive stream with entries: tar or cpio.
        let isTar = (peek.head.count == Tar.block && peek.head.withUnsafeBytes { Tar.looksLikeHeader($0) })
            || Cpio.looksLikeHeader(peek.head)
        return (pipe, peek, isTar, compression)
    }

    static func extract(_ path: String, ctx: ExtractionContext, tracker: ProgressTracker, cancel: CancellationToken?) throws {
        if AppleArchiveReader.isAppleArchive(path) {
            tracker.setTotals(bytes: 0, entries: 0)
            try extractEntries(try AppleArchiveReader(path: path, password: ctx.options.password), ctx: ctx, tracker: tracker,
                               cancel: cancel, reportCompressed: {})
            return
        }
        let (pipe, source, isTar, compression) = try open(path, workload: ctx.options.workload)
        defer { pipe.close() }
        let fileSize = (try? FileReader(path: path).size) ?? 0
        tracker.setTotals(bytes: fileSize, entries: 0)
        let reportCompressed = { tracker.add(bytes: pipe.compressedRead - tracker.completedBytes) }

        guard isTar else {
            // Single compressed file: name it after the archive without its extension.
            guard compression != .none else { throw XipperError.unsupported("not a recognized archive") }
            let name = singleFileName(path)
            guard let comps = ctx.sanitize(name) else { return }
            try ctx.writeFile(comps, permissions: nil, modified: nil) { sink in
                let buf = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16384)
                defer { buf.deallocate() }
                while true {
                    try cancel?.check()
                    let n = try source.read(into: buf, max: 1 << 20)
                    if n == 0 { break }
                    try sink(UnsafeRawBufferPointer(start: buf, count: n))
                    reportCompressed()
                }
            }
            try ctx.finalize()
            return
        }

        try extractEntries(Cpio.reader(for: source, head: source.head), ctx: ctx, tracker: tracker, cancel: cancel,
                           reportCompressed: reportCompressed, beforeFinalize: { try pipe.drainAndCheck() })
    }

    /// Extracts the entries of a tar, cpio or Apple Archive stream through the safe extraction context.
    static func extractEntries(_ reader: EntryStreamReader, ctx: ExtractionContext, tracker: ProgressTracker,
                               cancel: CancellationToken?, reportCompressed: @escaping () -> Void,
                               beforeFinalize: () throws -> Void = {}) throws {
        let writes = BackgroundWrites(workload: ctx.options.workload)
        defer { writes.waitIgnoringErrors() }
        var count = 0
        while let e = try reader.next() {
            try cancel?.check()
            count += 1
            if count > ctx.options.limits.maxEntries { throw XipperError.limitExceeded("more than \(ctx.options.limits.maxEntries) entries") }
            if let sel = ctx.options.selection, !sel.isEmpty,
               !(sel.contains(e.entry.path) || sel.contains { e.entry.path.hasPrefix($0 + "/") }) {
                continue
            }
            if e.entry.kind == .file, let target = ctx.appleDoubleTarget(e.entry.path, size: e.header.size) {
                var data: [UInt8] = []
                try reader.readData(cancel: cancel) { data.append(contentsOf: $0) }
                reportCompressed()
                ctx.stashAppleDouble(target: target, data: data)
                continue
            }
            guard let full = ctx.sanitize(e.entry.path) else { continue }
            if ctx.options.flatten && e.header.type == Tar.TypeFlag.directory.rawValue { continue }
            let comps = ctx.layout(full)
            switch e.header.type {
            case Tar.TypeFlag.directory.rawValue:
                do { try ctx.makeDirectory(comps, permissions: e.entry.permissions, modified: e.entry.modified) } catch let XipperError.unsafeEntry(p, r) { ctx.skip(p, r, .throughSymlink) }
                ctx.setAttributes(e.header.xattrs, onDirectory: comps)
            case Tar.TypeFlag.symlink.rawValue:
                ctx.addSymlink(comps, target: e.header.linkTarget, modified: e.entry.modified)
            case Tar.TypeFlag.hardlink.rawValue:
                if let target = ctx.sanitize(e.header.linkTarget) { ctx.addHardLink(comps, target: target) }
            case Tar.TypeFlag.file.rawValue, Tar.TypeFlag.contiguous.rawValue:
                if e.header.size <= BackgroundWrites.inlineLimit {
                    // Small file: buffer it and let a worker create it, so file creation
                    // (the slow part, especially under Endpoint Security agents) runs in parallel.
                    var data = [UInt8]()
                    data.reserveCapacity(Int(e.header.size))
                    try reader.readData(cancel: cancel) { data.append(contentsOf: $0) }
                    reportCompressed()
                    let entry = e.entry
                    let attrs = e.header.xattrs
                    let content = data
                    try writes.submit {
                        do {
                            try ctx.writeFile(comps, permissions: entry.permissions, modified: entry.modified,
                                              declaredSize: entry.uncompressedSize, xattrs: attrs) { sink in
                                try content.withUnsafeBytes { try sink($0) }
                            }
                        } catch let XipperError.unsafeEntry(p, r) {
                            ctx.skip(p, r, .throughSymlink)
                        }
                    }
                } else {
                    do {
                        try ctx.writeFile(comps, permissions: e.entry.permissions, modified: e.entry.modified,
                                          declaredSize: e.entry.uncompressedSize, xattrs: e.header.xattrs) { sink in
                            try reader.readData(cancel: cancel) { chunk in
                                try sink(chunk)
                                reportCompressed()
                            }
                        }
                    } catch let XipperError.unsafeEntry(p, r) {
                        ctx.skip(p, r, .throughSymlink)
                    }
                }
            default:
                ctx.skip(e.entry.path, "special file type not extracted", .specialFile)
            }
            tracker.add(bytes: 0, entries: 1, current: e.entry.path)
        }
        try writes.wait()
        try beforeFinalize()
        try ctx.finalize()
    }

    static func list(_ path: String, workload: Workload, password: String? = nil) throws -> [ArchiveEntry] {
        if AppleArchiveReader.isAppleArchive(path) {
            let reader = try AppleArchiveReader(path: path, password: password)
            var out: [ArchiveEntry] = []
            while let e = try reader.next() { out.append(e.entry) }
            return out
        }
        let (pipe, source, isTar, compression) = try open(path, workload: workload)
        defer { pipe.close() }
        guard isTar else {
            guard compression != .none else { throw XipperError.unsupported("not a recognized archive") }
            return [ArchiveEntry(path: singleFileName(path), kind: .file, uncompressedSize: -1, compressedSize: (try? FileReader(path: path).size) ?? 0,
                                 modified: nil, permissions: nil, encryption: .none, method: "\(compression)", linkTarget: nil)]
        }
        let reader = Cpio.reader(for: source, head: source.head)
        var out: [ArchiveEntry] = []
        while let e = try reader.next() { out.append(e.entry) }
        return out
    }

    /// Decompresses and parses everything; codec checksums (gzip CRC, xz CRC64, zstd XXH64,
    /// bzip2 CRC) provide the integrity check, tar itself has none for data.
    static func test(_ path: String, workload: Workload, tracker: ProgressTracker, digests: DigestCollector? = nil,
                     password: String? = nil, cancel: CancellationToken?) throws -> (entries: Int, failures: [SkippedEntry]) {
        var count = 0
        if AppleArchiveReader.isAppleArchive(path) {
            // AppleArchive checks the data as it decodes it; reading every entry is the test.
            do {
                let reader = try AppleArchiveReader(path: path, password: password)
                while let e = try reader.next() {
                    var hasher = digests != nil && e.entry.kind == .file ? SHA256() : nil
                    try reader.readData(cancel: cancel) { chunk in
                        hasher?.update(bufferPointer: chunk)
                        tracker.add(bytes: Int64(chunk.count))
                    }
                    if let hasher { digests?.add(e.entry.path, hasher) }
                    tracker.add(bytes: 0, entries: 1, current: e.entry.path)
                    count += 1
                }
            } catch let e as XipperError where e != .cancelled {
                if case .passwordRequired = e { throw e }
                if case .wrongPassword = e { throw e }
                return (count, [SkippedEntry(path: (path as NSString).lastPathComponent, error: e)])
            }
            return (count, [])
        }
        let (pipe, source, isTar, compression) = try open(path, workload: workload)
        defer { pipe.close() }
        tracker.setTotals(bytes: (try? FileReader(path: path).size) ?? 0, entries: 0)
        do {
            if isTar {
                let reader = Cpio.reader(for: source, head: source.head)
                while let e = try reader.next() {
                    var hasher = digests != nil && e.entry.kind == .file ? SHA256() : nil
                    try reader.readData(cancel: cancel) { chunk in
                        hasher?.update(bufferPointer: chunk)
                        tracker.add(bytes: pipe.compressedRead - tracker.completedBytes)
                    }
                    if let hasher { digests?.add(e.entry.path, hasher) }
                    tracker.add(bytes: 0, entries: 1, current: e.entry.path)
                    count += 1
                }
            } else if compression == .none {
                throw XipperError.unsupported("not a recognized archive")
            } else if let digests {
                // A single compressed file: its digest is the one of the whole decoded stream.
                var hasher = SHA256()
                let buf = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16384)
                defer { buf.deallocate() }
                while case let n = try source.read(into: buf, max: 1 << 20), n > 0 {
                    try cancel?.check()
                    hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: n))
                    tracker.add(bytes: pipe.compressedRead - tracker.completedBytes)
                }
                digests.add(singleFileName(path), hasher)
            }
            try pipe.drainAndCheck()
        } catch let e as XipperError where e != .cancelled {
            if case .unsupported = e { throw e }
            return (count, [SkippedEntry(path: (path as NSString).lastPathComponent, error: e)])
        }
        return (isTar ? count : 1, [])
    }

    static func singleFileName(_ path: String) -> String {
        let base = (path as NSString).lastPathComponent
        for ext in [".gz", ".bgz", ".bz2", ".xz", ".zst", ".lz4", ".br", ".tgz", ".tbz2", ".txz", ".tzst", ".tlz4"] where base.lowercased().hasSuffix(ext) {
            let stem = String(base.dropLast(ext.count))
            return ext.hasPrefix(".t") && ext.count > 4 ? stem + ".tar" : stem
        }
        return base + ".out"
    }
}

/// Bounded pool for writing small extracted files in parallel while the stream is parsed.
final class BackgroundWrites: @unchecked Sendable {
    static let inlineLimit: Int64 = 8 << 20
    private let queue: DispatchQueue
    private let group = DispatchGroup()
    private let slots: DispatchSemaphore
    private let failure = Mutex<Error?>(nil)

    init(workload: Workload) {
        queue = DispatchQueue(label: "xipper.extract.writes", qos: workload == .background ? .utility : .userInitiated,
                              attributes: .concurrent)
        slots = DispatchSemaphore(value: workload.workerCount * 2)
    }

    func submit(_ work: @escaping @Sendable () throws -> Void) throws {
        if let e = failure.withLock({ $0 }) { throw e }
        slots.wait()
        group.enter()
        queue.async {
            defer { self.slots.signal(); self.group.leave() }
            if self.failure.withLock({ $0 }) != nil { return }
            do { try work() } catch { self.failure.withLock { if $0 == nil { $0 = error } } }
        }
    }

    func wait() throws {
        group.wait()
        if let e = failure.withLock({ $0 }) { throw e }
    }

    func waitIgnoringErrors() { group.wait() }
}
