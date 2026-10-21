#if DEBUG
import AppKit
import Foundation
import XipperKit

/// Debug-only launch hooks for visual checks without UI scripting:
/// XIPPER_DEMO_EXTRACT=<archive>, XIPPER_DEMO_TEST=<archive>, XIPPER_DEMO_CREATE=<folder>,
/// XIPPER_DEMO_DARK=1 (forces dark appearance).
@MainActor
enum DebugHooks {
    private static var done = false

    static func run(_ jobs: JobCenter) {
        guard !done else { return }
        done = true
        let env = ProcessInfo.processInfo.environment
        if env["XIPPER_DEMO_DARK"] != nil { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if let p = env["XIPPER_DEMO_CREATE"] {
            let src = URL(fileURLWithPath: p)
            jobs.start(.create(sources: [src], destination: uniqueURL(src.deletingLastPathComponent().appendingPathComponent(src.lastPathComponent + ".tar.zst")),
                               format: .tarZstd, preset: .best, password: nil))
        }
        if let p = env["XIPPER_DEMO_EXTRACT"] {
            jobs.start(.extract(ExtractRequest(archive: URL(fileURLWithPath: p))))
        }
        if let spec = env["XIPPER_DEMO_CONFLICT"] {  // "<archive>|<existing folder>"
            let parts = spec.split(separator: "|").map(String.init)
            jobs.start(.extract(ExtractRequest(archive: URL(fileURLWithPath: parts[0]), destination: URL(fileURLWithPath: parts[1]),
                                               mode: .into, overwrite: .ask, reveal: false)))
        }
        if let p = env["XIPPER_DEMO_TEST"] {
            jobs.start(.test(archive: URL(fileURLWithPath: p), password: nil))
        }
    }
}
#endif
