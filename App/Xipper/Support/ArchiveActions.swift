import AppKit
import XipperKit

/// Changes made from the archive window: editing the content (ROADMAP v2 §5) and PAR2 recovery
/// data (§4). Each runs off the main thread; errors end in an alert, success calls `done`.
@MainActor
enum ArchiveActions {
    /// Formats Xipper can write back (single compressed files, lz4 and brotli cannot be edited).
    static func canEdit(_ format: ArchiveFormat?) -> Bool {
        guard let format else { return false }
        return format.canCreate && !format.isSingleFile
    }

    static func edit(_ archive: URL, _ changes: [ArchiveChange], password: String?, signer: XizSigner? = nil, done: @escaping () -> Void) {
        var options = CreateOptions()
        options.xizSigner = signer
        let o = options
        run(String(localized: "Impossibile modificare “\(archive.lastPathComponent)”"), done: done) {
            try Xipper.edit(archive, changes: changes, password: password, options: o)
        }
    }

    // MARK: XIZ 1.3

    /// The signer for a change to `archive`: the default signing key, when the archive is signed
    /// and Settings ask to sign changes (Touch ID). nil: unsigned change.
    @MainActor
    static func signerForChange(_ info: XizArchiveInfo?) async -> XizSigner? {
        guard let info, info.hasDirectory, info.signed, Preferences.defaults.object(forKey: PrefKey.xizSignEdits) as? Bool ?? true else { return nil }
        return await KeyVault.defaultSigner()
    }

    /// "Crea prova di appartenenza…": a JSON proof saved where the user chooses.
    static func saveProof(_ archive: URL, path: String, password: String?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (path as NSString).lastPathComponent + ".prova.json"
        panel.message = String(localized: "La prova dimostra che questo file fa parte dell'archivio firmato, senza consegnare il resto.")
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        run(String(localized: "Impossibile creare la prova"), done: {}) {
            try Xipper.xizProof(archive, path: path, password: password).write(to: dest, options: .atomic)
        }
    }

    /// "Cancella definitivamente…": confirm, then erase (signed when appropriate).
    @MainActor
    static func erase(_ archive: URL, paths: [String], password: String?, info: XizArchiveInfo?, done: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = paths.count == 1
            ? String(localized: "Cancellare definitivamente “\((paths[0] as NSString).lastPathComponent)”?")
            : String(localized: "Cancellare definitivamente \(paths.count) elementi?")
        alert.informativeText = String(localized: "La chiave dei file viene distrutta: il contenuto diventa illeggibile in questo archivio e in tutte le sue versioni, e nelle copie fatte da adesso in poi. Le copie dell'archivio fatte prima conservano i file. Non si può annullare.")
        alert.addButton(withTitle: String(localized: "Cancella definitivamente"))
        alert.addButton(withTitle: String(localized: "Annulla"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            var options = CreateOptions()
            options.xizSigner = await signerForChange(info)
            let o = options
            run(String(localized: "Impossibile cancellare"), done: done) {
                try Xipper.xizErase(archive, paths: paths, password: password, options: o)
            }
        }
    }

    /// "Verifica prova di appartenenza…": the proof, then the file it is about.
    @MainActor
    static func verifyProof() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        p.message = String(localized: "Scegli la prova di appartenenza (.json).")
        guard p.runModal() == .OK, let proofURL = p.url, let proof = try? Data(contentsOf: proofURL) else { return }
        let f = NSOpenPanel()
        f.message = String(localized: "Scegli il file a cui si riferisce la prova.")
        guard f.runModal() == .OK, let file = f.url else { return }
        let alert = NSAlert()
        do {
            let r = try Xipper.xizVerifyProof(proof, file: file)
            alert.alertStyle = r.valid ? .informational : .warning
            alert.messageText = r.valid ? String(localized: "Prova valida") : String(localized: "Prova non valida")
            var lines: [String] = [String(localized: "File nell'archivio: \(r.path)")]
            lines.append(r.contentMatches ? String(localized: "Il contenuto coincide.") : String(localized: "Il contenuto è DIVERSO da quello dell'archivio."))
            lines.append(r.inTree ? String(localized: "Fa parte dell'archivio.") : String(localized: "NON risulta nell'archivio."))
            if r.signed {
                lines.append(String(localized: "Firmato da \(r.signerLabel) il \(r.signedAt?.formatted(date: .long, time: .shortened) ?? "?")."))
                lines.append(r.signerKey)
            } else {
                lines.append(String(localized: "L'archivio non è firmato: nessuno garantisce per questa prova."))
            }
            if let ts = r.timestamp {
                lines.append(ts.valid ? String(localized: "Marca temporale: \(ts.time.formatted(date: .long, time: .shortened)), \(ts.authority)\(ts.trusted ? "" : String(localized: " (autorità non riconosciuta da questo Mac)"))")
                                      : String(localized: "Marca temporale NON valida."))
            }
            alert.informativeText = lines.joined(separator: "\n")
        } catch {
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Impossibile verificare la prova")
            alert.informativeText = (error as? XipperError).map(Job.localized) ?? error.localizedDescription
        }
        alert.runModal()
    }

