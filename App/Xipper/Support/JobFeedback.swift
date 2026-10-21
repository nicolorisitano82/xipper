import AppKit
import UserNotifications

/// Progress on the Dock icon and a notification when a job ends while Xipper is in the background.
@MainActor
enum JobFeedback {
    private static let progressView = DockProgressView()
    private static var lastDockUpdate = Date.distantPast

    /// Called when jobs start or end, and on progress (throttled here).
    static func update(_ jobs: [Job], force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastDockUpdate) >= 0.25 else { return }
        lastDockUpdate = now
        let running = jobs.filter(\.isRunning)
        let tile = NSApp.dockTile
        let waiting = jobs.filter { if case .needsPassword = $0.state { true } else { $0.paused } }.count
        tile.badgeLabel = waiting > 0 ? "!" : (running.count > 1 ? "\(running.count)" : nil)
        if running.isEmpty {
            if tile.contentView != nil { tile.contentView = nil }
        } else {
            let total = running.reduce(Int64(0)) { $0 + max(0, $1.progress?.totalBytes ?? 0) }
            let done = running.reduce(Int64(0)) { $0 + max(0, $1.progress?.completedBytes ?? 0) }
            progressView.fraction = total > 0 ? min(1, Double(done) / Double(total)) : nil
            if tile.contentView !== progressView { tile.contentView = progressView }
        }
        tile.display()
        HUDPanel.update(jobs)
    }

    /// Asks once, quietly: provisional notifications land in Notification Center without a prompt.
    static func prepare() {
        let reveal = UNNotificationAction(identifier: "reveal", title: String(localized: "Mostra nel Finder"))
        let verify = UNNotificationAction(identifier: "verify", title: String(localized: "Verifica"))
        let report = UNNotificationAction(identifier: "report", title: String(localized: "Mostra rapporto"), options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "created", actions: [reveal, verify], intentIdentifiers: []),
            UNNotificationCategory(identifier: "verifyFailed", actions: [report], intentIdentifiers: []),
        ])
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .provisional]) { _, _ in }
    }

    /// Posts the outcome of a job if the user is not looking at Xipper.
    static func notifyEnd(of job: Job) {
        guard !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        switch job.state {
        case let .finished(detail):
            content.title = String(localized: "\(job.verb) completata")
            content.body = "\(job.title): \(detail)"
        case let .failed(reason):
            content.title = String(localized: "\(job.verb) non riuscita")
            content.body = "\(job.title): \(reason)"
            content.sound = .default
        case .needsPassword:
            // A saved password is being unlocked with Touch ID: that prompt is enough.
            if let archive = job.archive, PasswordVault.has(archive) { return }
            content.title = String(localized: "Password richiesta")
            content.body = String(localized: "\(job.title) è protetto da password.")
        case .needsOverride:
            content.title = String(localized: "Estrazione fermata")
            content.body = String(localized: "\(job.title) supera il limite di sicurezza sulla compressione.")
        case .running, .cancelled:
            return
        }
        if let output = job.output { content.userInfo["reveal"] = output.path }
        if case .create = job.kind, case .finished = job.state { content.categoryIdentifier = "created" }
        if case let .test(archive, _) = job.kind, job.verifyOK == false {
            content.categoryIdentifier = "verifyFailed"
            content.userInfo["archive"] = archive.path
            content.userInfo["job"] = job.id.uuidString
        }
        let request = UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// App icon with a progress bar, as the Finder shows during copies.
private final class DockProgressView: NSView {
    var fraction: Double?

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage.draw(in: bounds)
        let bar = NSRect(x: bounds.width * 0.1, y: bounds.height * 0.08, width: bounds.width * 0.8, height: bounds.height * 0.11)
        let track = NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2)
        NSColor.black.withAlphaComponent(0.55).setFill()
        track.fill()
        let inner = bar.insetBy(dx: 2, dy: 2)
        let width = inner.width * (fraction ?? 0.15)
        let fill = NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: max(inner.height, width), height: inner.height),
                                xRadius: inner.height / 2, yRadius: inner.height / 2)
        NSColor.controlAccentColor.setFill()
        fill.fill()
    }
}

/// Clicking a notification shows the result in the Finder.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let raw = response.notification.request.content.userInfo
        // Only the strings cross to the main actor.
        let info: [String: String] = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in
            (k as? String).flatMap { key in (v as? String).map { (key, $0) } }
        })
        let action = response.actionIdentifier
        await MainActor.run {
            if action == "verify", let path = info["reveal"] {
                JobCenter.shared.start(.test(archive: URL(fileURLWithPath: path), password: nil))
            } else if let archive = info["archive"] {
                // "Mostra rapporto" (or a click): the damaged entries in the archive window (5.2).
                let url = URL(fileURLWithPath: archive)
                if let id = info["job"].flatMap(UUID.init(uuidString:)) { AppState.shared.reportRequests[url] = id }
                AppState.shared.open([url])
                NSApp.activate()
            } else if let path = info["reveal"] {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
    }
}
