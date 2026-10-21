import SwiftUI
import UniformTypeIdentifiers
import XipperKit

/// "Voci danneggiate" (5.2): shown in the archive window in place of the content.
/// A red glass banner floats over an opaque table of the damaged entries.
struct DamagedEntriesView: View {
    let job: Job
    let model: ArchiveModel
    /// Opens the extraction sheet with the intact entries selected.
    let extractIntact: (Set<String>) -> Void
    /// Repairs the archive from its PAR2 files (nil: no recovery data, or a repair is running).
    var repair: (() -> Void)?
    @State private var onlyErrors = true

    struct Row: Identifiable {
        let path: String
        let size: Int64
        let problem: SkippedEntry.Problem?
        var id: String { path }
    }

    private var failures: [SkippedEntry] { job.report }
    private var total: Int { job.testReport?.entries ?? model.fileCount }
    private var damagedPaths: Set<String> { Set(failures.map(\.path)) }
    /// Single-stream archives (tar.*, gz…) fail as a whole: there are no intact entries to pick.
    private var perEntry: Bool { model.format == .zip }

    private var rows: [Row] {
        let sizes = Dictionary(model.entries.map { ($0.path, $0.uncompressedSize) }, uniquingKeysWith: { a, _ in a })
        let bad = failures.map { Row(path: $0.path, size: sizes[$0.path] ?? -1, problem: $0.problem) }
        guard !onlyErrors else { return bad }
        let good = model.entries.filter { $0.kind == .file && !damagedPaths.contains($0.path) }
            .map { Row(path: $0.path, size: $0.uncompressedSize, problem: nil) }
        return bad + good
    }

    var body: some View {
        VStack(spacing: 0) {
            table
            Text(footnote)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                // Leaves room for the jobs HUD in the bottom-right corner.
                .frame(maxWidth: 520, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .safeAreaInset(edge: .top) { banner.padding(.horizontal, 16).padding(.top, 8) }
    }

    private var banner: some View {
        HStack(spacing: 14) {
            Image(systemName: "xmark.circle.fill").font(.largeTitle).foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(failures.count) voci danneggiate su \(total)").font(.title3.weight(.semibold))
                Text("Verifica completata in \(elapsed) · nessun dato scritto su disco").foregroundStyle(.secondary)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            if let repair {
                Button("Ripara", systemImage: "cross.case", action: repair)
                    .buttonStyle(.glassProminent)
                    .fixedSize()
                    .help("Ricostruisce le parti danneggiate dai dati di recupero PAR2")
            }
            Button("Esporta rapporto…") { exportReport() }
                .buttonStyle(.glass)
                .fixedSize()
            if perEntry && failures.count < total {
                Button("Estrai voci integre…") {
                    extractIntact(Set(model.entries.filter { $0.kind == .file && !damagedPaths.contains($0.path) }.map(\.path)))
                }
                .buttonStyle(.glassProminent)
                .fixedSize()
            }
        }
        .padding(16)
        .accessibleGlass(tint: .red, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityLabel(Text("\(failures.count) voci danneggiate su \(total)"))
    }

    private var table: some View {
        Table(rows) {
            TableColumn("Voce") { row in
                Label {
                    Text(row.path).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: row.problem == nil ? "doc" : "exclamationmark.triangle.fill")
                }
                .foregroundStyle(row.problem == nil ? Color.primary : Color.red)
            }
            .width(min: 220, ideal: 360)
            TableColumn("Dimensione") { row in
                Text(row.size >= 0 ? row.size.byteText : "—").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Problema") { row in
                Text(row.problem?.message ?? "").foregroundStyle(.secondary).lineLimit(2)
                    .help(failures.first { $0.path == row.path }?.reason ?? "")
            }
            .width(min: 200, ideal: 320)
            TableColumn("Esito") { row in
                if row.problem == nil {
                    Label("Integra", systemImage: "checkmark").foregroundStyle(.green)
                } else {
                    Label("Danneggiata", systemImage: "xmark").foregroundStyle(.red)
                }
            }
            .width(min: 90, ideal: 110)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Picker("Mostra", selection: $onlyErrors) {
                    Text("Tutte").tag(false)
                    Text("Solo errori").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Text("\(max(0, total - failures.count)) integre · \(failures.count) errori")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.bar)
        }
    }

    private var elapsed: String {
        let s = job.testReport?.elapsed ?? 0
        return s < 10 ? s.formatted(.number.precision(.fractionLength(1))) + " s" : Duration.seconds(s).formatted(.units(allowed: [.minutes, .seconds]))
    }

    private var footnote: String {
        let intact = max(0, total - failures.count)
        let first = perEntry && intact > 0
            ? String(localized: "Le altre \(intact) voci sono integre e si possono estrarre.")
            : String(localized: "L'archivio è un unico flusso compresso: i dati dopo il punto danneggiato non sono recuperabili.")
        let recovery = PAR2.indexFile(for: model.url) != nil
            ? String(localized: "Ci sono dati di recupero PAR2: «Ripara» ricostruisce le parti danneggiate, se il danno non supera la ridondanza.")
            : String(localized: "Riparazione non disponibile: l'archivio non contiene dati di recupero PAR2.")
        return first + " " + recovery
    }

    private func exportReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (model.url.deletingPathExtension().lastPathComponent) + " - verifica.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var text = String(localized: "Verifica di \(model.url.lastPathComponent)") + "\n"
        text += String(localized: "\(failures.count) voci danneggiate su \(total)") + "\n\n"
        for f in failures { text += "\(f.path)\t\(f.problem.message)\t\(f.reason)\n" }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
