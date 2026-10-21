import AppIntents
import Foundation
import XipperKit

/// Shortcuts actions (Comandi Rapidi): compress, extract and verify without opening a window.
/// They call XipperKit directly and return the files they produce, so they chain with other actions.

enum IntentFormat: String, AppEnum {
    case zip, tarZstd, tarGzip, tarXz

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Formato"
    static let caseDisplayRepresentations: [IntentFormat: DisplayRepresentation] = [
        .zip: "ZIP", .tarZstd: "tar.zst", .tarGzip: "tar.gz", .tarXz: "tar.xz",
    ]

    var format: ArchiveFormat {
        switch self {
        case .zip: .zip
        case .tarZstd: .tarZstd
        case .tarGzip: .tarGzip
        case .tarXz: .tarXz
        }
    }
}

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case noFiles
    case notAnArchive(String)
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noFiles: "Nessun file da elaborare."
        case let .notAnArchive(name): "\(name) non è un archivio riconosciuto."
        case let .failed(reason): "\(reason)"
        }
    }
}

/// Files handed over by Shortcuts: real paths when the file lives on disk, otherwise a copy.
private func localURLs(_ files: [IntentFile]) throws -> [URL] {
    try files.map { file in
        if let url = file.fileURL { return url }
        let dir = EntryStaging.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(file.filename)
        try file.data.write(to: url)
        return url
    }
}

private func describe(_ error: Error) -> IntentFailure {
    (error as? XipperError).map { .failed(Job.localized($0)) } ?? .failed(error.localizedDescription)
}

struct CompressIntent: AppIntent {
    static let title: LocalizedStringResource = "Comprimi con Xipper"
    static let description = IntentDescription("Crea un archivio con i file indicati, accanto al primo.")

    @Parameter(title: "File", supportedContentTypes: [.item])
    var files: [IntentFile]

    @Parameter(title: "Formato", default: .zip)
    var format: IntentFormat

    @Parameter(title: "Nome")
    var name: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Comprimi \(\.$files) in \(\.$format)") { \.$name }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let sources = try localURLs(files)
        guard let first = sources.first else { throw IntentFailure.noFiles }
        let fmt = sources.count > 1 && !ArchiveFormat.multiItem.contains(format.format) ? .zip : format.format
        let base = name.flatMap { $0.isEmpty ? nil : $0 } ?? (sources.count == 1 ? first.lastPathComponent : "Archivio")
        let dest = uniqueURL(first.deletingLastPathComponent().appendingPathComponent("\(base).\(fmt.fileExtension)"))
        let preset = LevelPreset(rawValue: Preferences.defaults.string(forKey: PrefKey.levelPreset) ?? "") ?? .balanced
        let options = Preferences.createOptions(format: fmt, preset: preset, password: nil)
        do {
            _ = try await Task.detached { try Xipper.create(from: sources, to: dest, options: options) }.value
        } catch {
            throw describe(error)
        }
        return .result(value: IntentFile(fileURL: dest))
    }
}

struct ExtractIntent: AppIntent {
    static let title: LocalizedStringResource = "Estrai con Xipper"
    static let description = IntentDescription("Estrae l'archivio accanto all'originale (o nella cartella indicata) e restituisce la cartella o il file estratto.")

    @Parameter(title: "Archivio", supportedContentTypes: [.archive, .data])
    var archive: IntentFile

    @Parameter(title: "Destinazione", supportedContentTypes: [.folder])
    var destination: IntentFile?

    @Parameter(title: "Password")
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Estrai \(\.$archive)") {
            \.$destination
            \.$password
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let url = try localURLs([archive]).first else { throw IntentFailure.noFiles }
        guard AppState.isArchive(url) else { throw IntentFailure.notAnArchive(url.lastPathComponent) }
        let folder = destination?.fileURL
        var options = Preferences.extractOptions(password: password)
        if password == nil, PasswordVault.has(url) { options.password = await PasswordVault.password(for: url) }
        let opts = options
        do {
            let report = try await Task.detached { try Xipper.extract(url, to: folder, mode: .smart, options: opts) }.value
            return .result(value: IntentFile(fileURL: report.destination))
        } catch {
            throw describe(error)
        }
    }
}

struct VerifyIntent: AppIntent {
    static let title: LocalizedStringResource = "Verifica con Xipper"
    static let description = IntentDescription("Controlla l'integrità dell'archivio senza estrarlo. Restituisce Sì se è integro.")

    @Parameter(title: "Archivio", supportedContentTypes: [.archive, .data])
    var archive: IntentFile

    @Parameter(title: "Password")
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Verifica \(\.$archive)") { \.$password }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        guard let url = try localURLs([archive]).first else { throw IntentFailure.noFiles }
        guard AppState.isArchive(url) else { throw IntentFailure.notAnArchive(url.lastPathComponent) }
        var pw = password
        if pw == nil, PasswordVault.has(url) { pw = await PasswordVault.password(for: url) }
        let p = pw
        do {
            let r = try await Task.detached { try Xipper.test(url, password: p) }.value
            let text = r.isOK ? "\(url.lastPathComponent) è integro (\(r.entries) elementi)."
                              : "\(url.lastPathComponent): \(r.failures.count) problemi trovati."
            return .result(value: r.isOK, dialog: "\(text)")
        } catch {
            throw describe(error)
        }
    }
}

struct XipperShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CompressIntent(), phrases: ["Comprimi con \(.applicationName)"],
                    shortTitle: "Comprimi", systemImageName: "arrow.down.right.and.arrow.up.left")
        AppShortcut(intent: ExtractIntent(), phrases: ["Estrai con \(.applicationName)"],
                    shortTitle: "Estrai", systemImageName: "arrow.down.to.line")
        AppShortcut(intent: VerifyIntent(), phrases: ["Verifica con \(.applicationName)"],
                    shortTitle: "Verifica", systemImageName: "checkmark.shield")
    }
}
