import CoreFoundation
import Foundation
import Synchronization

/// The code page of ZIP names written without the UTF-8 flag. APPNOTE says CP437, but Windows
/// writes the system's OEM code page (CP866 in Russia, Shift-JIS in Japan, GBK in China…), so
/// such names come out as gibberish. Xipper guesses the code page from all legacy names of the
/// archive together, scoring how plausible each candidate's byte structure is, and keeps CP437
/// unless another code page is clearly better. The user can force one (`Xipper.setZipNameEncoding`).
public enum ZipNameEncoding: String, Sendable, CaseIterable, Identifiable {
    case cp437, cp850, cp866, windows1252, windows1251, shiftJIS = "shiftjis", gbk, big5, eucKR = "euckr"

    public var id: String { rawValue }

    public var encoding: String.Encoding {
        func cf(_ e: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
        }
        switch self {
        case .cp437: return cf(.dosLatinUS)
        case .cp850: return cf(.dosLatin1)
        case .cp866: return cf(.dosRussian)
        case .windows1252: return .windowsCP1252
        case .windows1251: return .windowsCP1251
        case .shiftJIS: return .shiftJIS
        case .gbk: return cf(.GB_18030_2000)
        case .big5: return cf(.big5)
        case .eucKR: return cf(.EUC_KR)
        }
    }

    /// Candidates of the automatic guess (the Windows ANSI pages are only chosen by hand: ZIP
    /// tools write the OEM ones).
    static let guessed: [ZipNameEncoding] = [.cp437, .cp866, .shiftJIS, .gbk, .big5, .eucKR]

    public func decode(_ raw: [UInt8]) -> String? { String(data: Data(raw), encoding: encoding) }

    /// How plausible `names` are in this code page: 0…1 over the non-ASCII characters, nil if
    /// they are not valid in it.
    func score(_ names: [[UInt8]]) -> Double? {
        var weight = 0.0, units = 0
        for raw in names {
            guard decode(raw) != nil else { return nil }
            var i = 0
            while i < raw.count {
                let b = raw[i]
                if b < 0x80 { i += 1; continue }
                units += 1
                switch self {
                case .cp437, .cp850:
                    // Accented Latin letters, ñ, ß; box drawing, Greek and math are not names.
                    weight += (0x80...0xA5).contains(b) || b == 0xE1 ? 1 : 0
                    i += 1
                case .cp866:
                    weight += (0x80...0xAF).contains(b) || (0xE0...0xF1).contains(b) ? 1 : 0
                    i += 1
                case .shiftJIS:
                    if (0xA1...0xDF).contains(b) { i += 1; continue }  // half-width katakana: rare in names
                    let w: Double = b == 0x82 || b == 0x83 || (0x88...0x97).contains(b) ? 1 : (b == 0x81 ? 0.5 : 0.3)
                    weight += w
                    i += 2
                case .gbk:
                    let w: Double = (0xB0...0xD7).contains(b) ? 1 : (0xA1...0xA9).contains(b) ? 0.5 : (0xD8...0xF7).contains(b) ? 0.3 : 0
                    weight += w
                    i += (0x30...0x39).contains(i + 1 < raw.count ? raw[i + 1] : 0) ? 4 : 2
                case .big5:
                    let w: Double = (0xA4...0xC6).contains(b) ? 1 : (0xA1...0xA3).contains(b) ? 0.5 : (0xC9...0xF9).contains(b) ? 0.3 : 0
                    weight += w
                    i += 2
                case .eucKR:
                    let w: Double = (0xB0...0xC8).contains(b) ? 1 : (0xA1...0xAC).contains(b) ? 0.5 : (0xCA...0xFD).contains(b) ? 0.3 : 0
                    weight += w
                    i += 2
                case .windows1252, .windows1251:
                    weight += 1
                    i += 1
                }
            }
        }
        return units == 0 ? 1 : weight / Double(units)
    }

    /// The code page for these legacy names: CP437 unless a candidate scores clearly higher.
    /// Some pages share their byte structure (EUC-KR Hangul and GBK level-1 Hanzi): on a tie the
    /// one of the Mac's preferred language wins, else the earlier candidate.
    static func guess(_ names: [[UInt8]], languages: [String] = Locale.preferredLanguages) -> ZipNameEncoding {
        guard !names.isEmpty else { return .cp437 }
        let base = cp437.score(names) ?? 0
        let scored = guessed.filter { $0 != .cp437 }.compactMap { c in c.score(names).map { (c, $0) } }
        guard let top = scored.map(\.1).max(), top >= 0.75, top > base + 0.05 else { return .cp437 }
        let tied = scored.filter { $0.1 >= top - 0.001 }.map(\.0)
        let preferred = languages.lazy.compactMap { lang -> ZipNameEncoding? in
            switch lang.prefix(2) {
            case "ko": .eucKR
            case "ja": .shiftJIS
            case "ru", "uk", "be", "bg": .cp866
            case "zh": lang.contains("Hant") || lang.hasSuffix("TW") || lang.hasSuffix("HK") ? .big5 : .gbk
            default: nil
            }
        }.first { tied.contains($0) }
        return preferred ?? tied[0]
    }
}

extension Xipper {
    private static let nameEncodingOverrides = Mutex<[String: ZipNameEncoding]>([:])

    /// Forces the code page of `archive`'s legacy ZIP names for every later operation in this
    /// process (nil: back to the automatic guess).
    public static func setZipNameEncoding(_ encoding: ZipNameEncoding?, for archive: URL) {
        nameEncodingOverrides.withLock { $0[archive.standardizedFileURL.path] = encoding }
    }

    static func zipNameEncodingOverride(_ path: String) -> ZipNameEncoding? {
        nameEncodingOverrides.withLock { $0[URL(fileURLWithPath: path).standardizedFileURL.path] }
    }

    /// For a ZIP with names written without the UTF-8 flag (and not valid UTF-8): the code page
    /// in use (forced or guessed) and whether it was guessed. nil when every name is Unicode.
    public static func zipNameEncoding(of archive: URL) throws -> (encoding: ZipNameEncoding, guessed: Bool)? {
        let z = try ZipArchive(path: archive.standardizedFileURL.path)
        guard let e = z.nameEncoding else { return nil }
        return (e, zipNameEncodingOverride(archive.path) == nil)
    }
}
