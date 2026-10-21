import Foundation

/// ZIP constants (APPNOTE.TXT 6.3.10 plus the WinZip AES and zstd/xz method registrations).
enum Zip {
    static let localSignature: UInt32 = 0x0403_4b50
    static let centralSignature: UInt32 = 0x0201_4b50
    static let endSignature: UInt32 = 0x0605_4b50
    static let zip64EndSignature: UInt32 = 0x0606_4b50
    static let zip64LocatorSignature: UInt32 = 0x0706_4b50
    static let dataDescriptorSignature: UInt32 = 0x0807_4b50

    enum Method: UInt16 {
        case store = 0, deflate = 8, deflate64 = 9, bzip2 = 12, lzma = 14, zstd = 93, xz = 95, aes = 99
    }

    enum Flag {
        static let encrypted: UInt16 = 1 << 0
        static let dataDescriptor: UInt16 = 1 << 3
        static let strongEncryption: UInt16 = 1 << 6
        static let utf8: UInt16 = 1 << 11
    }

    enum Extra {
        static let zip64: UInt16 = 0x0001
        static let extendedTimestamp: UInt16 = 0x5455
        static let unicodePath: UInt16 = 0x7075
        static let aes: UInt16 = 0x9901
    }

    enum Host: UInt8 { case msdos = 0, unix = 3, ntfs = 10, vfat = 14, osx = 19 }

    /// "Version made by": Unix, spec 6.3.
    static let versionMadeBy: UInt16 = UInt16(Host.unix.rawValue) << 8 | 63

    static let max16: UInt64 = 0xFFFF
    static let max32: UInt64 = 0xFFFF_FFFF
}

/// MS-DOS date/time (local time, 2-second resolution, 1980–2107).
enum DOSDateTime {
    static func encode(_ date: Date) -> (time: UInt16, date: UInt16) {
        var t = time_t(max(315_532_800, min(date.timeIntervalSince1970, 4_354_819_198)))
        var tmv = tm()
        localtime_r(&t, &tmv)
        let time = UInt16(tmv.tm_hour) << 11 | UInt16(tmv.tm_min) << 5 | UInt16(tmv.tm_sec / 2)
        let day = UInt16(max(0, Int(tmv.tm_year) - 80)) << 9 | UInt16(tmv.tm_mon + 1) << 5 | UInt16(tmv.tm_mday)
        return (time, day)
    }

    static func decode(time: UInt16, date: UInt16) -> Date {
        var tmv = tm()
        tmv.tm_year = Int32(date >> 9) + 80
        tmv.tm_mon = Int32((date >> 5) & 0xF) - 1
        tmv.tm_mday = Int32(date & 0x1F)
        tmv.tm_hour = Int32(time >> 11)
        tmv.tm_min = Int32((time >> 5) & 0x3F)
        tmv.tm_sec = Int32(time & 0x1F) * 2
        tmv.tm_isdst = -1
        return Date(timeIntervalSince1970: Double(mktime(&tmv)))
    }
}

/// Encryption applied to an entry.
public enum EntryEncryption: Sendable, Equatable {
    case none
    /// Traditional PKWARE encryption (weak; read-only support).
    case zipCrypto
    /// WinZip AES; `vendorVersion` 1 = AE-1 (CRC stored), 2 = AE-2 (CRC zeroed).
    case aes(strength: UInt8, vendorVersion: UInt16, actualMethod: UInt16)
}

/// One entry of an archive, format-independent view used by listing and extraction.
public struct ArchiveEntry: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case file, directory, symlink, hardlink }

    public var path: String
    public var kind: Kind
    public var uncompressedSize: Int64
    public var compressedSize: Int64
    public var modified: Date?
    /// Permission bits (0o7777), if the archive records them.
    public var permissions: UInt16?
    public var encryption: EntryEncryption
    /// Format-specific method name ("deflate", "zstd", …).
    public var method: String
    /// Symlink / hard link target.
    public var linkTarget: String?

    public var isEncrypted: Bool { encryption != .none }
}

/// ZIP-specific entry record parsed from the central directory.
struct ZipEntryRecord: Sendable {
    var entry: ArchiveEntry
    var rawName: [UInt8]
    var method: UInt16
    var flags: UInt16
    var crc: UInt32
    var compressedSize: Int64
    var uncompressedSize: Int64
    var localHeaderOffset: Int64
    var dosTime: UInt16
    var hostSystem: UInt8
    /// Absolute file offset of the entry's data; resolved from the local header.
    var dataOffset: Int64 = -1
}

func zipMethodName(_ m: UInt16) -> String {
    switch Zip.Method(rawValue: m) {
    case .store: return "store"
    case .deflate: return "deflate"
    case .deflate64: return "deflate64"
    case .bzip2: return "bzip2"
    case .lzma: return "lzma"
    case .zstd: return "zstd"
    case .xz: return "xz"
    case .aes: return "aes"
    case nil: return "method \(m)"
    }
}
