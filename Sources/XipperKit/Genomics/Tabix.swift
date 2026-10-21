import CDeflate
import Foundation

/// How tabix reads coordinates from a text line (htslib `tbx_conf_t`). Columns are 1-based.
public struct TabixConfig: Sendable, Equatable {
    public enum Preset: String, Sendable, CaseIterable { case vcf, bed, gff }

    /// 0 generic, 1 SAM, 2 VCF; | 0x10000 for zero-based half-open coordinates (UCSC/BED).
    public var format: Int32
    public var sequenceColumn: Int32
    public var beginColumn: Int32
    /// 0: the record spans one base (VCF: the REF allele, or INFO/END).
    public var endColumn: Int32
    public var metaChar: UInt8
    public var skipLines: Int32

    public var zeroBased: Bool { format & 0x10000 != 0 }
    var isVCF: Bool { format & 0xFFFF == 2 }

    public init(format: Int32, sequenceColumn: Int32, beginColumn: Int32, endColumn: Int32, metaChar: UInt8 = UInt8(ascii: "#"), skipLines: Int32 = 0) {
        self.format = format
        self.sequenceColumn = sequenceColumn
        self.beginColumn = beginColumn
        self.endColumn = endColumn
        self.metaChar = metaChar
        self.skipLines = skipLines
    }

    /// The same presets as `tabix -p`.
    public init(preset: Preset) {
        switch preset {
        case .vcf: self.init(format: 2, sequenceColumn: 1, beginColumn: 2, endColumn: 0)
        case .bed: self.init(format: 0x10000, sequenceColumn: 1, beginColumn: 2, endColumn: 3)
        case .gff: self.init(format: 0, sequenceColumn: 1, beginColumn: 4, endColumn: 5)
        }
    }

    /// Preset from the file name (`.vcf.gz`, `.bed.bgz`, `.gff3.gz`, `.gtf.gz`…), else nil.
    public static func preset(forFileName name: String) -> Preset? {
        var n = name.lowercased()
        for s in [".gz", ".bgz", ".bgzf"] where n.hasSuffix(s) { n.removeLast(s.count); break }
        switch (n as NSString).pathExtension {
        case "vcf": return .vcf
        case "bed", "bedgraph", "narrowpeak", "broadpeak": return .bed
        case "gff", "gff3", "gtf": return .gff
        default: return nil
        }
    }
}

public struct TabixReport: Sendable {
    public enum Kind: String, Sendable { case tbi, csi }
    public var index: URL
    public var kind: Kind
    public var sequences: [String]
    public var records: Int
    public var elapsed: Double
}

/// In-memory binning index shared by .tbi, .csi and .bai (SAM spec §5, CSIv1).
struct BinningIndex {
    enum Kind: String { case tbi, csi, bai }
    struct Chunk { var begin: UInt64; var end: UInt64 }
    struct Bin { var id: UInt32; var loffset: UInt64; var chunks: [Chunk] }
    struct Reference {
        var bins: [Bin] = []
        /// Linear index (.tbi/.bai): smallest virtual offset per 16 kbp window.
        var linear: [UInt64] = []
    }

    var kind: Kind
    var minShift: Int
    var depth: Int
    var config: TabixConfig?
    var names: [String]
    var references: [Reference]
    var unplaced: UInt64?

    /// Pseudo-bin holding (start, end) offsets and (mapped, unmapped) counts.
    var metaBin: UInt32 { UInt32(((1 << (3 * (depth + 1))) - 1) / 7 + 1) }

    // MARK: binning arithmetic (htslib hts.h)

    static func reg2bin(_ beg: Int64, _ end: Int64, minShift: Int, depth: Int) -> UInt32 {
        var end = end - 1
        if end < beg { end = beg }
        var s = minShift
        var t = ((1 << (depth * 3)) - 1) / 7
        var l = depth
        while l > 0 {
            if beg >> s == end >> s { return UInt32(Int64(t) + (beg >> s)) }
            l -= 1
            s += 3
            t -= 1 << (l * 3)
        }
        return 0
    }

