import AppKit
import QuickLookThumbnailing
import XipperKit

/// Finder thumbnails for archives (9.5): the document icon of the format (FileIcons/*.svg, drawn
/// from sprite C by scripts/make-artwork.py) with its label in the bottom band and, for ZIP, the
/// number of files (central directory only, so it stays instant even for huge archives).
/// Encrypted ZIP and 7z archives show the padlock.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL
        let format = (try? ArchiveFormat.detect(url)) ?? nil
        var count: Int?
        var encrypted = false
        if format == .zip || format == .sevenZip {
            do {
                let entries = try Xipper.list(url).filter { !$0.isAppleDoubleMetadata }
                encrypted = entries.contains(where: \.isEncrypted)
                if format == .zip { count = entries.filter { $0.kind == .file }.count }
            } catch XipperError.passwordRequired {
                encrypted = true  // 7z with encrypted names
            } catch {}
        }
        let isCRAM = format == nil && FileHandle(forReadingAtPath: url.path)?.readData(ofLength: 4) == Data("CRAM".utf8)
        let key = encrypted ? "encrypted" : isCRAM ? "cram" : Self.icon(format, url)
        let label = isCRAM ? "CRAM" : Self.label(format, url)
        let accent = Self.accent(isCRAM ? "cram" : Self.icon(format, url))
        let side = min(request.maximumSize.width, request.maximumSize.height)
        let canvas = CGSize(width: side, height: side)
        handler(QLThumbnailReply(contextSize: canvas, currentContextDrawing: {
            Self.draw(key, label: label, accent: accent, count: count, in: CGRect(origin: .zero, size: canvas))
            return true
        }), nil)
    }

    private static func label(_ f: ArchiveFormat?, _ url: URL) -> String {
        guard let f else { return url.pathExtension.uppercased() }
        switch f {
        case .bgzf: return url.pathExtension.lowercased() == "bam" ? "BAM" : url.pathExtension.lowercased() == "bcf" ? "BCF" : "BGZF"
        default: return f.rawValue.uppercased()
        }
    }

    /// The pictogram for a format (names of FileIcons/*.svg).
    private static func icon(_ f: ArchiveFormat?, _ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ext.count == 3, ext.allSatisfy(\.isNumber) || (ext.hasPrefix("z") && ext.dropFirst().allSatisfy(\.isNumber)) { return "split" }
        switch f {
        case .zip?: return "zip"
        case .sevenZip?: return "7z"
        case .tar?: return "tar"
        case .tarGzip?: return "tgz"
        case .gzip?: return "gz"
        case .tarBzip2?, .bzip2?: return "bz2"
        case .tarXz?: return "txz"
        case .xz?: return "xz"
        case .tarZstd?: return "tzst"
        case .zstd?: return "zst"
        case .tarLz4?, .lz4?: return "lz4"
        case .tarBrotli?, .brotli?: return "br"
        case .cpio?: return "cpio"
        case .appleArchive?: return "aar"
        case .xiz?: return "xiz"
        case .bgzf?: return "bgzf"
        case nil: return "generic"
        }
    }

    private static let accents: [String: [String]] = {
        guard let url = resource("labels", "json"), let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: [String]] ?? [:]
    }()

    private static func accent(_ key: String) -> NSColor {
        guard let hex = accents[key]?.first, let v = UInt32(hex.dropFirst(), radix: 16) else { return .secondaryLabelColor }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// Resources may be copied flat or inside "FileIcons".
    private static func resource(_ name: String, _ ext: String) -> URL? {
        let b = Bundle(for: ThumbnailProvider.self)
        return b.url(forResource: name, withExtension: ext) ?? b.url(forResource: name, withExtension: ext, subdirectory: "FileIcons")
    }

    /// The 256-unit page scaled to `rect`; label from 64 px up, as the .icns document icons.
    private static func draw(_ key: String, label: String, accent: NSColor, count: Int?, in rect: CGRect) {
        if let url = resource(key, "svg") ?? resource("generic", "svg"), let image = NSImage(contentsOf: url) {
            image.draw(in: rect)
        }
        let s = rect.width / 256
        guard rect.width >= 64, !label.isEmpty else { return }
        func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
            let f = NSFont.systemFont(ofSize: size, weight: weight)
            return NSFont(descriptor: f.fontDescriptor.withDesign(.rounded) ?? f.fontDescriptor, size: size) ?? f
        }
        var size = 34 * s
        var attrs: [NSAttributedString.Key: Any] = [.font: rounded(size, .heavy), .foregroundColor: accent]
        while (label as NSString).size(withAttributes: attrs).width > 150 * s && size > 6 { size -= 1; attrs[.font] = rounded(size, .heavy) }
        let t = (label as NSString).size(withAttributes: attrs)
        let labelY = count == nil ? 46 * s : 54 * s
        (label as NSString).draw(at: NSPoint(x: rect.minX + 129 * s - t.width / 2, y: rect.minY + labelY - t.height / 2), withAttributes: attrs)
        if let count, rect.width >= 128 {
            let text = "\(count) file" as NSString
            let small: [NSAttributedString.Key: Any] = [.font: rounded(16 * s, .semibold), .foregroundColor: NSColor(white: 0.45, alpha: 1)]
            let c = text.size(withAttributes: small)
            text.draw(at: NSPoint(x: rect.minX + 129 * s - c.width / 2, y: rect.minY + 28 * s - c.height / 2), withAttributes: small)
        }
    }
}
