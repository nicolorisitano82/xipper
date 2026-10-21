import AppKit
import SwiftUI
import XipperKit

/// "Questo archivio si espande in modo anomalo" (6.1) and the second confirmation (6.2).
/// Shown when an extraction stops on the compression-ratio guard, before anything is written.
@MainActor
enum ZipBombPrompt {
    struct Facts {
        var archiveSize: Int64
        var declared: Int64
        var freeSpace: Int64?
        var totalSpace: Int64?
        var ratio: Double { archiveSize > 0 ? Double(declared) / Double(archiveSize) : 0 }
        /// What the always-on "keep 10% free" rule leaves for an override (nil when unknown).
        var room: Int64? {
            guard let freeSpace, let totalSpace else { return nil }
            return max(0, freeSpace - totalSpace / 10)
        }
    }

    static func facts(for r: ExtractRequest) -> Facts {
        let size = ((try? FileManager.default.attributesOfItem(atPath: r.archive.path)[.size]) as? NSNumber)?.int64Value ?? 0
        let declared = ((try? Xipper.list(r.archive)) ?? []).reduce(Int64(0)) { $0 + max(0, $1.uncompressedSize) }
        let folder = r.destination ?? r.archive.deletingLastPathComponent()
        let v = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return Facts(archiveSize: size, declared: declared, freeSpace: v?.volumeAvailableCapacityForImportantUsage,
                     totalSpace: v?.volumeTotalCapacity.map(Int64.init))
    }

    static func ask(for job: Job, request r: ExtractRequest) {
        let facts = facts(for: r)
        let name = r.archive.lastPathComponent
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "Questo archivio si espande in modo anomalo")
        alert.informativeText = String(localized: "“\(name)” pesa \(facts.archiveSize.byteText) ma dichiara \(facts.declared.byteText) di dati estratti. Potrebbe essere una zip-bomb, pensata per riempire il disco.")
        alert.addButton(withTitle: String(localized: "Non estrarre"))
        alert.addButton(withTitle: String(localized: "Sposta nel Cestino"))
        let anyway = alert.addButton(withTitle: String(localized: "Estrai comunque…"))
        anyway.hasDestructiveAction = true
        let details = NSHostingView(rootView: FactsGrid(facts: facts))
        details.frame.size = details.fittingSize
        alert.accessoryView = details
        NSApp.requestUserAttention(.criticalRequest)
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            try? FileManager.default.trashItem(at: r.archive, resultingItemURL: nil)
            job.state = .failed(String(localized: "Non estratto: archivio spostato nel Cestino"))
        case .alertThirdButtonReturn:
            confirm(job, request: r, facts: facts)
        default:
            job.state = .failed(String(localized: "Non estratto: possibile zip-bomb"))
        }
    }

    /// 6.2: extract up to a chosen limit, in a new folder in Downloads.
    private static func confirm(_ job: Job, request r: ExtractRequest, facts: Facts) {
        var choice: (cap: Int64, downloads: Bool)?
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: 300), styleMask: [.titled, .docModalWindow], backing: .buffered, defer: false)
        let view = SecondConfirmation(name: r.archive.lastPathComponent, facts: facts) { result in
            choice = result
            NSApp.stopModal()
        }
        window.contentViewController = NSHostingController(rootView: view)
        window.center()
        NSApp.runModal(for: window)
        window.orderOut(nil)
        guard let choice else {
            job.state = .failed(String(localized: "Non estratto: possibile zip-bomb"))
            return
        }
        var request = r
        request.capBytes = choice.cap
        if choice.downloads {
            request.destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            request.mode = .smart
        }
        JobCenter.shared.remove(job)
        JobCenter.shared.start(.extract(request))
    }
}

private struct FactsGrid: View {
    let facts: ZipBombPrompt.Facts

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("Rapporto").foregroundStyle(.secondary)
                Text("1 : \(facts.ratio < 1_000_000 ? Int(facts.ratio.rounded()).formatted() : Int(facts.ratio.rounded()).formatted(.number.notation(.compactName)))").monospacedDigit()
            }
            GridRow {
                Text("Dati dichiarati").foregroundStyle(.secondary)
                Text(facts.declared.byteText).monospacedDigit()
            }
            if let free = facts.freeSpace {
                GridRow {
                    Text("Spazio libero").foregroundStyle(.secondary)
                    Text(free.byteText).monospacedDigit()
                }
            }
        }
        .font(.callout)
        .padding(.vertical, 4)
    }
}

private struct SecondConfirmation: View {
    let name: String
    let facts: ZipBombPrompt.Facts
    let onDone: ((cap: Int64, downloads: Bool)?) -> Void
    /// Decimal sizes, so the labels read exactly "1 GB", "10 GB", "50 GB" (as the Finder counts).
    static let caps: [Int64] = [1_000_000_000, 10_000_000_000, 50_000_000_000]
    @State private var cap: Int64 = caps[0]
    @State private var downloads = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Estrarre comunque “\(name)”?").font(.headline)
                    Text(facts.freeSpace.map { String(localized: "Dichiara \(facts.declared.byteText) su un disco con \($0.byteText) liberi.") }
                         ?? String(localized: "Dichiara \(facts.declared.byteText)."))
                        .foregroundStyle(.secondary)
                }
            }
            Text("Xipper estrae finché i dati non superano il limite che scegli, poi si ferma ed elimina quanto scritto.")
                .fixedSize(horizontal: false, vertical: true)
            // Plain stack, not a grouped Form: inside the modal panel a Form collapses to zero height.
            VStack(alignment: .leading, spacing: 10) {
                Picker("Ferma l'estrazione oltre", selection: $cap) {
                    ForEach(Self.caps, id: \.self) { Text($0.byteText).tag($0) }
                }
                .fixedSize()
                Toggle("Estrai in una cartella nuova in Download", isOn: $downloads)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Fermati se resta meno del 10% di spazio libero", isOn: .constant(true)).disabled(true)
                    Text("Sempre attivo, non si può disattivare.").font(.caption).foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
            if let room = facts.room, room < 64 << 20 {
                Label("Sul disco resta meno del 10% di spazio libero: libera spazio prima di estrarre.", systemImage: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Estrai fino a \(cap.byteText)", role: .destructive) { onDone((cap, downloads)) }
                    .foregroundStyle(.red)
                    .disabled((facts.room ?? .max) < 64 << 20)
                Spacer()
                Button("Annulla") { onDone(nil) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 470)
    }
}
