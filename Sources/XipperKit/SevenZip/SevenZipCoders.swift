import CLZMA
import CPpmd
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
        out.removeAll(keepingCapacity: true)
        out.reserveCapacity(input.count)
        for b in input {
            let prev = history[(pos &- distance) & 0xFF]
            let v = encoding ? b &- prev : b &+ prev
            history[pos & 0xFF] = encoding ? b : v
            pos &+= 1
            out.append(v)
        }
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

    func open() throws -> ByteSource { try source(forOut: folder.mainOutStream) }

    private func source(forOut out: Int) throws -> ByteSource {
        guard let ci = folder.coder(forOutStream: out) else { throw XipperError.corrupt("7z folder graph") }
        let c = folder.coders[ci]
        let base = folder.streamBases()[ci].inBase
        let inputs: [ByteSource] = try (0..<c.numInStreams).map { k in
            let idx = base + k
            if let bp = folder.bindPairs.first(where: { $0.inIndex == idx }) { return try source(forOut: bp.outIndex) }
            guard let p = folder.packedStreams.firstIndex(of: idx), p < packs.count else { throw XipperError.corrupt("7z folder graph") }
            let s = PackStreamSource(input, offset: packs[p].offset, size: packs[p].size)
            s.onRead = onPackRead
            return s
        }
        let size = folder.unpackSizes[out]
        return ExactSource(try decoder(c, inputs, size: size), size: size)
    }

    private func decoder(_ c: SZCoder, _ inputs: [ByteSource], size: Int64) throws -> ByteSource {
        typealias M = SevenZip.Method
        if c.method != M.bcj2 && inputs.count != 1 { throw XipperError.corrupt("7z coder \(M.name(c.method)) with \(inputs.count) inputs") }
        let start = c.props.count == 4 ? UInt32(c.props[0]) | UInt32(c.props[1]) << 8 | UInt32(c.props[2]) << 16 | UInt32(c.props[3]) << 24 : 0
        switch c.method {
        case M.copy: return inputs[0]
        case M.lzma: return TransformSource(inputs[0], try LZMACoder.sevenZipLZMADecoder(props: c.props, unpackSize: size))
        case M.lzma2:
            guard c.props.count == 1 else { throw XipperError.corrupt("bad 7z LZMA2 properties") }
            return TransformSource(inputs[0], try LZMACoder.sevenZipLZMA2Decoder(prop: c.props[0], unpackSize: size))
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
