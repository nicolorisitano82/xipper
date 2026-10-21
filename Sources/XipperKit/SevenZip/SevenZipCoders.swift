import CLZMA
import CLzmaSDK
import Foundation

// MARK: - Input: one archive or a set of volumes (.7z.001, .7z.002, …)

/// Random-access view of a 7z archive, possibly split into volumes that are simply
/// consecutive slices of one byte stream.
final class SevenZipInput: @unchecked Sendable {
    let volumes: [FileReader]
    private let starts: [Int64]
    let size: Int64
    let path: String

    init(path: String) throws {
        self.path = path
        let paths = Self.volumePaths(path)
        volumes = try paths.map { try FileReader(path: $0) }
        var s: [Int64] = []
        var total: Int64 = 0
        for v in volumes { s.append(total); total += v.size }
        starts = s
        size = total
    }

    /// "x.7z.001" (or any of its siblings) → every consecutive volume; anything else → itself.
    static func volumePaths(_ path: String) -> [String] {
        guard let first = firstVolume(path) else { return [path] }
        let stem = String(first.dropLast(3))
        var out: [String] = []
        for n in 1...9999 {
            let p = stem + String(format: n < 1000 ? "%03d" : "%d", n)
            guard FileManager.default.fileExists(atPath: p) else { break }
            out.append(p)
        }
        return out.isEmpty ? [path] : out
    }

    /// Path of volume 001 when `path` is a numbered volume.
    static func firstVolume(_ path: String) -> String? {
        guard let dot = path.lastIndex(of: "."), path[path.index(after: dot)...].count >= 3,
              path[path.index(after: dot)...].allSatisfy(\.isNumber) else { return nil }
        let stem = path[..<path.index(after: dot)]
        return stem.lowercased().hasSuffix(".7z.") ? String(stem) + "001" : nil
    }

    func read(at offset: Int64, into dst: UnsafeMutableRawPointer, count: Int) throws {
        if offset < 0 || offset + Int64(count) > size { throw XipperError.corrupt("7z data beyond the end of the archive (truncated or missing volume)") }
        var off = offset, done = 0
        var v = (starts.lastIndex { $0 <= off }) ?? 0
        while done < count {
            while v < volumes.count - 1 && off >= starts[v] + volumes[v].size { v += 1 }
            let inVol = off - starts[v]
            let n = Int(min(Int64(count - done), volumes[v].size - inVol))
            try volumes[v].read(at: inVol, into: dst + done, count: n)
            done += n
            off += Int64(n)
        }
    }

    func read(at offset: Int64, count: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: count)
        try buf.withUnsafeMutableBytes { try read(at: offset, into: $0.baseAddress!, count: count) }
        return buf
    }
}

// MARK: - Pull sources

/// One packed stream of the archive.
final class PackStreamSource: ByteSource {
    private let input: SevenZipInput
    private var offset: Int64
    private var left: Int64
    /// Called with the number of packed bytes read (progress).
    var onRead: ((Int) -> Void)?

    init(_ input: SevenZipInput, offset: Int64, size: Int64) {
        self.input = input
        self.offset = offset
        left = size
    }

    func read(into buf: UnsafeMutableRawPointer, max: Int) throws -> Int {
        let n = Int(min(Int64(max), left))
        if n == 0 { return 0 }
        try input.read(at: offset, into: buf, count: n)
        offset += Int64(n)
        left -= Int64(n)
        onRead?(n)
        return n
    }
}

/// Runs a push codec over a pulled input.
final class TransformSource: ByteSource {
    private let input: ByteSource
    private let transform: StreamTransform
    private var out: [UInt8] = []
    private var outPos = 0
    private var finished = false
    private let inBuf = UnsafeMutableRawPointer.allocate(byteCount: 1 << 18, alignment: 16)

    init(_ input: ByteSource, _ transform: StreamTransform) {
        self.input = input
        self.transform = transform
    }
    deinit { inBuf.deallocate() }

    func read(into buf: UnsafeMutableRawPointer, max: Int) throws -> Int {
        while outPos == out.count {
            if finished { return 0 }
            out.removeAll(keepingCapacity: true)
            outPos = 0
            let n = try input.read(into: inBuf, max: 1 << 18)
            let collect: ByteSink = { self.out.append(contentsOf: $0) }
            if n == 0 {
                try transform.finish(collect)
                finished = true
            } else {
                try transform.process(UnsafeRawBufferPointer(start: inBuf, count: n), collect)
            }
        }
        let n = min(max, out.count - outPos)
        out.withUnsafeBytes { buf.copyMemory(from: $0.baseAddress! + outPos, byteCount: n) }
        outPos += n
        return n
    }
}

/// Exactly `size` bytes of `inner`: an early end is corruption, extra output is ignored.
final class ExactSource: ByteSource {
    private let inner: ByteSource
    private var left: Int64

    init(_ inner: ByteSource, size: Int64) {
        self.inner = inner
        left = size
    }

    func read(into buf: UnsafeMutableRawPointer, max: Int) throws -> Int {
        if left == 0 { return 0 }
        let n = try inner.read(into: buf, max: Int(min(Int64(max), left)))
        if n == 0 { throw XipperError.corrupt("7z stream ended early (truncated or corrupt data)") }
        left -= Int64(n)
        return n
    }
}

