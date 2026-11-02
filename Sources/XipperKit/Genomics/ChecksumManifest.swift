import CryptoKit
import CXipShims
import Foundation

/// Checksum algorithms with their GA4GH DRS / IANA "Named Information" names.
public enum ChecksumAlgorithm: String, CaseIterable, Sendable, Codable {
    case sha256 = "sha-256"
    case sha512 = "sha-512"
    case sha1 = "sha-1"
    case md5
    case crc32c
    /// GA4GH refget/VRS digest: base64url of the first 24 bytes of SHA-512.
    case sha512t24u
    case sha3_256 = "sha3-256"
    case blake3
    /// XXH3 64-bit and 128-bit (seed 0): fast, not cryptographic.
    case xxh3 = "xxh3-64"
    case xxh128
    /// The CRC-32 of ZIP, gzip and 7z (crc32c above is the Castagnoli one).
    case crc32

    /// Accepts DRS/IANA names and common spellings: `sha256`, `SHA-256`, `sha2-256`, `MD5`, `crc-32c`…
    public init?(name: String) {
        let n = name.lowercased().replacingOccurrences(of: "_", with: "-").trimmingCharacters(in: .whitespaces)
        switch n {
        case "sha-256", "sha256", "sha2-256": self = .sha256
        case "sha-512", "sha512", "sha2-512": self = .sha512
        case "sha-1", "sha1": self = .sha1
        case "md5", "md-5": self = .md5
        case "crc32c", "crc-32c": self = .crc32c
        case "sha512t24u", "ga4gh": self = .sha512t24u
        case "sha3-256", "sha3", "sha-3-256": self = .sha3_256
        case "blake3", "b3": self = .blake3
        case "xxh3-64", "xxh3", "xxh64", "xxh3-64bits": self = .xxh3
        case "xxh128", "xxh3-128": self = .xxh128
        case "crc32", "crc-32", "crc": self = .crc32
        default: return nil
        }
    }

    /// Characters of the textual digest (hex, or base64url for sha512t24u).
    var digestLength: Int {
        switch self {
        case .sha256: 64
        case .sha512: 128
        case .sha1: 40
        case .md5: 32
        case .crc32c: 8
        case .sha512t24u: 32
        case .sha3_256, .blake3: 64
        case .xxh3: 16
        case .xxh128: 32
        case .crc32: 8
        }
    }

    public var title: String {
        switch self {
        case .sha256: "SHA-256"
        case .sha512: "SHA-512"
        case .sha1: "SHA-1"
        case .md5: "MD5"
        case .crc32c: "CRC-32C"
        case .sha512t24u: "sha512t24u"
        case .sha3_256: "SHA3-256"
        case .blake3: "BLAKE3"
        case .xxh3: "XXH3-64"
        case .xxh128: "XXH3-128"
        case .crc32: "CRC-32"
        }
    }

    /// Resistant to deliberate collisions: fit to show that a file was not swapped. MD5, SHA-1,
    /// the CRCs and XXH3 only catch accidental damage.
    public var isCryptographic: Bool { [.sha256, .sha512, .sha3_256, .blake3, .sha512t24u].contains(self) }

    /// Tag of a BSD-style line (`SHA256 (file) = …`, as `shasum --tag`, `b3sum --tag`, `openssl dgst`).
    public var bsdTag: String {
        switch self {
        case .sha256: "SHA256"
        case .sha512: "SHA512"
        case .sha1: "SHA1"
        case .md5: "MD5"
        case .crc32c: "CRC32C"
        case .sha512t24u: "SHA512T24U"
        case .sha3_256: "SHA3-256"
        case .blake3: "BLAKE3"
        case .xxh3: "XXH3"
        case .xxh128: "XXH128"
        case .crc32: "CRC32"
        }
    }

