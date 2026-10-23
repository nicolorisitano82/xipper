import CommonCrypto
import Foundation

/// RAR5 encryption (AES-256), read side, written from RARLAB's published "RAR 5.0 archive format"
/// description: RAR's own unrar code is never used (STUDIO.md §4.2).
///
/// libarchive's RAR5 reader recognizes encrypted entries but cannot decrypt them, so Xipper puts
/// `Rar5PlainStream` in front of it: the archive is rewritten on the fly into the unencrypted
/// RAR5 archive it stands for (headers decrypted, crypt records removed, data decrypted), and
/// libarchive decompresses that. Checksums that RAR "tweaked" with the password (HMAC-SHA256 of
/// the CRC-32 or BLAKE2sp) cannot be checked by libarchive: they are taken out of the headers and
/// checked here, on the decompressed data (`Rar5Expected`).
enum Rar5Crypto {
    struct Keys {
        var key: [UInt8]       // AES-256
        var hashKey: [UInt8]   // HMAC key of the tweaked checksums
        var check: [UInt8]     // 8-byte password check value
    }

    /// PBKDF2-HMAC-SHA256 with 2^`log2Count` iterations gives the key; 16 and 32 iterations more
    /// (the same running XOR) give the checksum key and the password check value.
    static func keys(password: String, salt: [UInt8], log2Count: Int) throws -> Keys {
        guard log2Count <= 24 else { throw XipperError.unsupported("RAR5 key derivation with 2^\(log2Count) iterations") }
        let pw = Array(password.utf8)
        func hmac(_ data: [UInt8]) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: 32)
            CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), pw, pw.count, data, data.count, &out)
            return out
        }
        var u = hmac(salt + [0, 0, 0, 1])
        var f = u
        var outputs: [[UInt8]] = []
        for rounds in [(1 << log2Count) - 1, 16, 16] {
            for _ in 0..<rounds {
                u = hmac(u)
                for i in 0..<32 { f[i] ^= u[i] }
            }
            outputs.append(f)
        }
        var check = [UInt8](repeating: 0, count: 8)
        for i in 0..<32 { check[i % 8] ^= outputs[2][i] }
        return Keys(key: outputs[0], hashKey: outputs[1], check: check)
    }

    /// The 12-byte check record: the check value and the first 4 bytes of its SHA-256 (which
    /// tells a damaged record from a wrong password).
    static func verify(_ keys: Keys, record: [UInt8], entry: String) throws {
        guard record.count == 12 else { return }
        var sum = [UInt8](repeating: 0, count: 32)
        CC_SHA256(Array(record[0..<8]), 8, &sum)
        guard Array(sum[0..<4]) == Array(record[8..<12]) else { throw XipperError.corrupt("\(entry): damaged RAR5 password check") }
        if Array(record[0..<8]) != keys.check { throw XipperError.wrongPassword(entry: entry) }
    }

    static func hmac(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), key, key.count, data, data.count, &out)
        return out
    }

    /// CRC-32 as stored with tweaked checksums: the HMAC of the real one, folded to 32 bits.
    static func tweak(crc: UInt32, hashKey: [UInt8]) -> UInt32 {
        let d = hmac(hashKey, [UInt8(crc & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 24)])
        var v: UInt32 = 0
        for i in 0..<32 { v ^= UInt32(d[i]) << UInt32((i & 3) * 8) }
        return v
    }
}

/// AES-256-CBC without padding, streaming.
final class AESCBCDecryptor {
    private var ref: CCCryptorRef?

    init(key: [UInt8], iv: [UInt8]) throws {
        guard CCCryptorCreate(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0, key, key.count, iv, &ref) == kCCSuccess else {
            throw XipperError.codec("AES")
        }
    }

    deinit { CCCryptorRelease(ref) }

    /// `data.count` must be a multiple of 16.
    func decrypt(_ data: [UInt8]) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        guard CCCryptorUpdate(ref, data, data.count, &out, out.count, &moved) == kCCSuccess, moved == data.count else {
            throw XipperError.codec("AES")
        }
        return out
    }
}

/// What a tweaked file header promised about its data, checked after decompression.
struct Rar5Expected: Sendable {
    var crc: UInt32?
    var blake2: [UInt8]?
    var hashKey: [UInt8]
}

/// An encrypted RAR5 archive (one volume) presented as the plain RAR5 archive it encodes.
final class Rar5PlainStream {
    private let r: FileReader
    private let name: String
    private let password: String
    private var pos: Int64 = 0
    private var headerKeys: Rar5Crypto.Keys?
    private var keyCache: [[UInt8]: Rar5Crypto.Keys] = [:]
    private var pending: [UInt8] = []
    /// Data area still to copy or decrypt for the current block.
    private var dataLeft: Int64 = 0
    private var dataKeep: Int64 = 0
    private var dataCipher: AESCBCDecryptor?
    private var ended = false
    /// One element per file header (not service headers), in order: nil when nothing was tweaked.
    private(set) var expected: [Rar5Expected?] = []
    /// Indexes (as in `expected`) of files whose password check failed: passed on still encrypted.
    private(set) var wrongPassword = Set<Int>()

