import CLZMA
import CLzmaSDK
import CryptoKit
import Foundation
import Synchronization

/// .xz decoded with the LZMA SDK's LZMA2 decoder and 7-Zip's ARM64 assembly loop: about 1.4×
/// liblzma on one core (`xz -T1` output, 234 MB: `xipper test` 1.64 s against 2.33 s). Streams
/// whose blocks declare their size (multi-threaded xz, Xipper) go to liblzma's multi-threaded
/// decoder when there are threads to spare; with one thread they are decoded here too.
/// The container is checked as liblzma does: header and block CRCs, padding, the stream's check
/// (CRC-32, CRC-64 or SHA-256), the index against the blocks and the footer.
/// Filters other than a lone LZMA2 (BCJ, delta) go to liblzma, decided at the first block.
final class XzDecoder: StreamTransform {
    private var buf: [UInt8] = []
    private var pos = 0
    private enum State { case streamHeader, blockOrIndex, streaming, blockEnd }
    private var state = State.streamHeader
    private var streams = 0
    private var checkType: UInt8 = 0
    private var records: [(unpadded: UInt64, size: UInt64)] = []
    private var sawBlock = false
    private var fallback: LZMACoder?
    private let threads: Int
    private let window: Int

    /// Blocks waiting to be decoded in parallel (all their bytes are buffered).
    private struct Pending { var data: Range<Int>; var prop: UInt8; var size: Int?; var check: Range<Int>; var header: Int }
    private var batch: [Pending] = []
    private var batchBytes = 0

    /// The block being streamed.
    private var dec: OpaquePointer?
    private var block = (header: 0, compressed: 0, produced: 0, declaredC: Int?.none, declaredU: Int?.none)
    private var digest = Digest(type: 0)

    init(threads: Int, window: Int = 32 << 20) {
        self.threads = max(1, threads)
        self.window = window
    }
    deinit { if let dec { xs_lzdec_free(dec) } }

    func process(_ input: UnsafeRawBufferPointer, _ sink: ByteSink) throws {
        if let fallback { return try fallback.process(input, sink) }
        buf.append(contentsOf: input)
        if buf.count - pos >= window || state == .streaming { try drain(final: false, sink) }
    }

    func finish(_ sink: ByteSink) throws {
        if let fallback { return try fallback.finish(sink) }
        try drain(final: false, sink)
        if let fallback { return try fallback.finish(sink) }
        try drain(final: true, sink)
        guard streams > 0, state == .streamHeader, pos == buf.count else { throw XipperError.corrupt("truncated xz stream") }
    }

    // MARK: container

    private func u32(_ i: Int) -> UInt32 { UInt32(buf[i]) | UInt32(buf[i + 1]) << 8 | UInt32(buf[i + 2]) << 16 | UInt32(buf[i + 3]) << 24 }
    private func crc32(_ r: Range<Int>) -> UInt32 { buf.withUnsafeBytes { CRC32.checksum(UnsafeRawBufferPointer(rebasing: $0[r])) } }

    /// Variable-length integer at `i` (at most 9 bytes); nil if incomplete.
    private func vli(_ i: inout Int, end: Int) throws -> UInt64? {
        var v: UInt64 = 0
        for k in 0..<9 {
            guard i < end else { return nil }
            let b = buf[i]; i += 1
            v |= UInt64(b & 0x7F) << (7 * UInt64(k))
            if b & 0x80 == 0 {
                if b == 0 && k > 0 { throw XipperError.corrupt("invalid xz data") }
                return v
            }
        }
        throw XipperError.corrupt("invalid xz data")
    }

    private var checkSize: Int {
        switch checkType { case 0: 0; case 1...3: 4; case 4...6: 8; case 7...9: 16; case 10...12: 32; default: 64 }
    }

