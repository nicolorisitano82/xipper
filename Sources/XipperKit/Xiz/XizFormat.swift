import CArgon2
import CryptoKit
import CXipShims
import CZstd
import Foundation

/// XIZ, Xipper's own archive format. Version 1.0 is frozen: the public specification is
/// docs/XIZ_SPEC.md and any change from here on is either an optional feature (old readers skip
/// it) or a required feature bit (old readers refuse the archive cleanly).
///
/// Layout: superblock (64 B) · [keys block, when encrypted] · frames (header 32 B + payload:
/// independent zstd or stored, ≤ 64 MiB of data, AES-256-GCM when encrypted) · catalog (zstd,
/// then STREAM-encrypted) · footer (96 B, fixed size).
/// The catalog is the single source of truth: frame headers are redundancy for checks and repair.
/// Version 0.1 (the beta) differs only in the catalog encoding and is still read.
enum Xiz {
    static let superMagic: [UInt8] = Array("XIZ\0\r\n".utf8) + [0x1A, 0x0A]
    static let frameMagic: [UInt8] = Array("XFR1".utf8)
    static let catalogMagic: [UInt8] = Array("XCAT".utf8)
    static let footerMagic: [UInt8] = Array("XIZF".utf8)
    static let tailMagic: [UInt8] = Array("XIZ!".utf8)
    static let keysMagic: [UInt8] = Array("XKEY".utf8)
    static let versionMajor: UInt16 = 1, versionMinor: UInt16 = 0
    static let superblockSize = 64
    static let frameHeaderSize = 32
    static let footerSize = 96
    static let frameData = 4 << 20
    static let tagSize = 16
    /// Decoder limits (STUDIO report, "regole di sicurezza").
    static let maxFrameData = 64 << 20
    static let maxCatalog = 1 << 30
    static let maxKeysBlock = 64 << 10
    /// Frame flag (1.2): the frame holds a zstd dictionary, not file data.
    static let dictionaryFrame: UInt8 = 1
    static let maxDictionary = 1 << 20

    /// Features an archive needs; a reader refuses bits it does not know.
    struct Required: OptionSet, Sendable {
        let rawValue: UInt16
        static let encrypted = Required(rawValue: 1 << 0)
        /// 1.2: frames compressed with a zstd dictionary stored in a dictionary frame.
        static let dictionaries = Required(rawValue: 1 << 1)
        /// Reserved for 1.x: appended segments (footer.previousFooter).
        static let appendChain = Required(rawValue: 1 << 2)
        static let understood: Required = [.encrypted, .dictionaries]
    }

    /// Features a reader may ignore.
    struct Optional: OptionSet, Sendable {
        let rawValue: UInt16
        /// Reserved for 1.x: Reed-Solomon recovery data.
        static let recovery = Optional(rawValue: 1 << 0)
    }

    enum Codec: UInt8 { case store = 0, zstd = 1 }
    enum EntryType: UInt8 { case file = 0, directory = 1, symlink = 2 }

    struct Frame: Equatable {
        var offset: Int64  // of the frame header in the file
        var csize: UInt32  // payload as written (with the AEAD tag when encrypted)
        var usize: UInt32
        var crc: UInt32  // CRC-32C of the payload as written
        var codec: Codec
        var flags: UInt8 = 0
        var dictionary: UInt16 = 0
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
        /// SHA-256 of the content (HMAC-SHA-256 with the archive's MAC key when encrypted).
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

    // MARK: superblock

    struct Superblock {
        var major: UInt16 = versionMajor
        var minor: UInt16 = versionMinor
        var required: Required = []
        var optional: Optional = []
        var archiveID: [UInt8]
        /// Length of the keys block right after the superblock (0 when not encrypted).
        var keysLength: UInt32 = 0

