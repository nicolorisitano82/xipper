import Foundation

/// Pull-style byte stream.
protocol ByteSource: AnyObject {
    /// Reads up to `max` bytes; returns 0 only at end of stream.
    func read(into buf: UnsafeMutableRawPointer, max: Int) throws -> Int
}

extension ByteSource {
    /// Fills `count` bytes or throws `corrupt` on premature end. Returns false if the stream
    /// was already at its end (zero bytes read) and `allowEOF` is set.
    func readExactly(into buf: UnsafeMutableRawPointer, count: Int, allowEOF: Bool = false) throws -> Bool {
        var done = 0
        while done < count {
            let n = try read(into: buf + done, max: count - done)
            if n == 0 {
                if done == 0 && allowEOF { return false }
                throw XipperError.corrupt("unexpected end of archive")
            }
            done += n
        }
        return true
    }

    func skip(_ count: Int64) throws {
        var left = count
        let tmp = UnsafeMutableRawPointer.allocate(byteCount: 1 << 16, alignment: 16)
        defer { tmp.deallocate() }
        while left > 0 {
            let n = try read(into: tmp, max: Int(min(left, 1 << 16)))
            if n == 0 { throw XipperError.corrupt("unexpected end of archive") }
            left -= Int64(n)
        }
    }
}

/// Compression framing recognized by magic bytes.
enum StreamCompression: Sendable, Equatable {
    case none, gzip, bgzf, bzip2, xz, zstd
    /// Read only: LZ4 frames (magic) and brotli (no magic: recognized by the file name).
    case lz4, brotli

    /// Bytes needed by `detect` (BGZF is recognized from the gzip extra field).
    static let detectLength = 64

    static func detect(_ head: [UInt8]) -> StreamCompression {
        if head.starts(with: [0x1f, 0x8b]) { return BGZF.isBGZF(head) ? .bgzf : .gzip }
        if head.starts(with: [0x42, 0x5a, 0x68]) { return .bzip2 }  // "BZh"
        if head.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .xz }
        if head.starts(with: [0x28, 0xB5, 0x2F, 0xFD]) { return .zstd }
        if head.starts(with: [0x04, 0x22, 0x4D, 0x18]) { return .lz4 }
        return .none
    }

    /// Like `detect`, plus brotli by name (`.br`, `.tar.br`), which has no signature.
    static func detect(_ head: [UInt8], name: String) -> StreamCompression {
        let found = detect(head)
        if found == .none && name.lowercased().hasSuffix(".br") { return .brotli }
        return found
    }

    func decoder(threads: Int) throws -> StreamTransform {
        switch self {
        case .none: return PassthroughTransform()
        case .gzip: return try InflateDecoder(gzip: true)
        case .bgzf: return BGZFDecoder(workload: .threads(threads), cancel: nil)
        case .bzip2: return ParallelBzip2Decoder()
        case .xz: return XzDecoder(threads: threads)
        case .zstd: return try ZstdDecoder()
        case .lz4: return LZ4FrameDecoder()
        case .brotli: return try BrotliDecoder()
        }
    }

    func encoder(level: Int, workload: Workload, cancel: CancellationToken?) throws -> StreamTransform {
        switch self {
        case .none: return PassthroughTransform()
        case .gzip: return ParallelGzipEncoder(level: level, workload: workload, cancel: cancel)
        case .bgzf: return BGZFEncoder(level: level, workload: workload, cancel: cancel)
        case .bzip2: return ParallelBzip2Encoder(level: level, workload: workload, cancel: cancel)
        case .xz: return try LZMACoder.xzEncoder(preset: level, threads: workload.workerCount, cancel: cancel)
        case .zstd: return try ZstdEncoder(level: level, threads: workload.workerCount, cancel: cancel)
        case .lz4, .brotli: throw XipperError.unsupported("\(self) is read only")
        }
    }
}

/// Reads a file through a decoder running on its own thread.
///
/// The decoder pushes output into a bounded queue and blocks when it is full, so memory stays
/// bounded whatever the compression ratio, and decompression overlaps with the consumer's work.
final class DecodingPipe: ByteSource, @unchecked Sendable {
    private let cond = NSCondition()
    private var queue: [[UInt8]] = []
    private var head: [UInt8] = []
    private var headPos = 0
    private var finished = false
    private var failure: Error?
    private var closed = false
    private let maxQueued = 8
    private var thread: Thread?

    /// Total compressed bytes consumed so far (for progress).
    private(set) var compressedRead: Int64 = 0

    init(file: FileReader, compression: StreamCompression, threads: Int, qos: QualityOfService) throws {
        nonisolated(unsafe) let decoder = try compression.decoder(threads: threads)
        // The thread keeps the pipe alive until it finishes; consumers must call `close()`
        // when they stop early so a producer blocked on a full queue can exit.
        let t = Thread { self.produce(file: file, decoder: decoder) }
        t.qualityOfService = qos
        t.name = "xipper.decode"
        thread = t
        t.start()
    }

    /// Stops the producer (consumer gave up early).
    func close() {
        cond.lock()
        closed = true
        cond.broadcast()
        cond.unlock()
    }

    private func produce(file: FileReader, decoder: StreamTransform) {
        let inBuf = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16384)
        defer { inBuf.deallocate() }
        let push: ByteSink = { chunk in
            let copy = Array(chunk)
            self.cond.lock()
            defer { self.cond.unlock() }
            while self.queue.count >= self.maxQueued && !self.closed { self.cond.wait() }
            if self.closed { throw XipperError.cancelled }
            self.queue.append(copy)
            self.cond.broadcast()
        }
        do {
            var offset: Int64 = 0
            while true {
                let n = try file.readSome(at: offset, into: inBuf, count: 1 << 20)
                if n == 0 { break }
                offset += Int64(n)
                cond.lock(); compressedRead = offset; cond.unlock()
                try decoder.process(UnsafeRawBufferPointer(start: inBuf, count: n), push)
            }
            try decoder.finish(push)
            cond.lock(); finished = true
        } catch {
            cond.lock(); failure = error; finished = true
        }
        cond.broadcast()
        cond.unlock()
    }

    func read(into buf: UnsafeMutableRawPointer, max: Int) throws -> Int {
        if headPos == head.count {
            cond.lock()
            while queue.isEmpty && !finished { cond.wait() }
            if queue.isEmpty {
                let e = failure
                cond.unlock()
                if let e { throw e }
                return 0
            }
            head = queue.removeFirst()
            headPos = 0
            cond.broadcast()
            cond.unlock()
        }
        let n = min(max, head.count - headPos)
        head.withUnsafeBytes { buf.copyMemory(from: $0.baseAddress! + headPos, byteCount: n) }
        headPos += n
        return n
    }

    /// After the consumer saw end of data: surfaces decoder errors (truncation, bad checksum)
    /// that happened after the last byte it needed.
    func drainAndCheck() throws {
        let tmp = UnsafeMutableRawPointer.allocate(byteCount: 1 << 16, alignment: 16)
        defer { tmp.deallocate() }
        while try read(into: tmp, max: 1 << 16) > 0 {}
    }
}
