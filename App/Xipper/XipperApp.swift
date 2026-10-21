import SwiftUI
import XipperKit

@main
struct XipperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var jobs = JobCenter.shared
    @State private var appState = AppState.shared

    init() { Preferences.register() }

    var body: some Scene {
        Window("Xipper", id: "home") {
            HomeView()
                .environment(jobs)
                .environment(appState)
        }
        .defaultSize(width: 760, height: 580)
        .commands { XipperCommands() }

        WindowGroup("Archivio", id: "archive", for: URL.self) { $url in
            if let url {
                ArchiveBrowserView(url: url)
                    .environment(jobs)
                    .environment(appState)
            }
        }
        .defaultSize(width: 980, height: 620)

        Settings {
            SettingsView()
        }
    }
}

struct XipperCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Apri archivio…") {
                for url in AppState.shared.showOpenPanel() { openWindow(id: "archive", value: url) }
            }
            .keyboardShortcut("o")
            Button("Nuovo archivio") { openWindow(id: "home") }
                .keyboardShortcut("n")
        }
    }
}
