import AppKit
import Observation
import UniformTypeIdentifiers
import UserNotifications
import XipperKit

/// Files the system asked us to open (Finder double click, Dock drop, Open Recent),
/// consumed by whichever window can open them.
@MainActor
@Observable
final class AppState {
    static let shared = AppState()
    var pendingOpen: [URL] = []
    /// Verification results to show in an archive window (5.2): archive → job id.
    var reportRequests: [URL: UUID] = [:]
    /// First launch, or "Introduzione a Xipper" in the Help menu.
    var showOnboarding = !Preferences.defaults.bool(forKey: PrefKey.onboardingDone)
        && !ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("XIPPER_DEMO") }

    func open(_ urls: [URL]) {
        pendingOpen.append(contentsOf: urls)
        for url in urls { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
    }

    /// Lets the user pick archives to open.
    func showOpenPanel() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = String(localized: "Scegli un archivio da aprire")
        panel.prompt = String(localized: "Apri")
        return panel.runModal() == .OK ? panel.urls : []
    }

    nonisolated static func isArchive(_ url: URL) -> Bool {
        (try? ArchiveFormat.detect(url)) != nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = ServiceProvider()
    private let notifications = NotificationRouter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        EntryStaging.cleanUp()
        UNUserNotificationCenter.current().delegate = notifications
        MainActor.assumeIsolated { JobFeedback.prepare() }
        NSApp.servicesProvider = services
        #if !DEBUG
        MainActor.assumeIsolated { UpdateController.shared.checkQuietlyIfDue() }
        #endif
        NSUpdateDynamicServices()
    }

    /// Files from the Finder/Dock, and `xipper://` actions from the Finder extension.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls where url.scheme == "xipper" {
                if let action = ExternalAction(url: url) { ExternalActionRunner.run(action) }
            }
            let files = urls.filter(\.isFileURL)
            if !files.isEmpty { AppState.shared.open(files) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        EntryStaging.cleanUp()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Mounted archives first: their server lives in this process.
        let mounted = MainActor.assumeIsolated { !MountCenter.shared.mounts.isEmpty }
        if mounted {
            let alert = NSAlert()
            alert.messageText = String(localized: "Ci sono archivi montati")
            alert.informativeText = String(localized: "Xipper li espelle prima di uscire e salva le modifiche negli archivi.")
            alert.addButton(withTitle: String(localized: "Espelli ed esci"))
            alert.addButton(withTitle: String(localized: "Annulla"))
            guard alert.runModal() == .alertFirstButtonReturn,
                  MainActor.assumeIsolated({ MountCenter.shared.ejectAllForQuit() }) else { return .terminateCancel }
        }
        let running = MainActor.assumeIsolated { JobCenter.shared.jobs.contains(where: \.isRunning) }
        guard running else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "Ci sono lavori in corso")
        alert.informativeText = String(localized: "Se esci ora verranno annullati. Gli archivi incompleti non vengono lasciati sul disco.")
        alert.addButton(withTitle: String(localized: "Continua"))
        alert.addButton(withTitle: String(localized: "Esci e annulla"))
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