    /// First linear-index window covered by `bin`.
    static func binBottom(_ bin: UInt32, depth: Int) -> Int {
        var l = 0, b = Int(bin)
        while b > 0 { l += 1; b = (b - 1) >> 3 }
        let first = ((1 << (l * 3)) - 1) / 7
        return (Int(bin) - first) << ((depth - l) * 3)
    }

    // MARK: serialization

    /// Uncompressed index bytes (the caller BGZF-compresses .tbi and .csi).
    func serialize() -> [UInt8] {
        var w = ByteWriter(capacity: 1 << 16)
        var aux = ByteWriter()
        if let c = config {
            aux.u32(UInt32(bitPattern: c.format)); aux.u32(UInt32(bitPattern: c.sequenceColumn))
            aux.u32(UInt32(bitPattern: c.beginColumn)); aux.u32(UInt32(bitPattern: c.endColumn))
            aux.u32(UInt32(c.metaChar)); aux.u32(UInt32(bitPattern: c.skipLines))
            let nm: [UInt8] = names.flatMap { Array($0.utf8) + [UInt8(0)] }
            aux.u32(UInt32(nm.count))
            aux.append(nm)
        }
        switch kind {
        case .tbi:
            w.append(Array("TBI\u{1}".utf8))
            w.u32(UInt32(references.count))
            w.append(aux.bytes)
        case .csi:
            w.append(Array("CSI\u{1}".utf8))
            w.u32(UInt32(minShift)); w.u32(UInt32(depth))
            w.u32(UInt32(aux.bytes.count)); w.append(aux.bytes)
            w.u32(UInt32(references.count))
        case .bai:
            w.append(Array("BAI\u{1}".utf8))
            w.u32(UInt32(references.count))
        }
        for r in references {
            w.u32(UInt32(r.bins.count))
            for b in r.bins {
                w.u32(b.id)
                if kind == .csi { w.u64(b.loffset) }
                w.u32(UInt32(b.chunks.count))
                for c in b.chunks { w.u64(c.begin); w.u64(c.end) }
            }
            if kind != .csi {
                w.u32(UInt32(r.linear.count))
                for o in r.linear { w.u64(o) }
            }
        }
        if let u = unplaced { w.u64(u) }
        return w.bytes
    }

