import Foundation

/// The file tree of a mounted archive (docs/FSKIT.md): the archive's entries, read on demand
/// through `Xipper.streamEntry`, with a copy-on-write overlay on disk for changes.
///
/// - New and modified files live in the overlay folder and shadow the archive's entries.
/// - Deleting an archive entry records a "whiteout": the entry (and, for a folder, everything
///   below it) disappears from the tree.
/// - `save()` rebuilds the archive in its own format with the changes, atomically: the original
///   is replaced only once the new archive is complete.
///
/// Paths are relative, "/"-separated, without a leading slash; "" is the root. Thread-safe.
public final class MountedArchive: @unchecked Sendable {
    public struct Info: Sendable, Equatable {
        public var name: String
        public var isDirectory: Bool
        public var size: Int64
        public var modified: Date
        /// Changes when the content changes (archive CRC or overlay size and date).
        public var etag: String
    }

    public let archive: URL
    public let format: ArchiveFormat
    public let password: String?
    /// False for archives Xipper cannot write back (gz/xz/… single files, lz4, brotli) or when asked.
    public let writable: Bool
    /// Where the overlay and the save staging live; removed by `close()`.
    public let workDirectory: URL

    private let lock = NSLock()
    private var baseFiles: [String: ArchiveEntry] = [:]
    private var baseDirs: Set<String> = [""]
    private var whiteouts: Set<String> = []
    private var dirty = false
    private let mountedAt = Date()
    private var overlay: URL { workDirectory.appendingPathComponent("overlay", isDirectory: true) }

