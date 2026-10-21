import CDeflate
import Foundation
import Synchronization

/// BGZF ("Blocked GNU Zip Format", SAM/BAM specification v1 §4.1): a series of independent
/// gzip members of at most 64 KiB each, carrying their size in a "BC" extra subfield, ending
/// with a fixed 28-byte empty block. It is the compression layer of bgzip'ed VCF/BED/FASTA,
/// BAM and BCF, and allows random access through tabix/BAM indexes.
enum BGZF {
    /// Uncompressed bytes per block. htslib uses the same value so that even an
    /// incompressible block plus headers stays within 64 KiB.
    static let blockInput = 0xFF00
    static let maxBlockSize = 0x10000
    static let headerSize = 18
    static let footerSize = 8

    /// End-of-file marker: an empty block, byte-exact as mandated by the specification.
    static let eofMarker: [UInt8] = [
        0x1f, 0x8b, 0x08, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x06, 0x00, 0x42, 0x43, 0x02, 0x00,
        0x1b, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]

    /// htslib's zlib → libdeflate level table (measured against bgzip 1.24: identical sizes).
    static func libdeflateLevel(forZlibLevel level: Int) -> Int {
        [0, 1, 2, 3, 5, 6, 7, 8, 10, 12][max(0, min(9, level))]
    }

    /// True if `head` starts with a gzip member carrying the BGZF "BC" extra subfield.
    static func isBGZF(_ head: [UInt8]) -> Bool {
        head.withUnsafeBytes { blockSize(at: $0) != nil }
    }

    /// Total size of the block starting at `b` (from its BSIZE field), or nil if `b` does not start
    /// with a BGZF block header. Needs at least the gzip header plus the extra field.
    static func blockSize(at b: UnsafeRawBufferPointer) -> Int? {
        guard b.count >= headerSize, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8, b[3] & 4 != 0 else { return nil }
        let xlen = Int(b[10]) | Int(b[11]) << 8
        guard b.count >= 12 + xlen else { return nil }
        var i = 12
        while i + 4 <= 12 + xlen {
            let slen = Int(b[i + 2]) | Int(b[i + 3]) << 8
            if b[i] == 66 && b[i + 1] == 67 && slen == 2 && i + 6 <= 12 + xlen {
                return (Int(b[i + 4]) | Int(b[i + 5]) << 8) + 1
            }
            i += 4 + slen
        }
        return nil
    }

    // MARK: block codec

    private static let compressors = Mutex<[Int32: [UInt]]>([:])

    /// Compresses one block (≤ `blockInput` bytes) into a complete BGZF member.
    static func compressBlock(_ data: UnsafeRawBufferPointer, level: Int) -> [UInt8] {
        let lvl = Int32(max(0, min(12, level)))
        var block = deflateBlock(data, level: lvl)
        if block.count + headerSize + footerSize > maxBlockSize {
            block = deflateBlock(data, level: 0)  // stored blocks always fit: 0xFF00 + 5 + 26 < 64 KiB
        }
        let total = headerSize + block.count + footerSize
        var w = ByteWriter(capacity: total)
        w.append([0x1f, 0x8b, 0x08, 0x04, 0, 0, 0, 0, 0x00, 0xff, 0x06, 0x00, 0x42, 0x43, 0x02, 0x00])
        w.u16(UInt16(total - 1))
        w.append(block)
        w.u32(CRC32.checksum(data))
        w.u32(UInt32(data.count))
        return w.bytes
    }

