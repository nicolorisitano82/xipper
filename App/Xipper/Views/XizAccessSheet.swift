import SwiftUI
import XipperKit

/// What the user sets up in "Accesso e firma" for a new XIZ archive (XIZ 1.3).
struct XizAccessDraft {
    struct Folder: Identifiable {
        let id = UUID()
        var name = ""
        var paths: [String] = []
    }

    enum Kind: String, CaseIterable, Identifiable {
        case password, publicKey
        var id: String { rawValue }
        var title: String { self == .password ? String(localized: "Password") : String(localized: "Chiave pubblica") }
    }

    struct Person: Identifiable {
        let id = UUID()
        var label = ""
        var kind = Kind.password
        var password = ""
        var confirm = ""
        var publicKey = ""
        /// Folder names it opens ("" = everything else); nil = all.
        var folders: Set<String>?
    }

    struct Custodians: Identifiable {
        let id = UUID()
        var label = ""
        var k = 2
        var people: [Person] = [Person(), Person(), Person()]
        var folders: Set<String>?
    }

    var folders: [Folder] = []
    var recipients: [Person] = []
    var custodians: [Custodians] = []
    var erasable = false
    /// Keychain signing key ("" = do not sign).
    var signingKey = UserDefaults.standard.string(forKey: PrefKey.xizSigningKey) ?? ""

    var hasAccess: Bool { !folders.isEmpty || !recipients.isEmpty || !custodians.isEmpty || erasable }
    var isConfigured: Bool { hasAccess || !signingKey.isEmpty }

    /// Folder names offered to recipients: "" (everything else) first.
    var folderNames: [String] { [XizAccess.defaultGroup] + folders.map(\.name).filter { !$0.isEmpty } }

    /// What is still wrong, in the user's words (empty: ready).
    func problems(hasPassword: Bool) -> [String] {
        var out: [String] = []
        let names = folders.map { $0.name.trimmingCharacters(in: .whitespaces) }
        if names.contains("") { out.append(String(localized: "Dai un nome a ogni cartella riservata.")) }
        if Set(names).count != names.count { out.append(String(localized: "Due cartelle riservate hanno lo stesso nome.")) }
        if folders.contains(where: { $0.paths.isEmpty }) { out.append(String(localized: "Scegli almeno una cartella per ogni cartella riservata.")) }
        func check(_ p: Person, _ who: String) {
            switch p.kind {
            case .password:
                if p.password.isEmpty { out.append(String(localized: "\(who): manca la password.")) }
                else if p.password != p.confirm { out.append(String(localized: "\(who): le password non coincidono.")) }
            case .publicKey:
                if (try? XizIdentity.publicKey(fromText: p.publicKey)) == nil { out.append(String(localized: "\(who): la chiave pubblica non è valida (xizpk1…).")) }
            }
        }
        for (i, p) in recipients.enumerated() { check(p, p.label.isEmpty ? String(localized: "Destinatario \(i + 1)") : p.label) }
        for (i, c) in custodians.enumerated() {
            let name = c.label.isEmpty ? String(localized: "Custodi \(i + 1)") : c.label
            if c.people.count < 2 { out.append(String(localized: "\(name): servono almeno 2 custodi.")) }
            if c.k < 2 || c.k > c.people.count { out.append(String(localized: "\(name): il numero richiesto deve stare tra 2 e \(c.people.count).")) }
            for (j, p) in c.people.enumerated() { check(p, p.label.isEmpty ? String(localized: "\(name), custode \(j + 1)") : "\(name), \(p.label)") }
        }
        let known = Set(folderNames)
        let unknown = (recipients.compactMap(\.folders) + custodians.compactMap(\.folders)).flatMap { $0 }.filter { !known.contains($0) }
        if let name = unknown.first { out.append(String(localized: "La cartella riservata «\(name)» non esiste più: aggiorna chi può aprirla.")) }
        if hasAccess && recipients.isEmpty && custodians.isEmpty && !hasPassword {
            out.append(String(localized: "Serve almeno un destinatario, un gruppo di custodi o una password."))
        }
        return out
    }

