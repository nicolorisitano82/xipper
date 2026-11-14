import Foundation
import LocalAuthentication
import Security
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
        if name.hasPrefix(certificatePrefix) { return await certificateSigner(String(name.dropFirst(certificatePrefix.count))) }
        guard await authorize(String(localized: "firmare con la chiave «\(name)»")),
              let text = XizKeychain.secret(.signing, name: name) else { return nil }
        return try? XizSigner(secretText: text, label: signerName, timestampURL: timestampURL)
    }

    /// Choices for signing XIZ archives that are certificates (Keychain, smart cards): `cert:NAME`.
    static let certificatePrefix = "cert:"

    /// Certificates for signing (non-repudiation), read from the certificates only: no private key touched.
    static func signingCertificates() -> [String] {
        XizCertificateSigner.identities().compactMap { id in
            var c: SecCertificate?
            SecIdentityCopyCertificate(id.identity, &c)
            guard let c, let cert = try? SignerCertificate(der: Array(SecCertificateCopyData(c) as Data)),
                  cert.nonRepudiation, cert.isValid(at: Date()) else { return nil }
            return id.name
        }
    }

    /// A signer with a certificate's key (algorithm 2 or 3): the card may ask for its PIN, macOS for
    /// permission to use a Keychain key. The signature is checked with the certificate first.
    private static func certificateSigner(_ name: String) async -> XizSigner? {
        let label = signerName, url = timestampURL
        return await Task.detached { () -> XizSigner? in
            guard let identity = XizCertificateSigner.identity(named: name),
                  let c = try? XizCertificateSigner(identity: identity) else { return nil }
            return XizSigner(key: XizSigningKey(), label: label, timestampURL: url, certificate: c)
        }.value
    }

    /// Apple Archive signs only with an Ed25519 key (its P-256 key is derived from it).
    static func signsAppleArchive(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix(certificatePrefix) else { return false }
        return !(XizKeychain.list(.signing).first { $0.name == name }?.publicKey.hasPrefix(XizEnclaveSigningKey.publicPrefix) ?? false)
    }

    /// Shown in pickers: a certificate as its name with a mark.
    static func displayName(_ choice: String) -> String {
        choice.hasPrefix(certificatePrefix) ? String(localized: "Certificato: \(String(choice.dropFirst(certificatePrefix.count)))") : choice
    }

    /// The secret of a key, to export it (after Touch ID).
    static func exportSecret(_ kind: XizKeychain.Kind, name: String) async -> String? {
        guard await authorize(String(localized: "esportare la chiave «\(name)»")) else { return nil }
        guard let text = XizKeychain.secret(kind, name: name) else { return nil }
        if kind == .identity, let i = try? XizIdentity(secretText: text) { return i.fileText }
        if kind == .signing, let k = try? XizSigningKey(secretText: text) { return k.fileText }
        if kind == .signing, let k = try? XizEnclaveSigningKey(secretText: text) { return k.fileText }
        return nil
    }
}
