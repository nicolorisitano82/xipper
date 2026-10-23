import Foundation

/// htslib's index builder (`hts_idx_push` / `hts_idx_finish` in hts.c 1.24) for files whose records
/// carry a numeric reference id: BAM (.bai, .csi) and BCF (.csi). Unlike tabix, the linear index
/// only covers mapped records, the meta bin counts mapped and placed-unmapped records, and records
/// without a reference are counted at the end (`n_no_coor`).
struct HTSIndexBuilder {
    let kind: BinningIndex.Kind
    let minShift: Int, depth: Int
    private var bins: [[UInt32: [BinningIndex.Chunk]]]
    private var linear: [[UInt64]]
    private var lastTid = Int32.min, saveTid: Int32 = -1
    private var lastBin = UInt32.max, saveBin = UInt32.max
    private var saveOff: UInt64, lastOff: UInt64, offBeg: UInt64
    private var lastCoor: Int64 = -1
    private var mapped: UInt64 = 0, unmapped: UInt64 = 0
    private(set) var noCoor: UInt64 = 0
    private(set) var records = 0
    private var metaBin: UInt32 { UInt32(((1 << (3 * (depth + 1))) - 1) / 7 + 1) }

    init(kind: BinningIndex.Kind, references: Int, minShift: Int = 14, depth: Int = 5, firstOffset: UInt64) {
        self.kind = kind
        self.minShift = minShift
        self.depth = depth
        bins = Array(repeating: [:], count: references)
        linear = Array(repeating: [], count: references)
        saveOff = firstOffset; lastOff = firstOffset; offBeg = firstOffset
    }

    /// `offset`: virtual offset just past the record; `beg`/`end` 0-based half-open.
    mutating func push(tid: Int32, beg begIn: Int64, end endIn: Int64, offset: UInt64, isMapped: Bool) throws {
        var beg = begIn, end = endIn
        if tid < 0 { beg = -1; end = 0 }
        if tid >= 0 && Int(tid) >= bins.count { throw XipperError.corrupt("record on reference \(tid), the header has \(bins.count)") }
        if tid >= 0 && end > 1 << Int64(minShift + 3 * depth) {
            throw XipperError.limitExceeded(kind == .bai ? "position \(end) is beyond the 512 Mbp limit of .bai indexes: build a CSI index (-c)"
                                                         : "position \(end) is beyond this CSI index's range")
        }
        if lastTid != tid || (lastTid >= 0 && tid < 0) {
            if tid >= 0 && noCoor > 0 { throw XipperError.corrupt("not sorted: mapped records after unplaced ones (sort by coordinate first)") }
            if tid >= 0 && (!bins[Int(tid)].isEmpty || !linear[Int(tid)].isEmpty) {
                throw XipperError.corrupt("not sorted: reference \(tid) appears again (sort by coordinate first)")
            }
            lastTid = tid
            lastBin = .max
        } else if tid >= 0 && lastCoor > beg {
            throw XipperError.corrupt("not sorted: position \(beg + 1) after \(lastCoor + 1) (sort by coordinate first)")
        }
        if tid >= 0 {
            if isMapped {
                let wb = Int(beg >> Int64(minShift)), we = Int((max(end, beg + 1) - 1) >> Int64(minShift))
                if linear[Int(tid)].count <= we { linear[Int(tid)] += [UInt64](repeating: .max, count: we + 1 - linear[Int(tid)].count) }
                for w in wb...we where linear[Int(tid)][w] == .max { linear[Int(tid)][w] = lastOff }
            }
        } else {
            noCoor += 1
        }
        let bin = BinningIndex.reg2bin(beg, end, minShift: minShift, depth: depth)
        if lastBin != bin {
            if saveBin != .max && saveTid >= 0 { bins[Int(saveTid)][saveBin, default: []].append(.init(begin: saveOff, end: lastOff)) }
            if lastBin == .max && saveBin != .max && saveTid >= 0 {  // change of reference: its meta information
                bins[Int(saveTid)][metaBin, default: []] += [.init(begin: offBeg, end: lastOff), .init(begin: mapped, end: unmapped)]
                mapped = 0; unmapped = 0
                offBeg = lastOff
            }
            saveOff = lastOff
            saveBin = bin; lastBin = bin
            saveTid = tid
        }
        if isMapped { mapped += 1 } else { unmapped += 1 }
        lastOff = offset
        lastCoor = beg
        records += 1
    }

