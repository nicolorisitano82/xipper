import CDeflate
import Foundation

/// Virtual file offsets (SAM/BAM spec §4.1.1): compressed block start << 16 | offset inside the
/// uncompressed block. Used by every BGZF index (.tbi, .csi, .bai).
enum VirtualOffset {
    static func make(_ coffset: UInt64, _ uoffset: Int) -> UInt64 { coffset << 16 | UInt64(uoffset) }
    static func coffset(_ v: UInt64) -> UInt64 { v >> 16 }
    static func uoffset(_ v: UInt64) -> Int { Int(v & 0xFFFF) }
    static func text(_ v: UInt64) -> String { "\(coffset(v)):\(uoffset(v))" }
}

/// Sequential BGZF reader handing out whole decompressed blocks with their file offset.
/// Batches of blocks are read with one `pread` and inflated in parallel.
final class BGZFBlockReader {
    struct Block {
        let offset: UInt64
        /// Compressed size of the block (header to footer).
        let size: Int
        let data: [UInt8]
        var end: UInt64 { offset + UInt64(size) }
    }

    private let file: FileReader
    private let workload: Workload
    private let cancel: CancellationToken?
    private var next: Int64 = 0
    private var queue: [Block] = []
    private var queueIndex = 0
    private let batchBytes: Int
    private(set) var endsWithEOFMarker = false
    private(set) var blockCount = 0
    var bytesRead: Int64 { next }

    init(file: FileReader, workload: Workload = .interactive, cancel: CancellationToken? = nil, batchBytes: Int = 4 << 20) {
        self.file = file
        self.workload = workload
        self.cancel = cancel
        self.batchBytes = max(batchBytes, BGZF.maxBlockSize)
    }

    /// Throws a clear error when the file is plain gzip or not compressed at all.
    static func requireBGZF(_ file: FileReader, name: String) throws {
        let head = try file.read(at: 0, count: Int(min(file.size, 64)))
        if BGZF.isBGZF(head) { return }
        if head.count >= 2 && head[0] == 0x1f && head[1] == 0x8b {
            throw XipperError.unsupported("\(name) is plain gzip, not BGZF: indexes need BGZF. Convert it first with bgzf_convert (xipper bgzip --convert)")
        }
        throw XipperError.unsupported("\(name) is not BGZF-compressed: compress it first with bgzf_compress (xipper bgzip)")
    }

    func nextBlock() throws -> Block? {
        if queueIndex == queue.count {
            try fill()
            if queue.isEmpty { return nil }
        }
        defer { queueIndex += 1 }
        return queue[queueIndex]
    }

    /// The blocks of the next batch (empty at end of file).
    func nextBatch() throws -> [Block] {
        if queueIndex == queue.count { try fill() }
        defer { queue.removeAll(keepingCapacity: true); queueIndex = 0 }
        return Array(queue[queueIndex...])
    }

    private func fill() throws {
        queue.removeAll(keepingCapacity: true)
        queueIndex = 0
        guard next < file.size else { return }
        try cancel?.check()
        let count = Int(min(Int64(batchBytes), file.size - next))
        let buf = try file.read(at: next, count: count)
        var ranges: [Range<Int>] = []
        var pos = 0
        try buf.withUnsafeBytes { b in
            while pos < count {
                let avail = UnsafeRawBufferPointer(rebasing: b[pos..<min(count, pos + 64)])
                guard let size = BGZF.blockSize(at: avail) else {
                    let atEnd = next + Int64(count) == file.size
                    if count - pos < 64 && !atEnd { break }  // header split across batches
                    if count - pos < 18 && atEnd {
                        throw XipperError.corrupt("BGZF file truncated inside the last block (offset \(next + Int64(pos)))")
                    }
                    throw XipperError.corrupt("not a BGZF block at offset \(next + Int64(pos))")
                }
                if pos + size > count {
                    if next + Int64(count) == file.size {
                        throw XipperError.corrupt("BGZF file truncated inside the last block (offset \(next + Int64(pos)))")
                    }
                    break
                }
                ranges.append(pos..<pos + size)
                pos += size
            }
        }
        if ranges.isEmpty { throw XipperError.corrupt("not a BGZF block at offset \(next)") }
        let results = Slots<[UInt8]>(ranges.count)
        try buf.withUnsafeBytes { p in
            try parallelFor(ranges.count, workload: workload, cancel: cancel) { i in
                let d = libdeflate_alloc_decompressor()!
                defer { libdeflate_free_decompressor(d) }
                do {
                    results[i] = try BGZF.decompressBlock(UnsafeRawBufferPointer(rebasing: p[ranges[i]]), decompressor: d)
                } catch let e as XipperError {
                    throw XipperError.corrupt("BGZF block at offset \(next + Int64(ranges[i].lowerBound)): \(e.description)")
                }
            }
        }
        for (i, r) in ranges.enumerated() {
            let data = results.take(i)!
            queue.append(Block(offset: UInt64(next + Int64(r.lowerBound)), size: r.count, data: data))
            endsWithEOFMarker = data.isEmpty
        }
        blockCount += ranges.count
        next += Int64(pos)
    }
}

