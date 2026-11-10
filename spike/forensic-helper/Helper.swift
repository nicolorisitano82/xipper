// xipper-forensic helper spike: a root LaunchDaemon registered with SMAppService.
// It does one thing: open a raw disk device read-only and hand the descriptor to the app over XPC.
// The process running as root never writes and never reads disk data itself.
import Foundation
import XPC

let service = "com.xipper.forensic.helper"

func log(_ s: String) { FileHandle.standardError.write(Data("helper: \(s)\n".utf8)) }

/// Only whole raw disks or partitions: /dev/rdiskN or /dev/rdiskNsM.
func allowed(_ path: String) -> Bool {
    path.range(of: #"^/dev/rdisk[0-9]+(s[0-9]+)?$"#, options: .regularExpression) != nil
}

let listener = xpc_connection_create_mach_service(service, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))

// Requirement for clients: read from the environment file next to the plist would be nicer;
// for the spike it is passed by launchd as an argument (see plist).
let requirement = CommandLine.arguments.dropFirst().first

xpc_connection_set_event_handler(listener) { peer in
    guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
    let conn = peer as xpc_connection_t
    if let req = requirement {
        let rc = xpc_connection_set_peer_code_signing_requirement(conn, req)
        if rc != 0 { log("cannot set requirement: \(rc)") }
    }
    xpc_connection_set_event_handler(conn) { msg in
        guard xpc_get_type(msg) == XPC_TYPE_DICTIONARY else {
            if msg === XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT { log("peer rejected: code signing requirement") }
            return
        }
        guard let reply = xpc_dictionary_create_reply(msg) else { return }
        xpc_dictionary_set_int64(reply, "uid", Int64(getuid()))
        xpc_dictionary_set_int64(reply, "euid", Int64(geteuid()))
        xpc_dictionary_set_int64(reply, "pid", Int64(getpid()))
        let path = xpc_dictionary_get_string(msg, "open").map { String(cString: $0) }
        if let path {
            if !allowed(path) {
                xpc_dictionary_set_string(reply, "error", "path not allowed")
            } else {
                let fd = open(path, O_RDONLY)
                if fd < 0 {
                    xpc_dictionary_set_string(reply, "error", "open: \(String(cString: strerror(errno)))")
                } else {
                    xpc_dictionary_set_fd(reply, "fd", fd)   // dup'd into the message
                    close(fd)
                    log("opened \(path) read-only for pid \(xpc_connection_get_pid(conn))")
                }
            }
        }
        xpc_connection_send_message(conn, reply)
    }
    xpc_connection_resume(conn)
}
xpc_connection_resume(listener)
log("listening on \(service), uid \(getuid())")
dispatchMain()