    private static func deflateBlock(_ data: UnsafeRawBufferPointer, level: Int32) -> [UInt8] {
        let cached = compressors.withLock { $0[level]?.popLast() }
        let c = cached.flatMap { OpaquePointer(bitPattern: $0) } ?? libdeflate_alloc_compressor(level)!
        defer {
            let bits = UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(c)))
            compressors.withLock { $0[level, default: []].append(bits) }
        }
        let bound = libdeflate_deflate_compress_bound(c, data.count)
        return [UInt8](unsafeUninitializedCapacity: bound) { buf, n in
            n = libdeflate_deflate_compress(c, data.baseAddress, data.count, buf.baseAddress, bound)
        }
    }

    /// Decompresses and verifies one complete block. Returns its content.
    static func decompressBlock(_ block: UnsafeRawBufferPointer, decompressor d: OpaquePointer) throws -> [UInt8] {
        guard let size = blockSize(at: block), size == block.count, size >= headerSize + footerSize else {
            throw XipperError.corrupt("invalid BGZF block header")
        }
        let xlen = Int(block[10]) | Int(block[11]) << 8
        guard 12 + xlen <= size - footerSize else { throw XipperError.corrupt("invalid BGZF extra field length") }
        let cdata = UnsafeRawBufferPointer(rebasing: block[(12 + xlen)..<(size - footerSize)])
        let crc = block.loadUnaligned(fromByteOffset: size - 8, as: UInt32.self).littleEndian
        let isize = Int(block.loadUnaligned(fromByteOffset: size - 4, as: UInt32.self).littleEndian)
        if isize > maxBlockSize { throw XipperError.corrupt("BGZF block declares \(isize) bytes (max 65536)") }
        var ok = false
        let out = [UInt8](unsafeUninitializedCapacity: max(isize, 1)) { buf, n in
            var actual = 0
            let r = libdeflate_deflate_decompress(d, cdata.baseAddress, cdata.count, buf.baseAddress, isize, &actual)
            ok = r == LIBDEFLATE_SUCCESS && actual == isize
            n = ok ? actual : 0
        }
        if !ok { throw XipperError.corrupt("invalid deflate data in BGZF block") }
        if CRC32.checksum(out) != crc { throw XipperError.integrity(entry: "BGZF block", detail: "CRC-32 mismatch") }
        return out
    }
}

/// Parallel BGZF writer: blocks are independent, so they are compressed on all workers.
final class BGZFEncoder: ParallelChunkEncoder {
    private let level: Int
    /// Index entries (compressed offset, uncompressed offset) of every block after the first,
    /// as written by `bgzip -i`.
    private(set) var index: [(UInt64, UInt64)] = []
    private var compressedOffset: UInt64 = 0
    private var uncompressedOffset: UInt64 = 0

    /// `level` uses bgzip's 0–9 scale (zlib), mapped to libdeflate exactly as htslib does,
    /// so `-l N` gives the same output size as `bgzip -l N`.
    init(level: Int, workload: Workload, cancel: CancellationToken?) {
        self.level = BGZF.libdeflateLevel(forZlibLevel: level)
        super.init(chunkSize: BGZF.blockInput, workload: workload, cancel: cancel, chunksPerWorker: 16)
    }

    override func compressChunk(_ chunk: UnsafeRawBufferPointer, previous: UnsafeRawBufferPointer?, last: Bool) throws -> [UInt8] {
        chunk.isEmpty ? [] : BGZF.compressBlock(chunk, level: level)
    }

    override func chunkWritten(input: Int, output: Int) {
        guard output > 0 else { return }
        if compressedOffset > 0 { index.append((compressedOffset, uncompressedOffset)) }
        compressedOffset += UInt64(output)
        uncompressedOffset += UInt64(input)
    }

    override func trailer() -> [UInt8] { BGZF.eofMarker }
}

/// Parallel BGZF reader: block boundaries come from the BSIZE fields, so a batch of complete
/// blocks is cut from the input and inflated in parallel (exact output size known from ISIZE).
final class BGZFDecoder: StreamTransform {
    private let workload: Workload
    private let cancel: CancellationToken?
    private var pending: [UInt8] = []
    private var blocks: [Range<Int>] = []
    private let batchBytes: Int
    private(set) var blockCount = 0
    /// Whether the stream ended with the mandatory empty EOF block.
    private(set) var endsWithEOFMarker = false
    private var lastBlockWasEmpty = false

    init(workload: Workload, cancel: CancellationToken?) {
        self.workload = workload
        self.cancel = cancel
        batchBytes = max(1, workload.workerCount) * 16 * BGZF.maxBlockSize
    }

