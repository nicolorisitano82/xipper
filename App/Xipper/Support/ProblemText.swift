import Foundation
import XipperKit

/// User-facing text for the problems found by a test or blocked during an extraction (5.2, 6.3).
extension SkippedEntry.Problem {
    var message: String {
        switch self {
        case .escapesDestination: String(localized: "Percorso fuori dalla destinazione")
        case .invalidName: String(localized: "Nome non valido")
        case .throughSymlink: String(localized: "Scrittura attraverso un symlink esterno")
        case .symlinkOutside: String(localized: "Symlink che punta fuori dalla destinazione")
        case .symlinksDisabled: String(localized: "Symlink disattivati nelle Impostazioni")
        case .specialFile: String(localized: "File speciale (dispositivo o FIFO)")
        case .alreadyExists: String(localized: "Esiste già: saltato")
        case let .checksumMismatch(expected, actual):
            String(localized: "CRC non corrispondente (atteso \(Self.hex(expected)), letto \(Self.hex(actual)))")
        case let .truncated(read?, expected?):
            String(localized: "Dati troncati: letti \(read.byteText) su \(expected.byteText)")
        case .truncated: String(localized: "Dati troncati")
        case .authenticationFailed: String(localized: "Autenticazione AES non valida: dati alterati")
        case .missingEndMarker: String(localized: "Marker EOF mancante: file troncato")
        case .wrongPassword: String(localized: "Password errata")
        case .passwordRequired: String(localized: "Serve la password")
        case .unsupported: String(localized: "Metodo di compressione non supportato")
        case .damaged, .other: String(localized: "Dati danneggiati")
        }
    }

    private static func hex(_ v: UInt32) -> String {
        let s = String(v, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 8 - s.count)) + s
    }
}

extension SkippedEntry {
    /// Where a blocked entry would have written (6.3), relative to the extraction folder.
    func intendedTarget(in destination: URL?) -> String {
        let base = destination?.path ?? ""
        switch problem {
        case let .symlinkOutside(target):
            let parent = ((base as NSString).appendingPathComponent(path) as NSString).deletingLastPathComponent
            return target.hasPrefix("/") ? target : (((parent as NSString).appendingPathComponent(target) as NSString).standardizingPath as NSString).abbreviatingWithTildeInPath
        case .escapesDestination:
            return (((base as NSString).appendingPathComponent(path) as NSString).standardizingPath as NSString).abbreviatingWithTildeInPath
        default:
            return path
        }
    }
}

extension SkippedEntry: @retroactive Identifiable {
    public var id: String { path }
}
