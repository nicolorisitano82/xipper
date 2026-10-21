import SwiftUI
import UniformTypeIdentifiers
import XipperKit

/// Verification result or skipped entries after an extraction.
struct ReportSheet: View {
    let job: Job
    @Environment(\.dismiss) private var dismiss
    @State private var exporting = false

    private var ok: Bool { job.verifyOK ?? job.report.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Summary banner: the only glass here, tinted only to carry meaning (errors).
            HStack(spacing: 12) {
                Image(systemName: ok ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.largeTitle).foregroundStyle(ok ? .green : .red)
                VStack(alignment: .leading) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(job.title).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibleGlass(tint: ok ? nil : .red, in: RoundedRectangle(cornerRadius: 18))
            .padding(16)

            if !job.report.isEmpty {
                List(job.report, id: \.path) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(item.path, systemImage: "xmark.octagon").foregroundStyle(.primary)
                        Text(item.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 220)
            } else {
                Text("Tutte le voci hanno superato il controllo (CRC, codici di autenticazione, checksum dei codec).")
                    .foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 12)
            }
            HStack {
                if case let .test(archive, password) = job.kind, ok {
                    Button {
                        exportSums(archive, password: password)
                    } label: {
                        if exporting { ProgressView().controlSize(.small) } else { Text("Esporta SHA256SUMS…") }
                    }
                    .buttonStyle(.glass)
                    .disabled(exporting)
                    .help("Calcola l'impronta SHA-256 di ogni file, nel formato di shasum -c")
                }
                Spacer()
                Button("Chiudi") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520)
    }

    /// A second pass that hashes every file (5.1); the manifest is saved next to the archive by default.
    private func exportSums(_ archive: URL, password: String?) {
        let panel = NSSavePanel()
        panel.directoryURL = archive.deletingLastPathComponent()
        panel.nameFieldStringValue = archive.lastPathComponent + ".sha256sums"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true
        Task {
            let result = await Task.detached { Result { try Xipper.test(archive, password: password, workload: Preferences.workload, digests: true) } }.value
            exporting = false
            switch result {
            case let .success(r): try? r.sha256sums.write(to: url, atomically: true, encoding: .utf8)
            case let .failure(e):
                let alert = NSAlert()
                alert.messageText = String(localized: "Impossibile calcolare le impronte")
                alert.informativeText = (e as? XipperError).map(Job.localized) ?? e.localizedDescription
                alert.runModal()
            }
        }
    }

    private var title: String {
        switch job.kind {
        case .test: ok ? String(localized: "Archivio integro") : String(localized: "Problemi di integrità")
        case .extract: String(localized: "Voci non estratte per sicurezza")
        case .create: String(localized: "Report")
        }
    }
}
