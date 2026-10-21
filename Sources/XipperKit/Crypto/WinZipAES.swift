import CommonCrypto
import Darwin

/// WinZip AES encryption (AE-1/AE-2), the de-facto standard for encrypted ZIP:
/// PBKDF2-HMAC-SHA1 (1000 iterations) derives an AES key, an HMAC key and a 2-byte
/// password verifier; data is AES-CTR encrypted and authenticated with HMAC-SHA1-80.
///
/// Entry layout: salt ‖ verifier(2) ‖ ciphertext ‖ authcode(10).
enum WinZipAES {
    enum Strength: UInt8, Sendable {
        case aes128 = 1, aes192 = 2, aes256 = 3
        var keyLength: Int { [16, 24, 32][Int(rawValue) - 1] }
        var saltLength: Int { [8, 12, 16][Int(rawValue) - 1] }
    }

    static let verifierLength = 2
    static let macLength = 10
    static let iterations: UInt32 = 1000

    /// Bytes added to the compressed size of an AES-256 entry.
    static func overhead(_ s: Strength) -> Int { s.saltLength + verifierLength + macLength }

    struct Keys {
        var aes: [UInt8]
        var mac: [UInt8]
        var verifier: [UInt8]
    }

    static func deriveKeys(password: [UInt8], salt: [UInt8], strength: Strength) throws -> Keys {
        let kl = strength.keyLength
        var dk = [UInt8](repeating: 0, count: 2 * kl + verifierLength)
        let r = password.withUnsafeBufferPointer { pw in
            pw.baseAddress!.withMemoryRebound(to: CChar.self, capacity: max(pw.count, 1)) { pwc in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pwc, pw.count, salt, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), iterations, &dk, dk.count)
            }
        }
        if r != kCCSuccess { throw XipperError.codec("PBKDF2 failed (\(r))") }
        return Keys(aes: Array(dk[0..<kl]), mac: Array(dk[kl..<2 * kl]), verifier: Array(dk[(2 * kl)..<dk.count]))
    }
}

/// AES-CTR with a 128-bit little-endian counter starting at 1 (Gladman/WinZip convention).
/// CommonCrypto's CTR mode is big-endian, so the keystream is built from AES-ECB,
/// which still runs on the ARMv8 AES instructions (≈13 GB/s, SPIKE_FASE0.md §4).
final class AESCTRLittleEndian {
    private var cryptor: CCCryptorRef?
    private var counter: UInt64 = 0
    private let scratch: UnsafeMutableRawPointer
    private static let scratchBlocks = 4096  // 64 KiB of keystream per ECB call
    private var leftover = [UInt8](repeating: 0, count: 16)
    private var leftoverPos = 16

    init(key: [UInt8]) throws {
        let r = CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeECB), CCAlgorithm(kCCAlgorithmAES),
                                        CCPadding(ccNoPadding), nil, key, key.count, nil, 0, 0, 0, &cryptor)
        if r != kCCSuccess { throw XipperError.codec("AES init failed (\(r))") }
        scratch = .allocate(byteCount: Self.scratchBlocks * 16, alignment: 16)
    }

    deinit {
        CCCryptorRelease(cryptor)
        scratch.deallocate()
    }

    /// Fills `scratch` with `blocks` keystream blocks.
    private func keystream(blocks: Int) {
        let w = scratch.assumingMemoryBound(to: UInt64.self)
        for i in 0..<blocks {
            counter &+= 1
            w[2 * i] = counter.littleEndian
            w[2 * i + 1] = 0
        }
        var moved = 0
        CCCryptorUpdate(cryptor, scratch, blocks * 16, scratch, blocks * 16, &moved)
    }

    /// XORs the keystream into `buf` in place (encryption and decryption are identical).
    func apply(_ buf: UnsafeMutableRawBufferPointer) {
        guard var p = buf.baseAddress else { return }
        var n = buf.count
        while leftoverPos < 16 && n > 0 {
            p.storeBytes(of: p.load(as: UInt8.self) ^ leftover[leftoverPos], as: UInt8.self)
            leftoverPos += 1; p += 1; n -= 1
        }
        while n >= 16 {
            let blocks = min(n / 16, Self.scratchBlocks)
            keystream(blocks: blocks)
            let words = blocks * 2
            let ks = scratch.assumingMemoryBound(to: UInt64.self)
            for i in 0..<words {
                let v = (p + i * 8).loadUnaligned(as: UInt64.self) ^ ks[i]
                (p + i * 8).storeBytes(of: v, as: UInt64.self)
            }
            p += blocks * 16; n -= blocks * 16
        }
        if n > 0 {
            keystream(blocks: 1)
            for i in 0..<16 { leftover[i] = scratch.load(fromByteOffset: i, as: UInt8.self) }
            leftoverPos = 0
            while n > 0 {
                p.storeBytes(of: p.load(as: UInt8.self) ^ leftover[leftoverPos], as: UInt8.self)
                leftoverPos += 1; p += 1; n -= 1
            }
        }
    }
}

