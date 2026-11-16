import SwiftUI
import XipperKit

/// Password entry (system sheet: already glass, no custom glass inside).
struct PasswordSheet: View {
    enum Mode { case create, open(wrong: Bool) }

    let mode: Mode
    let archiveName: String
    /// The password (nil if cancelled) and whether to remember it in the Keychain.
    let onDone: (String?, _ remember: Bool) -> Void
    /// ZIP creation only: AES-256 (false) or ZipCrypto (true), offered with a warning (UI_SPEC 2.7).
    var legacyZipCrypto: Binding<Bool>?
    /// XIZ creation: bind the password to a key file (XIZ 1.14 second factor).
    var factorChoice: Binding<Bool>?
    /// XIZ creation: the strong key derivation profile (3.5).
    var strongKDF: Binding<Bool>?
    /// Apple Archive (AEA) needs at least 20 characters.
    var minimumLength = 1
    /// Opening: the archive, to tell whether it also needs a key file (factor).
    var archiveURL: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    /// Shown while the fields still hold it: a generated password must be seen to be kept.
    @State private var generated: String?
    @State private var confirmWeak = false
    @State private var factorTick = 0
    @AppStorage("rememberArchivePasswords") private var remember = false

    private var isCreate: Bool { if case .create = mode { true } else { false } }
    private var nonASCII: Bool { password.unicodeScalars.contains { !$0.isASCII } }
    private var valid: Bool {
        !password.isEmpty && password.utf8.count >= minimumLength && (!isCreate || password == confirm) && !factorMissing
    }

    private var factorOn: Bool { factorChoice?.wrappedValue == true }

