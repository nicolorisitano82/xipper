import SwiftUI
import XipperKit

/// Floating stack of glass capsules, one per job (Liquid Glass control layer).
struct JobsHUD: View {
    @Environment(JobCenter.self) private var center
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(center.jobs.filter { !center.focused.contains($0.id) }) { job in
                    JobCapsule(job: job)
                        .accessibleGlass(tint: tint(for: job), in: RoundedRectangle(cornerRadius: 24))
                        .glassEffectID(job.id, in: glass)
                        .transition(AnyTransition.morph(reduceMotion: reduceMotion, AnyTransition(.blurReplace)))
                }
            }
        }
        .frame(maxWidth: 380)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy, value: center.jobs.map(\.id))
    }

    private func tint(for job: Job) -> Color? {
        switch job.state {
        case .failed: .red
        case .needsPassword, .needsOverride: .orange
        default: nil
        }
    }
}

private struct JobCapsule: View {
    @Bindable var job: Job
    @Environment(JobCenter.self) private var center
    @State private var askPassword = false
    @State private var showReport = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .symbolEffect(.pulse, isActive: job.isRunning && !reduceMotion)
                    .accessibilityHidden(true)
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
                PasswordSheet(mode: .open(wrong: wrong), archiveName: job.title) { pw, remember in
                    if let pw { center.retry(job, password: pw, remember: remember) }
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
            if job.paused { return String(localized: "In pausa: un file esiste già") }
            guard let p = job.progress else { return "\(job.verb) in corso…" }
            let pct = p.totalBytes > 0 ? String(localized: "\(Int(p.fraction * 100))% · ") : ""
            return "\(pct)\(Int(job.smoothedSpeed / 1e6)) MB/s" + (p.currentEntry.map { " · \(($0 as NSString).lastPathComponent)" } ?? "")
        case let .finished(s): return s
        case let .failed(s): return s
        case .cancelled: return String(localized: "Annullato")
        case let .needsPassword(wrong): return wrong ? String(localized: "Password errata") : String(localized: "Archivio protetto da password")
        case .needsOverride: return String(localized: "Possibile zip bomb: estrazione fermata prima di scrivere")
        }
    }

    @ViewBuilder private var actions: some View {
        switch job.state {
        case .running:
            Button("Annulla", systemImage: "xmark") { job.cancelJob() }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
        case .finished, .failed:
            if !job.report.isEmpty || job.verifyOK != nil {
                Button("Dettagli", systemImage: "list.bullet.rectangle") { showDetails() }
                    .help("Dettagli")
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
        case .needsOverride:
            Button("Opzioni…") {
                if case let .extract(r) = job.kind { ZipBombPrompt.ask(for: job, request: r) }
            }
            .buttonStyle(.glass)
            dismiss
        }
    }

    /// Damaged entries open in the archive window (5.2), blocked items in their own window (6.3).
    private func showDetails() {
        if case let .test(archive, _) = job.kind, job.verifyOK == false {
            AppState.shared.reportRequests[archive] = job.id
            openWindow(id: "archive", value: archive)
        } else if !job.blocked.isEmpty {
            BlockedEntriesWindow.show(job)
        } else {
            showReport = true
        }
    }

    private var dismiss: some View {
        Button("Chiudi", systemImage: "xmark") { center.remove(job) }
            .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
    }
}
