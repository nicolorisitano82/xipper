import AppKit
import SwiftUI
import XipperKit

/// "File già esistente" (3.3): a system alert shown from an extraction thread, which waits
/// for the answer (the extraction is paused meanwhile).
enum ConflictPrompt {
    static func ask(_ c: ExtractConflict, folder: String, others: Int) -> ConflictResolution {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated { present(c, folder: folder, others: others) }
        }
    }

    @MainActor
    private static func present(_ c: ExtractConflict, folder: String, others: Int) -> ConflictResolution {
        let name = (c.entry as NSString).lastPathComponent
        let alert = NSAlert()
        // The folder that actually holds the clashing file ("in Progetto-Atlante").
        let holder = c.existing.deletingLastPathComponent().lastPathComponent
        alert.messageText = "“\(name)” esiste già in \(holder.isEmpty ? folder : holder)"
        alert.informativeText = "Scegli cosa fare con il file che stai estraendo."
        alert.addButton(withTitle: "Mantieni entrambi")
        alert.addButton(withTitle: "Sostituisci")
        alert.addButton(withTitle: "Salta")
        if others > 0 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = others == 1 ? "Applica all'altro conflitto" : "Applica agli altri \(others) conflitti"
        }
        let view = NSHostingView(rootView: ConflictDetails(conflict: c, name: name))
        view.frame.size = view.fittingSize
        alert.accessoryView = view
        NSApp.requestUserAttention(.informationalRequest)
        let response = alert.runModal()
        let all = alert.suppressionButton?.state == .on
        switch response {
        case .alertSecondButtonReturn: return ConflictResolution(.replace, applyToAll: all)
        case .alertThirdButtonReturn: return ConflictResolution(.skip, applyToAll: all)
        default: return ConflictResolution(.keepBoth, applyToAll: all)
        }
    }
}

private struct ConflictDetails: View {
    let conflict: ExtractConflict
    let name: String

    private var archiveNewer: Bool {
        guard let a = conflict.archiveModified, let d = conflict.diskModified else { return false }
        return a > d
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                box("Nell'archivio", size: conflict.archiveSize, date: conflict.archiveModified, newer: archiveNewer)
                box("Sul disco", size: conflict.diskSize, date: conflict.diskModified, newer: !archiveNewer && conflict.archiveModified != nil)
            }
            Text("“Mantieni entrambi” salva la copia come “\(keepBothName)”. Sostituisci sposta il file sul disco nel Cestino.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 320)
    }

    private var keepBothName: String {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(stem) 2" : "\(stem) 2.\(ext)"
    }

    private func box(_ title: String, size: Int64?, date: Date?, newer: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                if newer {
                    Text("più recente").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15), in: .capsule)
                }
            }
            Text(size.map { $0.byteText } ?? "—").font(.callout).monospacedDigit()
            Text(date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "").font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
    }
}