    mutating func finish(finalOffset: UInt64, names: [String] = [], config: TabixConfig? = nil) -> BinningIndex {
        if saveTid >= 0 && saveBin != .max {
            bins[Int(saveTid)][saveBin, default: []].append(.init(begin: saveOff, end: finalOffset))
            bins[Int(saveTid)][metaBin, default: []] += [.init(begin: offBeg, end: finalOffset), .init(begin: mapped, end: unmapped)]
        }
        var idx = BinningIndex(kind: kind, minShift: minShift, depth: depth, config: config, names: names, references: [], unplaced: noCoor)
        let nBins = metaBin - 1
        for t in bins.indices {
            var lin = linear[t]
            for l in stride(from: lin.count - 2, through: 0, by: -1) where lin[l] == .max { lin[l] = lin[l + 1] }
            var b = bins[t]
            // compress_binning: a bin whose chunks span less than 64 KiB of compressed data joins its parent.
            for level in stride(from: depth, to: 0, by: -1) {
                let first = UInt32(((1 << (3 * level)) - 1) / 7)
                for id in b.keys.sorted() where id < nBins && id >= first {
                    var chunks = b[id]!
                    if level < depth && chunks.count > 1 { chunks.sort { $0.begin < $1.begin } }
                    guard (chunks.last!.end >> 16) &- (chunks.first!.begin >> 16) < 0x10000 else { b[id] = chunks; continue }
                    let parent = (id - 1) >> 3
                    guard b[parent] != nil else { b[id] = chunks; continue }
                    b[parent]! += chunks
                    b[id] = nil
                }
            }
            var ref = BinningIndex.Reference()
            for id in b.keys.sorted() where id != metaBin {
                var merged: [BinningIndex.Chunk] = []
                for c in b[id]!.sorted(by: { $0.begin < $1.begin }) {
                    if let last = merged.last, last.end >> 16 >= c.begin >> 16 { merged[merged.count - 1].end = max(last.end, c.end) } else { merged.append(c) }
                }
                let bottom = BinningIndex.binBottom(id, depth: depth)
                ref.bins.append(.init(id: id, loffset: kind == .csi && bottom < lin.count ? lin[bottom] : 0, chunks: merged))
            }
            if let meta = b[metaBin] { ref.bins.append(.init(id: metaBin, loffset: 0, chunks: meta)) }
            if kind != .csi { ref.linear = lin }
            idx.references.append(ref)
        }
        return idx
    }

    /// htslib's CSI depth for references up to `maxLength` bases.
    static func depth(maxLength: Int64, minShift: Int) -> Int {
        var n = 0, s: Int64 = 1 << Int64(minShift)
        let m = maxLength + 256
        while m > s { n += 1; s <<= 3 }
        return n
    }
}

/// Feeds a BGZF stream block by block and hands out bytes with their virtual offsets.
struct BGZFCursor {
    private var buf: [UInt8] = []
    private var pos = 0
    /// (start in `buf` of a block's data, compressed offset, compressed end) of the buffered blocks.
    private var blocks: [(start: Int, offset: UInt64, end: UInt64)] = []
    private let reader: BGZFBlockReader
    private(set) var atEnd = false
    private var lastEnd: UInt64 = 0

    init(_ reader: BGZFBlockReader) { self.reader = reader }

