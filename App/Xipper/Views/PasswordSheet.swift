import SwiftUI

/// Password entry (system sheet: already glass, no custom glass inside).
struct PasswordSheet: View {
    enum Mode { case create, open(wrong: Bool) }

    let mode: Mode
    let archiveName: String
    /// The password (nil if cancelled) and whether to remember it in the Keychain.
    let onDone: (String?, _ remember: Bool) -> Void
    /// ZIP creation only: AES-256 (false) or ZipCrypto (true), offered with a warning (UI_SPEC 2.7).
    var legacyZipCrypto: Binding<Bool>?
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    @AppStorage("rememberArchivePasswords") private var remember = false

    private var isCreate: Bool { if case .create = mode { true } else { false } }
    private var nonASCII: Bool { password.unicodeScalars.contains { !$0.isASCII } }
    private var valid: Bool { !password.isEmpty && (!isCreate || password == confirm) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(isCreate ? String(localized: "Proteggi con password") : String(localized: "Password richiesta"), systemImage: "lock.fill")
                .font(.title2.weight(.semibold))
            Text(isCreate ? (legacyZipCrypto?.wrappedValue == true
                             ? String(localized: "\(archiveName) sarà cifrato con ZipCrypto. Senza la password nessuno potrà aprirlo, nemmeno tu.")
                             : String(localized: "\(archiveName) sarà cifrato con AES-256. Senza la password nessuno potrà aprirlo, nemmeno tu."))
                          : String(localized: "\(archiveName) è protetto. Inserisci la password per continuare."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if case .open(wrong: true) = mode {
                Label("Password errata, riprova.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 8) {
                SecureField("Password", text: $password)
                if isCreate {
                    SecureField("Ripeti password", text: $confirm)
                    StrengthMeter(password: password)
                }
            }
            .textFieldStyle(.roundedBorder)
            if isCreate, let legacyZipCrypto {
                Picker("Cifratura", selection: legacyZipCrypto) {
                    Text("AES-256 (consigliata)").tag(false)
                    Text("ZipCrypto (compatibilità)").tag(true)
                }
                if legacyZipCrypto.wrappedValue {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("ZipCrypto è una cifratura debole", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline).foregroundStyle(.orange)
                        Text("Chi possiede anche uno solo dei file in chiaro (per esempio un PDF già inviato per email) può ricavare la chiave e aprire tutto l'archivio in pochi minuti.")
                        Text("Usalo solo se chi riceve ha un programma che non supporta AES. 7-Zip, WinRAR, Keka e Xipper aprono gli archivi AES-256.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
                }
            }
            Toggle("Ricorda nel Portachiavi (sblocco con Touch ID)", isOn: $remember)
            if isCreate && nonASCII {
                Label("Le password con caratteri accentati o speciali non si possono inserire in 7-Zip.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if isCreate && !confirm.isEmpty && password != confirm {
                Text("Le password non coincidono.").font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button("Annulla", role: .cancel) { onDone(nil, false); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isCreate, let legacyZipCrypto, legacyZipCrypto.wrappedValue {
                    Button("Usa ZipCrypto") { onDone(password, remember); dismiss() }
                        .buttonStyle(.glass)
                        .disabled(!valid)
                    Button("Usa AES-256") { legacyZipCrypto.wrappedValue = false; onDone(password, remember); dismiss() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!valid)
                } else {
                    Button(isCreate ? String(localized: "Usa password") : String(localized: "Apri")) { onDone(password, remember); dismiss() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!valid)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

/// Rough strength estimate: length and character classes (no network, no dictionary).
private struct StrengthMeter: View {
    let password: String

    private var score: Int {
        guard !password.isEmpty else { return 0 }
        var classes = 0
        if password.contains(where: \.isLowercase) { classes += 1 }
        if password.contains(where: \.isUppercase) { classes += 1 }
        if password.contains(where: \.isNumber) { classes += 1 }
        if password.contains(where: { !$0.isLetter && !$0.isNumber }) { classes += 1 }
        let bits = Double(password.count) * log2(Double([0, 26, 52, 62, 94][classes]))
        return bits < 40 ? 1 : bits < 60 ? 2 : bits < 80 ? 3 : 4
    }

    var body: some View {
        LabeledContent("Robustezza") {
            HStack(spacing: 4) {
                ForEach(1...4, id: \.self) { i in
                    Capsule().fill(i <= score ? color : Color.secondary.opacity(0.2)).frame(width: 34, height: 6)
                }
                Text(["", "Debole", "Discreta", "Buona", "Ottima"][score]).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var color: Color { [.clear, .red, .orange, .yellow, .green][score] }
}
