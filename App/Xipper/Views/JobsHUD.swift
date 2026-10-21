import SwiftUI
import XipperKit

/// Floating stack of glass capsules, one per job (Liquid Glass control layer).
struct JobsHUD: View {
    @Environment(JobCenter.self) private var center
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(center.jobs.filter { !center.focused.contains($0.id) }) { job in
                    JobCapsule(job: job)
                        .glassEffect(glass(for: job), in: .rect(cornerRadius: 24))
                        .glassEffectID(job.id, in: glass)
                        .transition(.blurReplace)
                }
            }
        }
        .frame(maxWidth: 380)
        .animation(.snappy, value: center.jobs.map(\.id))
    }

    private func glass(for job: Job) -> Glass {
        if reduceTransparency { return .identity }
        switch job.state {
        case .failed: return .regular.tint(.red.opacity(0.35))
        case .needsPassword, .needsOverride: return .regular.tint(.orange.opacity(0.3))
        default: return .regular
        }
    }
}

private struct JobCapsule: View {
    @Bindable var job: Job
    @Environment(JobCenter.self) private var center
    @State private var askPassword = false
    @State private var showReport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .symbolEffect(.pulse, isActive: job.isRunning)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.title).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                actions
            }
            if job.isRunning {
                ProgressView(value: job.progress?.fraction ?? 0)
                    .progressViewStyle(.linear)
            }
        }
        .padding(12)
        .frame(width: 364)
        .sheet(isPresented: $askPassword) {
            if case let .needsPassword(wrong) = job.state {
                PasswordSheet(mode: .open(wrong: wrong), archiveName: job.title) { pw in
                    if let pw { center.retry(job, password: pw) }
                }
            }
        }
        .sheet(isPresented: $showReport) { ReportSheet(job: job) }
    }

    private var icon: String {
        switch job.state {
        case .running: job.symbol
        case .finished: job.verifyOK == true ? "checkmark.shield.fill" : "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled: "xmark.circle"
        case .needsPassword: "lock.fill"
        case .needsOverride: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch job.state {
        case .finished: .green
        case .failed: .red
        case .needsPassword, .needsOverride: .orange
        default: .accentColor
        }
    }

    private var subtitle: String {
        switch job.state {
        case .running:
            if job.paused { return "In pausa: un file esiste già" }
            guard let p = job.progress else { return "\(job.verb) in corso…" }
            let pct = p.totalBytes > 0 ? "\(Int(p.fraction * 100))% · " : ""
            return "\(pct)\(Int(job.smoothedSpeed / 1e6)) MB/s" + (p.currentEntry.map { " · \(($0 as NSString).lastPathComponent)" } ?? "")
        case let .finished(s): return s
        case let .failed(s): return s
        case .cancelled: return "Annullato"
        case let .needsPassword(wrong): return wrong ? "Password errata" : "Archivio protetto da password"
        case .needsOverride: return "Possibile zip bomb: estrazione fermata prima di scrivere"
        }
    }

    @ViewBuilder private var actions: some View {
        switch job.state {
        case .running:
            Button("Annulla", systemImage: "xmark") { job.cancelJob() }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
        case .finished, .failed:
            if !job.report.isEmpty || job.verifyOK != nil {
                Button("Dettagli", systemImage: "list.bullet.rectangle") { showReport = true }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            if let out = job.output {
                Button("Mostra nel Finder", systemImage: "arrow.up.forward") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                    .help("Mostra nel Finder")
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            dismiss
        case .cancelled:
            dismiss
        case .needsPassword:
            Button("Password…") { askPassword = true }.buttonStyle(.glass)
            dismiss
        case let .needsOverride(message):
            Button("Estrai comunque") { confirmOverride(message) }.buttonStyle(.glass)
            dismiss
        }
    }

    private var dismiss: some View {
        Button("Chiudi", systemImage: "xmark") { center.remove(job) }
            .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
    }

    /// Second, explicit confirmation before lifting the zip-bomb guard.
    private func confirmOverride(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Estrarre comunque \(job.title)?"
        alert.informativeText = "Xipper ha fermato l'estrazione: \(message).\nUn archivio così può riempire il disco. Continua solo se ti fidi della provenienza."
        alert.addButton(withTitle: "Annulla")
        alert.addButton(withTitle: "Estrai comunque")
        if alert.runModal() == .alertSecondButtonReturn { center.retry(job, ratioOverride: 1_000_000) }
    }
}