/// Reads its source in 1 MiB pieces (many small reads, e.g. LZMA2 chunk headers).
final class ReadAheadSource: ByteSource {
    private let inner: ByteSource
    private let buf = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16384)
    private var pos = 0, len = 0

    init(_ inner: ByteSource) { self.inner = inner }
    deinit { buf.deallocate() }

    func read(into dst: UnsafeMutableRawPointer, max: Int) throws -> Int {
        if pos == len {
            if max >= 1 << 20 { return try inner.read(into: dst, max: max) }
            len = try inner.read(into: buf, max: 1 << 20)
            pos = 0
            if len == 0 { return 0 }
        }
        let n = min(max, len - pos)
        dst.copyMemory(from: buf + pos, byteCount: n)
        pos += n
        return n
    }
}

/// Decodes `inner` on its own thread, a few MiB ahead of the consumer, so decoding overlaps
/// with what the consumer does (CRC, writing files), as 7-Zip does.
final class PipelinedSource: ByteSource {
    private final class State: @unchecked Sendable {
        let cond = NSCondition()
        var queue: [[UInt8]] = []
        var finished = false
        var failure: Error?
        var closed = false
    }

    private let state = State()
    private var head: [UInt8] = []
    private var headPos = 0
    private static let piece = 1 << 20
    private static let maxQueued = 8

    init(_ inner: ByteSource, qos: QualityOfService) {
        nonisolated(unsafe) let source = inner
        let st = state
        let t = Thread {
            let buf = UnsafeMutableRawPointer.allocate(byteCount: Self.piece, alignment: 16384)
            defer { buf.deallocate() }
            do {
                while true {
                    var n = 0
                    while n < Self.piece {  // fill whole pieces: fewer hand-overs
                        let r = try source.read(into: buf + n, max: Self.piece - n)
                        if r == 0 { break }
                        n += r
                    }
                    if n == 0 { break }
                    let chunk = Array(UnsafeRawBufferPointer(start: buf, count: n))
                    st.cond.lock()
                    while st.queue.count >= Self.maxQueued && !st.closed { st.cond.wait() }
                    if st.closed { st.cond.unlock(); return }
                    st.queue.append(chunk)
                    st.cond.broadcast()
                    st.cond.unlock()
                }
                st.cond.lock(); st.finished = true
            } catch {
                st.cond.lock(); st.failure = error; st.finished = true
            }
            st.cond.broadcast()
            st.cond.unlock()
        }
        t.qualityOfService = qos
        t.name = "xipper.7z.decode"
        t.start()
    }

    deinit {
        state.cond.lock()
        state.closed = true
        state.cond.broadcast()
        state.cond.unlock()
    }

    func read(into buf: UnsafeMutableRawPointer, max: Int) throws -> Int {
        if headPos == head.count {
            state.cond.lock()
            while state.queue.isEmpty && !state.finished { state.cond.wait() }
            if state.queue.isEmpty {
                let e = state.failure
                state.cond.unlock()
                if let e { throw e }
                return 0
            }
            head = state.queue.removeFirst()
            headPos = 0
            state.cond.broadcast()
            state.cond.unlock()
        }
        let n = min(max, head.count - headPos)
        head.withUnsafeBytes { buf.copyMemory(from: $0.baseAddress! + headPos, byteCount: n) }
        headPos += n
        return n
    }
}

/// Byte-at-a-time reads over a source (BCJ2's four inputs).
final class BufferedSource {
    private let inner: ByteSource
    private let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 16)
    private var pos = 0, len = 0

    init(_ inner: ByteSource) { self.inner = inner }
    deinit { buf.deallocate() }

    @inline(__always) func byte() throws -> UInt8 {
        if pos == len {
            len = try inner.read(into: buf, max: 1 << 16)
            pos = 0
            if len == 0 { throw XipperError.corrupt("7z BCJ2 stream ended early") }
        }
        defer { pos += 1 }
        return buf[pos]
    }
}

// MARK: - Branch converters (BCJ filters)

/// Position-dependent converters for executable code (xz and 7-Zip share the algorithms;
/// ported from liblzma's simple filters). Bytes the converter cannot handle yet (an
/// instruction split across chunks) wait for the next chunk; at the end they pass unchanged.
final class BranchFilter: StreamTransform {
    enum Kind { case x86, arm, armThumb, arm64, ppc, sparc, riscv }

    private let kind: Kind
    private let encoding: Bool
    private var position: UInt32
    private var pending: [UInt8] = []
    // x86 state
    private var prevMask: UInt32 = 0
    private var prevPos: UInt32 = 0 &- 5

    init(_ kind: Kind, encoding: Bool, startOffset: UInt32 = 0) {
        self.kind = kind
        self.encoding = encoding
        position = startOffset
    }

    func process(_ input: UnsafeRawBufferPointer, _ sink: ByteSink) throws {
        guard !input.isEmpty else { return }
        var work = pending
        work.append(contentsOf: input)
        let done = work.withUnsafeMutableBytes { convert($0.baseAddress!.assumingMemoryBound(to: UInt8.self), $0.count) }
        position &+= UInt32(truncatingIfNeeded: done)
        try work.withUnsafeBytes { try sink(UnsafeRawBufferPointer(rebasing: $0[0..<done])) }
        pending = Array(work[done...])
    }

    func finish(_ sink: ByteSink) throws {
        try emit(pending, to: sink)
        pending = []
    }

    /// In-place conversion of a whole buffer from `startOffset` (the writer's path).
    static func convert(_ kind: Kind, encoding: Bool, _ buf: UnsafeMutableRawBufferPointer, startOffset: UInt32) {
        let f = BranchFilter(kind, encoding: encoding, startOffset: startOffset)
        _ = f.convert(buf.baseAddress!.assumingMemoryBound(to: UInt8.self), buf.count)
    }

