import Foundation
import NetFS

/// An archive mounted as a volume (/Volumes/<name>): a `DAVServer` on 127.0.0.1 and macOS's own
/// WebDAV client, mounted through NetFS with the server's one-time credentials (docs/FSKIT.md).
/// The server lives in this process: keep the object alive while the volume is mounted, then
/// call `finish(save:)` once it is ejected (or `unmount()` it yourself).
public final class ArchiveMount: @unchecked Sendable {
    public let tree: MountedArchive
    public let server: DAVServer
    public private(set) var mountPoint: URL?

    /// `writable: false` mounts read-only even when the format could be written back.
    public init(archive: URL, password: String? = nil, writable: Bool = true) throws {
        tree = try MountedArchive(archive: archive, password: password, writable: writable)
        let name = archive.deletingPathExtension().lastPathComponent
        server = DAVServer(tree: tree, volumeName: archive.pathExtension == "tar" || !name.hasSuffix(".tar") ? name
                                                    : (name as NSString).deletingPathExtension)
        try server.start()
    }

    deinit { server.stop() }

    /// Mounts the volume; returns the mount point. `directory` nil: /Volumes/<archive name>.
    @discardableResult
    public func mount(at directory: URL? = nil) throws -> URL {
        let open = NSMutableDictionary()
        open[kNAUIOptionKey] = kNAUIOptionNoUI
        open[kNetFSAllowLoopbackKey] = true
        let options = NSMutableDictionary()
        var flags = Int32(MNT_NOSUID | MNT_NODEV)
        if !tree.writable { flags |= Int32(MNT_RDONLY) }
        options[kNetFSMountFlagsKey] = flags
        if directory != nil { options[kNetFSMountAtMountDirKey] = true }
        var points: Unmanaged<CFArray>?
        let status = NetFSMountURLSync(server.url as CFURL, directory as CFURL?, server.user as CFString,
                                       server.password as CFString, open, options, &points)
        guard status == 0, let list = points?.takeRetainedValue() as? [String], let first = list.first else {
            throw XipperError.io("mount (NetFS error \(status))", path: tree.archive.path, errno: status > 0 ? status : EIO)
        }
        let url = URL(fileURLWithPath: first, isDirectory: true)
        mountPoint = url
        return url
    }

    /// True while the volume is mounted (ejecting it from the Finder makes this false).
    public var isMounted: Bool {
        guard let mountPoint else { return false }
        var fs = statfs()
        guard statfs(mountPoint.path, &fs) == 0 else { return false }
        let type = withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let on = withUnsafeBytes(of: fs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return type == "webdav" && on == mountPoint.path
    }

    /// Unmounts the volume (`force` also when files are open).
    public func unmount(force: Bool = false) throws {
        guard let mountPoint, isMounted else { return }
        if Darwin.unmount(mountPoint.path, force ? MNT_FORCE : 0) != 0 {
            throw XipperError.posix("unmount", mountPoint.path)
        }
    }

    /// Blocks until the volume is no longer mounted, checking every `interval` seconds.
    public func waitUntilUnmounted(interval: TimeInterval = 0.5, cancel: CancellationToken? = nil) {
        while isMounted && !(cancel?.isCancelled ?? false) { Thread.sleep(forTimeInterval: interval) }
    }

    /// After the volume is gone: stops the server, then writes the changes back into the archive
    /// (`save`) or drops them, and removes the overlay.
    public func finish(save: Bool, progress: ProgressHandler? = nil) throws {
        server.stop()
        defer { tree.close() }
        if save && tree.writable && tree.hasChanges { try tree.save(progress: progress) }
    }
}
