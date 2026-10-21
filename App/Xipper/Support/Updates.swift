import AppKit
import CryptoKit

/// Manual updates, the same way as Neko and Underdock: Xipper asks GitHub whether there is
/// a newer release, offers to download the disk image into Downloads, checks it against the
/// release's SHA-256 file, then opens it and quits. Dragging Xipper into Applications stays
/// with the user: nothing is installed behind anybody's back.
struct Release: Equatable {
    /// "0.9.0-beta3", without the "v" of the tag.
    var version: String
    var notes: String
    var pageURL: URL?
    var diskImageURL: URL?
    var checksumURL: URL?
    var size: Int64
}

enum Updates {
    static let repository = "nicolorisitano82/xipper"

    /// The version this copy is: the full release name written by scripts/release.sh
    /// ("0.9.0-beta2"), or the marketing version for a development build.
    static var runningVersion: String {
        #if DEBUG
        if let v = ProcessInfo.processInfo.environment["XIPPER_DEMO_VERSION"] { return v }
        #endif
        let info = Bundle.main.infoDictionary
        return (info?["XipperReleaseVersion"] as? String) ?? (info?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    // MARK: Versions

    /// Numbers before the dash, then the pre-release ("beta2"); none sorts after any.
    struct Version: Comparable {
        var core: [Int]
        var pre: (label: String, number: Int)?

        init(_ text: String) {
            let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            let parts = trimmed.split(separator: "-", maxSplits: 1).map(String.init)
            core = parts[0].split(separator: ".").map { Int($0) ?? 0 }
            if parts.count > 1 {
                let label = parts[1].filter(\.isLetter).lowercased()
                pre = (label, Int(parts[1].filter(\.isNumber)) ?? 0)
            }
        }

        var isPrerelease: Bool { pre != nil }

        static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }

        static func < (a: Version, b: Version) -> Bool {
            for i in 0..<max(a.core.count, b.core.count) {
                let x = i < a.core.count ? a.core[i] : 0, y = i < b.core.count ? b.core[i] : 0
                if x != y { return x < y }
            }
            switch (a.pre, b.pre) {
            case (nil, nil), (nil, _?): return false
            case (_?, nil): return true
            case let (p?, q?): return p.label != q.label ? p.label < q.label : p.number < q.number
            }
        }
    }

    // MARK: Asking GitHub

    /// The newest release after `running`. Pre-releases count only for a beta copy:
    /// whoever runs a final version is not offered betas.
    static func newest(in releases: [Release], after running: String) -> Release? {
        let current = Version(running)
        return releases
            .filter { !Version($0.version).isPrerelease || current.isPrerelease }
            .filter { Version($0.version) > current }
            .max { Version($0.version) < Version($1.version) }
    }

    static func releases(from json: Data) -> [Release] {
        guard let list = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return [] }
        return list.compactMap { root in
            guard root["draft"] as? Bool != true, let tag = root["tag_name"] as? String else { return nil }
            let assets = root["assets"] as? [[String: Any]] ?? []
            let image = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
            let sum = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg.sha256") == true }
            return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                           notes: (root["body"] as? String) ?? "",
                           pageURL: (root["html_url"] as? String).flatMap(URL.init(string:)),
                           diskImageURL: (image?["browser_download_url"] as? String).flatMap(URL.init(string:)),
                           checksumURL: (sum?["browser_download_url"] as? String).flatMap(URL.init(string:)),
                           size: Int64((image?["size"] as? Int) ?? 0))
        }
    }

    static func fetchReleases() async throws -> [Release] {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=20")!)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub wants to know who is asking: the application and its version, nothing else.
        request.setValue("Xipper/\(runningVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError(String(localized: "GitHub ha risposto \(http.statusCode)."))
        }
        return releases(from: data)
    }

    /// Downloads come from GitHub over HTTPS only: a tampered feed cannot send Xipper elsewhere.
    static func isTrusted(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".github.com") || host.hasSuffix(".githubusercontent.com")
    }

    /// Once a day at most.
    static func isDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) > 24 * 60 * 60
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func freeFile(in folder: URL, named name: String) -> URL {
        var candidate = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) && n < 100 {
            candidate = folder.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The questions: is there one, shall I download it, it is downloaded — shall I open it and quit.
@MainActor
final class UpdateController: NSObject, URLSessionDownloadDelegate {
    static let shared = UpdateController()

    private var busy = false
    private var session: URLSession?
    private var pending: Release?
    private var panel: NSPanel?
    private var bar: NSProgressIndicator?
    private var label: NSTextField?

    /// "Cerca aggiornamenti…": answers even when there is nothing new.
    func checkForUpdates() { Task { await check(loud: true) } }

    /// At launch: if allowed, once a day, silent unless there is something new,
    /// and each version is announced only once.
    func checkQuietlyIfDue() {
        let defaults = Preferences.defaults
        guard defaults.bool(forKey: PrefKey.updatesAutomatic) else { return }
        guard Updates.isDue(lastCheck: defaults.object(forKey: PrefKey.updatesLastCheck) as? Date) else { return }
        Task { await check(loud: false) }
    }

    private func check(loud: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let releases: [Release]
        do {
            releases = try await Updates.fetchReleases()
        } catch {
            if loud { say(String(localized: "Non sono riuscito a chiedere a GitHub."), detail: error.localizedDescription) }
            return
        }
        Preferences.defaults.set(Date(), forKey: PrefKey.updatesLastCheck)
        guard let release = Updates.newest(in: releases, after: Updates.runningVersion) else {
            if loud {
                say(String(localized: "Xipper è aggiornato."), detail: String(localized: "Hai la versione \(Updates.runningVersion)."))
            }
            return
        }
        if !loud && Preferences.defaults.string(forKey: PrefKey.updatesAnnounced) == release.version { return }
        Preferences.defaults.set(release.version, forKey: PrefKey.updatesAnnounced)
        offer(release)
    }

    private func say(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        NSApp.activate()
        alert.runModal()
    }

    private func offer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = String(localized: "È disponibile Xipper \(release.version).")
        var notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 400 { notes = String(notes.prefix(400)) + "…" }
        var detail = String(localized: "Hai la \(Updates.runningVersion).")
        if release.size > 0 { detail += " " + String(localized: "Immagine disco: \(release.size.byteText).") }
        detail += " " + String(localized: "La scarico nei Download; poi la apro e Xipper si chiude, così lo trascini in Applicazioni al posto di questa copia.")
        if !notes.isEmpty { detail += "\n\n" + notes }
        alert.informativeText = detail
        alert.addButton(withTitle: String(localized: "Scarica"))
        alert.addButton(withTitle: String(localized: "Non ora"))
        if release.pageURL != nil { alert.addButton(withTitle: String(localized: "Note di rilascio")) }
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: fetch(release)
        case .alertThirdButtonReturn: release.pageURL.map { _ = NSWorkspace.shared.open($0) }
        default: break
        }
    }

    // MARK: Download

    private func fetch(_ release: Release) {
        guard let url = release.diskImageURL else {
            say(String(localized: "Questa versione non ha un'immagine disco."), detail: String(localized: "Scaricala dalla pagina del rilascio."))
            release.pageURL.map { _ = NSWorkspace.shared.open($0) }
            return
        }
        guard Updates.isTrusted(url), release.checksumURL.map(Updates.isTrusted) ?? true else {
            say(String(localized: "Il file non viene da GitHub."), detail: url.absoluteString)
            return
        }
        pending = release
        busy = true
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        self.session = session
        showProgress(release)
        session.downloadTask(with: url).resume()
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            guard totalBytesExpectedToWrite > 0 else { bar?.isIndeterminate = true; return }
            bar?.isIndeterminate = false
            bar?.doubleValue = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            label?.stringValue = "\(totalBytesWritten.byteText) / \(totalBytesExpectedToWrite.byteText)"
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file disappears when this returns: move it first.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dmg")
        let moved = (try? FileManager.default.moveItem(at: location, to: scratch)) != nil
        MainActor.assumeIsolated {
            guard moved, let release = pending else { finish(); return }
            finish()
            Task { await arrived(scratch, release: release) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        MainActor.assumeIsolated {
            finish()
            if (error as NSError).code != NSURLErrorCancelled {
                say(String(localized: "Il download non è riuscito."), detail: error.localizedDescription)
            }
        }
    }

    /// Checks the image against the release's .sha256, puts it in Downloads, asks to open it.
    private func arrived(_ file: URL, release: Release) async {
        if let sumURL = release.checksumURL {
            do {
                let (data, _) = try await URLSession.shared.data(from: sumURL)
                let expected = String(decoding: data, as: UTF8.self).split(separator: " ").first.map(String.init)?.lowercased() ?? ""
                let actual = try Updates.sha256(of: file)
                guard expected == actual else {
                    try? FileManager.default.removeItem(at: file)
                    say(String(localized: "L'immagine scaricata non corrisponde all'impronta SHA-256 del rilascio."),
                        detail: String(localized: "L'ho eliminata. Riprova più tardi o scaricala dalla pagina del rilascio."))
                    return
                }
            } catch {
                try? FileManager.default.removeItem(at: file)
                say(String(localized: "Non sono riuscito a verificare l'impronta SHA-256."), detail: error.localizedDescription)
                return
            }
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let name = release.diskImageURL?.lastPathComponent ?? "Xipper-\(release.version).dmg"
        let destination = Updates.freeFile(in: downloads, named: name)
        do {
            try FileManager.default.moveItem(at: file, to: destination)
        } catch {
            say(String(localized: "Non sono riuscito a metterla nei Download."), detail: error.localizedDescription)
            return
        }
        askToOpen(destination, version: release.version)
    }

    private func askToOpen(_ image: URL, version: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Xipper \(version) è nei Download.")
        alert.informativeText = String(localized: "La apro e chiudo Xipper? Poi trascina Xipper in Applicazioni, sostituendo quello che c'è, e riaprilo. Mi chiudo prima, così la copia che sostituisci non è quella in uso.")
        alert.addButton(withTitle: String(localized: "Apri e chiudi Xipper"))
        alert.addButton(withTitle: String(localized: "Mostra nel Finder"))
        alert.addButton(withTitle: String(localized: "Più tardi"))
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(image)
            // Running jobs still get their "Ci sono lavori in corso" question.
            NSApp.terminate(nil)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([image])
        default:
            break
        }
    }

    private func finish() {
        busy = false
        session?.finishTasksAndInvalidate()
        session = nil
        pending = nil
        panel?.orderOut(nil)
        panel = nil
        bar = nil
        label = nil
    }

    @objc private func cancelDownload() {
        session?.invalidateAndCancel()
        session = nil
        finish()
    }

    private func showProgress(_ release: Release) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 108), styleMask: [.titled, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Xipper \(release.version)"
        panel.isFloatingPanel = true
        let heading = NSTextField(labelWithString: String(localized: "Download in corso…"))
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = true
        bar.minValue = 0
        bar.maxValue = 1
        bar.startAnimation(nil)
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        let stop = NSButton(title: String(localized: "Annulla"), target: self, action: #selector(cancelDownload))
        let stack = NSStackView(views: [heading, bar, label, stop])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
        panel.contentView = stack
        bar.widthAnchor.constraint(equalToConstant: 320).isActive = true
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.panel = panel
        self.bar = bar
        self.label = label
    }
}
