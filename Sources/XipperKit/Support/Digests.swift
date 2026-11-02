import Synchronization

/// Digests gathered by parallel workers during a test (SHA256SUMS manifests, hashes of an
/// archive's content), several algorithms in one pass.
final class DigestCollector: Sendable {
    let algorithms: [ChecksumAlgorithm]
    private let map = Mutex<[String: [ChecksumAlgorithm: String]]>([:])

    init(_ algorithms: [ChecksumAlgorithm] = [.sha256]) { self.algorithms = algorithms }

    func hasher() -> MultiHasher { MultiHasher(Set(algorithms)) }

    func add(_ path: String, _ hasher: MultiHasher) {
        let d = hasher.finalize()
        map.withLock { $0[path] = d }
    }

    /// The first algorithm's digest, per path.
    var all: [String: String] { map.withLock { $0 }.compactMapValues { $0[algorithms[0]] } }
    var everything: [String: [ChecksumAlgorithm: String]] { map.withLock { $0 } }
}
