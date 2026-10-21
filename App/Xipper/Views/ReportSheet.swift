import SwiftUI
import XipperKit

/// Verification result or skipped entries after an extraction.
struct ReportSheet: View {
    let job: Job
    @Environment(\.dismiss) private var dismiss

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
                Spacer()
                Button("Chiudi") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520)
    }

    private var title: String {
        switch job.kind {
        case .test: ok ? String(localized: "Archivio integro") : String(localized: "Problemi di integrità")
        case .extract: String(localized: "Voci non estratte per sicurezza")
        case .create: String(localized: "Report")
        }
    }
}
