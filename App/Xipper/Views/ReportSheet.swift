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
            // Summary banner: tinted only to carry meaning (errors); "Il vetro non si tinge" when intact (5.1).
            HStack(spacing: 12) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 40)).foregroundStyle(ok ? .green : .red)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(subtitle).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibleGlass(tint: ok ? nil : .red, in: RoundedRectangle(cornerRadius: 18))
            .padding(16)

            if isTest && ok {
                verifiedTable
            } else if !job.report.isEmpty {
                List(job.report, id: \.path) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(item.path, systemImage: "xmark.octagon").foregroundStyle(.primary)
                        Text(item.problem.message).font(.caption).foregroundStyle(.secondary).help(item.reason)
                    }
                }
                .frame(minHeight: 220)
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
                Button(isTest && ok ? String(localized: "Fine") : String(localized: "Chiudi")) { dismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: isTest && ok ? 640 : 520)
        .task {
            guard isTest, ok, case let .test(archive, password) = job.kind else { return }
            entries = await Task.detached { (try? Xipper.list(archive, password: password)) ?? [] }.value
                .filter { $0.kind == .file && !$0.isAppleDoubleMetadata }
        }
    }

    private var isTest: Bool { if case .test = job.kind { true } else { false } }
    @State private var entries: [ArchiveEntry] = []
    @State private var onlyErrors = false

    private var subtitle: String {
        guard isTest, let r = job.testReport else { return job.title }
        let speed = r.elapsed > 0 ? Double(r.bytes) / r.elapsed : 0
        return String(localized: "\(job.title) · verificato senza scrivere su disco · \(r.elapsed.formatted(.number.precision(.fractionLength(1)))) s · \(Int64(speed).byteText)/s")
    }

    /// 5.1: Tutte / Solo errori, then Voce · Dimensione · CRC-32 · Esito.
    private var verifiedTable: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Mostra", selection: $onlyErrors) {
                    Text("Tutte").tag(false)
                    Text("Solo errori").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Text("\(entries.count) integre · 0 errori").foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
            Table(onlyErrors ? [] : entries) {
                TableColumn("Voce") { e in Text(e.path).lineLimit(1).truncationMode(.middle) }
                    .width(min: 200, ideal: 300)
                TableColumn("Dimensione") { e in Text(e.uncompressedSize >= 0 ? e.uncompressedSize.byteText : "—").monospacedDigit().foregroundStyle(.secondary) }
                    .width(min: 70, ideal: 90)
                TableColumn("CRC-32") { e in
                    Text(e.crc32.map { String(format: "%08X", $0) } ?? "—").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 90)
                TableColumn("Esito") { _ in Label("Integra", systemImage: "checkmark").foregroundStyle(.green) }
                    .width(min: 70, ideal: 80)
            }
            .frame(minHeight: 260)
        }
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
        case .test: ok ? String(localized: "Tutte le \(entries.isEmpty ? (job.testReport?.entries ?? 0) : entries.count) voci sono integre") : String(localized: "Problemi di integrità")
        case .extract: String(localized: "Voci non estratte per sicurezza")
        case .create: String(localized: "Report")
        }
    }
}
