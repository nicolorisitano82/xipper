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
    /// Little free space (XIZ from ZIP or 7z): possible here, chosen, free bytes on the volume.
    @State private var littleSpacePossible = false
    @State private var littleSpace = false
    @State private var freeBytes: Int64?

    /// Every archive format the compression window offers (single-file streams hold no archive).
    static let targets: [ArchiveFormat] = ArchiveFormat.multiItem

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
                        if let freeBytes, freeBytes < plan.spaceNeeded {
                            Label("Sul disco ci sono solo \(freeBytes.byteText) liberi", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(littleSpacePossible ? .secondary : Color.orange)
                        }
                        if plan.streamed && plan.recompressed > 0 {
                            Label("I file passano direttamente nel nuovo archivio, senza essere estratti su disco", systemImage: "arrow.right.circle")
                        }
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

            if littleSpacePossible {
                Toggle(isOn: $littleSpace) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Converti con poco spazio libero")
                        Text("Xipper converte un blocco alla volta e libera via via lo spazio dell'originale, che alla fine viene eliminato. Se si interrompe, anche per un calo di corrente, riaprendo l'originale Xipper riprende da dove era arrivato.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !littleSpace {
                Toggle("Sposta l'originale nel Cestino quando il nuovo archivio è verificato", isOn: $trashOriginal)
            }
            if !seriousLosses.isEmpty {
                Toggle("Ho capito cosa si perde", isOn: $acceptLosses)
            }
            Text(littleSpace ? "L'originale non si potrà più aprire da solo dopo il primo blocco: il nuovo archivio prende il suo nome solo dopo la verifica completa."
                             : "L'originale non viene modificato: il nuovo archivio prende il suo nome solo dopo la verifica.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Annulla", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Cambia formato") {
                    jobs.start(.convert(source: archive, target: target, format: format, password: password,
                                        trashOriginal: trashOriginal && !littleSpace, littleSpace: littleSpace))
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
        littleSpacePossible = false
        littleSpace = false
        let (archive, format, password) = (archive, format, password)
        let result = await Task.detached { () -> Result<ConversionPlan, Error> in
            var o = CreateOptions()
            o.format = format
            return Result { try Xipper.conversionPlan(archive, to: format, password: password, options: o) }
        }.value
        let (possible, free) = await Task.detached { () -> (Bool, Int64?) in
            let values = try? archive.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            var fs = statfs()
            let raw = statfs(archive.deletingLastPathComponent().path, &fs) == 0 ? Int64(fs.f_bavail) * Int64(fs.f_bsize) : nil
            let free = [values?.volumeAvailableCapacityForImportantUsage, raw].compactMap { $0 }.max()
            return (format == .xiz && Xipper.lowSpaceConversionProblem(archive, to: format, password: password) == nil, free)
        }.value
        freeBytes = free
        switch result {
        case let .success(p):
            plan = p
            littleSpacePossible = possible
            // Suggested when the usual way would not fit.
            littleSpace = possible && (free.map { $0 < p.spaceNeeded } ?? false)
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
