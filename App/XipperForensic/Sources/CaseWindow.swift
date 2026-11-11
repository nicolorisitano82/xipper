import AppKit
import ForensicKit
import SwiftUI
import XipperKit

/// A case: summary, log, evidence items (docs/XIPPER_FORENSIC.md §4.2).
struct CaseWindow: View {
    @State private var model: CaseModel
    @State private var selection: Pane? = .summary
    @State private var acquiring = false

    enum Pane: Hashable { case summary, log, evidence(String) }

    init(url: URL) { _model = State(initialValue: CaseModel(url: url)) }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Case") {
                    Label("Summary", systemImage: "doc.text").tag(Pane.summary)
                    Label("Log", systemImage: "list.bullet.rectangle").tag(Pane.log)
                }
                Section("Evidence") {
                    ForEach(model.items) { i in
                        HStack {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(i.id).font(.body.weight(.medium))
                                    if !i.description.isEmpty || !i.model.isEmpty {
                                        Text(i.description.isEmpty ? i.model : i.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            } icon: { Image(systemName: i.method == "logical" ? "folder" : "internaldrive") }
                            Spacer()
                            StatusIcon(i.passed == nil ? .skipped : i.passed! ? (i.warnings ? .warning : .passed) : .failed)
                        }
                        .tag(Pane.evidence(i.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            .safeAreaInset(edge: .bottom) {
                Button { acquiring = true } label: { Label("New Evidence Item…", systemImage: "plus") }
                    .buttonStyle(.borderless).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            switch selection {
            case .summary, nil: CaseSummaryView(model: model)
            case .log: CaseLogView(model: model)
            case let .evidence(id):
                if let i = model.items.first(where: { $0.id == id }) { EvidenceView(model: model, item: i) } else { Text("No evidence item selected") }
            }
        }
        .navigationTitle(model.title)
        .navigationSubtitle(model.info["proceeding"] ?? model.info["title"] ?? "")
        .toolbar {
            ToolbarItem(placement: .status) {
                Label("Sources are never written", systemImage: "lock.shield")
                    .labelStyle(.titleAndIcon).foregroundStyle(.green).font(.callout)
                    .padding(.horizontal, 12)
                    .help("Xipper Forensic only reads the sources: files and folders are opened read-only and nothing is written next to them.")
            }
            ToolbarItem {
                Button { Task { await model.verifyCase() } } label: { Label("Verify Case", systemImage: "checkmark.shield") }
            }
            ToolbarItem {
                Button { NSWorkspace.shared.activateFileViewerSelecting([model.url]) } label: { Label("Show in Finder", systemImage: "folder") }
            }
        }
        .sheet(isPresented: $acquiring) {
            AcquireWizard(model: model) { id in
                if let id { selection = .evidence(id) }
            }
        }
        .alert("Error", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct CaseSummaryView: View {
    let model: CaseModel
    @State private var editing = false
    @State private var draft: [String: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(model.title).font(.largeTitle.bold())
                    Spacer()
                    Button(editing ? "Cancel" : "Edit…") { draft = model.info; editing.toggle() }
                }
                if editing {
                    Form {
                        CaseFields(values: $draft)
                        Text("The change goes into the log with the hashes of the old and new record.").font(.caption).foregroundStyle(.secondary)
                    }
                    .formStyle(.grouped)
                    HStack {
                        Spacer()
                        Button("Save Changes") {
                            let new = draft.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.value.isEmpty }
                            Task { await model.update(new); editing = false }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled((draft["case_number"] ?? "").isEmpty)
                    }
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        ForEach(NewCaseView.fields + model.info.keys.filter { !NewCaseView.fields.contains($0) }.sorted(), id: \.self) { k in
                            if let v = model.info[k], !v.isEmpty {
                                GridRow {
                                    Text(Words.field(k)).foregroundStyle(.secondary)
                                    Text(v).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }

                GroupBox("Integrity of the case") {
                    VStack(alignment: .leading, spacing: 6) {
                        if model.verifying {
                            HStack { ProgressView().controlSize(.small); Text("Verifying…") }
                        } else if let v = model.verification {
                            HStack {
                                StatusIcon(v.passed ? .passed : .failed)
                                Text(v.passed ? String(localized: "Log, case record, archives and reports match what the log recorded")
                                              : String(localized: "Problems found"))
                                    .font(.headline)
                            }
                            Text(String(format: String(localized: "%lld log entries, signed by %@"), v.entries, v.signers.values.sorted().joined(separator: ", ")))
                                .font(.callout).foregroundStyle(.secondary)
                            ForEach(v.problems, id: \.self) { p in Label(p, systemImage: "xmark").foregroundStyle(.red) }
                        } else {
                            Text("Checks the signature and chain of every log line, the case record and the hash of every archive and report.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Button("Verify Case") { Task { await model.verifyCase() } }.disabled(model.verifying)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                GroupBox("Evidence") {
                    if model.items.isEmpty {
                        Text("No evidence items yet: add one with “New Evidence Item…”.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    } else {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                            ForEach(model.items) { i in
                                GridRow {
                                    StatusIcon(i.passed == true ? (i.warnings ? .warning : .passed) : .failed)
                                    Text(i.id).bold()
                                    Text(Words.method(i.method))
                                    Text(Words.bytes(i.sourceSize)).monospacedDigit()
                                    Text(i.sourceSHA256.prefix(16) + "…").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(4)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }
}

struct CaseLogView: View {
    let model: CaseModel
    @State private var note = ""
    @State private var selected: Int?

    var body: some View {
        VStack(spacing: 0) {
            Table(model.entries.reversed(), selection: $selected) {
                TableColumn("#") { e in Text("\(e.seq)").monospacedDigit() }.width(36)
                TableColumn("Time (UTC)") { e in Text(e.time).font(.system(.callout, design: .monospaced)) }.width(min: 170, ideal: 200)
                TableColumn("Event") { e in Text(Words.event(e.event)) }.width(min: 140, ideal: 170)
                TableColumn("By") { e in Text(e.by) }.width(min: 90, ideal: 120)
                TableColumn("Details") { e in
                    Text(e.fields.filter { !$0.key.hasSuffix("sha256") }.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: " · "))
                        .lineLimit(2).help(e.line)
                }
            }
            Divider()
            HStack {
                TextField("Add a note to the log (signed, cannot be removed)", text: $note)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add Note", action: add).disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
    }

    func add() {
        let t = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        note = ""
        Task { await model.note(t) }
    }
}

extension ForensicCase.LogEntry: Identifiable {
    public var id: Int { seq }
}