    /// Converts as much of `b` as possible; returns the number of bytes done.
    private func convert(_ b: UnsafeMutablePointer<UInt8>, _ size: Int) -> Int {
        switch kind {
        case .x86: return x86(b, size)
        case .arm64:
            return encoding ? lzma_bcj_arm64_encode(position, b, size) : lzma_bcj_arm64_decode(position, b, size)
        case .riscv:
            return encoding ? lzma_bcj_riscv_encode(position, b, size) : lzma_bcj_riscv_decode(position, b, size)
        case .arm: return arm(b, size)
        case .armThumb: return armThumb(b, size)
        case .ppc: return ppc(b, size)
        case .sparc: return sparc(b, size)
        }
    }

    @inline(__always) private static func test86MSByte(_ b: UInt8) -> Bool { b == 0 || b == 0xFF }

    private func x86(_ buf: UnsafeMutablePointer<UInt8>, _ size: Int) -> Int {
        let maskToBitNumber: [UInt32] = [0, 1, 2, 2, 3]
        if size < 5 { return 0 }
        let nowPos = position
        if nowPos &- prevPos > 5 { prevPos = nowPos &- 5 }
        let limit = size - 5
        var i = 0
        while i <= limit {
            var b = buf[i]
            if b != 0xE8 && b != 0xE9 { i += 1; continue }
            let offset = nowPos &+ UInt32(i) &- prevPos
            prevPos = nowPos &+ UInt32(i)
            if offset > 5 {
                prevMask = 0
            } else {
                for _ in 0..<offset { prevMask &= 0x77; prevMask <<= 1 }
            }
            b = buf[i + 4]
            if Self.test86MSByte(b) && (prevMask >> 1) <= 4 && (prevMask >> 1) != 3 {
                var src = UInt32(b) << 24 | UInt32(buf[i + 3]) << 16 | UInt32(buf[i + 2]) << 8 | UInt32(buf[i + 1])
                var dest: UInt32
                while true {
                    let here = nowPos &+ UInt32(i) &+ 5
                    dest = encoding ? src &+ here : src &- here
                    if prevMask == 0 { break }
                    let k = maskToBitNumber[Int(prevMask >> 1)]
                    b = UInt8(truncatingIfNeeded: dest >> (24 - k * 8))
                    if !Self.test86MSByte(b) { break }
                    src = dest ^ ((1 << (32 - k * 8)) &- 1)
                }
                buf[i + 4] = ~UInt8(truncatingIfNeeded: ((dest >> 24) & 1) &- 1)
                buf[i + 3] = UInt8(truncatingIfNeeded: dest >> 16)
                buf[i + 2] = UInt8(truncatingIfNeeded: dest >> 8)
                buf[i + 1] = UInt8(truncatingIfNeeded: dest)
                i += 5
                prevMask = 0
            } else {
                i += 1
                prevMask |= 1
                if Self.test86MSByte(b) { prevMask |= 0x10 }
            }
        }
        return i
    }

    private func arm(_ buf: UnsafeMutablePointer<UInt8>, _ size: Int) -> Int {
        let n = size & ~3
        var i = 0
        while i < n {
            if buf[i + 3] == 0xEB {
                let src = (UInt32(buf[i + 2]) << 16 | UInt32(buf[i + 1]) << 8 | UInt32(buf[i])) << 2
                let here = position &+ UInt32(i) &+ 8
                let dest = (encoding ? here &+ src : src &- here) >> 2
                buf[i + 2] = UInt8(truncatingIfNeeded: dest >> 16)
                buf[i + 1] = UInt8(truncatingIfNeeded: dest >> 8)
                buf[i] = UInt8(truncatingIfNeeded: dest)
            }
            i += 4
        }
        return i
    }

    private func armThumb(_ buf: UnsafeMutablePointer<UInt8>, _ size: Int) -> Int {
        if size < 4 { return 0 }
        let last = size - 4
        var i = 0
        while i <= last {
            if buf[i + 1] & 0xF8 == 0xF0 && buf[i + 3] & 0xF8 == 0xF8 {
                let src = ((UInt32(buf[i + 1]) & 7) << 19 | UInt32(buf[i]) << 11 | (UInt32(buf[i + 3]) & 7) << 8 | UInt32(buf[i + 2])) << 1
                let here = position &+ UInt32(i) &+ 4
                let dest = (encoding ? here &+ src : src &- here) >> 1
                buf[i + 1] = 0xF0 | UInt8(truncatingIfNeeded: (dest >> 19) & 7)
                buf[i] = UInt8(truncatingIfNeeded: dest >> 11)
                buf[i + 3] = 0xF8 | UInt8(truncatingIfNeeded: (dest >> 8) & 7)
                buf[i + 2] = UInt8(truncatingIfNeeded: dest)
                i += 2
            }
            i += 2
        }
        return i
    }

    private func ppc(_ buf: UnsafeMutablePointer<UInt8>, _ size: Int) -> Int {
        let n = size & ~3
        var i = 0
        while i < n {
            if buf[i] >> 2 == 0x12 && buf[i + 3] & 3 == 1 {
                let src = (UInt32(buf[i]) & 3) << 24 | UInt32(buf[i + 1]) << 16 | UInt32(buf[i + 2]) << 8 | (UInt32(buf[i + 3]) & ~3)
                let here = position &+ UInt32(i)
                let dest = encoding ? here &+ src : src &- here
                buf[i] = 0x48 | UInt8(truncatingIfNeeded: (dest >> 24) & 3)
                buf[i + 1] = UInt8(truncatingIfNeeded: dest >> 16)
                buf[i + 2] = UInt8(truncatingIfNeeded: dest >> 8)
                buf[i + 3] = (buf[i + 3] & 3) | UInt8(truncatingIfNeeded: dest)
            }
            i += 4
        }
        return i
    }