/// Every block start of a BGZF file with its uncompressed size, read from the headers only
/// (block sizes in BSIZE, ISIZE in the footer). Used to validate index offsets.
struct BGZFBlockMap {
    /// Sorted compressed offsets of every block, including the empty EOF block.
    var offsets: [UInt64]
    var isizes: [UInt32]
    var fileSize: UInt64
    var endsWithEOFMarker: Bool
    /// Why the block chain stops early (truncated or damaged file); offsets are valid up to there.
    var damage: String?

    static func scan(_ file: FileReader, cancel: CancellationToken? = nil) throws -> BGZFBlockMap {
        var offsets: [UInt64] = [], isizes: [UInt32] = []
        let chunk = 4 << 20
        var base: Int64 = 0
        var lastEmpty = false
        var damage: String?
        scanning: while base < file.size {
            try cancel?.check()
            let count = Int(min(Int64(chunk), file.size - base))
            let buf = try file.read(at: base, count: count)
            var pos = 0
            buf.withUnsafeBytes { b in
                while pos < count {
                    guard let size = BGZF.blockSize(at: UnsafeRawBufferPointer(rebasing: b[pos..<min(count, pos + 64)])) else {
                        if count - pos < 64 && base + Int64(count) < file.size { break }  // header split across chunks
                        damage = "not a BGZF block at offset \(base + Int64(pos))"
                        return
                    }
                    if pos + size > count {
                        if base + Int64(count) == file.size {
                            damage = "file truncated inside the block at offset \(base + Int64(pos))"
                            return
                        }
                        break
                    }
                    let isize = b.loadUnaligned(fromByteOffset: pos + size - 4, as: UInt32.self).littleEndian
                    offsets.append(UInt64(base + Int64(pos)))
                    isizes.append(isize)
                    lastEmpty = isize == 0
                    pos += size
                }
            }
            if damage != nil { break scanning }
            if pos == 0 { damage = "not a BGZF block at offset \(base)"; break }
            base += Int64(pos)
        }
        if damage != nil { lastEmpty = false }
        return BGZFBlockMap(offsets: offsets, isizes: isizes, fileSize: UInt64(file.size), endsWithEOFMarker: lastEmpty, damage: damage)
    }

    /// Nil if the virtual offset points to a valid position, else why not.
    func problem(with v: UInt64) -> String? {
        let c = VirtualOffset.coffset(v), u = VirtualOffset.uoffset(v)
        if c == fileSize && u == 0 { return nil }  // end of file
        guard let i = blockIndex(c) else {
            return c >= fileSize ? "points past the end of the file (\(fileSize) bytes)" : "does not start a BGZF block"
        }
        if u > Int(isizes[i]) { return "offset \(u) inside a block of \(isizes[i]) bytes" }
        return nil
    }

    func blockIndex(_ coffset: UInt64) -> Int? {
        var lo = 0, hi = offsets.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if offsets[mid] < coffset { lo = mid + 1 } else { hi = mid }
        }
        return lo < offsets.count && offsets[lo] == coffset ? lo : nil
    }
}

/// Reads the first `count` uncompressed bytes of a BGZF file (headers of BAM/BCF/VCF).
func bgzfPrefix(_ file: FileReader, count: Int) throws -> [UInt8] {
    let r = BGZFBlockReader(file: file, workload: .threads(1), batchBytes: 1 << 20)
    var out: [UInt8] = []
    while out.count < count, let b = try r.nextBlock() { out += b.data }
    return Array(out.prefix(count))
}
