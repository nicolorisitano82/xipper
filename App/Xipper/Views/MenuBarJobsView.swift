import SwiftUI
import XipperKit

/// Menu bar extra (7.2, optional): running jobs with their progress, plus Open Xipper and Settings.
/// Enabled in Settings › Integrations › "Icona nella barra dei menu".
struct MenuBarJobsView: View {
    @Environment(JobCenter.self) private var jobs
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var running: [Job] { jobs.jobs.filter(\.isRunning) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Xipper").font(.headline)
                    Text(running.isEmpty ? String(localized: "Nessun lavoro attivo") : String(localized: "\(running.count) lavori attivi"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !jobs.jobs.isEmpty {
                Divider()
                ForEach(jobs.jobs.prefix(6)) { job in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: job.symbol).foregroundStyle(.secondary).accessibilityHidden(true)
                            Text(job.title).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if job.isRunning {
                                Button("Annulla", systemImage: "xmark.circle.fill") { job.cancelJob() }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
                                    .help("Annulla")
                            }
                        }
                        if job.isRunning {
                            ProgressView(value: job.progress?.fraction ?? 0).progressViewStyle(.linear)
                        } else {
                            Text(status(job)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            Divider()
            Button("Apri Xipper") {
                openWindow(id: "home")
                NSApp.activate()
            }
            .buttonStyle(.borderless)
            Button("Impostazioni…") {
                openSettings()
                NSApp.activate()
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",")
        }
        .padding(14)
        .frame(width: 300)
    }

    private func status(_ job: Job) -> String {
        switch job.state {
        case let .finished(s), let .failed(s): s
        case .cancelled: String(localized: "Annullato")
        case .needsPassword: String(localized: "Password richiesta")
        case .needsOverride: String(localized: "Estrazione fermata")
        case .running: ""
        }
    }
}
