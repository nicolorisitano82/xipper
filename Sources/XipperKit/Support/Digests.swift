import CryptoKit
import Synchronization

/// SHA-256 digests gathered by parallel workers during a test (SHA256SUMS manifests).
final class DigestCollector: Sendable {
    private let map = Mutex<[String: String]>([:])

    func add(_ path: String, _ hasher: SHA256) {
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        map.withLock { $0[path] = hex }
    }

    var all: [String: String] { map.withLock { $0 } }
}
