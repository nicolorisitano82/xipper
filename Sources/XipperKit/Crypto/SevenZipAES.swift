import CommonCrypto
import Darwin
import Synchronization

/// 7z AES-256 (method 06F10701): AES-256-CBC, key = SHA-256 iterated 2^NumCyclesPower times over
/// salt ‖ UTF-16LE password ‖ 64-bit counter. There is no password verifier: a wrong password
/// shows up as a decoding or CRC error.
enum SevenZipAES {
    static let defaultCyclesPower: UInt8 = 19
    /// 7-Zip refuses more (2^24 rounds already take seconds).
    static let maxCyclesPower: UInt8 = 24

    struct Props: Sendable {
        var cyclesPower: UInt8
        var salt: [UInt8]
        /// Always 16 bytes (shorter stored IVs are zero-padded).
        var iv: [UInt8]
    }

    static func parseProps(_ p: [UInt8]) throws -> Props {
        guard let b0 = p.first else { throw XipperError.corrupt("7z AES: missing properties") }
        let power = b0 & 0x3F
        if b0 & 0xC0 == 0 {
            if p.count != 1 { throw XipperError.corrupt("7z AES: bad properties") }
            return Props(cyclesPower: power, salt: [], iv: [UInt8](repeating: 0, count: 16))
        }
        guard p.count >= 2 else { throw XipperError.corrupt("7z AES: bad properties") }
        let b1 = p[1]
        let saltSize = Int((b0 >> 7) & 1) + Int(b1 >> 4)
        let ivSize = Int((b0 >> 6) & 1) + Int(b1 & 0x0F)
        guard p.count == 2 + saltSize + ivSize else { throw XipperError.corrupt("7z AES: bad properties") }
        if power > maxCyclesPower && power != 0x3F { throw XipperError.unsupported("7z AES with 2^\(power) key rounds") }
        let salt = Array(p[2..<(2 + saltSize)])
        var iv = Array(p[(2 + saltSize)...])
        iv += [UInt8](repeating: 0, count: 16 - iv.count)
        return Props(cyclesPower: power, salt: salt, iv: iv)
    }

    /// No salt (as 7-Zip writes), 16-byte IV.
    static func encodeProps(cyclesPower: UInt8, iv: [UInt8]) -> [UInt8] {
        [cyclesPower | 0x40, UInt8(iv.count - 1)] + iv
    }

    /// 7-Zip hashes the password as UTF-16LE (what it reads from the terminal or the dialog).
    static func passwordBytes(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        for u in s.precomposedStringWithCanonicalMapping.utf16 { out.append(UInt8(u & 0xFF)); out.append(UInt8(u >> 8)) }
        return out
    }

    static func deriveKey(password: [UInt8], salt: [UInt8], cyclesPower: UInt8) -> [UInt8] {
        if cyclesPower == 0x3F {
            var key = Array((salt + password).prefix(32))
            key += [UInt8](repeating: 0, count: 32 - key.count)
            return key
        }
        // One SHA-256 over all rounds; rounds are hashed in batches to keep the call count low.
        let unit = salt.count + password.count + 8
        let rounds = UInt64(1) << UInt64(cyclesPower)
        let batch = Int(min(rounds, 4096))
        var buf = [UInt8](repeating: 0, count: unit * batch)
        for i in 0..<batch {
            buf.replaceSubrange((i * unit)..<(i * unit + salt.count), with: salt)
            buf.replaceSubrange((i * unit + salt.count)..<(i * unit + salt.count + password.count), with: password)
        }
        var ctx = CC_SHA256_CTX()
        CC_SHA256_Init(&ctx)
        var round: UInt64 = 0
        buf.withUnsafeMutableBytes { b in
            while round < rounds {
                let n = Int(min(UInt64(batch), rounds - round))
                for i in 0..<n {
                    b.storeBytes(of: (round + UInt64(i)).littleEndian, toByteOffset: i * unit + unit - 8, as: UInt64.self)
                }
                CC_SHA256_Update(&ctx, b.baseAddress, CC_LONG(n * unit))
                round += UInt64(n)
            }
        }
        var key = [UInt8](repeating: 0, count: 32)
        CC_SHA256_Final(&key, &ctx)
        return key
    }
}

/// Derived keys of one archive: every folder and the header normally share salt and rounds,
/// and 2^19 rounds cost tens of milliseconds.
final class SevenZipKeyCache: Sendable {
    let password: [UInt8]
    private let keys = Mutex<[[UInt8]: [UInt8]]>([:])

    init(password: [UInt8]) { self.password = password }

    func key(salt: [UInt8], cyclesPower: UInt8) -> [UInt8] {
        let id = [cyclesPower] + salt
        if let k = keys.withLock({ $0[id] }) { return k }
        let k = SevenZipAES.deriveKey(password: password, salt: salt, cyclesPower: cyclesPower)
        keys.withLock { $0[id] = k }
        return k
    }
}

/// AES-256-CBC without padding, streaming in whole blocks.
final class AESCBCCoder: StreamTransform {
    private var cryptor: CCCryptorRef?
    private var pending: [UInt8] = []
    private let encrypt: Bool
    private let scratch = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16)

    init(key: [UInt8], iv: [UInt8], encrypt: Bool) throws {
        self.encrypt = encrypt
        let r = CCCryptorCreateWithMode(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCMode(kCCModeCBC), CCAlgorithm(kCCAlgorithmAES),
                                        CCPadding(ccNoPadding), iv, key, key.count, nil, 0, 0, 0, &cryptor)
        if r != kCCSuccess { throw XipperError.codec("AES init failed (\(r))") }
    }

    deinit {
        CCCryptorRelease(cryptor)
        scratch.deallocate()
    }

    private func run(_ p: UnsafeRawPointer, _ n: Int, _ sink: ByteSink) throws {
        var off = 0
        while off < n {
            let len = min(n - off, 1 << 20)
            var moved = 0
            let r = CCCryptorUpdate(cryptor, p + off, len, scratch, 1 << 20, &moved)
            if r != kCCSuccess { throw XipperError.codec("AES failed (\(r))") }
            try sink(UnsafeRawBufferPointer(start: scratch, count: moved))
            off += len
        }
    }

    func process(_ input: UnsafeRawBufferPointer, _ sink: ByteSink) throws {
        guard var base = input.baseAddress, !input.isEmpty else { return }
        var count = input.count
        if !pending.isEmpty {
            let take = min(16 - pending.count, count)
            pending.append(contentsOf: UnsafeRawBufferPointer(start: base, count: take))
            base += take; count -= take
            if pending.count < 16 { return }
            let block = pending
            pending.removeAll(keepingCapacity: true)
            try block.withUnsafeBytes { try run($0.baseAddress!, 16, sink) }
        }
        let whole = count & ~15
        if whole > 0 { try run(base, whole, sink) }
        if count > whole { pending.append(contentsOf: UnsafeRawBufferPointer(start: base + whole, count: count - whole)) }
    }

    /// Encryption pads the last block with zeros (as 7-Zip does); decryption of a partial
    /// block means the packed stream was truncated.
    func finish(_ sink: ByteSink) throws {
        guard !pending.isEmpty else { return }
        if !encrypt { throw XipperError.corrupt("7z AES stream is not a whole number of blocks") }
        let block = pending + [UInt8](repeating: 0, count: 16 - pending.count)
        pending.removeAll()
        try block.withUnsafeBytes { try run($0.baseAddress!, 16, sink) }
    }
}
