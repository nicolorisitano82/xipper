import CryptoKit
import CXipShims
import CZstd
import Foundation

/// XIZ v0 (BETA): Xipper's own archive format, MVP of phase 1 of the study
/// (docs/reports/Nuovo formato di compressione Xipper.md).
///
/// Layout: superblock (64 B) · frames (header 32 B + payload, independent zstd, ≤ 4 MiB of data,
/// small files packed together, big files split) · catalog (zstd) · footer (96 B, fixed size).
/// The catalog is the single source of truth: frame headers are redundancy for checks and repair.
/// Not in v0: encryption, dictionaries, content-defined chunking, append, recovery data.
enum Xiz {
    static let superMagic: [UInt8] = Array("XIZ\0\r\n".utf8) + [0x1A, 0x0A]
    static let frameMagic: [UInt8] = Array("XFR1".utf8)
    static let catalogMagic: [UInt8] = Array("XCAT".utf8)
    static let footerMagic: [UInt8] = Array("XIZF".utf8)
    static let tailMagic: [UInt8] = Array("XIZ!".utf8)
    static let versionMajor: UInt16 = 0, versionMinor: UInt16 = 1
    static let superblockSize = 64
    static let frameHeaderSize = 32
    static let footerSize = 96
    static let frameData = 4 << 20
    /// Decoder limits (STUDIO report, "regole di sicurezza").
    static let maxFrameData = 64 << 20
    static let maxCatalog = 1 << 30

    enum Codec: UInt8 { case store = 0, zstd = 1 }
    enum EntryType: UInt8 { case file = 0, directory = 1, symlink = 2 }

    struct Frame: Equatable {
        var offset: Int64  // of the frame header in the file
        var csize: UInt32
        var usize: UInt32
        var crc: UInt32  // CRC-32C of the payload as written
        var codec: Codec
    }

    struct Extent: Equatable {
        var frame: UInt32
        var offset: UInt32
        var length: UInt32
    }

    struct Entry {
        var type: EntryType
        var path: String
        var mode: UInt16
        var uid: UInt32
        var gid: UInt32
        var mtimeSec: Int64
        var mtimeNsec: UInt32
        var size: UInt64
        var link: String
        var xattrs: [(name: String, value: [UInt8])]
        var extents: [Extent]
        var sha256: [UInt8]?

        var modified: Date { Date(timeIntervalSince1970: Double(mtimeSec) + Double(mtimeNsec) / 1e9) }
    }

    struct Catalog {
        var frames: [Frame] = []
        var entries: [Entry] = []
    }

    static func crc32c(_ data: UnsafeRawBufferPointer) -> UInt32 {
        guard let p = data.baseAddress, data.count > 0 else { return 0 }
        return xs_crc32c(0, p.assumingMemoryBound(to: UInt8.self), data.count)
    }

    static func crc32c(_ bytes: [UInt8]) -> UInt32 { bytes.withUnsafeBytes { crc32c($0) } }

    // MARK: superblock and footer