    /// Conventional name of a list file (`sha256sum > SHA256SUMS`, `b3sum > B3SUMS`).
    public var listName: String {
        switch self {
        case .sha256: "SHA256SUMS"
        case .sha512: "SHA512SUMS"
        case .sha1: "SHA1SUMS"
        case .md5: "MD5SUMS"
        case .crc32c: "CRC32CSUMS"
        case .sha512t24u: "SHA512T24USUMS"
        case .sha3_256: "SHA3-256SUMS"
        case .blake3: "B3SUMS"
        case .xxh3: "XXH64SUMS"
        case .xxh128: "XXH128SUMS"
        case .crc32: "CRC32SUMS"
        }
    }

    /// Algorithm of a coreutils-style manifest, from its file name (`x.sha256`, `md5sum.txt`, `MD5SUMS`…).
    public static func forManifestName(_ name: String) -> ChecksumAlgorithm? {
        let n = (name as NSString).lastPathComponent.lowercased()
        let ext = (n as NSString).pathExtension
        if let a = ChecksumAlgorithm(name: ext.hasSuffix("sum") ? String(ext.dropLast(3)) : ext) { return a }
        if let a = ChecksumAlgorithm(name: ext.hasSuffix("sums") ? String(ext.dropLast(4)) : ext) { return a }
        let base = (n as NSString).deletingPathExtension
        if base.hasPrefix("b3sum") || ext == "b3" { return .blake3 }
        if let a = allCases.first(where: { $0.listName.lowercased() == n }) { return a }
        for a in allCases {
            let short = a.rawValue.replacingOccurrences(of: "-", with: "")
            if base == short + "sum" || base == short + "sums" || n.hasPrefix(short + "sum") { return a }
        }
        return nil
    }
}

public struct ManifestEntry: Sendable, Equatable {
    /// POSIX path relative to the manifest's folder.
    public var path: String
    public var size: Int64?
    public var checksums: [ChecksumAlgorithm: String]
}

public struct ManifestCreateReport: Sendable {
    public var manifest: URL
    public var algorithms: [ChecksumAlgorithm]
    public var entries: [ManifestEntry]
    public var bytes: Int64
    public var elapsed: Double
}

public struct ManifestVerifyReport: Sendable {
    public struct Mismatch: Sendable { public var path: String; public var algorithm: ChecksumAlgorithm; public var expected: String; public var actual: String }
    public var manifest: URL
    public var checked: Int
    public var bytes: Int64
    public var mismatches: [Mismatch]
    public var missing: [String]
    /// Entries with absolute paths, `..`, or refused by the caller's path policy.
    public var refused: [String]
    /// Size recorded in a JSON manifest differs from the file.
    public var sizeMismatches: [String]
    /// Checksum types in the manifest that Xipper does not compute (e.g. `etag`).
    public var skippedTypes: [String]
    public var elapsed: Double
    public var isOK: Bool { mismatches.isEmpty && missing.isEmpty && refused.isEmpty && sizeMismatches.isEmpty && checked > 0 }
}