    /// Virtual offset of the next unread byte (a block boundary is the next block at 0, as htslib).
    var tell: UInt64 {
        for b in blocks.reversed() where b.start <= pos {
            let next = blocks.first { $0.start > b.start }
            if let next, pos >= next.start { continue }
            let blockLen = (next?.start ?? buf.count) - b.start
            if pos - b.start == blockLen { return VirtualOffset.make(b.end, 0) }
            return VirtualOffset.make(b.offset, pos - b.start)
        }
        return VirtualOffset.make(lastEnd, 0)
    }

    /// Makes `n` bytes available; false at the end of the data.
    mutating func need(_ n: Int) throws -> Bool {
        while buf.count - pos < n {
            guard let b = try reader.nextBlock() else { atEnd = true; return false }
            lastEnd = b.end
            if b.data.isEmpty { continue }
            compact()
            blocks.append((buf.count, b.offset, b.end))
            buf += b.data
        }
        return true
    }

    private mutating func compact() {
        guard pos > 1 << 20 else { return }
        let keep = blocks.lastIndex { $0.start <= pos } ?? 0
        let cut = blocks[keep].start
        buf.removeSubrange(0..<cut)
        pos -= cut
        blocks = blocks[keep...].map { ($0.start - cut, $0.offset, $0.end) }
    }

    mutating func bytes(_ n: Int) throws -> ArraySlice<UInt8> {
        guard try need(n) else { throw XipperError.corrupt("data ends inside a record") }
        defer { pos += n }
        return buf[pos..<(pos + n)]
    }

    mutating func u32() throws -> UInt32 {
        let b = try bytes(4)
        return UInt32(b[b.startIndex]) | UInt32(b[b.startIndex + 1]) << 8 | UInt32(b[b.startIndex + 2]) << 16 | UInt32(b[b.startIndex + 3]) << 24
    }
}

public struct IndexBuildReport: Sendable {
    public var index: URL
    /// "bai", "csi", "crai", "fai", "tbi"…
    public var kind: String
    public var records: Int
    public var sequences: Int
    public var elapsed: Double
}

extension Xipper {
    /// Builds the usual index of a genomics file, as htslib tools do:
    /// BAM → .bai (`samtools index`, or .csi with `csi`), CRAM → .crai, BCF → .csi (`bcftools index`),
    /// FASTA/FASTQ (plain or BGZF) → .fai (`samtools faidx`, plus .gzi when compressed),
    /// VCF/BED/GFF/SAM.gz → .tbi/.csi (`tabix`).
    @discardableResult
    public static func buildIndex(_ url: URL, csi: Bool = false, minShift: Int = 14, to dest: URL? = nil, overwrite: Bool = true,
                                  workload: Workload = .interactive, progress: ProgressHandler? = nil,
                                  cancel: CancellationToken? = nil) throws -> IndexBuildReport {
        let start = Date()
        let file = try FileReader(path: url.path)
        let head = try file.read(at: 0, count: Int(min(file.size, 1 << 16)))
        func finish(_ path: String, _ kind: String, _ records: Int, _ seqs: Int) -> IndexBuildReport {
            IndexBuildReport(index: URL(fileURLWithPath: path), kind: kind, records: records, sequences: seqs, elapsed: Date().timeIntervalSince(start))
        }
        if head.starts(with: [0x1F, 0x8B]) { try BGZFBlockReader.requireBGZF(file, name: url.lastPathComponent) }
        if CRAMScanner.isCRAM(head) {
            let path = dest?.path ?? url.path + ".crai"
            let (n, slices) = try writeCRAI(url, to: path, overwrite: overwrite, cancel: cancel)
            return finish(path, "crai", n, slices)
        }
        if BGZF.isBGZF(head) {
            let first = try head.withUnsafeBytes { try BGZF.decompressFirstBlock($0) }
            if first.starts(with: BAM.magic) {
                let path = dest?.path ?? url.path + (csi ? ".csi" : ".bai")
                let (n, refs) = try writeBAMIndex(file, to: path, csi: csi, minShift: minShift, overwrite: overwrite,
                                                  workload: workload, progress: progress, cancel: cancel)
                return finish(path, csi ? "csi" : "bai", n, refs)
            }
            if first.starts(with: Array("BCF\u{2}".utf8)) {
                let path = dest?.path ?? url.path + ".csi"
                let (n, refs) = try writeBCFIndex(file, to: path, minShift: minShift, overwrite: overwrite, workload: workload, cancel: cancel)
                return finish(path, "csi", n, refs)
            }
            if first.first == UInt8(ascii: ">") || first.first == UInt8(ascii: "@") && TabixConfig.preset(forFileName: url.lastPathComponent) == nil {
                let path = dest?.path ?? url.path + ".fai"
                let n = try writeFAI(url, to: path, overwrite: overwrite, workload: workload, cancel: cancel)
                try writeBGZFIndex(for: url)
                return finish(path, "fai", n, n)
            }
            let r = try tabixIndex(url, csi: csi, minShift: minShift, to: dest, overwrite: overwrite, workload: workload, progress: progress, cancel: cancel)
            return finish(r.index.path, r.kind.rawValue, r.records, r.sequences.count)
        }
        if head.first == UInt8(ascii: ">") || head.first == UInt8(ascii: "@") {
            let path = dest?.path ?? url.path + ".fai"
            let n = try writeFAI(url, to: path, overwrite: overwrite, workload: workload, cancel: cancel)
            return finish(path, "fai", n, n)
        }
        throw XipperError.unsupported("\(url.lastPathComponent): no index for this kind of file (BAM, CRAM, BCF, FASTA/FASTQ, or BGZF VCF/BED/GFF/SAM)")
    }