    private func sparc(_ buf: UnsafeMutablePointer<UInt8>, _ size: Int) -> Int {
        let n = size & ~3
        var i = 0
        while i < n {
            if (buf[i] == 0x40 && buf[i + 1] & 0xC0 == 0) || (buf[i] == 0x7F && buf[i + 1] & 0xC0 == 0xC0) {
                let src = (UInt32(buf[i]) << 24 | UInt32(buf[i + 1]) << 16 | UInt32(buf[i + 2]) << 8 | UInt32(buf[i + 3])) << 2
                let here = position &+ UInt32(i)
                var dest = (encoding ? here &+ src : src &- here) >> 2
                dest = (((0 &- ((dest >> 22) & 1)) << 22) & 0x3FFF_FFFF) | (dest & 0x3F_FFFF) | 0x4000_0000
                buf[i] = UInt8(truncatingIfNeeded: dest >> 24)
                buf[i + 1] = UInt8(truncatingIfNeeded: dest >> 16)
                buf[i + 2] = UInt8(truncatingIfNeeded: dest >> 8)
                buf[i + 3] = UInt8(truncatingIfNeeded: dest)
            }
            i += 4
        }
        return i
    }
}

/// Delta filter (7z method 03): byte-wise difference at distance 1...256.
final class DeltaFilter: StreamTransform {
    private let distance: Int
    private var history = [UInt8](repeating: 0, count: 256)
    private var pos = 0
    private let encoding: Bool
    private var out: [UInt8] = []

    init(props: [UInt8], encoding: Bool) throws {
        guard props.count == 1 else { throw XipperError.corrupt("bad 7z Delta properties") }
        distance = Int(props[0]) + 1
        self.encoding = encoding
    }

    func process(_ input: UnsafeRawBufferPointer, _ sink: ByteSink) throws {
        guard !input.isEmpty else { return }
        let d = distance, enc = encoding
        var p = pos
        out = [UInt8](unsafeUninitializedCapacity: input.count) { o, n in
            history.withUnsafeMutableBufferPointer { h in
                for i in 0..<input.count {
                    let b = input[i]
                    let prev = h[(p &- d) & 0xFF]
                    let v = enc ? b &- prev : b &+ prev
                    h[p & 0xFF] = enc ? b : v
                    p &+= 1
                    o[i] = v
                }
            }
            n = input.count
        }
        pos = p
        try emit(out, to: sink)
    }

    func finish(_ sink: ByteSink) throws {}
}

// MARK: - BCJ2

/// x86 BCJ2 decoder (7z method 0303011B): four inputs (main bytes, CALL targets, JMP targets,
/// range-coded "converted?" bits) rebuild the code.
final class BCJ2Source: ByteSource {
    private let main, call, jump, rc: BufferedSource
    private var probs = [UInt16](repeating: 1024, count: 258)
    private var range: UInt32 = 0xFFFF_FFFF
    private var code: UInt32 = 0
    private var started = false
    private var outPos: UInt32 = 0
    private var prevByte: UInt8 = 0
    private var left: Int64
    private var pending: (UInt32, Int) = (0, 0)  // converted address, bytes still to emit

    init(inputs: [ByteSource], size: Int64) throws {
        guard inputs.count == 4 else { throw XipperError.corrupt("7z BCJ2 needs 4 inputs") }
        main = BufferedSource(inputs[0])
        call = BufferedSource(inputs[1])
        jump = BufferedSource(inputs[2])
        rc = BufferedSource(inputs[3])
        left = size
    }

    @inline(__always) private func isJump(_ b0: UInt8, _ b1: UInt8) -> Bool {
        b1 & 0xFE == 0xE8 || (b0 == 0x0F && b1 & 0xF0 == 0x80)
    }

    private func bit(_ i: Int) throws -> Bool {
        let p = UInt32(probs[i])
        let bound = (range >> 11) &* p
        let one: Bool
        if code < bound {
            range = bound
            probs[i] = UInt16(p + ((2048 - p) >> 5))
            one = false
        } else {
            range &-= bound
            code &-= bound
            probs[i] = UInt16(p - (p >> 5))
            one = true
        }
        if range < 1 << 24 {
            range <<= 8
            code = code << 8 | UInt32(try rc.byte())
        }
        return one
    }

    func read(into buf: UnsafeMutableRawPointer, max: Int) throws -> Int {
        if !started {
            started = true
            for _ in 0..<5 { code = code << 8 | UInt32(try rc.byte()) }
        }
        let out = buf.assumingMemoryBound(to: UInt8.self)
        var n = 0
        while n < max && left > 0 {
            if pending.1 > 0 {
                out[n] = UInt8(truncatingIfNeeded: pending.0 >> UInt32(8 * (4 - pending.1)))
                pending.1 -= 1
                n += 1; left -= 1
                continue
            }
            let b = try main.byte()
            out[n] = b
            n += 1; left -= 1
            outPos &+= 1
            guard isJump(prevByte, b), left > 0 else { prevByte = b; continue }
            let index = b == 0xE8 ? Int(prevByte) : (b == 0xE9 ? 256 : 257)
            if try bit(index) {
                let s = b == 0xE8 ? call : jump
                var src: UInt32 = 0
                for _ in 0..<4 { src = src << 8 | UInt32(try s.byte()) }
                let dest = src &- (outPos &+ 4)
                pending = (dest, 4)
                prevByte = UInt8(truncatingIfNeeded: dest >> 24)
                outPos &+= 4
            } else {
                prevByte = b
            }
        }
        return n
    }
}

