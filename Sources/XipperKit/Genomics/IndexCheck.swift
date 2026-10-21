import Foundation

public struct IndexCheckReport: Sendable {
    public enum Kind: String, Sendable { case tbi, csi, bai, gzi, crai }
    public var index: URL
    public var data: URL
    public var kind: Kind
    /// Reference sequences described (0 for .gzi).
    public var references: Int
    /// Virtual or file offsets compared against the data file.
    public var offsetsChecked: Int
    /// Errors: the index does not match the data file.
    public var problems: [String]
    /// E.g. the index is older than the data file.
    public var warnings: [String]
    public var isOK: Bool { problems.isEmpty }

    public init(index: URL, data: URL, kind: Kind, references: Int, offsetsChecked: Int, problems: [String], warnings: [String]) {
        self.index = index
        self.data = data
        self.kind = kind
        self.references = references
        self.offsetsChecked = offsetsChecked
        self.problems = problems
        self.warnings = warnings
    }
}

/// Collects problems, keeping only the first few of each kind (a broken index can have millions).
struct ProblemList {
    private(set) var items: [String] = []
    private var counts: [String: Int] = [:]
    let limit: Int

    init(limit: Int = 8) { self.limit = limit }

    mutating func add(_ kind: String, _ detail: String) {
        counts[kind, default: 0] += 1
        if counts[kind]! <= limit { items.append("\(kind): \(detail)") }
    }

    var summary: [String] {
        items + counts.filter { $0.value > limit }.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value - limit) more" }
    }
}

