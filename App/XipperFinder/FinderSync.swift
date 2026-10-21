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
        NSImage(systemSymbolName: "archivebox", accessibilityDescription: "Xipper") ?? NSImage()
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
            root.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)
            target = NSMenu(title: "Xipper")
            root.submenu = target
        }
        let compressTitle = items.count == 1 ? String(localized: "Comprimi “\(items[0].lastPathComponent)”") : String(localized: "Comprimi \(items.count) elementi")
        add(target, compressTitle, "arrow.down.right.and.arrow.up.left", #selector(compress(_:)))
        if !archives.isEmpty {
            let extractable = archives.filter { !["bam", "bcf"].contains($0.pathExtension.lowercased()) }
            if !extractable.isEmpty { add(target, String(localized: "Estrai qui"), "arrow.down.to.line", #selector(extract(_:))) }
            add(target, String(localized: "Verifica"), "checkmark.shield", #selector(test(_:)))
            if archives.count == 1 { add(target, String(localized: "Apri in Xipper"), "eye", #selector(open(_:))) }
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

    private static func isArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return archiveExtensions.contains(url.pathExtension.lowercased()) || name.hasSuffix(".tar.gz") || name.hasSuffix(".tar.zst")
    }

    // MARK: actions

    @objc func compress(_ sender: AnyObject?) { send("compress", selection) }
    @objc func extract(_ sender: AnyObject?) { send("extract", selection.filter(Self.isArchive)) }
    @objc func test(_ sender: AnyObject?) { send("test", selection.filter(Self.isArchive)) }
    @objc func open(_ sender: AnyObject?) { send("open", selection.filter(Self.isArchive)) }

    private func send(_ verb: String, _ files: [URL]) {
        guard !files.isEmpty else { return }
        var c = URLComponents()
        c.scheme = "xipper"
        c.host = verb
        c.queryItems = files.map { URLQueryItem(name: "p", value: $0.path) }
        if let url = c.url { NSWorkspace.shared.open(url) }
    }
}
