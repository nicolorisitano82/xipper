import Foundation

/// A sequential reader of an archive stream: tar or cpio. Entries come out as tar headers,
/// so both go through the same safe extraction, listing and verification.
protocol EntryStreamReader: AnyObject {
    func next() throws -> TarReader.Entry?
    func readData(cancel: CancellationToken?, _ sink: ByteSink) throws
}

extension TarReader: EntryStreamReader {}

/// cpio: "newc" (070701), "crc" (070702) and portable ASCII "odc" (070707) headers (read only).
enum Cpio {
    static func looksLikeHeader(_ head: [UInt8]) -> Bool {
        head.count >= 76 && (head.starts(with: Array("070701".utf8)) || head.starts(with: Array("070702".utf8))
                             || head.starts(with: Array("070707".utf8)))
    }

    /// Picks the reader for a decompressed stream whose first bytes are `head`.
    static func reader(for source: ByteSource, head: [UInt8]) -> EntryStreamReader {
        looksLikeHeader(head) ? CpioReader(source: source) : TarReader(source: source)
    }
}

final class CpioReader: EntryStreamReader {
    private let source: ByteSource
    private var pendingData: Int64 = 0
    private var pendingPad = 0
    private var done = false

    init(source: ByteSource) { self.source = source }

    private func readBytes(_ n: Int) throws -> [UInt8] {
        var b = [UInt8](repeating: 0, count: n)
        if n > 0 { _ = try b.withUnsafeMutableBytes { try source.readExactly(into: $0.baseAddress!, count: n) } }
        return b
    }

    private static func number(_ field: ArraySlice<UInt8>, radix: Int) throws -> Int64 {
        guard let v = Int64(String(decoding: field, as: UTF8.self), radix: radix), v >= 0 else {
            throw XipperError.corrupt("invalid cpio header field")
        }
        return v
    }

    func next() throws -> TarReader.Entry? {
        while !done {
            if pendingData > 0 || pendingPad > 0 { try source.skip(pendingData + Int64(pendingPad)) }
            pendingData = 0
            pendingPad = 0
            var magic = [UInt8](repeating: 0, count: 6)
            guard try magic.withUnsafeMutableBytes({ try source.readExactly(into: $0.baseAddress!, count: 6, allowEOF: true) }) else {
                return nil
            }
            let ascii = String(decoding: magic, as: UTF8.self)
            let mode, uid, gid, mtime, size, nameSize: Int64
            let newc = ascii == "070701" || ascii == "070702"
            if newc {
                let h = try readBytes(104)
                func f(_ i: Int) throws -> Int64 { try Self.number(h[(i * 8)..<(i * 8 + 8)], radix: 16) }
                mode = try f(1); uid = try f(2); gid = try f(3); mtime = try f(5); size = try f(6); nameSize = try f(11)
            } else if ascii == "070707" {
                let h = try readBytes(70)
                mode = try Self.number(h[12..<18], radix: 8)
                uid = try Self.number(h[18..<24], radix: 8)
                gid = try Self.number(h[24..<30], radix: 8)
                mtime = try Self.number(h[42..<53], radix: 8)
                nameSize = try Self.number(h[53..<59], radix: 8)
                size = try Self.number(h[59..<70], radix: 8)
            } else {
                throw XipperError.corrupt("invalid cpio header")
            }
            guard nameSize > 0, nameSize <= 64 << 10, size <= 1 << 50 else { throw XipperError.corrupt("invalid cpio header sizes") }
            let rawName = try readBytes(Int(nameSize))
            if newc { try source.skip(Int64((4 - (110 + Int(nameSize)) % 4) % 4)) }
            let name = String(decoding: rawName.prefix { $0 != 0 }, as: UTF8.self)
            let dataPad = newc ? (4 - Int(size % 4)) % 4 : 0
            if name == "TRAILER!!!" { done = true; return nil }

            let type: UInt8
            switch mode & 0o170000 {
            case 0o040000: type = Tar.TypeFlag.directory.rawValue
            case 0o120000: type = Tar.TypeFlag.symlink.rawValue
            case 0o100000, 0: type = Tar.TypeFlag.file.rawValue
            default: type = Tar.TypeFlag.fifo.rawValue  // devices, FIFOs, sockets: reported, never created
            }
            var link = ""
            if type == Tar.TypeFlag.symlink.rawValue {
                guard size <= 4096 else { throw XipperError.corrupt("cpio symlink target too long") }
                link = String(decoding: try readBytes(Int(size)), as: UTF8.self)
                try source.skip(Int64(dataPad))
            } else {
                pendingData = size
                pendingPad = dataPad
            }
            var path = name
            while path.hasPrefix("./") { path.removeFirst(2) }
            while path.hasSuffix("/") { path.removeLast() }
            if path.isEmpty || path == "." { continue }  // the root of `find . | cpio`
            let header = Tar.Header(path: path, type: type, size: type == Tar.TypeFlag.file.rawValue ? size : 0,
                                    mode: UInt16(mode & 0o7777), uid: UInt32(clamping: uid), gid: UInt32(clamping: gid),
                                    mtime: Date(timeIntervalSince1970: Double(mtime)), linkTarget: link)
            let kind: ArchiveEntry.Kind = switch type {
            case Tar.TypeFlag.directory.rawValue: .directory
            case Tar.TypeFlag.symlink.rawValue: .symlink
            default: .file
            }
            let entry = ArchiveEntry(path: path, kind: kind, uncompressedSize: kind == .file ? size : 0, compressedSize: 0,
                                     modified: header.mtime, permissions: header.mode, encryption: .none, method: "cpio",
                                     linkTarget: kind == .symlink ? link : nil)
            return TarReader.Entry(header: header, entry: entry)
        }
        return nil
    }

    func readData(cancel: CancellationToken?, _ sink: ByteSink) throws {
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16384)
        defer { buf.deallocate() }
        while pendingData > 0 {
            try cancel?.check()
            let n = try source.read(into: buf, max: Int(min(pendingData, 1 << 20)))
            if n == 0 { throw XipperError.corrupt("cpio entry truncated") }
            pendingData -= Int64(n)
            try sink(UnsafeRawBufferPointer(start: buf, count: n))
        }
        try source.skip(Int64(pendingPad))
        pendingPad = 0
    }
}
