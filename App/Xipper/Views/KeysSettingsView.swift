import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XipperKit

/// Settings › Chiavi: XIZ identities (to receive archives) and signing keys, kept in the Keychain.
struct KeysSettings: View {
    @State private var identities = XizKeychain.list(.identity)
    @State private var signingKeys = XizKeychain.list(.signing)
    @State private var defaultKey = KeyVault.defaultSigningKey
    @State private var signerName = KeyVault.signerName
    @State private var timestamp = KeyVault.timestampURL?.absoluteString ?? ""
    @AppStorage(PrefKey.xizSignEdits) private var signEdits = true
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                keyList(identities, kind: .identity)
                HStack {
                    Button("Nuova identità…") { create(.identity) }
                    Button("Importa…") { importKey() }
                }
            } header: {
                Text("Le mie identità")
            } footer: {
                Text("Chi vuole mandarti un archivio XIZ usa la tua chiave pubblica (xizpk1…): solo tu potrai aprire le cartelle destinate a te.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                keyList(signingKeys, kind: .signing)
                HStack {
                    Button("Nuova chiave di firma…") { create(.signing) }
                    Button("Importa…") { importKey() }
                }
                Picker("Firma i nuovi archivi XIZ con", selection: $defaultKey) {
                    Text("Nessuna chiave").tag("")
                    ForEach(signingKeys) { Text($0.name).tag($0.name) }
                }
                .onChange(of: defaultKey) { _, v in KeyVault.defaultSigningKey = v }
                Toggle("Firma anche le modifiche agli archivi firmati", isOn: $signEdits)
                    .disabled(defaultKey.isEmpty)
                TextField("Nome nelle firme", text: $signerName)
                    .onChange(of: signerName) { _, v in KeyVault.signerName = v }
                TextField("Autorità di marca temporale (URL)", text: $timestamp, prompt: Text("nessuna"))
                    .onChange(of: timestamp) { _, v in KeyVault.timestampURL = URL(string: v.trimmingCharacters(in: .whitespaces)) }
            } header: {
                Text("Chiavi di firma")
            } footer: {
                Text("Con una chiave di firma, ogni archivio XIZ e ogni modifica portano la tua firma: chiunque può verificare chi ha cambiato cosa e quando. La marca temporale (RFC 3161) è facoltativa ed è l'unico caso in cui Xipper contatta un server per firmare.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func keyList(_ items: [XizKeychain.Item], kind: XizKeychain.Kind) -> some View {
        if items.isEmpty {
            Text(kind == .identity ? "Nessuna identità." : "Nessuna chiave di firma.").foregroundStyle(.secondary)
        }
        ForEach(items) { item in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                    Text(item.publicKey).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer()
                Button("Copia chiave pubblica", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.publicKey, forType: .string)
                    message = String(localized: "Chiave pubblica di «\(item.name)» copiata.")
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless).help("Copia chiave pubblica")
                Menu {
                    Button("Esporta…") { export(kind, item.name) }
                    Divider()
                    Button("Elimina…", role: .destructive) { delete(kind, item.name) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
    }

    private func reload() {
        identities = XizKeychain.list(.identity)
        signingKeys = XizKeychain.list(.signing)
        if !signingKeys.contains(where: { $0.name == defaultKey }) { defaultKey = "" }
    }

    private func create(_ kind: XizKeychain.Kind) {
        guard let name = KeysSettings.askName(kind == .identity ? String(localized: "Nuova identità") : String(localized: "Nuova chiave di firma"),
                                              default: kind == .identity ? NSFullUserName() : String(localized: "Firma di \(NSFullUserName())")) else { return }
        do {
            try XizKeychain.generate(kind, name: name)
            if kind == .signing && defaultKey.isEmpty { defaultKey = name }
            message = String(localized: "«\(name)» creata nel Portachiavi.")
        } catch {
            message = error.localizedDescription
        }
        reload()
    }

    private func importKey() {
        let panel = NSOpenPanel()
        panel.prompt = String(localized: "Importa")
        panel.message = String(localized: "Scegli un file di chiave XIZ (creato da «xipper keygen» o esportato da Xipper).")
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        guard let name = KeysSettings.askName(String(localized: "Nome della chiave"), default: url.deletingPathExtension().lastPathComponent) else { return }
        do {
            let (kind, _) = try XizKeychain.importKey(fileText: text, name: name)
            message = kind == .identity ? String(localized: "Identità «\(name)» importata.") : String(localized: "Chiave di firma «\(name)» importata.")
        } catch {
            message = String(localized: "Il file non contiene una chiave XIZ.")
        }
        reload()
    }

    private func export(_ kind: XizKeychain.Kind, _ name: String) {
        Task {
            guard let text = await KeyVault.exportSecret(kind, name: name) else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Esportare la chiave segreta «\(name)»?")
            alert.informativeText = String(localized: "Chi ha questo file può aprire gli archivi destinati a te o firmare al posto tuo. Tienilo in un posto sicuro e non mandarlo per email.")
            alert.addButton(withTitle: String(localized: "Esporta"))
            alert.addButton(withTitle: String(localized: "Annulla"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name + ".key"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            guard fd >= 0 else { message = String(localized: "Impossibile scrivere il file."); return }
            _ = text.utf8CString.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count - 1) }
            close(fd)
            message = String(localized: "Chiave esportata in \(url.lastPathComponent).")
        }
    }

    private func delete(_ kind: XizKeychain.Kind, _ name: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Eliminare «\(name)» dal Portachiavi?")
        alert.informativeText = kind == .identity
            ? String(localized: "Senza questa chiave non potrai più aprire le cartelle degli archivi destinati a te, a meno di averne una copia.")
            : String(localized: "Non potrai più firmare con questa chiave; le firme già fatte restano valide.")
        alert.addButton(withTitle: String(localized: "Elimina"))
        alert.addButton(withTitle: String(localized: "Annulla"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        XizKeychain.delete(kind, name: name)
        reload()
    }

    /// A name in a small alert (nil if cancelled or empty).
    static func askName(_ title: String, default value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Annulla"))
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
