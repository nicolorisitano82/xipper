import SwiftUI
import UniformTypeIdentifiers
import XipperKit

/// Home: empty drop zone (2.1) → list of dropped items (2.2) → progress panel (2.4) → done (2.5).
/// Content stays opaque; only the action bar and the job panel are glass, and they morph into
/// each other through a shared `glassEffectID`.
struct HomeView: View {
    @Environment(JobCenter.self) private var jobs
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PrefKey.defaultFormat) private var formatRaw = ArchiveFormat.zip.rawValue
    @AppStorage(PrefKey.levelPreset) private var presetRaw = LevelPreset.balanced.rawValue
    @AppStorage(PrefKey.zipMethod) private var zipMethodRaw = "deflate"

    @State private var items: [URL] = []
    @State private var infos: [URL: ItemInfo] = [:]
    @State private var selection = Set<URL>()
    @State private var name = ""
    @State private var saveFolder: URL?
    @State private var targeted = false
    @State private var password: String?
    @State private var rememberPassword = false
    @State private var askPassword = false
    @State private var job: Job?
    @Namespace private var glass

    // MARK: derived

    private var multi: Bool { items.count > 1 || items.contains { infos[$0]?.isFolder ?? $0.hasDirectoryPath } }

    private var format: ArchiveFormat {
        let f = ArchiveFormat(rawValue: formatRaw) ?? .zip
        return multi && !ArchiveFormat.multiItem.contains(f) ? .zip : f
    }

    private var preset: LevelPreset { LevelPreset(rawValue: presetRaw) ?? .balanced }
    private var totalSize: Int64 { items.reduce(0) { $0 + (infos[$1]?.size ?? 0) } }
    private var totalFiles: Int { items.reduce(0) { $0 + (infos[$1]?.files ?? 1) } }
    private var excludedMac: Int { items.reduce(0) { $0 + (infos[$1]?.excludedMacFiles ?? 0) } }
    private var defaultName: String { items.count == 1 ? items[0].lastPathComponent : String(localized: "Archivio") }
    private var archiveName: String { (name.isEmpty ? defaultName : name) + "." + format.fileExtension }
    private var folder: URL {
        saveFolder ?? items.first?.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            GlassEffectContainer(spacing: 16) {
                ZStack(alignment: .bottom) {
                    if let job {
                        JobPanel(job: job, onClose: closePanel, onHide: hidePanel)
                            .padding(28)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .glassEffectID("job", in: glass)
                            .transition(reduceMotion ? .opacity : .identity)
                    } else {
                        Group {
                            if items.isEmpty { dropZone } else { itemList }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                        .padding(.bottom, 104)
                        actionBar
                            .padding(.bottom, 28)
                    }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 500)
        .overlay(alignment: .bottomTrailing) { JobsHUD().padding(16).padding(.bottom, job == nil ? 88 : 0) }
        .navigationTitle(items.isEmpty || job != nil ? String(localized: "Xipper") : String(localized: "Nuovo archivio"))
        .navigationSubtitle(items.isEmpty || job != nil ? "" : String(localized: "\(items.count) elementi · \(totalSize.byteText)"))
        .toolbar { toolbar }
        .sheet(isPresented: Bindable(appState).showOnboarding) { OnboardingView() }
        .sheet(isPresented: $askPassword) {
            PasswordSheet(mode: .create, archiveName: archiveName) { pw, remember in
                if let pw { password = pw; rememberPassword = remember }
            }
        }
        #if DEBUG
        .task {
            DebugHooks.run(jobs)
            // XIPPER_DEMO_ITEMS=path:path (2.2), plus XIPPER_DEMO_COMPRESS=1 (2.4/2.5).
            let env = ProcessInfo.processInfo.environment
            if let list = env["XIPPER_DEMO_ITEMS"], items.isEmpty {
                route(list.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
                if let f = env["XIPPER_DEMO_FORMAT"] { formatRaw = f }
                if env["XIPPER_DEMO_COMPRESS"] != nil {
                    try? await Task.sleep(for: .seconds(1))
                    compress()
                }
            }
        }
        #endif
        .onChange(of: appState.pendingOpen, initial: true) { _, urls in
            guard !urls.isEmpty else { return }
            appState.pendingOpen.removeAll()
            route(urls)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .smooth, value: job?.id)
        .animation(reduceMotion ? nil : .snappy, value: items)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if !items.isEmpty && job == nil {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Aggiungi file", systemImage: "plus") { addFiles() }
                Button("Rimuovi dalla lista", systemImage: "trash") { removeSelected() }
                    .disabled(selection.isEmpty)
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItem(placement: .primaryAction) {
            Button("Apri archivio…", systemImage: "archivebox") {
                for url in appState.showOpenPanel() { openWindow(id: "archive", value: url) }
            }
            .help("Apri archivio…")
        }
    }

    // MARK: 2.1 drop zone

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: targeted ? 2 : 1.5, dash: targeted ? [] : [8, 6]))
            .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.4))
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(targeted ? Color.accentColor.opacity(0.07) : Color.primary.opacity(0.025))
            )
            .overlay {
                VStack(spacing: 14) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(.secondary)
                        .bounce(on: targeted)
                        .accessibilityHidden(true)
                    Text("Trascina qui file o cartelle").font(.title3.weight(.semibold))
                    Text("per creare un archivio. Rilascia un archivio per aprirlo.").foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding()
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Scegli i file da comprimere, oppure trascinali qui")
            .accessibilityAction { addFiles() }
            .dropDestination(for: URL.self) { urls, _ in
                route(urls)
                return true
            } isTargeted: { targeted = $0 }
            .animation(reduceMotion ? nil : .snappy, value: targeted)
    }

    // MARK: 2.2 dropped items

    private var itemList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                LabeledContent("Nome") {
                    HStack(spacing: 2) {
                        TextField("Nome", text: Binding(get: { name.isEmpty ? defaultName : name },
                                                        set: { name = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 180)
                        Text("." + format.fileExtension).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Salva in") {
                    Menu {
                        ForEach(saveCandidates, id: \.self) { u in
                            Button { saveFolder = u } label: { Label(u.lastPathComponent, systemImage: "folder.fill") }
                        }
                        Divider()
                        Button("Altra cartella…") { chooseFolder() }
                    } label: {
                        Label(folder.lastPathComponent, systemImage: "folder.fill")
                    }
                    .fixedSize()
                }
            }
            Table(items.map(DroppedItem.init), selection: $selection) {
                TableColumn("Nome") { (item: DroppedItem) in
                    let url = item.url
                    Label {
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    } icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                    }
                }
                .width(min: 200, ideal: 320)
                TableColumn("Tipo") { (item: DroppedItem) in
                    Text(kindText(item.url)).foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 120, ideal: 180)
                TableColumn("Dimensione") { (item: DroppedItem) in
                    Text(infos[item.url].map { $0.size.byteText } ?? "…").monospacedDigit().foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 80, ideal: 90)
            }
            .clipShape(.rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(nsColor: .separatorColor)))
            .dropDestination(for: URL.self) { urls, _ in
                route(urls)
                return true
            }
            .onDeleteCommand { removeSelected() }
            Text(summary).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        var s = "\(totalFiles) file · \(totalSize.byteText)"
        if excludedMac > 0 { s += String(localized: " · .DS_Store e __MACOSX esclusi (\(excludedMac))") }
        return s
    }

    private func kindText(_ url: URL) -> String {
        guard let i = infos[url] else { return "…" }
        return i.isFolder ? String(localized: "Cartella · \(i.files) elementi") : i.kind
    }

    private var saveCandidates: [URL] {
        var list: [URL] = []
        if let first = items.first { list.append(first.deletingLastPathComponent()) }
        for d in [FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .downloadsDirectory] {
            if let u = FileManager.default.urls(for: d, in: .userDomainMask).first, !list.contains(u) { list.append(u) }
        }
        return list
    }

    // MARK: action bar (glass)

    private var actionBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                formatMenu
                Divider().frame(height: 18)
                Menu {
                    Picker("Livello", selection: $presetRaw) {
                        ForEach(LevelPreset.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(preset.title)
                }
                .fixedSize()
                Divider().frame(height: 18)
                Button {
                    if password == nil { askPassword = true } else { password = nil }
                } label: {
                    Label("Password", systemImage: password == nil ? "lock" : "lock.fill")
                }
                .buttonStyle(.borderless)
                .disabled(!format.supportsPassword)
                .help(format.supportsPassword ? (password == nil ? String(localized: "Proteggi con password (AES-256)") : String(localized: "Rimuovi la password")) : "La password è disponibile solo per ZIP")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .padding(.horizontal, 18)
            .frame(height: 44)
            .accessibleGlass(in: Capsule())
            .glassEffectID("job", in: glass)

            Button {
                compress()
            } label: {
                Label("Comprimi", systemImage: "arrow.down.right.and.arrow.up.left").padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(items.isEmpty)
            .keyboardShortcut(.defaultAction)
            .glassEffectID("primary", in: glass)
        }
    }

    private var formatMenu: some View {
        Menu {
            Section("Formato") {
                ForEach(offered, id: \.self) { f in
                    Button {
                        formatRaw = f.rawValue
                        if f == .zip { zipMethodRaw = "deflate" }
                    } label: {
                        Text(f.displayName)
                        Text(description(f))
                    }
                    if f == .zip {
                        // ZIP with zstd (method 93): same container, much faster and smaller.
                        Button {
                            formatRaw = ArchiveFormat.zip.rawValue
                            zipMethodRaw = "zstd"
                        } label: {
                            Text("ZIP · zstd")
                            Text("più veloce · 7-Zip, WinZip; non Utility Archivio")
                        }
                    }
                }
            }
            Section("Preset") {
                Button { formatRaw = ArchiveFormat.tarZstd.rawValue; presetRaw = LevelPreset.fast.rawValue } label: {
                    Text("Backup veloce")
                    Text("tar.zst · Veloce")
                }
                Button { formatRaw = ArchiveFormat.tarXz.rawValue; presetRaw = LevelPreset.best.rawValue } label: {
                    Text("Archivio lungo termine")
                    Text("tar.xz · Massimo")
                }
            }
        } label: {
            Text(format == .zip && zipMethodRaw == "zstd" ? "ZIP · zstd" : format.displayName)
        }
        .fixedSize()
    }

    private var offered: [ArchiveFormat] {
        let single = items.count == 1 && !(infos[items[0]]?.isFolder ?? items[0].hasDirectoryPath)
        return ArchiveFormat.multiItem + (single || items.isEmpty ? ArchiveFormat.singleFile : [])
    }

    private func description(_ f: ArchiveFormat) -> String {
        switch f {
        case .zip: String(localized: "si apre ovunque")
        case .tarZstd: String(localized: "il più veloce")
        case .tarXz: "compatto"
        case .tarGzip: String(localized: "Linux e server")
        case .tarBzip2: String(localized: "compatibilità")
        case .tar: String(localized: "senza compressione")
        case .bgzf: String(localized: "genomica (tabix, samtools)")
        default: String(localized: "un solo file")
        }
    }

    // MARK: actions

    /// Archives open in a browser window (when nothing is queued); anything else joins the list.
    private func route(_ urls: [URL]) {
        if items.isEmpty && urls.count == 1, !urls[0].hasDirectoryPath, AppState.isArchive(urls[0]) {
            openWindow(id: "archive", value: urls[0])
            return
        }
        for u in urls where !items.contains(u) {
            items.append(u)
            let url = u
            Task.detached(priority: .userInitiated) {
                let info = ItemScanner.scan(url)
                await MainActor.run { infos[url] = info }
            }
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = String(localized: "Aggiungi")
        if panel.runModal() == .OK { route(panel.urls) }
    }

    private func removeSelected() {
        items.removeAll { selection.contains($0) }
        selection.removeAll()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Salva qui")
        if panel.runModal() == .OK { saveFolder = panel.url }
    }

    private func compress() {
        guard !items.isEmpty else { return }
        let dest = uniqueURL(folder.appendingPathComponent(archiveName))
        let started = jobs.start(.create(sources: items, destination: dest, format: format, preset: preset, password: password))
        started.rememberPassword = password != nil && rememberPassword
        jobs.focused.insert(started.id)
        job = started
    }

    /// "Nascondi": the job continues in the HUD.
    private func hidePanel() {
        if let job { jobs.focused.remove(job.id) }
        job = nil
        reset()
    }

    /// After completion or failure: back to an empty Home.
    private func closePanel() {
        if let job {
            jobs.focused.remove(job.id)
            if !job.isRunning { jobs.remove(job) }
        }
        job = nil
        reset()
    }

    private func reset() {
        items.removeAll()
        infos.removeAll()
        selection.removeAll()
        name = ""
        password = nil
        saveFolder = nil
    }
}

/// "name.zip" → "name 2.zip" when taken (Finder convention).
func uniqueURL(_ url: URL) -> URL {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { return url }
    let dir = url.deletingLastPathComponent()
    let name = url.lastPathComponent
    let ext = ArchiveFormat.allCases.map { "." + $0.fileExtension }.filter { name.hasSuffix($0) }.max(by: { $0.count < $1.count }) ?? ""
    let stem = String(name.dropLast(ext.count))
    for n in 2... {
        let candidate = dir.appendingPathComponent("\(stem) \(n)\(ext)")
        if !fm.fileExists(atPath: candidate.path) { return candidate }
    }
    return url
}

/// A row of the dropped-items table.
private struct DroppedItem: Identifiable {
    let url: URL
    var id: URL { url }
}
