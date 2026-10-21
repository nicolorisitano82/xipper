import SwiftUI
import UniformTypeIdentifiers
import XipperKit

/// Archive browser: system sidebar and toolbar (glass by default), opaque Table content,
/// inspector with details and a quick preview.
struct ArchiveBrowserView: View {
    let url: URL
    @Environment(JobCenter.self) private var jobs
    @State private var model: ArchiveModel
    @State private var selection = Set<BrowserItem.ID>()
    @State private var showInspector = true
    @State private var sortOrder = [KeyPathComparator(\BrowserItem.name)]
    @State private var extractSheet: ExtractSheetRequest?
    @State private var quickLook = EntryPreviewController()
    /// The verification started here (or opened from the HUD): its result replaces the content (5.2).
    @State private var verifyJob: Job?
    @State private var showDamaged = false
    @State private var intactReport: Job?
    @AppStorage(PrefKey.favoriteArchives) private var favoritesRaw = ""
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Asking the password of encrypted entries (wrong = the last one did not work).
    @State private var passwordPrompt: PasswordPrompt?
    /// An edit, recovery or repair in progress (shown in the status bar).
    @State private var working: String?
    /// Bumped when recovery files appear, so the inspector looks again.
    @State private var recoveryRevision = 0

    struct PasswordPrompt: Identifiable {
        let id = UUID()
        let wrong: Bool
        let then: () -> Void
    }

    struct ExtractSheetRequest: Identifiable {
        let id = UUID()
        let selection: Set<String>?
    }

    init(url: URL) {
        self.url = url
        _model = State(initialValue: ArchiveModel(url: url))
    }

