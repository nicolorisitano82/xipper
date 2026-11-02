import Foundation

/// A tar (compressed or not) written entry by entry as the source archive is read: the target
/// of «Cambia formato» in streaming, which never unpacks the source on disk. Entries arrive
/// from the extractors through `ExtractionRedirect`, possibly from several threads: each is
/// written whole under a lock. Folders are written at the end, with their attributes.
final class TarStream: ExtractionRedirect, @unchecked Sendable {
    /// An entry whose size is not declared is held in memory up to this size.
    static let maxBuffered = 256 << 20

    private let out: OutputFile
    private let compression: StreamCompression
    private let level: Int
    private let workload: Workload
    private let cancel: CancellationToken?
    private let tracker: ProgressTracker?
    private var encoder: StreamTransform
    private var written: Int64 = 0
    private let lock = NSLock()
    private let uid = getuid(), gid = getgid()

    init(path: String, compression: StreamCompression, level: Int, workload: Workload, tracker: ProgressTracker?,
         cancel: CancellationToken?) throws {
        out = try OutputFile(path: path)
        self.compression = compression
        self.level = level
        self.workload = workload
        self.cancel = cancel
        self.tracker = tracker
        encoder = try compression.encoder(level: level, workload: workload, cancel: cancel)
    }

    private func sink(_ chunk: UnsafeRawBufferPointer) throws { try out.write(chunk) }

    private func emit(_ chunk: UnsafeRawBufferPointer) throws {
        try encoder.process(chunk, sink)
        written += Int64(chunk.count)
    }

    private func emit(_ bytes: [UInt8]) throws { try bytes.withUnsafeBytes { try emit($0) } }

    private func item(_ path: String, _ kind: ArchiveItem.Kind, permissions: UInt16?, modified: Date?) -> ArchiveItem {
        let defaultMode: UInt16 = kind == .directory ? 0o755 : 0o644
        return ArchiveItem(name: path, sourcePath: "", kind: kind, permissions: (permissions ?? defaultMode) & 0o7777,
                           modified: modified ?? Date(), uid: uid, gid: gid)
    }

    func file(_ path: String, permissions: UInt16?, modified: Date?, size: Int64?,
              xattrs: [(name: String, value: [UInt8])], produce: (ByteSink) throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try cancel?.check()
        guard let size, size >= 0 else {
            // Size unknown until the end: buffered, then written like the others.
            var data: [UInt8] = []
            try produce { chunk in
                guard data.count + chunk.count <= Self.maxBuffered else { throw XipperError.unsupported("\(path): size unknown and larger than \(Self.maxBuffered >> 20) MiB") }
                data.append(contentsOf: chunk)
            }
            try emit(Tar.headerBlocks(for: item(path, .file(size: Int64(data.count)), permissions: permissions, modified: modified), xattrs: xattrs))
            try emit(data)
            try emit([UInt8](repeating: 0, count: Tar.padding(Int64(data.count))))
            tracker?.add(bytes: Int64(data.count), entries: 1, current: path)
            return
        }
        try emit(Tar.headerBlocks(for: item(path, .file(size: size), permissions: permissions, modified: modified), xattrs: xattrs))
        var n: Int64 = 0
        try produce { chunk in
            n += Int64(chunk.count)
            guard n <= size else { throw XipperError.corrupt("\(path) is larger than declared") }
            try self.emit(chunk)
            self.tracker?.add(bytes: Int64(chunk.count), current: path)
        }
        guard n == size else { throw XipperError.truncated(entry: path, read: n, expected: size) }
        try emit([UInt8](repeating: 0, count: Tar.padding(size)))
        tracker?.add(bytes: 0, entries: 1)
    }

    func directory(_ path: String, permissions: UInt16?, modified: Date?, xattrs: [(name: String, value: [UInt8])]) throws {
        lock.lock()
        defer { lock.unlock() }
        try emit(Tar.headerBlocks(for: item(path, .directory, permissions: permissions, modified: modified), xattrs: xattrs))
    }

    func symlink(_ path: String, target: String, modified: Date?) throws {
        lock.lock()
        defer { lock.unlock() }
        try emit(Tar.headerBlocks(for: item(path, .symlink(target: target), permissions: 0o755, modified: modified)))
    }

    /// A file whose data is already one member of the compressed stream (TarCarriedMember).
    func carried(_ item: ArchiveItem, _ m: TarCarriedMember) throws {
        lock.lock()
        defer { lock.unlock() }
        try emit(Tar.headerBlocks(for: item))
        try encoder.finish(sink)
        try out.write(m.prefix)
        var off: Int64 = 0
        while off < m.size {
            try cancel?.check()
            let n = Int(min(Int64(4 << 20), m.size - off))
            try out.write(try m.read(m.offset + off, n))
            off += Int64(n)
        }
        try out.write(m.suffix)
        encoder = try compression.encoder(level: level, workload: workload, cancel: cancel)
        written += item.size
        tracker?.add(bytes: item.size, entries: 1, current: item.name)
        try emit([UInt8](repeating: 0, count: Tar.padding(item.size)))
    }

    /// End of archive (two zero blocks, padded to a record), then the file under its name.
    func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        let end = written + Int64(2 * Tar.block)
        let pad = Int((Int64(Tar.record) - end % Int64(Tar.record)) % Int64(Tar.record))
        try emit([UInt8](repeating: 0, count: 2 * Tar.block + pad))
        try encoder.finish(sink)
        try out.flush()
        try out.commit(overwrite: true)
    }
}
