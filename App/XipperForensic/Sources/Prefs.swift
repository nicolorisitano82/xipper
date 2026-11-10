import AppKit
import ForensicKit
import Foundation
import SwiftUI
import XipperKit

/// The operator and their signing key: every segment, log line and report is signed with it.
/// The key lives in the Keychain (XizKeychain, the same items as `xipper keygen --signing --keychain`).
@MainActor @Observable
final class Prefs {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    var examiner: String { didSet { d.set(examiner, forKey: "examiner") } }
    var organization: String { didSet { d.set(organization, forKey: "organization") } }
    var keyName: String { didSet { d.set(keyName, forKey: "signingKey") } }
    var reportLanguage: ForensicPDF.Language { didSet { d.set(reportLanguage.rawValue, forKey: "reportLanguage") } }
    /// An RFC 3161 authority; empty is offline mode (no network at all, declared in the report).
    var timestampURL: String { didSet { d.set(timestampURL, forKey: "timestampURL") } }

    private init() {
        examiner = d.string(forKey: "examiner") ?? NSFullUserName()
        organization = d.string(forKey: "organization") ?? ""
        keyName = d.string(forKey: "signingKey") ?? ""
        let preferred = Locale.preferredLanguages.first ?? "it"
        reportLanguage = ForensicPDF.Language(rawValue: d.string(forKey: "reportLanguage") ?? "") ?? (preferred.hasPrefix("it") ? .it : .en)
        timestampURL = d.string(forKey: "timestampURL") ?? ""
        keys = XizKeychain.list(.signing)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Prefs.shared.reloadKeys() }
        }
    }

    /// Signing keys in the Keychain; refreshed on demand (the Keychain does not notify).
    private(set) var keys: [XizKeychain.Item] = []

    func reloadKeys() { keys = XizKeychain.list(.signing) }

    var ready: Bool { !examiner.trimmingCharacters(in: .whitespaces).isEmpty && keys.contains { $0.name == keyName } }

    var publicKey: String? { keys.first { $0.name == keyName }?.publicKey }

    enum Problem: LocalizedError {
        case noKey, badURL
        var errorDescription: String? {
            switch self {
            case .noKey: String(localized: "No signing key: choose or create one in Settings.")
            case .badURL: String(localized: "The time-stamp authority address is not a valid http(s) URL.")
            }
        }
    }

    /// Reads the key from the Keychain (macOS may ask for the login password).
    func signer() throws -> XizSigner {
        guard !keyName.isEmpty, let text = XizKeychain.secret(.signing, name: keyName) else { throw Problem.noKey }
        let key = try XizSigningKey(secretText: text)
        var url: URL?
        let t = timestampURL.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty {
            guard let u = URL(string: t), u.scheme == "https" || u.scheme == "http" else { throw Problem.badURL }
            url = u
        }
        return XizSigner(key: key, label: examiner, timestampURL: url)
    }

    func createKey(named name: String) throws {
        _ = try XizKeychain.generate(.signing, name: name)
        reloadKeys()
        keyName = name
    }
}

struct SettingsView: View {
    @Environment(Prefs.self) private var prefs
    @State private var newKey = ""
    @State private var error: String?

    var body: some View {
        @Bindable var p = prefs
        Form {
            Section("Operator") {
                TextField("Name", text: $p.examiner)
                TextField("Organization", text: $p.organization)
            }
            Section("Signing key") {
                Picker("Key", selection: $p.keyName) {
                    Text("None").tag("")
                    ForEach(prefs.keys) { k in Text(k.name).tag(k.name) }
                }
                if let pk = prefs.publicKey {
                    Text(pk).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                HStack {
                    TextField("New key name", text: $newKey)
                    Button("Create") {
                        do { try prefs.createKey(named: newKey.trimmingCharacters(in: .whitespaces)); newKey = "" } catch { self.error = error.localizedDescription }
                    }
                    .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Every archive segment, case log line and report is signed with this key. Give the public key to whoever has to check your signatures.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Reports") {
                Picker("Language of printed reports", selection: $p.reportLanguage) {
                    Text("Italian").tag(ForensicPDF.Language.it)
                    Text("English").tag(ForensicPDF.Language.en)
                }
                TextField("Time-stamp authority (RFC 3161)", text: $p.timestampURL, prompt: Text("empty: offline"))
                Text("Offline mode: with no authority, nothing goes on the network; the report says so.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .onAppear { prefs.reloadKeys() }
        .frame(width: 520)
        .padding(.vertical, 8)
    }
}