    var body: some View {
        NavigationSplitView {
            FolderSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            content
                .inspector(isPresented: Binding(get: { showInspector && !showDamaged }, set: { showInspector = $0 })) {
                    ArchiveInspector(model: model, selection: selectedItems, verify: {
                        verifyJob = jobs.start(.test(archive: url, password: model.password))
                    }, createRecovery: {
                        working = String(localized: "Creazione dei dati di recupero…")
                        ArchiveActions.createRecovery(for: url) { working = nil; recoveryRevision += 1 }
                    }, recoveryRevision: recoveryRevision)
                        .inspectorColumnWidth(min: 240, ideal: 262)
                }
        }
        .navigationTitle(showDamaged ? String(localized: "Verifica di \(url.lastPathComponent)") : url.lastPathComponent)
        .navigationSubtitle(showDamaged ? "" : pausedExtraction ?? (model.currentFolder.isEmpty ? subtitle : "/" + model.currentFolder))
        .sheet(item: $intactReport) { ReportSheet(job: $0) }
        .onReceive(NotificationCenter.default.publisher(for: .xipperArchiveDidChange)) { note in
            if (note.object as? URL)?.standardizedFileURL == url.standardizedFileURL { Task { await model.load() } }
        }
        .onChange(of: verifyJob?.verifyOK) { _, ok in
            guard let job = verifyJob, let ok else { return }
            if ok { intactReport = job } else { withAnimation(reduceMotion ? nil : .default) { showDamaged = true } }
        }
        .onChange(of: appState.reportRequests[url], initial: true) { _, id in
            guard let id, let job = jobs.jobs.first(where: { $0.id == id }) else { return }
            appState.reportRequests[url] = nil
            verifyJob = job
            if job.verifyOK == false { showDamaged = true }
        }
        .sheet(item: $extractSheet) { req in
            ExtractSheet(archive: url, selection: req.selection, itemNames: names(for: req.selection),
                         totalSize: size(for: req.selection))
                .environment(jobs)
        }
        .sheet(item: $passwordPrompt) { prompt in
            PasswordSheet(mode: .open(wrong: prompt.wrong), archiveName: url.lastPathComponent) { pw, remember in
                guard let pw else { return }
                Task {
                    if await model.check(password: pw) {
                        model.password = pw
                        if remember { PasswordVault.save(pw, for: url) }
                        prompt.then()
                    } else {
                        passwordPrompt = PasswordPrompt(wrong: true, then: prompt.then)
                    }
                }
            }
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Cerca nell'archivio")
        .toolbar { toolbar }
        .overlay(alignment: .bottomTrailing) { JobsHUD().padding(16) }
        .background { ResponderInstaller(responder: quickLook) }
        .onChange(of: selection) {
            syncQuickLook()
            quickLook.selectionChanged()
        }
        .task {
            await model.load()
            if model.namesLocked { unlockNames() }
            #if DEBUG
            if ProcessInfo.processInfo.environment["XIPPER_DEMO_EXTRACT_SHEET"] != nil {
                let firstFolder = model.folders.first.map { Set([$0]) }
                extractSheet = ExtractSheetRequest(selection: firstFolder)
            }
            if ProcessInfo.processInfo.environment["XIPPER_DEMO_VERIFY"] != nil {
                verifyJob = jobs.start(.test(archive: url, password: nil))
            }
            if let entry = ProcessInfo.processInfo.environment["XIPPER_DEMO_QUICKLOOK"] {
                model.currentFolder = (entry as NSString).deletingLastPathComponent
                selection = [entry]
                try? await Task.sleep(for: .milliseconds(500))
                syncQuickLook()
                quickLook.toggle()
            }
            #endif
        }
    }

    private var subtitle: String {
        guard let f = model.format else { return "" }
        return "\(f.displayName) · \(model.fileCount) file · \(model.totalSize.byteText)"
    }

    /// "archivebox Progetto.zip › Documenti", each part clickable (3.1).
    private var pathBar: some View {
        HStack(spacing: 4) {
            Button {
                model.currentFolder = ""
            } label: {
                Label(url.lastPathComponent, systemImage: "archivebox")
            }
            ForEach(Array(model.breadcrumb.enumerated()), id: \.offset) { i, name in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).accessibilityHidden(true)
                Button(name) {
                    model.currentFolder = model.breadcrumb.prefix(i + 1).joined(separator: "/")
                }
                .fontWeight(i == model.breadcrumb.count - 1 ? .semibold : .regular)
            }
            Spacer()
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .frame(height: 28)
        .background(.bar)
    }

    /// "1 di 1.206 selezionati · 1,21 GB in Documenti".
    private var statusBar: some View {
        let items = model.items
        let size = items.reduce(Int64(0)) { $0 + max(0, $1.size) }
        let place = model.currentFolder.isEmpty ? url.lastPathComponent : (model.currentFolder as NSString).lastPathComponent
        return HStack {
            Text(selection.isEmpty ? String(localized: "\(items.count) elementi · \(size.byteText) in \(place)")
                                   : String(localized: "\(selection.count) di \(items.count) selezionati · \(size.byteText) in \(place)"))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            if let working {
                ProgressView().controlSize(.mini)
                Text(working).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 24)
        .background(.bar)
    }

    /// Editing needs a format Xipper writes, the archive not mounted, and nothing else running.
    private var editable: Bool {
        ArchiveActions.canEdit(model.format) && !model.namesLocked && working == nil && MountCenter.shared.mounted(url) == nil
    }

    private func applyEdit(_ changes: [ArchiveChange]) {
        withPassword(for: Set(model.entries.map(\.path))) {
            working = String(localized: "Modifica dell'archivio…")
            ArchiveActions.edit(url, changes, password: model.password) {
                working = nil
                selection.removeAll()
                Task { await model.load() }
            }
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Aggiungi")
        panel.message = String(localized: "Gli elementi scelti vanno nella cartella «\(model.currentFolder.isEmpty ? url.lastPathComponent : (model.currentFolder as NSString).lastPathComponent)» dell'archivio.")
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func add(_ files: [URL]) {
        let folder = model.currentFolder
        applyEdit(files.map { .add($0, as: folder.isEmpty ? $0.lastPathComponent : folder + "/" + $0.lastPathComponent) })
    }

    private var isFavorite: Bool { favoritesRaw.split(separator: "\n").contains { String($0) == url.path } }

    private func toggleFavorite() {
        var list = favoritesRaw.split(separator: "\n").map(String.init)
        if let i = list.firstIndex(of: url.path) { list.remove(at: i) } else { list.insert(url.path, at: 0) }
        favoritesRaw = list.joined(separator: "\n")
    }

    /// Space bar: Quick Look of the selected files, unlocking encrypted ones first.
    private func previewSelection() {
        withPassword(for: selection) {
            syncQuickLook()
            quickLook.toggle()
        }
    }

    /// Runs `action` once the password of the encrypted entries in `ids` is known:
    /// from the Keychain (Touch ID) or asked to the user.
    private func withPassword(for ids: Set<String>, _ action: @escaping () -> Void) {
        let encrypted = model.entries.contains { e in e.isEncrypted && (ids.contains(e.path) || ids.contains { e.path.hasPrefix($0 + "/") }) }
        guard encrypted, model.password == nil else { return action() }
        Task {
            if let pw = await PasswordVault.password(for: url), await model.check(password: pw) {
                model.password = pw
                action()
            } else {
                passwordPrompt = PasswordPrompt(wrong: false, then: action)
            }
        }
    }

    /// 7z with encrypted names: the password (Keychain first) is needed to list the content.
    private func unlockNames() {
        Task {
            if let pw = await PasswordVault.password(for: url), await model.check(password: pw) {
                model.password = pw
                await model.load()
            } else {
                passwordPrompt = PasswordPrompt(wrong: false) { Task { await model.load() } }
            }
        }
    }

    /// Selected files (not folders) for the Quick Look panel.
    private func syncQuickLook() {
        quickLook.archive = url
        quickLook.paths = model.entries.filter { selection.contains($0.path) && $0.kind == .file }.map(\.path).sorted()
        quickLook.password = model.password
    }

    private var selectedItems: [BrowserItem] { model.items.filter { selection.contains($0.id) } }

    /// "Estrazione di 3 elementi · in pausa" while a conflict waits for an answer (3.3).
    private var pausedExtraction: String? {
        for job in jobs.jobs where job.paused {
            if case let .extract(r) = job.kind, r.archive == url {
                let n = r.selection?.count
                return n.map { String(localized: "Estrazione di \($0) elementi · in pausa") } ?? String(localized: "Estrazione · in pausa")
            }
        }
        return nil
    }

    private func names(for sel: Set<String>?) -> [String] {
        guard let sel else { return model.items.map(\.name) }
        return sel.sorted().map { ($0 as NSString).lastPathComponent }
    }

    private func size(for sel: Set<String>?) -> Int64 {
        guard let sel else { return model.totalSize }
        return model.entries.filter { e in sel.contains(e.path) || sel.contains { e.path.hasPrefix($0 + "/") } }
            .reduce(0) { $0 + max(0, $1.uncompressedSize) }
    }

    @ViewBuilder private var content: some View {
        if showDamaged, let job = verifyJob, !model.loading {
            DamagedEntriesView(job: job, model: model, extractIntact: { intact in
                extractSheet = ExtractSheetRequest(selection: intact)
            }, repair: PAR2.indexFile(for: url) == nil || working != nil ? nil : {
                working = String(localized: "Riparazione in corso…")
                ArchiveActions.repair(url) {
                    working = nil
                    verifyJob = jobs.start(.test(archive: url, password: model.password))
                    Task { await model.load() }
                }
            })
            .transition(.opacity)
        } else if model.loading {
            ProgressView("Lettura dell'archivio…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.namesLocked {
            ContentUnavailableView {
                Label("Nomi dei file cifrati", systemImage: "lock.fill")
            } description: {
                Text("Questo archivio nasconde anche i nomi dei file. Inserisci la password per vederne il contenuto.")
            } actions: {
                Button("Password…") { unlockNames() }.buttonStyle(.glassProminent)
            }
        } else if let error = model.error {
            ContentUnavailableView("Impossibile aprire l'archivio", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            Table(of: BrowserItem.self, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Nome", value: \.name) { item in
                    Label {
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                    } icon: {
                        Image(nsImage: icon(for: item)).resizable().frame(width: 16, height: 16)
                    }
                }
                .width(min: 220, ideal: 360)
                TableColumn("Dimensione", value: \.size) { Text($0.size >= 0 ? $0.size.byteText : "—").monospacedDigit().foregroundStyle(.secondary) }
                    .width(min: 70, ideal: 90)
                TableColumn("Compresso", value: \.compressed) { Text($0.compressed > 0 ? $0.compressed.byteText : "—").monospacedDigit().foregroundStyle(.secondary) }
                    .width(min: 70, ideal: 90)
                TableColumn("Rapporto") { item in
                    Text(item.ratio.map(\.ratioText) ?? "—").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 64, ideal: 72)
                TableColumn("Modificato") { item in
                    Text(item.entry?.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "").foregroundStyle(.secondary)
                }
                .width(min: 110, ideal: 140)
                TableColumn("") { item in
                    if item.entry?.isEncrypted == true { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                }
                .width(20)
            } rows: {
                ForEach(model.items.sorted(using: sortOrder)) { item in
                    TableRow(item)
                        .itemProvider { EntryStaging.dragProvider(for: item, archive: url, password: model.password) }
                }
            }
            .onKeyPress(.space) {
                previewSelection()
                return .handled
            }
            .contextMenu(forSelectionType: BrowserItem.ID.self) { ids in
                if ids.contains(where: { !model.folders.contains($0) }) {
                    Button("Anteprima") { selection = ids; previewSelection() }
                    Divider()
                }
                Button("Estrai…") { extractSheet = ExtractSheetRequest(selection: ids.isEmpty ? nil : ids) }
                if ids.count == 1, let id = ids.first, model.folders.contains(id) {
                    Button("Apri cartella") { model.currentFolder = id }
                }
                if editable {
                    Divider()
                    if ids.count == 1, let id = ids.first {
                        Button("Rinomina…") { if let new = ArchiveActions.askNewName(for: id) { applyEdit([.rename(id, to: new)]) } }
                    }
                    Button("Aggiungi file…") { addFiles() }
                    if !ids.isEmpty {
                        Button("Elimina", role: .destructive) {
                            if ArchiveActions.confirmDelete(ids.count, archive: url) { applyEdit(ids.sorted().map { .delete($0) }) }
                        }
                    }
                }
            } primaryAction: { ids in
                if ids.count == 1, let id = ids.first, model.folders.contains(id) {
                    model.search = ""
                    model.currentFolder = id
                    selection.removeAll()
                } else if !ids.isEmpty {
                    selection = ids
                    previewSelection()  // double click on a file: Quick Look (3.4)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                // Files dropped on the table go into the folder shown (not our own drag-out copies).
                let files = urls.filter { $0.isFileURL && !$0.path.hasPrefix(EntryStaging.root.path) }
                guard editable, !files.isEmpty else { return false }
                add(files)
                return true
            }
            .safeAreaInset(edge: .top, spacing: 0) { pathBar }
            .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
            .scrollEdgeEffectStyle(.hard, for: .top)
        }
    }

    private func icon(for item: BrowserItem) -> NSImage {
        if item.isFolder { return NSWorkspace.shared.icon(for: .folder) }
        let ext = (item.name as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if showDamaged {
                Button("Torna al contenuto", systemImage: "chevron.left") {
                    withAnimation(reduceMotion ? nil : .default) { showDamaged = false }
                }
                .help("Torna al contenuto")
            } else {
                Button("Indietro", systemImage: "chevron.left") {
                    model.currentFolder = (model.currentFolder as NSString).deletingLastPathComponent
                }
                .help("Cartella superiore")
                .disabled(model.currentFolder.isEmpty)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                extract(selection: selection.isEmpty ? nil : selection)
            } label: {
                Label(selection.isEmpty ? String(localized: "Estrai") : String(localized: "Estrai selezione"), systemImage: "arrow.down.to.line")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.glassProminent)
            .help("Estrai accanto all'archivio (⌥ per scegliere la cartella)")
            .disabled(model.loading || model.error != nil || model.namesLocked)
        }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
            Button(showDamaged ? String(localized: "Verifica di nuovo") : String(localized: "Verifica"), systemImage: "checkmark.shield") {
                verifyJob = jobs.start(.test(archive: url, password: model.password))
            }
            .help("Verifica l'integrità senza estrarre")
            .disabled(model.loading || model.error != nil || model.namesLocked)
            if let m = MountCenter.shared.mounted(url) {
                Button("Espelli", systemImage: "eject") { MountCenter.shared.eject(url) }
                    .help("Espelli il volume «\(m.point.lastPathComponent)»\(m.writable ? String(localized: " e salva le modifiche") : "")")
            } else {
                Button("Monta", systemImage: "externaldrive") {
                    withPassword(for: Set(model.entries.map(\.path))) { MountCenter.shared.mount(url, password: model.password) }
                }
                .help("Monta l'archivio come volume: lo apri e lo modifichi nel Finder senza estrarlo")
                .disabled(model.loading || model.error != nil || model.namesLocked || MountCenter.shared.busy.contains(url.standardizedFileURL))
            }
            Button(isFavorite ? "Togli dai Preferiti" : "Aggiungi ai Preferiti", systemImage: isFavorite ? "star.fill" : "star") {
                toggleFavorite()
            }
            .help(isFavorite ? "Togli dai Preferiti" : "Aggiungi ai Preferiti")
            Button("Info", systemImage: "info.circle") { showInspector.toggle() }
                .help("Mostra o nasconde l'inspector")
        }
    }

    /// Whole archive without ⌥: smart extraction next to it, no questions (like Archive Utility).
    /// A selection, or ⌥, opens the extraction sheet (3.2).
    private func extract(selection ids: Set<String>?) {
        if ids == nil && !NSEvent.modifierFlags.contains(.option) {
            jobs.start(.extract(ExtractRequest(archive: url)))
        } else {
            extractSheet = ExtractSheetRequest(selection: ids)
        }
    }
}

/// Folder outline of the archive.
private struct FolderSidebar: View {
    @Bindable var model: ArchiveModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(PrefKey.favoriteArchives) private var favoritesRaw = ""

    private static let otherArchive = "\u{1}archive:"
    private static let presetTag = "\u{1}preset:"
    @AppStorage(PrefKey.defaultFormat) private var formatRaw = ArchiveFormat.zip.rawValue
    @AppStorage(PrefKey.levelPreset) private var presetRaw = LevelPreset.balanced.rawValue

    /// Presets of the format menu (2.2): applied to the next archive, in the "Nuovo archivio" window.
    private struct Preset: Identifiable {
        let id: String
        let title: String
        let format: ArchiveFormat
        let level: LevelPreset
        var subtitle: String { "\(format.displayName) · \(level.title)" }
    }
    private var presets: [Preset] {
        [Preset(id: "share", title: String(localized: "Condivisione"), format: .zip, level: .balanced),
         Preset(id: "backup", title: String(localized: "Backup veloce"), format: .tarZstd, level: .fast),
         Preset(id: "archive", title: String(localized: "Archivio lungo termine"), format: .tarXz, level: .best),
         Preset(id: "private", title: String(localized: "Riservato"), format: .sevenZip, level: .best)]
    }
    private var favorites: [URL] {
        favoritesRaw.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    private var recents: [URL] {
        NSDocumentController.shared.recentDocumentURLs
            .filter { $0.standardizedFileURL != model.url.standardizedFileURL && !favorites.contains($0) }
            .prefix(6).map { $0 }
    }

    var body: some View {
        List(selection: Binding(get: { model.currentFolder }, set: { value in
            // Other archives open in their own window; this one keeps its folder.
            if let value, value.hasPrefix(Self.otherArchive) {
                openWindow(id: "archive", value: URL(fileURLWithPath: String(value.dropFirst(Self.otherArchive.count))))
                return
            }
            if let value, value.hasPrefix(Self.presetTag), let p = presets.first(where: { $0.id == value.dropFirst(Self.presetTag.count) }) {
                formatRaw = p.format.rawValue
                presetRaw = p.level.rawValue
                openWindow(id: "home")
                return
            }
            model.currentFolder = value ?? ""
            model.search = ""
        })) {
            Section("Archivio") {
                Label(model.url.lastPathComponent, systemImage: "archivebox").tag("")
            }
            if !model.folders.isEmpty {
                Section("Cartelle") {
                    ForEach(model.folders, id: \.self) { f in
                        Label((f as NSString).lastPathComponent, systemImage: "folder")
                            .padding(.leading, CGFloat(f.split(separator: "/").count - 1) * 12)
                            .tag(f)
                    }
                }
            }
            if !favorites.isEmpty {
                Section("Preferiti") {
                    ForEach(favorites, id: \.self) { u in
                        Label(u.lastPathComponent, systemImage: "star").tag(Self.otherArchive + u.path)
                    }
                }
            }
            Section("Preset") {
                ForEach(presets) { p in
                    Label(p.title, systemImage: "square.stack.3d.up")
                        .tag(Self.presetTag + p.id)
                        .help(String(localized: "\(p.subtitle): usa questo preset per un nuovo archivio"))
                }
            }
            if !recents.isEmpty {
                Section("Recenti") {
                    ForEach(recents, id: \.self) { u in
                        Label(u.lastPathComponent, systemImage: "clock").tag(Self.otherArchive + u.path)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// Details of the archive or of the selected entries, plus a preview of text and images.
private struct ArchiveInspector: View {
    let model: ArchiveModel
    let selection: [BrowserItem]
    /// "Verifica archivio" (3.1).
    var verify: () -> Void = {}
    /// "Crea dati di recupero" (PAR2).
    var createRecovery: () -> Void = {}
    var recoveryRevision = 0
    @State private var preview: Preview?
    @State private var sha256: String?

    enum Preview: Equatable { case text(String), image(NSImage), none(String) }

    var body: some View {
        Form {
            if let item = selection.first, selection.count == 1 {
                Section(item.isFolder ? String(localized: "Cartella") : String(localized: "File")) {
                    LabeledContent("Nome", value: item.name)
                    LabeledContent("Dimensione", value: item.size >= 0 ? item.size.byteText : "—")
                    if item.compressed > 0 { LabeledContent("Compresso", value: item.compressed.byteText) }
                    if let e = item.entry {
                        LabeledContent("Metodo", value: e.method)
                        if let m = e.modified { LabeledContent("Modificato", value: m.formatted(date: .abbreviated, time: .shortened)) }
                        if let c = e.crc32 {
                            LabeledContent("CRC-32") { Text(String(format: "%08X", c)).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                        }
                        if let p = e.permissions {
                            LabeledContent("Permessi") { Text(String(p, radix: 8)).font(.system(.body, design: .monospaced)) }
                        }
                        if e.isEncrypted { LabeledContent("Cifratura", value: encryptionName(e.encryption)) }
                        if let t = e.linkTarget { LabeledContent("Collegamento a", value: t) }
                    }
                }
                if !item.isFolder && item.entry?.kind == .file && (item.entry?.isEncrypted == false || model.password != nil) {
                    Section("Anteprima") { previewView }
                }
            } else if selection.count > 1 {
                Section("Selezione") {
                    LabeledContent("Elementi", value: "\(selection.count)")
                    LabeledContent("Dimensione", value: selection.reduce(Int64(0)) { $0 + max(0, $1.size) }.byteText)
                }
            } else {
                Section("Archivio") {
                    LabeledContent("Formato", value: model.format?.displayName ?? "—")
                    LabeledContent("Dimensione", value: model.archiveSize.byteText)
                    LabeledContent("Contenuto", value: model.totalSize.byteText)
                    LabeledContent("File", value: "\(model.fileCount)")
                    if model.totalSize > 0 {
                        LabeledContent("Rapporto", value: (Double(model.archiveSize) / Double(model.totalSize)).ratioText)
                    }
                    LabeledContent("Cifrato", value: model.isEncrypted ? String(localized: "Sì") : "No")
                    LabeledContent("SHA-256") {
                        if let sha256 {
                            Text(String(sha256.prefix(16)) + "…").font(.system(.body, design: .monospaced))
                                .textSelection(.enabled).help(sha256)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    LabeledContent("Quarantena", value: quarantine)
                }
                Section {
                    Button("Verifica archivio", systemImage: "checkmark.shield", action: verify)
                        .buttonStyle(.glass).controlSize(.small).frame(maxWidth: .infinity)
                }
                Section("Dati di recupero") {
                    let index = recoveryRevision >= 0 ? PAR2.indexFile(for: model.url) : nil
                    LabeledContent("PAR2", value: index == nil ? String(localized: "Assenti") : String(localized: "Presenti"))
                    if index == nil {
                        Button("Crea dati di recupero", systemImage: "cross.case", action: createRecovery)
                            .buttonStyle(.glass).controlSize(.small).frame(maxWidth: .infinity)
                            .help("File .par2 accanto all'archivio: servono a ripararlo se si danneggia")
                    }
                }
                if let b = model.bgzf {
                    Section("BGZF (genomica)") {
                        LabeledContent("Blocchi", value: "\(b.blocks)")
                        LabeledContent("Marcatore di fine", value: b.endsWithEOFMarker ? String(localized: "Presente") : String(localized: "Mancante: file troncato?"))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: "\(selection.first?.path ?? "")|\(model.password != nil)") { await loadPreview() }
        .task(id: model.url) {
            let url = model.url
            sha256 = await Task.detached { try? Updates.sha256(of: url) }.value
        }
    }

    /// "Sì, scaricato con Safari" from the quarantine attribute ("flags;time;agent;uuid"), or "No".
    private var quarantine: String {
        let size = getxattr(model.url.path, "com.apple.quarantine", nil, 0, 0, 0)
        guard size > 0 else { return String(localized: "No") }
        var buf = [UInt8](repeating: 0, count: size)
        _ = getxattr(model.url.path, "com.apple.quarantine", &buf, size, 0, 0)
        let fields = String(decoding: buf, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
        if fields.count > 2, !fields[2].isEmpty { return String(localized: "Sì, scaricato con \(String(fields[2]))") }
        return String(localized: "Sì")
    }

    @ViewBuilder private var previewView: some View {
        switch preview {
        case let .text(t)?:
            ScrollView { Text(t).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 220)
        case let .image(img)?:
            Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: 220)
        case let .none(reason)?:
            Text(reason).foregroundStyle(.secondary)
        case nil:
            ProgressView()
        }
    }

    private func encryptionName(_ e: EntryEncryption) -> String {
        switch e {
        case .none: String(localized: "Nessuna")
        case .zipCrypto: String(localized: "ZipCrypto (debole)")
        case let .aes(strength, _, _): "AES-\([128, 192, 256][max(0, min(2, Int(strength) - 1))])"
        }
    }

    private func loadPreview() async {
        preview = nil
        guard let item = selection.first, selection.count == 1, !item.isFolder else { return }
        let url = model.url
        let path = item.path
        let password = model.password
        let isImage = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff"].contains((path as NSString).pathExtension.lowercased())
        let result = await Task.detached { () -> Result<EntryContent, Error> in
            Result { try Xipper.readEntry(url, path: path, password: password, maxBytes: isImage ? 8 << 20 : 32 << 10) }
        }.value
        guard case let .success(c) = result else { preview = .none(String(localized: "Anteprima non disponibile")); return }
        if isImage, !c.truncated, let img = NSImage(data: Data(c.data)) {
            preview = .image(img)
        } else if let s = String(bytes: c.data, encoding: .utf8), !c.data.contains(0) {
            preview = .text(s + (c.truncated ? "\n…" : ""))
        } else {
            preview = .none(String(localized: "File binario"))
        }
    }
}