    /// The index `buildIndex` writes for `url`: path and kind ("bai", "csi", "crai", "fai", "tbi").
    public static func defaultIndex(for url: URL, csi: Bool = false) throws -> (url: URL, kind: String) {
        let file = try FileReader(path: url.path)
        let head = try file.read(at: 0, count: Int(min(file.size, 1 << 16)))
        func ext(_ e: String) -> (URL, String) { (URL(fileURLWithPath: url.path + "." + e), e) }
        if CRAMScanner.isCRAM(head) { return ext("crai") }
        if head.starts(with: [0x1F, 0x8B]) { try BGZFBlockReader.requireBGZF(file, name: url.lastPathComponent) }
        if BGZF.isBGZF(head) {
            let first = try head.withUnsafeBytes { try BGZF.decompressFirstBlock($0) }
            if first.starts(with: BAM.magic) { return ext(csi ? "csi" : "bai") }
            if first.starts(with: Array("BCF\u{2}".utf8)) { return ext("csi") }
            if first.first == UInt8(ascii: ">") || first.first == UInt8(ascii: "@") && TabixConfig.preset(forFileName: url.lastPathComponent) == nil { return ext("fai") }
            return ext(csi ? "csi" : "tbi")
        }
        if head.first == UInt8(ascii: ">") || head.first == UInt8(ascii: "@") { return ext("fai") }
        throw XipperError.unsupported("\(url.lastPathComponent): no index for this kind of file (BAM, CRAM, BCF, FASTA/FASTQ, or BGZF VCF/BED/GFF/SAM)")
    }

    // MARK: BAM