/// Computes several digests in one read pass; each algorithm runs on its own core.
final class MultiHasher: @unchecked Sendable {
    private final class Lane: @unchecked Sendable {
        var sha256: SHA256?
        var sha512: SHA512?
        var sha1: Insecure.SHA1?
        var md5: Insecure.MD5?
        var crc: UInt32?
        var sha3: SHA3_256?
        var blake3: xs_blake3?
        var xxh: UnsafeMutableRawPointer?
        var zipCRC: UInt32?
        deinit { if let xxh { xs_xxh3_free(xxh) } }
        /// BLAKE3 subtrees hashed on all cores: 1 MiB (1024 chunks) each.
        static let subtree = 1 << 20
        func update(_ b: UnsafeRawBufferPointer, more: Bool) {
            sha256?.update(bufferPointer: b)
            sha512?.update(bufferPointer: b)
            sha1?.update(bufferPointer: b)
            md5?.update(bufferPointer: b)
            sha3?.update(bufferPointer: b)
            guard let p = b.baseAddress, b.count > 0 else { return }
            if let c = crc { crc = xs_crc32c(c, p.assumingMemoryBound(to: UInt8.self), b.count) }
            if blake3 != nil {
                // Whole subtrees, never the last bytes of the input (the root is hashed differently).
                let n = b.count / Self.subtree
                if more, n >= 2, b.count % Self.subtree == 0, xs_blake3_at_boundary(&blake3!, UInt64(Self.subtree / 1024)) != 0 {
                    let start = blake3!.chunk_counter, chunks = UInt64(Self.subtree / 1024)
                    var cvs = [UInt32](repeating: 0, count: n * 8)
                    cvs.withUnsafeMutableBufferPointer { out in
                        nonisolated(unsafe) let out = out, src = p
                        DispatchQueue.concurrentPerform(iterations: n) { i in
                            xs_blake3_subtree(src.assumingMemoryBound(to: UInt8.self) + i * Self.subtree, chunks, start + UInt64(i) * chunks,
                                              out.baseAddress! + i * 8)
                        }
                    }
                    for i in 0..<n { cvs.withUnsafeBufferPointer { xs_blake3_push_subtree(&blake3!, $0.baseAddress! + i * 8, chunks) } }
                } else {
                    xs_blake3_update(&blake3!, p, b.count)
                }
            }
            if let xxh { xs_xxh3_update(xxh, p, b.count) }
            if let c = zipCRC { zipCRC = CRC32.update(c, b) }
        }
    }

    private let lanes: [Lane]
    private let algorithms: Set<ChecksumAlgorithm>

    init(_ algorithms: Set<ChecksumAlgorithm>) {
        self.algorithms = algorithms
        var lanes: [Lane] = []
        func lane(_ setup: (Lane) -> Void) { let l = Lane(); setup(l); lanes.append(l) }
        if algorithms.contains(.sha256) { lane { $0.sha256 = SHA256() } }
        if algorithms.contains(.sha512) || algorithms.contains(.sha512t24u) { lane { $0.sha512 = SHA512() } }
        if algorithms.contains(.sha1) { lane { $0.sha1 = Insecure.SHA1() } }
        if algorithms.contains(.md5) { lane { $0.md5 = Insecure.MD5() } }
        if algorithms.contains(.crc32c) { lane { $0.crc = 0 } }
        if algorithms.contains(.sha3_256) { lane { $0.sha3 = SHA3_256() } }
        if algorithms.contains(.blake3) { lane { var h = xs_blake3(); xs_blake3_init(&h); $0.blake3 = h } }
        // One XXH3 state gives both widths.
        if algorithms.contains(.xxh3) || algorithms.contains(.xxh128) { lane { $0.xxh = xs_xxh3_new() } }
        if algorithms.contains(.crc32) { lane { $0.zipCRC = 0 } }
        self.lanes = lanes
    }

    /// `more`: more data follows this buffer (lets BLAKE3 hash it as parallel subtrees).
    func update(_ b: UnsafeRawBufferPointer, more: Bool = false) {
        if lanes.count == 1 { lanes[0].update(b, more: more); return }
        nonisolated(unsafe) let buffer = b
        DispatchQueue.concurrentPerform(iterations: lanes.count) { lanes[$0].update(buffer, more: more) }
    }