    /// Parses an index file (.tbi/.csi BGZF-compressed or raw, .bai raw).
    static func parse(_ fileBytes: [UInt8]) throws -> BinningIndex {
        var raw = fileBytes
        if BGZF.isBGZF(fileBytes) {
            raw = []
            let d = libdeflate_alloc_decompressor()!
            defer { libdeflate_free_decompressor(d) }
            var pos = 0
            try fileBytes.withUnsafeBytes { b in
                while pos < b.count {
                    guard let size = BGZF.blockSize(at: UnsafeRawBufferPointer(rebasing: b[pos..<min(b.count, pos + 64)])),
                          pos + size <= b.count else { throw XipperError.corrupt("index truncated inside a BGZF block") }
                    raw += try BGZF.decompressBlock(UnsafeRawBufferPointer(rebasing: b[pos..<pos + size]), decompressor: d)
                    pos += size
                }
            }
        }
        return try raw.withUnsafeBytes { b in
            var r = ByteReader(b)
            guard b.count >= 4 else { throw XipperError.corrupt("index too short") }
            let magic = String(decoding: b[0..<3], as: UTF8.self)
            r.pos = 4
            var idx: BinningIndex
            func readConfig(_ r: inout ByteReader) throws -> (TabixConfig, [String]) {
                let f = Int32(bitPattern: try r.u32()), sc = Int32(bitPattern: try r.u32()), bc = Int32(bitPattern: try r.u32())
                let ec = Int32(bitPattern: try r.u32()), meta = UInt8(truncatingIfNeeded: try r.u32()), skip = Int32(bitPattern: try r.u32())
                let lnm = Int(try r.u32())
                let nm = try r.bytes(lnm)
                let names = nm.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
                return (TabixConfig(format: f, sequenceColumn: sc, beginColumn: bc, endColumn: ec, metaChar: meta, skipLines: skip), names)
            }
            let nref: Int
            switch (magic, b[3]) {
            case ("TBI", 1):
                nref = Int(try r.u32())
                let (c, n) = try readConfig(&r)
                idx = BinningIndex(kind: .tbi, minShift: 14, depth: 5, config: c, names: n, references: [], unplaced: nil)
            case ("BAI", 1):
                nref = Int(try r.u32())
                idx = BinningIndex(kind: .bai, minShift: 14, depth: 5, config: nil, names: [], references: [], unplaced: nil)
            case ("CSI", 1):
                let ms = Int(try r.u32()), dp = Int(try r.u32())
                guard (1...30).contains(ms), (1...12).contains(dp) else { throw XipperError.corrupt("CSI: invalid min_shift \(ms) / depth \(dp)") }
                let laux = Int(try r.u32())
                var config: TabixConfig?, names: [String] = []
                if laux >= 28 {
                    let auxStart = r.pos
                    (config, names) = try readConfig(&r)
                    r.pos = auxStart + laux
                } else {
                    _ = try r.bytes(laux)
                }
                nref = Int(try r.u32())
                idx = BinningIndex(kind: .csi, minShift: ms, depth: dp, config: config, names: names, references: [], unplaced: nil)
            default:
                throw XipperError.corrupt("not a .tbi, .csi or .bai index (magic \(magic.debugDescription))")
            }
            guard nref <= b.count / 8 else { throw XipperError.corrupt("index declares \(nref) references") }
            idx.references.reserveCapacity(nref)
            for _ in 0..<nref {
                var ref = Reference()
                let nbin = Int(try r.u32())
                guard nbin <= r.remaining / 8 else { throw XipperError.corrupt("index truncated (bins)") }
                for _ in 0..<nbin {
                    let id = try r.u32()
                    let loff = idx.kind == .csi ? try r.u64() : 0
                    let nchunk = Int(try r.u32())
                    guard nchunk <= r.remaining / 16 else { throw XipperError.corrupt("index truncated (chunks)") }
                    var chunks: [Chunk] = []
                    chunks.reserveCapacity(nchunk)
                    for _ in 0..<nchunk { chunks.append(Chunk(begin: try r.u64(), end: try r.u64())) }
                    ref.bins.append(Bin(id: id, loffset: loff, chunks: chunks))
                }
                if idx.kind != .csi {
                    let n = Int(try r.u32())
                    guard n <= r.remaining / 8 else { throw XipperError.corrupt("index truncated (linear index)") }
                    ref.linear = try (0..<n).map { _ in try r.u64() }
                }
                idx.references.append(ref)
            }
            if r.remaining >= 8 { idx.unplaced = try r.u64() }
            return idx
        }
    }
}

// MARK: - building

/// Streaming equivalent of htslib's `hts_idx_push` for tabix-style text files.
struct TabixBuilder {
    struct RefState {
        var bins: [UInt32: [BinningIndex.Chunk]] = [:]
        var binOrder: [UInt32] = []
        var linear: [UInt64] = []
        var offBegin: UInt64 = 0
        var offEnd: UInt64 = 0
        var mapped: UInt64 = 0
    }

    let config: TabixConfig
    let minShift: Int
    let depth: Int
    let kind: BinningIndex.Kind
    var maxEnd: Int64 { kind == .tbi ? 1 << 29 : 1 << Int64(minShift + 3 * depth) }

    var names: [String] = []
    var refs: [RefState] = []
    private var nameSet = Set<[UInt8]>()
    private var lastName: [UInt8] = []
    private var lastBeg: Int64 = -1
    private var saveBin: UInt32 = .max
    private var saveOff: UInt64 = 0
    private(set) var records = 0

    init(config: TabixConfig, kind: BinningIndex.Kind, minShift: Int, depth: Int) {
        self.config = config
        self.kind = kind
        self.minShift = minShift
        self.depth = depth
    }