    private func drain(final: Bool, _ sink: ByteSink) throws {
        loop: while true {
            switch state {
            case .streamHeader:
                if streams > 0 { while pos + 4 <= buf.count && buf[pos..<(pos + 4)].allSatisfy({ $0 == 0 }) { pos += 4 } }  // stream padding
                if pos == buf.count { break loop }
                guard pos + 12 <= buf.count else {
                    if final { throw XipperError.corrupt("truncated xz stream") }
                    break loop
                }
                guard buf[pos..<(pos + 6)].elementsEqual([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]), buf[pos + 6] == 0, buf[pos + 7] & 0xF0 == 0,
                      crc32((pos + 6)..<(pos + 8)) == u32(pos + 8) else { throw XipperError.corrupt("invalid xz stream header") }
                checkType = buf[pos + 7]
                guard [0, 1, 4, 10].contains(checkType) else { try switchToLiblzma(sink); return }
                pos += 12
                records = []
                state = .blockOrIndex

            case .blockOrIndex:
                guard pos < buf.count else { if final { throw XipperError.corrupt("truncated xz stream") }; break loop }
                if buf[pos] == 0 {
                    try flushBatch(sink)
                    guard try readIndexAndFooter() else { if final { throw XipperError.corrupt("truncated xz stream") }; break loop }
                    streams += 1
                    state = .streamHeader
                    continue
                }
                let size = (Int(buf[pos]) + 1) * 4
                guard pos + size <= buf.count else { if final { throw XipperError.corrupt("truncated xz stream") }; break loop }
                guard crc32(pos..<(pos + size - 4)) == u32(pos + size - 4) else { throw XipperError.corrupt("xz block header checksum") }
                let flags = buf[pos + 1]
                guard flags & 0x3C == 0 else { throw XipperError.unsupported("xz block flags") }
                var i = pos + 2
                let end = pos + size - 4
                let csize = flags & 0x40 != 0 ? try vli(&i, end: end) : nil
                let usize = flags & 0x80 != 0 ? try vli(&i, end: end) : nil
                // Only a single LZMA2 filter with its one property byte takes the fast path.
                let filters = Int(flags & 3) + 1
                let id = try vli(&i, end: end), propsSize = try vli(&i, end: end)
                guard filters == 1, id == 0x21, propsSize == 1, i < end, buf[i] <= 40,
                      buf[(i + 1)..<end].allSatisfy({ $0 == 0 }) else {
                    if !sawBlock { try switchToLiblzma(sink); return }
                    throw XipperError.unsupported("xz filters other than LZMA2 after the first block")
                }
                let prop = buf[i]
                // Blocks with declared sizes and several threads: liblzma's multi-threaded decoder
                // overlaps blocks better than parallel batches (Xipper's tar.xz: 0.31 s against 0.72 s).
                if !sawBlock && csize != nil && threads > 1 { try switchToLiblzma(sink); return }
                sawBlock = true
                if let csize, csize > 0, csize < UInt64(Int32.max), usize.map({ $0 < UInt64(1 << 31) }) ?? true {
                    // Known size: decode later, in parallel with its neighbours.
                    let c = Int(csize)
                    let dataStart = pos + size
                    let checkStart = dataStart + c + (4 - c % 4) % 4
                    guard checkStart + checkSize <= buf.count else {
                        if final { throw XipperError.corrupt("truncated xz stream") }
                        break loop
                    }
                    guard buf[(dataStart + c)..<checkStart].allSatisfy({ $0 == 0 }) else { throw XipperError.corrupt("xz block padding") }
                    batch.append(Pending(data: dataStart..<(dataStart + c), prop: prop, size: usize.map { Int($0) },
                                         check: checkStart..<(checkStart + checkSize), header: size))
                    batchBytes += c
                    pos = checkStart + checkSize
                    if batchBytes >= window { try flushBatch(sink) }
                    continue
                }
                try flushBatch(sink)
                guard let d = xs_lzma2_dec_new(prop, 0) else { throw XipperError.limitExceeded("xz: memory") }
                dec = d
                block = (size, 0, 0, csize.map { Int($0) }, usize.map { Int($0) })
                digest = Digest(type: checkType)
                pos += size
                state = .streaming

            case .streaming:
                guard let d = dec else { throw XipperError.codec("xz decoder") }
                var finished = false
                try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 1 << 20) { out in
                    while true {
                        var used = 0, produced = 0
                        let st = buf.withUnsafeBufferPointer { b in
                            xs_lzdec_run(d, b.baseAddress! + pos, b.count - pos, &used, out.baseAddress, out.count, &produced, 0)
                        }
                        guard st >= 0 else { throw XipperError.corrupt("invalid xz data") }
                        pos += used
                        block.compressed += used
                        block.produced += produced
                        if produced > 0 {
                            let o = UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(out)[..<produced])
                            digest.update(o)
                            try sink(o)
                        }
                        if st == 1 { finished = true; return }
                        if used == 0 && produced == 0 { return }  // needs more input
                    }
                }
                guard finished else { if final { throw XipperError.corrupt("truncated xz stream") }; break loop }
                xs_lzdec_free(d)
                dec = nil
                state = .blockEnd

            case .blockEnd:
                let pad = (4 - block.compressed % 4) % 4
                guard pos + pad + checkSize <= buf.count else { if final { throw XipperError.corrupt("truncated xz stream") }; break loop }
                guard buf[pos..<(pos + pad)].allSatisfy({ $0 == 0 }) else { throw XipperError.corrupt("xz block padding") }
                guard block.declaredC.map({ $0 == block.compressed }) ?? true, block.declaredU.map({ $0 == block.produced }) ?? true else {
                    throw XipperError.corrupt("xz block size mismatch")
                }
                guard digest.finish() == Array(buf[(pos + pad)..<(pos + pad + checkSize)]) else {
                    throw XipperError.checksumMismatch(entry: "xz block", expected: 0, actual: 0)
                }
                pos += pad + checkSize
                records.append((UInt64(block.header + block.compressed + checkSize), UInt64(block.produced)))
                state = .blockOrIndex
            }
        }
        if !final && state != .streaming { try flushBatch(sink) }
        // Drop what is consumed (all of it is kept until the first block shows the fast path applies).
        if sawBlock && fallback == nil && batch.isEmpty && pos > 0 { buf.removeSubrange(0..<pos); pos = 0 }
    }

    /// Index (records against the blocks seen) and stream footer; false if not all buffered.
    private func readIndexAndFooter() throws -> Bool {
        var i = pos + 1
        guard let n = try vli(&i, end: buf.count) else { return false }
        guard n == UInt64(records.count) else { throw XipperError.corrupt("xz index does not match the blocks") }
        for r in records {
            guard let u = try vli(&i, end: buf.count), let s = try vli(&i, end: buf.count) else { return false }
            guard u == r.unpadded, s == r.size else { throw XipperError.corrupt("xz index does not match the blocks") }
        }
        let padded = (i - pos + 3) / 4 * 4
        guard pos + padded + 4 + 12 <= buf.count else { return false }
        guard buf[i..<(pos + padded)].allSatisfy({ $0 == 0 }), crc32(pos..<(pos + padded)) == u32(pos + padded) else {
            throw XipperError.corrupt("xz index checksum")
        }
        let f = pos + padded + 4
        guard crc32((f + 4)..<(f + 10)) == u32(f), Int(u32(f + 4)) == (padded + 4) / 4 - 1,
              buf[f + 8] == 0, buf[f + 9] == checkType, buf[f + 10] == 0x59, buf[f + 11] == 0x5A else {
            throw XipperError.corrupt("invalid xz stream footer")
        }
        pos = f + 12
        return true
    }

    private func flushBatch(_ sink: ByteSink) throws {
        guard !batch.isEmpty else { return }
        let jobs = batch, type = checkType
        let results = Slots<[UInt8]>(jobs.count)
        let failed = Atomic<Bool>(false)
        try buf.withUnsafeBufferPointer { b in
            let base = b.baseAddress!
            try parallelFor(jobs.count, workload: .threads(threads), cancel: nil) { k in
                let j = jobs[k]
                guard let d = xs_lzma2_dec_new(j.prop, UInt32(clamping: j.size ?? 0)) else { failed.store(true, ordering: .relaxed); return }
                defer { xs_lzdec_free(d) }
                var out = [UInt8](unsafeUninitializedCapacity: j.size ?? (j.data.count * 4 + 4096)) { _, n in n = 0 }
                var inPos = j.data.lowerBound
                var status: Int32 = 2
                var chunk = [UInt8](repeating: 0, count: 1 << 20)
                while inPos < j.data.upperBound || status == 2 {
                    var used = 0, produced = 0
                    status = chunk.withUnsafeMutableBufferPointer {
                        xs_lzdec_run(d, base + inPos, j.data.upperBound - inPos, &used, $0.baseAddress, $0.count, &produced, 0)
                    }
                    if status < 0 { failed.store(true, ordering: .relaxed); return }
                    out.append(contentsOf: chunk[..<produced])
                    inPos += used
                    if status == 1 || (used == 0 && produced == 0) { break }
                }
                var digest = Digest(type: type)
                out.withUnsafeBytes { digest.update($0) }
                guard status == 1, inPos == j.data.upperBound, j.size.map({ $0 == out.count }) ?? true,
                      digest.finish().elementsEqual(UnsafeBufferPointer(rebasing: b[j.check])) else {
                    failed.store(true, ordering: .relaxed)
                    return
                }
                results[k] = out
            }
        }
        if failed.load(ordering: .relaxed) { throw XipperError.corrupt("invalid xz data") }
        for (k, j) in jobs.enumerated() {
            let out = results.take(k)!
            try emit(out, to: sink)
            records.append((UInt64(j.header + j.data.count + checkSize), UInt64(out.count)))
        }
        batch = []
        batchBytes = 0
    }

    /// Hands everything (from the first byte) to liblzma.
    private func switchToLiblzma(_ sink: ByteSink) throws {
        let f = try LZMACoder.xzDecoder(threads: threads)
        fallback = f
        let all = buf
        buf = []
        try all.withUnsafeBytes { try f.process($0, sink) }
    }

    /// The stream's integrity check over a block's output.
    struct Digest {
        let type: UInt8
        var crc32: UInt32 = 0
        var crc64: UInt64 = 0
        var sha = SHA256()

        init(type: UInt8) { self.type = type }

        mutating func update(_ b: UnsafeRawBufferPointer) {
            switch type {
            case 1: crc32 = CRC32.update(crc32, b)
            case 4: crc64 = lzma_crc64(b.baseAddress?.assumingMemoryBound(to: UInt8.self), b.count, crc64)
            case 10: sha.update(bufferPointer: b)
            default: break
            }
        }

        func finish() -> [UInt8] {
            switch type {
            case 1: withUnsafeBytes(of: crc32.littleEndian) { Array($0) }
            case 4: withUnsafeBytes(of: crc64.littleEndian) { Array($0) }
            case 10: Array(sha.finalize())
            default: []
            }
        }
    }
}
