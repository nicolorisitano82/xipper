import Cocoa
import FinderSync

/// Finder Sync extension: contextual menu items (the fitting action first, the others in a
/// submenu) and a toolbar button.
/// It is sandboxed and cannot read the files itself: it forwards the selection to Xipper.app
/// through `xipper://` URLs (see ExternalActions.swift in the app).
final class FinderSync: FIFinderSync {
    private static let archiveExtensions: Set<String> = [
        "zip", "7z", "xiz", "aar", "cpio", "tar", "tgz", "gz", "bgz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "tzst",
        "lz4", "br", "bam", "bcf", "001", "rar",
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
        let extractable = archives.filter { !["bam", "bcf"].contains($0.pathExtension.lowercased()) }
        let onlyArchives = archives.count == items.count
        let name = items.count == 1 ? items[0].lastPathComponent : nil

        // Contextual: the action that fits the selection comes first, with Xipper's icon
        // (extract for archives, compress for everything else); the rest go in a submenu.
        let primary: (String, Selector)
        if onlyArchives && !extractable.isEmpty {
            primary = (name.map { String(localized: "Decomprimi “\($0)”") } ?? String(localized: "Decomprimi \(items.count) archivi"), #selector(extract(_:)))
        } else if onlyArchives {
            primary = (String(localized: "Apri in Xipper"), #selector(open(_:)))  // BAM/BCF: browse, not extract
        } else {
            primary = (name.map { String(localized: "Comprimi “\($0)”") } ?? String(localized: "Comprimi \(items.count) elementi"), #selector(compress(_:)))
        }
        var others: [(String, String, Selector)] = []
        if primary.1 != #selector(compress(_:)) {
            others.append((name.map { String(localized: "Comprimi “\($0)”") } ?? String(localized: "Comprimi \(items.count) elementi"),
                           "arrow.down.right.and.arrow.up.left", #selector(compress(_:))))
        }
        if !extractable.isEmpty && primary.1 != #selector(extract(_:)) {
            others.append((String(localized: "Decomprimi gli archivi"), "arrow.down.to.line", #selector(extract(_:))))
        }
        if !archives.isEmpty {
            others.append((String(localized: "Verifica"), "checkmark.shield", #selector(test(_:))))
            if archives.count == 1 {
                if primary.1 != #selector(open(_:)) { others.append((String(localized: "Apri in Xipper"), "eye", #selector(open(_:)))) }
                others.append((String(localized: "Monta come volume"), "externaldrive", #selector(mount(_:))))
            }
        }

        if menuKind == .toolbarItemMenu {
            menu.addItem(withTitle: primary.0, action: primary.1, keyEquivalent: "").image = Self.glyph
            for o in others { add(menu, o.0, o.1, o.2) }
            return menu
        }
        menu.addItem(withTitle: primary.0, action: primary.1, keyEquivalent: "").image = Self.glyph
        if !others.isEmpty {
            let more = menu.addItem(withTitle: String(localized: "Altro con Xipper"), action: nil, keyEquivalent: "")
            more.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
            let sub = NSMenu(title: "Xipper")
            for o in others { add(sub, o.0, o.1, o.2) }
            more.submenu = sub
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

    /// Xipper's zipper X (docs/design/artwork) as a template bitmap, so it turns white in the
    /// highlighted row like the system symbols. Finder copies menus out of the extension and an
    /// SVG-backed image loses its template rendering on the way, so it is rasterized here.
    private static let glyph: NSImage? = {
        guard let url = Bundle(for: FinderSync.self).url(forResource: "XipperGlyph", withExtension: "svg"),
              let svg = NSImage(contentsOf: url) else { return nil }
        let image = NSImage(size: NSSize(width: 16, height: 16))
        for scale in [1, 2, 3] {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16 * scale, pixelsHigh: 16 * scale,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = NSSize(width: 16, height: 16)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            svg.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
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
    @objc func extract(_ sender: AnyObject?) {
        send("extract", selection.filter { Self.isArchive($0) && !["bam", "bcf"].contains($0.pathExtension.lowercased()) })
    }
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
