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

    /// Algorithms offered in the app, most useful first.
    static let checksumChoices: [ChecksumAlgorithm] = [.sha256, .blake3, .xxh128, .sha3_256, .sha512, .sha1, .md5, .crc32]

    /// "Calcola checksum…": files and folders, an algorithm, then the list (SHA256SUMS, B3SUMS…)
    /// saved in their common folder, readable by sha256sum -c, b3sum -c and Xipper.
    @MainActor
    static func computeChecksums() {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.allowsMultipleSelection = true
        open.message = String(localized: "Scegli i file e le cartelle di cui calcolare il checksum.")
        guard open.runModal() == .OK, !open.urls.isEmpty else { return }
        let sources = open.urls
        let ask = NSAlert()
        ask.messageText = String(localized: "Algoritmo del checksum")
        ask.informativeText = String(localized: "SHA-256 è il più diffuso; BLAKE3 è il più veloce tra quelli sicuri; XXH128 è velocissimo ma rileva solo i danni accidentali.")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
        popup.addItems(withTitles: checksumChoices.map(\.title))
        ask.accessoryView = popup
        ask.addButton(withTitle: String(localized: "Continua"))
        ask.addButton(withTitle: String(localized: "Annulla"))
        guard ask.runModal() == .alertFirstButtonReturn else { return }
        let algorithm = checksumChoices[popup.indexOfSelectedItem]
        var common = sources[0].deletingLastPathComponent()
        while !sources.allSatisfy({ $0.path.hasPrefix(common.path + "/") }) && common.path != "/" { common.deleteLastPathComponent() }
        let save = NSSavePanel()
        save.directoryURL = common
        save.nameFieldStringValue = algorithm.listName
        save.message = String(localized: "La lista va in una cartella che contiene tutti i file scelti.")
        guard save.runModal() == .OK, let list = save.url else { return }
        run(String(localized: "Impossibile calcolare i checksum"), done: { NSWorkspace.shared.activateFileViewerSelecting([list]) }) {
            try Xipper.createManifest(of: sources, to: list, algorithms: [algorithm], overwrite: true, workload: Preferences.workload)
        }
    }

    /// "Verifica checksum…": a list (sha256sum, b3sum, BSD tags or JSON), checked against the files next to it.
    @MainActor
    static func verifyChecksums() {
        let open = NSOpenPanel()
        open.message = String(localized: "Scegli la lista dei checksum (SHA256SUMS, B3SUMS, .sha256, .json…).")
        guard open.runModal() == .OK, let list = open.url else { return }
        Task {
            let result = await Task.detached { Result { try Xipper.verifyManifest(list, workload: Preferences.workload) } }.value
            let alert = NSAlert()
            switch result {
            case let .success(r):
                alert.alertStyle = r.isOK ? .informational : .warning
                alert.messageText = r.isOK ? String(localized: "Tutti i \(r.checked) file corrispondono") : String(localized: "Alcuni file non corrispondono")
                var lines: [String] = []
                if !r.mismatches.isEmpty { lines.append(String(localized: "Diversi: \(r.mismatches.prefix(8).map(\.path).joined(separator: ", "))\(r.mismatches.count > 8 ? "…" : "")")) }
                if !r.missing.isEmpty { lines.append(String(localized: "Mancanti: \(r.missing.prefix(8).joined(separator: ", "))\(r.missing.count > 8 ? "…" : "")")) }
                if !r.refused.isEmpty { lines.append(String(localized: "Ignorati (percorsi assoluti o con ..): \(r.refused.count)")) }
                lines.append(String(localized: "\(r.bytes.byteText) letti in \(r.elapsed.formatted(.number.precision(.fractionLength(1)))) s."))
                alert.informativeText = lines.joined(separator: "\n")
            case let .failure(error):
                alert.alertStyle = .warning
                alert.messageText = String(localized: "Impossibile verificare “\(list.lastPathComponent)”")
                alert.informativeText = (error as? XipperError).map(Job.localized) ?? error.localizedDescription
            }
            alert.runModal()
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

    /// Recovery data for the archive: PAR2 files next to it, or the record inside a XIZ (2.7).
    static func hasRecovery(_ archive: URL) -> Bool {
        PAR2.indexFile(for: archive) != nil || Xipper.xizRecoveryInfo(archive) != nil
    }

    /// XIZ: the record inside the archive; other formats: PAR2 files next to it.
    static func createRecovery(for archive: URL, done: @escaping () -> Void) {
        let percent = Preferences.recoveryPercent
        run(String(localized: "Impossibile creare i dati di recupero"), done: done) {
            if (try? ArchiveFormat.detect(archive)) == .xiz {
                try Xipper.addXizRecovery(archive, redundancy: percent)
                XizWatch.remember(archive)
            } else {
                try PAR2.create(for: [archive], redundancy: percent)
            }
        }
    }

    static func repair(_ archive: URL, done: @escaping () -> Void) {
        if Xipper.xizRecoveryInfo(archive) != nil {
            run(String(localized: "Impossibile riparare “\(archive.lastPathComponent)”"), done: done) {
                let r = try Xipper.scrubXiz(archive, repair: true)
                if !r.isClean && !r.repaired {
                    throw XipperError.corrupt("damaged in \(r.damagedRanges.count) places, the recovery data can rebuild \((r.info?.recoverySlices ?? 0) - r.damagedRecoverySlices)")
                }
            }
            return
        }
        guard let index = PAR2.indexFile(for: archive) else { return }
        run(String(localized: "Impossibile riparare “\(archive.lastPathComponent)”"), done: done) {
            try PAR2.repair(index)
        }
    }

    /// "Ricostruisci ZIP": a damaged ZIP without PAR2 rebuilt from its local headers into
    /// "name (riparato).zip" next to it; the original stays as it is.
    static func rebuildZip(_ archive: URL, password: String?) {
        Task {
            let result = await Task.detached { Result { try Xipper.repairZip(archive, password: password) } }.value
            let alert = NSAlert()
            switch result {
            case let .success(r):
                alert.messageText = String(localized: "Archivio ricostruito: “\(r.output.lastPathComponent)”")
                var lines = [String(localized: "Recuperati \(r.recovered) elementi.")]
                if !r.lost.isEmpty {
                    lines.append(String(localized: "Persi \(r.lost.count) file, troncati o danneggiati: \(r.lost.prefix(5).joined(separator: ", "))\(r.lost.count > 5 ? "…" : "")"))
                }
                if !r.unverified.isEmpty {
                    lines.append(String(localized: "\(r.unverified.count) file cifrati non verificati: servirebbe la password."))
                }
                lines.append(String(localized: "L'originale non è stato modificato."))
                alert.informativeText = lines.joined(separator: "\n")
                alert.alertStyle = r.lost.isEmpty ? .informational : .warning
                NSWorkspace.shared.activateFileViewerSelecting([r.output])
            case let .failure(error):
                alert.messageText = String(localized: "Impossibile ricostruire “\(archive.lastPathComponent)”")
                alert.informativeText = (error as? XipperError).map(Job.localized) ?? error.localizedDescription
            }
            alert.runModal()
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
