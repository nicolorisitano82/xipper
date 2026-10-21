import Darwin
import Dispatch
import Foundation
import Synchronization

/// How much of the machine a job may use.
///
/// Spike result (SPIKE_FASE0.md §5): E-cores slow down interactive jobs, so foreground
/// work runs on the P-cores only and background work stays on the E-cores.
public enum Workload: Sendable, Equatable {
    /// User is waiting: one worker per performance core, `.userInitiated` QoS.
    case interactive
    /// Finder actions, watched folders: efficiency cores, `.utility` QoS.
    case background
    /// Explicit worker count (tests, CLI `-j`), `.userInitiated` QoS.
    case threads(Int)

    var workerCount: Int {
        switch self {
        case .interactive: return max(1, CPUTopology.performanceCores)
        case .background: return max(2, CPUTopology.efficiencyCores)
        case let .threads(n): return max(1, n)
        }
    }

    var qos: DispatchQoS.QoSClass {
        self == .background ? .utility : .userInitiated
    }
}

public enum CPUTopology {
    public static let performanceCores = sysctlInt("hw.perflevel0.physicalcpu", fallback: ProcessInfo.processInfo.activeProcessorCount)
    public static let efficiencyCores = sysctlInt("hw.perflevel1.physicalcpu", fallback: 0)

    private static func sysctlInt(_ name: String, fallback: Int) -> Int {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : fallback
    }
}

/// Cooperative cancellation shared between the caller and worker threads.
public final class CancellationToken: Sendable {
    private let flag = Atomic<Bool>(false)
    private let pausedFlag = Atomic<Bool>(false)
    public init() {}
    public func cancel() { flag.store(true, ordering: .relaxed) }
    public var isCancelled: Bool { flag.load(ordering: .relaxed) }

    /// Pause (UI_SPEC 7.1): workers wait at their next check until `resume()` or `cancel()`.
    public func pause() { pausedFlag.store(true, ordering: .relaxed) }
    public func resume() { pausedFlag.store(false, ordering: .relaxed) }
    public var isPaused: Bool { pausedFlag.load(ordering: .relaxed) }

    func check() throws {
        while isPaused && !isCancelled { usleep(50_000) }
        if isCancelled { throw XipperError.cancelled }
    }
}

/// Snapshot delivered to progress handlers.
public struct ProgressSnapshot: Sendable {
    public var completedBytes: Int64
    public var totalBytes: Int64
    public var completedEntries: Int
    public var totalEntries: Int
    public var currentEntry: String?
    /// Seconds since the job started.
    public var elapsed: Double

    public var fraction: Double { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0 }
    public var bytesPerSecond: Double { elapsed > 0 ? Double(completedBytes) / elapsed : 0 }
}

public typealias ProgressHandler = @Sendable (ProgressSnapshot) -> Void

/// Thread-safe progress accumulator; calls the handler at most every 50 ms plus once at the end.
final class ProgressTracker: Sendable {
    private let bytes = Atomic<Int64>(0)
    private let entries = Atomic<Int>(0)
    private let lastReport = Atomic<UInt64>(0)
    private let current = Mutex<String?>(nil)
    private let totals: Mutex<(Int64, Int)>
    private let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    private let handler: ProgressHandler?

    init(totalBytes: Int64, totalEntries: Int, handler: ProgressHandler?) {
        totals = Mutex((totalBytes, totalEntries))
        self.handler = handler
    }

    func setTotals(bytes: Int64, entries: Int) { totals.withLock { $0 = (bytes, entries) } }

    func add(bytes n: Int64, entries e: Int = 0, current name: String? = nil) {
        if n != 0 { bytes.add(n, ordering: .relaxed) }
        if e != 0 { entries.add(e, ordering: .relaxed) }
        guard let handler else { return }
        if let name { current.withLock { $0 = name } }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let last = lastReport.load(ordering: .relaxed)
        if now - last < 50_000_000 { return }
        if lastReport.compareExchange(expected: last, desired: now, ordering: .relaxed).exchanged {
            handler(snapshot(now))
        }
    }

    func finish() { handler?(snapshot(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))) }

    var completedBytes: Int64 { bytes.load(ordering: .relaxed) }
    var elapsed: Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e9 }

    private func snapshot(_ now: UInt64) -> ProgressSnapshot {
        let (tb, te) = totals.withLock { $0 }
        return ProgressSnapshot(completedBytes: bytes.load(ordering: .relaxed), totalBytes: tb,
                                completedEntries: entries.load(ordering: .relaxed), totalEntries: te,
                                currentEntry: current.withLock { $0 }, elapsed: Double(now - start) / 1e9)
    }
}

/// Runs `body(i)` for every i in 0..<count on `workload.workerCount` threads.
/// Indices are handed out in order, so callers sort jobs largest-first for balance.
/// The first error stops the remaining work and is rethrown.
///
/// `body` is not `@Sendable`: callers guarantee that iterations touch disjoint state
/// (results go through `Slots`, shared state through locks/atomics).
func parallelFor(_ count: Int, workload: Workload, cancel: CancellationToken?,
                 _ body: (Int) throws -> Void) throws {
    if count == 0 { return }
    let workers = min(workload.workerCount, count)
    if workers == 1 {
        for i in 0..<count { try cancel?.check(); try body(i) }
        return
    }
    let state = LoopState()
    try withoutActuallyEscaping(body) { escapable in
        nonisolated(unsafe) let work = escapable
        DispatchQueue.global(qos: workload.qos).sync {
            DispatchQueue.concurrentPerform(iterations: workers) { _ in
                while !state.failed.load(ordering: .relaxed) {
                    let i = state.next.add(1, ordering: .relaxed).oldValue
                    if i >= count { return }
                    do {
                        try cancel?.check()
                        try work(i)
                    } catch {
                        state.failure.withLock { if $0 == nil { $0 = error } }
                        state.failed.store(true, ordering: .relaxed)
                    }
                }
            }
        }
        if let e = state.failure.withLock({ $0 }) { throw e }
    }
}

/// Shared loop state (atomics must live in a class to be captured by closures).
private final class LoopState: Sendable {
    let next = Atomic<Int>(0)
    let failed = Atomic<Bool>(false)
    let failure = Mutex<Error?>(nil)
}

/// Fixed-size result slots written concurrently at distinct indices.
/// Backed by a raw allocation: Array's mutable-buffer access is not safe from several threads.
final class Slots<T>: @unchecked Sendable {
    private let base: UnsafeMutablePointer<T?>
    let count: Int
    init(_ n: Int) {
        count = n
        base = .allocate(capacity: max(n, 1))
        base.initialize(repeating: nil, count: n)
    }
    deinit {
        base.deinitialize(count: count)
        base.deallocate()
    }
    subscript(i: Int) -> T? {
        get { base[i] }
        set { base[i] = newValue }
    }
    /// Moves a value out, leaving nil (frees memory early).
    func take(_ i: Int) -> T? {
        let v = base[i]
        base[i] = nil
        return v
    }
}
