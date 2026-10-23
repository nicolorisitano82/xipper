import Foundation

/// A container header (CRAMv3 §7) with where its blocks are.
struct CRAMContainer {
    var offset: Int64
    var length: Int
    var refID: Int32, start: Int32, span: Int32, records: Int32
    var counter: Int64, bases: Int64
    var blockCount: Int32
    var landmarks: [Int32]
    var dataOffset: Int64

    var isEOF: Bool { records == 0 && refID == -1 && start == 4_542_278 }
}

/// Sequential access to a CRAM 3.x file: file definition, SAM header, containers.
final class CRAMFileReader {
    let file: FileReader
    let major: UInt8, minor: UInt8
    let header: SAMHeader
    /// Offset of the first data container.
    let firstContainer: Int64

    init(_ url: URL) throws {
        file = try FileReader(path: url.path)
        let def = try file.read(at: 0, count: Int(min(26, file.size)))
        guard def.count == 26, def.starts(with: Array("CRAM".utf8)) else { throw XipperError.corrupt("not a CRAM file") }
        major = def[4]; minor = def[5]
        guard major == 3, minor <= 1 else { throw XipperError.unsupported("CRAM \(major).\(minor) (3.0 and 3.1 are supported)") }
        let hc = try Self.containerHeader(file, at: 26)
        var r = CRAMIO.Reader(try file.read(at: hc.dataOffset, count: hc.length))
        let first = try CRAMIO.readBlock(&r)
        guard first.contentType == .fileHeader, first.data.count >= 4 else { throw XipperError.corrupt("CRAM: missing SAM header block") }
        var hr = CRAMIO.Reader(first.data)
        let len = Int(try hr.int32())
        let text = String(decoding: try hr.bytes(min(len, hr.remaining)).prefix { $0 != 0 }, as: UTF8.self)
        var refs: [(String, Int)] = []
        for line in text.split(separator: "\n") where line.hasPrefix("@SQ\t") {
            var name = "", length = 0
            for f in line.split(separator: "\t") {
                if f.hasPrefix("SN:") { name = String(f.dropFirst(3)) }
                if f.hasPrefix("LN:") { length = Int(f.dropFirst(3)) ?? 0 }
            }
            refs.append((name, length))
        }
        header = SAMHeader(text: text, references: refs)
        firstContainer = hc.dataOffset + Int64(hc.length)
    }

    static func containerHeader(_ file: FileReader, at offset: Int64) throws -> CRAMContainer {
        var head = try file.read(at: offset, count: Int(min(Int64(1024), file.size - offset)))
        func parse() throws -> CRAMContainer {
            var r = CRAMIO.Reader(head)
            let length = Int(try r.int32())
            var c = CRAMContainer(offset: offset, length: length, refID: try r.itf8(), start: try r.itf8(), span: try r.itf8(),
                                  records: try r.itf8(), counter: try r.ltf8(), bases: try r.ltf8(), blockCount: try r.itf8(),
                                  landmarks: [], dataOffset: 0)
            let n = Int(try r.itf8())
            guard n >= 0, n < 1 << 20 else { throw XipperError.corrupt("CRAM: landmark count") }
            c.landmarks = try (0..<n).map { _ in try r.itf8() }
            let crcEnd = r.pos
            let stored = UInt32(bitPattern: try r.int32())
            let actual = head.withUnsafeBytes { CRC32.checksum(UnsafeRawBufferPointer(rebasing: $0[..<crcEnd])) }
            guard stored == actual else { throw XipperError.checksumMismatch(entry: "CRAM container at \(offset)", expected: stored, actual: actual) }
            guard length >= 0, offset + Int64(r.pos) + Int64(length) <= file.size else { throw XipperError.corrupt("CRAM: container exceeds the file") }
            c.dataOffset = offset + Int64(r.pos)
            return c
        }
        do { return try parse() } catch let e as XipperError {
            // Many landmarks: read the rest of the header.
            guard head.count == 1024, case .corrupt = e else { throw e }
            head = try file.read(at: offset, count: Int(min(Int64(1 << 22), file.size - offset)))
            return try parse()
        }
    }

    /// Data containers in file order (the EOF container ends the list).
    func containers() throws -> [CRAMContainer] {
        var out: [CRAMContainer] = []
        var off = firstContainer
        var sawEOF = false
        while off < file.size {
            let c = try Self.containerHeader(file, at: off)
            if c.isEOF { sawEOF = true; break }
            out.append(c)
            off = c.dataOffset + Int64(c.length)
        }
        if !sawEOF { throw XipperError.truncated(entry: "CRAM (no EOF container)", read: off, expected: off + 38) }
        return out
    }

