import CDeflate
import CXipShims

/// CRC-32 (ISO-HDLC), as used by ZIP and gzip. libdeflate's PMULL+CRC implementation
/// runs at memory bandwidth on Apple Silicon (SPIKE_FASE0.md §3).
enum CRC32 {
    static func update(_ crc: UInt32, _ data: UnsafeRawBufferPointer) -> UInt32 {
        guard let p = data.baseAddress, data.count > 0 else { return crc }
        return libdeflate_crc32(crc, p, data.count)
    }

    static func checksum(_ data: UnsafeRawBufferPointer) -> UInt32 { update(0, data) }

    static func checksum(_ bytes: [UInt8]) -> UInt32 { bytes.withUnsafeBytes { update(0, $0) } }

    /// CRC of A‖B from crc(A), crc(B) and |B|.
    static func combine(_ a: UInt32, _ b: UInt32, lengthB: Int64) -> UInt32 {
        xs_crc32_combine(a, b, UInt64(lengthB))
    }
}