    private mutating func flushBin(_ end: UInt64) {
        guard saveBin != .max, !refs.isEmpty else { return }
        let t = refs.count - 1
        if refs[t].bins[saveBin] == nil { refs[t].binOrder.append(saveBin) }
        refs[t].bins[saveBin, default: []].append(BinningIndex.Chunk(begin: saveOff, end: end))
    }

    mutating func push(name: UnsafeRawBufferPointer, beg: Int64, end: Int64, start: UInt64, stop: UInt64, line: Int) throws {
        if name.count != lastName.count || !lastName.withUnsafeBytes({ $0.elementsEqual(name) }) {
            let key = Array(name)
            if nameSet.contains(key) {
                throw XipperError.corrupt("not sorted: sequence \(String(decoding: key, as: UTF8.self)) appears again at line \(line) after other sequences. Sort the file (bcftools sort, or sort -k1,1 -k2,2n) and compress it again")
            }
            flushBin(start)
            if !refs.isEmpty { refs[refs.count - 1].offEnd = start }
            nameSet.insert(key)
            lastName = key
            names.append(String(decoding: key, as: UTF8.self))
            refs.append(RefState(offBegin: start))
            lastBeg = -1
            saveBin = .max
        } else if beg < lastBeg {
            throw XipperError.corrupt("not sorted: line \(line) (\(names.last!):\(beg + 1)) comes after position \(lastBeg + 1). Sort the file (bcftools sort, or sort -k1,1 -k2,2n) and compress it again")
        }
        if end > maxEnd {
            throw XipperError.limitExceeded(kind == .tbi
                ? "line \(line): position \(end) is beyond the 512 Mbp limit of .tbi indexes; build a CSI index instead (csi: true / --csi)"
                : "line \(line): position \(end) is beyond this CSI index's range")
        }
        let t = refs.count - 1
        // Linear index: first record offset overlapping each 16 kbp window.
        let wb = Int(beg >> Int64(minShift)), we = Int((end - 1) >> Int64(minShift))
        if refs[t].linear.count <= we { refs[t].linear += [UInt64](repeating: .max, count: we + 1 - refs[t].linear.count) }
        for w in wb...max(wb, we) where refs[t].linear[w] == .max { refs[t].linear[w] = start }
        let bin = BinningIndex.reg2bin(beg, end, minShift: minShift, depth: depth)
        if bin != saveBin {
            flushBin(start)
            saveBin = bin
            saveOff = start
        }
        refs[t].mapped += 1
        refs[t].offEnd = stop
        lastBeg = beg
        records += 1
    }

    mutating func finish(end: UInt64) -> BinningIndex {
        flushBin(end)
        var idx = BinningIndex(kind: kind, minShift: minShift, depth: depth, config: config, names: names, references: [], unplaced: 0)
        let meta = idx.metaBin
        for r in refs {
            var ref = BinningIndex.Reference()
            // Windows without records take the next window's offset (htslib 1.24 update_loff).
            var linear = r.linear
            for l in stride(from: linear.count - 2, through: 0, by: -1) where linear[l] == .max { linear[l] = linear[l + 1] }
            for id in r.binOrder.sorted() {
                // Merge chunks that touch the same compressed block (htslib compress_binning).
                var merged: [BinningIndex.Chunk] = []
                for c in r.bins[id]! {
                    if let last = merged.last, last.end >> 16 >= c.begin >> 16 {
                        merged[merged.count - 1].end = max(last.end, c.end)
                    } else {
                        merged.append(c)
                    }
                }
                let bottom = BinningIndex.binBottom(id, depth: depth)
                let loff = kind == .csi && bottom < linear.count ? linear[bottom] : 0
                ref.bins.append(BinningIndex.Bin(id: id, loffset: loff, chunks: merged))
            }
            ref.bins.append(BinningIndex.Bin(id: meta, loffset: 0, chunks: [
                BinningIndex.Chunk(begin: r.offBegin, end: r.offEnd), BinningIndex.Chunk(begin: r.mapped, end: 0),
            ]))
            if kind != .csi { ref.linear = linear }
            idx.references.append(ref)
        }
        return idx
    }
}

