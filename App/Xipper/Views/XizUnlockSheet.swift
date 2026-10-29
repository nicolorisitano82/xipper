import SwiftUI
import XipperKit

/// Opening an XIZ 1.3 archive: who can open it, one or more passwords (custodians each type
/// theirs), or the identities in the Keychain.
struct XizUnlockSheet: View {
    let model: ArchiveModel
    let onUnlock: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var passwords = [""]

    private var info: XizArchiveInfo? { model.xizInfo }
    private var myKeys: Bool {
        info?.matches(publicKeys: XizKeychain.list(.identity).map(\.publicKey)) ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Sblocca \(model.url.lastPathComponent)", systemImage: "lock.fill")
                .font(.title2.weight(.semibold))
            if let message = model.unlockMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if let info, !info.recipients.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Può aprirlo:").font(.headline)
                    ForEach(Array(info.recipients.enumerated()), id: \.offset) { _, r in
                        Label(describe(r), systemImage: symbol(r))
                            .padding(.leading, indent(r) ? 18 : 0)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(passwords.indices, id: \.self) { i in
                    SecureField(i == 0 ? String(localized: "Password") : String(localized: "Password di un altro custode"), text: $passwords[i])
                }
                if info?.needsCustodians == true {
                    Button("Aggiungi la password di un altro custode", systemImage: "plus") { passwords.append("") }
                        .buttonStyle(.borderless)
                    Text("Per le cartelle custodite, ogni custode inserisce la propria password su questo Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                Button("Annulla", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                if myKeys {
                    Button("Usa le mie chiavi", systemImage: "key") {
                        Task {
                            await KeyVault.unlockIdentities(for: model.url)
                            dismiss()
                            onUnlock(passwords.filter { !$0.isEmpty })
                        }
                    }
                }
                Spacer()
                Button("Apri") {
                    dismiss()
                    onUnlock(passwords.filter { !$0.isEmpty })
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(passwords.allSatisfy(\.isEmpty))
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func describe(_ r: XizRecipientInfo) -> String {
        let name = r.label.isEmpty ? String(localized: "senza nome") : r.label
        switch r.kind {
        case .password: return String(localized: "\(name) · password")
        case .publicKey: return String(localized: "\(name) · chiave pubblica")
        case let .threshold(k, n): return String(localized: "\(name) · \(k) custodi su \(n) insieme")
        case let .custodian(_, id): return id == nil ? String(localized: "\(name) · password") : String(localized: "\(name) · chiave pubblica")
        }
    }

    private func symbol(_ r: XizRecipientInfo) -> String {
        switch r.kind {
        case .password: "key.horizontal"
        case .publicKey: "person.crop.circle.badge.checkmark"
        case .threshold: "person.3"
        case .custodian: "person"
        }
    }

    private func indent(_ r: XizRecipientInfo) -> Bool { if case .custodian = r.kind { true } else { false } }
}