        func encode() -> [UInt8] {
            var w = ByteWriter(capacity: superblockSize)
            w.append(superMagic); w.u16(major); w.u16(minor); w.u16(required.rawValue); w.u16(optional.rawValue)
            w.append(archiveID); w.u32(keysLength)
            w.append([UInt8](repeating: 0, count: 24))
            w.u32(crc32c(w.bytes))
            return w.bytes
        }

        static func decode(_ b: [UInt8]) throws -> Superblock {
            guard b.count == superblockSize, b.starts(with: superMagic) else { throw XipperError.corrupt("not a XIZ archive") }
            let crc = b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 60, as: UInt32.self).littleEndian }
            guard crc == crc32c(Array(b[0..<60])) else { throw XipperError.corrupt("XIZ superblock checksum mismatch") }
            return try b.withUnsafeBytes { raw in
                var r = ByteReader(raw, at: 8)
                var s = Superblock(archiveID: [])
                s.major = try r.u16(); s.minor = try r.u16()
                s.required = Required(rawValue: try r.u16()); s.optional = Optional(rawValue: try r.u16())
                s.archiveID = Array(try r.bytes(16)); s.keysLength = try r.u32()
                guard s.major <= versionMajor else { throw XipperError.unsupported("XIZ version \(s.major).\(s.minor)") }
                let unknown = s.required.subtracting(.understood)
                guard unknown.isEmpty else { throw XipperError.unsupported("XIZ feature 0x\(String(unknown.rawValue, radix: 16)) (made by a newer Xipper)") }
                guard s.major == 1 || (s.required.isEmpty && s.keysLength == 0) else { throw XipperError.corrupt("XIZ 0.x superblock") }
                guard s.required.contains(.encrypted) == (s.keysLength > 0), s.keysLength <= UInt32(maxKeysBlock) else {
                    throw XipperError.corrupt("XIZ keys block")
                }
                return s
            }
        }
    }

    // MARK: footer

    struct Footer {
        var major: UInt16 = versionMajor
        var minor: UInt16 = versionMinor
        var catalogOffset: Int64
        var catalogCSize: Int64  // as written
        var catalogUSize: Int64  // decompressed
        var frameCount: UInt32
        var entryCount: UInt32
        var totalBytes: UInt64
        var catalogSHA256: [UInt8]  // of the catalog as written
        /// Reserved for appended segments (required feature `appendChain`); 0 in 1.0.
        var previousFooter: UInt64 = 0

        func encode() -> [UInt8] {
            var w = ByteWriter(capacity: footerSize)
            w.append(footerMagic); w.u16(major); w.u16(minor)
            w.u64(UInt64(catalogOffset)); w.u64(UInt64(catalogCSize)); w.u64(UInt64(catalogUSize))
            w.u32(frameCount); w.u32(entryCount); w.u64(totalBytes)
            w.append(catalogSHA256)
            w.u64(previousFooter)
            w.u32(crc32c(w.bytes))
            w.append(tailMagic)
            return w.bytes
        }

        /// The fields the encrypted catalog authenticates (everything but the hash and the CRC).
        var authenticatedFields: [UInt8] {
            var w = ByteWriter(capacity: 48)
            w.u16(major); w.u16(minor); w.u64(UInt64(catalogUSize)); w.u32(frameCount); w.u32(entryCount); w.u64(totalBytes)
            w.u64(previousFooter)
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
                let major = try r.u16(), minor = try r.u16()
                guard major <= versionMajor else { throw XipperError.unsupported("XIZ version \(major).\(minor)") }
                return Footer(major: major, minor: minor,
                              catalogOffset: Int64(bitPattern: try r.u64()), catalogCSize: Int64(bitPattern: try r.u64()),
                              catalogUSize: Int64(bitPattern: try r.u64()), frameCount: try r.u32(), entryCount: try r.u32(),
                              totalBytes: try r.u64(), catalogSHA256: Array(try r.bytes(32)), previousFooter: try r.u64())
            }
        }
    }

    // MARK: frame header

    static func frameHeader(index: UInt32, _ f: Frame) -> [UInt8] {
        var w = ByteWriter(capacity: frameHeaderSize)
        w.append(frameMagic); w.u8(f.codec.rawValue); w.u8(f.flags); w.u16(f.dictionary)
        w.u32(index); w.u32(f.csize); w.u32(f.usize); w.u32(f.crc)
        w.append([UInt8](repeating: 0, count: 8))
        return w.bytes
    }

    // MARK: catalog (1.0: TLV fields, unknown non-critical ones skipped)

    enum Tag: UInt16 {
        static let critical: UInt16 = 0x8000
        case size = 0x8001, extents = 0x8002, link = 0x8003
        case mode = 0x0004, owner = 0x0005, mtime = 0x0006, xattr = 0x0007, digest = 0x0008
    }

    static func encodeCatalog(_ c: Catalog) -> [UInt8] {
        var w = ByteWriter(capacity: 64 + c.frames.count * 24 + c.entries.count * 80)
        w.append(catalogMagic); w.u16(versionMajor)
        w.u32(UInt32(c.frames.count))
        for f in c.frames {
            w.u64(UInt64(f.offset)); w.u32(f.csize); w.u32(f.usize); w.u32(f.crc); w.u8(f.codec.rawValue); w.u8(f.flags)
            w.u16(f.dictionary)
        }
        w.u32(UInt32(c.entries.count))
        for e in c.entries {
            w.u8(e.type.rawValue)
            let p = Array(e.path.utf8); w.u16(UInt16(p.count)); w.append(p)
            var fields: [(Tag, [UInt8])] = []
            func field(_ tag: Tag, _ build: (inout ByteWriter) -> Void) {
                var f = ByteWriter(capacity: 16)
                build(&f)
                fields.append((tag, f.bytes))
            }
            if e.type == .file {
                field(.size) { $0.u64(e.size) }
                field(.extents) { f in for x in e.extents { f.u32(x.frame); f.u32(x.offset); f.u32(x.length) } }
            }
            if e.type == .symlink { field(.link) { $0.append(Array(e.link.utf8)) } }
            field(.mode) { $0.u16(e.mode) }
            field(.owner) { $0.u32(e.uid); $0.u32(e.gid) }
            field(.mtime) { $0.u64(UInt64(bitPattern: e.mtimeSec)); $0.u32(e.mtimeNsec) }
            for (name, value) in e.xattrs {
                field(.xattr) { f in let n = Array(name.utf8); f.u16(UInt16(n.count)); f.append(n); f.append(value) }
            }
            if let h = e.sha256 { field(.digest) { $0.append(h) } }
            w.u16(UInt16(fields.count))
            for (tag, bytes) in fields { w.u16(tag.rawValue); w.u32(UInt32(bytes.count)); w.append(bytes) }
        }
        return w.bytes
    }

    static func decodeCatalog(_ bytes: [UInt8]) throws -> Catalog {
        try bytes.withUnsafeBytes { raw in
            var r = ByteReader(raw)
            guard Array(try r.bytes(4)) == catalogMagic else { throw XipperError.corrupt("XIZ catalog magic") }
            let version = try r.u16()
            if version == 0 { return try decodeLegacyCatalog(&r, size: raw.count) }
            guard version == versionMajor else { throw XipperError.unsupported("XIZ catalog version \(version)") }
            var c = Catalog()
            let frames = Int(try r.u32())
            guard frames <= raw.count / 24 else { throw XipperError.corrupt("XIZ frame count") }
            c.frames.reserveCapacity(frames)
            for _ in 0..<frames {
                let off = Int64(bitPattern: try r.u64()), cs = try r.u32(), us = try r.u32(), crc = try r.u32()
                guard let codec = Codec(rawValue: try r.u8()) else { throw XipperError.unsupported("XIZ codec") }
                let flags = try r.u8(), dict = try r.u16()
                guard flags & ~dictionaryFrame == 0 else { throw XipperError.unsupported("XIZ frame flags \(flags)") }
                c.frames.append(Frame(offset: off, csize: cs, usize: us, crc: crc, codec: codec, flags: flags, dictionary: dict))
            }
            let entries = Int(try r.u32())
            guard entries <= raw.count / 5 else { throw XipperError.corrupt("XIZ entry count") }
            c.entries.reserveCapacity(entries)
            for _ in 0..<entries {
                guard let type = EntryType(rawValue: try r.u8()) else { throw XipperError.unsupported("XIZ entry type") }
                let path = String(decoding: try r.bytes(Int(try r.u16())), as: UTF8.self)
                var e = Entry(type: type, path: path, mode: type == .directory ? 0o755 : 0o644, uid: 0, gid: 0, mtimeSec: 0,
                              mtimeNsec: 0, size: 0, link: "", xattrs: [], extents: [], sha256: nil)
                var sawSize = false, sawExtents = false
                for _ in 0..<Int(try r.u16()) {
                    let tag = try r.u16(), len = Int(try r.u32())
                    guard len <= r.remaining else { throw XipperError.corrupt("XIZ field length") }
                    let body = try r.bytes(len)
                    var f = ByteReader(body)
                    switch Tag(rawValue: tag) {
                    case .size?: e.size = try f.u64(); sawSize = true
                    case .extents?:
                        guard len % 12 == 0 else { throw XipperError.corrupt("XIZ extents") }
                        e.extents.reserveCapacity(len / 12)
                        for _ in 0..<(len / 12) { e.extents.append(Extent(frame: try f.u32(), offset: try f.u32(), length: try f.u32())) }
                        sawExtents = true
                    case .link?: e.link = String(decoding: body, as: UTF8.self)
                    case .mode?: e.mode = try f.u16()
                    case .owner?: e.uid = try f.u32(); e.gid = try f.u32()
                    case .mtime?: e.mtimeSec = Int64(bitPattern: try f.u64()); e.mtimeNsec = try f.u32()
                    case .xattr?:
                        let n = Int(try f.u16())
                        let name = String(decoding: try f.bytes(n), as: UTF8.self)
                        e.xattrs.append((name, Array(try f.bytes(f.remaining))))
                    case .digest?:
                        guard len == 32 else { throw XipperError.corrupt("XIZ digest") }
                        e.sha256 = Array(body)
                    case nil:
                        // Unknown field: skipped, unless marked critical (a newer Xipper needs it understood).
                        if tag & Tag.critical != 0 { throw XipperError.unsupported("XIZ field 0x\(String(tag, radix: 16)) (made by a newer Xipper)") }
                    }
                }
                if type == .file && !(sawSize && sawExtents) { throw XipperError.corrupt("XIZ file without size or data: \(path)") }
                c.entries.append(e)
            }
            guard r.remaining == 0 else { throw XipperError.corrupt("XIZ catalog trailing data") }
            return c
        }
    }

    /// The 0.1 catalog of the beta (fixed records).
    private static func decodeLegacyCatalog(_ r: inout ByteReader, size: Int) throws -> Catalog {
        var c = Catalog()
        let frames = Int(try r.u32())
        guard frames <= size / 21 else { throw XipperError.corrupt("XIZ frame count") }
        c.frames.reserveCapacity(frames)
        for _ in 0..<frames {
            let off = Int64(bitPattern: try r.u64()), cs = try r.u32(), us = try r.u32(), crc = try r.u32()
            guard let codec = Codec(rawValue: try r.u8()) else { throw XipperError.unsupported("XIZ codec") }
            c.frames.append(Frame(offset: off, csize: cs, usize: us, crc: crc, codec: codec))
        }
        let entries = Int(try r.u32())
        guard entries <= size / 30 else { throw XipperError.corrupt("XIZ entry count") }
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

    /// `dictionary`: a ZSTD_DDict for frames compressed with one (1.2).
    static func zstdDecompress(_ src: UnsafeRawBufferPointer, size: Int, dictionary: OpaquePointer? = nil) throws -> [UInt8] {
        var ok = false
        let out = [UInt8](unsafeUninitializedCapacity: max(size, 1)) { buf, n in
            let r: Int
            if let dictionary, let d = ZSTD_createDCtx() {
                r = ZSTD_decompress_usingDDict(d, buf.baseAddress, size, src.baseAddress, src.count, dictionary)
                ZSTD_freeDCtx(d)
            } else {
                r = ZSTD_decompress(buf.baseAddress, size, src.baseAddress, src.count)
            }
            ok = ZSTD_isError(r) == 0 && r == size
            n = ok ? size : 0
        }
        guard ok else { throw XipperError.corrupt("invalid XIZ frame data") }
        return size == 0 ? [] : out
    }

    static func sha256(_ data: [UInt8]) -> [UInt8] { Array(SHA256.hash(data: data)) }

    /// A frame compressed with `dictionary` (ZDICT format). The dictionary is loaded into the
    /// window rather than attached: with 4 MiB frames attaching it costs 3% where loading gains
    /// 1.4% (docs/BENCHMARK.md). nil when the output would not be smaller.
    static func zstdCompress(_ src: UnsafeRawBufferPointer, level: Int, dictionary: [UInt8], pool: ZstdContextPool) -> [UInt8]? {
        let bound = ZSTD_compressBound(src.count)
        let out = [UInt8](unsafeUninitializedCapacity: bound) { buf, n in
            n = pool.with { c in
                defer { ZSTD_CCtx_reset(c, ZSTD_reset_session_and_parameters) }  // pooled contexts stay plain
                ZSTD_CCtx_setParameter(c, ZSTD_c_compressionLevel, Int32(max(1, min(22, level))))
                ZSTD_CCtx_setParameter(c, ZSTD_c_experimentalParam4,  // ZSTD_c_forceAttachDict (a macro)
                                        Int32(ZSTD_dictForceLoad.rawValue))
                ZSTD_CCtx_setPledgedSrcSize(c, UInt64(src.count))
                let loaded = dictionary.withUnsafeBytes { ZSTD_CCtx_loadDictionary(c, $0.baseAddress, $0.count) }
                if ZSTD_isError(loaded) != 0 { return 0 }
                let r = ZSTD_compress2(c, buf.baseAddress, bound, src.baseAddress, src.count)
                return ZSTD_isError(r) != 0 ? 0 : r
            }
        }
        return out.isEmpty || out.count >= src.count ? nil : out
    }
}

