import Foundation

/// Bech32 as age uses it (BIP 173, classic checksum, no length limit: C2SP age.md, "Conventions"):
/// enough to read age's keys, `age1…` / `age1pq1…` recipients and `AGE-SECRET-KEY-1…` /
/// `AGE-SECRET-KEY-PQ-1…` identities.
enum Bech32 {
    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l".utf8)
    private static let values: [Int8] = {
        var t = [Int8](repeating: -1, count: 128)
        for (i, c) in charset.enumerated() { t[Int(c)] = Int8(i) }
        return t
    }()

    private static func polymod(_ v: [UInt8]) -> UInt32 {
        let gen: [UInt32] = [0x3b6a_57b2, 0x2650_8e6d, 0x1ea1_19fa, 0x3d42_33dd, 0x2a14_62b3]
        var chk: UInt32 = 1
        for x in v {
            let top = chk >> 25
            chk = (chk & 0x1ff_ffff) << 5 ^ UInt32(x)
            for i in 0..<5 where (top >> i) & 1 == 1 { chk ^= gen[i] }
        }
        return chk
    }

    /// The human-readable part (lowercased) and the data bytes, or nil when the string is not valid
    /// Bech32: mixed case, a character outside the alphabet, a wrong checksum or non-zero padding.
    static func decode(_ s: String) -> (hrp: String, data: [UInt8])? {
        let bytes = Array(s.utf8)
        guard bytes.allSatisfy({ $0 >= 33 && $0 <= 126 }) else { return nil }
        let lower = s.lowercased(), upper = s.uppercased()
        guard s == lower || s == upper else { return nil }
        let b = Array(lower.utf8)
        guard let sep = b.lastIndex(of: UInt8(ascii: "1")), sep >= 1, b.count - sep - 1 >= 6 else { return nil }
        let hrp = Array(b[..<sep])
        var five: [UInt8] = []
        five.reserveCapacity(b.count - sep - 1)
        for c in b[(sep + 1)...] {
            guard c < 128, values[Int(c)] >= 0 else { return nil }
            five.append(UInt8(values[Int(c)]))
        }
        let expanded = hrp.map { $0 >> 5 } + [0] + hrp.map { $0 & 31 }
        guard polymod(expanded + five) == 1 else { return nil }
        // 5-bit groups to bytes; the padding must be shorter than 5 bits and zero.
        var out: [UInt8] = []
        out.reserveCapacity((five.count - 6) * 5 / 8)
        var acc: UInt32 = 0, bits = 0
        for v in five.dropLast(6) {
            acc = acc << 5 | UInt32(v)
            bits += 5
            if bits >= 8 { bits -= 8; out.append(UInt8((acc >> UInt32(bits)) & 0xff)) }
        }
        guard bits < 5, acc & ((1 << UInt32(bits)) - 1) == 0 else { return nil }
        return (String(decoding: hrp, as: UTF8.self), out)
    }
}
