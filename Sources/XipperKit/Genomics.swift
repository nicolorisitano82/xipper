import Foundation

/// Genomics-specific behaviour (STUDIO.md §4.4).
enum Genomics {
    /// Text formats that tabix/bcftools/samtools/faidx expect to be BGZF-compressed.
    static let bgzfTextExtensions: Set<String> = [
        "vcf", "bed", "gff", "gff3", "gtf", "fa", "fasta", "fna", "faa", "fq", "fastq", "sam", "tsv", "pileup", "maf",
    ]

    /// BGZF containers and indexes: never worth recompressing inside an archive.
    static let compressedExtensions: Set<String> = ["bam", "cram", "bcf", "bgz", "sra", "bai", "crai", "tbi", "csi", "gzi"]

    /// Index files that become invalid when the data file they describe is recompressed.
    static let indexSuffixes = [".tbi", ".csi", ".gzi", ".fai"]

    static func prefersBGZF(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return bgzfTextExtensions.contains(name[name.index(after: dot)...].lowercased())
    }
}

public struct BGZFInfo: Sendable {
    public var blocks: Int
    public var compressedSize: Int64
    public var uncompressedSize: Int64
    /// False means the file was very likely truncated (spec: the EOF block is mandatory).
    public var endsWithEOFMarker: Bool
}

public struct ConversionReport: Sendable {
    public var output: URL
    public var inputBytes: Int64
    public var outputBytes: Int64
    public var elapsed: Double
    /// Existing tabix/BAM/.gzi indexes next to the output that no longer match its new layout.
    public var staleIndexes: [URL]
}

extension Xipper {
    /// Reads the BGZF block chain without decompressing (fast even on 100 GB BAMs).
    public static func bgzfInfo(_ url: URL) throws -> BGZFInfo {
        let r = try FileReader(path: url.standardizedFileURL.path)
        let l = try BGZFLayout.scan(r)
        return BGZFInfo(blocks: l.blocks, compressedSize: r.size, uncompressedSize: Int64(l.uncompressedSize),
                        endsWithEOFMarker: l.endsWithEOFMarker)
    }

    /// Writes the `.gzi` index of a BGZF file (htslib/`bgzip -r` format), by default next to it.
    @discardableResult
    public static func writeBGZFIndex(for url: URL, to indexURL: URL? = nil, overwrite: Bool = true) throws -> URL {
        let path = url.standardizedFileURL.path
        let layout = try BGZFLayout.scan(try FileReader(path: path))
        let dest = indexURL ?? URL(fileURLWithPath: path + ".gzi")
        let out = try OutputFile(path: dest.standardizedFileURL.path)
        try out.write(BGZFLayout.gziBytes(layout.index))
        try out.commit(overwrite: overwrite)
        return dest
    }