    func finalize() -> [ChecksumAlgorithm: String] {
        func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }
        var out: [ChecksumAlgorithm: String] = [:]
        for l in lanes {
            if let h = l.sha256 { out[.sha256] = hex(h.finalize()) }
            if let h = l.sha512 {
                let d = Array(h.finalize())
                if algorithms.contains(.sha512) { out[.sha512] = hex(d) }
                if algorithms.contains(.sha512t24u) {
                    out[.sha512t24u] = Data(d.prefix(24)).base64EncodedString()
                        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                }
            }
            if let h = l.sha1 { out[.sha1] = hex(h.finalize()) }
            if let h = l.md5 { out[.md5] = hex(h.finalize()) }
            if let c = l.crc { out[.crc32c] = String(format: "%08x", c) }
            if let h = l.sha3 { out[.sha3_256] = hex(h.finalize()) }
            if var h = l.blake3 {
                var d = [UInt8](repeating: 0, count: 32)
                xs_blake3_final(&h, &d)
                out[.blake3] = hex(d)
            }
            // XXH3 and CRC-32 big-endian, as xxhsum, crc32 and 7-Zip print them.
            if let x = l.xxh {
                if algorithms.contains(.xxh3) { out[.xxh3] = String(format: "%016llx", xs_xxh3_64(x)) }
                if algorithms.contains(.xxh128) {
                    var high: UInt64 = 0, low: UInt64 = 0
                    xs_xxh3_128(x, &high, &low)
                    out[.xxh128] = String(format: "%016llx%016llx", high, low)
                }
            }
            if let c = l.zipCRC { out[.crc32] = String(format: "%08x", c) }
        }
        return out
    }

    static func hash(path: String, algorithms: Set<ChecksumAlgorithm>, tracker: ProgressTracker?, cancel: CancellationToken?) throws -> ([ChecksumAlgorithm: String], Int64) {
        let file = try FileReader(path: path)
        let h = MultiHasher(algorithms)
        let size = 16 << 20
        let piece = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16384)
        defer { piece.deallocate() }
        var off: Int64 = 0
        while true {
            try cancel?.check()
            let n = try file.readSome(at: off, into: piece, count: size)
            if n == 0 { break }
            h.update(UnsafeRawBufferPointer(start: piece, count: n), more: off + Int64(n) < file.size)
            off += Int64(n)
            tracker?.add(bytes: Int64(n))
        }
        return (h.finalize(), off)
    }
}

enum ManifestCodec {
    /// coreutils `sha256sum`/`md5sum` line, with its escaping of `\` and newlines.
    static func textLine(_ digest: String, _ path: String) -> String {
        if path.contains("\\") || path.contains("\n") || path.contains("\r") {
            let e = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
            return "\\\(digest)  \(e)\n"
        }
        return "\(digest)  \(path)\n"
    }