// MARK: - PPMd

/// PPMd variant H with the 7z range coder (030401), decoded by the LZMA SDK.
final class PPMdSource: ByteSource {
    private let input: ByteSource
    private var decoder: OpaquePointer?
    private var left: Int64
    private var inputError: Error?

    init(_ input: ByteSource, props: [UInt8], size: Int64) throws {
        guard props.count == 5 else { throw XipperError.corrupt("bad 7z PPMd properties") }
        let order = UInt32(props[0])
        let mem = UInt32(props[1]) | UInt32(props[2]) << 8 | UInt32(props[3]) << 16 | UInt32(props[4]) << 24
        if mem > 2 << 30 { throw XipperError.limitExceeded("PPMd model of \(mem >> 20) MiB") }
        self.input = input
        left = size
        let fill: xs_ppmd_fill = { ctx, buf, cap in
            let me = Unmanaged<PPMdSource>.fromOpaque(ctx!).takeUnretainedValue()
            do { return try me.input.read(into: buf!, max: cap) } catch {
                me.inputError = error
                return 0
            }
        }
        guard let d = xs_ppmd7_dec_new(order, mem, fill, Unmanaged.passUnretained(self).toOpaque()) else {
            throw XipperError.unsupported("PPMd order \(order) / memory \(mem)")
        }
        decoder = d
    }

    deinit { xs_ppmd7_dec_free(decoder) }

    func read(into buf: UnsafeMutableRawPointer, max: Int) throws -> Int {
        let n = Int(min(Int64(max), left))
        if n == 0 { return 0 }
        let r = xs_ppmd7_dec_read(decoder, buf.assumingMemoryBound(to: UInt8.self), n)
        if let e = inputError { throw e }
        if r == -2 { throw XipperError.corrupt("7z PPMd stream ended early") }
        if r != 0 { throw XipperError.corrupt("invalid PPMd data") }
        left -= Int64(n)
        return n
    }
}

// MARK: - Folder graph

/// Builds the pull pipeline that decodes a folder's content.
struct SZFolderDecoder {
    let folder: SZFolder
    let input: SevenZipInput
    /// Absolute offset and size of each of the folder's packed streams.
    let packs: [(offset: Int64, size: Int64)]
    let keys: SevenZipKeyCache?
    var onPackRead: ((Int) -> Void)?
    /// > 1: decode LZMA2 segments in parallel when the stream has dictionary resets.
    var workers = 1
    var qos: QualityOfService = .userInitiated

    func open() throws -> ByteSource {
        if workers > 1, let p = try parallelLZMA2() { return p }
        let s = try source(forOut: folder.mainOutStream)
        return workers > 1 && folder.unpackSize > 8 << 20 ? PipelinedSource(s, qos: qos) : s
    }

    /// LZMA2 producing the folder's content, alone or followed by ARM64 (stateless, so segments
    /// can be filtered independently when they start at multiples of 4). Its input can be
    /// anything (a packed stream, AES…): the stream is split while it is read.
    private func parallelLZMA2() throws -> ByteSource? {
        typealias M = SevenZip.Method
        let size = folder.unpackSize
        guard size > 8 << 20, let mc = folder.coder(forOutStream: folder.mainOutStream) else { return nil }
        var lzmaCoder = mc
        var arm64 = false
        if folder.coders[mc].method == M.arm64 && folder.coders[mc].props.isEmpty {
            guard let bp = folder.bindPairs.first(where: { $0.inIndex == folder.streamBases()[mc].inBase }),
                  let lc = folder.coder(forOutStream: bp.outIndex) else { return nil }
            lzmaCoder = lc
            arm64 = true
        }
        let c = folder.coders[lzmaCoder]
        let lzmaOut = folder.streamBases()[lzmaCoder].outBase
        guard c.method == M.lzma2, c.props.count == 1, c.numInStreams == 1, folder.unpackSizes[lzmaOut] == size else { return nil }
        let packed = try inputs(of: lzmaCoder)[0]
        return ExactSource(ParallelLZMA2Source(packed, prop: c.props[0], unpackSize: size, arm64: arm64, workers: workers, qos: qos), size: size)
    }

    private func inputs(of ci: Int) throws -> [ByteSource] {
        let base = folder.streamBases()[ci].inBase
        return try (0..<folder.coders[ci].numInStreams).map { k in
            let idx = base + k
            if let bp = folder.bindPairs.first(where: { $0.inIndex == idx }) { return try source(forOut: bp.outIndex) }
            guard let p = folder.packedStreams.firstIndex(of: idx), p < packs.count else { throw XipperError.corrupt("7z folder graph") }
            let s = PackStreamSource(input, offset: packs[p].offset, size: packs[p].size)
            s.onRead = onPackRead
            return s
        }
    }

    private func source(forOut out: Int) throws -> ByteSource {
        guard let ci = folder.coder(forOutStream: out) else { throw XipperError.corrupt("7z folder graph") }
        let size = folder.unpackSizes[out]
        return ExactSource(try decoder(folder.coders[ci], try inputs(of: ci), size: size), size: size)
    }