    /// All records of a container, slices decoded in order.
    func decode(_ c: CRAMContainer, reference: ReferenceSet?, options: CRAMDecodeOptions) throws -> [AlignmentRecord] {
        var r = CRAMIO.Reader(try file.read(at: c.dataOffset, count: c.length))
        let chBlock = try CRAMIO.readBlock(&r)
        guard chBlock.contentType == .compressionHeader else { throw XipperError.corrupt("CRAM: container without compression header") }
        let ch = try CRAMCompressionHeader.parse(chBlock.data)
        let groups = header.readGroups
        var out: [AlignmentRecord] = []
        for landmark in c.landmarks {
            r.pos = Int(landmark)
            let sh = try CRAMIO.readBlock(&r)
            guard sh.contentType == .sliceHeader else { throw XipperError.corrupt("CRAM: landmark does not point at a slice header") }
            let s = try CRAMSliceHeader.parse(sh.data)
            let blocks = try (0..<Int(s.blockCount)).map { _ in try CRAMIO.readBlock(&r) }
            out += try CRAMDecoder.decodeSlice(s, blocks: blocks, ch: ch, header: header, readGroups: groups,
                                               reference: reference, options: options)
        }
        guard out.count == Int(c.records) else { throw XipperError.corrupt("CRAM: container declares \(c.records) records, decoded \(out.count)") }
        return out
    }
}

public struct CRAMConversionReport: Sendable {
    public var records: Int64
    public var containers: Int
    public var inputBytes: Int64
    public var outputBytes: Int64
    public var elapsed: Double
}

extension Xipper {
    /// CRAM 3.0/3.1 → BAM. `reference` is the FASTA the CRAM was written against (checked
    /// against the slices' MD5s); it may be nil only for CRAM without reference-based reads.
    /// MD and NM are regenerated for mapped reads that lack them, as samtools does.
    @discardableResult
    public static func cramToBAM(_ input: URL, output: URL, reference: URL?, overwrite: Bool = false, level: Int = 6,
                                 regenerateMDNM: Bool = true, workload: Workload = .interactive, progress: ProgressHandler? = nil,
                                 cancel: CancellationToken? = nil) throws -> CRAMConversionReport {
        let start = Date()
        if !overwrite && FileManager.default.fileExists(atPath: output.path) { throw XipperError.alreadyExists(path: output.path) }
        let cram = try CRAMFileReader(input)
        let ref = try reference.map { try ReferenceSet(fasta: $0) }
        let containers = try cram.containers()
        let writer = try BAMWriter(path: output.path, header: cram.header, level: level, workload: workload)
        let tracker = ProgressTracker(totalBytes: cram.file.size, totalEntries: 0, handler: progress)
        var records: Int64 = 0
        let batch = max(2, workload.workerCount * 2)
        var i = 0
        while i < containers.count {
            try cancel?.check()
            let part = Array(containers[i..<min(containers.count, i + batch)])
            let results = Slots<[AlignmentRecord]>(part.count)
            try parallelFor(part.count, workload: workload, cancel: cancel) { k in
                results[k] = try cram.decode(part[k], reference: ref, options: CRAMDecodeOptions(regenerateMDNM: regenerateMDNM))
            }
            for k in part.indices {
                let recs = results.take(k)!
                for r in recs { try writer.write(r) }
                records += Int64(recs.count)
                tracker.add(bytes: Int64(part[k].length))
            }
            i += batch
        }
        try writer.finish(overwrite: overwrite)
        tracker.finish()
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
        return CRAMConversionReport(records: records, containers: containers.count, inputBytes: cram.file.size,
                                    outputBytes: size ?? 0, elapsed: Date().timeIntervalSince(start))
    }
}

extension Xipper {
    /// BAM → CRAM 3.1 (or 3.0 with `minor: 0`) against the FASTA `reference`. @SQ lines get the
    /// M5 checksums CRAM requires; an M5 already present must match the reference.
    @discardableResult
    public static func bamToCRAM(_ input: URL, output: URL, reference: URL, minor: UInt8 = 1, overwrite: Bool = false,
                                 workload: Workload = .interactive, progress: ProgressHandler? = nil,
                                 cancel: CancellationToken? = nil) throws -> CRAMConversionReport {
        let start = Date()
        if !overwrite && FileManager.default.fileExists(atPath: output.path) { throw XipperError.alreadyExists(path: output.path) }
        let bam = try BAMReader(input, workload: workload)
        let ref = try ReferenceSet(fasta: reference)
        var header = bam.header
        if !header.text.contains("@SQ\t") { header.text += SAMHeader.sqLines(header.references) }
        header.text = try header.text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard line.hasPrefix("@SQ\t"), let sn = line.split(separator: "\t").first(where: { $0.hasPrefix("SN:") }) else { return String(line) }
            let name = String(sn.dropFirst(3))
            guard ref.contains(name) else { throw XipperError.invalidArgument("reference sequence \(name) not in \(reference.lastPathComponent)") }
            let md5 = ReferenceSet.md5Hex(try ref.sequence(name))
            if let m5 = line.split(separator: "\t").first(where: { $0.hasPrefix("M5:") }) {
                guard m5.dropFirst(3).lowercased() == md5 else { throw XipperError.invalidArgument("\(name): the BAM was aligned to another reference (M5 differs)") }
                return String(line)
            }
            return line + "\tM5:" + md5
        }.joined(separator: "\n")
        let groups = Dictionary(header.readGroups.enumerated().map { ($0.element, Int32($0.offset)) }, uniquingKeysWith: { a, _ in a })
        let sorted = header.text.contains("SO:coordinate")
        let options = CRAMEncoder.Options(minor: minor)