    /// Parses coreutils (`<hex>  path`, `<hex> *path`) and BSD (`SHA256 (path) = <hex>`) lines.
    static func parseText(_ text: String, algorithm fallback: ChecksumAlgorithm?) throws -> [ManifestEntry] {
        var out: [ManifestEntry] = []
        for (n, raw) in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" }).enumerated() {
            var line = String(raw)
            if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if let open = line.range(of: " ("), let close = line.range(of: ") = ", options: .backwards), open.upperBound <= close.lowerBound {
                let name = String(line[..<open.lowerBound])
                guard let a = ChecksumAlgorithm(name: name) else { throw XipperError.corrupt("manifest line \(n + 1): unknown algorithm \(name)") }
                out.append(ManifestEntry(path: String(line[open.upperBound..<close.lowerBound]), size: nil,
                                         checksums: [a: String(line[close.upperBound...]).lowercased()]))
                continue
            }
            var escaped = false
            if line.hasPrefix("\\") { escaped = true; line.removeFirst() }
            guard let space = line.firstIndex(of: " ") else { throw XipperError.corrupt("manifest line \(n + 1) is not `<digest>  <path>`") }
            let digest = String(line[..<space])
            var rest = line[line.index(after: space)...]
            if rest.first == " " || rest.first == "*" { rest = rest.dropFirst() }
            var path = String(rest)
            if escaped {
                path = path.replacingOccurrences(of: "\\\\", with: "\u{0}").replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\r", with: "\r").replacingOccurrences(of: "\u{0}", with: "\\")
            }
            let algorithm = fallback ?? ChecksumAlgorithm.allCases.first { $0.digestLength == digest.count && $0 != .sha512t24u }
            guard let algorithm, digest.count == algorithm.digestLength else {
                throw XipperError.corrupt("manifest line \(n + 1): digest of \(digest.count) characters does not match \(fallback?.rawValue ?? "any known algorithm")")
            }
            out.append(ManifestEntry(path: path, size: nil, checksums: [algorithm: algorithm == .sha512t24u ? digest : digest.lowercased()]))
        }
        return out
    }

    static func json(_ entries: [ManifestEntry], algorithms: [ChecksumAlgorithm], root: String) throws -> Data {
        let iso = ISO8601DateFormatter()
        let objects: [[String: Any]] = entries.map { e in
            var o: [String: Any] = ["id": e.path, "name": (e.path as NSString).lastPathComponent, "path": e.path,
                                    "checksums": algorithms.compactMap { a in e.checksums[a].map { ["type": a.rawValue, "checksum": $0] } }]
            if let s = e.size { o["size"] = s }
            let attrs = try? FileManager.default.attributesOfItem(atPath: root + "/" + e.path)
            if let d = attrs?[.creationDate] as? Date { o["created_time"] = iso.string(from: d) }
            if let d = attrs?[.modificationDate] as? Date { o["updated_time"] = iso.string(from: d) }
            return o
        }
        let doc: [String: Any] = [
            "generator": "Xipper", "created_time": iso.string(from: Date()),
            "checksum_types": algorithms.map(\.rawValue), "objects": objects,
        ]
        return try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func parseJSON(_ data: Data) throws -> (entries: [ManifestEntry], skipped: [String]) {
        guard let doc = try? JSONSerialization.jsonObject(with: data) else { throw XipperError.corrupt("manifest is not valid JSON") }
        let objects: [[String: Any]]
        if let d = doc as? [String: Any], let o = d["objects"] as? [[String: Any]] { objects = o }
        else if let a = doc as? [[String: Any]] { objects = a }
        else if let d = doc as? [String: Any], d["checksums"] != nil { objects = [d] }  // a single DRS object
        else { throw XipperError.corrupt("JSON manifest has no \"objects\" array") }
        var skipped = Set<String>()
        var out: [ManifestEntry] = []
        for (i, o) in objects.enumerated() {
            guard let path = (o["path"] as? String) ?? (o["name"] as? String) else { throw XipperError.corrupt("object \(i) has no path or name") }
            var sums: [ChecksumAlgorithm: String] = [:]
            for c in (o["checksums"] as? [[String: Any]]) ?? [] {
                guard let t = c["type"] as? String, let v = c["checksum"] as? String else { continue }
                if let a = ChecksumAlgorithm(name: t) { sums[a] = a == .sha512t24u ? v : v.lowercased() } else { skipped.insert(t) }
            }
            out.append(ManifestEntry(path: path, size: (o["size"] as? NSNumber)?.int64Value, checksums: sums))
        }
        return (out, skipped.sorted())
    }
}

/// realpath(3): resolves every symlink (including /tmp → /private/tmp), unlike URL APIs.
func canonicalPath(_ p: String) -> String {
    guard let r = realpath(p, nil) else { return p }
    defer { free(r) }
    return String(cString: r)
}