    static func createRecovery(for archive: URL, done: @escaping () -> Void) {
        let percent = Preferences.recoveryPercent
        run(String(localized: "Impossibile creare i dati di recupero"), done: done) {
            try PAR2.create(for: [archive], redundancy: percent)
        }
    }

    static func repair(_ archive: URL, done: @escaping () -> Void) {
        guard let index = PAR2.indexFile(for: archive) else { return }
        run(String(localized: "Impossibile riparare “\(archive.lastPathComponent)”"), done: done) {
            try PAR2.repair(index)
        }
    }

    // MARK: genomics

    /// BAM → CRAM 3.1 or CRAM → BAM next to the file, with the reference FASTA the user picks
    /// (the last one is offered again).
    static func convertAlignment(_ url: URL, toCRAM: Bool, done: @escaping () -> Void) {
        let isCRAM = !toCRAM
        guard let reference = chooseReference(required: toCRAM, for: url) else { return done() }
        let save = NSSavePanel()
        save.nameFieldStringValue = url.deletingPathExtension().appendingPathExtension(toCRAM ? "cram" : "bam").lastPathComponent
        save.directoryURL = url.deletingLastPathComponent()
        save.allowedContentTypes = []
        guard save.runModal() == .OK, let out = save.url else { return done() }
        let ref = reference
        run(String(localized: "Impossibile convertire “\(url.lastPathComponent)”"), done: {
            if Preferences.defaults.bool(forKey: PrefKey.revealAfter) { NSWorkspace.shared.activateFileViewerSelecting([out]) }
            done()
        }) {
            if isCRAM {
                try Xipper.cramToBAM(url, output: out, reference: ref, overwrite: true, workload: Preferences.workload)
            } else {
                try Xipper.bamToCRAM(url, output: out, reference: ref, overwrite: true, workload: Preferences.workload)
            }
        }
    }

    /// The usual index next to the file (.bai, .crai, .csi, .fai, .tbi).
    static func buildIndex(_ url: URL, done: @escaping () -> Void) {
        run(String(localized: "Impossibile creare l'indice di “\(url.lastPathComponent)”"), done: done) {
            try Xipper.buildIndex(url, overwrite: true, workload: Preferences.workload)
        }
    }

    /// The reference FASTA, nil when cancelled.
    private static func chooseReference(required: Bool, for url: URL) -> URL? {
        let key = "genomicsReference"
        let panel = NSOpenPanel()
        panel.message = required ? String(localized: "Scegli il riferimento FASTA su cui sono state allineate le letture")
                                 : String(localized: "Scegli il riferimento FASTA usato per scrivere il CRAM")
        panel.prompt = String(localized: "Usa riferimento")
        panel.canChooseDirectories = false
        if let last = Preferences.defaults.string(forKey: key) {
            panel.directoryURL = URL(fileURLWithPath: last).deletingLastPathComponent()
        } else {
            panel.directoryURL = url.deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let ref = panel.url else { return nil }
        Preferences.defaults.set(ref.path, forKey: key)
        return ref
    }

    /// Asks a new name for an entry (only the last path component changes).
    static func askNewName(for path: String) -> String? {
        let old = (path as NSString).lastPathComponent
        let alert = NSAlert()
        alert.messageText = String(localized: "Rinomina “\(old)”")
        alert.addButton(withTitle: String(localized: "Rinomina"))
        alert.addButton(withTitle: String(localized: "Annulla"))
        let field = NSTextField(string: old)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != old, !name.contains("/"), name != ".", name != ".." else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? name : parent + "/" + name
    }

    static func confirmDelete(_ count: Int, archive: URL) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count == 1 ? String(localized: "Eliminare l'elemento da “\(archive.lastPathComponent)”?")
                                       : String(localized: "Eliminare \(count) elementi da “\(archive.lastPathComponent)”?")
        alert.informativeText = String(localized: "L'archivio viene modificato. L'operazione non si può annullare.")
        alert.addButton(withTitle: String(localized: "Elimina")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Annulla"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func run(_ failure: String, done: @escaping () -> Void, _ work: @escaping @Sendable () throws -> Void) {
        Task {
            let error = await Task.detached { () -> Error? in
                do { try work(); return nil } catch { return error }
            }.value
            if let error {
                let alert = NSAlert()
                alert.messageText = failure
                alert.informativeText = (error as? XipperError).map(Job.localized) ?? error.localizedDescription
                alert.runModal()
            }
            done()
        }
    }
}
