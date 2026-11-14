import AppKit
import Security
import SwiftUI
import XipperKit

/// Signing a document as `.p7m` (3.3): CAdES-BES with a certificate from the Keychain or a smart card,
/// CAdES-T with a time-stamp authority; for a `.p7m`, a parallel or a nested signature.
struct SignDocumentView: View {
    let url: URL
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    struct Candidate: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let forSigning: Bool
        let qualified: Bool
        let expired: Bool
        let issuer: String
    }

    @State private var candidates: [Candidate] = []
    @State private var showAll = false
    @AppStorage(PrefKey.signingCertificate) private var certificate = ""
    @State private var nested = false
    @State private var useTimestamp = false
    @AppStorage(PrefKey.signingTSA) private var tsaURL = ""
    @AppStorage(PrefKey.signingTSAUser) private var tsaUser = ""
    @State private var tsaPassword = ""
    @State private var working = false
    @State private var error: String?

    private var isP7M: Bool { ["p7m", "p7s"].contains(url.pathExtension.lowercased()) }
    private var shown: [Candidate] { showAll ? candidates : candidates.filter(\.forSigning) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Documento", value: url.lastPathComponent)
                if isP7M {
                    Picker("Tipo di firma", selection: $nested) {
                        Text("Parallela (accanto alle altre)").tag(false)
                        Text("A matrioska (sopra le altre)").tag(true)
                    }
                    .help("Parallela: un'altra firma sullo stesso documento. A matrioska: firmi il .p7m intero, come una controfirma.")
                }
            }
            Section("Certificato") {
                if shown.isEmpty {
                    Text(candidates.isEmpty
                         ? "Nessun certificato di firma: inserisci la smart card o il token, o importa il certificato nel Portachiavi."
                         : "Nessun certificato per la firma di documenti.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("Firma con", selection: $certificate) {
                        ForEach(shown) { c in
                            Text(c.name + (c.qualified ? String(localized: " — qualificato") : "") + (c.expired ? String(localized: " — scaduto") : ""))
                                .tag(c.name)
                        }
                    }
                    if let c = candidates.first(where: { $0.name == certificate }) {
                        LabeledContent("Emesso da", value: c.issuer).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Toggle("Mostra tutti i certificati", isOn: $showAll)
                    Spacer()
                    Button("Aggiorna", systemImage: "arrow.clockwise") { loadCandidates() }
                        .labelStyle(.iconOnly)
                        .help("Rileggi i certificati (dopo aver inserito la smart card)")
                }
            }
            Section {
                Toggle("Marca temporale", isOn: $useTimestamp)
                    .help("Una marca temporale prova quando hai firmato (CAdES-T), anche dopo la scadenza del certificato")
                if useTimestamp {
                    TextField("Servizio (URL)", text: $tsaURL, prompt: Text(verbatim: "https://…"))
                    TextField("Utente", text: $tsaUser, prompt: Text("solo se il servizio lo chiede"))
                    if !tsaUser.isEmpty { SecureField("Password", text: $tsaPassword) }
                }
            } footer: {
                Text("Le marche temporali qualificate richiedono un account presso il prestatore (per esempio quello della tua firma). La password non viene salvata.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle("Firma digitale")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(working ? "Firma in corso…" : "Firma documento") { sign() }
                    .disabled(working || !shown.contains { $0.name == certificate } || (useTimestamp && URL(string: tsaURL)?.scheme?.hasPrefix("http") != true))
            }
        }
        .onAppear(perform: loadCandidates)
    }

    /// The signing certificates: read from the certificates only, no private key touched.
    private func loadCandidates() {
        candidates = XizCertificateSigner.identities().map { id in
            var c: SecCertificate?
            SecIdentityCopyCertificate(id.identity, &c)
            let cert = c.flatMap { try? SignerCertificate(der: Array(SecCertificateCopyData($0) as Data)) }
            return Candidate(name: id.name, forSigning: cert?.nonRepudiation == true, qualified: cert?.qcCompliance == true,
                             expired: cert.map { !$0.isValid(at: Date()) } ?? false, issuer: cert?.issuer.display ?? "")
        }
        .sorted { ($0.qualified ? 0 : $0.forSigning ? 1 : 2, $0.name) < ($1.qualified ? 0 : $1.forSigning ? 1 : 2, $1.name) }
        if !shown.contains(where: { $0.name == certificate }) { certificate = shown.first?.name ?? "" }
    }

    private func sign() {
        guard XizCertificateSigner.identity(named: certificate) != nil else { error = String(localized: "Certificato non trovato"); return }
        let name = certificate
        let mode: DocumentSignatureMode = isP7M ? (nested ? .nested : .parallel) : .new
        var output: URL? = nil
        if mode != .parallel {
            let proposed = url.appendingPathExtension("p7m")
            if FileManager.default.fileExists(atPath: proposed.path) {
                let panel = NSSavePanel()
                panel.directoryURL = url.deletingLastPathComponent()
                panel.nameFieldStringValue = proposed.lastPathComponent
                guard panel.runModal() == .OK, let dest = panel.url else { return }
                output = dest
            }
        }
        var timestamp: TimestampSource?
        if useTimestamp, let u = URL(string: tsaURL) {
            timestamp = .authority(u, credentials: tsaUser.isEmpty ? nil : (tsaUser, tsaPassword))
        }
        working = true
        error = nil
        let url = url, out = output, stamp = timestamp
        Task {
            let result = await Task.detached { () -> Result<URL, Error> in
                // The card may ask for its PIN here (a system dialog).
                Result {
                    guard let identity = XizCertificateSigner.identity(named: name) else { throw XipperError.invalidArgument("no certificate \(name)") }
                    return try Xipper.signDocument(url, output: out, mode: mode, signer: try XizCertificateSigner(identity: identity),
                                                   timestamp: stamp, overwrite: out != nil)
                }
            }.value
            working = false
            switch result {
            case let .success(out):
                tsaPassword = ""
                openWindow(id: "signed", value: out)
                dismiss()
            case let .failure(e): error = e.localizedDescription
            }
        }
    }
}
