import AppKit
import Observation
import UniformTypeIdentifiers
import XipperKit

/// Files the system asked us to open (Finder double click, Dock drop, Open Recent),
/// consumed by whichever window can open them.
@MainActor
@Observable
final class AppState {
    static let shared = AppState()
    var pendingOpen: [URL] = []

    func open(_ urls: [URL]) {
        pendingOpen.append(contentsOf: urls)
        for url in urls { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
    }

    /// Lets the user pick archives to open.
    func showOpenPanel() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Scegli un archivio da aprire"
        panel.prompt = "Apri"
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func isArchive(_ url: URL) -> Bool {
        (try? ArchiveFormat.detect(url)) != nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { AppState.shared.open(urls) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = MainActor.assumeIsolated { JobCenter.shared.jobs.contains(where: \.isRunning) }
        guard running else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Ci sono lavori in corso"
        alert.informativeText = "Se esci ora verranno annullati. Gli archivi incompleti non vengono lasciati sul disco."
        alert.addButton(withTitle: "Continua")
        alert.addButton(withTitle: "Esci e annulla")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
