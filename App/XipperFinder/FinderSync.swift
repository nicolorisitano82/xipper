import Cocoa
import FinderSync

/// Finder Sync extension: "Xipper" submenu in the contextual menu and a toolbar button.
/// It is sandboxed and cannot read the files itself: it forwards the selection to Xipper.app
/// through `xipper://` URLs (see ExternalActions.swift in the app).
final class FinderSync: FIFinderSync {
    private static let archiveExtensions: Set<String> = [
        "zip", "tar", "tgz", "gz", "bgz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "tzst", "bam", "bcf",
    ]

    override init() {
        super.init()
        // Offer the menu everywhere (the extension only reads names, never contents).
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    // MARK: toolbar

    override var toolbarItemName: String { "Xipper" }
    override var toolbarItemToolTip: String { String(localized: "Comprimi, estrai o verifica con Xipper") }
    override var toolbarItemImage: NSImage {
        Self.glyph ?? NSImage(systemSymbolName: "archivebox", accessibilityDescription: "Xipper") ?? NSImage()
    }

    // MARK: menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")
        let items = selection
        guard !items.isEmpty else { return menu }
        let archives = items.filter(Self.isArchive)
        let target: NSMenu
        if menuKind == .toolbarItemMenu {
            target = menu
        } else {
            let root = menu.addItem(withTitle: "Xipper", action: nil, keyEquivalent: "")
            root.image = Self.glyph ?? NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)
            target = NSMenu(title: "Xipper")
            root.submenu = target
        }
        let compressTitle = items.count == 1 ? String(localized: "Comprimi “\(items[0].lastPathComponent)”") : String(localized: "Comprimi \(items.count) elementi")
        add(target, compressTitle, "arrow.down.right.and.arrow.up.left", #selector(compress(_:)))
        if !archives.isEmpty {
            let extractable = archives.filter { !["bam", "bcf"].contains($0.pathExtension.lowercased()) }
            if !extractable.isEmpty { add(target, String(localized: "Estrai qui"), "arrow.down.to.line", #selector(extract(_:))) }
            add(target, String(localized: "Verifica"), "checkmark.shield", #selector(test(_:)))
            if archives.count == 1 {
                add(target, String(localized: "Apri in Xipper"), "eye", #selector(open(_:)))
                add(target, String(localized: "Monta come volume"), "externaldrive", #selector(mount(_:)))
            }
        }
        return menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ symbol: String, _ action: Selector) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    /// Selected items, or the folder shown in the window when nothing is selected.
    private var selection: [URL] {
        let c = FIFinderSyncController.default()
        if let s = c.selectedItemURLs(), !s.isEmpty { return s }
        return c.targetedURL().map { [$0] } ?? []
    }

    /// Xipper's zipper X (docs/design/artwork), as a template image like the system symbols.
    private static let glyph: NSImage? = {
        guard let url = Bundle(for: FinderSync.self).url(forResource: "XipperGlyph", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        image.accessibilityDescription = "Xipper"
        return image
    }()

    private static func isArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return archiveExtensions.contains(url.pathExtension.lowercased()) || name.hasSuffix(".tar.gz") || name.hasSuffix(".tar.zst")
    }

    // MARK: actions

    @objc func compress(_ sender: AnyObject?) { send("compress", selection) }
    @objc func extract(_ sender: AnyObject?) { send("extract", selection.filter(Self.isArchive)) }
    @objc func test(_ sender: AnyObject?) { send("test", selection.filter(Self.isArchive)) }
    @objc func open(_ sender: AnyObject?) { send("open", selection.filter(Self.isArchive)) }
    @objc func mount(_ sender: AnyObject?) { send("mount", selection.filter(Self.isArchive)) }

    private func send(_ verb: String, _ files: [URL]) {
        guard !files.isEmpty else { return }
        var c = URLComponents()
        c.scheme = "xipper"
        c.host = verb
        c.queryItems = files.map { URLQueryItem(name: "p", value: $0.path) }
        if let url = c.url { NSWorkspace.shared.open(url) }
    }
}
