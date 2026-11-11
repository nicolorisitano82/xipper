import Darwin
import Foundation
import ServiceManagement
import XipperKit
import XPC

/// Opening a raw disk for reading. A disk image the user attached is theirs and opens directly; a real disk
/// belongs to root, so the privileged helper (`xipper-forensic-helper`, a LaunchDaemon registered with
/// SMAppService) opens it read-only and hands the descriptor over XPC. With `sudo` the CLI opens it itself.
public enum DeviceAccess {
    public static let service = "app.xipper.forensic.helper"
    public static let plist = "app.xipper.forensic.helper.plist"

    public enum Problem: LocalizedError, Equatable {
        case notAllowed(String)
        case helperMissing
        case helperNeedsApproval
        case fullDiskAccess
        case helper(String)
        case open(String, Int32)

        public var errorDescription: String? {
            switch self {
            case .notAllowed(let p): "\(p) is not a raw disk (/dev/rdiskN or /dev/rdiskNsM)"
            case .helperMissing: "the disk helper is not installed: install it from Xipper Forensic › Settings, or run the CLI with sudo"
            case .helperNeedsApproval: "the disk helper waits for approval in System Settings › General › Login Items & Extensions"
            case .fullDiskAccess: "the disk helper needs Full Disk Access (System Settings › Privacy & Security) to read this disk"
            case .helper(let m): "disk helper: \(m)"
            case .open(let p, let e): "\(p): \(String(cString: strerror(e)))"
            }
        }
    }

    /// Only raw whole disks or partitions.
    public static func allowed(_ path: String) -> Bool {
        path.range(of: #"^/dev/rdisk[0-9]+(s[0-9]+)?$"#, options: .regularExpression) != nil
    }

    /// How the device was opened, for the acquisition record.
    public enum Route: String, Sendable { case direct, helper }

    /// Opens `path` (`/dev/rdiskN…`) read-only: directly when permitted, otherwise through the helper.
    public static func open(_ path: String) throws -> (XizForensic.ImageSource, Route) {
        guard allowed(path) else { throw Problem.notAllowed(path) }
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        if fd >= 0 { return (try XizForensic.ImageSource(fd: fd, name: path), .direct) }
        let direct = errno
        guard direct == EACCES || direct == EPERM else { throw Problem.open(path, direct) }
        if geteuid() == 0 && direct == EPERM { throw Problem.fullDiskAccess }
        return (try XizForensic.ImageSource(fd: try viaHelper(path), name: path), .helper)
    }

    /// Asks the helper for a read-only descriptor of `path`.
    static func viaHelper(_ path: String) throws -> Int32 {
        let conn = xpc_connection_create_mach_service(service, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
        xpc_connection_set_event_handler(conn) { _ in }
        xpc_connection_resume(conn)
        defer { xpc_connection_cancel(conn) }
        let msg = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(msg, "open", path)
        let reply = xpc_connection_send_message_with_reply_sync(conn, msg)
        guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else {
            if helperStatus == .requiresApproval { throw Problem.helperNeedsApproval }
            throw Problem.helperMissing
        }
        if let e = xpc_dictionary_get_string(reply, "error") {
            let errno = Int32(xpc_dictionary_get_int64(reply, "errno"))
            if errno == EPERM { throw Problem.fullDiskAccess }
            throw Problem.helper(String(cString: e))
        }
        let fd = xpc_dictionary_dup_fd(reply, "fd")
        guard fd >= 0 else { throw Problem.helper("no descriptor in the reply") }
        return fd
    }

    /// Asks the helper whether it can read this disk (Full Disk Access granted): nil when it can.
    public static func probe(_ path: String) -> Problem? {
        do { close(try viaHelper(path)); return nil } catch let p as Problem { return p } catch { return .helper("\(error)") }
    }

    // MARK: the helper (app only: SMAppService works from the app bundle)

    public enum HelperStatus: Sendable, Equatable { case notInstalled, requiresApproval, enabled, unavailable }

    public static var helperStatus: HelperStatus {
        switch SMAppService.daemon(plistName: plist).status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notInstalled
        default: .unavailable
        }
    }

    /// Registers the helper; macOS then asks the user to allow it in Login Items (`requiresApproval`).
    public static func installHelper() throws {
        do {
            try SMAppService.daemon(plistName: plist).register()
        } catch {
            // "Operation not permitted" with status requiresApproval is the normal first answer.
            if helperStatus != .requiresApproval && helperStatus != .enabled { throw error }
        }
    }

    public static func removeHelper() throws { try SMAppService.daemon(plistName: plist).unregister() }

    public static func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}
