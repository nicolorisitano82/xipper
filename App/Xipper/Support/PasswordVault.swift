import Foundation
import LocalAuthentication
import Security

/// Archive passwords remembered in the login Keychain (4.2), one per archive path.
/// Using one asks for Touch ID (or the Mac password) first, unless turned off in Settings.
enum PasswordVault {
    private static let service = "app.xipper.archive-password"

    /// The real path, so /tmp and /private/tmp (or a symlinked folder) give the same entry.
    private static func account(_ archive: URL) -> String {
        guard let p = realpath(archive.path, nil) else { return archive.standardizedFileURL.path }
        defer { free(p) }
        return String(cString: p)
    }

    private static func query(_ archive: URL?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let archive { q[kSecAttrAccount as String] = account(archive) }
        return q
    }

    /// Whether a password is stored for the archive (no prompt).
    static func has(_ archive: URL) -> Bool {
        var q = query(archive)
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    static func save(_ password: String, for archive: URL) {
        SecItemDelete(query(archive) as CFDictionary)
        var add = query(archive)
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrLabel as String] = "Xipper: \(archive.lastPathComponent)"
        add[kSecAttrDescription as String] = String(localized: "Password di archivio")
        SecItemAdd(add as CFDictionary, nil)
    }

    static func remove(for archive: URL) {
        SecItemDelete(query(archive) as CFDictionary)
    }

    /// Number of stored passwords, for Settings.
    static var count: Int {
        var q = query(nil)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return 0 }
        return (out as? [[String: Any]])?.count ?? 0
    }

    static func removeAll() {
        while SecItemDelete(query(nil) as CFDictionary) == errSecSuccess {}
    }

    /// The stored password, after Touch ID / the Mac password when required.
    /// nil if none is stored or the user cancelled.
    static func password(for archive: URL) async -> String? {
        guard has(archive) else { return nil }
        if Preferences.defaults.bool(forKey: PrefKey.vaultRequiresAuth) {
            let context = LAContext()
            context.localizedCancelTitle = String(localized: "Inserisci a mano")
            do {
                guard try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                       localizedReason: String(localized: "usare la password salvata di \(archive.lastPathComponent)")) else { return nil }
            } catch {
                return nil
            }
        }
        var q = query(archive)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
