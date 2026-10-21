import SwiftUI

/// Password entry (system sheet: already glass, no custom glass inside).
struct PasswordSheet: View {
    enum Mode { case create, open(wrong: Bool) }

    let mode: Mode
    let archiveName: String
    let onDone: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""

    private var isCreate: Bool { if case .create = mode { true } else { false } }
    private var nonASCII: Bool { password.unicodeScalars.contains { !$0.isASCII } }
    private var valid: Bool { !password.isEmpty && (!isCreate || password == confirm) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(isCreate ? "Proteggi con password" : "Password richiesta", systemImage: "lock.fill")
                .font(.title2.weight(.semibold))
            Text(isCreate ? "\(archiveName) sarà cifrato con AES-256. Senza la password nessuno potrà aprirlo, nemmeno tu."
                          : "\(archiveName) è protetto. Inserisci la password per continuare.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if case .open(wrong: true) = mode {
                Label("Password errata, riprova.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            Form {
                SecureField("Password", text: $password)
                if isCreate {
                    SecureField("Ripeti password", text: $confirm)
                    StrengthMeter(password: password)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            if isCreate && nonASCII {
                Label("Le password con caratteri accentati o speciali non si possono inserire in 7-Zip.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if isCreate && !confirm.isEmpty && password != confirm {
                Text("Le password non coincidono.").font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Annulla", role: .cancel) { onDone(nil); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isCreate ? "Usa password" : "Apri") { onDone(password); dismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
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