    static func superblock() -> [UInt8] {
        var w = ByteWriter(capacity: superblockSize)
        w.append(superMagic); w.u16(versionMajor); w.u16(versionMinor); w.u32(0)
        var id = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&id, 16)
        w.append(id)
        w.append([UInt8](repeating: 0, count: 28))
        w.u32(crc32c(w.bytes))
        return w.bytes
    }

    struct Footer {
        var catalogOffset: Int64
        var catalogCSize: Int64
        var catalogUSize: Int64
        var frameCount: UInt32
        var entryCount: UInt32
        var totalBytes: UInt64
        var catalogSHA256: [UInt8]

        func encode() -> [UInt8] {
            var w = ByteWriter(capacity: footerSize)
            w.append(footerMagic); w.u16(versionMajor); w.u16(versionMinor)
            w.u64(UInt64(catalogOffset)); w.u64(UInt64(catalogCSize)); w.u64(UInt64(catalogUSize))
            w.u32(frameCount); w.u32(entryCount); w.u64(totalBytes)
            w.append(catalogSHA256)
            w.append([UInt8](repeating: 0, count: 8))
            w.u32(crc32c(w.bytes))
            w.append(tailMagic)
            return w.bytes
        }

        static func decode(_ b: [UInt8]) throws -> Footer {
            guard b.count == footerSize, b.starts(with: footerMagic), Array(b[92..<96]) == tailMagic else {
                throw XipperError.corrupt("XIZ footer not found")
            }
            let crc = b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 88, as: UInt32.self).littleEndian }
            guard crc == crc32c(Array(b[0..<88])) else { throw XipperError.corrupt("XIZ footer checksum mismatch") }
            return try b.withUnsafeBytes { raw in
                var r = ByteReader(raw, at: 4)
                let major = try r.u16()
                _ = try r.u16()
                guard major == versionMajor else { throw XipperError.unsupported("XIZ version \(major)") }
                return Footer(catalogOffset: Int64(bitPattern: try r.u64()), catalogCSize: Int64(bitPattern: try r.u64()),
                              catalogUSize: Int64(bitPattern: try r.u64()), frameCount: try r.u32(), entryCount: try r.u32(),
                              totalBytes: try r.u64(), catalogSHA256: Array(try r.bytes(32)))
            }
        }
    }

    // MARK: frame header

    static func frameHeader(index: UInt32, _ f: Frame) -> [UInt8] {
        var w = ByteWriter(capacity: frameHeaderSize)
        w.append(frameMagic); w.u8(f.codec.rawValue); w.append([0, 0, 0])
        w.u32(index); w.u32(f.csize); w.u32(f.usize); w.u32(f.crc)
        w.append([UInt8](repeating: 0, count: 8))
        return w.bytes
    }

    // MARK: catalog

    static func encodeCatalog(_ c: Catalog) -> [UInt8] {
        var w = ByteWriter(capacity: 64 + c.frames.count * 21 + c.entries.count * 64)
        w.append(catalogMagic); w.u16(versionMajor)
        w.u32(UInt32(c.frames.count))
        for f in c.frames {
            w.u64(UInt64(f.offset)); w.u32(f.csize); w.u32(f.usize); w.u32(f.crc); w.u8(f.codec.rawValue)
        }
        w.u32(UInt32(c.entries.count))
        for e in c.entries {
            w.u8(e.type.rawValue)
            let p = Array(e.path.utf8); w.u16(UInt16(p.count)); w.append(p)
            w.u16(e.mode); w.u32(e.uid); w.u32(e.gid); w.u64(UInt64(bitPattern: e.mtimeSec)); w.u32(e.mtimeNsec)
            w.u64(e.size)
            let l = Array(e.link.utf8); w.u16(UInt16(l.count)); w.append(l)
            w.u16(UInt16(e.xattrs.count))
            for (name, value) in e.xattrs {
                let n = Array(name.utf8); w.u8(UInt8(n.count)); w.append(n)
                w.u32(UInt32(value.count)); w.append(value)
            }
            w.u32(UInt32(e.extents.count))
            for x in e.extents { w.u32(x.frame); w.u32(x.offset); w.u32(x.length) }
            if let h = e.sha256 { w.u8(1); w.append(h) } else { w.u8(0) }
        }
        return w.bytes
    }

    static func decodeCatalog(_ bytes: [UInt8]) throws -> Catalog {
        try bytes.withUnsafeBytes { raw in
            var r = ByteReader(raw)
            guard Array(try r.bytes(4)) == catalogMagic else { throw XipperError.corrupt("XIZ catalog magic") }
            _ = try r.u16()
            var c = Catalog()
            let frames = Int(try r.u32())
            guard frames <= raw.count / 21 else { throw XipperError.corrupt("XIZ frame count") }
            c.frames.reserveCapacity(frames)
            for _ in 0..<frames {
                let off = Int64(bitPattern: try r.u64()), cs = try r.u32(), us = try r.u32(), crc = try r.u32()
                guard let codec = Codec(rawValue: try r.u8()) else { throw XipperError.unsupported("XIZ codec") }
                c.frames.append(Frame(offset: off, csize: cs, usize: us, crc: crc, codec: codec))
            }
            let entries = Int(try r.u32())
            guard entries <= raw.count / 30 else { throw XipperError.corrupt("XIZ entry count") }
            c.entries.reserveCapacity(entries)
            for _ in 0..<entries {
                guard let type = EntryType(rawValue: try r.u8()) else { throw XipperError.unsupported("XIZ entry type") }
                let path = String(decoding: try r.bytes(Int(try r.u16())), as: UTF8.self)
                let mode = try r.u16(), uid = try r.u32(), gid = try r.u32()
                let sec = Int64(bitPattern: try r.u64()), nsec = try r.u32(), size = try r.u64()
                let link = String(decoding: try r.bytes(Int(try r.u16())), as: UTF8.self)
                var xattrs: [(String, [UInt8])] = []
                for _ in 0..<Int(try r.u16()) {
                    let name = String(decoding: try r.bytes(Int(try r.u8())), as: UTF8.self)
                    xattrs.append((name, Array(try r.bytes(Int(try r.u32())))))
                }
                let n = Int(try r.u32())
                guard n <= r.remaining / 12 else { throw XipperError.corrupt("XIZ extent count") }
                var extents: [Extent] = []
                extents.reserveCapacity(n)
                for _ in 0..<n { extents.append(Extent(frame: try r.u32(), offset: try r.u32(), length: try r.u32())) }
                let sha = try r.u8() == 1 ? Array(try r.bytes(32)) : nil
                c.entries.append(Entry(type: type, path: path, mode: mode, uid: uid, gid: gid, mtimeSec: sec, mtimeNsec: nsec,
                                       size: size, link: link, xattrs: xattrs, extents: extents, sha256: sha))
            }
            return c
        }
    }

    static func zstdDecompress(_ src: UnsafeRawBufferPointer, size: Int) throws -> [UInt8] {
        var ok = false
        let out = [UInt8](unsafeUninitializedCapacity: max(size, 1)) { buf, n in
            let r = ZSTD_decompress(buf.baseAddress, size, src.baseAddress, src.count)
            ok = ZSTD_isError(r) == 0 && r == size
            n = ok ? size : 0
        }
        guard ok else { throw XipperError.corrupt("invalid XIZ frame data") }
        return size == 0 ? [] : out
    }

    static func sha256(_ data: [UInt8]) -> [UInt8] { Array(SHA256.hash(data: data)) }
}
