import XipperKit

// User-facing names and explanations for XipperKit values.

extension DeceptiveName.Reason {
    /// What the name hides, for the inspector.
    var explanation: String {
        switch self {
        case .bidiControl:
            String(localized: "Contiene caratteri che invertono la fine del nome: l'estensione che vedi non è quella vera.")
        case let .doubleExtension(shown, real):
            String(localized: "Sembra un file .\(shown) ma è un .\(real), che si apre come programma.")
        case let .paddedExtension(real):
            String(localized: "Gli spazi nascondono la vera estensione, .\(real), che si apre come programma.")
        }
    }
}

extension ZipNameEncoding {
    /// Menu title: the language people know, then the code page.
    var title: String {
        switch self {
        case .cp437: String(localized: "Occidentale (DOS, CP437)")
        case .cp850: String(localized: "Europa occidentale (DOS, CP850)")
        case .cp866: String(localized: "Cirillico (DOS, CP866)")
        case .windows1252: String(localized: "Occidentale (Windows-1252)")
        case .windows1251: String(localized: "Cirillico (Windows-1251)")
        case .shiftJIS: String(localized: "Giapponese (Shift-JIS)")
        case .gbk: String(localized: "Cinese semplificato (GBK)")
        case .big5: String(localized: "Cinese tradizionale (Big5)")
        case .eucKR: String(localized: "Coreano (EUC-KR)")
        }
    }
}
