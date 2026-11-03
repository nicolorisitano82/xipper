import AppKit
import UserNotifications
import XipperKit

/// Periodic check of the XIZ archives Xipper gave a recovery record (2.7): once a month each one is
/// read in full against its record, in the background on the efficiency cores; damage the record
/// can rebuild is repaired in place, and a notification says what happened.
@MainActor
enum XizWatch {
    static let interval: TimeInterval = 30 * 24 * 3600
    private static var scheduler: NSBackgroundActivityScheduler?

    /// Archives being watched, with the time of their last check (0 = never).
    static var archives: [String: Double] {
        get { Preferences.defaults.dictionary(forKey: PrefKey.xizWatchList) as? [String: Double] ?? [:] }
        set { Preferences.defaults.set(newValue, forKey: PrefKey.xizWatchList) }
    }

    /// Called from job threads too: UserDefaults is thread-safe.
    nonisolated static func remember(_ archive: URL) {
        var list = Preferences.defaults.dictionary(forKey: PrefKey.xizWatchList) as? [String: Double] ?? [:]
        list[archive.standardizedFileURL.path] = Date().timeIntervalSince1970
        Preferences.defaults.set(list, forKey: PrefKey.xizWatchList)
    }

    /// Starts (or stops) the daily look for archives due, as the preference says.
    static func schedule() {
        scheduler?.invalidate()
        scheduler = nil
        guard Preferences.defaults.bool(forKey: PrefKey.xizPeriodicScrub) else { return }
        let s = NSBackgroundActivityScheduler(identifier: "app.xipper.xiz-scrub")
        s.repeats = true
        s.interval = 24 * 3600
        s.tolerance = 6 * 3600
        s.qualityOfService = .background
        s.schedule { done in
            Task { @MainActor in
                await checkDue(force: false)
                done(.finished)
            }
        }
        scheduler = s
    }

    /// Checks the archives due (all with `force`); files that no longer exist leave the list.
    @discardableResult
    static func checkDue(force: Bool) async -> (checked: Int, repaired: [String], damaged: [String]) {
        let now = Date().timeIntervalSince1970
        var list = archives
        for path in list.keys where !FileManager.default.fileExists(atPath: path) { list[path] = nil }
        let due = list.filter { force || now - $0.value >= interval }.keys.sorted()
        var repaired: [String] = [], damaged: [String] = []
        for path in due {
            let url = URL(fileURLWithPath: path)
            let result = await Task.detached(priority: .background) { try? Xipper.scrubXiz(url, repair: true) }.value
            guard let r = result, r.info != nil else { list[path] = nil; continue }  // record removed
            list[path] = now
            if r.repaired { repaired.append(path) } else if !r.isClean { damaged.append(path) }
        }
        archives = list
        notify(repaired: repaired, damaged: damaged)
        return (due.count, repaired, damaged)
    }

    private static func notify(repaired: [String], damaged: [String]) {
        guard !repaired.isEmpty || !damaged.isEmpty else { return }
        let content = UNMutableNotificationContent()
        func names(_ p: [String]) -> String { p.map { ($0 as NSString).lastPathComponent }.formatted(.list(type: .and)) }
        if damaged.isEmpty {
            content.title = String(localized: "Archivi riparati")
            content.body = String(localized: "La verifica periodica ha trovato e riparato dei danni in \(names(repaired)).")
        } else {
            content.title = String(localized: "Archivi danneggiati")
            content.body = String(localized: "I dati di recupero non bastano a riparare \(names(damaged)). Fanne una nuova copia da un'altra fonte, se ce l'hai.")
            content.sound = .default
            content.categoryIdentifier = "verifyFailed"
            content.userInfo["archive"] = damaged[0]
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "xiz-scrub-\(UUID())", content: content, trigger: nil))
    }
}
