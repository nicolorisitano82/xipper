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
    @State private var delivering = false

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
                    Button { delivering = true } label: { Label("Deliver a Copy…", systemImage: "shippingbox") }
                    if item.method != "logical" {
                        Menu {
                            Button("Raw Image (.dd)…") { export(e01: false) }
                            Button("E01 (EnCase)…") { export(e01: true) }
                        } label: { Label("Export", systemImage: "square.and.arrow.up") }
                        .fixedSize()
                    }
                }
                HStack {
                    Button { Task { await model.reverify(item.id) } } label: { Label("Verify Again", systemImage: "checkmark.shield") }
                        .disabled(model.verifying)
                    Button { NSWorkspace.shared.open(item.evidence.pdf) } label: { Label("Report (PDF)", systemImage: "doc.richtext") }
                        .disabled(!FileManager.default.fileExists(atPath: item.evidence.pdf.path))
                    Button { openWindow(id: "verify", value: item.evidence.archive) } label: { Label("Details", systemImage: "list.bullet.clipboard") }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([item.evidence.archive]) } label: { Label("Show in Finder", systemImage: "folder") }
                }
                if model.verifying { ProgressView().controlSize(.small) }
                if let b = model.busy { HStack { ProgressView().controlSize(.small); Text(b).foregroundStyle(.secondary) } }

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
        .sheet(isPresented: $delivering) { DeliverySheet(model: model, item: item) }
    }

    func export(e01: Bool) {
        let p = NSSavePanel()
        p.nameFieldStringValue = item.id + (e01 ? ".E01" : ".dd")
        p.message = e01 ? String(localized: "E01 segments of about 1.5 GB each, with the case fields, MD5 and SHA-1") : String(localized: "The image as raw bytes, checked against the source hash while written")
        guard p.runModal() == .OK, let u = p.url else { return }
        Task { _ = await model.export(item.id, raw: e01 ? nil : u, e01: e01 ? u : nil) }
    }

    func summary(_ e: ForensicCase.LogEntry) -> String {
        switch e.event {
        case "custody": [e.fields["from"], e.fields["to"]].compactMap { $0 }.joined(separator: " → ")
        case "evidence verified": e.fields["passed"] == "true" ? String(localized: "passed") : String(localized: "FAILED: ") + (e.fields["failed"] ?? "")
        case "acquisition failed", "acquisition interrupted": e.fields["reason"] ?? e.fields["error"] ?? ""
        case "evidence delivered": (e.fields["recipient"] ?? "") + " · " + (e.fields["format"] ?? "")
        case "evidence exported": (e.fields["format"] ?? "") + " · " + (e.fields["files"] ?? "")
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


/// A copy for someone (§4.7): format, access, the files of a logical acquisition; receipt and custody follow.
struct DeliverySheet: View {
    let model: CaseModel
    let item: EvidenceItem
    @Environment(\.dismiss) private var dismiss
    @State private var recipient = ""
    @State private var format = Delivery.Format.xiz
    @State private var protect = 0  // 0 key, 1 password, 2 none
    @State private var key = ""
    @State private var password = ""
    @State private var password2 = ""
    @State private var files: [String] = []
    @State private var chosen: Set<String> = []
    @State private var reason = ""
    @State private var notes = ""
    @State private var working = false
    @State private var done: URL?

    var image: Bool { item.method != "logical" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(format: String(localized: "Copy of %@ for…"), item.id)).font(.title2.bold()).padding()
            Form {
                TextField("Recipient", text: $recipient, prompt: Text("e.g. Procura di Milano, dott. Rossi"))
                Picker("Format", selection: $format) {
                    Text(image ? "XIZ (new archive for the recipient)" : "XIZ (the archive as acquired)").tag(Delivery.Format.xiz)
                    if image {
                        Text("Raw image + hashes").tag(Delivery.Format.raw)
                        Text("E01 (EnCase)").tag(Delivery.Format.e01)
                    } else {
                        Text("Some files, each with its proof").tag(Delivery.Format.files)
                    }
                }
                if format == .xiz && image {
                    Picker("Protection", selection: $protect) {
                        Text("Recipient's public key").tag(0)
                        Text("Password told separately").tag(1)
                        Text("None").tag(2)
                    }
                    if protect == 0 {
                        LabeledContent("Public key") {
                            TextField("", text: $key, prompt: Text("xizpk1… or xizpq1…")).font(.system(.body, design: .monospaced)).labelsHidden()
                        }
                    }
                    if protect == 1 {
                        SecureField("Password (at least 8 characters)", text: $password)
                        SecureField("Repeat password", text: $password2)
                    }
                }
                if format == .files {
                    List(files, id: \.self, selection: $chosen) { Text($0).lineLimit(1).truncationMode(.middle) }
                        .frame(minHeight: 140)
                }
                TextField("Reason", text: $reason)
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...3)
                Text(note).font(.caption).foregroundStyle(.secondary)
                if let done {
                    Label(String(format: String(localized: "Delivered: %@"), done.lastPathComponent), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .formStyle(.grouped)
            HStack {
                if working { ProgressView().controlSize(.small); Text(model.busy ?? "").foregroundStyle(.secondary) }
                Spacer()
                if let done {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([done]) }
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }
                    Button("Make the Copy") { start() }.keyboardShortcut(.defaultAction).disabled(!ready || working)
                }
            }
            .padding()
        }
        .frame(width: 560)
        .task {
            guard !image else { return }
            let url = item.evidence.archive
            files = (try? await Task.detached { try Xipper.list(url).filter { $0.kind == .file && !$0.path.hasPrefix("forensic/") }.map(\.path) }.value) ?? []
        }
    }

    var note: String {
        let what: String = switch format {
        case .xiz: image ? String(localized: "A new forensic archive with the same image and hashes, signed by you, for this recipient only.") : String(localized: "The archive as acquired, with all its signatures.")
        case .raw: String(localized: "The image as raw bytes and a text file with its SHA-256, MD5 and SHA-1.")
        case .e01: String(localized: "E01 segments with the case fields, MD5 and SHA-1, for tools that do not read XIZ.")
        case .files: String(localized: "Only the chosen files, each with a proof that it belongs to the signed archive: the rest stays private.")
        }
        return what + " " + String(localized: "A signed receipt goes with the copy, and the original gains a hand-over to the recipient.")
    }

    var ready: Bool {
        guard !recipient.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if format == .files { return !chosen.isEmpty }
        if format == .xiz && image {
            if protect == 0 { return key.hasPrefix("xizpk1") || key.hasPrefix("xizpq1") }
            if protect == 1 { return password.count >= 8 && password == password2 }
        }
        return true
    }

    func start() {
        var o = Delivery.Options(recipient: recipient.trimmingCharacters(in: .whitespaces))
        o.format = format
        if format == .xiz && image {
            if protect == 0 { o.recipientKeys = [key.trimmingCharacters(in: .whitespacesAndNewlines)] }
            if protect == 1 { o.password = password }
        }
        o.files = Array(chosen).sorted()
        o.reason = reason
        o.notes = notes
        working = true
        Task {
            done = await model.deliver(item.id, o)
            working = false
            password = ""; password2 = ""
        }
    }
}