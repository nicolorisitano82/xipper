// xipper-forensic-helper: the only part of Xipper Forensic that runs as root (a LaunchDaemon registered
// with SMAppService from the app). It does one thing: open a raw disk read-only and hand the descriptor
// to the app or the CLI over XPC. It never writes and never reads disk data itself.
// Clients must satisfy the code-signing requirement given as the first argument (set at build time:
// the app's or the CLI's identifier, signed with the same certificate).
import Darwin
import Foundation
import os
@preconcurrency import XPC

let service = "app.xipper.forensic.helper"
let log = Logger(subsystem: service, category: "open")

/// Only whole raw disks or partitions: /dev/rdiskN or /dev/rdiskNsM.
func allowed(_ path: String) -> Bool {
    path.range(of: #"^/dev/rdisk[0-9]+(s[0-9]+)?$"#, options: .regularExpression) != nil
}

guard let requirement = CommandLine.arguments.dropFirst().first, !requirement.isEmpty else {
    log.error("no client requirement: refusing to start")
    exit(78)
}

let listener = xpc_connection_create_mach_service(service, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
xpc_connection_set_event_handler(listener) { peer in
    guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
    let conn = peer as xpc_connection_t
    guard xpc_connection_set_peer_code_signing_requirement(conn, requirement) == 0 else {
        xpc_connection_cancel(conn)
        return
    }
    xpc_connection_set_event_handler(conn) { msg in
        guard xpc_get_type(msg) == XPC_TYPE_DICTIONARY, let reply = xpc_dictionary_create_reply(msg) else {
            if msg === XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT { log.error("client refused: code signing requirement") }
            return
        }
        xpc_dictionary_set_string(reply, "version", "1")
        if let raw = xpc_dictionary_get_string(msg, "open") {
            let path = String(cString: raw)
            if !allowed(path) {
                xpc_dictionary_set_string(reply, "error", "path not allowed")
            } else {
                let fd = open(path, O_RDONLY | O_CLOEXEC)
                if fd < 0 {
                    let e = errno
                    xpc_dictionary_set_string(reply, "error", "open \(path): \(String(cString: strerror(e)))")
                    xpc_dictionary_set_int64(reply, "errno", Int64(e))
                } else {
                    xpc_dictionary_set_fd(reply, "fd", fd)
                    close(fd)
                    log.notice("opened \(path, privacy: .public) read-only for pid \(xpc_connection_get_pid(conn))")
                }
            }
        }
        xpc_connection_send_message(conn, reply)
    }
    xpc_connection_resume(conn)
}
xpc_connection_resume(listener)
dispatchMain()