    func process(_ input: UnsafeRawBufferPointer, _ sink: ByteSink) throws {
        pending.append(contentsOf: input)
        // Split complete blocks off the pending buffer.
        var pos = blocks.last?.upperBound ?? 0
        while pending.count - pos >= 12 {
            if pending[pos] != 0x1f || pending[pos + 1] != 0x8b {
                throw XipperError.corrupt("not a BGZF block at offset \(pos)")
            }
            let headerLen = 12 + (Int(pending[pos + 10]) | Int(pending[pos + 11]) << 8)
            if pending.count - pos < headerLen { break }  // extra field not complete yet
            let size = pending.withUnsafeBytes { BGZF.blockSize(at: UnsafeRawBufferPointer(rebasing: $0[pos..<pos + headerLen])) }
            guard let size else { throw XipperError.corrupt("gzip member without BGZF header at offset \(pos)") }
            if pending.count - pos < size { break }
            blocks.append(pos..<pos + size)
            pos += size
        }
        if pos >= batchBytes { try flush(sink) }
    }

    func finish(_ sink: ByteSink) throws {
        try flush(sink)
        if !pending.isEmpty { throw XipperError.corrupt("BGZF stream truncated inside a block") }
        endsWithEOFMarker = lastBlockWasEmpty
    }

    private func flush(_ sink: ByteSink) throws {
        guard !blocks.isEmpty else { return }
        let ranges = blocks
        let results = Slots<[UInt8]>(ranges.count)
        try pending.withUnsafeBytes { p in
            try parallelFor(ranges.count, workload: workload, cancel: cancel) { i in
                let d = libdeflate_alloc_decompressor()!
                defer { libdeflate_free_decompressor(d) }
                results[i] = try BGZF.decompressBlock(UnsafeRawBufferPointer(rebasing: p[ranges[i]]), decompressor: d)
            }
        }
        for i in 0..<ranges.count {
            let out = results.take(i)!
            lastBlockWasEmpty = out.isEmpty
            if !out.isEmpty { try out.withUnsafeBytes { try sink($0) } }
        }
        blockCount += ranges.count
        pending.removeFirst(ranges.last!.upperBound)
        blocks.removeAll(keepingCapacity: true)
    }
}

/// Facts about a BGZF file gathered by scanning block headers only (no decompression).
struct BGZFLayout {
    var blocks: Int
    var uncompressedSize: UInt64
    var endsWithEOFMarker: Bool
    /// `.gzi` entries: (compressed offset, uncompressed offset) of each data block after the first.
    var index: [(UInt64, UInt64)]

    /// Walks the BSIZE chain with `pread`. Throws on a malformed or truncated chain.
    static func scan(_ reader: FileReader) throws -> BGZFLayout {
        var off: Int64 = 0
        var u: UInt64 = 0
        var blocks = 0
        var index: [(UInt64, UInt64)] = []
        var lastEmpty = false
        var head = [UInt8](repeating: 0, count: 64)
        while off < reader.size {
            let n = Int(min(64, reader.size - off))
            try head.withUnsafeMutableBytes { try reader.read(at: off, into: $0.baseAddress!, count: n) }
            guard let size = head.withUnsafeBytes({ BGZF.blockSize(at: UnsafeRawBufferPointer(rebasing: $0[0..<n])) }) else {
                throw XipperError.corrupt("not a BGZF block at offset \(off)")
            }
            if off + Int64(size) > reader.size { throw XipperError.corrupt("BGZF file truncated inside the last block") }
            let isize = try reader.read(at: off + Int64(size) - 4, count: 4).withUnsafeBytes {
                UInt64($0.loadUnaligned(as: UInt32.self).littleEndian)
            }
            if isize > 0 && off > 0 { index.append((UInt64(off), u)) }
            lastEmpty = isize == 0
            u += isize
            off += Int64(size)
            blocks += 1
        }
        return BGZFLayout(blocks: blocks, uncompressedSize: u, endsWithEOFMarker: lastEmpty, index: index)
    }

    /// `.gzi` file content (htslib format: uint64 count, then uint64 pairs, little-endian).
    static func gziBytes(_ index: [(UInt64, UInt64)]) -> [UInt8] {
        var w = ByteWriter(capacity: 8 + 16 * index.count)
        w.u64(UInt64(index.count))
        for (c, u) in index { w.u64(c); w.u64(u) }
        return w.bytes
    }
}