    static func writeBAMIndex(_ file: FileReader, to path: String, csi: Bool, minShift: Int, overwrite: Bool, workload: Workload,
                              progress: ProgressHandler?, cancel: CancellationToken?) throws -> (Int, Int) {
        var cur = BGZFCursor(BGZFBlockReader(file: file, workload: workload, cancel: cancel))
        guard Array(try cur.bytes(4)) == BAM.magic else { throw XipperError.corrupt("not a BAM file") }
        _ = try cur.bytes(Int(try cur.u32()))
        let nRef = Int(try cur.u32())
        var lengths: [Int64] = []
        for _ in 0..<nRef {
            _ = try cur.bytes(Int(try cur.u32()))
            lengths.append(Int64(try cur.u32()))
        }
        let shift = csi ? minShift : 14
        let depth = csi ? HTSIndexBuilder.depth(maxLength: lengths.max() ?? 0, minShift: shift) : 5
        var b = HTSIndexBuilder(kind: csi ? .csi : .bai, references: nRef, minShift: shift, depth: depth, firstOffset: cur.tell)
        let tracker = ProgressTracker(totalBytes: file.size, totalEntries: 0, handler: progress)
        var n = 0
        while try cur.need(4) {
            let size = Int(try cur.u32())
            guard size >= 32 else { throw XipperError.corrupt("BAM record too short") }
            let r = try cur.bytes(size)
            func i32(_ o: Int) -> Int32 { Int32(bitPattern: UInt32(r[r.startIndex + o]) | UInt32(r[r.startIndex + o + 1]) << 8 | UInt32(r[r.startIndex + o + 2]) << 16 | UInt32(r[r.startIndex + o + 3]) << 24) }
            let tid = i32(0), pos = Int64(i32(4))
            let nameLen = Int(r[r.startIndex + 8]), nCigar = Int(r[r.startIndex + 12]) | Int(r[r.startIndex + 13]) << 8
            let flag = Int(r[r.startIndex + 14]) | Int(r[r.startIndex + 15]) << 8
            var rlen: Int64 = 0
            if flag & 4 == 0 {
                for k in 0..<nCigar {
                    let c = UInt32(bitPattern: i32(32 + nameLen + 4 * k))
                    if [0, 2, 3, 7, 8].contains(c & 0xF) { rlen += Int64(c >> 4) }
                }
            }
            if rlen == 0 { rlen = 1 }
            try b.push(tid: tid, beg: pos, end: pos + rlen, offset: cur.tell, isMapped: flag & 4 == 0)
            n += 1
            if n & 0xFFFF == 0 { try cancel?.check(); tracker.add(bytes: 0) }
        }
        let idx = b.finish(finalOffset: cur.tell)
        let bytes = idx.serialize()
        let out = try OutputFile(path: path)
        try out.write(csi ? compressBGZFBlocks(bytes) : bytes)
        try out.commit(overwrite: overwrite)
        tracker.finish()
        return (n, nRef)
    }

    // MARK: BCF

    static func writeBCFIndex(_ file: FileReader, to path: String, minShift: Int, overwrite: Bool, workload: Workload,
                              cancel: CancellationToken?) throws -> (Int, Int) {
        var cur = BGZFCursor(BGZFBlockReader(file: file, workload: workload, cancel: cancel))
        guard Array(try cur.bytes(5)).starts(with: Array("BCF\u{2}".utf8)) else { throw XipperError.corrupt("not a BCF file") }
        let text = String(decoding: try cur.bytes(Int(try cur.u32())), as: UTF8.self)
        // Contigs in header order (IDX= overrides the position), with their lengths.
        var contigs: [(Int, Int64)] = []
        var dictionary = 0
        var maxLen: Int64 = 0
        for line in text.split(separator: "\n") where line.hasPrefix("##contig=<") {
            var idx = dictionary
            for field in line.dropFirst(10).dropLast().split(separator: ",") {
                if field.hasPrefix("length="), let l = Int64(field.dropFirst(7)) { maxLen = max(maxLen, l) }
                if field.hasPrefix("IDX="), let i = Int(field.dropFirst(4)) { idx = i }
            }
            contigs.append((idx, maxLen))
            dictionary = idx + 1
        }
        let nRef = (contigs.map(\.0).max() ?? -1) + 1
        if maxLen == 0 { maxLen = 1 << 31 }
        var b = HTSIndexBuilder(kind: .csi, references: nRef, minShift: minShift,
                                depth: HTSIndexBuilder.depth(maxLength: maxLen, minShift: minShift), firstOffset: cur.tell)
        var n = 0
        while try cur.need(8) {
            let shared = Int(try cur.u32()), indiv = Int(try cur.u32())
            let r = try cur.bytes(shared)
            _ = try cur.bytes(indiv)
            guard shared >= 12 else { throw XipperError.corrupt("BCF record too short") }
            func i32(_ o: Int) -> Int32 { Int32(bitPattern: UInt32(r[r.startIndex + o]) | UInt32(r[r.startIndex + o + 1]) << 8 | UInt32(r[r.startIndex + o + 2]) << 16 | UInt32(r[r.startIndex + o + 3]) << 24) }
            let rid = i32(0), pos = Int64(i32(4)), rlen = Int64(i32(8))
            try b.push(tid: rid, beg: pos, end: pos + rlen, offset: cur.tell, isMapped: true)
            n += 1
            if n & 0xFFFF == 0 { try cancel?.check() }
        }
        let idx = b.finish(finalOffset: cur.tell)
        let out = try OutputFile(path: path)
        try out.write(compressBGZFBlocks(idx.serialize()))
        try out.commit(overwrite: overwrite)
        return (n, nRef)
    }