    private func decoder(_ c: SZCoder, _ inputs: [ByteSource], size: Int64) throws -> ByteSource {
        typealias M = SevenZip.Method
        if c.method != M.bcj2 && inputs.count != 1 { throw XipperError.corrupt("7z coder \(M.name(c.method)) with \(inputs.count) inputs") }
        let start = c.props.count == 4 ? UInt32(c.props[0]) | UInt32(c.props[1]) << 8 | UInt32(c.props[2]) << 16 | UInt32(c.props[3]) << 24 : 0
        switch c.method {
        case M.copy: return inputs[0]
        case M.lzma: return TransformSource(inputs[0], try SZLZMA.decoder(props: c.props, unpackSize: size))
        case M.lzma2:
            guard c.props.count == 1 else { throw XipperError.corrupt("bad 7z LZMA2 properties") }
            return TransformSource(inputs[0], try SZLZMA.decoder2(prop: c.props[0], unpackSize: size))
        case M.ppmd: return try PPMdSource(inputs[0], props: c.props, size: size)
        case M.bzip2: return TransformSource(inputs[0], try Bzip2Decoder())
        case M.deflate: return TransformSource(inputs[0], try InflateDecoder(gzip: false))
        case M.zstd: return TransformSource(inputs[0], try ZstdDecoder())
        case M.bcj2: return try BCJ2Source(inputs: inputs, size: size)
        case M.delta: return TransformSource(inputs[0], try DeltaFilter(props: c.props, encoding: false))
        case M.bcj: return TransformSource(inputs[0], BranchFilter(.x86, encoding: false, startOffset: start))
        case M.arm: return TransformSource(inputs[0], BranchFilter(.arm, encoding: false, startOffset: start))
        case M.armThumb: return TransformSource(inputs[0], BranchFilter(.armThumb, encoding: false, startOffset: start))
        case M.arm64: return TransformSource(inputs[0], BranchFilter(.arm64, encoding: false, startOffset: start))
        case M.riscv: return TransformSource(inputs[0], BranchFilter(.riscv, encoding: false, startOffset: start))
        case M.ppc: return TransformSource(inputs[0], BranchFilter(.ppc, encoding: false, startOffset: start))
        case M.sparc: return TransformSource(inputs[0], BranchFilter(.sparc, encoding: false, startOffset: start))
        case M.aes:
            guard let keys else { throw SZNeedsPassword() }
            let p = try SevenZipAES.parseProps(c.props)
            let key = keys.key(salt: p.salt, cyclesPower: p.cyclesPower)
            return TransformSource(inputs[0], try AESCBCCoder(key: key, iv: p.iv, encrypt: false))
        default:
            throw XipperError.unsupported("7z method \(M.name(c.method))")
        }
    }
}

/// An encrypted folder was reached without a password (mapped to `passwordRequired` with the entry name).
struct SZNeedsPassword: Error {}

// MARK: - LZMA / LZMA2 decoders

/// Chooses the LZMA decoder: the LZMA SDK's, whose main loop is 7-Zip's ARM64 assembly
/// (`Vendor/lzma-sdk/Asm/arm64/LzmaDecOpt.S`), or liblzma, the portable path.
enum SZLZMA {
    /// Set `XIPPER_PORTABLE_LZMA=1` to force liblzma (benchmarks, bug hunting).
    nonisolated(unsafe) static var useAssembly = ProcessInfo.processInfo.environment["XIPPER_PORTABLE_LZMA"] != "1"

    static func decoder(props: [UInt8], unpackSize: Int64, assembly: Bool = useAssembly) throws -> StreamTransform {
        guard assembly else { return try LZMACoder.sevenZipLZMADecoder(props: props, unpackSize: unpackSize) }
        return try SDKLZMADecoder(props: props, unpackSize: unpackSize)
    }

    static func decoder2(prop: UInt8, unpackSize: Int64, assembly: Bool = useAssembly) throws -> StreamTransform {
        guard assembly else { return try LZMACoder.sevenZipLZMA2Decoder(prop: prop, unpackSize: unpackSize) }
        return try SDKLZMADecoder(lzma2Prop: prop, unpackSize: unpackSize)
    }
}

