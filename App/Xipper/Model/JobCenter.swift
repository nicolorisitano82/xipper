import AppKit
import Foundation
import Observation
import XipperKit

/// Everything the extraction sheet (3.2) can choose.
struct ExtractRequest: @unchecked Sendable {
    var archive: URL
    /// nil = next to the archive.
    var destination: URL?
    var mode: ExtractionMode = .smart
    var selection: Set<String>?
    var flatten = false
    var overwrite: OverwritePolicy = .keepBoth
    /// nil = the "reveal in Finder" preference.
    var reveal: Bool?
    var password: String?
    var ratioOverride: Double?
}

/// One background operation shown in the jobs HUD.
@MainActor
@Observable
final class Job: Identifiable {
    enum Kind {
        case create(sources: [URL], destination: URL, format: ArchiveFormat, preset: LevelPreset, password: String?)
        case extract(ExtractRequest)
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
    /// Waiting for the user to resolve a "file already exists" conflict.
    var paused = false
    /// Final numbers of a creation, for the completion panel (2.5).
    var writeReport: WriteReport?
    /// Why a job failed, when the UI can say something specific (2.8).
    var failure: Failure?
    /// Save the password in the Keychain once the job succeeds (4.2).
    var rememberPassword = false
    /// The password came from the Keychain: a wrong one is forgotten, not retried.
    var passwordFromVault = false

    /// The archive the job reads, or the one it creates.
    var archive: URL? {
        switch kind {
        case let .create(_, dest, _, _, _): output ?? dest
        case let .extract(r): r.archive
        case let .test(a, _): a
        }
    }

    var password: String? {
        switch kind {
        case let .create(_, _, _, _, p): p
        case let .extract(r): r.password
        case let .test(_, p): p
        }
    }

    enum Failure: Equatable {
        case diskFull(available: Int64?)
        case permission
        case readOnly
        case volumeGone
        case other
    }

    /// Where the job writes (for free-space checks and "Salva altrove").
    var destinationFolder: URL? {
        switch kind {
        case let .create(_, dest, _, _, _): dest.deletingLastPathComponent()
        case let .extract(r): r.destination ?? r.archive.deletingLastPathComponent()
        case .test: nil
        }
    }
    let started = Date()
    fileprivate let cancel = CancellationToken()

    /// Speed averaged over the last second, refreshed at most 4 times a second (2.4).
    private(set) var smoothedSpeed: Double = 0
    @ObservationIgnored private var samples: [(Date, Int64)] = []
    @ObservationIgnored private var lastSpeedUpdate = Date.distantPast

    func record(_ p: ProgressSnapshot) {
        progress = p
        let now = Date()
        samples.append((now, p.completedBytes))
        // Keep one sample at least a second old as the reference, even across encoder stalls.
        while samples.count > 2 && now.timeIntervalSince(samples[1].0) >= 1 { samples.removeFirst() }
        JobFeedback.update(JobCenter.shared.jobs)
        guard now.timeIntervalSince(lastSpeedUpdate) >= 0.25, let first = samples.first else { return }
        lastSpeedUpdate = now
        let dt = now.timeIntervalSince(first.0)
        smoothedSpeed = dt > 0.05 ? Double(p.completedBytes - first.1) / dt : p.bytesPerSecond
    }

    /// Seconds left at the current speed, if meaningful.
    var eta: Double? {
        guard let p = progress, p.totalBytes > 0, smoothedSpeed > 0 else { return nil }
        return Double(p.totalBytes - p.completedBytes) / smoothedSpeed
    }

