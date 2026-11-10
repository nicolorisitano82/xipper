// xipper-forensic helper spike, app side (run the executable inside the .app from Terminal).
//   status | register | unregister | open /dev/rdiskN [bytes]
import Foundation
import ServiceManagement
import XPC
import CryptoKit

let plistName = "com.xipper.forensic.helper.plist"
let service = "com.xipper.forensic.helper"
let daemon = SMAppService.daemon(plistName: plistName)

func name(_ s: SMAppService.Status) -> String {
    switch s {
    case .notRegistered: "notRegistered"
    case .enabled: "enabled"
    case .requiresApproval: "requiresApproval"
    case .notFound: "notFound"
    @unknown default: "unknown(\(s.rawValue))"
    }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first ?? "status" {
case "status":
    print("status:", name(daemon.status))
case "register":
    do { try daemon.register(); print("registered, status:", name(daemon.status)) }
    catch { print("register failed:", error, "status:", name(daemon.status)); exit(1) }
case "unregister":
    do { try daemon.unregister(); print("unregistered, status:", name(daemon.status)) }
    catch { print("unregister failed:", error); exit(1) }
case "settings":
    SMAppService.openSystemSettingsLoginItems()
case "open":
    let path = args.count > 1 ? args[1] : "/dev/rdisk0"
    let count = args.count > 2 ? Int(args[2]) ?? 1 << 20 : 1 << 20
    // Without the helper first: show that a normal user cannot open it.
    let direct = open(path, O_RDONLY)
    print("direct open as uid \(getuid()):", direct >= 0 ? "OK (!)" : String(cString: strerror(errno)))
    if direct >= 0 { close(direct) }

    let conn = xpc_connection_create_mach_service(service, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
    xpc_connection_set_event_handler(conn) { _ in }
    xpc_connection_resume(conn)
    let msg = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_string(msg, "open", path)
    let reply = xpc_connection_send_message_with_reply_sync(conn, msg)
    guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else {
        print("XPC error:", xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION).map { String(cString: $0) } ?? "?")
        exit(1)
    }
    print("helper uid \(xpc_dictionary_get_int64(reply, "uid")) euid \(xpc_dictionary_get_int64(reply, "euid")) pid \(xpc_dictionary_get_int64(reply, "pid"))")
    if let e = xpc_dictionary_get_string(reply, "error") { print("helper error:", String(cString: e)); exit(1) }
    let fd = xpc_dictionary_dup_fd(reply, "fd")
    guard fd >= 0 else { print("no fd in reply"); exit(1) }
    // Read in the unprivileged app with the root-opened descriptor.
    var buf = [UInt8](repeating: 0, count: count)
    let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, 0) }
    print("read \(n) bytes as uid \(getuid()) through the helper's fd")
    if n > 0 { print("sha256:", SHA256.hash(data: buf[0..<n]).map { String(format: "%02x", $0) }.joined()) }
    // The descriptor is read-only: writing must fail.
    var one: UInt8 = 0
    let w = pwrite(fd, &one, 1, 0)
    print("write attempt:", w < 0 ? "refused (\(String(cString: strerror(errno))))" : "WROTE (!)")
    close(fd)
default:
    print("usage: status | register | unregister | settings | open /dev/rdiskN [bytes]")
}
