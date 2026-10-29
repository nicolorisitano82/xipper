import Foundation
import LocalAuthentication
import XipperKit

/// XIZ identities and signing keys in the Keychain (XizKeychain), with the same Touch ID gate as
/// archive passwords (4.2): a secret is read only after the Mac's owner confirms, unless turned off
/// in Settings. Unlocked identities stay in `XizCredentials.shared` for the session.
@MainActor
enum KeyVault {
    /// The signing key used by default to sign new XIZ archives and their changes ("" = none).
    static var defaultSigningKey: String {
        get { Preferences.defaults.string(forKey: PrefKey.xizSigningKey) ?? "" }
        set { Preferences.defaults.set(newValue, forKey: PrefKey.xizSigningKey) }
    }

    /// The name shown in signed histories (default: the user's full name).
    static var signerName: String {
        get { Preferences.defaults.string(forKey: PrefKey.xizSignerName).flatMap { $0.isEmpty ? nil : $0 } ?? NSFullUserName() }
        set { Preferences.defaults.set(newValue, forKey: PrefKey.xizSignerName) }
    }

    /// RFC 3161 authority for time-stamps (nil: none, no network).
    static var timestampURL: URL? {
        get { Preferences.defaults.string(forKey: PrefKey.xizTimestampURL).flatMap { $0.isEmpty ? nil : URL(string: $0) } }
        set { Preferences.defaults.set(newValue?.absoluteString ?? "", forKey: PrefKey.xizTimestampURL) }
    }

    /// Identities already unlocked this session (names).
    private static var unlocked = Set<String>()

    /// Asks Touch ID / the Mac password when Settings require it.
    static func authorize(_ reason: String) async -> Bool {
        guard Preferences.defaults.bool(forKey: PrefKey.vaultRequiresAuth) else { return true }
        let context = LAContext()
        do { return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) } catch { return false }
    }

    /// Loads the identities that can open `archive` (all of them if `archive` is nil) into the
    /// credentials XIZ tries. Returns whether any new one was loaded.
    @discardableResult
    static func unlockIdentities(for archive: URL?) async -> Bool {
        var items = XizKeychain.list(.identity).filter { !unlocked.contains($0.name) }
        if let archive, let info = try? Xipper.xizInfo(archive) {
            items = items.filter { info.matches(publicKeys: [$0.publicKey]) }
        }
        guard !items.isEmpty else { return false }
        let name = archive?.lastPathComponent ?? ""
        guard await authorize(String(localized: "usare le tue chiavi per aprire \(name)")) else { return false }
        var loaded = false
        for item in items {
            if let text = XizKeychain.secret(.identity, name: item.name), let id = try? XizIdentity(secretText: text) {
                XizCredentials.shared.add(identity: id)
                unlocked.insert(item.name)
                loaded = true
            }
        }
        return loaded
    }

    /// The default signer, after Touch ID; nil when no signing key is set or the user cancels.
    static func defaultSigner() async -> XizSigner? {
        let name = defaultSigningKey
        guard !name.isEmpty else { return nil }
        return await signer(named: name)
    }

    static func signer(named name: String) async -> XizSigner? {
        guard await authorize(String(localized: "firmare con la chiave «\(name)»")),
              let text = XizKeychain.secret(.signing, name: name), let key = try? XizSigningKey(secretText: text) else { return nil }
        return XizSigner(key: key, label: signerName, timestampURL: timestampURL)
    }

    /// The secret of a key, to export it (after Touch ID).
    static func exportSecret(_ kind: XizKeychain.Kind, name: String) async -> String? {
        guard await authorize(String(localized: "esportare la chiave «\(name)»")) else { return nil }
        guard let text = XizKeychain.secret(kind, name: name) else { return nil }
        if kind == .identity, let i = try? XizIdentity(secretText: text) { return i.fileText }
        if kind == .signing, let k = try? XizSigningKey(secretText: text) { return k.fileText }
        return nil
    }
}
