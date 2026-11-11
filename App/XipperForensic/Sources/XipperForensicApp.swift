import AppKit
import ForensicKit
import SwiftUI
import XipperKit

/// Xipper Forensic (docs/XIPPER_FORENSIC.md §4): cases, evidence, guided acquisition, verification,
/// custody, printable reports. A separate product of the Xipper family: Xipper itself shows none of this.
@main
struct XipperForensicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var prefs = Prefs.shared

    var body: some Scene {
        WindowGroup("Xipper Forensic", id: "welcome") {
            WelcomeView()
                .environment(prefs)
                .opensRoutedFiles()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                OpenCommands()
            }
        }

        WindowGroup(id: "case", for: URL.self) { $url in
            if let url {
                CaseWindow(url: url)
                    .environment(prefs)
                    .opensRoutedFiles()
            }
        }
        .defaultSize(width: 1100, height: 720)

        WindowGroup(id: "verify", for: URL.self) { $url in
            VerifyView(archive: url)
                .environment(prefs)
                .opensRoutedFiles()
        }
        .defaultSize(width: 760, height: 640)

        Settings {
            SettingsView()
                .environment(prefs)
        }
    }
}

/// Files opened from the Finder (a case folder, an archive) reach the windows through this.
@MainActor @Observable
final class Router {
    static let shared = Router()
    var pending: [URL] = []
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { Router.shared.pending += urls }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        #if DEBUG
        MainActor.assumeIsolated { Snapshot.runIfAsked() }
        #endif
    }
}

struct RoutedFiles: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var active
    let router = Router.shared

    func body(content: Content) -> some View {
        content
            .onChange(of: router.pending, initial: true) { _, urls in
                guard !urls.isEmpty else { return }
                router.pending = []
                for u in urls { open(u, openWindow) }
            }
    }
}

@MainActor func open(_ url: URL, _ openWindow: OpenWindowAction) {
    if url.pathExtension == ForensicCase.fileExtension {
        Recents.add(url)
        openWindow(id: "case", value: url)
    } else {
        openWindow(id: "verify", value: url)
    }
}

extension View {
    func opensRoutedFiles() -> some View { modifier(RoutedFiles()) }
}

struct OpenCommands: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Case…") { openWindow(id: "welcome") }
            .keyboardShortcut("n")
        Button("Open Case…") {
            if let u = Panels.openCase() { open(u, openWindow) }
        }
        .keyboardShortcut("o")
        Button("Verify an Archive…") {
            openWindow(id: "verify", value: URL?.none)
        }
        .keyboardShortcut("v", modifiers: [.command, .shift])
    }
}

/// Recently opened cases, newest first.
enum Recents {
    static let key = "recentCases"
    @MainActor static var all: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    @MainActor static func add(_ u: URL) {
        var a = UserDefaults.standard.stringArray(forKey: key) ?? []
        a.removeAll { $0 == u.path }
        a.insert(u.path, at: 0)
        UserDefaults.standard.set(Array(a.prefix(10)), forKey: key)
    }
}

enum Panels {
    @MainActor static func openCase() -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.treatsFilePackagesAsDirectories = false
        // No content types: a .xfcase is a folder, and until Launch Services knows the app's package type
        // it is greyed out. The delegate enables case folders and lets every other folder be browsed.
        let filter = CaseFilter()
        p.delegate = filter
        p.message = String(localized: "Choose a case folder (.xfcase)")
        guard p.runModal() == .OK, let u = p.url else { return nil }
        withExtendedLifetime(filter) {}
        return u.pathExtension == ForensicCase.fileExtension ? u : nil
    }

    /// Case folders can be chosen; other folders are only for browsing.
    final class CaseFilter: NSObject, NSOpenSavePanelDelegate {
        func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
            url.pathExtension == ForensicCase.fileExtension || url.hasDirectoryPath
        }
        func panel(_ sender: Any, validate url: URL) throws {
            guard url.pathExtension == ForensicCase.fileExtension else {
                throw NSError(domain: "XipperForensic", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Choose a case folder (.xfcase)")])
            }
        }
    }

    @MainActor static func openArchive() -> URL? {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.init(filenameExtension: "xiz") ?? .data]
        p.message = String(localized: "Choose a forensic archive (.xiz)")
        guard p.runModal() == .OK, let u = p.url else { return nil }
        return u
    }

    @MainActor static func save(name: String, type: String) -> URL? {
        let p = NSSavePanel()
        p.nameFieldStringValue = name
        p.allowedContentTypes = [.init(filenameExtension: type) ?? .data]
        guard p.runModal() == .OK, let u = p.url else { return nil }
        return u
    }
}