/// Parses tabix intervals out of text lines (htslib 1.24 `tbx_parse1`).
///
/// VCF ends follow htslib: the longest of REF, INFO/END, |SVLEN| of symbolic alleles and the
/// samples' FORMAT/LEN for gVCF `<*>`/`<NON_REF>`. Where htslib is more selective (SVLEN only
/// for some symbolic alleles) the larger end is kept: a record placed in a wider bin is still
/// found by every query, while a narrower one could be missed.
struct TabixLineParser {
    let config: TabixConfig
    private let lastColumn: Int

    init(config: TabixConfig) {
        self.config = config
        lastColumn = config.isVCF ? Int.max : Int(max(config.sequenceColumn, config.beginColumn, config.endColumn))
    }

    struct Interval { var name: Range<Int>; var beg: Int64; var end: Int64 }

    /// nil when a required column is missing or not a number.
    func parse(_ line: UnsafeRawBufferPointer) -> Interval? {
        var col = 1, start = 0
        var name = 0..<0
        var beg: Int64 = -1, end: Int64 = -1
        // VCF state
        var refLength: Int64 = 0, infoEnd: Int64 = -1, svlen: Int64 = 0, fmtlen: Int64 = 0
        var symbolic = false, gvcf = false, lenPos = -1
        let n = line.count
        var i = 0
        while col <= lastColumn {
            while i < n && line[i] != 9 { i += 1 }
            let field = start..<i
            if col == config.sequenceColumn { name = field }
            if col == config.beginColumn {
                guard let v = Self.integer(line, field) else { return nil }
                beg = config.zeroBased ? v : v - 1
                if beg < 0 { beg = 0 }
            } else if config.endColumn != 0 && col == config.endColumn && !config.isVCF {
                guard let v = Self.integer(line, field) else { return nil }
                end = v
            }
            if config.isVCF {
                switch col {
                case 4: refLength = Int64(field.count)
                case 5:
                    for allele in Self.split(line, field, by: 44) {
                        guard allele.count > 2, line[allele.lowerBound] == 60 else { continue }  // '<'
                        let text = String(decoding: UnsafeRawBufferPointer(rebasing: line[allele]), as: UTF8.self)
                        if text == "<*>" || text == "<NON_REF>" { gvcf = true } else { symbolic = true }
                    }
                case 8:
                    if let v = Self.infoValue(line, field, key: "END"), let e = Self.integer(line, v) { infoEnd = e }
                    if symbolic, let v = Self.infoValue(line, field, key: "SVLEN") {
                        for x in Self.split(line, v, by: 44) { svlen = max(svlen, Self.signedMagnitude(line, x) ?? 1) }
                    }
                case 9 where gvcf:
                    lenPos = Self.split(line, field, by: 58).firstIndex { Self.equals(line, $0, "LEN") } ?? -1
                default:
                    if col > 9 && lenPos >= 0 {
                        let parts = Self.split(line, field, by: 58)
                        if lenPos < parts.count, let v = Self.integer(line, parts[lenPos]) { fmtlen = max(fmtlen, v) }
                    }
                }
                if col == 9 && lenPos < 0 { col += 1; break }  // nothing more to read
            }
            if i >= n { col += 1; break }
            i += 1
            start = i
            col += 1
        }
        let required = Int(max(config.sequenceColumn, config.beginColumn, config.endColumn))
        guard col > required, !name.isEmpty, beg >= 0 else { return nil }
        if config.isVCF {
            end = beg + max(refLength, svlen, fmtlen, 1)
            if infoEnd > end { end = infoEnd }
        } else if config.endColumn == 0 || end <= beg {
            end = beg + 1
        }
        return Interval(name: name, beg: beg, end: end)
    }

