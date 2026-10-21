import AppKit
import SwiftUI
import XipperKit

/// "Estrai N elementi" (3.2): destination, structure, overwrite policy.
struct ExtractSheet: View {
    let archive: URL
    /// nil = the whole archive.
    let selection: Set<String>?
    let itemNames: [String]
    let totalSize: Int64
    @Environment(JobCenter.self) private var jobs
    @Environment(\.dismiss) private var dismiss

    @State private var destination: URL
    @State private var flatten = false
    @State private var overwrite: OverwritePolicy = .ask
    @State private var reveal = true
    @State private var candidates: [URL]

    init(archive: URL, selection: Set<String>?, itemNames: [String], totalSize: Int64) {
        self.archive = archive
        self.selection = selection
        self.itemNames = itemNames
        self.totalSize = totalSize
        let base = Xipper.baseName(archive.lastPathComponent)
        let suggested = archive.deletingLastPathComponent().appendingPathComponent(base, isDirectory: true)
        _destination = State(initialValue: suggested)
        let fm = FileManager.default
        let extra = [FileManager.SearchPathDirectory.downloadsDirectory, .desktopDirectory, .documentDirectory]
            .compactMap { fm.urls(for: $0, in: .userDomainMask).first?.appendingPathComponent(base, isDirectory: true) }
        _candidates = State(initialValue: [suggested] + extra.filter { $0 != suggested })
    }

    private var count: Int { selection?.count ?? itemNames.count }
    private var quarantined: Bool { getxattr(archive.path, "com.apple.quarantine", nil, 0, 0, 0) > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selection == nil ? "Estrai \(archive.lastPathComponent)" : "Estrai \(count) element\(count == 1 ? "o" : "i")")
                    .font(.title2.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary).lineLimit(2)
            }
            Form {
                Picker("Destinazione", selection: $destination) {
                    ForEach(candidates, id: \.self) { url in
                        Label(display(url), systemImage: "folder.fill").tag(url)
                    }
                }
                Button("Altra cartella…") { choose() }
                Picker("Struttura", selection: $flatten) {
                    Text("Mantieni le cartelle").tag(false)
                    Text("Solo i file, tutti nella destinazione").tag(true)
                }
                .pickerStyle(.radioGroup)
                Picker("Se un file esiste già", selection: $overwrite) {
                    Text("Chiedi ogni volta").tag(OverwritePolicy.ask)
                    Text("Sostituisci").tag(OverwritePolicy.replace)
                    Text("Mantieni entrambi").tag(OverwritePolicy.keepBoth)
                    Text("Salta").tag(OverwritePolicy.skip)
                }
                Toggle("Apri la cartella al termine", isOn: $reveal)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            if quarantined {
                Label {
                    Text("L'archivio viene da Internet: i file estratti restano in quarantena e Gatekeeper li controllerà alla prima apertura.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.shield").foregroundStyle(.green)
                }
                .font(.callout)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: .rect(cornerRadius: 12))
            }
            HStack {
                Spacer()
                Button("Annulla", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(selection == nil ? "Estrai" : "Estrai \(count) element\(count == 1 ? "o" : "i")") { start() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private var subtitle: String {
        let names = itemNames.prefix(3).joined(separator: ", ") + (itemNames.count > 3 ? "…" : "")
        return "\(names) · \(totalSize.byteText)"
    }

    /// "Download › Progetto-Atlante".
    private func display(_ url: URL) -> String {
        "\(url.deletingLastPathComponent().lastPathComponent) › \(url.lastPathComponent)"
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Estrai qui"
        guard panel.runModal() == .OK, let u = panel.url else { return }
        if !candidates.contains(u) { candidates.insert(u, at: 0) }
        destination = u
    }

    private func start() {
        jobs.start(.extract(ExtractRequest(archive: archive, destination: destination, mode: .into, selection: selection,
                                           flatten: flatten, overwrite: overwrite, reveal: reveal)))
        dismiss()
    }
}
