import SwiftUI
import UniformTypeIdentifiers
import XipperKit

/// Home: drop zone (content layer, no glass) and a floating glass action bar.
struct HomeView: View {
    @Environment(JobCenter.self) private var jobs
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(PrefKey.defaultFormat) private var formatRaw = ArchiveFormat.zip.rawValue
    @AppStorage(PrefKey.levelPreset) private var presetRaw = LevelPreset.balanced.rawValue

    @State private var items: [URL] = []
    @State private var targeted = false
    @State private var usePassword = false
    @State private var showPassword = false
    @State private var password: String?
    @Namespace private var glass

    private var format: ArchiveFormat {
        let f = ArchiveFormat(rawValue: formatRaw) ?? .zip
        if items.count > 1 || items.contains(where: \.hasDirectoryPath) {
            return ArchiveFormat.multiItem.contains(f) ? f : .zip
        }
        return f
    }

    private var offeredFormats: [ArchiveFormat] {
        let single = items.count == 1 && !items[0].hasDirectoryPath
        return ArchiveFormat.multiItem + (single || items.isEmpty ? ArchiveFormat.singleFile : [])
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            dropZone
                .padding(24)
                .padding(.bottom, 80)
            actionBar
                .padding(.bottom, 28)
        }
        .frame(minWidth: 600, minHeight: 460)
        .overlay(alignment: .bottomTrailing) { JobsHUD().padding(16).padding(.bottom, 72) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Apri archivio…", systemImage: "archivebox") {
                    for url in appState.showOpenPanel() { openWindow(id: "archive", value: url) }
                }
                .buttonStyle(.glass)
            }
        }
        .sheet(isPresented: $showPassword) {
            PasswordSheet(mode: .create, archiveName: suggestedName) { pw in
                password = pw
                usePassword = pw != nil
            }
        }
        #if DEBUG
        .task { DebugHooks.run(jobs) }
        #endif
        .onChange(of: appState.pendingOpen, initial: true) { _, urls in
            guard !urls.isEmpty else { return }
            appState.pendingOpen.removeAll()
            route(urls)
        }
    }

    // MARK: drop zone

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: targeted ? 2 : 1.5, dash: targeted ? [] : [8, 6]))
            .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.4))
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(targeted ? Color.accentColor.opacity(0.07) : Color.primary.opacity(0.025))
            )
            .overlay { items.isEmpty ? AnyView(emptyState) : AnyView(selection) }
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { urls, _ in
                route(urls)
                return true
            } isTargeted: { targeted = $0 }
            .animation(.snappy, value: targeted)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
                .symbolEffect(.bounce, value: targeted)
            Text("Trascina qui file o cartelle")
                .font(.title3.weight(.semibold))
            Text("per creare un archivio. Rilascia un archivio per aprirlo.")
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding()
    }

    private var selection: some View {
        VStack(spacing: 16) {
            HStack(spacing: -18) {
                ForEach(items.prefix(4), id: \.self) { url in
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 72, height: 72)
                        .shadow(radius: 3, y: 2)
                }
            }
            Text(items.count == 1 ? items[0].lastPathComponent : "\(items.count) elementi")
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Text("Diventerà \(suggestedName)")
                .foregroundStyle(.secondary)
            Button("Svuota", systemImage: "xmark.circle") { withAnimation(.snappy) { items.removeAll() } }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: action bar (glass)

    private var actionBar: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 14) {
                HStack(spacing: 12) {
                    Picker("Formato", selection: $formatRaw) {
                        ForEach(offeredFormats) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .fixedSize()
                    Picker("Livello", selection: $presetRaw) {
                        ForEach(LevelPreset.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Toggle(isOn: Binding(get: { usePassword }, set: { on in
                        if on { showPassword = true } else { usePassword = false; password = nil }
                    })) {
                        Label("Password", systemImage: usePassword ? "lock.fill" : "lock")
                    }
                    .toggleStyle(.button)
                    .disabled(!format.supportsPassword)
                    .help(format.supportsPassword ? "Cifra con AES-256" : "La password è disponibile solo per ZIP")
                }
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(reduceTransparency ? .identity : .regular, in: .capsule)
                .glassEffectID("options", in: glass)

                Button {
                    compress()
                } label: {
                    Label("Comprimi", systemImage: "arrow.down.right.and.arrow.up.left")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(items.isEmpty)
                .keyboardShortcut(.defaultAction)
                .glassEffectID("primary", in: glass)
            }
        }
    }

    // MARK: actions

    /// Archives open in a browser window; anything else is queued for compression.
    private func route(_ urls: [URL]) {
        var toCompress: [URL] = []
        for url in urls {
            if !url.hasDirectoryPath && AppState.isArchive(url) && items.isEmpty && urls.count == 1 {
                openWindow(id: "archive", value: url)
            } else {
                toCompress.append(url)
            }
        }
        withAnimation(.snappy) {
            for u in toCompress where !items.contains(u) { items.append(u) }
        }
    }

    private var suggestedName: String {
        guard let first = items.first else { return "Archivio.\(format.fileExtension)" }
        let base = items.count == 1 ? first.lastPathComponent : "Archivio"
        return "\(base).\(format.fileExtension)"
    }

    private func compress() {
        guard let first = items.first else { return }
        let folder = first.deletingLastPathComponent()
        let dest = uniqueURL(folder.appendingPathComponent(suggestedName))
        jobs.start(.create(sources: items, destination: dest, format: format,
                           preset: LevelPreset(rawValue: presetRaw) ?? .balanced, password: usePassword ? password : nil))
        withAnimation(.snappy) { items.removeAll() }
        usePassword = false
        password = nil
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
