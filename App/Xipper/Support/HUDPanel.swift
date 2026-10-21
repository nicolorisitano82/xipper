import AppKit
import SwiftUI

/// The jobs HUD when no Xipper window is open (7.1): a floating, non-activating panel in the
/// bottom-right corner of the screen, e.g. for extractions started from the Finder.
@MainActor
enum HUDPanel {
    private static var panel: NSPanel?

    /// Shows or hides the panel according to the jobs and the open windows.
    static func update(_ jobs: [Job]) {
        let windowOpen = NSApp.windows.contains { $0.isVisible && !($0 is NSPanel) && $0.canBecomeMain }
        guard !jobs.isEmpty, !windowOpen else {
            panel?.orderOut(nil)
            return
        }
        let p = panel ?? make()
        panel = p
        if let screen = NSScreen.main?.visibleFrame {
            p.contentView?.layoutSubtreeIfNeeded()
            let size = p.contentView?.fittingSize ?? NSSize(width: 400, height: 120)
            guard size != p.frame.size || !p.isVisible else { return }
            p.setFrame(NSRect(x: screen.maxX - size.width - 16, y: screen.minY + 16, width: size.width, height: size.height), display: true)
        }
        p.orderFrontRegardless()
    }

    private static func make() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
                        styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: JobsHUD().environment(JobCenter.shared).padding(8))
        host.sizingOptions = [.intrinsicContentSize]
        p.contentView = host
        return p
    }
}