    // MARK: CRAM

    /// .crai (CRAMv3 §12): one line per slice (per reference for multi-reference slices), gzip.
    static func writeCRAI(_ url: URL, to path: String, overwrite: Bool, cancel: CancellationToken?) throws -> (Int, Int) {
        let cram = try CRAMFileReader(url)
        var lines = ""
        var records = 0, slices = 0
        for c in try cram.containers() {
            try cancel?.check()
            var r = CRAMIO.Reader(try cram.file.read(at: c.dataOffset, count: c.length))
            let chBlock = try CRAMIO.readBlock(&r)
            let ch = try CRAMCompressionHeader.parse(chBlock.data)
            for (k, landmark) in c.landmarks.enumerated() {
                r.pos = Int(landmark)
                let sh = try CRAMIO.readBlock(&r)
                let s = try CRAMSliceHeader.parse(sh.data)
                let blocks = try (0..<Int(s.blockCount)).map { _ in try CRAMIO.readBlock(&r) }
                let end = k + 1 < c.landmarks.count ? Int(c.landmarks[k + 1]) : c.length
                let size = end - Int(landmark)
                records += Int(s.records)
                slices += 1
                let prefix = "\(c.offset)\t\(landmark)\t\(size)"
                if s.refID != -2 {
                    lines += s.refID >= 0 ? "\(s.refID)\t\(s.start)\t\(s.span)\t\(prefix)\n" : "-1\t0\t0\t\(prefix)\n"
                    continue
                }
                // Multi-reference slice: one line per reference, spans from the records.
                let recs = try CRAMDecoder.decodeSlice(s, blocks: blocks, ch: ch, header: cram.header, readGroups: [],
                                                      reference: nil, options: CRAMDecodeOptions(regenerateMDNM: false))
                var spans: [(Int32, Int64, Int64)] = []
                for x in recs {
                    let id: Int32 = x.refID >= 0 ? x.refID : -1
                    let beg = Int64(x.pos) + 1, end = id >= 0 ? Int64(x.pos) + Int64(x.flag & 4 != 0 ? 1 : max(1, x.referenceLength)) : 0
                    if let last = spans.last, last.0 == id {
                        spans[spans.count - 1] = (id, min(last.1, beg), max(last.2, end))
                    } else {
                        spans.append((id, beg, end))
                    }
                }
                for (id, b, e) in spans { lines += id >= 0 ? "\(id)\t\(b)\t\(e - b + 1)\t\(prefix)\n" : "-1\t0\t0\t\(prefix)\n" }
            }
        }
        let gz = CRAMIO.compress(.gzip, Array(lines.utf8), order: 6) ?? []
        let out = try OutputFile(path: path)
        try out.write(gz)
        try out.commit(overwrite: overwrite)
        return (records, slices)
    }

    // MARK: FASTA / FASTQ

