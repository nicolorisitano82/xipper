import Foundation

/// One change to an archive's content (`Xipper.edit`). Paths are "/"-separated, relative.
public enum ArchiveChange: Sendable, Equatable {
    /// A file or a folder with everything inside it.
    case delete(String)
    /// A file or a folder; the new path must not exist.
    case rename(String, to: String)
    /// A file or folder from disk, stored at path `as`. A folder merges into an existing folder of
    /// the same path; a file replaces the entry with its path.
    case add(URL, as: String)
    case makeDirectory(String)
}

public struct EditReport: Sendable {
    /// Entries in the archive after the edit.
    public var entries: Int
    /// Entries carried over without decompressing or recompressing them.
    public var copied: Int
    /// Entries compressed anew (added or replaced).
    public var compressed: Int
    /// True when the format needed the whole archive rebuilt (everything recompressed).
    public var rebuilt: Bool
    public var outputBytes: Int64
}

extension Xipper {
    /// Changes an archive's content without unpacking it by hand: entries are deleted, renamed,
    /// added or replaced. ZIP keeps every untouched entry's compressed (and encrypted) bytes as
    /// they are and only compresses what is new; the other formats are rebuilt in their format,
    /// with their password. The original is replaced atomically, only when the new archive is complete.
    /// XIZ edits in place: the changes are appended as a new segment (XIZ 1.1) and nothing
    /// already written is touched; `compact` rewrites it instead, dropping deleted data.
    /// `options` sets how new entries are compressed (its format and password are ignored).
    @discardableResult
    public static func edit(_ archive: URL, changes: [ArchiveChange], password: String? = nil,
                            options: CreateOptions = CreateOptions(), compact: Bool = false, progress: ProgressHandler? = nil,
                            cancel: CancellationToken? = nil) throws -> EditReport {
        guard let format = try ArchiveFormat.detect(archive) else { throw XipperError.unsupported("not a recognized archive") }
        guard format.canCreate, !format.isSingleFile else {
            throw XipperError.unsupported("\(format.rawValue) archives cannot be edited (Xipper does not write them as archives)")
        }
        let path = archive.standardizedFileURL.path
        let originals = try list(archive, password: password).filter { !$0.isAppleDoubleMetadata || format != .zip }
        let tree = try EditTree(originals, changes: changes, archivePath: path, scan: options.scan)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Xipper-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var o = options
        o.format = format
        o.password = password
        o.overwrite = true
        if format == .zip && ZipArchive.volumes(for: path).count == 1 {
            return try ZipEditor.apply(tree, to: path, options: o, work: work, progress: progress, cancel: cancel)
        }
        if format == .xiz && !compact {
            return try XizEditor.apply(tree, to: path, options: o, progress: progress, cancel: cancel)
        }
        return try rebuild(tree, archive: archive, options: o, work: work, progress: progress, cancel: cancel)
    }

    /// Formats without raw copy: extract, rearrange on disk, create again, replace.
    private static func rebuild(_ tree: EditTree, archive: URL, options: CreateOptions, work: URL,
                                progress: ProgressHandler?, cancel: CancellationToken?) throws -> EditReport {
        let fm = FileManager.default
        let old = work.appendingPathComponent("old", isDirectory: true), new = work.appendingPathComponent("new", isDirectory: true)
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        if tree.usesOriginals {
            var x = ExtractOptions()
            x.password = options.password
            x.overwrite = .replace
            x.propagateQuarantine = false
            _ = try extract(archive, to: old, mode: .into, options: x, cancel: cancel)
        }
        for key in tree.order {
            guard let node = tree.nodes[key] else { continue }
            let dest = new.appendingPathComponent(key)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch node {
            case let .original(entry):
                if entry.kind == .directory { try fm.createDirectory(at: dest, withIntermediateDirectories: true); continue }
                let src = old.appendingPathComponent(entry.path)
                if (try? src.checkResourceIsReachable()) == true || (try? fm.destinationOfSymbolicLink(atPath: src.path)) != nil {
                    try fm.moveItem(at: src, to: dest)
                }
            case let .disk(item):
                switch item.kind {
                case .directory: try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                case let .symlink(target): try fm.createSymbolicLink(atPath: dest.path, withDestinationPath: target)
                case .file: try fm.copyItem(atPath: item.sourcePath, toPath: dest.path)
                }
            case .newDirectory:
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            }
        }
        let top = try fm.contentsOfDirectory(at: new, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !top.isEmpty else { throw XipperError.invalidArgument("the archive would be empty") }
        let r = try create(from: top, to: archive, options: options, progress: progress, cancel: cancel)
        return EditReport(entries: r.entries, copied: 0, compressed: r.entries, rebuilt: true, outputBytes: r.outputBytes)
    }
}

/// The archive's content after the changes: every path and where its data comes from.
struct EditTree {
    enum Node {
        case original(ArchiveEntry)
        case disk(ArchiveItem)
        case newDirectory
    }

