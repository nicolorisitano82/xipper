import AppKit
import XipperKit

/// Actions requested from outside the app: Finder Quick Actions (Services) and the Finder Sync
/// extension (through `xipper://` URLs). All of them only create new files next to the
/// originals (compress, smart extraction) or read (test, open): nothing is ever overwritten.
enum ExternalAction: Equatable {
    case compress([URL])
    case extract([URL])
    case test([URL])
    case open([URL])

    /// `xipper://compress?p=/path&p=/path` (also extract, test, open).
    init?(url: URL) {
        guard url.scheme == "xipper", let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let files = (c.queryItems ?? []).filter { $0.name == "p" }.compactMap(\.value)
            .filter { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        guard !files.isEmpty else { return nil }
        switch c.host {
        case "compress": self = .compress(files)
        case "extract": self = .extract(files.filter(AppState.isArchive))
        case "test": self = .test(files.filter(AppState.isArchive))
        case "open": self = .open(files.filter(AppState.isArchive))
        default: return nil
        }
    }

    static func url(_ verb: String, _ files: [URL]) -> URL? {
        var c = URLComponents()
        c.scheme = "xipper"
        c.host = verb
        c.queryItems = files.map { URLQueryItem(name: "p", value: $0.path) }
        return c.url
    }
}

@MainActor
enum ExternalActionRunner {
    static func run(_ action: ExternalAction) {
        let jobs = JobCenter.shared
        switch action {
        case let .compress(files):
            guard let first = files.first else { return }
            let format = defaultFormat(for: files)
            let name = files.count == 1 ? first.lastPathComponent : String(localized: "Archivio")
            let dest = uniqueURL(first.deletingLastPathComponent().appendingPathComponent("\(name).\(format.fileExtension)"))
            let preset = LevelPreset(rawValue: Preferences.defaults.string(forKey: PrefKey.levelPreset) ?? "") ?? .balanced
            jobs.start(.create(sources: files, destination: dest, format: format, preset: preset, password: nil))
        case let .extract(archives):
            for a in archives { jobs.start(.extract(ExtractRequest(archive: a))) }
        case let .test(archives):
            for a in archives { jobs.start(.test(archive: a, password: nil)) }
        case let .open(archives):
            AppState.shared.open(archives)
        }
        NSApp.activate()
    }

    /// The default format, falling back to ZIP when it cannot hold several items or a folder.
    private static func defaultFormat(for files: [URL]) -> ArchiveFormat {
        let f = ArchiveFormat(rawValue: Preferences.defaults.string(forKey: PrefKey.defaultFormat) ?? "") ?? .zip
        let multi = files.count > 1 || files.contains(where: \.hasDirectoryPath)
        if multi { return ArchiveFormat.multiItem.contains(f) ? f : .zip }
        return f
    }
}

/// Finder Quick Actions / Services menu ("Comprimi con Xipper", …), declared in Info.plist.
final class ServiceProvider: NSObject {
    @objc func compressFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(pboard) { .compress($0) }
    }

    @objc func extractArchives(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(pboard) { .extract($0.filter(AppState.isArchive)) }
    }

    @objc func testArchives(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(pboard) { .test($0.filter(AppState.isArchive)) }
    }

    private func handle(_ pboard: NSPasteboard, _ make: ([URL]) -> ExternalAction) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return }
        let action = make(urls)
        MainActor.assumeIsolated { ExternalActionRunner.run(action) }
    }
}
