import Foundation
import XipperKit

/// Earlier versions of XIZ archives opened in a window of their own: each is an APFS clone of the
/// archive cut to that version (no extra space), read-only, next to the archive on its volume, and
/// removed when Xipper quits.
@MainActor
enum ArchiveVersions {
    private static var folders: [URL] = []

    /// Writes version `number` of `archive` and opens it.
    static func open(_ archive: URL, number: Int) async throws {
        let (folder, copy) = try await Task.detached { () throws -> (URL, URL) in
            let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                     appropriateFor: archive.standardizedFileURL, create: true)
            let name = String(localized: "\(archive.deletingPathExtension().lastPathComponent) (versione \(number))")
            let copy = folder.appendingPathComponent(name).appendingPathExtension(archive.pathExtension)
            do {
                try Xipper.xizVersion(archive, number: number, to: copy)
                try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: copy.path)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
            return (folder, copy)
        }.value
        folders.append(folder)
        AppState.shared.pendingOpen.append(copy)
    }

    /// Called at quit.
    static func cleanUp() {
        for f in folders { try? FileManager.default.removeItem(at: f) }
        folders = []
    }
}
