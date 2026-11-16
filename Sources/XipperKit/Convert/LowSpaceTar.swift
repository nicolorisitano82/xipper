import Foundation

/// «Cambia formato» with little free space from an uncompressed tar (3.4). A tar has no central
/// directory: each member is a run of header blocks (pax, GNU long names) followed by its data,
/// so a member is a byte range that can be released on its own. Once part of the tar is released
/// the archive can no longer be read from the start (the released blocks read as zeros, the end
/// marker), so the plan — every member's range, name and size — is kept in the journal, and each
/// batch is read member by member at its own offset.
enum LowSpaceTar {
    struct Member {
        var range: LowSpaceConverter.Range
        var entry: ArchiveEntry
    }

    /// The members of the tar at `path`, in file order, and where its end marker starts.
    static func scan(_ path: String) throws -> (members: [Member], end: Int64) {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw XipperError.posix("open", path) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw XipperError.posix("stat", path) }
        let size = Int64(st.st_size)
        var block = [UInt8](repeating: 0, count: Tar.block)
        func readBlock(_ at: Int64) throws -> Bool {
            guard at + Int64(Tar.block) <= size else { return false }
            let n = block.withUnsafeMutableBytes { pread(fd, $0.baseAddress, Tar.block, at) }
            guard n == Tar.block else { throw XipperError.posix("read", path) }
            return true
        }
        var members: [Member] = []
        var offset: Int64 = 0
        var start: Int64 = 0
        var pax: [String: String] = [:]
        var longName: String?, longLink: String?
        while try readBlock(offset) {
            guard var h = try block.withUnsafeBytes({ try Tar.parseHeader($0) }) else { break }  // end marker
            let dataStart = offset + Int64(Tar.block)
            switch h.type {
            case Tar.TypeFlag.paxLocal.rawValue, Tar.TypeFlag.paxGlobal.rawValue, Tar.TypeFlag.gnuLongName.rawValue,
                 Tar.TypeFlag.gnuLongLink.rawValue:
                guard h.size >= 0, h.size <= 16 << 20, dataStart + h.size <= size else { throw XipperError.corrupt("tar metadata record out of range") }
                var data = [UInt8](repeating: 0, count: Int(h.size))
                if h.size > 0 {
                    let n = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, Int(h.size), dataStart) }
                    guard n == Int(h.size) else { throw XipperError.posix("read", path) }
                }
                switch h.type {
                case Tar.TypeFlag.paxLocal.rawValue: pax.merge(Tar.parsePax(data)) { $1 }
                case Tar.TypeFlag.gnuLongName.rawValue: longName = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
                case Tar.TypeFlag.gnuLongLink.rawValue: longLink = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
                default: break
                }
                offset = dataStart + h.size + Int64(Tar.padding(h.size))
                continue
            default:
                break
            }
            if let p = pax["path"] ?? longName { h.path = p }
            if let l = pax["linkpath"] ?? longLink { h.linkTarget = l }
            if let s = pax["size"], let v = Int64(s) { h.size = v }
            if let m = pax["mtime"], let v = Double(m) { h.mtime = Date(timeIntervalSince1970: v) }
            guard h.size >= 0 else { throw XipperError.corrupt("negative tar entry size") }
            if h.path.hasSuffix("/") && h.type == Tar.TypeFlag.file.rawValue { h.type = Tar.TypeFlag.directory.rawValue }
            let kind: ArchiveEntry.Kind
            switch h.type {
            case Tar.TypeFlag.directory.rawValue: kind = .directory
            case Tar.TypeFlag.symlink.rawValue: kind = .symlink
            case Tar.TypeFlag.hardlink.rawValue: kind = .hardlink
            case Tar.TypeFlag.file.rawValue, Tar.TypeFlag.contiguous.rawValue: kind = .file
            default: throw XipperError.unsupported("tar archives with special files need the usual conversion")
            }
            let dataSize = kind == .file || kind == .directory ? h.size : 0
            let end = dataStart + dataSize + Int64(Tar.padding(dataSize))
            guard end <= size else { throw XipperError.corrupt("tar entry truncated") }
            var name = h.path
            while name.hasSuffix("/") { name.removeLast() }
            let entry = ArchiveEntry(path: name, kind: kind, uncompressedSize: kind == .file ? h.size : 0, compressedSize: 0,
                                     modified: h.mtime, permissions: h.mode, encryption: .none, method: "tar",
                                     linkTarget: kind == .symlink || kind == .hardlink ? h.linkTarget : nil)
            members.append(Member(range: LowSpaceConverter.Range(start: start, end: end), entry: entry))
            offset = end
            start = end
            pax = [:]
            longName = nil
            longLink = nil
        }
        return (members, start)
    }
}

/// Reads the tar members lying in `ranges` (each one a whole member: its headers and data), in
/// order, each at its own offset: the rest of the file may already be released.
final class TarRangesReader: EntryStreamReader {
    private let fd: Int32
    private let ranges: [LowSpaceConverter.Range]
    private var index = 0
    private var current: TarReader?

    init(path: String, ranges: [LowSpaceConverter.Range]) throws {
        fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw XipperError.posix("open", path) }
        self.ranges = ranges.sorted { $0.start < $1.start }
    }

    deinit { close(fd) }

    func next() throws -> TarReader.Entry? {
        guard index < ranges.count else { return nil }
        let r = ranges[index]
        index += 1
        let reader = TarReader(source: RangeSource(fd: fd, offset: r.start, end: r.end))
        current = reader
        guard let e = try reader.next() else { throw XipperError.corrupt("tar member missing at offset \(r.start)") }
        return e
    }

    func readData(cancel: CancellationToken?, _ sink: ByteSink) throws {
        guard let current else { return }
        try current.readData(cancel: cancel, sink)
    }

    private final class RangeSource: ByteSource {
        let fd: Int32
        var offset: Int64
        let end: Int64

        init(fd: Int32, offset: Int64, end: Int64) {
            self.fd = fd
            self.offset = offset
            self.end = end
        }

        func read(into buf: UnsafeMutableRawPointer, max: Int) throws -> Int {
            let n = Int(min(Int64(max), end - offset))
            if n <= 0 { return 0 }
            let got = pread(fd, buf, n, offset)
            if got < 0 { throw XipperError.posix("read", nil) }
            offset += Int64(got)
            return got
        }
    }
}