    public init(archive: URL, password: String? = nil, writable: Bool = true, workDirectory: URL? = nil) throws {
        self.archive = archive.standardizedFileURL
        guard let format = try ArchiveFormat.detect(archive) else { throw XipperError.unsupported("not a recognized archive") }
        self.format = format
        self.password = password
        self.writable = writable && format.canCreate && !format.isSingleFile
        self.workDirectory = workDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("Xipper-mount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: true)
        for e in try Xipper.list(archive, password: password) {
            // Same names the safe extraction accepts; symlinks and hard links stay in the archive
            // (and in a saved copy) but WebDAV cannot show them.
            guard let path = Self.normalize(e.path) else { continue }
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty, !baseDirs.contains(parent) {
                baseDirs.insert(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
            switch e.kind {
            case .directory: baseDirs.insert(path)
            case .file: baseFiles[path] = e
            case .symlink, .hardlink: break
            }
        }
    }

    deinit { close() }

    /// Removes the overlay and staging folders (unsaved changes are lost).
    public func close() {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    /// "a/b/c" from any spelling ("/a//b/c/"); nil for "..", "." or NUL components.
    public static func normalize(_ path: String) -> String? {
        var parts: [Substring] = []
        for p in path.split(separator: "/") {
            if p == "." || p == ".." || p.contains("\0") { return nil }
            parts.append(p)
        }
        return parts.joined(separator: "/")
    }

    public var hasChanges: Bool { lock.withLock { dirty } }

    // MARK: reading the tree

    private func hidden(_ path: String) -> Bool {
        whiteouts.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func overlayURL(_ path: String) -> URL { path.isEmpty ? overlay : overlay.appendingPathComponent(path) }

    private func overlayInfo(_ path: String) -> Info? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: overlayURL(path).path) else { return nil }
        let isDir = (a[.type] as? FileAttributeType) == .typeDirectory
        let size = (a[.size] as? NSNumber)?.int64Value ?? 0
        let date = a[.modificationDate] as? Date ?? mountedAt
        return Info(name: (path as NSString).lastPathComponent, isDirectory: isDir, size: isDir ? 0 : size, modified: date,
                    etag: "o\(size)-\(Int64(date.timeIntervalSince1970 * 1000))")
    }

    private func infoLocked(_ path: String) -> Info? {
        if path.isEmpty { return Info(name: "", isDirectory: true, size: 0, modified: mountedAt, etag: "root") }
        if let o = overlayInfo(path) { return o }
        guard !hidden(path) else { return nil }
        if let e = baseFiles[path] {
            let date = e.modified ?? mountedAt
            return Info(name: (path as NSString).lastPathComponent, isDirectory: false, size: max(0, e.uncompressedSize),
                        modified: date, etag: e.crc32.map { "c" + String($0, radix: 16) } ?? "b\(e.uncompressedSize)-\(Int64(date.timeIntervalSince1970))")
        }
        if baseDirs.contains(path) {
            return Info(name: (path as NSString).lastPathComponent, isDirectory: true, size: 0, modified: mountedAt, etag: "d")
        }
        return nil
    }

    public func info(_ path: String) -> Info? { lock.withLock { infoLocked(path) } }

    /// The items directly inside a folder, by name.
    public func children(_ path: String) -> [Info] {
        lock.withLock {
            var names = Set<String>()
            let prefix = path.isEmpty ? "" : path + "/"
            for p in baseFiles.keys where p.hasPrefix(prefix) && !p.dropFirst(prefix.count).contains("/") {
                names.insert(String(p.dropFirst(prefix.count)))
            }
            for p in baseDirs where !p.isEmpty && p.hasPrefix(prefix) && !p.dropFirst(prefix.count).contains("/") {
                names.insert(String(p.dropFirst(prefix.count)))
            }
            if let o = try? FileManager.default.contentsOfDirectory(atPath: overlayURL(path).path) { names.formUnion(o) }
            return names.sorted().compactMap { infoLocked(prefix + $0) }
        }
    }

    /// Streams a file's content from `offset` on.
    public func read(_ path: String, from offset: Int64 = 0, cancel: CancellationToken? = nil,
                     _ body: (UnsafeRawBufferPointer) throws -> Void) throws {
        let (inOverlay, entry): (Bool, ArchiveEntry?) = lock.withLock {
            if overlayInfo(path) != nil { return (true, nil) }
            return (false, hidden(path) ? nil : baseFiles[path])
        }
        if inOverlay {
            let r = try FileReader(path: overlayURL(path).path)
            let buf = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16384)
            defer { buf.deallocate() }
            var off = max(0, offset)
            while off < r.size {
                try cancel?.check()
                let n = try r.readSome(at: off, into: buf, count: 1 << 20)
                if n == 0 { break }
                try body(UnsafeRawBufferPointer(start: buf, count: n))
                off += Int64(n)
            }
            return
        }
        guard let entry else { throw XipperError.invalidArgument("no file named \(path)") }
        try Xipper.streamEntry(archive, path: entry.path, password: password, from: offset, cancel: cancel, body)
    }

    // MARK: changes

    private func requireWritable() throws {
        guard writable else { throw XipperError.io("write (read-only archive)", path: archive.path, errno: EROFS) }
    }

    private func requireParent(_ path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        guard infoLocked(parent)?.isDirectory == true else { throw XipperError.io("create (no parent folder)", path: path, errno: ENOENT) }
        try FileManager.default.createDirectory(at: overlayURL(parent), withIntermediateDirectories: true)
    }

    /// A new file in the overlay: write it with `fill` (which gets a handle on a temporary file),
    /// then it replaces `path` atomically. Returns true when `path` did not exist.
    @discardableResult
    public func write(_ path: String, _ fill: (FileHandle) throws -> Void) throws -> Bool {
        try requireWritable()
        guard !path.isEmpty else { throw XipperError.io("write (root)", path: path, errno: EISDIR) }
        let temp = workDirectory.appendingPathComponent("upload-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: temp) }
        let handle = try FileHandle(forWritingTo: temp)
        do { try fill(handle) } catch { try? handle.close(); throw error }
        try handle.close()
        return try lock.withLock {
            let existing = infoLocked(path)
            if existing?.isDirectory == true { throw XipperError.io("write (is a folder)", path: path, errno: EISDIR) }
            try requireParent(path)
            let dest = overlayURL(path)
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: temp, to: dest)
            dirty = true
            return existing == nil
        }
    }

    public func makeDirectory(_ path: String) throws {
        try requireWritable()
        try lock.withLock {
            guard !path.isEmpty, infoLocked(path) == nil else { throw XipperError.alreadyExists(path: path) }
            try requireParent(path)
            try FileManager.default.createDirectory(at: overlayURL(path), withIntermediateDirectories: true)
            dirty = true
        }
    }

    public func delete(_ path: String) throws {
        try requireWritable()
        try lock.withLock { try deleteLocked(path) }
    }

    private func deleteLocked(_ path: String) throws {
        guard !path.isEmpty, infoLocked(path) != nil else { throw XipperError.io("delete (not found)", path: path, errno: ENOENT) }
        try? FileManager.default.removeItem(at: overlayURL(path))
        let prefix = path + "/"
        if baseFiles[path] != nil || baseDirs.contains(path) || baseFiles.keys.contains(where: { $0.hasPrefix(prefix) }) {
            whiteouts = whiteouts.filter { !$0.hasPrefix(prefix) }
            whiteouts.insert(path)
        }
        dirty = true
    }

    /// Copies a file or folder (recursively) to `destination`; with `overwrite` an existing
    /// destination is replaced. Returns true when the destination did not exist.
    @discardableResult
    public func copy(_ source: String, to destination: String, overwrite: Bool) throws -> Bool {
        try requireWritable()
        guard let src = info(source) else { throw XipperError.io("copy (not found)", path: source, errno: ENOENT) }
        if destination == source || destination.hasPrefix(source + "/") {
            throw XipperError.io("copy (into itself)", path: destination, errno: EINVAL)
        }
        let existed = info(destination) != nil
        if existed {
            guard overwrite else { throw XipperError.alreadyExists(path: destination) }
            try delete(destination)
        }
        if src.isDirectory {
            try makeDirectory(destination)
            for c in children(source) {
                try copy(source.isEmpty ? c.name : source + "/" + c.name, to: destination + "/" + c.name, overwrite: false)
            }
        } else {
            try write(destination) { h in try read(source) { try h.write(contentsOf: Data($0)) } }
        }
        return !existed
    }

    @discardableResult
    public func move(_ source: String, to destination: String, overwrite: Bool) throws -> Bool {
        let created = try copy(source, to: destination, overwrite: overwrite)
        try delete(source)
        return created
    }

    // MARK: saving

    /// Rebuilds the archive with the changes, in its format and with its password. The original is
    /// replaced only when the new one is complete; symlinks and hard links of untouched folders
    /// are kept, Finder's ._ and .DS_Store files are left out.
    public func save(progress: ProgressHandler? = nil, cancel: CancellationToken? = nil) throws {
        try requireWritable()
        let (outs, changed) = lock.withLock { (whiteouts, dirty) }
        guard changed else { return }
        let staging = workDirectory.appendingPathComponent("save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        if !baseFiles.isEmpty || baseDirs.count > 1 {
            var x = ExtractOptions()
            x.password = password
            x.overwrite = .replace
            x.propagateQuarantine = false
            _ = try Xipper.extract(archive, to: staging, mode: .into, options: x, cancel: cancel)
        }
        for w in outs { try? FileManager.default.removeItem(at: staging.appendingPathComponent(w)) }
        try merge(overlay, into: staging)

        let top = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != ".DS_Store" && !$0.lastPathComponent.hasPrefix("._") }
        guard !top.isEmpty else { throw XipperError.invalidArgument("the archive would be empty") }
        var o = CreateOptions()
        o.format = format
        o.password = password
        o.overwrite = true
        _ = try Xipper.create(from: top.sorted { $0.lastPathComponent < $1.lastPathComponent }, to: archive, options: o,
                              progress: progress, cancel: cancel)
        lock.withLock { dirty = false }
    }

    /// Copies the overlay over the extracted tree: folders merge, files replace.
    private func merge(_ from: URL, into to: URL) throws {
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: from.path) {
            let s = from.appendingPathComponent(name), d = to.appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: s.path, isDirectory: &isDir)
            var destIsDir: ObjCBool = false
            let destExists = fm.fileExists(atPath: d.path, isDirectory: &destIsDir)
            if isDir.boolValue {
                if destExists && !destIsDir.boolValue { try fm.removeItem(at: d) }
                if !destExists || !destIsDir.boolValue { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
                try merge(s, into: d)
            } else {
                if destExists || (try? fm.destinationOfSymbolicLink(atPath: d.path)) != nil { try fm.removeItem(at: d) }
                try fm.copyItem(at: s, to: d)
            }
        }
    }
}
