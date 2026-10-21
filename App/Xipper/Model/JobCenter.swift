import AppKit
import Foundation
import Observation
import XipperKit

/// One background operation shown in the jobs HUD.
@MainActor
@Observable
final class Job: Identifiable {
    enum Kind {
        case create(sources: [URL], destination: URL, format: ArchiveFormat, preset: LevelPreset, password: String?)
        case extract(archive: URL, destination: URL?, selection: Set<String>?, password: String?, ratioOverride: Double?)
        case test(archive: URL, password: String?)
    }

    enum State {
        case running
        case finished(String)
        case failed(String)
        case cancelled
        /// Encrypted archive and no (or a wrong) password: the UI asks and calls `retry`.
        case needsPassword(wrong: Bool)
        /// A safety limit stopped the extraction before writing anything (possible zip bomb).
        case needsOverride(String)
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let symbol: String
    var state: State = .running
    var progress: ProgressSnapshot?
    /// Archive or folder produced, for "Mostra nel Finder".
    var output: URL?
    /// Verification details / skipped entries for the result sheet.
    var report: [SkippedEntry] = []
    var verifyOK: Bool?
    fileprivate let cancel = CancellationToken()

    init(kind: Kind) {
        self.kind = kind
        switch kind {
        case let .create(_, dest, _, _, _): title = dest.lastPathComponent; symbol = "arrow.down.right.and.arrow.up.left"
        case let .extract(archive, _, _, _, _): title = archive.lastPathComponent; symbol = "arrow.down.to.line"
        case let .test(archive, _): title = archive.lastPathComponent; symbol = "checkmark.shield"
        }
    }

    var isRunning: Bool { if case .running = state { true } else { false } }

    var verb: String {
        switch kind {
        case .create: "Compressione"
        case .extract: "Estrazione"
        case .test: "Verifica"
        }
    }

    func cancelJob() { cancel.cancel() }
}

/// Runs XipperKit operations off the main thread and publishes their progress.
@MainActor
@Observable
final class JobCenter {
    static let shared = JobCenter()
    private(set) var jobs: [Job] = []
    /// Keeps App Nap from throttling progress updates (and the Mac from idle-sleeping)
    /// while any job runs, as the Finder does during copies.
    @ObservationIgnored private var activity: NSObjectProtocol?

    fileprivate func jobsChanged() {
        let running = jobs.contains(where: \.isRunning)
        if running && activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Xipper: archivio in elaborazione")
        } else if !running, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    @discardableResult
    func start(_ kind: Job.Kind) -> Job {
        let job = Job(kind: kind)
        jobs.append(job)
        jobsChanged()
        run(job, kind)
        return job
    }

    func remove(_ job: Job) {
        jobs.removeAll { $0.id == job.id }
        jobsChanged()
    }
    func clearFinished() { jobs.removeAll { !$0.isRunning } }

    /// Re-runs a job that stopped for a password or a safety override.
    func retry(_ job: Job, password: String? = nil, ratioOverride: Double? = nil) {
        let kind: Job.Kind
        switch job.kind {
        case let .extract(a, d, s, p, r): kind = .extract(archive: a, destination: d, selection: s, password: password ?? p, ratioOverride: ratioOverride ?? r)
        case let .test(a, p): kind = .test(archive: a, password: password ?? p)
        case .create: kind = job.kind
        }
        remove(job)
        start(kind)
    }

    private func run(_ job: Job, _ kind: Job.Kind) {
        let token = job.cancel
        let progress: ProgressHandler = { [weak job] snapshot in
            Task { @MainActor in job?.progress = snapshot }
        }
        Task.detached(priority: .userInitiated) {
            let outcome: Outcome
            do {
                outcome = try Self.perform(kind, progress: progress, cancel: token)
            } catch {
                outcome = .error(error)
            }
            await MainActor.run {
                job.apply(outcome)
                JobCenter.shared.jobsChanged()
            }
        }
    }

    enum Outcome: Sendable {
        case created(WriteReport, URL)
        case extracted(ExtractReport)
        case tested(TestReport)
        case error(any Error)
    }

    nonisolated private static func perform(_ kind: Job.Kind, progress: @escaping ProgressHandler,
                                            cancel: CancellationToken) throws -> Outcome {
        switch kind {
        case let .create(sources, dest, format, preset, password):
            let options = Preferences.createOptions(format: format, preset: preset, password: password)
            let r = try Xipper.create(from: sources, to: dest, options: options, progress: progress, cancel: cancel)
            return .created(r, dest)
        case let .extract(archive, dest, selection, password, ratio):
            var options = Preferences.extractOptions(password: password)
            options.selection = selection
            if let ratio { options.limits.maxCompressionRatio = ratio }
            return .extracted(try Xipper.extract(archive, to: dest, options: options, progress: progress, cancel: cancel))
        case let .test(archive, password):
            return .tested(try Xipper.test(archive, password: password, workload: Preferences.workload, progress: progress, cancel: cancel))
        }
    }
}

extension Job.Kind: @unchecked Sendable {}

extension Job {
    fileprivate func apply(_ outcome: JobCenter.Outcome) {
        switch outcome {
        case let .created(r, url):
            output = url
            let ratio = r.inputBytes > 0 ? Double(r.outputBytes) / Double(r.inputBytes) * 100 : 0
            state = .finished("\(r.entries) elementi · \(r.inputBytes.byteText) → \(r.outputBytes.byteText) (\(Int(ratio.rounded()))%)")
            revealIfWanted()
        case let .extracted(r):
            output = r.destination
            report = r.skipped
            var s = "\(r.files) file · \(r.bytes.byteText)"
            if !r.skipped.isEmpty { s += " · \(r.skipped.count) saltati" }
            state = .finished(s)
            revealIfWanted()
        case let .tested(r):
            report = r.failures
            verifyOK = r.isOK
            state = r.isOK ? .finished("Integro · \(r.entries) elementi verificati") : .failed("\(r.failures.count) problemi trovati")
        case let .error(e):
            switch e as? XipperError {
            case .cancelled?: state = .cancelled
            case .passwordRequired?: state = .needsPassword(wrong: false)
            case .wrongPassword?: state = .needsPassword(wrong: true)
            case let .limitExceeded(m)?: state = .needsOverride(m)
            case let x?: state = .failed(Self.localized(x))
            case nil: state = .failed(e.localizedDescription)
            }
        }
    }

    private func revealIfWanted() {
        guard let output, Preferences.defaults.bool(forKey: PrefKey.revealAfter) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([output])
    }

    /// Italian messages for the errors users can act on; the technical text otherwise.
    static func localized(_ e: XipperError) -> String {
        switch e {
        case let .alreadyExists(p): "Esiste già: \((p as NSString).lastPathComponent)"
        case let .unsupported(m): "Formato non supportato: \(m)"
        case let .corrupt(m): "Archivio danneggiato: \(m)"
        case let .integrity(entry, _): "Dati non integri in \(entry)"
        case let .io(op, path, errno): "Errore di disco (\(op)) \(path.map { ($0 as NSString).lastPathComponent } ?? ""): \(String(cString: strerror(errno)))"
        default: e.description
        }
    }
}