extension Xipper {
    /// Writes a checksum manifest of `sources` (files, or folders walked recursively).
    /// The format comes from the manifest name: `.json` (DRS-style objects with every algorithm),
    /// otherwise a coreutils file for one algorithm (`.sha256`, `.md5`, `md5sum.txt`, `.crc32c`…).
    /// Paths are stored relative to the manifest's folder, which must contain every source.
    @discardableResult
    public static func createManifest(of sources: [URL], to manifest: URL, algorithms: [ChecksumAlgorithm]? = nil,
                                      overwrite: Bool = false, workload: Workload = .interactive,
                                      progress: ProgressHandler? = nil, cancel: CancellationToken? = nil) throws -> ManifestCreateReport {
        let given = manifest.standardizedFileURL.path
        let root = canonicalPath((given as NSString).deletingLastPathComponent)
        let manifestPath = root + "/" + (given as NSString).lastPathComponent
        let isJSON = manifestPath.lowercased().hasSuffix(".json")
        let algos: [ChecksumAlgorithm]
        if let algorithms, !algorithms.isEmpty {
            var seen = Set<ChecksumAlgorithm>()
            algos = algorithms.filter { seen.insert($0).inserted }
        } else if isJSON {
            algos = [.sha256, .md5, .crc32c]
        } else if let a = ChecksumAlgorithm.forManifestName(manifestPath) {
            algos = [a]
        } else {
            throw XipperError.invalidArgument("cannot tell the checksum type from \(manifest.lastPathComponent): use .sha256, .md5, .crc32c or .json, or pass the algorithm")
        }
        if !isJSON && algos.count > 1 { throw XipperError.invalidArgument("text manifests hold one algorithm; use a .json manifest for several") }
        if !overwrite && FileManager.default.fileExists(atPath: manifestPath) { throw XipperError.alreadyExists(path: manifestPath) }

        var files: [(rel: String, abs: String, size: Int64)] = []
        let fm = FileManager.default
        func add(_ abs: String) throws {
            guard abs.hasPrefix(root + "/") else {
                throw XipperError.invalidArgument("\(abs) is outside the manifest's folder \(root): put the manifest in a common parent folder")
            }
            if abs == manifestPath { return }
            let size = (try? fm.attributesOfItem(atPath: abs)[.size] as? NSNumber)?.int64Value ?? 0
            files.append((String(abs.dropFirst(root.count + 1)), abs, size))
        }
        for s in sources {
            let abs = canonicalPath(s.standardizedFileURL.path)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: abs, isDirectory: &isDir) else { throw XipperError.io("stat", path: abs, errno: ENOENT) }
            if !isDir.boolValue { try add(abs); continue }
            guard let e = fm.enumerator(at: URL(fileURLWithPath: abs), includingPropertiesForKeys: [.isRegularFileKey],
                                        options: [.skipsHiddenFiles]) else { continue }
            for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let name = u.lastPathComponent
                if name.hasPrefix("._") || name.contains(".xiptmp-") { continue }
                try add(canonicalPath(u.path))
            }
        }
        var seen = Set<String>()
        files = files.filter { seen.insert($0.rel).inserted }.sorted { $0.rel < $1.rel }
        if files.isEmpty { throw XipperError.invalidArgument("no files to checksum") }

        let tracker = ProgressTracker(totalBytes: files.reduce(0) { $0 + $1.size }, totalEntries: files.count, handler: progress)
        let set = Set(algos)
        let results = Slots<[ChecksumAlgorithm: String]>(files.count)
        let order = files.indices.sorted { files[$0].size > files[$1].size }
        try parallelFor(order.count, workload: workload, cancel: cancel) { k in
            let i = order[k]
            results[i] = try MultiHasher.hash(path: files[i].abs, algorithms: set, tracker: tracker, cancel: cancel).0
            tracker.add(bytes: 0, entries: 1, current: files[i].rel)
        }
        let entries = files.indices.map { ManifestEntry(path: files[$0].rel, size: files[$0].size, checksums: results.take($0)!) }
        let out = try OutputFile(path: manifestPath)
        if isJSON {
            try out.write(Array(try ManifestCodec.json(entries, algorithms: algos, root: root)) + [10])
        } else {
            try out.write(Array(entries.map { ManifestCodec.textLine($0.checksums[algos[0]]!, $0.path) }.joined().utf8))
        }
        try out.commit(overwrite: overwrite)
        tracker.finish()
        return ManifestCreateReport(manifest: URL(fileURLWithPath: manifestPath), algorithms: algos, entries: entries,
                                    bytes: tracker.completedBytes, elapsed: tracker.elapsed)
    }

    /// Verifies every file listed in a manifest (.json, coreutils or BSD text). Paths are taken
    /// relative to the manifest's folder; absolute paths and `..` are refused. `resolve` may
    /// further restrict or map paths (the MCP server applies its allowlist there).
    public static func verifyManifest(_ manifest: URL, algorithm: ChecksumAlgorithm? = nil,
                                      resolve: ((String) throws -> String)? = nil, workload: Workload = .interactive,
                                      progress: ProgressHandler? = nil, cancel: CancellationToken? = nil) throws -> ManifestVerifyReport {
        let manifestPath = manifest.standardizedFileURL.path
        let root = (manifestPath as NSString).deletingLastPathComponent
        let data = try FileReader(path: manifestPath).readAll(limit: 256 << 20)
        var entries: [ManifestEntry]
        var skippedTypes: [String] = []
        if data.first(where: { $0 != 32 && $0 != 10 && $0 != 13 && $0 != 9 }).map({ $0 == UInt8(ascii: "{") || $0 == UInt8(ascii: "[") }) == true {
            (entries, skippedTypes) = try ManifestCodec.parseJSON(Data(data))
        } else {
            entries = try ManifestCodec.parseText(String(decoding: data, as: UTF8.self), algorithm: algorithm ?? ChecksumAlgorithm.forManifestName(manifestPath))
        }
        // BSD lists with several algorithms name a file once per algorithm: one check per file.
        var merged: [ManifestEntry] = []
        var at: [String: Int] = [:]
        for e in entries {
            if let i = at[e.path] { merged[i].checksums.merge(e.checksums) { a, _ in a } } else { at[e.path] = merged.count; merged.append(e) }
        }
        entries = merged
        var report = ManifestVerifyReport(manifest: URL(fileURLWithPath: manifestPath), checked: 0, bytes: 0, mismatches: [], missing: [],
                                          refused: [], sizeMismatches: [], skippedTypes: skippedTypes, elapsed: 0)
        var jobs: [(entry: ManifestEntry, path: String)] = []
        for e in entries {
            let comps = e.path.split(separator: "/")
            if e.path.hasPrefix("/") || e.path.hasPrefix("~") || comps.contains("..") || e.path.isEmpty {
                report.refused.append(e.path)
                continue
            }
            var p = root + "/" + e.path
            if let resolve {
                do { p = try resolve(p) } catch { report.refused.append(e.path); continue }
            }
            if !FileManager.default.fileExists(atPath: p) { report.missing.append(e.path); continue }
            if e.checksums.isEmpty { continue }
            jobs.append((e, p))
        }
        let sizes = jobs.map { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.int64Value ?? 0 }
        let tracker = ProgressTracker(totalBytes: sizes.reduce(0, +), totalEntries: jobs.count, handler: progress)
        let results = Slots<[ChecksumAlgorithm: String]>(jobs.count)
        let order = jobs.indices.sorted { sizes[$0] > sizes[$1] }
        try parallelFor(order.count, workload: workload, cancel: cancel) { k in
            let i = order[k]
            results[i] = try MultiHasher.hash(path: jobs[i].path, algorithms: Set(jobs[i].entry.checksums.keys), tracker: tracker, cancel: cancel).0
            tracker.add(bytes: 0, entries: 1, current: jobs[i].entry.path)
        }
        for (i, j) in jobs.enumerated() {
            let actual = results.take(i)!
            report.checked += 1
            if let s = j.entry.size, s != sizes[i] { report.sizeMismatches.append("\(j.entry.path): \(sizes[i]) bytes, manifest says \(s)") }
            for (a, expected) in j.entry.checksums.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where actual[a] != expected {
                report.mismatches.append(.init(path: j.entry.path, algorithm: a, expected: expected, actual: actual[a] ?? ""))
            }
        }
        tracker.finish()
        report.bytes = tracker.completedBytes
        report.elapsed = tracker.elapsed
        return report
    }

    /// Digests of files and of the files inside folders (walked, hidden files and symlinks
    /// skipped), in parallel, each file read once for every algorithm. Paths are relative to
    /// `base` when the file is inside it, otherwise as given.
    public static func hashFiles(_ sources: [URL], algorithms: [ChecksumAlgorithm], relativeTo base: URL? = nil,
                                 workload: Workload = .interactive, progress: ProgressHandler? = nil,
                                 cancel: CancellationToken? = nil) throws -> [ManifestEntry] {
        let fm = FileManager.default
        let root = base.map { canonicalPath($0.standardizedFileURL.path) }
        var files: [(rel: String, abs: String, size: Int64)] = []
        func add(_ abs: String, shown: String) {
            let size = (try? fm.attributesOfItem(atPath: abs)[.size] as? NSNumber)?.int64Value ?? 0
            let rel = root.flatMap { abs.hasPrefix($0 + "/") ? String(abs.dropFirst($0.count + 1)) : nil } ?? shown
            files.append((rel, abs, size))
        }
        for s in sources {
            let abs = canonicalPath(s.standardizedFileURL.path)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: abs, isDirectory: &isDir) else { throw XipperError.io("stat", path: s.path, errno: ENOENT) }
            if !isDir.boolValue { add(abs, shown: s.relativePath); continue }
            guard let e = fm.enumerator(at: URL(fileURLWithPath: abs), includingPropertiesForKeys: [.isRegularFileKey],
                                        options: [.skipsHiddenFiles]) else { continue }
            for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let p = canonicalPath(u.path)
                add(p, shown: (s.relativePath as NSString).appendingPathComponent(String(p.dropFirst(abs.count + 1))))
            }
        }
        let tracker = ProgressTracker(totalBytes: files.reduce(0) { $0 + $1.size }, totalEntries: files.count, handler: progress)
        let set = Set(algorithms)
        let results = Slots<[ChecksumAlgorithm: String]>(files.count)
        let order = files.indices.sorted { files[$0].size > files[$1].size }
        try parallelFor(order.count, workload: workload, cancel: cancel) { k in
            let i = order[k]
            results[i] = try MultiHasher.hash(path: files[i].abs, algorithms: set, tracker: tracker, cancel: cancel).0
            tracker.add(bytes: 0, entries: 1, current: files[i].rel)
        }
        tracker.finish()
        return files.indices.map { ManifestEntry(path: files[$0].rel, size: files[$0].size, checksums: results.take($0)!) }
    }

    /// Digests of the files inside an archive, read in one verifying pass (nothing is extracted).
    /// Throws if an entry fails its own check (CRC, authentication).
    public static func hashContents(_ archive: URL, algorithms: [ChecksumAlgorithm], password: String? = nil,
                                    workload: Workload = .interactive, progress: ProgressHandler? = nil,
                                    cancel: CancellationToken? = nil) throws -> [ManifestEntry] {
        let r = try test(archive, password: password, workload: workload, digestAlgorithms: algorithms, progress: progress, cancel: cancel)
        if let f = r.failures.first { throw XipperError.integrity(entry: f.path, detail: f.reason) }
        let sizes = Dictionary((try? list(archive, password: password))?.map { ($0.path, $0.uncompressedSize) } ?? [], uniquingKeysWith: { a, _ in a })
        return r.allDigests.sorted { $0.key < $1.key }.map { ManifestEntry(path: $0.key, size: sizes[$0.key], checksums: $0.value) }
    }

    /// Lines of a checksum list: coreutils style for one algorithm (`sha256sum`, `b3sum`), BSD
    /// style (`SHA256 (file) = …`) with `bsd` or with several algorithms.
    public static func checksumLines(_ entries: [ManifestEntry], algorithms: [ChecksumAlgorithm], bsd: Bool = false) -> String {
        var out = ""
        for e in entries {
            for a in algorithms {
                guard let d = e.checksums[a] else { continue }
                out += bsd || algorithms.count > 1 ? "\(a.bsdTag) (\(e.path)) = \(d)\n" : ManifestCodec.textLine(d, e.path)
            }
        }
        return out
    }

    /// One digest of one file (e.g. to compare with a DRS object's `checksums`).
    public static func checksum(_ url: URL, algorithm: ChecksumAlgorithm, cancel: CancellationToken? = nil) throws -> String {
        try MultiHasher.hash(path: url.standardizedFileURL.path, algorithms: [algorithm], tracker: nil, cancel: cancel).0[algorithm]!
    }
}
