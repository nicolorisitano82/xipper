import SwiftUI
import XipperKit

/// «Cambia formato…»: pick the new format, see the plan (what keeps its compressed bytes, what is
/// recompressed, the free space needed, what would be lost), then run it as a job.
struct ConvertSheet: View {
    let archive: URL
    let current: ArchiveFormat?
    let password: String?
    @Environment(JobCenter.self) private var jobs
    @Environment(\.dismiss) private var dismiss
    @State private var format: ArchiveFormat = .sevenZip
    @State private var plan: ConversionPlan?
    @State private var planError: String?
    @State private var trashOriginal = false
    @State private var acceptLosses = false
    @State private var showDetails = false

    static let targets: [ArchiveFormat] = [.zip, .sevenZip, .xiz, .tarZstd, .tarXz, .tarGzip, .appleArchive]

    private var target: URL {
        var name = archive.lastPathComponent
        if let current, name.lowercased().hasSuffix("." + current.fileExtension) { name.removeLast(current.fileExtension.count + 1) }
        return uniqueURL(archive.deletingLastPathComponent().appendingPathComponent(name + "." + format.fileExtension))
    }

    private var seriousLosses: [ConversionPlan.Loss] { plan?.losses.filter { if case .recoveryData = $0 { false } else { true } } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cambia formato di “\(archive.lastPathComponent)”").font(.title3.weight(.semibold))
            Picker("Nuovo formato", selection: $format) {
                ForEach(Self.targets.filter { $0 != current }) { f in Text(f.displayName).tag(f) }
            }
            .pickerStyle(.menu)
            Text("Nuovo archivio: \(target.lastPathComponent), accanto all'originale")
                .font(.callout).foregroundStyle(.secondary)

            GroupBox {
                if let plan {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("\(plan.copied) file copiati senza ricomprimere (\(plan.bytesCopied.byteText))", systemImage: "bolt.fill")
                        Label("\(plan.recompressed) file ricompressi (\(plan.bytesRecompressed.byteText))", systemImage: "arrow.triangle.2.circlepath")
                        Label("Spazio libero necessario: fino a \(plan.spaceNeeded.byteText)", systemImage: "internaldrive")
                        ForEach(Array(plan.losses.enumerated()), id: \.offset) { _, loss in
                            Label(text(loss), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        if plan.recompressed > 0 {
                            DisclosureGroup("Perché si ricomprimono", isExpanded: $showDetails) {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 2) {
                                        ForEach(plan.items.filter { $0.action == .recompressed }.prefix(200), id: \.path) { i in
                                            Text("\(i.path) — \(i.reason ?? "")").font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 120)
                            }
                            .font(.callout)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if let planError {
                    Label(planError, systemImage: "xmark.octagon").foregroundStyle(.red)
                } else {
                    ProgressView("Preparo il piano…").frame(maxWidth: .infinity)
                }
            }

            Toggle("Sposta l'originale nel Cestino quando il nuovo archivio è verificato", isOn: $trashOriginal)
            if !seriousLosses.isEmpty {
                Toggle("Ho capito cosa si perde", isOn: $acceptLosses)
            }
            Text("L'originale non viene modificato: il nuovo archivio prende il suo nome solo dopo la verifica.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Annulla", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Cambia formato") {
                    jobs.start(.convert(source: archive, target: target, format: format, password: password, trashOriginal: trashOriginal))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(plan == nil || (!seriousLosses.isEmpty && !acceptLosses))
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { if format == current { format = current == .zip ? .sevenZip : .zip } }
        .task(id: format) { await loadPlan() }
    }

    private func loadPlan() async {
        plan = nil
        planError = nil
        acceptLosses = false
        let (archive, format, password) = (archive, format, password)
        let result = await Task.detached { () -> Result<ConversionPlan, Error> in
            var o = CreateOptions()
            o.format = format
            return Result { try Xipper.conversionPlan(archive, to: format, password: password, options: o) }
        }.value
        switch result {
        case let .success(p): plan = p
        case let .failure(e): planError = (e as? XipperError)?.description ?? e.localizedDescription
        }
    }

    private func text(_ loss: ConversionPlan.Loss) -> String {
        switch loss {
        case .signatures: String(localized: "Le firme non passano al nuovo archivio")
        case .accessGroups: String(localized: "I gruppi di accesso XIZ non passano al nuovo archivio")
        case let .recoveryData(f): String(localized: "I dati di recupero \(f) valgono solo per l'originale")
        case .encryption: String(localized: "Il nuovo archivio non avrà la password")
        }
    }
}
