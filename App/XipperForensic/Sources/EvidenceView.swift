import AppKit
import ForensicKit
import SwiftUI
import XipperKit

/// One evidence item: stages, hashes, actions, history (docs/XIPPER_FORENSIC.md §4.2, §4.6).
struct EvidenceView: View {
    let model: CaseModel
    let item: EvidenceItem
    @Environment(\.openWindow) private var openWindow
    @State private var custody = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.id + (item.description.isEmpty ? "" : " · " + item.description)).font(.largeTitle.bold())
                    if !item.model.isEmpty || !item.serial.isEmpty {
                        Text([item.model, item.serial.isEmpty ? "" : "SN " + item.serial].filter { !$0.isEmpty }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 18) {
                    Stage(title: String(localized: "acquired"), state: .passed)
                    Stage(title: String(localized: "verified"), state: item.passed == true ? (item.warnings ? .warning : .passed) : .failed)
                    Stage(title: String(localized: "signed"), state: item.signers.isEmpty ? .failed : .passed)
                    Stage(title: String(localized: "time-stamped"), state: item.timestamped ? .passed : .skipped)
                    Stage(title: String(format: String(localized: "hand-overs: %lld"), item.custody), state: item.custody > 0 ? .passed : .skipped)
                }
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    row("Method", Words.method(item.method))
                    if let f = item.files {
                        row("Files", f + (item.skipped > 0 ? " " + String(format: String(localized: "(%lld not acquired: see the inventory)"), item.skipped) : ""))
                    }
                    row("Source size", Words.bytes(item.sourceSize))
                    row("Archive size", Words.bytes(item.archiveBytes))
                    hash(item.method == "logical" ? "Inventory SHA-256" : "Source SHA-256", item.sourceSHA256)
                    if let m = item.md5 { hash("MD5", m) }
                    if let s = item.sha1 { hash("SHA-1", s) }
                    hash("Archive SHA-256", item.archiveSHA256)
                    row("Signed by", item.signers.joined(separator: ", "))
                }

                Text("Write the archive's SHA-256 into the written record: it is the reference that makes any later change evident.")
                    .font(.callout).foregroundStyle(.secondary)

                HStack {
                    Button { custody = true } label: { Label("Hand-over…", systemImage: "person.2") }
                    Button { Task { await model.reverify(item.id) } } label: { Label("Verify Again", systemImage: "checkmark.shield") }
                        .disabled(model.verifying)
                    Button { NSWorkspace.shared.open(item.evidence.pdf) } label: { Label("Report (PDF)", systemImage: "doc.richtext") }
                        .disabled(!FileManager.default.fileExists(atPath: item.evidence.pdf.path))
                    Button { openWindow(id: "verify", value: item.evidence.archive) } label: { Label("Details", systemImage: "list.bullet.clipboard") }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([item.evidence.archive]) } label: { Label("Show in Finder", systemImage: "folder") }
                }
                if model.verifying { ProgressView().controlSize(.small) }

                Text("History").font(.title3.bold()).padding(.top, 6)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.entries(for: item.id).reversed()) { e in
                        HStack(alignment: .firstTextBaseline) {
                            Text(Words.time(e.time)).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 190, alignment: .leading)
                            Text(Words.event(e.event)).bold()
                            Text(summary(e)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .sheet(isPresented: $custody) { CustodySheet(model: model, id: item.id) }
    }

    func summary(_ e: ForensicCase.LogEntry) -> String {
        switch e.event {
        case "custody": [e.fields["from"], e.fields["to"]].compactMap { $0 }.joined(separator: " → ")
        case "evidence verified": e.fields["passed"] == "true" ? String(localized: "passed") : String(localized: "FAILED: ") + (e.fields["failed"] ?? "")
        case "acquisition failed", "acquisition interrupted": e.fields["reason"] ?? e.fields["error"] ?? ""
        default: ""
        }
    }

    @ViewBuilder func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    @ViewBuilder func hash(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            HStack {
                Text(value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy")
            }
        }
    }
}

struct Stage: View {
    let title: String
    let state: StatusIcon.State

    var body: some View {
        HStack(spacing: 5) {
            StatusIcon(state)
            Text(title).font(.callout)
        }
    }
}

/// A hand-over (§4.6): a custody segment signed at the end of the archive, and a log line.
struct CustodySheet: View {
    let model: CaseModel
    let id: String
    @Environment(Prefs.self) private var prefs
    @Environment(\.dismiss) private var dismiss
    @State private var from = ""
    @State private var to = ""
    @State private var reason = ""
    @State private var seals = ""
    @State private var notes = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(format: String(localized: "Hand-over of %@"), id)).font(.title2.bold()).padding()
            Form {
                TextField("From", text: $from)
                TextField("To", text: $to)
                TextField("Reason", text: $reason)
                TextField("State of the seals", text: $seals, prompt: Text("e.g. intact, seal no. 4471"))
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...4)
                Text("A custody segment, signed with your key, is appended to the archive; the content is not touched and the earlier signatures stay valid.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Record Hand-over") {
                    working = true
                    var f = ["reason": reason, "seals": seals, "notes": notes].mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    f = f.filter { !$0.value.isEmpty }
                    Task {
                        if await model.custody(id, from: from, to: to, fields: f) { dismiss() }
                        working = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || from.trimmingCharacters(in: .whitespaces).isEmpty || to.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 500)
        .onAppear { from = prefs.examiner }
    }
}