    private(set) var nodes: [String: Node] = [:]
    /// Original entries first (in archive order), then new ones in the order they were added.
    private(set) var order: [String] = []

    var usesOriginals: Bool { nodes.values.contains { if case .original = $0 { true } else { false } } }

    init(_ entries: [ArchiveEntry], changes: [ArchiveChange], archivePath: String, scan: ScanOptions) throws {
        for e in entries {
            guard let p = MountedArchive.normalize(e.path), !p.isEmpty, nodes[p] == nil else { continue }
            insert(p, .original(e))
        }
        for change in changes {
            switch change {
            case let .delete(raw):
                let p = try Self.path(raw)
                guard exists(p) else { throw XipperError.invalidArgument("no entry named \(p)") }
                remove(p)
            case let .rename(rawFrom, rawTo):
                let from = try Self.path(rawFrom), to = try Self.path(rawTo)
                guard exists(from) else { throw XipperError.invalidArgument("no entry named \(from)") }
                guard !exists(to) else { throw XipperError.alreadyExists(path: to) }
                guard !(to + "/").hasPrefix(from + "/") else { throw XipperError.invalidArgument("cannot move \(from) into itself") }
                let moved = order.filter { $0 == from || $0.hasPrefix(from + "/") }
                for k in moved {
                    let node = nodes.removeValue(forKey: k)!
                    let target = to + k.dropFirst(from.count)
                    nodes[target] = node
                    order[order.firstIndex(of: k)!] = target
                }
            case let .add(url, rawDest):
                let dest = try Self.path(rawDest)
                let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
                guard resolved != archivePath else { throw XipperError.invalidArgument("the archive cannot contain itself") }
                let items = try SourceScanner.scan([url], options: scan)
                let rootName = url.lastPathComponent
                for var item in items {
                    let rest = item.name.dropFirst(rootName.count)
                    item.name = dest + rest
                    if case .directory = item.kind, case .original? = nodes[item.name] { continue }  // folders merge
                    if case .directory = item.kind, case .newDirectory? = nodes[item.name] { continue }
                    // A file replaces whatever has its path (a folder there goes, with its content).
                    if exists(item.name) { remove(item.name) }
                    insert(item.name, .disk(item))
                }
            case let .makeDirectory(raw):
                let p = try Self.path(raw)
                guard !exists(p) else { throw XipperError.alreadyExists(path: p) }
                insert(p, .newDirectory)
            }
        }
    }

    private static func path(_ raw: String) throws -> String {
        guard let p = MountedArchive.normalize(raw), !p.isEmpty else { throw XipperError.invalidArgument("invalid path \(raw)") }
        return p
    }

    /// Explicit entry, or a folder implied by the paths below it.
    func exists(_ p: String) -> Bool { nodes[p] != nil || order.contains { $0.hasPrefix(p + "/") } }

    private mutating func insert(_ p: String, _ node: Node) {
        if nodes[p] == nil { order.append(p) }
        nodes[p] = node
    }

