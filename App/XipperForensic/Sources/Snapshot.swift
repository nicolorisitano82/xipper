#if DEBUG
import AppKit
import ForensicKit
import SwiftUI
import XipperKit

/// Debug builds only: `XipperForensic --snapshot OUT CASE.xfcase [-AppleLanguages '(it)']` draws every
/// screen with that case into OUT/*.png and quits, to check layout and wording without clicking.
@MainActor
enum Snapshot {
    static func runIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 2 < args.count else { return }
        let out = URL(fileURLWithPath: args[i + 1])
        let caseURL = URL(fileURLWithPath: args[i + 2])
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        Task { @MainActor in
            await shoot(out: out, caseURL: caseURL)
            exit(0)
        }
    }

    static func shoot(out: URL, caseURL: URL) async {
        let prefs = Prefs.shared
        let model = CaseModel(url: caseURL)
        await model.verifyCase()
        await render(WelcomeView(), CGSize(width: 700, height: 540), out, "1-welcome")
        await render(NewCaseView(), CGSize(width: 520, height: 620), out, "2-new-case")
        await render(CaseWindow(url: caseURL), CGSize(width: 1100, height: 720), out, "3-case")
        await render(CaseSummaryView(model: model), CGSize(width: 860, height: 640), out, "4-summary")
        await render(CaseLogView(model: model), CGSize(width: 980, height: 520), out, "5-log")
        for (n, item) in model.items.enumerated() {
            await render(EvidenceView(model: model, item: item), CGSize(width: 900, height: 720), out, "6-evidence-\(n + 1)")
        }
        if let first = model.items.first {
            await render(CustodySheet(model: model, id: first.id), CGSize(width: 500, height: 460), out, "7-custody")
            await render(VerifyView(archive: first.evidence.archive), CGSize(width: 760, height: 640), out, "8-verify", wait: 2.5)
        }
        // The wizard, step by step, with sample answers (nothing is acquired).
        for step in Acquisition.Step.allCases {
            let a = Acquisition(model: model)
            a.description = "Chiavetta USB"
            a.deviceModel = "SanDisk Ultra 64 GB"
            a.serial = "4C530001"
            a.files = model.items.first.map { [$0.evidence.folder] } ?? []
            // The disk source with a disk image attached (the first one listed), when there is one.
            await a.refreshDisks()
            if let d = a.disks.first(where: { $0.isDiskImage && !$0.partitions.isEmpty }) {
                a.choose(d.partitions[0].bsd)
            } else {
                a.kind = .files
            }
            a.step = step
            if step == .checks { await a.runChecks() }
            if step == .running {
                a.progress = ProgressSnapshot(completedBytes: 40_300_000_000, totalBytes: 64_000_000_000, completedEntries: 0, totalEntries: 1,
                                              currentEntry: nil, elapsed: 98)
                a.unreadable = [.init(offset: 21_000_000_000, length: 4096), .init(offset: 21_000_100_000, length: 512)]
            }
            if step == .done, let i = model.items.first {
                a.id = i.id
                a.finish()
            }
            await render(WizardSnapshot(a: a), CGSize(width: 720, height: 600), out, "9-wizard-\(step.rawValue + 1)")
        }
        _ = prefs
    }

    static func render<V: View>(_ view: V, _ size: CGSize, _ out: URL, _ name: String, wait: Double = 0.6) async {
        let host = NSHostingView(rootView: view.environment(Prefs.shared).background(Color(nsColor: .windowBackgroundColor)))
        let w = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20000, y: 0), size: size), styleMask: [.titled], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
        w.contentView = host
        w.orderBack(nil)
        try? await Task.sleep(for: .seconds(wait))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
        w.orderOut(nil)
    }
}

/// The wizard's body for a given state (the real sheet owns its state).
struct WizardSnapshot: View {
    let a: Acquisition
    var body: some View {
        VStack(spacing: 0) {
            StepBar(step: a.step)
            Divider()
            Group {
                switch a.step {
                case .item: ItemStep(a: a)
                case .source: SourceStep(a: a)
                case .options: OptionsStep(a: a)
                case .checks: ChecksStep(a: a)
                case .running: RunningStep(a: a)
                case .done: DoneStep(a: a)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 720, height: 600)
    }
}
#endif
