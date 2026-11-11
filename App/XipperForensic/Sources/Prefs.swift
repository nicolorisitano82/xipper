import AppKit
import ForensicKit
import Foundation
import Security
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
    /// An account at the authority (qualified ones want it); the password is in the Keychain.
    var timestampUser: String { didSet { d.set(timestampUser, forKey: "timestampUser") } }
    /// A certificate identity (Keychain or smart card) that signs instead of the Xipper key; empty: none.
    var certificateName: String { didSet { d.set(certificateName, forKey: "certificateName") } }
    /// EU trusted list to check time-stamps against (e.g. "IT"); empty: no check (no network for it).
    var trustedListCountry: String { didSet { d.set(trustedListCountry, forKey: "trustedListCountry") } }

    private init() {
        examiner = d.string(forKey: "examiner") ?? NSFullUserName()
        organization = d.string(forKey: "organization") ?? ""
        keyName = d.string(forKey: "signingKey") ?? ""
        let preferred = Locale.preferredLanguages.first ?? "it"
        reportLanguage = ForensicPDF.Language(rawValue: d.string(forKey: "reportLanguage") ?? "") ?? (preferred.hasPrefix("it") ? .it : .en)
        timestampURL = d.string(forKey: "timestampURL") ?? ""
        timestampUser = d.string(forKey: "timestampUser") ?? ""
        certificateName = d.string(forKey: "certificateName") ?? ""
        trustedListCountry = d.string(forKey: "trustedListCountry") ?? ""
        keys = XizKeychain.list(.signing)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Prefs.shared.reloadKeys() }
        }
    }

    /// Signing keys in the Keychain; refreshed on demand (the Keychain does not notify).
    private(set) var keys: [XizKeychain.Item] = []

    func reloadKeys() { keys = XizKeychain.list(.signing) }

    var ready: Bool {
        !examiner.trimmingCharacters(in: .whitespaces).isEmpty && (keys.contains { $0.name == keyName } || !certificateName.isEmpty)
    }

    /// Certificate identities, by name, from the certificates only (listing never touches a private key).
    func identityNames() -> [String] { XizCertificateSigner.identities().map(\.name) }

    var publicKey: String? { keys.first { $0.name == keyName }?.publicKey }

    enum Problem: LocalizedError {
        case noKey, badURL, noCertificate(String)
        var errorDescription: String? {
            switch self {
            case .noKey: String(localized: "No signing key: choose or create one in Settings.")
            case .badURL: String(localized: "The time-stamp authority address is not a valid http(s) URL.")
            case .noCertificate(let n): String(format: String(localized: "The certificate “%@” is not available: insert the smart card or choose another in Settings."), n)
            }
        }
    }

    static let tsaService = "app.xipper.forensic.tsa"

    /// The authority's password, in the Keychain under the user name.
    func timestampPassword() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.tsaService,
                                kSecAttrAccount as String: timestampUser, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    func setTimestampPassword(_ p: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.tsaService,
                                kSecAttrAccount as String: timestampUser]
        SecItemDelete(q as CFDictionary)
        guard !p.isEmpty else { return }
        var a = q
        a[kSecValueData as String] = Data(p.utf8)
        SecItemAdd(a as CFDictionary, nil)
    }

    /// The trusted list, when the check is on (fetched once a day, cached).
    func trustedList() throws -> TrustedList? {
        trustedListCountry.isEmpty ? nil : try TrustedList.load(country: trustedListCountry)
    }

    /// Reads the key from the Keychain (macOS may ask for the login password).
    func signer() throws -> XizSigner {
        var certificate: XizCertificateSigner?
        if !certificateName.isEmpty {
            guard let id = XizCertificateSigner.identity(named: certificateName) else { throw Problem.noCertificate(certificateName) }
            certificate = try XizCertificateSigner(identity: id)
        }
        let key: XizSigningKey
        if !keyName.isEmpty, let text = XizKeychain.secret(.signing, name: keyName) {
            key = try XizSigningKey(secretText: text)
        } else if certificate != nil {
            key = XizSigningKey()  // unused: the certificate signs
        } else {
            throw Problem.noKey
        }
        var url: URL?
        let t = timestampURL.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty {
            guard let u = URL(string: t), u.scheme == "https" || u.scheme == "http" else { throw Problem.badURL }
            url = u
        }
        var s = XizSigner(key: key, label: examiner, timestampURL: url, certificate: certificate)
        if !timestampUser.isEmpty, let p = timestampPassword() { s.timestampCredentials = (timestampUser, p) }
        return s
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
    @State private var tsaPassword = ""

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
            CertificateSection()
            Section("Reports") {
                Picker("Language of printed reports", selection: $p.reportLanguage) {
                    Text("Italian").tag(ForensicPDF.Language.it)
                    Text("English").tag(ForensicPDF.Language.en)
                }
                TextField("Time-stamp authority (RFC 3161)", text: $p.timestampURL, prompt: Text("empty: offline"))
                if !prefs.timestampURL.isEmpty {
                    TextField("Account (if the authority wants one)", text: $p.timestampUser)
                    if !prefs.timestampUser.isEmpty {
                        SecureField("Password (kept in the Keychain)", text: $tsaPassword)
                            .onSubmit { prefs.setTimestampPassword(tsaPassword); tsaPassword = "" }
                        Text(prefs.timestampPassword() == nil ? "No password saved: type it and press Return." : "Password saved in the Keychain.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker("Check time-stamps against the EU trusted list", selection: $p.trustedListCountry) {
                    Text("No").tag("")
                    Text("Italy (AgID)").tag("IT")
                }
                Text("Offline mode: with no authority, nothing goes on the network; the report says so. The trusted list, when chosen, is downloaded once a day to say whether each time-stamp is qualified (eIDAS).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HelperSection()
            if let error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .onAppear { prefs.reloadKeys() }
        .frame(width: 520)
        .padding(.vertical, 8)
    }
}

/// The disk helper: a root LaunchDaemon that only opens disks read-only for this app. Two approvals,
/// both the user's: allow it in Login Items, then give it Full Disk Access (needed for internal disks).
struct HelperSection: View {
    @State private var status = DeviceAccess.helperStatus
    @State private var error: String?

    var body: some View {
        Section {
            LabeledContent("Disk helper") {
                switch status {
                case .enabled: Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .requiresApproval: Label("Waiting for approval", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .notInstalled: Label("Not installed", systemImage: "minus.circle").foregroundStyle(.secondary)
                case .unavailable: Label("Not available in this build", systemImage: "xmark.octagon").foregroundStyle(.secondary)
                }
            }
            HStack {
                switch status {
                case .notInstalled, .unavailable:
                    Button("Install…") {
                        do { try DeviceAccess.installHelper() } catch { self.error = error.localizedDescription }
                        status = DeviceAccess.helperStatus
                        if status == .requiresApproval { DeviceAccess.openLoginItems() }
                    }
                case .requiresApproval:
                    Button("Open Login Items…") { DeviceAccess.openLoginItems() }
                case .enabled:
                    Button("Open Full Disk Access…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    Button("Remove") {
                        do { try DeviceAccess.removeHelper() } catch { self.error = error.localizedDescription }
                        status = DeviceAccess.helperStatus
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
        } header: { Text("Disks") } footer: {
            Text("Disks belong to the system. The helper runs as root and does only one thing: it opens a disk read-only and hands it to Xipper Forensic; it never writes. macOS asks you to allow it in Login Items; for internal disks also give “xipper-forensic-helper” Full Disk Access.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { status = DeviceAccess.helperStatus }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in status = DeviceAccess.helperStatus }
    }
}


/// Signing with a certificate (smart card, Keychain, Secure Enclave) instead of the Xipper key: the
/// signature then names a person through their certificate authority.
struct CertificateSection: View {
    @Environment(Prefs.self) private var prefs
    @State private var names: [String] = []
    @State private var check: String?

    var body: some View {
        @Bindable var p = prefs
        Section {
            Picker("Sign with", selection: $p.certificateName) {
                Text("The Xipper key above").tag("")
                ForEach(names, id: \.self) { Text($0).tag($0) }
                if !prefs.certificateName.isEmpty && !names.contains(prefs.certificateName) {
                    Text(prefs.certificateName + " " + String(localized: "(not available now)")).tag(prefs.certificateName)
                }
            }
            if !prefs.certificateName.isEmpty {
                HStack {
                    Button("Try the Certificate") {
                        do {
                            let s = try prefs.signer()
                            check = String(format: String(localized: "Works: %@ (%@)"), s.certificate?.subject ?? "", s.certificate?.algorithm == 2 ? "ECDSA P-256" : "RSA")
                        } catch { check = error.localizedDescription }
                    }
                    if let check { Text(check).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Button("Refresh") { names = prefs.identityNames() }
        } header: { Text("Certificate") } footer: {
            Text("Certificates with a private key from the Keychain or an inserted smart card (PIV; other cards need their maker's driver). ECDSA P-256 or RSA. The card asks for its PIN when signing.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { names = prefs.identityNames() }
    }
}