    private mutating func remove(_ p: String) {
        for k in order where k == p || k.hasPrefix(p + "/") { nodes.removeValue(forKey: k) }
        order.removeAll { $0 == p || $0.hasPrefix(p + "/") }
    }
}

/// ZIP without recompression: untouched entries keep their local header, data and data descriptor
/// byte for byte (only the name changes on rename); new entries are compressed by ZipWriter into a
/// temporary archive and copied the same way; the central directory is written anew.
enum ZipEditor {
    static func apply(_ tree: EditTree, to path: String, options: CreateOptions, work: URL,
                      progress: ProgressHandler?, cancel: CancellationToken?) throws -> EditReport {
        let original = try ZipArchive(path: path)
        var byPath: [String: Int] = [:]
        for (i, r) in original.records.enumerated() {
            if let p = MountedArchive.normalize(r.entry.path), byPath[p] == nil { byPath[p] = i }
        }
        // New entries (files from disk, new folders) go through the normal writer first.
        var fresh: [ArchiveItem] = []
        let placeholder = work.appendingPathComponent("dir", isDirectory: true)
        try FileManager.default.createDirectory(at: placeholder, withIntermediateDirectories: true)
        for key in tree.order {
            switch tree.nodes[key] {
            case let .disk(item)?: fresh.append(item)
            case .newDirectory?:
                fresh.append(ArchiveItem(name: key, sourcePath: placeholder.path, kind: .directory, permissions: 0o755,
                                         modified: Date(), uid: getuid(), gid: getgid()))
            default: break
            }
        }
        var added: ZipArchive?
        if !fresh.isEmpty {
            let temp = work.appendingPathComponent("new.zip").path
            var z = ZipOptions()
            z.method = options.zipMethod
            z.level = options.level ?? (options.zipMethod == .zstd ? 3 : ArchiveFormat.zip.defaultLevel)
            z.password = options.password
            z.legacyZipCrypto = options.legacyZipCrypto
            z.storeAlreadyCompressed = options.storeAlreadyCompressed
            z.workload = options.workload
            _ = try ZipWriter.write(items: fresh, to: temp, options: z, overwrite: true, progress: progress, cancel: cancel)
            added = try ZipArchive(path: temp)
        }
        var addedByPath: [String: Int] = [:]
        for (i, r) in (added?.records ?? []).enumerated() { addedByPath[r.entry.path] = i }

        let out = try OutputFile(path: path)
        var central = ByteWriter(capacity: 1 << 16)
        var count = 0, copied = 0
        for key in tree.order {
            try cancel?.check()
            switch tree.nodes[key] {
            case let .original(entry)?:
                guard let i = byPath[MountedArchive.normalize(entry.path) ?? ""] else { continue }
                let rec = original.records[i]
                let name = rec.entry.kind == .directory ? key + "/" : key
                try copy(rec, from: original, name: name, renamed: name != rec.entry.path + (rec.entry.kind == .directory ? "/" : ""),
                         to: out, central: &central)
                copied += 1
            case .disk?, .newDirectory?:
                guard let added, let i = addedByPath[key] else { continue }
                let rec = added.records[i]
                try copy(rec, from: added, name: String(decoding: rec.rawName, as: UTF8.self), renamed: false, to: out, central: &central)
            case nil:
                continue
            }
            count += 1
        }
        try finish(out, central: central.bytes, count: count, forceZip64: options.forceZip64)
        let size = out.position
        try out.commit(overwrite: true)
        return EditReport(entries: count, copied: copied, compressed: count - copied, rebuilt: false, outputBytes: size)
    }

