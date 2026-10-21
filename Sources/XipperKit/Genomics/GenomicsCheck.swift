import Foundation

/// What `genomicsCheck` found about one file.
public struct GenomicsCheckReport: Sendable {
    public enum Kind: String, Sendable { case vcf, bcf, bam, cram, bgzf, gzip, uncompressed }
    public var file: URL
    public var kind: Kind
    /// E.g. "VCFv4.3", "BCF 2.2", "BAM, 25 references", "CRAM 3.1".
    public var detail: String
    public var problems: [String]
    public var warnings: [String]
    public var indexes: [IndexCheckReport]
    public var cram: CRAMReport?
    public var elapsed: Double
    public var isOK: Bool { problems.isEmpty && indexes.allSatisfy(\.isOK) }
}

/// The parts of a VCF/BCF header that a structural check needs.
struct VariantHeader {
    var fileformat: String?
    var contigs = 0
    var samples = 0
    var hasColumnLine = false
    var bcfVersion: String?

    static let columns = "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO"

    /// Reads the header of a BGZF VCF (text lines up to `#CHROM`) or of a BCF.
    static func read(_ file: FileReader, limit: Int = 256 << 20) throws -> VariantHeader {
        let magic = try bgzfPrefix(file, count: 9)
        if magic.starts(with: Array("BCF\u{2}".utf8)), magic.count == 9 {
            var h = VariantHeader()
            h.bcfVersion = "\(magic[3]).\(magic[4])"
            let ltext = Int(UInt32(magic[5]) | UInt32(magic[6]) << 8 | UInt32(magic[7]) << 16 | UInt32(magic[8]) << 24)
            guard ltext <= limit else { throw XipperError.corrupt("BCF header declares \(ltext) bytes") }
            let all = try bgzfPrefix(file, count: 9 + ltext)
            guard all.count == 9 + ltext else { throw XipperError.corrupt("BCF header truncated") }
            var text = all[9...]
            if text.last == 0 { text = text.dropLast() }
            h.parse(lines: text.split(separator: 10).map { String(decoding: $0, as: UTF8.self) })
            return h
        }
        var h = VariantHeader()
        let reader = BGZFBlockReader(file: file, workload: .threads(2), batchBytes: 1 << 20)
        var buf: [UInt8] = []
        var lines: [String] = []
        outer: while let b = try reader.nextBlock() {
            buf += b.data
            while let nl = buf.firstIndex(of: 10) {
                let line = String(decoding: buf[..<nl], as: UTF8.self)
                buf.removeSubrange(...nl)
                lines.append(line)
                if !line.hasPrefix("##") { break outer }
            }
            if buf.count > limit { throw XipperError.limitExceeded("VCF header line longer than \(limit) bytes") }
            if lines.isEmpty && buf.count >= 2 && !buf.starts(with: Array("##".utf8)) { break }
        }
        if lines.isEmpty && !buf.isEmpty { lines.append(String(decoding: buf.prefix(4096), as: UTF8.self)) }
        h.parse(lines: lines)
        return h
    }

    mutating func parse(lines: [String]) {
        for line in lines {
            if fileformat == nil, line.hasPrefix("##fileformat=") { fileformat = String(line.dropFirst(13)) }
            if line.hasPrefix("##contig=") { contigs += 1 }
            if line.hasPrefix("#CHROM") {
                hasColumnLine = line.hasPrefix(Self.columns)
                let n = line.split(separator: "\t", omittingEmptySubsequences: false).count
                samples = max(0, n - 9)
            }
        }
    }
}