/// LZMA1 (known size, end marker optional) or LZMA2 (ends with its end marker) through the LZMA SDK.
final class SDKLZMADecoder: StreamTransform {
    private let d: OpaquePointer
    private let lzma2: Bool
    /// LZMA1 output still expected.
    private var remaining: Int64
    private var ended = false
    private let out = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 20)

    private static func cap(_ size: Int64) -> UInt32 { UInt32(max(4096, min(size, Int64(UInt32.max)))) }

    init(props: [UInt8], unpackSize: Int64) throws {
        guard props.count == 5, let d = xs_lzma_dec_new(props, Self.cap(unpackSize)) else { throw XipperError.corrupt("bad 7z LZMA properties") }
        self.d = d
        lzma2 = false
        remaining = unpackSize
        ended = unpackSize == 0
    }

    init(lzma2Prop prop: UInt8, unpackSize: Int64) throws {
        guard let d = xs_lzma2_dec_new(prop, Self.cap(unpackSize)) else { throw XipperError.corrupt("bad 7z LZMA2 properties") }
        self.d = d
        lzma2 = true
        remaining = .max
    }

    deinit {
        xs_lzdec_free(d)
        out.deallocate()
    }

    private func run(_ input: UnsafeRawBufferPointer, last: Bool, _ sink: ByteSink) throws {
        var rest = input
        while !ended {
            let capacity = lzma2 ? 1 << 20 : Int(min(Int64(1 << 20), remaining))
            var used = 0, produced = 0
            let st = xs_lzdec_run(d, rest.baseAddress?.assumingMemoryBound(to: UInt8.self), rest.count, &used,
                                  out, capacity, &produced, lzma2 || Int64(capacity) < remaining ? 0 : 1)
            if st < 0 { throw XipperError.corrupt("invalid \(lzma2 ? "lzma2" : "lzma") data") }
            if produced > 0 { try sink(UnsafeRawBufferPointer(start: out, count: produced)) }
            rest = UnsafeRawBufferPointer(rebasing: rest[used...])
            if !lzma2 { remaining -= Int64(produced) }
            if st == 1 || (!lzma2 && remaining == 0) { ended = true; return }
            if used == 0 && produced == 0 {
                if last { throw XipperError.corrupt("truncated \(lzma2 ? "lzma2" : "lzma") stream") }
                return  // needs more input
            }
        }
    }

    func process(_ input: UnsafeRawBufferPointer, _ sink: ByteSink) throws {
        if !input.isEmpty { try run(input, last: false, sink) }
    }

    func finish(_ sink: ByteSink) throws { try run(UnsafeRawBufferPointer(start: nil, count: 0), last: true, sink) }
}

// MARK: - Parallel LZMA2

/// Decodes an LZMA2 stream in parallel where it restarts with a dictionary reset (7-Zip's
/// multi-threaded encoder and ours join independent chunks that way). The packed stream is
/// read sequentially and cut at chunk boundaries; segments are decoded by a pool and
/// delivered in order. A stream without usable resets falls back to one sequential decoder.
final class ParallelLZMA2Source: ByteSource, @unchecked Sendable {
    private final class Job: @unchecked Sendable {
        let unpackOffset: Int64
        let unpackSize: Int64
        var packed: [UInt8]
        var output: [UInt8] = []
        var error: Error?
        let done = DispatchSemaphore(value: 0)
        init(packed: [UInt8], unpackOffset: Int64, unpackSize: Int64) {
            self.packed = packed
            self.unpackOffset = unpackOffset
            self.unpackSize = unpackSize
        }
    }

    /// Segments are cut only past this size (tiny segments cost more than they save).
    static let minSegment: Int64 = 1 << 20
    /// A segment growing past these sizes without a reset switches to the sequential decoder.
    /// 7-Zip's blocks are 4× the dictionary (256 MiB at -mx6): those must still fit.
    static let maxPackedSegment = Int(min(256 << 20, ProcessInfo.processInfo.physicalMemory / 32))
    static let maxSegment = Int64(min(1 << 30, ProcessInfo.processInfo.physicalMemory / 16))

    private let packed: ByteSource
    private let prop: UInt8
    private let unpackSize: Int64
    private let arm64: Bool
    private let pool = OperationQueue()
    private let maxInFlight: Int
    private let budget: Int64
    private var queue: [Job] = []
    private var queuedBytes: Int64 = 0
    private var current: Job?
    private var pos = 0
    private var tail: ByteSource?
    /// Splitter state: raw bytes (whole chunks) of the segment being collected.
    private var seg: [UInt8] = []
    private var segStart: Int64 = 0
    private var unpacked: Int64 = 0
    /// Uncompressed chunk with dictionary reset that may start the next segment: (index in seg, unpacked offset).
    private var candidate: (Int, Int64)?
    private var splitDone = false
    private(set) var segmentCount = 0

    init(_ packed: ByteSource, prop: UInt8, unpackSize: Int64, arm64: Bool, workers: Int, qos: QualityOfService) {
        self.packed = ReadAheadSource(packed)
        self.prop = prop
        self.unpackSize = unpackSize
        self.arm64 = arm64
        pool.maxConcurrentOperationCount = max(1, workers)
        pool.qualityOfService = qos
        maxInFlight = workers + 2
        // Decoded segments wait in memory: a quarter of RAM at most (and 4 GiB).
        budget = Int64(min(ProcessInfo.processInfo.physicalMemory / 4, 4 << 30))
    }

    deinit { pool.cancelAllOperations() }

    private func readExactly(_ n: Int, into a: inout [UInt8]) throws {
        let old = a.count
        a.append(contentsOf: repeatElement(0, count: n))
        try a.withUnsafeMutableBytes { _ = try packed.readExactly(into: $0.baseAddress! + old, count: n) }
    }