    /// Copies one entry: local header (with `name`), data, data descriptor; adds its central record.
    private static func copy(_ rec: ZipEntryRecord, from zip: ZipArchive, name: String, renamed: Bool,
                             to out: OutputFile, central: inout ByteWriter) throws {
        let fixed = try zip.reader.read(at: rec.localHeaderOffset, count: 30)
        let (sig, nameLen, extraLen) = fixed.withUnsafeBytes {
            ($0.loadUnaligned(as: UInt32.self).littleEndian, Int($0.loadUnaligned(fromByteOffset: 26, as: UInt16.self).littleEndian),
             Int($0.loadUnaligned(fromByteOffset: 28, as: UInt16.self).littleEndian))
        }
        guard sig == Zip.localSignature else { throw XipperError.corrupt("bad local header for \(rec.entry.path)") }
        var localExtra = try zip.reader.read(at: rec.localHeaderOffset + 30 + Int64(nameLen), count: extraLen)
        let dataStart = rec.localHeaderOffset + 30 + Int64(nameLen) + Int64(extraLen)
        let localZip64 = Self.has(localExtra, Zip.Extra.zip64)
        // Data descriptor (bit 3): copied as is; it may or may not start with its signature.
        var descriptor = 0
        if rec.flags & 0x0008 != 0 {
            let afterData = dataStart + rec.compressedSize
            let peek = try zip.reader.read(at: afterData, count: 4)
            let signed = peek.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian } == 0x0807_4B50
            let sizes = localZip64 || rec.compressedSize >= 0xFFFF_FFFF || rec.uncompressedSize >= 0xFFFF_FFFF ? 16 : 8
            descriptor = (signed ? 4 : 0) + 4 + sizes
        }
        let nameBytes = Array(name.utf8)
        var flags = rec.flags
        if renamed {
            localExtra = strip(localExtra, Zip.Extra.unicodePath)  // its CRC is of the old name
            if nameBytes.contains(where: { $0 >= 0x80 }) { flags |= Zip.Flag.utf8 }
        }
        let headerOffset = out.position
        var local = ByteWriter(capacity: 30 + nameBytes.count + localExtra.count)
        local.append(Array(fixed[0..<6])); local.u16(flags); local.append(Array(fixed[8..<26]))
        local.u16(UInt16(nameBytes.count)); local.u16(UInt16(localExtra.count)); local.append(nameBytes); local.append(localExtra)
        try out.write(local.bytes)
        // Data and descriptor, streamed.
        var off = dataStart
        let end = dataStart + rec.compressedSize + Int64(descriptor)
        while off < end {
            let n = Int(min(Int64(4 << 20), end - off))
            try out.write(try zip.reader.read(at: off, count: n))
            off += Int64(n)
        }
        // Central record with the new name and offset; ZIP64 fields only where they overflow.
        let c = rec.central
        var extra = strip(strip(c.extra, Zip.Extra.zip64), renamed ? Zip.Extra.unicodePath : 0)
        var z64 = ByteWriter(capacity: 24)
        let bigU = rec.uncompressedSize >= 0xFFFF_FFFF, bigC = rec.compressedSize >= 0xFFFF_FFFF, bigO = headerOffset >= 0xFFFF_FFFF
        if bigU { z64.u64(UInt64(rec.uncompressedSize)) }
        if bigC { z64.u64(UInt64(rec.compressedSize)) }
        if bigO { z64.u64(UInt64(headerOffset)) }
        if !z64.bytes.isEmpty {
            var e = ByteWriter(capacity: 4 + z64.bytes.count)
            e.u16(Zip.Extra.zip64); e.u16(UInt16(z64.bytes.count)); e.append(z64.bytes)
            extra = e.bytes + extra
        }
        central.u32(Zip.centralSignature); central.u16(c.versionMadeBy)
        central.u16(z64.bytes.isEmpty ? c.versionNeeded : max(c.versionNeeded, 45))
        central.u16(flags); central.u16(rec.method); central.u16(rec.dosTime); central.u16(c.dosDate); central.u32(rec.crc)
        central.u32(bigC ? UInt32.max : UInt32(rec.compressedSize)); central.u32(bigU ? UInt32.max : UInt32(rec.uncompressedSize))
        central.u16(UInt16(nameBytes.count)); central.u16(UInt16(extra.count)); central.u16(UInt16(c.comment.count))
        central.u16(0); central.u16(c.internalAttributes); central.u32(c.externalAttributes)
        central.u32(bigO ? UInt32.max : UInt32(headerOffset))
        central.append(nameBytes); central.append(extra); central.append(c.comment)
    }

    private static func fields(_ extra: [UInt8]) -> [(id: UInt16, bytes: ArraySlice<UInt8>)] {
        var out: [(UInt16, ArraySlice<UInt8>)] = []
        var i = 0
        while i + 4 <= extra.count {
            let id = UInt16(extra[i]) | UInt16(extra[i + 1]) << 8
            let len = Int(UInt16(extra[i + 2]) | UInt16(extra[i + 3]) << 8)
            guard i + 4 + len <= extra.count else { break }
            out.append((id, extra[i..<(i + 4 + len)]))
            i += 4 + len
        }
        return out
    }

    private static func has(_ extra: [UInt8], _ id: UInt16) -> Bool { fields(extra).contains { $0.id == id } }

    private static func strip(_ extra: [UInt8], _ id: UInt16) -> [UInt8] {
        guard id != 0 else { return extra }
        return fields(extra).filter { $0.id != id }.flatMap { Array($0.bytes) }
    }

    private static func finish(_ out: OutputFile, central: [UInt8], count: Int, forceZip64: Bool) throws {
        let cdOffset = out.position
        try out.write(central)
        let cdSize = Int64(central.count)
        let needs64 = forceZip64 || UInt64(count) >= Zip.max16 || UInt64(cdOffset) >= Zip.max32 || UInt64(cdSize) >= Zip.max32
        var w = ByteWriter()
        if needs64 {
            let z64Offset = out.position
            w.u32(Zip.zip64EndSignature); w.u64(44); w.u16(Zip.versionMadeBy); w.u16(45)
            w.u32(0); w.u32(0); w.u64(UInt64(count)); w.u64(UInt64(count)); w.u64(UInt64(cdSize)); w.u64(UInt64(cdOffset))
            w.u32(Zip.zip64LocatorSignature); w.u32(0); w.u64(UInt64(z64Offset)); w.u32(1)
        }
        let n16 = needs64 ? UInt16.max : UInt16(count)
        w.u32(Zip.endSignature); w.u16(0); w.u16(0); w.u16(n16); w.u16(n16)
        w.u32(needs64 ? UInt32.max : UInt32(cdSize)); w.u32(needs64 ? UInt32.max : UInt32(cdOffset)); w.u16(0)
        try out.write(w.bytes)
        try out.flush()
    }
}