    func access() throws -> XizAccess? {
        guard hasAccess else { return nil }
        func credential(_ p: Person) throws -> XizAccess.Credential {
            p.kind == .password ? .password(p.password) : .publicKey(try XizIdentity.publicKey(fromText: p.publicKey))
        }
        func groups(_ s: Set<String>?) -> [String]? { s.map { Array($0) } }
        return XizAccess(
            groups: folders.map { XizAccess.Group(name: $0.name.trimmingCharacters(in: .whitespaces), prefixes: $0.paths) },
            recipients: try recipients.map { XizAccess.Recipient(label: $0.label, credential: try credential($0), groups: groups($0.folders)) },
            thresholds: try custodians.map { c in
                XizAccess.Threshold(label: c.label, k: c.k,
                                    custodians: try c.people.map { XizAccess.Recipient(label: $0.label, credential: try credential($0)) },
                                    groups: groups(c.folders))
            },
            erasable: erasable)
    }
}

/// "Accesso e firma" (XIZ 1.3): reserved folders, who opens what, custodians, erasable files, signature.
struct XizAccessSheet: View {
    @Binding var draft: XizAccessDraft
    /// Folders inside the items being compressed (archive paths), to pick from.
    let availableFolders: [String]
    let hasPassword: Bool
    @Environment(\.dismiss) private var dismiss
    private let identities = XizKeychain.list(.identity)
    private let signingKeys = XizKeychain.list(.signing)

