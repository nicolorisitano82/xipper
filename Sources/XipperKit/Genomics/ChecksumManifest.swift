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
        }
    }

    /// Algorithm of a coreutils-style manifest, from its file name (`x.sha256`, `md5sum.txt`, `MD5SUMS`…).
    public static func forManifestName(_ name: String) -> ChecksumAlgorithm? {
        let n = (name as NSString).lastPathComponent.lowercased()
        let ext = (n as NSString).pathExtension
        if let a = ChecksumAlgorithm(name: ext.hasSuffix("sum") ? String(ext.dropLast(3)) : ext) { return a }
        if let a = ChecksumAlgorithm(name: ext.hasSuffix("sums") ? String(ext.dropLast(4)) : ext) { return a }
        let base = (n as NSString).deletingPathExtension
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
        func update(_ b: UnsafeRawBufferPointer) {
            sha256?.update(bufferPointer: b)
            sha512?.update(bufferPointer: b)
            sha1?.update(bufferPointer: b)
            md5?.update(bufferPointer: b)
            if let c = crc, let p = b.baseAddress { crc = xs_crc32c(c, p.assumingMemoryBound(to: UInt8.self), b.count) }
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
        self.lanes = lanes
    }

    func update(_ b: UnsafeRawBufferPointer) {
        if lanes.count == 1 { lanes[0].update(b); return }
        nonisolated(unsafe) let buffer = b
        DispatchQueue.concurrentPerform(iterations: lanes.count) { lanes[$0].update(buffer) }
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
        }
        return out
    }

    static func hash(path: String, algorithms: Set<ChecksumAlgorithm>, tracker: ProgressTracker?, cancel: CancellationToken?) throws -> ([ChecksumAlgorithm: String], Int64) {
        let file = try FileReader(path: path)
        let h = MultiHasher(algorithms)
        let piece = UnsafeMutableRawPointer.allocate(byteCount: 4 << 20, alignment: 16384)
        defer { piece.deallocate() }
        var off: Int64 = 0
        while true {
            try cancel?.check()
            let n = try file.readSome(at: off, into: piece, count: 4 << 20)
            if n == 0 { break }
            h.update(UnsafeRawBufferPointer(start: piece, count: n))
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

    /// One digest of one file (e.g. to compare with a DRS object's `checksums`).
    public static func checksum(_ url: URL, algorithm: ChecksumAlgorithm, cancel: CancellationToken? = nil) throws -> String {
        try MultiHasher.hash(path: url.standardizedFileURL.path, algorithms: [algorithm], tracker: nil, cancel: cancel).0[algorithm]!
    }
}