    static let signature = RarReader.signature5

    /// True when the headers themselves are encrypted (names cannot be listed without the password).
    static func headersEncrypted(_ path: String) -> Bool {
        guard let r = try? FileReader(path: path), r.size > 16,
              let head = try? r.read(at: 0, count: Int(min(r.size, 32))), head.starts(with: signature) else { return false }
        var p = 8 + 4
        guard (try? vint(head, &p)) != nil, let type = try? vint(head, &p) else { return false }
        return type == 4
    }

    /// True when any file is encrypted (or the headers are). Reads headers only.
    static func isEncrypted(_ path: String) -> Bool {
        if headersEncrypted(path) { return true }
        guard let r = try? FileReader(path: path) else { return false }
        var off: Int64 = 8
        while off + 6 < r.size {
            guard let head = try? r.read(at: off, count: Int(min(r.size - off, 16))) else { return false }
            var p = 4
            guard let size = try? vint(head, &p), size < 2 << 20, off + Int64(p) + Int64(size) <= r.size,
                  let h = try? r.read(at: off + Int64(p), count: Int(size)) else { return false }
            var q = 0
            guard let type = try? vint(h, &q), let flags = try? vint(h, &q) else { return false }
            let extra = flags & 1 != 0 ? (try? vint(h, &q)) ?? 0 : 0
            let data = flags & 2 != 0 ? (try? vint(h, &q)) ?? 0 : 0
            if type == 5 { return false }
            if (type == 2 || type == 3) && extra > 0 && extra <= UInt64(h.count) {
                var e = h.count - Int(extra)
                while e < h.count {
                    guard let len = try? vint(h, &e) else { break }
                    let start = e
                    guard let id = try? vint(h, &e) else { break }
                    if id == 1 { return true }
                    e = start + Int(len)
                }
            }
            off += Int64(p) + Int64(size) + Int64(data)
        }
        return false
    }

    init(path: String, password: String) throws {
        r = try FileReader(path: path)
        name = (path as NSString).lastPathComponent
        self.password = password
        let sig = try r.read(at: 0, count: 8)
        guard sig == Self.signature else { throw XipperError.corrupt("\(name): not a RAR5 archive") }
        pending = sig
        pos = 8
    }

    /// The next piece of the plain archive; empty at the end.
    func next() throws -> [UInt8] {
        if !pending.isEmpty { defer { pending = [] }; return pending }
        if dataLeft > 0 { return try nextData() }
        while !ended {
            if let block = try nextBlock() { return block }
        }
        return []
    }

    private func nextData() throws -> [UInt8] {
        let n = Int(min(dataLeft, 1 << 20))
        var chunk = try r.read(at: pos, count: n)
        pos += Int64(n)
        dataLeft -= Int64(n)
        if let c = dataCipher {
            guard n % 16 == 0 else { throw XipperError.corrupt("\(name): encrypted RAR5 data not a multiple of 16 bytes") }
            chunk = try c.decrypt(chunk)
        }
        if dataKeep < Int64(chunk.count) { chunk.removeSubrange(Int(max(0, dataKeep))...) }
        dataKeep -= Int64(n)
        return chunk
    }

    private func keys(salt: [UInt8], count: Int, check: [UInt8], entry: String) throws -> Rar5Crypto.Keys {
        let k: Rar5Crypto.Keys
        if let cached = keyCache[salt + [UInt8(count)]] {
            k = cached
        } else {
            k = try Rar5Crypto.keys(password: password, salt: salt, log2Count: count)
            keyCache[salt + [UInt8(count)]] = k
        }
        try Rar5Crypto.verify(k, record: check, entry: entry)
        return k
    }

