import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers
import XipperKit

/// Extracts single entries to a private temporary folder, for Quick Look (3.4) and for
/// dragging entries out of the browser. Uses the same safe extraction as a normal job.
enum EntryStaging {
    nonisolated static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Xipper-staging", isDirectory: true)
    }

    /// Extracts `paths` (files or folders) of `archive` into a new folder and returns
    /// the extracted item for each path, in order.
    nonisolated static func stage(_ paths: [String], of archive: URL, password: String?) throws -> [URL] {
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var options = ExtractOptions()
        options.selection = Set(paths)
        options.password = password
        options.overwrite = .replace
        _ = try Xipper.extract(archive, to: dir, mode: .into, options: options)
        return paths.map { dir.appendingPathComponent($0) }
    }

    /// Removes everything staged by previous runs (called at launch and at quit).
    nonisolated static func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    /// A drag item that extracts the entry only when the drop target asks for the file.
    nonisolated static func dragProvider(for item: BrowserItem, archive: URL, password: String?) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = (item.path as NSString).lastPathComponent
        let type: UTType = item.isFolder ? .folder : (UTType(filenameExtension: (item.path as NSString).pathExtension) ?? .data)
        let path = item.path
        provider.registerFileRepresentation(for: type, visibility: .all, openInPlace: false) { completion in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    completion(try stage([path], of: archive, password: password).first, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }
}

/// Feeds the shared Quick Look panel with staged entries of the focused browser.
/// Installed in the window's responder chain, where the panel looks for a controller.
@MainActor
final class EntryPreviewController: NSResponder {
    /// Archive, selected file paths and password, kept current by the browser.
    var archive = URL(fileURLWithPath: "/")
    var paths: [String] = []
    var password: String?
    private var items: [URL] = []
    private var staged: [String: URL] = [:]
    private var stagedArchive: URL?
    private var generation = 0

    private var panelIsOurs: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible && QLPreviewPanel.shared().dataSource === self
    }

    /// Space bar / "Anteprima": opens or closes the panel on the selection.
    func toggle() {
        if panelIsOurs {
            QLPreviewPanel.shared().orderOut(nil)
        } else {
            Task { await refresh(open: true) }
        }
    }

    /// Keeps an open panel in sync with the selection.
    func selectionChanged() {
        if panelIsOurs { Task { await refresh(open: false) } }
    }

    private func refresh(open: Bool) async {
        let (archive, paths, password) = (archive, paths, password)
        guard !paths.isEmpty else { return }
        if stagedArchive != archive { staged = [:]; stagedArchive = archive }
        generation += 1
        let current = generation
        let missing = paths.filter { staged[$0] == nil }
        if !missing.isEmpty {
            let result = await Task.detached { try? EntryStaging.stage(missing, of: archive, password: password) }.value
            guard current == generation else { return }
            for (p, u) in zip(missing, result ?? []) where FileManager.default.fileExists(atPath: u.path) { staged[p] = u }
        }
        items = paths.compactMap { staged[$0] }
        guard !items.isEmpty else { NSSound.beep(); return }
        let panel = QLPreviewPanel.shared()!
        if open {
            panel.makeKeyAndOrderFront(nil)
        }
        if panel.dataSource === self {
            panel.reloadData()
            panel.currentPreviewItemIndex = 0
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

extension EntryPreviewController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        items[index] as NSURL
    }
}

/// Puts a responder right after the window in the responder chain.
struct ResponderInstaller: NSViewRepresentable {
    let responder: NSResponder

    func makeNSView(context: Context) -> NSView { InstallerView(responder: responder) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class InstallerView: NSView {
        let responder: NSResponder
        init(responder: NSResponder) {
            self.responder = responder
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.nextResponder !== responder else { return }
            responder.nextResponder = window.nextResponder
            window.nextResponder = responder
        }
    }
}
