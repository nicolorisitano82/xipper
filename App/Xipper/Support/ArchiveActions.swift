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

    static func edit(_ archive: URL, _ changes: [ArchiveChange], password: String?, done: @escaping () -> Void) {
        run(String(localized: "Impossibile modificare “\(archive.lastPathComponent)”"), done: done) {
            try Xipper.edit(archive, changes: changes, password: password)
        }
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