    /// Reads one header (decrypting it if the headers are encrypted); returns its bytes after the
    /// CRC and size fields, and sets up the data area that follows. nil for blocks not passed on.
    private func nextBlock() throws -> [UInt8]? {
        guard pos < r.size else { ended = true; return nil }
        var header: [UInt8]
        if let hk = headerKeys {
            let iv = try r.read(at: pos, count: 16)
            let c = try AESCBCDecryptor(key: hk.key, iv: iv)
            var first = try c.decrypt(try r.read(at: pos + 16, count: 16))
            var p = 4
            let size = try Self.vint(first, &p)
            guard size < 2 << 20 else { throw XipperError.corrupt("\(name): RAR5 header too large") }
            let total = p + Int(size)
            let padded = (total + 15) & ~15
            if padded > 16 { first += try c.decrypt(try r.read(at: pos + 32, count: padded - 16)) }
            pos += 16 + Int64(padded)
            header = Array(first[0..<total])
            guard CRC32.checksum(Array(header[4...])) == Self.u32(header, 0) else { throw XipperError.wrongPassword(entry: name) }
            header = Array(header[p...])
        } else {
            let head = try r.read(at: pos, count: Int(min(r.size - pos, 16)))
            var p = 4
            let size = try Self.vint(head, &p)
            guard size < 2 << 20, pos + Int64(p) + Int64(size) <= r.size else { throw XipperError.corrupt("\(name): invalid RAR5 header") }
            header = try r.read(at: pos + Int64(p), count: Int(size))
            pos += Int64(p) + Int64(size)
        }
        var q = 0
        let type = try Self.vint(header, &q)
        let flags = try Self.vint(header, &q)
        let extraSize = flags & 1 != 0 ? try Self.vint(header, &q) : 0
        let dataSize = flags & 2 != 0 ? try Self.vint(header, &q) : 0
        let fieldsStart = q
        guard extraSize <= UInt64(header.count - fieldsStart) else { throw XipperError.corrupt("\(name): invalid RAR5 extra area") }
        let extraStart = header.count - Int(extraSize)

        switch type {
        case 4:  // archive encryption header: version, flags, KDF count, salt, check
            var c = fieldsStart
            _ = try Self.vint(header, &c)
            let cf = try Self.vint(header, &c)
            guard c + 17 <= header.count else { throw XipperError.corrupt("\(name): invalid RAR5 encryption header") }
            let count = Int(header[c]); c += 1
            let salt = Array(header[c..<(c + 16)]); c += 16
            let check = cf & 1 != 0 && c + 12 <= header.count ? Array(header[c..<(c + 12)]) : []
            headerKeys = try keys(salt: salt, count: count, check: check, entry: name)
            return nil
        case 2, 3:
            return try fileBlock(header, type: type, flags: flags, dataSize: dataSize, fieldsStart: fieldsStart, extraStart: extraStart)
        default:
            if type == 5 { ended = true }
            dataLeft = Int64(dataSize)
            dataKeep = dataLeft
            dataCipher = nil
            return Self.wrap(header)
        }
    }

    private func fileBlock(_ header: [UInt8], type: UInt64, flags: UInt64, dataSize: UInt64,
                           fieldsStart: Int, extraStart: Int) throws -> [UInt8] {
        // File fields: flags, unpacked size, attributes, [mtime], [CRC], compression, host, name.
        var f = fieldsStart
        let fileFlags = try Self.vint(header, &f)
        let afterFlags = f
        let unpacked = try Self.vint(header, &f)
        _ = try Self.vint(header, &f)
        if fileFlags & 2 != 0 { f += 4 }
        let crcAt = fileFlags & 4 != 0 ? f : nil
        if crcAt != nil { f += 4 }
        let compression = try Self.vint(header, &f)
        guard f <= extraStart else { throw XipperError.corrupt("\(name): invalid RAR5 file header") }

        // Extra records: find the crypt record, keep the others.
        var kept: [UInt8] = []
        var crypt: (keys: Rar5Crypto.Keys, iv: [UInt8], tweaked: Bool)?
        var hash: [UInt8]?
        var e = extraStart
        var records: [(id: UInt64, bytes: ArraySlice<UInt8>, body: Int)] = []
        while e < header.count {
            let start = e
            let len = try Self.vint(header, &e)
            let bodyStart = e
            guard bodyStart + Int(len) <= header.count, len > 0 else { throw XipperError.corrupt("\(name): invalid RAR5 extra record") }
            let id = try Self.vint(header, &e)
            records.append((id, header[start..<(bodyStart + Int(len))], e))
            e = bodyStart + Int(len)
        }
        for rec in records where rec.id == 1 {
            var c = rec.body
            _ = try Self.vint(header, &c)
            let cf = try Self.vint(header, &c)
            guard c + 33 <= header.count else { throw XipperError.corrupt("\(name): invalid RAR5 encryption record") }
            let count = Int(header[c]); c += 1
            let salt = Array(header[c..<(c + 16)]); c += 16
            let iv = Array(header[c..<(c + 16)]); c += 16
            let check = cf & 1 != 0 && c + 12 <= header.count ? Array(header[c..<(c + 12)]) : []
            do {
                crypt = (try keys(salt: salt, count: count, check: check, entry: name), iv, cf & 2 != 0)
            } catch XipperError.wrongPassword {
                // Another password for this file: libarchive sees it encrypted, reading it fails.
                if type == 2 { wrongPassword.insert(expected.count); expected.append(nil) }
                dataLeft = Int64(dataSize)
                dataKeep = dataLeft
                dataCipher = nil
                return Self.wrap(header)
            }
        }
        for rec in records where rec.id != 1 {
            if rec.id == 2, crypt?.tweaked == true {
                var c = rec.body
                if try Self.vint(header, &c) == 0, c + 32 <= header.count { hash = Array(header[c..<(c + 32)]); continue }
            }
            kept += rec.bytes
        }

        // Rebuild the header without the crypt record (and without tweaked checksums).
        var fields = Array(header[fieldsStart..<extraStart])
        var expected: Rar5Expected?
        if let crypt, crypt.tweaked {
            var crc: UInt32?
            if let at = crcAt {
                crc = Self.u32(header, at)
                fields = Self.encode(fileFlags & ~4) + Array(header[afterFlags..<at]) + Array(header[(at + 4)..<extraStart])
            }
            expected = Rar5Expected(crc: crc, blake2: hash, hashKey: crypt.keys.hashKey)
        }
        // The data size counts the AES padding, which libarchive would read as more data: stored
        // files keep their size, compressed ones end with the block marked last.
        let method = (compression >> 7) & 7
        var newData = dataSize
        if let crypt, fileFlags & 1 == 0, dataSize > 0 {
            newData = method == 0 ? min(dataSize, unpacked)
                                  : try compressedLength(at: pos, size: Int64(dataSize), key: crypt.keys.key, iv: crypt.iv)
        }
        var out: [UInt8] = []
        out += Self.encode(type)
        let newFlags = (kept.isEmpty ? flags & ~1 : flags | 1)
        out += Self.encode(newFlags)
        if newFlags & 1 != 0 { out += Self.encode(UInt64(kept.count)) }
        if newFlags & 2 != 0 { out += Self.encode(newData) }
        out += fields
        out += kept
        if type == 2 { self.expected.append(expected) }

        dataLeft = Int64(dataSize)
        dataKeep = Int64(newData)
        dataCipher = try crypt.map { try AESCBCDecryptor(key: $0.keys.key, iv: $0.iv) }
        return Self.wrap(out)
    }

