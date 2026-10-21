import SwiftUI
import XipperKit

/// Floating stack of glass capsules, one per job (Liquid Glass control layer).
struct JobsHUD: View {
    @Environment(JobCenter.self) private var center
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass
    /// With three or more jobs the HUD collapses into one capsule; a click expands it (7.1).
    @State private var expanded = false

    private var shown: [Job] { center.jobs.filter { !center.focused.contains($0.id) } }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .trailing, spacing: 8) {
                if shown.count >= 3 && !expanded {
                    compact
                        .accessibleGlass(in: Capsule())
                        .glassEffectID("compact", in: glass)
                        .onTapGesture { expanded = true }
                } else {
                    if shown.count >= 3 {
                        Button("Comprimi l'elenco", systemImage: "chevron.down") { expanded = false }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).help("Comprimi l'elenco")
                    }
                    ForEach(shown) { job in
                        JobCapsule(job: job)
                            .accessibleGlass(tint: tint(for: job), in: RoundedRectangle(cornerRadius: 24))
                            .glassEffectID(job.id, in: glass)
                            .transition(AnyTransition.morph(reduceMotion: reduceMotion, AnyTransition(.blurReplace)))
                    }
                }
            }
        }
        .frame(maxWidth: 380)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy, value: center.jobs.map(\.id))
    }

    /// Ring with the overall progress, "3 lavori", "46% · 5 s".
    private var compact: some View {
        let running = shown.filter(\.isRunning)
        let total = running.reduce(Int64(0)) { $0 + max(0, $1.progress?.totalBytes ?? 0) }
        let done = running.reduce(Int64(0)) { $0 + max(0, $1.progress?.completedBytes ?? 0) }
        let fraction = running.isEmpty ? 1 : (total > 0 ? Double(done) / Double(total) : 0)
        let eta = running.compactMap(\.eta).max()
        return HStack(spacing: 10) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 4)
                Circle().trim(from: 0, to: fraction).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(shown.count) lavori").font(.callout.weight(.semibold))
                Text(running.isEmpty ? String(localized: "Completati")
                                     : "\(Int(fraction * 100))%" + (eta.map { " · \(Int($0.rounded())) s" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contentShape(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Mostra i lavori")
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
                    .symbolEffect(.pulse, isActive: job.isRunning && !job.userPaused && !job.paused && !reduceMotion)
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
            if job.userPaused { return String(localized: "In pausa") }
            guard let p = job.progress else { return "\(job.verb) in corso…" }
            let pct = p.totalBytes > 0 ? String(localized: "\(Int(p.fraction * 100))% · ") : ""
            return "\(pct)" + (job.smoothedSpeed > 0 ? "\(Int(job.smoothedSpeed / 1e6)) MB/s" : "…") + (p.currentEntry.map { " · \(($0 as NSString).lastPathComponent)" } ?? "")
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
            Button(job.userPaused ? "Riprendi" : "Pausa", systemImage: job.userPaused ? "play.fill" : "pause.fill") { job.togglePause() }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .help(job.userPaused ? "Riprendi" : "Pausa")
            Button("Annulla", systemImage: "xmark") { job.cancelJob() }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .help("Annulla")
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