/// Streaming HMAC-SHA1.
final class HMACSHA1 {
    private let ctx = UnsafeMutablePointer<CCHmacContext>.allocate(capacity: 1)
    init(key: [UInt8]) { CCHmacInit(ctx, CCHmacAlgorithm(kCCHmacAlgSHA1), key, key.count) }
    deinit { ctx.deallocate() }
    func update(_ data: UnsafeRawBufferPointer) {
        if let p = data.baseAddress, data.count > 0 { CCHmacUpdate(ctx, p, data.count) }
    }
    func finalize() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CCHmacFinal(ctx, &out)
        return out
    }
}

/// Encrypts one entry's compressed data. Usage: `header` → `encrypt` (any number of calls) → `trailer`.
/// Encrypts the data of one ZIP entry: header before the data, trailer after it.
protocol ZipEntryEncryptor: AnyObject {
    var header: [UInt8] { get }
    var trailer: [UInt8] { get }
    func encrypt(_ bytes: inout [UInt8])
}

final class WinZipAESEncryptor: ZipEntryEncryptor {
    let header: [UInt8]
    private let ctr: AESCTRLittleEndian
    private let mac: HMACSHA1

    init(password: [UInt8], strength: WinZipAES.Strength = .aes256) throws {
        var salt = [UInt8](repeating: 0, count: strength.saltLength)
        arc4random_buf(&salt, salt.count)
        let keys = try WinZipAES.deriveKeys(password: password, salt: salt, strength: strength)
        header = salt + keys.verifier
        ctr = try AESCTRLittleEndian(key: keys.aes)
        mac = HMACSHA1(key: keys.mac)
    }

    func encrypt(_ buf: UnsafeMutableRawBufferPointer) {
        ctr.apply(buf)
        mac.update(UnsafeRawBufferPointer(buf))
    }

    func encrypt(_ bytes: inout [UInt8]) { bytes.withUnsafeMutableBytes { encrypt($0) } }

    var trailer: [UInt8] { Array(mac.finalize().prefix(WinZipAES.macLength)) }
}

/// Decrypts one entry. Throws `wrongPassword` immediately if the verifier does not match.
final class WinZipAESDecryptor {
    private let ctr: AESCTRLittleEndian
    private let mac: HMACSHA1

    init(password: [UInt8], salt: [UInt8], verifier: [UInt8], strength: WinZipAES.Strength, entry: String) throws {
        let keys = try WinZipAES.deriveKeys(password: password, salt: salt, strength: strength)
        if keys.verifier != verifier { throw XipperError.wrongPassword(entry: entry) }
        ctr = try AESCTRLittleEndian(key: keys.aes)
        mac = HMACSHA1(key: keys.mac)
    }

    /// MAC is computed over ciphertext, so it is updated before decrypting.
    func decrypt(_ buf: UnsafeMutableRawBufferPointer) {
        mac.update(UnsafeRawBufferPointer(buf))
        ctr.apply(buf)
    }

