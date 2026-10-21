import AppKit
import XipperKit

extension Notification.Name {
    /// Posted with the archive URL as object after a mounted archive was saved with changes.
    static let xipperArchiveDidChange = Notification.Name("app.xipper.archiveDidChange")
}

/// Archives mounted as volumes (docs/FSKIT.md): a WebDAV server per archive, in this process,
/// with the volume read-write when the format can be written back. Ejecting the volume (from the
/// Finder or here) asks whether to save the changes into the archive.
@MainActor
@Observable
final class MountCenter {
    static let shared = MountCenter()

    struct Mounted: Identifiable {
        var id: URL { archive }
        let archive: URL
        let point: URL
        let mount: ArchiveMount
        var writable: Bool { mount.tree.writable }
    }

    private(set) var mounts: [Mounted] = []
    /// Archives being mounted or saved, so their buttons wait.
    private(set) var busy: Set<URL> = []

    @ObservationIgnored private var watcher: Timer?
    @ObservationIgnored private var unmountObserver: NSObjectProtocol?

    private init() {
        unmountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { MountCenter.shared.check() } }
    }

    func mounted(_ archive: URL) -> Mounted? { mounts.first { $0.archive == archive.standardizedFileURL } }

    func mount(_ archive: URL, password: String?) {
        let archive = archive.standardizedFileURL
        if let m = mounted(archive) { NSWorkspace.shared.open(m.point); return }
        guard !busy.contains(archive) else { return }
        busy.insert(archive)
        Task {
            let result = await Task.detached { () -> Result<(ArchiveMount, URL), Error> in
                Result {
                    let m = try ArchiveMount(archive: archive, password: password)
                    return (m, try m.mount())
                }
            }.value
            busy.remove(archive)
            switch result {
            case let .success((m, point)):
                mounts.append(Mounted(archive: archive, point: point, mount: m))
                startWatching()
                NSWorkspace.shared.open(point)
            case let .failure(error):
                Self.alert(String(localized: "Impossibile montare “\(archive.lastPathComponent)”"), Self.describe(error))
            }
        }
    }

    func eject(_ archive: URL) {
        guard let m = mounted(archive) else { return }
        do {
            try m.mount.unmount()
        } catch {
            Self.alert(String(localized: "Impossibile espellere “\(m.point.lastPathComponent)”"),
                       String(localized: "Alcuni file del volume sono ancora aperti. Chiudili e riprova."))
            return
        }
        check()
    }

    /// Volumes that are gone (ejected from the Finder too): ask about their changes and clean up.
    private func check() {
        let gone = mounts.filter { !$0.mount.isMounted }
        guard !gone.isEmpty else { return }
        mounts.removeAll { m in gone.contains { $0.archive == m.archive } }
        if mounts.isEmpty { watcher?.invalidate(); watcher = nil }
        for m in gone { finish(m, ask: true) }
    }

    private func finish(_ m: Mounted, ask: Bool) {
        var save = m.mount.tree.hasChanges
        if save && ask {
            let alert = NSAlert()
            alert.messageText = String(localized: "Salvare le modifiche in “\(m.archive.lastPathComponent)”?")
            alert.informativeText = String(localized: "Hai modificato il volume montato. Xipper ricostruisce l'archivio con le modifiche e sostituisce l'originale solo quando il nuovo è completo.")
            alert.addButton(withTitle: String(localized: "Salva"))
            alert.addButton(withTitle: String(localized: "Non salvare")).hasDestructiveAction = true
            NSApp.activate()
            save = alert.runModal() == .alertFirstButtonReturn
        }
        guard save else { try? m.mount.finish(save: false); return }
        busy.insert(m.archive)
        Task {
            let mount = m.mount
            let error = await Task.detached { () -> Error? in
                do { try mount.finish(save: true); return nil } catch { return error }
            }.value
            busy.remove(m.archive)
            if let error {
                Self.alert(String(localized: "Modifiche non salvate in “\(m.archive.lastPathComponent)”"), Self.describe(error))
            } else {
                NotificationCenter.default.post(name: .xipperArchiveDidChange, object: m.archive)
            }
        }
    }

    private func startWatching() {
        guard watcher == nil else { return }
        // Fallback for unmounts the workspace notification misses (forced, or by another process).
        watcher = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { MountCenter.shared.check() }
        }
    }

    /// At quit: ejects every volume and saves the changes. False if a volume is still in use.
    func ejectAllForQuit() -> Bool {
        for m in mounts {
            do { try m.mount.unmount() } catch {
                Self.alert(String(localized: "Impossibile espellere “\(m.point.lastPathComponent)”"),
                           String(localized: "Alcuni file del volume sono ancora aperti. Chiudili e riprova."))
                return false
            }
        }
        let all = mounts
        mounts.removeAll()
        watcher?.invalidate()
        watcher = nil
        for m in all {
            do { try m.mount.finish(save: true) } catch {
                Self.alert(String(localized: "Modifiche non salvate in “\(m.archive.lastPathComponent)”"), Self.describe(error))
            }
        }
        return true
    }

    private static func describe(_ error: Error) -> String {
        (error as? XipperError).map(Job.localized) ?? error.localizedDescription
    }

    private static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
