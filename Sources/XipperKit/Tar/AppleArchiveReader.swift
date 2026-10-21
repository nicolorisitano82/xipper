import AppleArchive
import Foundation
import System

/// Apple Archive (`.aar`, read only) through the system AppleArchive framework, which handles its
/// compression (LZFSE, LZMA, LZ4, zlib, raw). Entries come out as tar headers, so they go through
/// Xipper's own safe extraction instead of AppleArchive's extractor.
final class AppleArchiveReader: EntryStreamReader {
    private let file: ArchiveByteStream
    private let decompressed: ArchiveByteStream
    private let decoder: ArchiveStream
    private var pendingData: Int64 = 0
    private var dataKey: ArchiveHeader.FieldKey { ArchiveHeader.FieldKey("DAT") }

    /// "pbz" + algorithm (compressed) or "AA01"/"YAA1" (raw). Encrypted archives ("AEA1") are not supported.
    static func looksLikeArchive(_ head: [UInt8]) -> Bool {
        head.count >= 4 && (head.starts(with: Array("pbz".utf8)) || head.starts(with: Array("AA01".utf8))
                            || head.starts(with: Array("YAA1".utf8)))
    }

    static func isAppleArchive(_ path: String) -> Bool {
        guard let r = try? FileReader(path: path), let head = try? r.read(at: 0, count: Int(min(r.size, 8))) else { return false }
        return looksLikeArchive(head)
    }

    init(path: String) throws {
        guard let f = ArchiveByteStream.fileStream(path: FilePath(path), mode: .readOnly, options: [],
                                                   permissions: FilePermissions(rawValue: 0o644)) else {
            throw XipperError.posix("open", path)
        }
        guard let d = ArchiveByteStream.decompressionStream(readingFrom: f),
              let s = ArchiveStream.decodeStream(readingFrom: d) else {
            try? f.close()
            throw XipperError.corrupt("not a valid Apple Archive")
        }
        file = f
        decompressed = d
        decoder = s
    }

    deinit {
        try? decoder.close()
        try? decompressed.close()
        try? file.close()
    }

    func next() throws -> TarReader.Entry? {
        let header: ArchiveHeader?
        do { header = try decoder.readHeader() } catch { throw XipperError.corrupt("invalid Apple Archive data") }
        guard let header else { return nil }
        func string(_ key: String) -> String? {
            if case let .string(_, value)? = header.field(forKey: ArchiveHeader.FieldKey(key)) { return value }
            return nil
        }
        func uint(_ key: String) -> UInt64? {
            if case let .uint(_, value)? = header.field(forKey: ArchiveHeader.FieldKey(key)) { return value }
            return nil
        }
        var size: Int64 = 0
        if case let .blob(_, s, _)? = header.field(forKey: dataKey) { size = Int64(clamping: s) }
        var mtime = Date(timeIntervalSince1970: 0)
        if case let .timespec(_, ts)? = header.field(forKey: ArchiveHeader.FieldKey("MTM")) {
            mtime = Date(timeIntervalSince1970: Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9)
        }
        let type: UInt8
        switch header.entryType {
        case .directory?: type = Tar.TypeFlag.directory.rawValue
        case .link?: type = Tar.TypeFlag.symlink.rawValue
        case .regularFile?: type = Tar.TypeFlag.file.rawValue
        case .metadata?, nil: type = Tar.TypeFlag.paxGlobal.rawValue  // nothing to create
        default: type = Tar.TypeFlag.fifo.rawValue  // devices, FIFOs, sockets: reported, never created
        }
        var path = string("PAT") ?? ""
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasSuffix("/") { path.removeLast() }
        pendingData = type == Tar.TypeFlag.file.rawValue ? size : 0
        if path.isEmpty || type == Tar.TypeFlag.paxGlobal.rawValue {
            // The archive root ("PAT" empty) and metadata entries: skip to the next real one.
            return try next()
        }
        let link = string("LNK") ?? ""
        let header2 = Tar.Header(path: path, type: type, size: pendingData, mode: UInt16(uint("MOD") ?? 0o644) & 0o7777,
                                 uid: UInt32(clamping: uint("UID") ?? 0), gid: UInt32(clamping: uint("GID") ?? 0),
                                 mtime: mtime, linkTarget: link)
        let kind: ArchiveEntry.Kind = switch type {
        case Tar.TypeFlag.directory.rawValue: .directory
        case Tar.TypeFlag.symlink.rawValue: .symlink
        default: .file
        }
        let entry = ArchiveEntry(path: path, kind: kind, uncompressedSize: kind == .file ? pendingData : 0, compressedSize: 0,
                                 modified: mtime, permissions: header2.mode, encryption: .none, method: "aar",
                                 linkTarget: kind == .symlink ? link : nil)
        return TarReader.Entry(header: header2, entry: entry)
    }

    func readData(cancel: CancellationToken?, _ sink: ByteSink) throws {
        let chunk = 1 << 20
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 16384)
        defer { buf.deallocate() }
        while pendingData > 0 {
            try cancel?.check()
            let n = Int(min(Int64(chunk), pendingData))
            let part = UnsafeMutableRawBufferPointer(rebasing: buf[0..<n])
            do { try decoder.readBlob(key: dataKey, into: part) } catch { throw XipperError.corrupt("Apple Archive entry truncated") }
            pendingData -= Int64(n)
            try sink(UnsafeRawBufferPointer(part))
        }
    }
}