    func verify(_ authCode: UnsafeRawBufferPointer, entry: String) throws {
        let expected = mac.finalize().prefix(WinZipAES.macLength)
        // Constant-time comparison.
        var diff: UInt8 = 0
        for (a, b) in zip(expected, authCode) { diff |= a ^ b }
        if diff != 0 || authCode.count != WinZipAES.macLength {
            throw XipperError.integrity(entry: entry, detail: "AES authentication code mismatch")
        }
    }
}

/// Traditional PKWARE encryption ("ZipCrypto"). Cryptographically broken: Xipper writes it
/// only on explicit request, after a warning (UI_SPEC 2.7), for receivers without AES support.
final class ZipCryptoEncryptor: ZipEntryEncryptor {
    private var k0: UInt32 = 0x1234_5678
    private var k1: UInt32 = 0x2345_6789
    private var k2: UInt32 = 0x3456_7890
    private(set) var header: [UInt8] = []
    var trailer: [UInt8] { [] }

    @inline(__always) private func update(_ b: UInt8) {
        k0 = ZipCryptoDecryptor.crcStep(k0, b)
        k1 = (k1 &+ (k0 & 0xff)) &* 134_775_813 &+ 1
        k2 = ZipCryptoDecryptor.crcStep(k2, UInt8(truncatingIfNeeded: k1 >> 24))
    }

    @inline(__always) private func encryptByte(_ p: UInt8) -> UInt8 {
        let t = UInt16(truncatingIfNeeded: k2 | 2)
        let c = p ^ UInt8(truncatingIfNeeded: (UInt32(t) &* UInt32(t ^ 1)) >> 8)
        update(p)
        return c
    }

    /// `check` is the last header byte the reader verifies (here: the DOS time high byte,
    /// because entries are written with a data descriptor).
    init(password: [UInt8], check: UInt8) {
        for b in password { update(b) }
        var plain = [UInt8](repeating: 0, count: 12)
        arc4random_buf(&plain, 11)
        plain[11] = check
        header = plain.map { encryptByte($0) }
    }

    func encrypt(_ bytes: inout [UInt8]) {
        for i in bytes.indices { bytes[i] = encryptByte(bytes[i]) }
    }
}

final class ZipCryptoDecryptor {
    private var k0: UInt32 = 0x1234_5678
    private var k1: UInt32 = 0x2345_6789
    private var k2: UInt32 = 0x3456_7890

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    @inline(__always) static func crcStep(_ c: UInt32, _ b: UInt8) -> UInt32 {
        table[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8)
    }
    @inline(__always) private static func crc(_ c: UInt32, _ b: UInt8) -> UInt32 { crcStep(c, b) }

    @inline(__always) private func update(_ b: UInt8) {
        k0 = Self.crc(k0, b)
        k1 = (k1 &+ (k0 & 0xff)) &* 134_775_813 &+ 1
        k2 = Self.crc(k2, UInt8(truncatingIfNeeded: k1 >> 24))
    }

    @inline(__always) private func decryptByte(_ c: UInt8) -> UInt8 {
        let t = UInt16(truncatingIfNeeded: k2 | 2)
        let p = c ^ UInt8(truncatingIfNeeded: (UInt32(t) &* UInt32(t ^ 1)) >> 8)
        update(p)
        return p
    }

    /// `header` is the 12-byte encryption header; `check` the expected value of its last byte
    /// (CRC high byte, or DOS time high byte when the entry uses a data descriptor).
    init(password: [UInt8], header: UnsafeRawBufferPointer, check: UInt8, entry: String) throws {
        for b in password { update(b) }
        var last: UInt8 = 0
        for b in header { last = decryptByte(b) }
        if last != check { throw XipperError.wrongPassword(entry: entry) }
    }

    func decrypt(_ buf: UnsafeMutableRawBufferPointer) {
        guard let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        for i in 0..<buf.count { p[i] = decryptByte(p[i]) }
    }
}
