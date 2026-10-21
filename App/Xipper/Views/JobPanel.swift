import SwiftUI
import XipperKit

/// In-window job panel: progress (2.4), then completion (2.5) or failure, in the same glass
/// surface (the Home action bar morphs into it).
struct JobPanel: View {
    @Bindable var job: Job
    let onClose: () -> Void
    let onHide: () -> Void
    @Environment(JobCenter.self) private var center
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            switch job.state {
            case .running: running
            case .finished: finished
            default: problem
            }
        }
        .padding(30)
        .frame(maxWidth: 560)
        .glassEffect(glass, in: .rect(cornerRadius: 30))
        .animation(.easeInOut(duration: 0.25), value: job.isRunning)
    }

    private var glass: Glass {
        if reduceTransparency { return .identity }
        if case .failed = job.state { return .regular.tint(.red.opacity(0.3)) }
        return .regular
    }

    // MARK: 2.4

    private var running: some View {
        VStack(alignment: .leading, spacing: 18) {
            header(symbol: "arrow.down.right.and.arrow.up.left", color: .accentColor,
                   title: "Compressione in corso", subtitle: job.title)
            HStack(alignment: .firstTextBaseline) {
                Text(job.smoothedSpeed > 0 ? "\(Int(job.smoothedSpeed / 1e6))" : "…")
                    .font(.system(size: 44, weight: .bold)).monospacedDigit()
                    .foregroundStyle(job.smoothedSpeed > 0 ? .primary : .secondary)
                    .contentTransition(.numericText())
                Text("MB/s").font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((job.progress?.fraction ?? 0) * 100))%")
                    .font(.title2.weight(.semibold)).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: job.progress?.fraction ?? 0)
                    .progressViewStyle(.linear)
                    .scaleEffect(x: 1, y: 1.6, anchor: .center)
                HStack {
                    Text("\((job.progress?.completedBytes ?? 0).byteText) di \((job.progress?.totalBytes ?? 0).byteText)")
                    Spacer()
                    if let eta = job.eta { Text(etaText(eta)) }
                }
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            if let current = job.progress?.currentEntry {
                VStack(alignment: .leading, spacing: 2) {
                    Text("File corrente").font(.caption).foregroundStyle(.secondary)
                    Text(current).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                }
            }
            HStack {
                Spacer()
                Button("Nascondi") { onHide() }.buttonStyle(.glass)
                Button("Annulla") { job.cancelJob() }.buttonStyle(.glass)
            }
        }
    }

    // MARK: 2.5

    private var finished: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
                    .symbolEffect(.bounce, value: job.isRunning)
                Text("Archivio creato").font(.title2.weight(.semibold))
                if let out = job.output {
                    Text("\(out.lastPathComponent), in \(out.deletingLastPathComponent().lastPathComponent)").foregroundStyle(.secondary)
                }
            }
            if let r = job.writeReport {
                HStack(spacing: 10) {
                    tile("Dimensione", r.outputBytes.byteText, saving(r))
                    tile("Tempo", seconds(r.elapsed), "\(r.entries.formatted()) elementi")
                    tile("Velocità media", r.elapsed > 0 ? "\(Int(Double(r.inputBytes) / r.elapsed / 1e6)) MB/s" : "—",
                         "\(CPUTopology.performanceCores) P-core")
                }
            }
            if encrypted {
                Label("Cifrato con AES-256", systemImage: "lock").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Verifica", systemImage: "checkmark.shield") {
                    if let out = job.output { center.start(.test(archive: out, password: nil)) }
                }
                .buttonStyle(.glass)
                Button("Mostra contenuto") {
                    if let out = job.output { openWindow(id: "archive", value: out) }
                }
                .buttonStyle(.glass)
                Spacer()
                Button("Mostra nel Finder") {
                    if let out = job.output { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                }
                .buttonStyle(.glassProminent)
            }
            Button("Crea un altro archivio") { onClose() }
                .buttonStyle(.link)
                .frame(maxWidth: .infinity)
        }
    }

    private var problem: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch job.state {
            case let .failed(message):
                header(symbol: "xmark.circle.fill", color: .red, title: failureTitle(message),
                       subtitle: "La compressione si è fermata al \(Int((job.progress?.fraction ?? 0) * 100))%.")
                if job.progress?.fraction ?? 0 > 0 {
                    ProgressView(value: job.progress?.fraction ?? 0).tint(.red)
                }
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    if case .diskFull = job.failure {
                        if let free = job.freeSpace {
                            GridRow { Text("Spazio libero in \(job.destinationFolder?.lastPathComponent ?? "destinazione")").foregroundStyle(.secondary); Text(free.byteText) }
                        }
                        if let p = job.progress, p.totalBytes > p.completedBytes {
                            GridRow { Text("Spazio ancora necessario").foregroundStyle(.secondary); Text("fino a \((p.totalBytes - p.completedBytes).byteText)") }
                        }
                    } else if job.failure != nil && job.failure != .other || !message.isEmpty {
                        GridRow { Text("Motivo").foregroundStyle(.secondary); Text(message).lineLimit(2) }
                    }
                    GridRow { Text("File parziale").foregroundStyle(.secondary); Text("eliminato") }
                    GridRow { Text("Originali").foregroundStyle(.secondary); Text("intatti, nessun file è stato modificato") }
                }
                .font(.callout)
                HStack {
                    Button("Chiudi") { onClose() }.buttonStyle(.glass)
                    Spacer()
                    Button("Riprova") { center.retry(job) ; onClose() }.buttonStyle(.glass)
                    Button("Salva altrove…") { saveElsewhere() }.buttonStyle(.glassProminent)
                }
            default:
                header(symbol: "xmark.circle", color: .secondary, title: "Compressione annullata",
                       subtitle: "Nessun file è stato creato.")
                HStack {
                    Spacer()
                    Button("Chiudi") { onClose() }.buttonStyle(.glassProminent)
                }
            }
        }
    }

    private func failureTitle(_ message: String) -> String {
        switch job.failure {
        case .diskFull?: "Spazio su disco esaurito"
        case .permission?: "Permessi insufficienti"
        case .readOnly?: "Volume in sola lettura"
        case .volumeGone?: "Volume non disponibile"
        default: "Compressione non riuscita"
        }
    }

    /// Picks another folder and restarts the same creation there (2.8).
    private func saveElsewhere() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Salva qui"
        panel.message = "Scegli dove salvare l'archivio"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        center.relocate(job, to: folder)
        onClose()
    }

    // MARK: helpers

    private var encrypted: Bool {
        if case let .create(_, _, _, _, password) = job.kind { return password != nil }
        return false
    }

    private func header(symbol: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
        }
    }

    /// Opaque tile inside the glass panel (no glass on glass).
    private func tile(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }

    private func saving(_ r: WriteReport) -> String {
        guard r.inputBytes > 0 else { return "" }
        let pct = Int(((1 - Double(r.outputBytes) / Double(r.inputBytes)) * 100).rounded())
        if pct == 0 { return "da \(r.inputBytes.byteText) · già compressi" }
        return "da \(r.inputBytes.byteText) · \(pct > 0 ? "−" : "+")\(abs(pct))%"
    }

    private func seconds(_ s: Double) -> String {
        s < 60 ? String(format: "%.1f s", s) : Duration.seconds(s).formatted(.units(allowed: [.minutes, .seconds]))
    }

    private func etaText(_ s: Double) -> String {
        s < 1 ? "meno di un secondo" : s < 60 ? "circa \(Int(s.rounded())) secondi" : "circa \(Int((s / 60).rounded())) minuti"
    }
}
