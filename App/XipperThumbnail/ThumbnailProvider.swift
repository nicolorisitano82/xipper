import AppKit
import QuickLookThumbnailing
import XipperKit

/// Finder thumbnails for archives (9.5): an archive box with the format and, for ZIP, the number
/// of files (central directory only, so it stays instant even for huge archives).
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL
        let format = (try? ArchiveFormat.detect(url)) ?? nil
        var count: Int?
        if format == .zip { count = (try? Xipper.list(url))?.filter { $0.kind == .file && !$0.isAppleDoubleMetadata }.count }
        let label = Self.label(format, url)
        let size = request.maximumSize
        let side = min(size.width, size.height)
        let canvas = CGSize(width: side, height: side)
        handler(QLThumbnailReply(contextSize: canvas, currentContextDrawing: {
            Self.draw(in: CGRect(origin: .zero, size: canvas), label: label, count: count)
            return true
        }), nil)
    }

    private static func label(_ f: ArchiveFormat?, _ url: URL) -> String {
        guard let f else { return url.pathExtension.uppercased() }
        switch f {
        case .bgzf: return url.pathExtension.lowercased() == "bam" ? "BAM" : url.pathExtension.lowercased() == "bcf" ? "BCF" : "BGZF"
        case .zip: return "ZIP"
        default: return f.rawValue.uppercased()
        }
    }

    private static func draw(in rect: CGRect, label: String, count: Int?) {
        let s = rect.width
        // Box body.
        let body = NSRect(x: s * 0.12, y: s * 0.10, width: s * 0.76, height: s * 0.62)
        let lid = NSRect(x: s * 0.08, y: s * 0.70, width: s * 0.84, height: s * 0.17)
        let fill = NSGradient(colors: [NSColor(srgbRed: 0.18, green: 0.80, blue: 0.86, alpha: 1),
                                       NSColor(srgbRed: 0.10, green: 0.42, blue: 0.98, alpha: 1)])!
        fill.draw(in: NSBezierPath(roundedRect: body, xRadius: s * 0.06, yRadius: s * 0.06), angle: 90)
        NSColor(srgbRed: 0.08, green: 0.36, blue: 0.86, alpha: 1).setFill()
        NSBezierPath(roundedRect: lid, xRadius: s * 0.05, yRadius: s * 0.05).fill()
        // Handle slot.
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: s * 0.38, y: s * 0.56, width: s * 0.24, height: s * 0.05), xRadius: s * 0.025, yRadius: s * 0.025).fill()
        // Format label.
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: s * (label.count > 4 ? 0.11 : 0.15), weight: .heavy),
            .foregroundColor: NSColor.white, .paragraphStyle: para,
        ]
        label.draw(in: NSRect(x: body.minX, y: s * 0.30, width: body.width, height: s * 0.2), withAttributes: attrs)
        if let count {
            let small: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: s * 0.075, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.9), .paragraphStyle: para,
            ]
            "\(count) file".draw(in: NSRect(x: body.minX, y: s * 0.16, width: body.width, height: s * 0.12), withAttributes: small)
        }
    }
}