    /// Cuts the next segment; nil when the stream ended or the splitter handed over to `tail`.
    private func split() throws -> Job? {
        while !splitDone {
            var head: [UInt8] = []
            try readExactly(1, into: &head)
            let c = head[0]
            if c == 0 {
                splitDone = true
                if unpacked != unpackSize { throw XipperError.corrupt("LZMA2 stream size mismatch") }
                return seg.isEmpty ? nil : cut(at: seg.count, unpacked: unpacked)
            }
            var cutAt: (Int, Int64)?
            let chunkUnpacked: Int64
            let rest: Int
            if c == 1 || c == 2 {
                try readExactly(2, into: &head)
                chunkUnpacked = (Int64(head[1]) << 8 | Int64(head[2])) + 1
                rest = Int(chunkUnpacked)
                if c == 1 && candidate == nil { candidate = (seg.count, unpacked) }
            } else if c >= 0x80 {
                try readExactly(c >= 0xC0 ? 5 : 4, into: &head)
                chunkUnpacked = (Int64(c & 0x1F) << 16 | Int64(head[1]) << 8 | Int64(head[2])) + 1
                rest = (Int(head[3]) << 8 | Int(head[4])) + 1
                // A reset with properties starts a segment; so does an earlier uncompressed reset
                // if this chunk brings properties (otherwise it would depend on older ones).
                if c >= 0xE0 { cutAt = candidate ?? (seg.count, unpacked) } else if c >= 0xC0, let cand = candidate { cutAt = cand }
                candidate = nil
            } else {
                throw XipperError.corrupt("invalid LZMA2 control byte \(c)")
            }
            var job: Job?
            if let (idx, u) = cutAt, idx > 0, u - segStart >= Self.minSegment, !arm64 || u % 4 == 0 {
                job = cut(at: idx, unpacked: u)
            }
            seg.append(contentsOf: head)
            try readExactly(rest, into: &seg)
            unpacked += chunkUnpacked
            if unpacked > unpackSize { throw XipperError.corrupt("LZMA2 stream larger than declared") }
            if job == nil && (seg.count > Self.maxPackedSegment || unpacked - segStart > Self.maxSegment) {
                startTail()
                return nil
            }
            if let job { return job }
        }
        return nil
    }

    /// Ends the current segment at `idx` (a chunk boundary in `seg`).
    private func cut(at idx: Int, unpacked u: Int64) -> Job {
        var bytes = Array(seg[0..<idx])
        bytes.append(0)  // end marker
        seg.removeFirst(idx)
        if let c = candidate { candidate = c.0 >= idx ? (c.0 - idx, c.1) : nil }
        let job = Job(packed: bytes, unpackOffset: segStart, unpackSize: u - segStart)
        segStart = u
        return job
    }

    /// Sequential decoding from the current segment start (a reset point) to the end.
    private func startTail() {
        splitDone = true
        let prefix = seg
        seg = []
        let source = ConcatSource(prefix, packed)
        var t: ByteSource = TransformSource(source, (try? SZLZMA.decoder2(prop: prop, unpackSize: unpackSize - segStart)) ?? FailingTransform())
        if arm64 { t = TransformSource(t, BranchFilter(.arm64, encoding: false, startOffset: UInt32(truncatingIfNeeded: segStart))) }
        tail = PipelinedSource(t, qos: pool.qualityOfService)
    }

    private func submit() throws {
        while queue.count < maxInFlight && queuedBytes < budget {
            guard let job = try split() else { return }
            segmentCount += 1
            queue.append(job)
            queuedBytes += job.unpackSize
            let prop = self.prop, arm64 = self.arm64
            pool.addOperation {
                defer { job.done.signal() }
                do { job.output = try Self.decode(job, prop: prop, arm64: arm64) } catch { job.error = error }
                job.packed = []
            }
        }
    }

    private static func decode(_ j: Job, prop: UInt8, arm64: Bool) throws -> [UInt8] {
        let coder = try SZLZMA.decoder2(prop: prop, unpackSize: j.unpackSize)
        var out = [UInt8](repeating: 0, count: Int(j.unpackSize))
        var filled = 0
        try out.withUnsafeMutableBytes { o in
            let sink: ByteSink = { chunk in
                if filled + chunk.count > o.count { throw XipperError.corrupt("LZMA2 segment larger than declared") }
                (o.baseAddress! + filled).copyMemory(from: chunk.baseAddress!, byteCount: chunk.count)
                filled += chunk.count
            }
            try j.packed.withUnsafeBytes { try coder.process($0, sink) }
            try coder.finish(sink)
            if filled != o.count { throw XipperError.corrupt("LZMA2 segment shorter than declared") }
            if arm64 {
                _ = lzma_bcj_arm64_decode(UInt32(truncatingIfNeeded: j.unpackOffset), o.baseAddress!.assumingMemoryBound(to: UInt8.self), o.count)
            }
        }
        return out
    }

    func read(into buf: UnsafeMutableRawPointer, max: Int) throws -> Int {
        while current == nil || pos == current!.output.count {
            current = nil
            try submit()
            guard !queue.isEmpty else { return try tail?.read(into: buf, max: max) ?? 0 }
            let job = queue.removeFirst()
            job.done.wait()
            queuedBytes -= job.unpackSize
            if let e = job.error { throw e }
            current = job
            pos = 0
            try submit()
        }
        let n = min(max, current!.output.count - pos)
        current!.output.withUnsafeBytes { buf.copyMemory(from: $0.baseAddress! + pos, byteCount: n) }
        pos += n
        return n
    }
}

/// `prefix` then `rest`.
final class ConcatSource: ByteSource {
    private let prefix: [UInt8]
    private var pos = 0
    private let rest: ByteSource

    init(_ prefix: [UInt8], _ rest: ByteSource) {
        self.prefix = prefix
        self.rest = rest
    }

    func read(into buf: UnsafeMutableRawPointer, max: Int) throws -> Int {
        if pos < prefix.count {
            let n = min(max, prefix.count - pos)
            prefix.withUnsafeBytes { buf.copyMemory(from: $0.baseAddress! + pos, byteCount: n) }
            pos += n
            return n
        }
        return try rest.read(into: buf, max: max)
    }
}

private final class FailingTransform: StreamTransform {
    func process(_ input: UnsafeRawBufferPointer, _ sink: ByteSink) throws { throw XipperError.corrupt("bad LZMA2 properties") }
    func finish(_ sink: ByteSink) throws { throw XipperError.corrupt("bad LZMA2 properties") }
}