        let out = try OutputFile(path: output.path)
        var def = Array("CRAM".utf8) + [3, minor]
        def += Array(output.lastPathComponent.utf8.prefix(20)) + [UInt8](repeating: 0, count: max(0, 20 - output.lastPathComponent.utf8.count))
        try out.write(Array(def.prefix(26)))
        var text = Array(header.text.utf8)
        if text.last != 0x0A && !text.isEmpty { text.append(0x0A) }
        var hb: [UInt8] = []
        CRAMIO.int32(Int32(text.count), into: &hb)
        let headerBlock = CRAMIO.blockBytes(CRAMIO.Block(contentType: .fileHeader, data: hb + text))
        try out.write(CRAMEncoder.containerHeader(length: headerBlock.count, refID: 0, start: 0, span: 0, records: 0, counter: 0,
                                                  bases: 0, blockCount: 1, landmarks: [0]) + headerBlock)

        let tracker = ProgressTracker(totalBytes: (try? FileReader(path: input.path).size) ?? 0, totalEntries: 0, handler: progress)
        var records: Int64 = 0, containers = 0
        var pending: [[AlignmentRecord]] = []
        var current: [AlignmentRecord] = []
        let batch = max(2, workload.workerCount * 2)
        func flushBatch() throws {
            guard !pending.isEmpty else { return }
            let jobs = pending
            var counters: [Int64] = []
            var c = records
            for j in jobs { counters.append(c); c += Int64(j.count) }
            let results = Slots<[UInt8]>(jobs.count)
            let h = header
            try parallelFor(jobs.count, workload: workload, cancel: cancel) { k in
                results[k] = try CRAMEncoder.container(jobs[k], counter: counters[k], header: h, groups: groups, reference: ref, options: options)
            }
            for k in jobs.indices {
                let bytes = results.take(k)!
                try out.write(bytes)
                tracker.add(bytes: Int64(bytes.count) * 3)  // roughly the BAM bytes consumed
            }
            records = c
            containers += jobs.count
            pending = []
        }
        func close() throws {
            guard !current.isEmpty else { return }
            pending.append(current)
            current = []
            if pending.count >= batch { try flushBatch() }
        }
        while let r = try bam.next() {
            try cancel?.check()
            let refID = r.flag & 4 != 0 && r.refID < 0 ? -1 : r.refID
            if let last = current.last, sorted, (last.flag & 4 != 0 && last.refID < 0 ? -1 : last.refID) != refID { try close() }
            current.append(r)
            if current.count >= options.recordsPerContainer { try close() }
        }
        try close()
        try flushBatch()
        try out.write(CRAMScanner.eofContainer)
        try out.commit(overwrite: overwrite)
        tracker.finish()
        let size = (try? FileReader(path: output.path).size) ?? 0
        return CRAMConversionReport(records: records, containers: containers, inputBytes: (try? FileReader(path: input.path).size) ?? 0,
                                    outputBytes: size, elapsed: Date().timeIntervalSince(start))
    }
}

/// What the app and Quick Look show about an alignment file (BAM or CRAM), read from the header
/// and, for CRAM, the container headers (no record is decoded).
public struct AlignmentSummary: Sendable {
    public enum Kind: Sendable { case bam, cram(major: Int, minor: Int) }
    public var kind: Kind
    public var references: [String]
    public var sortOrder: String?
    public var readGroups: [String]
    /// Records and containers (CRAM only: BAM has no count without reading every record).
    public var records: Int64?
    public var containers: Int?
    public var isCRAM: Bool { if case .cram = kind { true } else { false } }
    public var formatName: String {
        switch kind { case .bam: "BAM"; case let .cram(a, b): "CRAM \(a).\(b)" }
    }
}

extension Xipper {
    /// nil when `url` is neither BAM nor CRAM.
    public static func alignmentSummary(_ url: URL) throws -> AlignmentSummary? {
        let file = try FileReader(path: url.path)
        let head = try file.read(at: 0, count: Int(min(file.size, 1 << 16)))
        func summary(_ kind: AlignmentSummary.Kind, _ h: SAMHeader) -> AlignmentSummary {
            let so = h.text.split(separator: "\n").first { $0.hasPrefix("@HD\t") }?
                .split(separator: "\t").first { $0.hasPrefix("SO:") }.map { String($0.dropFirst(3)) }
            return AlignmentSummary(kind: kind, references: h.references.map(\.name), sortOrder: so, readGroups: h.readGroups)
        }
        if CRAMScanner.isCRAM(head) {
            let c = try CRAMFileReader(url)
            let containers = try c.containers()
            var s = summary(.cram(major: Int(c.major), minor: Int(c.minor)), c.header)
            s.records = containers.reduce(0) { $0 + Int64($1.records) }
            s.containers = containers.count
            return s
        }
        guard BGZF.isBGZF(head), try head.withUnsafeBytes({ try BGZF.decompressFirstBlock($0) }).starts(with: BAM.magic) else { return nil }
        return summary(.bam, try BAMReader(url).header)
    }
}