    init(kind: Kind) {
        self.kind = kind
        switch kind {
        case let .create(_, dest, _, _, _): title = dest.lastPathComponent; symbol = "arrow.down.right.and.arrow.up.left"
        case let .extract(r): title = r.archive.lastPathComponent; symbol = "arrow.down.to.line"
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
    /// Jobs shown in a window's own panel (2.4): the HUD does not repeat them.
    var focused = Set<UUID>()
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
        JobFeedback.update(jobs, force: true)
    }

    @discardableResult
    func start(_ kind: Job.Kind) -> Job {
        let job = Job(kind: kind)
        jobs.append(job)
        jobsChanged()
        run(job, kind)
        return job
    }

    /// "Salva altrove…": runs the same creation into another folder.
    func relocate(_ job: Job, to folder: URL) {
        guard case let .create(sources, dest, format, preset, password) = job.kind else { return }
        remove(job)
        // The panel closes: the new job is followed in the HUD.
        focused.remove(job.id)
        let new = start(.create(sources: sources, destination: uniqueURL(folder.appendingPathComponent(dest.lastPathComponent)),
                                format: format, preset: preset, password: password))
        new.rememberPassword = job.rememberPassword
    }

    func remove(_ job: Job) {
        jobs.removeAll { $0.id == job.id }
        jobsChanged()
    }
    func clearFinished() { jobs.removeAll { !$0.isRunning } }

    /// Re-runs a job that stopped for a password or a safety override.
    func retry(_ job: Job, password: String? = nil, ratioOverride: Double? = nil, remember: Bool = false, fromVault: Bool = false) {
        let kind: Job.Kind
        switch job.kind {
        case var .extract(r):
            if let password { r.password = password }
            if let ratioOverride { r.ratioOverride = ratioOverride }
            kind = .extract(r)
        case let .test(a, p): kind = .test(archive: a, password: password ?? p)
        case .create: kind = job.kind
        }
        remove(job)
        let new = start(kind)
        new.rememberPassword = remember || job.rememberPassword
        new.passwordFromVault = fromVault
    }

    private func run(_ job: Job, _ kind: Job.Kind) {
        let token = job.cancel
        let progress: ProgressHandler = { [weak job] snapshot in
            Task { @MainActor in job?.record(snapshot) }
        }
        let pause: @Sendable (Bool) -> Void = { [weak job] on in
            Task { @MainActor in job?.paused = on }
        }
        Task.detached(priority: .userInitiated) {
            let outcome: Outcome
            do {
                outcome = try Self.perform(kind, progress: progress, pause: pause, cancel: token)
            } catch {
                outcome = .error(error)
            }
            await MainActor.run {
                job.apply(outcome)
                JobCenter.shared.jobsChanged()
                JobFeedback.notifyEnd(of: job)
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
                                            pause: @escaping @Sendable (Bool) -> Void,
                                            cancel: CancellationToken) throws -> Outcome {
        switch kind {
        case let .create(sources, dest, format, preset, password):
            let options = Preferences.createOptions(format: format, preset: preset, password: password)
            let r = try Xipper.create(from: sources, to: dest, options: options, progress: progress, cancel: cancel)
            return .created(r, dest)
        case let .extract(r):
            var options = Preferences.extractOptions(password: r.password)
            options.selection = r.selection
            options.flatten = r.flatten
            options.overwrite = r.overwrite
            options.trashReplacedFiles = true
            if let ratio = r.ratioOverride { options.limits.maxCompressionRatio = ratio }
            if let dest = r.destination, r.mode == .into {
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                if r.overwrite == .ask {
                    let planned = (try? Xipper.plannedConflicts(r.archive, into: dest, selection: r.selection, flatten: r.flatten).count) ?? 0
                    let remaining = ConflictCounter(planned)
                    options.conflictHandler = { conflict in
                        pause(true)
                        defer { pause(false) }
                        return ConflictPrompt.ask(conflict, folder: dest.lastPathComponent, others: remaining.next())
                    }
                }
            }
            return .extracted(try Xipper.extract(r.archive, to: r.destination, mode: r.mode, options: options, progress: progress, cancel: cancel))
        case let .test(archive, password):
            return .tested(try Xipper.test(archive, password: password, workload: Preferences.workload, progress: progress, cancel: cancel))
        }
    }
}

extension Job.Kind: @unchecked Sendable {}

/// Conflicts still expected after the current one ("Applica agli altri N conflitti").
final class ConflictCounter: @unchecked Sendable {
    private var left: Int
    private let lock = NSLock()
    init(_ total: Int) { left = total }
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        left = max(0, left - 1)
        return left
    }
}

extension Job {
    fileprivate func apply(_ outcome: JobCenter.Outcome) {
        defer {
            if rememberPassword, case .finished = state, let pw = password, let archive { PasswordVault.save(pw, for: archive) }
        }
        switch outcome {
        case let .created(r, url):
            output = url
            writeReport = r
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
            case .passwordRequired?:
                state = .needsPassword(wrong: false)
                if let archive, PasswordVault.has(archive) {
                    Task {
                        if let pw = await PasswordVault.password(for: archive) {
                            JobCenter.shared.retry(self, password: pw, fromVault: true)
                        }
                    }
                }
            case .wrongPassword?:
                if passwordFromVault, let archive { PasswordVault.remove(for: archive) }
                state = .needsPassword(wrong: true)
            case let .limitExceeded(m)?: state = .needsOverride(m)
            case let .insufficientSpace(needed, available)?:
                failure = .diskFull(available: available)
                state = .failed("Spazio su disco insufficiente: servono \(needed.byteText), liberi \(max(0, available).byteText)")
            case let .io(_, _, err)? where [ENOSPC, EDQUOT].contains(err):
                failure = .diskFull(available: freeSpace)
                state = .failed("Spazio su disco esaurito")
            case let .io(_, path, err)? where [EACCES, EPERM].contains(err):
                failure = .permission
                state = .failed("Permessi insufficienti\(path.map { " per \(($0 as NSString).lastPathComponent)" } ?? "")")
            case .io(_, _, EROFS)?:
                failure = .readOnly
                state = .failed("Il volume di destinazione è in sola lettura")
            case let .io(_, _, err)? where [ENXIO, ENODEV, EIO].contains(err):
                failure = .volumeGone
                state = .failed("Il volume non è più disponibile")
            case let x?:
                failure = .other
                state = .failed(Self.localized(x))
            case nil: state = .failed(e.localizedDescription)
            }
        }
    }

    /// Free space where the job writes ("important usage" capacity, as the Finder shows).
    var freeSpace: Int64? {
        guard let folder = destinationFolder,
              let v = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else { return nil }
        return v.volumeAvailableCapacityForImportantUsage
    }

    private func revealIfWanted() {
        var wanted = Preferences.defaults.bool(forKey: PrefKey.revealAfter)
        if case let .extract(r) = kind, let explicit = r.reveal { wanted = explicit }
        // A job shown in its own panel offers "Mostra nel Finder" instead.
        if JobCenter.shared.focused.contains(id) { wanted = false }
        guard let output, wanted else { return }
        NSWorkspace.shared.activateFileViewerSelecting([output])
    }

    /// Italian messages for the errors users can act on; the technical text otherwise.
    nonisolated static func localized(_ e: XipperError) -> String {
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
