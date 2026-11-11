import ForensicKit
import SwiftUI
import XipperKit

/// First window: new case, open case, verify an archive, recent cases. Without an operator name and a
/// signing key nothing can be signed, so those come first.
struct WelcomeView: View {
    @Environment(Prefs.self) private var prefs
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var creating = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 54)).foregroundStyle(.tint)
                Text("Xipper Forensic").font(.largeTitle.bold())
                Text("Acquisition, verification and chain of custody of digital evidence, in signed XIZ archives.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Preview — disks and partitions, files and folders, image files, Mac via Share Disk. Apple silicon only.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if !prefs.ready {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Set up the operator and the signing key first", systemImage: "person.badge.key")
                                .font(.headline).fixedSize(horizontal: false, vertical: true)
                            Text("Every step is signed: the case log, the archives, the reports.").font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Open Settings…") { openSettings() }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Button { creating = true } label: { Label("New Case…", systemImage: "folder.badge.plus").frame(maxWidth: .infinity, alignment: .leading) }
                        .disabled(!prefs.ready)
                    Button { if let u = Panels.openCase() { open(u, openWindow) } } label: {
                        Label("Open Case…", systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button { openWindow(id: "verify", value: URL?.none) } label: {
                        Label("Verify an Archive…", systemImage: "checkmark.shield").frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .controlSize(.large)
            }
            .padding(32)
            .frame(width: 360)

            Divider()

            VStack(alignment: .leading) {
                Text("Recent cases").font(.headline).padding([.top, .horizontal])
                let recents = Recents.all
                if recents.isEmpty {
                    Spacer()
                    Text("No cases yet").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    List(recents, id: \.self) { u in
                        Button { open(u, openWindow) } label: {
                            VStack(alignment: .leading) {
                                Text(u.deletingPathExtension().lastPathComponent).font(.body.weight(.medium))
                                Text(u.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(width: 340)
        }
        .frame(height: 540)
        .sheet(isPresented: $creating) { NewCaseView() }
        .onAppear { prefs.reloadKeys() }
    }
}

struct NewCaseView: View {
    @Environment(Prefs.self) private var prefs
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var f: [String: String] = [:]
    @State private var error: String?
    @State private var working = false

    static let fields = ["case_number", "title", "proceeding", "court", "examiner", "organization", "location", "notes"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New case").font(.title2.bold()).padding()
            Form {
                CaseFields(values: $f)
                Text("The case is a folder (.xfcase) with the case record, a signed log of every step and one folder per evidence item.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create…") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || (f["case_number"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 520)
        .onAppear {
            f["examiner"] = prefs.examiner
            f["organization"] = prefs.organization
        }
    }

    func create() {
        let number = (f["case_number"] ?? "").trimmingCharacters(in: .whitespaces)
        let name = number.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard let url = Panels.save(name: name + "." + ForensicCase.fileExtension, type: ForensicCase.fileExtension) else { return }
        let info = f.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.value.isEmpty }
        working = true
        Task {
            defer { working = false }
            do {
                let s = try prefs.signer()
                _ = try await Task.detached { try ForensicCase.create(at: url, info: info, signer: s) }.value
                open(url, openWindow)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// The case record's fields, in a fixed order.
struct CaseFields: View {
    @Binding var values: [String: String]

    var body: some View {
        ForEach(NewCaseView.fields, id: \.self) { k in
            if k == "notes" {
                TextField(Words.field(k), text: binding(k), axis: .vertical).lineLimit(2...5)
            } else {
                TextField(Words.field(k) + (k == "case_number" ? " *" : ""), text: binding(k))
            }
        }
    }

    func binding(_ k: String) -> Binding<String> {
        Binding(get: { values[k] ?? "" }, set: { values[k] = $0 })
    }
}