extension Xipper {
    /// Index files next to `data` (`x.vcf.gz.tbi`, `x.bam.bai`, `x.bai`, `x.cram.crai`…).
    public static func indexes(for data: URL) -> [URL] {
        let path = data.standardizedFileURL.path
        var names = [".tbi", ".csi", ".bai", ".gzi", ".crai"].map { path + $0 }
        if path.lowercased().hasSuffix(".bam") { names.append(String(path.dropLast(4)) + ".bai") }
        if path.lowercased().hasSuffix(".cram") { names.append(String(path.dropLast(5)) + ".crai") }
        return names.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// The data file an index describes, from its name.
    public static func dataFile(forIndex index: URL) -> URL? {
        let path = index.standardizedFileURL.path
        let ext = (path as NSString).pathExtension.lowercased()
        guard ["tbi", "csi", "bai", "gzi", "crai"].contains(ext) else { return nil }
        let stripped = String(path.dropLast(ext.count + 1))
        var candidates = [stripped]
        if ext == "bai" { candidates.append(stripped + ".bam") }
        if ext == "crai" { candidates.append(stripped + ".cram") }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Checks that an index (.tbi, .csi, .bai, .gzi, .crai) matches its data file: every virtual
    /// offset must fall on a BGZF block boundary inside the file (container starts and slice
    /// landmarks for .crai), and the index must not be older than the data.
    public static func checkIndex(_ index: URL, data: URL? = nil, cancel: CancellationToken? = nil) throws -> IndexCheckReport {
        let indexPath = index.standardizedFileURL.path
        guard let dataURL = data ?? dataFile(forIndex: index) else {
            throw XipperError.invalidArgument("cannot find the data file of \(index.lastPathComponent): pass it explicitly")
        }
        let dataPath = dataURL.standardizedFileURL.path
        let bytes = try FileReader(path: indexPath).readAll()
        let ext = (indexPath as NSString).pathExtension.lowercased()
        var warnings: [String] = []
        let fm = FileManager.default
        if let im = try? fm.attributesOfItem(atPath: indexPath)[.modificationDate] as? Date,
           let dm = try? fm.attributesOfItem(atPath: dataPath)[.modificationDate] as? Date, im < dm {
            let f = ISO8601DateFormatter()
            warnings.append("index is older than the data file (\(f.string(from: im)) < \(f.string(from: dm))): it was probably built for a previous version; rebuild it")
        }
        let dataFile = try FileReader(path: dataPath)
        var report: IndexCheckReport
        if ext == "crai" {
            report = try checkCRAI(bytes, data: dataFile, cancel: cancel)
        } else {
            try BGZFBlockReader.requireBGZF(dataFile, name: dataURL.lastPathComponent)
            let map = try BGZFBlockMap.scan(dataFile, cancel: cancel)
            if ext == "gzi" || !(bytes.starts(with: [0x1f, 0x8b]) || bytes.starts(with: Array("BAI\u{1}".utf8)) || bytes.starts(with: Array("CSI\u{1}".utf8))) {
                report = try checkGZI(bytes, map: map)
            } else {
                report = try checkBinning(bytes, map: map, data: dataFile)
            }
            if let d = map.damage { report.problems.insert("data file is damaged: \(d)", at: 0) }
            else if !map.endsWithEOFMarker { report.problems.insert("data file has no BGZF end-of-file marker: it is probably truncated", at: 0) }
        }
        report.index = URL(fileURLWithPath: indexPath)
        report.data = URL(fileURLWithPath: dataPath)
        report.warnings = warnings + report.warnings
        return report
    }

    private static func checkGZI(_ bytes: [UInt8], map: BGZFBlockMap) throws -> IndexCheckReport {
        var problems = ProblemList()
        let entries: [(UInt64, UInt64)] = try bytes.withUnsafeBytes { b in
            var r = ByteReader(b)
            let n = try r.u64()
            guard n <= UInt64(b.count / 16) else { throw XipperError.corrupt(".gzi declares \(n) entries in \(b.count) bytes") }
            return try (0..<Int(n)).map { _ in (try r.u64(), try r.u64()) }
        }
        // Cumulative uncompressed start of every block.
        var ustart = [UInt64](repeating: 0, count: map.offsets.count)
        var u: UInt64 = 0
        for i in map.offsets.indices { ustart[i] = u; u += UInt64(map.isizes[i]) }
        for (c, uo) in entries {
            guard let i = map.blockIndex(c) else {
                problems.add("offset not on a BGZF block", "compressed offset \(c)")
                continue
            }
            if ustart[i] != uo { problems.add("wrong uncompressed offset", "block at \(c) starts at \(ustart[i]), index says \(uo)") }
        }
        let expected = zip(map.offsets, map.isizes).enumerated().filter { $0.offset > 0 && $0.element.1 > 0 }.count
        if entries.count != expected { problems.add("entry count", "\(entries.count) entries, the file has \(expected) data blocks after the first") }
        return IndexCheckReport(index: URL(fileURLWithPath: "/"), data: URL(fileURLWithPath: "/"), kind: .gzi, references: 0,
                                offsetsChecked: entries.count, problems: problems.summary, warnings: [])
    }

    private static func checkBinning(_ bytes: [UInt8], map: BGZFBlockMap, data: FileReader) throws -> IndexCheckReport {
        let idx = try BinningIndex.parse(bytes)
        var problems = ProblemList()
        var checked = 0
        let maxBin = idx.metaBin
        func check(_ v: UInt64, _ what: String, ref: Int) {
            checked += 1
            if let p = map.problem(with: v) { problems.add("bad virtual offset", "\(what) of reference #\(ref) \(VirtualOffset.text(v)) \(p)") }
        }
        for (t, ref) in idx.references.enumerated() {
            for bin in ref.bins {
                if bin.id > maxBin { problems.add("bin out of range", "bin \(bin.id) of reference #\(t)"); continue }
                let meta = bin.id == maxBin
                for (k, c) in bin.chunks.enumerated() {
                    if meta && k == 1 { break }  // (mapped, unmapped) counts, not offsets
                    check(c.begin, "chunk start", ref: t)
                    check(c.end, "chunk end", ref: t)
                    if c.end < c.begin { problems.add("chunk ends before it starts", "reference #\(t) bin \(bin.id)") }
                }
                if idx.kind == .csi && bin.loffset != 0 { check(bin.loffset, "bin linear offset", ref: t) }
            }
            for (w, o) in ref.linear.enumerated() where o != 0 { check(o, "linear index window \(w)", ref: t) }
        }
        var warnings: [String] = []
        // The BAM header must declare the same number of references.
        if idx.kind == .bai || (idx.kind == .csi && idx.config == nil) {
            if let n = try? bamReferenceCount(data), n != idx.references.count {
                problems.add("reference count", "index has \(idx.references.count) references, the BAM header \(n)")
            }
        }
        if let c = idx.config, c.isVCF, let n = try? vcfContigCount(data), n > 0, idx.references.count > n {
            warnings.append("index lists \(idx.references.count) sequences but the VCF header declares \(n) contigs")
        }
        let kind: IndexCheckReport.Kind = idx.kind == .bai ? .bai : idx.kind == .csi ? .csi : .tbi
        return IndexCheckReport(index: URL(fileURLWithPath: "/"), data: URL(fileURLWithPath: "/"), kind: kind, references: idx.references.count,
                                offsetsChecked: checked, problems: problems.summary, warnings: warnings)
    }

    private static func checkCRAI(_ bytes: [UInt8], data: FileReader, cancel: CancellationToken?) throws -> IndexCheckReport {
        var text = bytes
        if bytes.starts(with: [0x1f, 0x8b]) {
            text = []
            let d = try StreamCompression.gzip.decoder(threads: 1)
            try bytes.withUnsafeBytes { try d.process($0) { text.append(contentsOf: $0) } }
            try d.finish { text.append(contentsOf: $0) }
        }
        let layout = try CRAMScanner.scan(data, cancel: cancel)
        var problems = ProblemList()
        if !layout.problems.isEmpty { problems.add("CRAM file", layout.problems.joined(separator: "; ")) }
        var checked = 0
        var refs = Set<Int>()
        for (n, line) in String(decoding: text, as: UTF8.self).split(separator: "\n").enumerated() {
            let f = line.split(separator: "\t").map { Int64($0) }
            guard f.count == 6, f.allSatisfy({ $0 != nil }) else { problems.add("malformed line", "line \(n + 1)"); continue }
            refs.insert(Int(f[0]!))
            checked += 1
            guard let landmarks = layout.landmarks[UInt64(f[3]!)] else {
                problems.add("not a container start", "line \(n + 1): offset \(f[3]!)")
                continue
            }
            if !landmarks.contains(Int(f[4]!)) { problems.add("not a slice start", "line \(n + 1): slice offset \(f[4]!) in container at \(f[3]!)") }
        }
        return IndexCheckReport(index: URL(fileURLWithPath: "/"), data: URL(fileURLWithPath: "/"), kind: .crai, references: refs.count,
                                offsetsChecked: checked, problems: problems.summary, warnings: [])
    }

    /// n_ref from a BAM header (magic, l_text, text, n_ref).
    static func bamReferenceCount(_ file: FileReader) throws -> Int {
        let head = try bgzfPrefix(file, count: 8)
        guard head.count == 8, head.starts(with: Array("BAM\u{1}".utf8)) else { throw XipperError.corrupt("not a BAM file") }
        let ltext = Int(UInt32(head[4]) | UInt32(head[5]) << 8 | UInt32(head[6]) << 16 | UInt32(head[7]) << 24)
        let more = try bgzfPrefix(file, count: 12 + ltext)
        guard more.count == 12 + ltext else { throw XipperError.corrupt("BAM header truncated") }
        return Int(UInt32(more[8 + ltext]) | UInt32(more[9 + ltext]) << 8 | UInt32(more[10 + ltext]) << 16 | UInt32(more[11 + ltext]) << 24)
    }

    static func vcfContigCount(_ file: FileReader) throws -> Int {
        try VariantHeader.read(file).contigs
    }
}

extension FileReader {
    func readAll(limit: Int64 = 1 << 30) throws -> [UInt8] {
        guard size <= limit else { throw XipperError.limitExceeded("\(path) is larger than \(limit) bytes") }
        return try read(at: 0, count: Int(size))
    }
}
