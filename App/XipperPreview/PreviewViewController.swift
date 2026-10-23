import AppKit
import QuickLookUI
import SwiftUI
import XipperKit

/// Quick Look preview of an archive (space bar in the Finder, 9.2): summary and entry list,
/// read straight from the archive (no extraction). Sandboxed: only the previewed file is read.
final class PreviewViewController: NSViewController, QLPreviewingController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let summary = await Task.detached(priority: .userInitiated) { ArchiveSummary.load(url) }.value
        let host = NSHostingView(rootView: ArchivePreview(summary: summary))
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor), host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        preferredContentSize = NSSize(width: 640, height: 480)
    }
}

struct ArchiveSummary: Sendable {
    var name: String
    var format: String
    var archiveSize: Int64
    var entries: [ArchiveEntry] = []
    var totalEntries = 0
    var uncompressed: Int64 = 0
    var encrypted = false
    var note: String?

    /// Above this size, compressed tar listings (which need full decompression) are skipped.
    static let tarListingLimit: Int64 = 2 << 30
    static let maxRows = 500

    static func load(_ url: URL) -> ArchiveSummary {
        let size = ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize).map(Int64.init) ?? 0
        var s = ArchiveSummary(name: url.lastPathComponent, format: "—", archiveSize: size)
        do {
            // Alignments (BAM, CRAM): what the header says.
            if let a = try? Xipper.alignmentSummary(url) {
                let refs = a.references.prefix(8).joined(separator: ", ") + (a.references.count > 8 ? ", …" : "")
                var parts = [String(localized: "\(a.references.count) sequenze di riferimento (\(refs))")]
                if let r = a.records { parts.insert(String(localized: "\(r.formatted()) letture"), at: 0) }
                if let so = a.sortOrder { parts.append(String(localized: "ordinamento \(so)")) }
                if a.isCRAM {
                    s.format = a.formatName
                    s.note = parts.joined(separator: " · ")
                    return s
                }
                s.note = "BAM · " + parts.joined(separator: " · ")
            }
            guard let f = try ArchiveFormat.detect(url) else { s.note = String(localized: "Formato non riconosciuto"); return s }
            s.format = f.displayName
            if f == .bgzf {
                let i = try Xipper.bgzfInfo(url)
                s.uncompressed = i.uncompressedSize
                s.totalEntries = 1
                let blocks = i.endsWithEOFMarker ? String(localized: "BGZF · \(i.blocks) blocchi · marcatore di fine presente")
                                                 : String(localized: "BGZF · \(i.blocks) blocchi · marcatore di fine MANCANTE (file troncato?)")
                s.note = s.note.map { $0 + "\n" + blocks } ?? blocks
                return s
            }
            if f != .zip && f != .tar && size > tarListingLimit {
                s.note = String(localized: "Archivio grande: aprilo in Xipper per vedere il contenuto")
                return s
            }
            let all = try Xipper.list(url).filter { !$0.isAppleDoubleMetadata }
            s.totalEntries = all.count
            s.uncompressed = all.reduce(0) { $0 + max(0, $1.uncompressedSize) }
            s.encrypted = all.contains(where: \.isEncrypted)
            s.entries = Array(all.prefix(maxRows))
        } catch {
            s.note = String(localized: "Impossibile leggere l'archivio: \(error)")
        }
        return s
    }
}

private extension ArchiveFormat {
    var displayName: String {
        switch self {
        case .zip: "ZIP"
        case .bgzf: "BGZF (bgzip)"
        default: rawValue
        }
    }
}

private extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

struct ArchivePreview: View {
    let summary: ArchiveSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "archivebox.fill").font(.system(size: 34)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if summary.encrypted { Label("Cifrato", systemImage: "lock.fill").foregroundStyle(.secondary) }
            }
            .padding(16)
            Divider()
            if let note = summary.note {
                Text(note).foregroundStyle(.secondary).padding(16)
            }
            if !summary.entries.isEmpty {
                List(summary.entries, id: \.path) { e in
                    HStack {
                        Image(systemName: e.kind == .directory ? "folder.fill" : e.kind == .symlink ? "link" : "doc")
                            .foregroundStyle(e.kind == .directory ? Color.accentColor : .secondary)
                            .frame(width: 18)
                        Text(e.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if e.isEncrypted { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                        if e.kind == .file { Text(max(0, e.uncompressedSize).bytes).monospacedDigit().foregroundStyle(.secondary) }
                    }
                    .font(.callout)
                }
                .listStyle(.inset)
                if summary.totalEntries > summary.entries.count {
                    Text("… e altri \(summary.totalEntries - summary.entries.count) elementi")
                        .font(.caption).foregroundStyle(.secondary).padding(8)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 240)
    }

    private var subtitle: String {
        var parts = [summary.format, summary.archiveSize.bytes]
        if summary.totalEntries > 0 { parts.append("\(summary.totalEntries) elementi") }
        if summary.uncompressed > 0 {
            parts.append("\(summary.uncompressed.bytes) estratti")
            let ratio = Int((Double(summary.archiveSize) / Double(summary.uncompressed) * 100).rounded())
            if ratio < 100 { parts.append(String(localized: "rapporto \(ratio)%")) }
        }
        return parts.joined(separator: " · ")
    }
}
