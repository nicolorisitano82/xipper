import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XipperKit

/// A signed document (3.3): a `.p7m`, a signed PDF or an ASiC container, with every signature
/// checked: who, when, whether it is qualified, whether the certificate was revoked.
@MainActor
@Observable
final class SignedDocumentModel {
    let url: URL
    var document: SignedDocument?
    var error: String?
    var loading = false
    /// The trusted list used (nil: none available offline).
    var listDate: Date?

    init(url: URL) { self.url = url }

    var online: Bool { Preferences.defaults.string(forKey: PrefKey.signaturesOnline) == "yes" }
    var askedOnline: Bool { !(Preferences.defaults.string(forKey: PrefKey.signaturesOnline) ?? "").isEmpty }

    func load() {
        loading = true
        error = nil
        let url = url, online = online
        let country = Preferences.defaults.string(forKey: PrefKey.signaturesCountry) ?? "IT"
        Task {
            let result = await Task.detached { () -> Result<(SignedDocument, Date?), Error> in
                let tl = country.isEmpty ? nil : (online ? (try? TrustedList.load(country: country)) : TrustedList.cached(country: country))
                do {
                    let d = try Xipper.verifySignedDocument(url, options: SignatureCheckOptions(trustedList: tl, online: online))
                    return .success((d, tl?.issued))
                } catch { return .failure(error) }
            }.value
            switch result {
            case let .success((d, date)): document = d; listDate = date
            case let .failure(e): error = e.localizedDescription
            }
            loading = false
        }
    }

    func setOnline(_ yes: Bool) {
        Preferences.defaults.set(yes ? "yes" : "no", forKey: PrefKey.signaturesOnline)
        load()
    }

    /// Writes the signed document (inside a .p7m, or the ASiC-S file) where the user chooses.
    func extractDocument() {
        guard let doc = document, let content = doc.content else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = doc.contentName
        panel.directoryURL = url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do { try Data(content).write(to: dest) } catch { self.error = error.localizedDescription }
    }

    /// Opens the signed document with its usual app (a copy in a temporary folder).
    func openDocument() {
        guard let doc = document else { return }
        if doc.format == .pdf { NSWorkspace.shared.open(url); return }
        guard let content = doc.content else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xipper-signed-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent((doc.contentName as NSString).lastPathComponent)
        do {
            try Data(content).write(to: file)
            try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch { self.error = error.localizedDescription }
    }

    func copyReport() {
        guard let doc = document else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SignedDocumentView.report(doc, file: url.lastPathComponent), forType: .string)
    }
}

struct SignedDocumentView: View {
    let url: URL
    @State private var model: SignedDocumentModel

