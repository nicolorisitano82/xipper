import FinderSync
import SwiftUI
import UniformTypeIdentifiers

/// First launch (1.1–1.3): Finder extension, default app for archives, `xipper` in the Terminal.
/// Shown once; reachable again from the Help menu.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var finderEnabled = FIFinderSyncController.isExtensionEnabled
    @State private var isDefault = DefaultApp.isDefault
    @State private var cli = CommandLineTool.status

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Benvenuto in Xipper").font(.title.weight(.semibold))
                    Text("Tre passaggi facoltativi per averlo sempre a portata di mano.").foregroundStyle(.secondary)
                }
            }
            step(symbol: "folder.badge.gearshape", title: String(localized: "Xipper nel Finder"),
                 detail: String(localized: "Menu Xipper nel clic destro e pulsante nella barra degli strumenti."),
                 done: finderEnabled, action: finderEnabled ? nil : "Attiva…") {
                FIFinderSyncController.showExtensionManagementInterface()
            }
            step(symbol: "doc.zipper", title: String(localized: "Apri gli archivi con Xipper"),
                 detail: String(localized: "Doppio clic su ZIP, 7z, tar, gz, xz, zst e BGZF apre Xipper invece di Utility Archivio."),
                 done: isDefault, action: isDefault ? nil : String(localized: "Imposta")) {
                Task { await DefaultApp.makeDefault(); isDefault = DefaultApp.isDefault }
            }
            step(symbol: "terminal", title: String(localized: "Comando xipper nel Terminale"),
                 detail: cli.detail, done: cli.installed, action: cli.installed ? nil : cli.actionTitle) {
                cli = CommandLineTool.install()
            }
            HStack {
                Spacer()
                Button("Inizia") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            finderEnabled = FIFinderSyncController.isExtensionEnabled
            isDefault = DefaultApp.isDefault
        }
        .onDisappear { Preferences.defaults.set(true, forKey: PrefKey.onboardingDone) }
    }

    private func step(symbol: String, title: String, detail: String, done: Bool, action: String?,
                      perform: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if done {
                Label("Fatto", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).font(.title2).foregroundStyle(.green)
            } else if let action {
                Button(action, action: perform).buttonStyle(.glass)
            }
        }
    }
}

/// Default handler for the archive types Xipper declares.
enum DefaultApp {
    static let types: [UTType] = ["public.zip-archive", "org.7-zip.7-zip-archive", "public.tar-archive", "com.apple.archive", "public.cpio-archive",
                                  "app.xipper.lz4", "app.xipper.brotli", "org.gnu.gnu-zip-archive",
                                  "org.gnu.gnu-zip-tar-archive", "public.bzip2-archive", "org.tukaani.xz-archive",
                                  "org.tukaani.tar-xz-archive", "com.facebook.zstandard-archive",
                                  "app.xipper.tar-zstd", "app.xipper.bgzf"].compactMap { UTType($0) }

    static var isDefault: Bool {
        guard let zip = UTType("public.zip-archive"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: zip) else { return false }
        return app.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// The system asks the user to confirm the change.
    static func makeDefault() async {
        for type in types {
            try? await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type)
        }
    }
}

/// Link to the bundled CLI in a folder on the PATH. Homebrew's bin (owned by the user) works
/// without a password; otherwise the command for /usr/local/bin is copied to the clipboard.
enum CommandLineTool {
    struct Status {
        var installed: Bool
        var detail: String
        var actionTitle: String
    }

    static var helper: String { Bundle.main.bundlePath + "/Contents/Helpers/xipper" }
    private static let candidates = ["/opt/homebrew/bin", "/usr/local/bin"]

    static var status: Status {
        for dir in candidates {
            if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: dir + "/xipper"), dest == helper {
                return Status(installed: true, detail: String(localized: "Installato in \(dir)/xipper."), actionTitle: "")
            }
        }
        let writable = candidates.first { FileManager.default.isWritableFile(atPath: $0) }
        return Status(installed: false,
                      detail: writable.map { String(localized: "Crea il collegamento \($0)/xipper per comprimere ed estrarre dagli script.") }
                          ?? String(localized: "Copia il comando da incollare nel Terminale (chiede la password di amministratore)."),
                      actionTitle: writable == nil ? String(localized: "Copia comando") : String(localized: "Installa"))
    }

    static func install() -> Status {
        if let dir = candidates.first(where: { FileManager.default.isWritableFile(atPath: $0) }) {
            let link = dir + "/xipper"
            // Replace only an older link to a Xipper app, never someone else's file.
            if let old = try? FileManager.default.destinationOfSymbolicLink(atPath: link), old.hasSuffix("Xipper.app/Contents/Helpers/xipper") {
                try? FileManager.default.removeItem(atPath: link)
            }
            if (try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: helper)) != nil { return status }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("sudo mkdir -p /usr/local/bin && sudo ln -sf \"\(helper)\" /usr/local/bin/xipper", forType: .string)
        var s = status
        s.detail = String(localized: "Comando copiato: incollalo nel Terminale.")
        return s
    }
}