    private static func integer(_ b: UnsafeRawBufferPointer, _ r: Range<Int>) -> Int64? {
        var v: Int64 = 0
        var any = false
        var i = r.lowerBound
        while i < r.upperBound, b[i] == 32 { i += 1 }
        if i < r.upperBound, b[i] == 43 { i += 1 }
        while i < r.upperBound, b[i] >= 48 && b[i] <= 57 {
            v = v &* 10 &+ Int64(b[i] - 48)
            any = true
            i += 1
        }
        return any ? v : nil
    }

    private static func signedMagnitude(_ b: UnsafeRawBufferPointer, _ r: Range<Int>) -> Int64? {
        if !r.isEmpty, b[r.lowerBound] == 45 { return integer(b, (r.lowerBound + 1)..<r.upperBound) }
        return integer(b, r)
    }

    private static func split(_ b: UnsafeRawBufferPointer, _ r: Range<Int>, by sep: UInt8) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var s = r.lowerBound
        for i in r where b[i] == sep { out.append(s..<i); s = i + 1 }
        out.append(s..<r.upperBound)
        return out
    }

    private static func equals(_ b: UnsafeRawBufferPointer, _ r: Range<Int>, _ s: String) -> Bool {
        r.count == s.utf8.count && UnsafeRawBufferPointer(rebasing: b[r]).elementsEqual(s.utf8)
    }

    /// Value range of `KEY=` in a VCF INFO field (first key or after ';').
    private static func infoValue(_ b: UnsafeRawBufferPointer, _ r: Range<Int>, key: String) -> Range<Int>? {
        let k = Array(key.utf8) + [61]
        var i = r.lowerBound
        while i + k.count <= r.upperBound {
            if (i == r.lowerBound || b[i - 1] == 59) && UnsafeRawBufferPointer(rebasing: b[i..<(i + k.count)]).elementsEqual(k) {
                var e = i + k.count
                while e < r.upperBound && b[e] != 59 { e += 1 }
                return (i + k.count)..<e
            }
            i += 1
        }
        return nil
    }
}

extension Xipper {
    /// Builds the tabix (.tbi) or CSI index of a coordinate-sorted, BGZF-compressed VCF/BED/GFF,
    /// compatible with htslib (`tabix -p vcf` / `tabix -C`). By default written next to the file.
    @discardableResult
    public static func tabixIndex(_ url: URL, config: TabixConfig? = nil, csi: Bool = false, minShift: Int = 14,
                                  to indexURL: URL? = nil, overwrite: Bool = true, workload: Workload = .interactive,
                                  progress: ProgressHandler? = nil, cancel: CancellationToken? = nil) throws -> TabixReport {
        let path = url.standardizedFileURL.path
        let name = url.lastPathComponent
        let file = try FileReader(path: path)
        try BGZFBlockReader.requireBGZF(file, name: name)
        let conf: TabixConfig
        if let config { conf = config } else {
            guard let p = TabixConfig.preset(forFileName: name) else {
                throw XipperError.invalidArgument("cannot tell the format of \(name) from its name: pass a preset (vcf, bed, gff)")
            }
            conf = TabixConfig(preset: p)
        }
        guard (8...24).contains(minShift) else { throw XipperError.invalidArgument("min_shift must be 8-24") }
        let tracker = ProgressTracker(totalBytes: file.size, totalEntries: 1, handler: progress)
        // htslib's default CSI depth when no contig lengths are known: ≥ 100 Gbp for min_shift ≥ 10.
        let depth = csi ? (minShift < 10 ? 9 : 9 - (minShift - 10) / 3) : 5
        let (idx, records) = try buildTabix(file: file, config: conf, kind: csi ? .csi : .tbi, minShift: csi ? minShift : 14,
                                            depth: depth, workload: workload, tracker: tracker, cancel: cancel)
        let dest = indexURL?.standardizedFileURL.path ?? path + (csi ? ".csi" : ".tbi")
        let out = try OutputFile(path: dest)
        try out.write(compressBGZFBlocks(idx.serialize()))
        try out.commit(overwrite: overwrite)
        tracker.add(bytes: 0, entries: 1)
        tracker.finish()
        return TabixReport(index: URL(fileURLWithPath: dest), kind: csi ? .csi : .tbi, sequences: idx.names, records: records,
                           elapsed: tracker.elapsed)
    }