    /// Opening an archive whose password is bound to a key file not given yet.
    private var factorMissing: Bool {
        _ = factorTick
        guard !isCreate, let archiveURL else { return false }
        let ids = XizFactor.required(by: archiveURL)
        return !ids.isEmpty && !ids.contains(where: XizCredentials.shared.hasFactor(id:))
    }


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
            if !isCreate, let archiveURL { FactorPicker(archive: archiveURL, onChange: { factorTick += 1 }) }
            if case .open(wrong: true) = mode {
                Label("Password errata, riprova.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 8) {
                SecureField("Password", text: $password)
                if isCreate {
                    SecureField("Ripeti password", text: $confirm)
                    StrengthMeter(strength: strength)
                }
            }
            .textFieldStyle(.roundedBorder)
            if isCreate {
                if let generated, generated == password, generated == confirm {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(generated).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Button("Copia") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(generated, forType: .string)
                            }
                        }
                        Text("Conservala o salvala nel Portachiavi: senza di lei l'archivio non si apre.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))
                } else {
                    Menu("Genera password sicura", systemImage: "wand.and.stars") {
                        if Passphrase.wordList(.italian) != nil {
                            Button("Frase di 6 parole italiane") { use(Passphrase.generate(language: .italian)) }
                        }
                        if Passphrase.wordList(.english) != nil {
                            Button("Frase di 6 parole inglesi") { use(Passphrase.generate(language: .english)) }
                        }
                        Button("Caratteri casuali") { use(Self.generatePassword()) }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            if isCreate, let factorChoice {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Richiedi anche un file chiave", isOn: factorChoice)
                    Text("L'archivio si aprirà solo con la password e con un file che salverai a parte: chi ruba l'archivio non può provare password.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if isCreate, let strongKDF, XizKDFProfile.strongIsAvailable {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Protezione più lenta da forzare", isOn: strongKDF)
                    Text("Ogni tentativo costa circa 1 secondo e 1 GB di memoria, anche a chi apre l'archivio. Aiuta poco: una buona password conta molto di più.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
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
            if isCreate && minimumLength > 1 && password.utf8.count < minimumLength {
                Text("Gli Apple Archive cifrati richiedono almeno \(minimumLength) caratteri.")
                    .font(.callout).foregroundStyle(.secondary)
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
                    Button(isCreate ? String(localized: "Usa password") : String(localized: "Apri")) {
                        if isCreate && strength.isWeak && !factorOn { confirmWeak = true } else { onDone(password, remember); dismiss() }
                    }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!valid)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .alert("Password debole", isPresented: $confirmWeak) {
            Button("Cambia password", role: .cancel) {}
            Button("Usa comunque", role: .destructive) { onDone(password, remember); dismiss() }
        } message: {
            Text("Chi ha l'archivio può provare password senza limiti: questa si indovina in \(StrengthMeter.duration(strength.crackSeconds)) con 1000 GPU. Una frase di 6 parole resiste per miliardi di anni.")
        }
    }

    private var strength: PasswordStrength {
        PasswordStrength.estimate(password, userWords: [(archiveName as NSString).deletingPathExtension])
    }

    private func use(_ g: String?) {
        guard let g else { return }
        password = g
        confirm = g
        generated = g
    }

    /// Four groups of six characters (about 138 bits) from an alphabet without look-alikes
    /// (0/O, 1/l/I), ASCII only so that 7-Zip and Windows tools accept it.
    static func generatePassword() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var rng = SystemRandomNumberGenerator()
        return (0..<4).map { _ in String((0..<6).map { _ in alphabet.randomElement(using: &rng)! }) }.joined(separator: "-")
    }
}

/// zxcvbn's estimate (XipperKit `PasswordStrength`): guesses an attacker with dictionaries and
/// rules needs, shown as the time 1000 GPUs take against an encrypted XIZ.
private struct StrengthMeter: View {
    let strength: PasswordStrength

    private var score: Int { strength.bits == 0 ? 0 : strength.level.rawValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Robustezza") {
                HStack(spacing: 4) {
                    ForEach(1...4, id: \.self) { i in
                        Capsule().fill(i <= score ? color : Color.secondary.opacity(0.2)).frame(width: 34, height: 6)
                    }
                    Text(["", "Debole", "Discreta", "Buona", "Ottima"][score]).font(.caption).foregroundStyle(.secondary)
                }
            }
            if score > 0 {
                Text("Si indovina in \(Self.duration(strength.crackSeconds)) con 1000 GPU")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var color: Color { [.clear, .red, .orange, .yellow, .green][score] }

    /// "3 giorni", "12 anni", "più di un milione di anni".
    static func duration(_ seconds: Double) -> String {
        let year = 31_557_600.0
        if seconds >= year * 1e6 { return String(localized: "più di un milione di anni") }
        if seconds < 1 { return String(localized: "meno di un secondo") }
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.maximumUnitCount = 1
        f.allowedUnits = seconds >= year ? [.year] : [.day, .hour, .minute, .second]
        if seconds >= year {
            var c = DateComponents()
            c.year = Int((seconds / year).rounded())
            return f.string(from: c) ?? ""
        }
        return f.string(from: seconds) ?? ""
    }
}

/// For an archive whose password is bound to a key file (XIZ 1.14): says so and lets the user
/// choose the `.xizfactor` file; nothing when the archive needs none or it was already given.
struct FactorPicker: View {
    let archive: URL
    var onChange: () -> Void = {}
    @State private var tick = 0
    @State private var failed = false

    private var missing: Bool {
        _ = tick
        let ids = XizFactor.required(by: archive)
        return !ids.isEmpty && !ids.contains(where: XizCredentials.shared.hasFactor(id:))
    }

    var body: some View {
        if missing {
            VStack(alignment: .leading, spacing: 6) {
                Label("Questo archivio si apre con la password e con il suo file chiave.", systemImage: "key.fill")
                Button("Scegli il file chiave…") { choose() }
                if failed { Text("Non è un file chiave di Xipper.").foregroundStyle(.red) }
            }
            .font(.callout)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Scegli il file chiave")
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            XizCredentials.shared.add(factor: try XizFactor(contentsOf: url).bytes)
            failed = false
        } catch {
            failed = true
        }
        tick += 1
        onChange()
    }
}
