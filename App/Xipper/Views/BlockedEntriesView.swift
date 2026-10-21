import AppKit
import SwiftUI
import XipperKit

/// "Elementi bloccati" (6.3): opens after an extraction that refused unsafe entries.
/// There is deliberately no "extract anyway" here.
@MainActor
enum BlockedEntriesWindow {
    private static var open: [UUID: NSWindow] = [:]

    static func show(_ job: Job) {
        if let w = open[job.id] { w.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = String(localized: "Estrazione di \(job.title)")
        window.subtitle = String(localized: "Completata con avvisi · \(job.extractReport.map { $0.files + $0.directories + $0.symlinks + job.blocked.count } ?? job.blocked.count) voci")
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: BlockedEntriesView(job: job) { window.close() })
        window.setContentSize(NSSize(width: 760, height: 520))
        window.center()
        open[job.id] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { _ = open.removeValue(forKey: job.id) }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct BlockedEntriesView: View {
    let job: Job
    let close: () -> Void

    private var blocked: [SkippedEntry] { job.blocked }
    private var destination: URL? { job.extractReport?.destination ?? job.output }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Table(blocked) {
                TableColumn("Voce nell'archivio") { e in
                    Label {
                        Text(e.path).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                .width(min: 200, ideal: 280)
                TableColumn("Motivo") { e in Text(e.problem.message).help(e.reason) }
                    .width(min: 180, ideal: 240)
                TableColumn("Dove avrebbe scritto") { e in
                    Text(e.intendedTarget(in: destination)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                .width(min: 160, ideal: 220)
            }
            .safeAreaInset(edge: .top) { banner.padding(.horizontal, 16).padding(.top, 8) }
            VStack(alignment: .leading, spacing: 8) {
                if let r = job.extractReport {
                    Label {
                        Text("\(r.files) elementi estratti in **\(shortPath(r.destination))**.")
                    } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                Label("Gli eseguibili estratti restano in quarantena: Gatekeeper e XProtect li controlleranno alla prima apertura.",
                      systemImage: "checkmark.shield")
                Label("Questi elementi non si possono estrarre nemmeno su richiesta. Se ti servono, estrai l'archivio con un altro strumento a tuo rischio.",
                      systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(16)
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    private var banner: some View {
        HStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(blocked.count) elementi bloccati per sicurezza").font(.title3.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            Button("Copia rapporto") { copyReport() }.buttonStyle(.glass)
            if let destination {
                Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(16)
        .accessibleGlass(tint: .orange, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
    }

    private var subtitle: String {
        let outside = blocked.allSatisfy { [.escapesDestination, .throughSymlink].contains($0.problem) || { if case .symlinkOutside = $0.problem { true } else { false } }($0) }
        return outside ? String(localized: "Avrebbero scritto fuori dalla cartella di destinazione")
                       : String(localized: "Non sono sicuri da estrarre su questo Mac")
    }

    private func shortPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home + "/") ? String(url.path.dropFirst(home.count + 1)) : url.path
    }

    private func copyReport() {
        var text = String(localized: "Estrazione di \(job.title)") + "\n"
        text += String(localized: "\(blocked.count) elementi bloccati per sicurezza") + "\n\n"
        for e in blocked { text += "\(e.path)\t\(e.problem.message)\t\(e.intendedTarget(in: destination))\n" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