    /// `samtools faidx`: NAME, LENGTH, OFFSET, LINEBASES, LINEWIDTH (and QUALOFFSET for FASTQ).
    /// Offsets are in the uncompressed data, as htslib does with BGZF files.
    static func writeFAI(_ url: URL, to path: String, overwrite: Bool, workload: Workload, cancel: CancellationToken?) throws -> Int {
        let file = try FileReader(path: url.path)
        let head = try file.read(at: 0, count: Int(min(file.size, 64)))
        var lines = ""
        var count = 0
        // Line scanner over the (decompressed) stream.
        var name = "", length = 0, lineBases = 0, lineWidth = 0, offset: Int64 = 0, qualOffset: Int64 = -1
        var fastq = false, inQual = false, qualLen = 0, seqLinesDone = false, lastLineShort = false
        var pos: Int64 = 0
        var line: [UInt8] = []
        func flush() {
            guard !name.isEmpty else { return }
            lines += fastq ? "\(name)\t\(length)\t\(offset)\t\(lineBases)\t\(lineWidth)\t\(qualOffset)\n" : "\(name)\t\(length)\t\(offset)\t\(lineBases)\t\(lineWidth)\n"
            count += 1
        }
        func handle(_ l: [UInt8], start: Int64, end: Int64) throws {
            let width = Int(end - start)
            var content = l
            if content.last == 0x0D { content.removeLast() }
            if !inQual, let first = content.first, first == UInt8(ascii: ">") || (first == UInt8(ascii: "@") && (name.isEmpty || seqLinesDone)) {
                flush()
                fastq = first == UInt8(ascii: "@")
                let title = content.dropFirst().split(whereSeparator: { $0 == 0x20 || $0 == 0x09 }).first ?? []
                name = String(decoding: title, as: UTF8.self)
                length = 0; lineBases = 0; lineWidth = 0; offset = end; qualOffset = -1; inQual = false; qualLen = 0
                seqLinesDone = false; lastLineShort = false
                return
            }
            if fastq && !inQual && content.first == UInt8(ascii: "+") { inQual = true; qualOffset = end; return }
            if inQual {
                qualLen += content.count
                if qualLen >= length { inQual = false; seqLinesDone = true }
                return
            }
            guard !name.isEmpty, !content.isEmpty else { return }
            if lastLineShort { throw XipperError.corrupt("\(name): lines of different lengths (samtools faidx requires uniform lines)") }
            if lineBases == 0 { lineBases = content.count; lineWidth = width }
            else if content.count != lineBases || width != lineWidth {
                if content.count > lineBases { throw XipperError.corrupt("\(name): lines of different lengths (samtools faidx requires uniform lines)") }
                lastLineShort = true
            }
            length += content.count
            if fastq { seqLinesDone = true }
        }
        func feed(_ data: UnsafeRawBufferPointer) throws {
            var s = 0
            for i in 0..<data.count where data[i] == 0x0A {
                line.append(contentsOf: data[s..<i])
                let lineStart = pos + Int64(s) - Int64(line.count - (i - s))
                try handle(line, start: lineStart, end: pos + Int64(i) + 1)
                line.removeAll(keepingCapacity: true)
                s = i + 1
            }
            line.append(contentsOf: data[s...])
            pos += Int64(data.count)
        }
        if BGZF.isBGZF(head) {
            let reader = BGZFBlockReader(file: file, workload: workload, cancel: cancel)
            while let b = try reader.nextBlock() { try b.data.withUnsafeBytes { try feed($0) } }
        } else {
            var off: Int64 = 0
            while off < file.size {
                try cancel?.check()
                let chunk = try file.read(at: off, count: Int(min(Int64(4 << 20), file.size - off)))
                try chunk.withUnsafeBytes { try feed($0) }
                off += Int64(chunk.count)
            }
        }
        if !line.isEmpty { try handle(line, start: pos - Int64(line.count), end: pos + 1) }
        flush()
        let out = try OutputFile(path: path)
        try out.write(Array(lines.utf8))
        try out.commit(overwrite: overwrite)
        return count
    }
}
