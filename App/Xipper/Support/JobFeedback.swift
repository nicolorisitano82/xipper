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
    }

    /// Asks once, quietly: provisional notifications land in Notification Center without a prompt.
    static func prepare() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .provisional]) { _, _ in }
    }

    /// Posts the outcome of a job if the user is not looking at Xipper.
    static func notifyEnd(of job: Job) {
        guard !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        switch job.state {
        case let .finished(detail):
            content.title = "\(job.verb) completata"
            content.body = "\(job.title): \(detail)"
        case let .failed(reason):
            content.title = "\(job.verb) non riuscita"
            content.body = "\(job.title): \(reason)"
            content.sound = .default
        case .needsPassword:
            // A saved password is being unlocked with Touch ID: that prompt is enough.
            if let archive = job.archive, PasswordVault.has(archive) { return }
            content.title = "Password richiesta"
            content.body = "\(job.title) è protetto da password."
        case .needsOverride:
            content.title = "Estrazione fermata"
            content.body = "\(job.title) supera il limite di sicurezza sulla compressione."
        case .running, .cancelled:
            return
        }
        if let output = job.output { content.userInfo = ["reveal": output.path] }
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
        guard let path = response.notification.request.content.userInfo["reveal"] as? String else { return }
        await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }
}
