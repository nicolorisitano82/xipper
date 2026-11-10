import AppKit
import ForensicKit
import SwiftUI
import UniformTypeIdentifiers
import XipperKit

/// Verification of any forensic .xiz, with or without its case (docs/XIPPER_FORENSIC.md §4.5):
/// also for whoever receives the evidence.
struct VerifyView: View {
    @Environment(Prefs.self) private var prefs
    @State private var archive: URL?
    @State private var expected = ""
    @State private var password = ""
    @State private var report: XizForensic.Report?
    @State private var running = false
    @State private var error: String?
    @State private var targeted = false

    init(archive: URL?) { _archive = State(initialValue: archive) }

    var expectedBytes: [UInt8]? {
        let h = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard h.count == 64 else { return nil }
        var out: [UInt8] = []
        var i = h.startIndex
        while i < h.endIndex {
            let j = h.index(i, offsetBy: 2)
            guard let b = UInt8(h[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "checkmark.shield").font(.title)
                VStack(alignment: .leading) {
                    Text(archive?.lastPathComponent ?? String(localized: "Verify a forensic archive")).font(.title2.bold())
                    if let a = archive { Text(a.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                }
                Spacer()
                Button("Choose…") { if let u = Panels.openArchive() { archive = u; report = nil } }
            }
            Form {
                TextField("SHA-256 from the written record (optional)", text: $expected, prompt: Text("64 hex digits"))
                if !expected.isEmpty && expectedBytes == nil { Text("Not a SHA-256: 64 hex digits.").foregroundStyle(.red).font(.caption) }
                SecureField("Password (only to check the content)", text: $password)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 120)
            HStack {
                Button("Verify") { verify() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(archive == nil || running || (!expected.isEmpty && expectedBytes == nil))
                if running { ProgressView().controlSize(.small); Text("Verifying…").foregroundStyle(.secondary) }
                Spacer()
                if report != nil {
                    Button("Report (PDF)…") { export(pdf: true) }
                    Button("Export JSON…") { export(pdf: false) }
                }
            }
            if let r = report {
                Divider()
                HStack {
                    StatusIcon(!r.passed ? StatusIcon.State.failed : r.checks.contains { $0.status == XizForensic.Check.Status.warning } ? StatusIcon.State.warning : StatusIcon.State.passed).font(.title)
                    Text(r.passed ? String(localized: "Verification passed") : String(localized: "Verification FAILED")).font(.title3.bold())
                }
                List {
                    Section("Checks") {
                        ForEach(r.checks, id: \.name) { c in
                            HStack(alignment: .firstTextBaseline) {
                                StatusIcon(check: c.status)
                                Text(Words.check(c.name)).bold()
                                Text(c.detail).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                    Section("Signed segments") {
                        ForEach(r.signatures, id: \.segment) { s in
                            HStack(alignment: .firstTextBaseline) {
                                StatusIcon(s.valid && s.chained ? .passed : .failed)
                                Text(String(format: String(localized: "Segment %lld"), s.segment)).bold()
                                Text(s.label)
                                if let t = s.time { Text(Words.time(ISO8601DateFormatter().string(from: t))).foregroundStyle(.secondary) }
                                Spacer()
                                Text(s.publicKeyText).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            } else if let error {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Spacer()
            } else {
                Spacer()
                Text("Checks the structure, the hash of every frame, the signature chain, the time-stamps and the source hash. The password is not needed for these.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 520)
        .navigationTitle(archive?.lastPathComponent ?? String(localized: "Verify"))
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first(where: { $0.pathExtension == "xiz" }) else { return false }
            archive = u; report = nil; error = nil
            return true
        } isTargeted: { targeted = $0 }
        .overlay { if targeted { RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 3).padding(4) } }
        .onAppear { if archive != nil && report == nil { verify() } }
    }

    func verify() {
        guard let archive else { return }
        running = true
        error = nil
        report = nil
        let pw = password.isEmpty ? nil : password, exp = expectedBytes
        Task {
            defer { running = false }
            do { report = try await Task.detached { try XizForensic.verify(archive.path, password: pw, expectSHA256: exp) }.value }
            catch { self.error = error.localizedDescription }
        }
    }

    func export(pdf: Bool) {
        guard let archive else { return }
        let base = archive.deletingPathExtension().lastPathComponent + ".verification"
        guard let out = Panels.save(name: base + (pdf ? ".pdf" : ".json"), type: pdf ? "pdf" : "json") else { return }
        let pw = password.isEmpty ? nil : password, exp = expectedBytes, lang = prefs.reportLanguage
        Task {
            do {
                try await Task.detached {
                    let o = try ForensicReport.build(archive: archive, password: pw, expectSHA256: exp)
                    try? FileManager.default.removeItem(at: out)
                    if pdf {
                        try ForensicPDF.render(o, language: lang).write(to: out)
                    } else {
                        try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: out)
                    }
                }.value
                NSWorkspace.shared.open(out)
            } catch { self.error = error.localizedDescription }
        }
    }
}