    init(url: URL) {
        self.url = url
        _model = State(initialValue: SignedDocumentModel(url: url))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !model.askedOnline { consent }
                if model.loading && model.document == nil {
                    ProgressView("Verifica delle firme…").frame(maxWidth: .infinity)
                } else if let e = model.error {
                    Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                } else if let doc = model.document {
                    header(doc)
                    ForEach(Array(doc.signatures.enumerated()), id: \.offset) { i, s in card(i, s, doc) }
                    footer(doc)
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(url.lastPathComponent)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.document?.content != nil || model.document?.format == .pdf {
                    Button("Apri documento", systemImage: "doc.text") { model.openDocument() }
                        .help("Apri il documento firmato con la sua app")
                }
                if model.document?.content != nil {
                    Button("Estrai documento…", systemImage: "square.and.arrow.down") { model.extractDocument() }
                        .help("Salva il documento firmato, senza la busta di firma")
                }
                Button("Copia rapporto", systemImage: "doc.on.clipboard") { model.copyReport() }
                    .help("Copia negli appunti il rapporto della verifica")
                    .disabled(model.document == nil)
                Button("Verifica di nuovo", systemImage: "arrow.clockwise") { model.load() }
                    .help("Ripeti la verifica delle firme")
                    .disabled(model.loading)
            }
        }
        .task { model.load() }
        .frame(minWidth: 560, minHeight: 420)
    }

    private var consent: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Controlli in rete", systemImage: "network").font(.headline)
                Text("Per dire se una firma è qualificata Xipper usa l'elenco di fiducia europeo (per l'Italia quello di AgID), e per sapere se un certificato è stato revocato interroga l'autorità che l'ha emesso. Servono connessioni a quei servizi, solo quando verifichi una firma. Senza, Xipper usa l'elenco già scaricato e i dati di revoca contenuti nel file.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Consenti") { model.setOnline(true) }.buttonStyle(.borderedProminent)
                    Button("Non ora") { model.setOnline(false) }
                }
                Text("Puoi cambiare idea in Impostazioni › Sicurezza.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }

    private func header(_ doc: SignedDocument) -> some View {
        let (icon, color, text) = Self.verdict(doc)
        return VStack(alignment: .leading, spacing: 6) {
            Label(text, systemImage: icon).font(.title2.weight(.semibold)).foregroundStyle(color)
            Text(doc.format == .pdf ? String(localized: "PDF firmato · \(doc.signatures.count) firme")
                 : String(localized: "\(doc.contentName) · \(doc.signatures.count) firme"))
                .foregroundStyle(.secondary)
        }
    }

    static func verdict(_ doc: SignedDocument) -> (String, Color, String) {
        if !doc.allValid { return ("xmark.seal.fill", .red, String(localized: "Firma non valida")) }
        switch doc.level {
        case .qualified: return ("checkmark.seal.fill", .green, String(localized: "Firma qualificata valida"))
        case .qualifiedCertificate: return ("checkmark.seal", .green, String(localized: "Firma valida con certificato qualificato"))
        case .advanced: return ("checkmark.seal", .blue, String(localized: "Firma valida, certificato non qualificato"))
        case .untrustedSigner: return ("questionmark.diamond", .orange, String(localized: "Firma integra, firmatario non verificato"))
        case .invalid: return ("xmark.seal.fill", .red, String(localized: "Firma non valida"))
        }
    }

    private func card(_ i: Int, _ s: DocumentSignature, _ doc: SignedDocument) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(s.kind == .documentTimestamp ? String(localized: "Marca temporale del documento")
                         : (s.signer?.subject.display ?? String(localized: "Firmatario sconosciuto")))
                        .font(.headline)
                    Spacer()
                    Text(Self.levelText(s.level)).font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Self.levelColor(s.level).opacity(0.15), in: Capsule())
                        .foregroundStyle(Self.levelColor(s.level))
                }
                if doc.format == .p7m, s.depth > 0 {
                    Text("Firma interna, livello \(s.depth)").font(.caption).foregroundStyle(.secondary)
                }
                if let c = s.signer {
                    if let cf = c.taxCode { LabeledContent("Codice fiscale", value: cf) }
                    if let o = c.subject.organization { LabeledContent("Organizzazione", value: o) }
                    LabeledContent("Emesso da", value: c.issuer.display)
                    if let q = s.qualifiedAuthority { LabeledContent("Elenco di fiducia", value: q) }
                    LabeledContent("Validità", value: "\(c.notBefore.formatted(date: .abbreviated, time: .omitted)) – \(c.notAfter.formatted(date: .abbreviated, time: .omitted))")
                }
                if let ts = s.timestamp {
                    LabeledContent("Marca temporale", value: "\(ts.time.formatted(date: .abbreviated, time: .standard)) · \(ts.authority)\(ts.qualified ? String(localized: " · qualificata") : "")")
                }
                if let t = s.claimedTime {
                    LabeledContent("Ora dichiarata", value: t.formatted(date: .abbreviated, time: .standard))
                }
                LabeledContent("Integrità", value: s.integrity ? String(localized: "il documento è quello firmato") : String(localized: "il documento è stato modificato"))
                LabeledContent("Revoca", value: Self.revocationText(s.revocation))
                ForEach(s.problems, id: \.self) { p in
                    Label(p, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(4)
        }
    }

    private func footer(_ doc: SignedDocument) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if doc.trustedList == nil {
                Text("Nessun elenco di fiducia disponibile: non si può dire se le firme sono qualificate. Consenti i controlli in rete in Impostazioni › Sicurezza.")
            } else if let date = model.listDate {
                Text("Elenco di fiducia del \(date.formatted(date: .abbreviated, time: .omitted)).")
            }
            Text("Xipper verifica le firme dal punto di vista tecnico; il loro valore legale in un caso concreto va valutato da un esperto.")
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    static func levelText(_ l: SignatureLevel) -> String {
        switch l {
        case .qualified: String(localized: "Qualificata")
        case .qualifiedCertificate: String(localized: "Certificato qualificato")
        case .advanced: String(localized: "Avanzata")
        case .untrustedSigner: String(localized: "Non verificato")
        case .invalid: String(localized: "Non valida")
        }
    }

    static func levelColor(_ l: SignatureLevel) -> Color {
        switch l {
        case .qualified, .qualifiedCertificate: .green
        case .advanced: .blue
        case .untrustedSigner: .orange
        case .invalid: .red
        }
    }

    static func revocationText(_ r: RevocationStatus) -> String {
        switch r {
        case .notChecked: String(localized: "non controllata")
        case let .good(source): String(localized: "certificato non revocato (\(source))")
        case let .revoked(date, _): date.map { String(localized: "certificato REVOCATO il \($0.formatted(date: .abbreviated, time: .shortened))") }
            ?? String(localized: "certificato REVOCATO")
        case let .revokedLater(date, _): String(localized: "revocato dopo la firma, il \(date.formatted(date: .abbreviated, time: .omitted))")
        case .unknown: String(localized: "stato sconosciuto")
        }
    }

    /// A plain-text report, for the clipboard.
    static func report(_ doc: SignedDocument, file: String) -> String {
        var lines = ["\(file) — \(verdict(doc).2)", ""]
        for (i, s) in doc.signatures.enumerated() {
            lines.append("\(i + 1). \(s.signer?.subject.display ?? "?") — \(levelText(s.level))")
            if let c = s.signer {
                if let cf = c.taxCode { lines.append("   " + String(localized: "Codice fiscale") + ": \(cf)") }
                lines.append("   " + String(localized: "Emesso da") + ": \(c.issuer.display)")
                lines.append("   SHA-256: \(c.sha256)")
            }
            if let ts = s.timestamp { lines.append("   " + String(localized: "Marca temporale") + ": \(ts.time.formatted()) · \(ts.authority)") }
            if let t = s.claimedTime { lines.append("   " + String(localized: "Ora dichiarata") + ": \(t.formatted())") }
            lines.append("   " + String(localized: "Revoca") + ": \(revocationText(s.revocation))")
            for p in s.problems { lines.append("   ! \(p)") }
        }
        if let t = doc.trustedList { lines.append(""); lines.append("Trusted list \(t["country"] ?? "") #\(t["sequence"] ?? ""), SHA-256 \(t["sha256"] ?? "")") }
        return lines.joined(separator: "\n")
    }
}