/// XIZ 1.2 dictionaries: one zstd dictionary trained on the archive's small files, stored once
/// in a dictionary frame and used by the frames made mostly of small files.
enum XizDictionary {
    static let id: UInt16 = 1
    static let capacity = 112_640  // zstd's default dictionary size
    /// Files below this size are "small": they gain from a dictionary and feed the training.
    static let smallFile: Int64 = 128 << 10
    /// Small-file bytes below which a dictionary does not pay for itself: it gains ~1.4% inside
    /// 4 MiB frames and costs ~40 KB stored.
    static let minimumSmallBytes: Int64 = 32 << 20
    /// At zstd 3 the gain is nil (20,000 source files: +0.06%); from 9 up it is about 1%.
    static let minimumLevel = 9

    /// Trains a dictionary from samples (whole small files); its ID is set to `id`.
    static func train(_ samples: [[UInt8]]) -> [UInt8]? {
        guard samples.count >= 64 else { return nil }
        let flat = samples.flatMap { $0 }
        let sizes = samples.map { $0.count }
        var dict = [UInt8](repeating: 0, count: capacity)
        let n = dict.withUnsafeMutableBytes { d in
            flat.withUnsafeBytes { f in ZDICT_trainFromBuffer(d.baseAddress, capacity, f.baseAddress, sizes, UInt32(sizes.count)) }
        }
        guard ZDICT_isError(n) == 0, n >= 8 else { return nil }
        dict.removeSubrange(n...)
        // Header: magic EC30A437, then the dictionary ID (little-endian).
        dict[4] = UInt8(id & 0xFF); dict[5] = UInt8(id >> 8); dict[6] = 0; dict[7] = 0
        return dict
    }

