import Foundation
import Observation
import XipperKit

/// A row of the browser table: an entry or a folder implied by entry paths.
struct BrowserItem: Identifiable, Hashable {
    let path: String
    let name: String
    let isFolder: Bool
    let entry: ArchiveEntry?
    /// For folders: total uncompressed size of their content.
    let size: Int64
    let compressed: Int64
    var id: String { path }

    var ratio: Double? { size > 0 && compressed > 0 ? Double(compressed) / Double(size) : nil }

    static func == (a: BrowserItem, b: BrowserItem) -> Bool { a.path == b.path && a.size == b.size }
    func hash(into h: inout Hasher) { h.combine(path) }
}

/// Loaded listing of one archive with folder navigation.
@MainActor
@Observable
final class ArchiveModel {
    let url: URL
    private(set) var format: ArchiveFormat?
    private(set) var entries: [ArchiveEntry] = []
    private(set) var bgzf: BGZFInfo?
    private(set) var loading = true
    private(set) var error: String?
    private(set) var folders: [String] = []
    var currentFolder = ""
    var search = ""

    init(url: URL) { self.url = url }

    var isEncrypted: Bool { entries.contains(where: \.isEncrypted) }
    var totalSize: Int64 { entries.reduce(0) { $0 + max(0, $1.uncompressedSize) } }
    var archiveSize: Int64 { ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0 }
    var fileCount: Int { entries.filter { $0.kind == .file }.count }

    func load() async {
        loading = true
        let url = url
        let result = await Task.detached { () -> Result<(ArchiveFormat?, [ArchiveEntry], BGZFInfo?), Error> in
            Result {
                let f = try ArchiveFormat.detect(url)
                var entries = try Xipper.list(url)
                if f == .bgzf {
                    // Sizes come from the block chain without decompressing.
                    let info = try Xipper.bgzfInfo(url)
                    if !entries.isEmpty {
                        entries[0].uncompressedSize = info.uncompressedSize
                        entries[0].compressedSize = info.compressedSize
                    }
                    return (f, entries, info)
                }
                return (f, entries, nil)
            }
        }.value
        switch result {
        case let .success((f, e, b)):
            format = f
            entries = e
            bgzf = b
            folders = Self.folderSet(e).sorted()
        case let .failure(err):
            error = (err as? XipperError).map(Job.localized) ?? err.localizedDescription
        }
        loading = false
    }

    /// Every folder path, explicit or implied by an entry's parent.
    private static func folderSet(_ entries: [ArchiveEntry]) -> Set<String> {
        var s = Set<String>()
        for e in entries {
            if e.kind == .directory { s.insert(e.path) }
            var p = (e.path as NSString).deletingLastPathComponent
            while !p.isEmpty && s.insert(p).inserted { p = (p as NSString).deletingLastPathComponent }
        }
        return s
    }

    /// Children of the current folder, or search results over the whole archive.
    var items: [BrowserItem] {
        if !search.isEmpty {
            return entries.filter { $0.kind != .directory && $0.path.localizedCaseInsensitiveContains(search) }
                .map { BrowserItem(path: $0.path, name: $0.path, isFolder: false, entry: $0,
                                   size: $0.uncompressedSize, compressed: $0.compressedSize) }
        }
        let prefix = currentFolder.isEmpty ? "" : currentFolder + "/"
        var out: [BrowserItem] = []
        for f in folders where f.hasPrefix(prefix) && !f.dropFirst(prefix.count).contains("/") && f != currentFolder {
            let inner = entries.filter { $0.path.hasPrefix(f + "/") }
            out.append(BrowserItem(path: f, name: String(f.dropFirst(prefix.count)), isFolder: true, entry: nil,
                                   size: inner.reduce(0) { $0 + max(0, $1.uncompressedSize) },
                                   compressed: inner.reduce(0) { $0 + $1.compressedSize }))
        }
        for e in entries where e.kind != .directory && e.path.hasPrefix(prefix) && !e.path.dropFirst(prefix.count).contains("/") {
            out.append(BrowserItem(path: e.path, name: String(e.path.dropFirst(prefix.count)), isFolder: false, entry: e,
                                   size: e.uncompressedSize, compressed: e.compressedSize))
        }
        return out
    }

    var breadcrumb: [String] {
        currentFolder.isEmpty ? [] : currentFolder.split(separator: "/").map(String.init)
    }
}