    /// Length of RAR5 compressed data without the AES padding: block headers (flags, check byte,
    /// 1–3 size bytes) are decrypted one at a time (CBC allows it) until the last block.
    private func compressedLength(at start: Int64, size: Int64, key: [UInt8], iv: [UInt8]) throws -> UInt64 {
        func plain(_ off: Int64, _ count: Int) throws -> [UInt8] {
            let first = off / 16, last = (off + Int64(count) - 1) / 16
            guard (last + 1) * 16 <= size else { throw XipperError.corrupt("\(name): RAR5 compressed data overruns its area") }
            var out: [UInt8] = []
            for b in first...last {
                let cipher = try r.read(at: start + b * 16, count: 16)
                let prev = b == 0 ? iv : try r.read(at: start + (b - 1) * 16, count: 16)
                var block = [UInt8](repeating: 0, count: 16)
                var moved = 0
                guard CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), key, key.count,
                              nil, cipher, 16, &block, 16, &moved) == kCCSuccess else { throw XipperError.codec("AES") }
                out += (0..<16).map { block[$0] ^ prev[$0] }
            }
            let skip = Int(off - first * 16)
            return Array(out[skip..<(skip + count)])
        }
        var off: Int64 = 0
        while off + 3 <= size {
            let head = try plain(off, Int(min(5, size - off)))
            let sizeBytes = Int((head[0] >> 3) & 7) + 1
            guard sizeBytes <= 3, head.count >= 2 + sizeBytes else { throw XipperError.corrupt("\(name): invalid RAR5 compressed block") }
            var blockSize: Int64 = 0
            for i in 0..<sizeBytes { blockSize |= Int64(head[2 + i]) << (8 * i) }
            off += 2 + Int64(sizeBytes) + blockSize
            if head[0] & 0x40 != 0 { return UInt64(min(off, size)) }
        }
        return UInt64(size)
    }

    /// CRC-32 and size in front of a header body.
    private static func wrap(_ body: [UInt8]) -> [UInt8] {
        let size = encode(UInt64(body.count))
        let crc = CRC32.checksum(size + body)
        return [UInt8(crc & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 24)] + size + body
    }

    static func vint(_ b: [UInt8], _ p: inout Int) throws -> UInt64 {
        var v: UInt64 = 0
        var shift: UInt64 = 0
        while p < b.count && shift < 64 {
            let x = b[p]; p += 1
            v |= UInt64(x & 0x7F) << shift
            if x & 0x80 == 0 { return v }
            shift += 7
        }
        throw XipperError.corrupt("invalid RAR5 number")
    }

    static func encode(_ v: UInt64) -> [UInt8] {
        var v = v
        var out: [UInt8] = []
        repeat {
            var b = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
        } while v != 0
        return out
    }

    static func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }
}