    /// Intervals parsed from the lines that start in one BGZF block (done in parallel).
    private struct ParsedBlock {
        struct Record { var name: Int32; var beg: Int64; var end: Int64; var start: UInt64; var stop: UInt64; var line: Int32 }
        var names: [[UInt8]] = []
        var records: [Record] = []
        /// Local index and text of the first line that cannot be parsed (`name == -1` records mark it).
        var bad: [Int32: String] = [:]
        /// Lines starting and ending in this block.
        var lines: Int32 = 0
        /// Offset of a last line that continues into the following block(s).
        var tail: Int?
        /// Index just past the first newline (the end of a line started in an earlier block).
        var firstNewline: Int?
    }

    static func buildTabix(file: FileReader, config: TabixConfig, kind: BinningIndex.Kind, minShift: Int, depth: Int,
                           workload: Workload, tracker: ProgressTracker, cancel: CancellationToken?) throws -> (BinningIndex, Int) {
        let reader = BGZFBlockReader(file: file, workload: workload, cancel: cancel)
        let parser = TabixLineParser(config: config)
        var builder = TabixBuilder(config: config, kind: kind, minShift: minShift, depth: depth)
        var lineNo = 0
        var lastEnd: UInt64 = 0
        var reported: Int64 = 0
        var previousEndsWithNewline = true
        var pending: (bytes: [UInt8], start: UInt64)?
        let format = config.isVCF ? "VCF" : config.zeroBased ? "BED" : "tab-separated coordinates"

        /// Parses one line: nil for meta/empty lines, .failure for unparseable ones.
        func interval(_ line: UnsafeRawBufferPointer) -> Result<TabixLineParser.Interval, XipperError>? {
            if line.isEmpty || line[0] == config.metaChar { return nil }
            if config.format & 0x10000 != 0, Self.isBEDHeader(line) { return nil }
            guard let iv = parser.parse(line) else {
                let text = String(decoding: line.prefix(80), as: UTF8.self)
                return .failure(.corrupt("cannot be parsed as \(format): \(text.debugDescription)"))
            }
            return .success(iv)
        }

        /// A line assembled across blocks, handled sequentially.
        func handleSpanning(_ bytes: [UInt8], start: UInt64, stop: UInt64) throws {
            lineNo += 1
            try bytes.withUnsafeBytes { line in
                guard lineNo > config.skipLines, let r = interval(line) else { return }
                switch r {
                case let .success(iv):
                    try builder.push(name: UnsafeRawBufferPointer(rebasing: line[iv.name]), beg: iv.beg, end: iv.end, start: start, stop: stop, line: lineNo)
                case let .failure(e):
                    throw XipperError.corrupt("line \(lineNo) " + e.description.replacingOccurrences(of: "corrupt archive: ", with: ""))
                }
            }
        }

        while true {
            let batch = try reader.nextBatch()
            if batch.isEmpty { break }
            // Where the first line owned by each block starts.
            var owned = [Int?](repeating: nil, count: batch.count)
            for (k, block) in batch.enumerated() {
                if block.data.isEmpty { continue }
                if previousEndsWithNewline { owned[k] = 0 }
                previousEndsWithNewline = block.data.last == 10
            }
            let parsed = Slots<ParsedBlock>(batch.count)
            try parallelFor(batch.count, workload: workload, cancel: cancel) { k in
                let block = batch[k]
                var out = ParsedBlock()
                block.data.withUnsafeBytes { b in
                    guard let base = b.baseAddress, b.count > 0 else { return }
                    let firstNL = memchr(base, 10, b.count).map { base.distance(to: UnsafeRawPointer($0)) + 1 }
                    out.firstNewline = firstNL
                    var p = owned[k] ?? firstNL ?? b.count
                    while p < b.count {
                        guard let nl = memchr(base + p, 10, b.count - p) else { out.tail = p; break }
                        let e = base.distance(to: UnsafeRawPointer(nl))
                        let line = UnsafeRawBufferPointer(rebasing: b[p..<e])
                        let stop = e + 1 == b.count ? VirtualOffset.make(block.end, 0) : VirtualOffset.make(block.offset, e + 1)
                        let local = out.lines
                        out.lines += 1
                        switch interval(line) {
                        case nil: break
                        case let .success(iv)?:
                            let name = UnsafeRawBufferPointer(rebasing: line[iv.name])
                            if out.names.last.map({ !$0.elementsEqual(name) }) ?? true { out.names.append(Array(name)) }
                            out.records.append(.init(name: Int32(out.names.count - 1), beg: iv.beg, end: iv.end,
                                                     start: VirtualOffset.make(block.offset, p), stop: stop, line: local))
                        case let .failure(err)?:
                            out.bad[local] = err.description.replacingOccurrences(of: "corrupt archive: ", with: "")
                            out.records.append(.init(name: -1, beg: 0, end: 0, start: 0, stop: 0, line: local))
                        }
                        p = e + 1
                    }
                }
                parsed[k] = out
            }
            for (k, block) in batch.enumerated() {
                guard let pb = parsed.take(k) else { continue }
                if block.data.isEmpty { lastEnd = VirtualOffset.make(block.end, 0); continue }
                if var tail = pending {
                    if let nl = pb.firstNewline {
                        tail.bytes += block.data[..<(nl - 1)]
                        let stop = nl == block.data.count ? VirtualOffset.make(block.end, 0) : VirtualOffset.make(block.offset, nl)
                        try handleSpanning(tail.bytes, start: tail.start, stop: stop)
                        pending = nil
                    } else {
                        tail.bytes += block.data
                        pending = tail
                    }
                }
                let base = lineNo
                for r in pb.records {
                    let line = base + Int(r.line) + 1
                    if line <= config.skipLines { continue }
                    if r.name < 0 { throw XipperError.corrupt("line \(line) \(pb.bad[r.line]!)") }
                    try pb.names[Int(r.name)].withUnsafeBytes { name in
                        try builder.push(name: name, beg: r.beg, end: r.end, start: r.start, stop: r.stop, line: line)
                    }
                }
                lineNo += Int(pb.lines)
                if let t = pb.tail { pending = (Array(block.data[t...]), VirtualOffset.make(block.offset, t)) }
                lastEnd = VirtualOffset.make(block.end, 0)
            }
            let read = reader.bytesRead
            if read - reported >= 4 << 20 { tracker.add(bytes: read - reported); reported = read }
        }
        if let tail = pending { try handleSpanning(tail.bytes, start: tail.start, stop: lastEnd) }
        if !reader.endsWithEOFMarker {
            throw XipperError.corrupt("BGZF end-of-file marker missing: the file is probably truncated")
        }
        tracker.add(bytes: reader.bytesRead - reported)
        if builder.records == 0 { throw XipperError.corrupt("no data lines to index") }
        return (builder.finish(end: lastEnd), builder.records)
    }

    /// UCSC "track"/"browser" header lines, which BED files may carry before the data.
    private static func isBEDHeader(_ line: UnsafeRawBufferPointer) -> Bool {
        for word in ["track", "browser"] where line.count > word.utf8.count {
            if line.prefix(word.utf8.count).elementsEqual(word.utf8) && (line[word.utf8.count] == 32 || line[word.utf8.count] == 9) { return true }
        }
        return false
    }

    /// Compresses `data` as complete BGZF (blocks + EOF marker), as htslib writes indexes.
    static func compressBGZFBlocks(_ data: [UInt8], level: Int = 6) -> [UInt8] {
        var out: [UInt8] = []
        data.withUnsafeBytes { b in
            var i = 0
            while i < b.count {
                let n = min(BGZF.blockInput, b.count - i)
                out += BGZF.compressBlock(UnsafeRawBufferPointer(rebasing: b[i..<(i + n)]), level: BGZF.libdeflateLevel(forZlibLevel: level))
                i += n
            }
        }
        return out + BGZF.eofMarker
    }
}