    /// A dictionary frame's content: a ZDICT dictionary with the frame's ID.
    static func ddict(_ bytes: [UInt8], id: UInt16) throws -> OpaquePointer {
        let declared = bytes.withUnsafeBytes { ZSTD_getDictID_fromDict($0.baseAddress, $0.count) }
        guard declared == UInt32(id), let d = bytes.withUnsafeBytes({ ZSTD_createDDict($0.baseAddress, $0.count) }) else {
            throw XipperError.corrupt("XIZ dictionary \(id) is not valid")
        }
        return d
    }
}

// MARK: - encryption

/// Authenticated encryption of XIZ 1.0 (docs/XIZ_SPEC.md §6): a random 256-bit file key wrapped
/// by Argon2id(password) in the keys block; HKDF-SHA-256 derives one key per purpose; frames are
/// AES-256-GCM messages; the catalog is STREAM-encrypted in 64 KiB chunks.
struct XizKeys: @unchecked Sendable {
    struct KDF: Equatable {
        var memoryKiB: UInt32
        var iterations: UInt32
        var parallelism: UInt32
        /// RFC 9106 second recommended profile, about 0.2 s on Apple Silicon.
        static let standard = KDF(memoryKiB: 256 << 10, iterations: 3, parallelism: 4)
        /// The cheapest parameters a reader accepts (tests only).
        static let minimum = KDF(memoryKiB: 19 << 10, iterations: 1, parallelism: 1)
        /// Bounds a decoder accepts (DoS protection, OWASP minimum).
        var isAcceptable: Bool {
            (19 << 10...(2 << 20)).contains(memoryKiB) && (1...10).contains(iterations) && (1...16).contains(parallelism)
        }
    }