extension Xipper {
    /// One-stop genomics check (STUDIO.md §4.6): detects VCF.gz, BCF, BAM, CRAM or other BGZF data,
    /// verifies it (BGZF blocks and EOF marker, VCF/BCF header, BAM magic, CRAM CRCs and EOF
    /// container) and, with `checkIndexes`, every index next to it.
    public static func genomicsCheck(_ url: URL, checkIndexes: Bool = true, workload: Workload = .interactive,
                                     progress: ProgressHandler? = nil, cancel: CancellationToken? = nil) throws -> GenomicsCheckReport {
        let path = url.standardizedFileURL.path
        let name = url.lastPathComponent
        let file = try FileReader(path: path)
        let head = try file.read(at: 0, count: Int(min(file.size, 64)))
        let tracker = ProgressTracker(totalBytes: file.size, totalEntries: 1, handler: progress)
        var r = GenomicsCheckReport(file: URL(fileURLWithPath: path), kind: .bgzf, detail: "", problems: [], warnings: [],
                                    indexes: [], cram: nil, elapsed: 0)
        let lower = name.lowercased()
        let looksVCF = lower.contains(".vcf")

        if CRAMScanner.isCRAM(head) {
            r.kind = .cram
            var last: Int64 = 0
            let l = try CRAMScanner.scan(file, cancel: cancel) { off in tracker.add(bytes: off - last); last = off }
            r.cram = CRAMReport(version: "\(l.major).\(l.minor)", containers: l.containers, blocks: l.blocks, records: l.records,
                                bases: l.bases, hasEOFContainer: l.eof, problems: l.problems)
            r.detail = "CRAM \(l.major).\(l.minor), \(l.containers) containers, \(l.records) records"
            r.problems = l.problems
            if l.major < 3 { r.warnings.append("CRAM \(l.major).\(l.minor) has no CRC32 checksums: only the structure was checked") }
        } else if !BGZF.isBGZF(head) {
            let gz = head.starts(with: [0x1f, 0x8b])
            r.kind = gz ? .gzip : .uncompressed
            r.detail = gz ? "plain gzip" : "not compressed"
            if gz {
                r.problems.append("\(name) is plain gzip, not BGZF: tabix, bcftools and samtools need BGZF. Convert it with bgzf_convert (xipper bgzip --convert)")
            } else if looksVCF || lower.hasSuffix(".bed") || lower.hasSuffix(".gff") || lower.hasSuffix(".gff3") || lower.hasSuffix(".gtf") {
                r.problems.append("\(name) is not compressed: compress it with bgzf_compress (xipper bgzip) to index it")
            } else {
                throw XipperError.unsupported("\(name) is not a BGZF, BAM, BCF, VCF.gz or CRAM file")
            }
        } else {
            let (_, failures) = try BGZFVerifier.verify(path, workload: workload, tracker: tracker, cancel: cancel)
            r.problems += failures.map(\.reason)
            let magic = (try? bgzfPrefix(file, count: 16)) ?? []
            if magic.starts(with: Array("BAM\u{1}".utf8)) {
                r.kind = .bam
                if let n = try? bamReferenceCount(file) { r.detail = "BAM, \(n) reference sequences" } else {
                    r.detail = "BAM"
                    r.problems.append("BAM header is truncated")
                }
            } else if magic.starts(with: Array("BCF".utf8)) {
                r.kind = .bcf
                do {
                    let h = try VariantHeader.read(file)
                    r.detail = "BCF \(h.bcfVersion ?? "?")"
                    if h.bcfVersion != "2.1" && h.bcfVersion != "2.2" { r.problems.append("unknown BCF version \(h.bcfVersion ?? "?") (expected 2.1 or 2.2)") }
                    checkVariantHeader(h, into: &r)
                } catch let e as XipperError {
                    r.detail = "BCF"
                    r.problems.append("BCF header: \(e.description)")
                }
            } else if magic.starts(with: Array("##fileformat=VCF".utf8)) || looksVCF {
                r.kind = .vcf
                do {
                    let h = try VariantHeader.read(file)
                    r.detail = h.fileformat ?? "VCF"
                    checkVariantHeader(h, into: &r)
                } catch let e as XipperError {
                    r.detail = "VCF"
                    r.problems.append("VCF header: \(e.description)")
                }
            } else {
                r.kind = .bgzf
                let i = try bgzfInfo(url)
                r.detail = "BGZF, \(i.blocks) blocks"
            }
        }
        if checkIndexes {
            for idx in indexes(for: url) {
                do { r.indexes.append(try checkIndex(idx, data: url, cancel: cancel)) } catch let e as XipperError where e != .cancelled {
                    r.indexes.append(IndexCheckReport(index: idx, data: url, kind: IndexCheckReport.Kind(rawValue: idx.pathExtension.lowercased()) ?? .tbi,
                                                      references: 0, offsetsChecked: 0, problems: [e.description], warnings: []))
                }
            }
        }
        tracker.finish()
        r.elapsed = tracker.elapsed
        return r
    }

    private static func checkVariantHeader(_ h: VariantHeader, into r: inout GenomicsCheckReport) {
        guard let f = h.fileformat else {
            r.problems.append("missing ##fileformat header line: not a valid VCF")
            return
        }
        if !f.hasPrefix("VCFv") { r.problems.append("##fileformat=\(f) is not a VCF version") }
        if !h.hasColumnLine { r.problems.append("missing or malformed #CHROM header line (expected \(VariantHeader.columns.replacingOccurrences(of: "\t", with: " ")))") }
        r.detail += h.samples > 0 ? ", \(h.samples) samples" : ""
        if h.contigs == 0 { r.warnings.append("no ##contig lines in the header") }
    }
}