    var body: some View {
        VStack(spacing: 0) {
            Form {
                foldersSection
                recipientsSection
                custodiansSection
                optionsSection
                let problems = draft.problems(hasPassword: hasPassword)
                if !problems.isEmpty {
                    Section {
                        ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Rimuovi tutto", role: .destructive) { draft = XizAccessDraft(); draft.signingKey = ""; dismiss() }
                Spacer()
                Button("Fatto") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.problems(hasPassword: hasPassword).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 680, height: 640)
    }

    // MARK: sections

    private var foldersSection: some View {
        Section {
            ForEach($draft.folders) { $f in
                HStack(alignment: .top) {
                    TextField("Nome", text: $f.name, prompt: Text("es. Referti"))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(f.paths, id: \.self) { p in
                            HStack(spacing: 4) {
                                Image(systemName: "folder").foregroundStyle(.secondary)
                                Text(p).lineLimit(1).truncationMode(.middle)
                                Button { f.paths.removeAll { $0 == p } } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                            }
                        }
                        Menu("Scegli cartella") {
                            ForEach(availableFolders.filter { !f.paths.contains($0) }, id: \.self) { p in
                                Button(p) { f.paths.append(p) }
                            }
                        }
                        .fixedSize()
                        .disabled(availableFolders.isEmpty)
                    }
                    Spacer()
                    Button { draft.folders.removeAll { $0.id == f.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Button("Aggiungi cartella riservata", systemImage: "plus") { draft.folders.append(.init()) }
        } header: {
            Text("Cartelle riservate")
        } footer: {
            Text("Ogni cartella riservata è cifrata con una chiave propria. Tutto il resto forma la cartella principale.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var recipientsSection: some View {
        Section {
            ForEach($draft.recipients) { $p in
                personRow($p, folders: true) { draft.recipients.removeAll { $0.id == p.id } }
            }
            Button("Aggiungi destinatario", systemImage: "plus") { draft.recipients.append(.init()) }
        } header: {
            Text("Chi può aprire")
        } footer: {
            Text(hasPassword ? String(localized: "La password scelta con il pulsante Password apre tutto l'archivio.")
                             : String(localized: "Ognuno vede ed estrae solo le cartelle che può aprire; le altre non compaiono nemmeno."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var custodiansSection: some View {
        Section {
            ForEach($draft.custodians) { $c in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Nome del gruppo", text: $c.label, prompt: Text("es. Dati grezzi"))
                            .labelsHidden().textFieldStyle(.roundedBorder)
                            .frame(width: 170)
                        Text(String(localized: "\(c.k) su \(c.people.count)")).monospacedDigit()
                        Stepper("", value: $c.k, in: 2...max(2, c.people.count)).labelsHidden().fixedSize()
                        foldersMenu($c.folders)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Button { draft.custodians.removeAll { $0.id == c.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                    ForEach($c.people) { $p in
                        personRow($p, folders: false) {
                            c.people.removeAll { $0.id == p.id }
                            c.k = min(c.k, max(2, c.people.count))
                        }
                        .padding(.leading, 16)
                    }
                    Button("Aggiungi custode", systemImage: "plus") { c.people.append(.init()) }
                        .buttonStyle(.borderless).padding(.leading, 16)
                }
            }
            Button("Aggiungi gruppo di custodi", systemImage: "plus") { draft.custodians.append(.init()) }
        } header: {
            Text("Custodi")
        } footer: {
            Text("Le cartelle di un gruppo di custodi si aprono solo quando il numero richiesto di custodi sblocca insieme; nessuno può farlo da solo.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var optionsSection: some View {
        Section {
            Toggle(isOn: $draft.erasable) {
                Text("File cancellabili")
                Text("Ogni file ha una chiave propria: «Cancella definitivamente» lo rende illeggibile in tutte le versioni dell'archivio. Le copie fatte prima della cancellazione lo conservano.")
            }
            Picker("Firma", selection: $draft.signingKey) {
                Text("Non firmare").tag("")
                ForEach(signingKeys) { Text($0.name).tag($0.name) }
            }
            if signingKeys.isEmpty {
                SettingsLink { Text("Crea una chiave di firma nelle Impostazioni…") }
                    .buttonStyle(.link)
            }
        } header: {
            Text("Opzioni")
        }
    }

    // MARK: pieces

    private func personRow(_ p: Binding<XizAccessDraft.Person>, folders: Bool, remove: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            TextField("Nome", text: p.label, prompt: Text("es. Laboratorio"))
                .labelsHidden().textFieldStyle(.roundedBorder)
                .frame(width: 130)
            Picker("", selection: p.kind) {
                ForEach(XizAccessDraft.Kind.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().fixedSize()
            VStack(spacing: 4) {
                if p.wrappedValue.kind == .password {
                    SecureField("Password", text: p.password, prompt: Text("Password")).labelsHidden()
                    SecureField("Ripeti", text: p.confirm, prompt: Text("Ripeti")).labelsHidden()
                } else {
                    HStack(spacing: 4) {
                        TextField("Chiave pubblica", text: p.publicKey, prompt: Text("xizpk1…")).labelsHidden()
                            .font(.system(.body, design: .monospaced))
                        if !identities.isEmpty {
                            Menu {
                                ForEach(identities) { i in Button(i.name) { p.publicKey.wrappedValue = i.publicKey } }
                            } label: { Image(systemName: "person.crop.circle") }
                            .menuStyle(.borderlessButton).fixedSize().help("Usa una delle tue identità")
                        }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            if folders { foldersMenu(p.folders) }
            Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
        }
    }

    /// "Tutto" or a choice of folders ("" = the main folder).
    private func foldersMenu(_ selection: Binding<Set<String>?>) -> some View {
        Menu {
            Button {
                selection.wrappedValue = nil
            } label: {
                if selection.wrappedValue == nil { Label("Tutto", systemImage: "checkmark") } else { Text("Tutto") }
            }
            Divider()
            ForEach(draft.folderNames, id: \.self) { name in
                let title = name.isEmpty ? String(localized: "Cartella principale") : name
                let on = selection.wrappedValue?.contains(name) == true
                Button {
                    var s = selection.wrappedValue ?? []
                    if on { s.remove(name) } else { s.insert(name) }
                    selection.wrappedValue = s.isEmpty ? nil : s
                } label: {
                    if on { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        } label: {
            Text(selection.wrappedValue.map { s in s.count == 1 ? (s.first!.isEmpty ? String(localized: "Principale") : s.first!) : String(localized: "\(s.count) cartelle") }
                 ?? String(localized: "Tutto"))
        }
        .fixedSize()
    }
}

/// Archive paths of the folders inside the items being compressed (a few levels deep).
func archiveFolders(of items: [URL], depth: Int = 3, limit: Int = 400) -> [String] {
    var out: [String] = []
    let fm = FileManager.default
    for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        out.append(item.lastPathComponent)
        guard let e = fm.enumerator(at: item, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
        for case let url as URL in e {
            if out.count >= limit { return out }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let rel = url.path.dropFirst(item.deletingLastPathComponent().path.count + 1)
            if rel.split(separator: "/").count > depth { e.skipDescendants(); continue }
            out.append(String(rel))
        }
    }
    return out
}