    /// Recompresses a gzip, BGZF or other single-file stream as `.bgzf` or `.gzip`.
    /// With `output == nil` the input is replaced atomically.
    @discardableResult
    public static func convert(_ input: URL, to output: URL? = nil, format: ArchiveFormat = .bgzf, level: Int? = nil,
                               writeIndex: Bool = false, workload: Workload = .interactive,
                               progress: ProgressHandler? = nil, cancel: CancellationToken? = nil) throws -> ConversionReport {
        guard format.isSingleFile else { throw XipperError.invalidArgument("conversion target must be a single-file format") }
        let inPath = input.standardizedFileURL.path
        let outPath = (output ?? input).standardizedFileURL.path
        let file = try FileReader(path: inPath)
        let head = try file.read(at: 0, count: Int(min(file.size, Int64(StreamCompression.detectLength))))
        let source = StreamCompression.detect(head)
        if source == .none { throw XipperError.unsupported("input is not compressed (use create)") }
        if source == format.compression && output == nil {
            return ConversionReport(output: input, inputBytes: file.size, outputBytes: file.size, elapsed: 0, staleIndexes: [])
        }
        let tracker = ProgressTracker(totalBytes: file.size, totalEntries: 1, handler: progress)
        let decoder = try source.decoder(threads: workload.workerCount)
        let encoder = try format.compression.encoder(level: level ?? format.defaultLevel, workload: workload, cancel: cancel)
        let out = try OutputFile(path: outPath)
        let sink: ByteSink = { try out.write($0) }
        let piece = UnsafeMutableRawPointer.allocate(byteCount: 4 << 20, alignment: 16384)
        defer { piece.deallocate() }
        var offset: Int64 = 0
        while true {
            try cancel?.check()
            let n = try file.readSome(at: offset, into: piece, count: 4 << 20)
            if n == 0 { break }
            offset += Int64(n)
            try decoder.process(UnsafeRawBufferPointer(start: piece, count: n)) { try encoder.process($0, sink) }
            tracker.add(bytes: Int64(n))
        }
        try decoder.finish { try encoder.process($0, sink) }
        try encoder.finish(sink)
        try out.flush()
        try out.commit(overwrite: output == nil)
        if writeIndex, let bgzf = encoder as? BGZFEncoder {
            let idx = try OutputFile(path: outPath + ".gzi")
            try idx.write(BGZFLayout.gziBytes(bgzf.index))
            try idx.commit(overwrite: true)
        }
        tracker.add(bytes: 0, entries: 1)
        tracker.finish()
        let stale = Genomics.indexSuffixes
            .filter { !(writeIndex && $0 == ".gzi") && $0 != ".fai" }
            .map { URL(fileURLWithPath: outPath + $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return ConversionReport(output: URL(fileURLWithPath: outPath), inputBytes: file.size, outputBytes: out.position,
                                elapsed: tracker.elapsed, staleIndexes: stale)
    }
}

/// Integrity check for BGZF files: every block's CRC and size, plus the mandatory EOF marker.
enum BGZFVerifier {
    static func verify(_ path: String, workload: Workload, tracker: ProgressTracker,
                       cancel: CancellationToken?) throws -> (blocks: Int, failures: [SkippedEntry]) {
        let name = (path as NSString).lastPathComponent
        let file = try FileReader(path: path)
        tracker.setTotals(bytes: file.size, entries: 1)
        let decoder = BGZFDecoder(workload: workload, cancel: cancel)
        let piece = UnsafeMutableRawPointer.allocate(byteCount: 8 << 20, alignment: 16384)
        defer { piece.deallocate() }
        do {
            var offset: Int64 = 0
            while true {
                let n = try file.readSome(at: offset, into: piece, count: 8 << 20)
                if n == 0 { break }
                offset += Int64(n)
                try decoder.process(UnsafeRawBufferPointer(start: piece, count: n)) { _ in }
                tracker.add(bytes: Int64(n))
            }
            try decoder.finish { _ in }
        } catch let e as XipperError where e != .cancelled {
            return (decoder.blockCount, [SkippedEntry(path: name, error: e)])
        }
        tracker.add(bytes: 0, entries: 1)
        if !decoder.endsWithEOFMarker {
            return (decoder.blockCount, [SkippedEntry(path: name, reason: "BGZF end-of-file marker missing: the file is probably truncated", problem: .missingEndMarker)])
        }
        return (decoder.blockCount, [])
    }
}

extension Xipper {
    /// Decompresses a single-file stream (gz, BGZF, bz2, xz, zst) to `output`
    /// (default: the input path without its compression extension).
    @discardableResult
    public static func decompressSingle(_ input: URL, to output: URL? = nil, overwrite: Bool = false,
                                        workload: Workload = .interactive, progress: ProgressHandler? = nil,
                                        cancel: CancellationToken? = nil) throws -> URL {
        let inPath = input.standardizedFileURL.path
        let dest = output?.standardizedFileURL.path
            ?? (input.deletingLastPathComponent().path + "/" + TarExtractor.singleFileName(inPath))
        let out = try OutputFile(path: dest)
        let tracker = ProgressTracker(totalBytes: (try? FileReader(path: inPath).size) ?? 0, totalEntries: 1, handler: progress)
        try stream(input, compress: false, workload: workload, cancel: cancel) { chunk in
            try out.write(chunk)
            tracker.add(bytes: Int64(chunk.count))
        }
        try out.flush()
        try out.commit(overwrite: overwrite)
        tracker.finish()
        return URL(fileURLWithPath: dest)
    }

    /// Streams `input` through BGZF compression (`compress`) or through the decompressor
    /// matching its content, handing every output chunk to `output` (e.g. standard output).
    public static func stream(_ input: URL, compress: Bool, level: Int? = nil, workload: Workload = .interactive,
                              cancel: CancellationToken? = nil, output: (UnsafeRawBufferPointer) throws -> Void) throws {
        let file = try FileReader(path: input.standardizedFileURL.path)
        let codec: StreamTransform
        if compress {
            codec = BGZFEncoder(level: level ?? ArchiveFormat.bgzf.defaultLevel, workload: workload, cancel: cancel)
        } else {
            let head = try file.read(at: 0, count: Int(min(file.size, Int64(StreamCompression.detectLength))))
            let c = StreamCompression.detect(head)
            if c == .none { throw XipperError.unsupported("not a compressed file") }
            codec = try c.decoder(threads: workload.workerCount)
        }
        try withoutActuallyEscaping(output) { sink in
            let piece = UnsafeMutableRawPointer.allocate(byteCount: 4 << 20, alignment: 16384)
            defer { piece.deallocate() }
            var offset: Int64 = 0
            while true {
                try cancel?.check()
                let n = try file.readSome(at: offset, into: piece, count: 4 << 20)
                if n == 0 { break }
                offset += Int64(n)
                try codec.process(UnsafeRawBufferPointer(start: piece, count: n), sink)
            }
            try codec.finish(sink)
            if let d = codec as? BGZFDecoder, !d.endsWithEOFMarker {
                throw XipperError.corrupt("BGZF end-of-file marker missing: the file is probably truncated")
            }
        }
    }
}