    let archiveID: [UInt8]
    let data: SymmetricKey
    let catalog: SymmetricKey
    let fileMAC: SymmetricKey

    init(fileKey: SymmetricKey, archiveID: [UInt8]) {
        self.archiveID = archiveID
        func derive(_ purpose: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: fileKey, salt: Data(archiveID), info: Data("xiz/1/\(purpose)".utf8),
                                   outputByteCount: 32)
        }
        data = derive("data")
        catalog = derive("catalog")
        fileMAC = derive("file-mac")
    }

    static func argon2id(_ password: String, salt: [UInt8], _ kdf: KDF) throws -> SymmetricKey {
        var out = [UInt8](repeating: 0, count: 32)
        let pw = Array(password.utf8)
        let rc = pw.withUnsafeBytes { p in
            salt.withUnsafeBytes { s in
                argon2id_hash_raw(kdf.iterations, kdf.memoryKiB, kdf.parallelism, p.baseAddress, pw.count, s.baseAddress, salt.count,
                                  &out, out.count)
            }
        }
        guard rc == 0 else { throw XipperError.codec("Argon2id: \(String(cString: argon2_error_message(rc)))") }
        defer { out.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        return SymmetricKey(data: out)
    }

    // MARK: keys block

    /// "XKEY" (4) + count (2) + one password stanza (1 + 2 + 104) + CRC-32C (4).
    static let keysBlockSize = 117

    /// "XKEY", count, one password stanza (type 1: Argon2id), CRC-32C. The stanza wraps the file key
    /// with AES-256-GCM under the Argon2id key, authenticating the superblock and the KDF parameters.
    static func keysBlock(password: String, fileKey: SymmetricKey, superblock: [UInt8], kdf: KDF = .standard) throws -> [UInt8] {
        var salt = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&salt, 32)
        let kek = try argon2id(password, salt: salt, kdf)
        var stanza = ByteWriter(capacity: 104)
        stanza.u32(kdf.memoryKiB); stanza.u32(kdf.iterations); stanza.u32(kdf.parallelism); stanza.append(salt)
        let aad = Array(superblock[0..<60]) + [1] + stanza.bytes
        let sealed = try fileKey.withUnsafeBytes { try AES.GCM.seal(Data($0), using: kek, authenticating: Data(aad)) }
        stanza.append(Array(sealed.nonce)); stanza.append(Array(sealed.ciphertext)); stanza.append(Array(sealed.tag))
        var w = ByteWriter(capacity: 128)
        w.append(Xiz.keysMagic); w.u16(1)
        w.u8(1); w.u16(UInt16(stanza.bytes.count)); w.append(stanza.bytes)
        w.u32(Xiz.crc32c(w.bytes))
        return w.bytes
    }

    /// The file key from the keys block; `wrongPassword` when no stanza opens with `password`.
    static func open(keysBlock b: [UInt8], superblock: [UInt8], password: String) throws -> SymmetricKey {
        guard b.count >= 10, b.starts(with: Xiz.keysMagic) else { throw XipperError.corrupt("XIZ keys block") }
        let crc = b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: b.count - 4, as: UInt32.self).littleEndian }
        guard crc == Xiz.crc32c(Array(b[..<(b.count - 4)])) else { throw XipperError.corrupt("XIZ keys block checksum mismatch") }
        return try b.withUnsafeBytes { raw in
            var r = ByteReader(UnsafeRawBufferPointer(rebasing: raw[..<(raw.count - 4)]), at: 4)
            let count = Int(try r.u16())
            var sawPassword = false
            for _ in 0..<count {
                let type = try r.u8(), len = Int(try r.u16())
                let body = Array(try r.bytes(len))
                guard type == 1 else { continue }  // other stanza types (keyfile, public key): later versions
                sawPassword = true
                guard body.count == 104 else { throw XipperError.corrupt("XIZ password stanza") }
                let kdf = body.withUnsafeBytes { p in
                    KDF(memoryKiB: p.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian,
                        iterations: p.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian,
                        parallelism: p.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian)
                }
                guard kdf.isAcceptable else { throw XipperError.limitExceeded("XIZ key derivation parameters") }
                let salt = Array(body[12..<44])
                let kek = try argon2id(password, salt: salt, kdf)
                let aad = Array(superblock[0..<60]) + [1] + Array(body[0..<44])
                do {
                    let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: body[44..<56]), ciphertext: body[56..<88], tag: body[88..<104])
                    let key = try AES.GCM.open(box, using: kek, authenticating: Data(aad))
                    return SymmetricKey(data: key)
                } catch {
                    continue
                }
            }
            if !sawPassword { throw XipperError.unsupported("XIZ key stanza (made by a newer Xipper)") }
            throw XipperError.wrongPassword(entry: "")
        }
    }

    // MARK: frames

    private func frameNonce(_ index: UInt32) throws -> AES.GCM.Nonce {
        var n = [UInt8](repeating: 0, count: 12)
        var be = UInt64(index).bigEndian
        withUnsafeBytes(of: &be) { n.replaceSubrange(4..<12, with: $0) }
        return try AES.GCM.Nonce(data: n)
    }

    /// AAD of a frame: the archive, the frame's position and every header field the decoder acts on.
    private func frameAAD(_ index: UInt32, _ f: Xiz.Frame) -> Data {
        var w = ByteWriter(capacity: 48)
        w.append(Array("XIZ1frame".utf8)); w.append(archiveID); w.u32(index); w.u8(f.codec.rawValue); w.u8(f.flags)
        w.u16(f.dictionary); w.u32(f.usize)
        return Data(w.bytes)
    }

    func sealFrame(_ payload: [UInt8], index: UInt32, _ f: Xiz.Frame) throws -> [UInt8] {
        let box = try AES.GCM.seal(payload, using: data, nonce: try frameNonce(index), authenticating: frameAAD(index, f))
        return Array(box.ciphertext) + Array(box.tag)
    }

    func openFrame(_ sealed: [UInt8], index: UInt32, _ f: Xiz.Frame) throws -> [UInt8] {
        guard sealed.count >= Xiz.tagSize else { throw XipperError.corrupt("XIZ frame \(index) too short") }
        do {
            let box = try AES.GCM.SealedBox(nonce: try frameNonce(index), ciphertext: sealed[..<(sealed.count - Xiz.tagSize)],
                                            tag: sealed[(sealed.count - Xiz.tagSize)...])
            return Array(try AES.GCM.open(box, using: data, authenticating: frameAAD(index, f)))
        } catch {
            throw XipperError.integrity(entry: "frame \(index)", detail: "authentication failed (data altered)")
        }
    }

    // MARK: catalog (STREAM, 64 KiB chunks)

    static let catalogChunk = 64 << 10

    /// `00 00 00 ‖ last ‖ counter` in 1.0; appended segments (1.1) put their number in the first
    /// three bytes, so no two catalogs of an archive share a nonce.
    private func catalogNonce(_ counter: UInt64, last: Bool, segment: UInt32) throws -> AES.GCM.Nonce {
        var n = [UInt8](repeating: 0, count: 12)
        n[0] = UInt8((segment >> 16) & 0xFF); n[1] = UInt8((segment >> 8) & 0xFF); n[2] = UInt8(segment & 0xFF)
        n[3] = last ? 1 : 0
        var be = counter.bigEndian
        withUnsafeBytes(of: &be) { n.replaceSubrange(4..<12, with: $0) }
        return try AES.GCM.Nonce(data: n)
    }

    private func catalogAAD(_ footer: Xiz.Footer) -> Data {
        Data(Array("XIZ1catalog".utf8) + archiveID + footer.authenticatedFields)
    }

    func sealCatalog(_ plain: [UInt8], footer: Xiz.Footer, segment: UInt32 = 0) throws -> [UInt8] {
        precondition(segment < 1 << 24)
        var out = [UInt8]()
        out.reserveCapacity(plain.count + (plain.count / Self.catalogChunk + 1) * Xiz.tagSize)
        var start = 0, counter: UInt64 = 0
        repeat {
            let end = min(plain.count, start + Self.catalogChunk)
            let box = try AES.GCM.seal(plain[start..<end], using: catalog, nonce: try catalogNonce(counter, last: end == plain.count, segment: segment),
                                       authenticating: catalogAAD(footer))
            out += Array(box.ciphertext) + Array(box.tag)
            start = end
            counter += 1
        } while start < plain.count
        return out
    }

    func openCatalog(_ sealed: [UInt8], footer: Xiz.Footer, segment: UInt32 = 0) throws -> [UInt8] {
        guard segment < 1 << 24 else { throw XipperError.corrupt("XIZ segment number") }
        var out = [UInt8]()
        var start = 0, counter: UInt64 = 0
        let step = Self.catalogChunk + Xiz.tagSize
        while start < sealed.count {
            let end = min(sealed.count, start + step)
            let last = end == sealed.count
            guard end - start >= Xiz.tagSize else { throw XipperError.corrupt("XIZ catalog truncated") }
            do {
                let box = try AES.GCM.SealedBox(nonce: try catalogNonce(counter, last: last, segment: segment), ciphertext: sealed[start..<(end - Xiz.tagSize)],
                                                tag: sealed[(end - Xiz.tagSize)..<end])
                out += Array(try AES.GCM.open(box, using: catalog, authenticating: catalogAAD(footer)))
            } catch {
                throw XipperError.integrity(entry: "catalog", detail: "authentication failed (data altered or truncated)")
            }
            start = end
            counter += 1
        }
        return out
    }

    /// Content digest stored in the catalog: keyed, so the encrypted archive leaks nothing.
    func fileDigest() -> HMAC<SHA256> { HMAC<SHA256>(key: fileMAC) }
}
