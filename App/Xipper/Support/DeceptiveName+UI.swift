import XipperKit

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