/// XIZ in place (format 1.1, docs/XIZ_SPEC.md §11): new frames, then a complete new catalog and a
/// footer pointing at the previous one, all written after the current end. Untouched entries keep
/// pointing at their frames; new content is deduplicated against what the archive already holds.
enum XizEditor {
    static func apply(_ tree: EditTree, to path: String, options: CreateOptions, progress: ProgressHandler?,
                      cancel: CancellationToken?) throws -> EditReport {
        let a = try XizArchive(path: path, password: options.password)
        var byPath: [String: Xiz.Entry] = [:]
        var known: [[UInt8]: [Xiz.Extent]] = [:]
        for e in a.catalog.entries {
            if let p = MountedArchive.normalize(e.path), byPath[p] == nil { byPath[p] = e }
            if let d = e.sha256, e.type == .file, known[d] == nil { known[d] = e.extents }
        }
        var fresh: [ArchiveItem] = []
        for key in tree.order { if case let .disk(item)? = tree.nodes[key] { fresh.append(item) } }

        let end = a.footerOffset + Int64(Xiz.footerSize)
        let out = try AppendFile(path: path, at: end)  // also drops the tail of an interrupted append
        defer { out.close() }
        let tracker = ProgressTracker(totalBytes: fresh.reduce(0) { $0 + $1.size }, totalEntries: fresh.count, handler: progress)
        let (frames, written) = try XizWriter.writeData(fresh, to: out, startFrame: a.catalog.frames.count, known: known, keys: a.keys,
                                                        level: options.level ?? 3, extendedAttributes: options.storeExtendedAttributes,
                                                        workload: options.workload, tracker: tracker, cancel: cancel)
        var newByName: [String: Xiz.Entry] = [:]
        for e in written { newByName[e.path] = e }
        var entries: [Xiz.Entry] = []
        var copied = 0
        for key in tree.order {
            switch tree.nodes[key] {
            case let .original(entry)?:
                guard var e = byPath[MountedArchive.normalize(entry.path) ?? ""] else { continue }
                e.path = key
                entries.append(e)
                copied += 1
            case .disk?:
                if let e = newByName[key] { entries.append(e) }
            case .newDirectory?:
                let now = Date().timeIntervalSince1970
                entries.append(Xiz.Entry(type: .directory, path: key, mode: 0o755, uid: getuid(), gid: getgid(),
                                         mtimeSec: Int64(now), mtimeNsec: 0, size: 0, link: "", xattrs: [], extents: [], sha256: nil))
            case nil:
                continue
            }
        }
        try XizWriter.writeCatalog(Xiz.Catalog(frames: a.catalog.frames + frames, entries: entries), to: out, keys: a.keys,
                                   segment: UInt32(a.segments), previousFooter: UInt64(a.footerOffset))
        try out.sync()
        tracker.finish()
        return EditReport(entries: entries.count, copied: copied, compressed: entries.count - copied, rebuilt: false, outputBytes: out.position)
    }
}

/// Writes at the end of an existing file (pwrite), truncating it to `at` first.
final class AppendFile: XizOutput {
    private var fd: Int32
    private(set) var position: Int64

    init(path: String, at offset: Int64) throws {
        fd = open(path, O_WRONLY | O_CLOEXEC)
        guard fd >= 0 else { throw XipperError.posix("open for append", path) }
        guard ftruncate(fd, offset) == 0 else { Darwin.close(fd); fd = -1; throw XipperError.posix("truncate", path) }
        position = offset
    }

    func write(_ src: UnsafeRawBufferPointer) throws {
        var done = 0
        while done < src.count {
            let n = pwrite(fd, src.baseAddress! + done, min(src.count - done, 1 << 30), off_t(position))
            if n < 0 { if errno == EINTR { continue }; throw XipperError.posix("write", nil) }
            done += n
            position += Int64(n)
        }
    }

    func write(_ bytes: [UInt8]) throws { try bytes.withUnsafeBytes { try write($0) } }

    func sync() throws { if fcntl(fd, F_FULLFSYNC) != 0 && fsync(fd) != 0 { throw XipperError.posix("fsync", nil) } }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    deinit { close() }
}
