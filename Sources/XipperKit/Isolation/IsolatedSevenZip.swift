import Darwin
import Foundation
import Synchronization

/// 7z folders decoded in the `xipper-decoder` helper (2.7). The 7z parser is Xipper's own Swift and
/// stays here; what goes to the helper is the C code: LZMA/LZMA2 (with 7-Zip's ARM64 assembly),
/// PPMd, BZip2, Deflate, zstd, BCJ2 and the branch filters. The encoded header goes the same way.
///
/// A request carries one folder (its coder graph, where its packed streams are, the AES keys
/// already derived here: the password never leaves this process) and the helper streams back the
/// folder's content. Folders are independent, so each archive keeps a small pool of helpers: one
/// per folder decoded at the same time, reused once a folder has been read to its end; a folder
/// abandoned halfway takes its helper with it.
final class SevenZipDecoderPool: @unchecked Sendable {
    let helper: String
    let volumes: [String]
    let name: String
    private let idle = Mutex<[DecoderProcess]>([])
    static let maxChunk = 1 << 20

    init(helper: String, volumes: [String], name: String) {
        self.helper = helper
        self.volumes = volumes
        self.name = name
    }

    /// The content of `folder` from byte `skip`, decoded in a helper.
    func open(_ folder: SZFolder, packs: [(offset: Int64, size: Int64)], keys: SevenZipKeyCache?,
              workers: Int, qos: QualityOfService, skip: Int64) throws -> ByteSource {
        var w = IsolatedDecoder.Writer()
        Self.encode(folder, into: &w)
        w.u32(UInt32(packs.count))
        for p in packs { w.i64(p.offset); w.i64(p.size) }
        // The keys of the folder's AES coders; none without a password (the helper then says so).
        let aes = folder.coders.filter { $0.method == SevenZip.Method.aes }
        if let keys {
            w.u8(1)
            w.u32(UInt32(aes.count))
            for c in aes {
                let p = try SevenZipAES.parseProps(c.props)
                let id = [p.cyclesPower] + p.salt
                w.u32(UInt32(id.count)); w.bytes += id
                let k = keys.key(salt: p.salt, cyclesPower: p.cyclesPower)
                w.u32(UInt32(k.count)); w.bytes += k
            }
        } else {
            w.u8(0)
        }
        w.u32(UInt32(max(1, min(workers, 64)))); w.i64(Int64(qos.rawValue)); w.i64(skip)
        let process = try idle.withLock { $0.popLast() } ?? spawn()
        try process.send(.folder, w.bytes)
        return IsolatedFolderSource(pool: self, process: process, size: max(0, folder.unpackSize - skip))
    }

    private func spawn() throws -> DecoderProcess {
        let p = try DecoderProcess(helper: helper, volumes: volumes, name: name)
        var w = IsolatedDecoder.Writer()
        w.str(name); w.u32(UInt32(volumes.count))
        try p.send(.sevenZip, w.bytes)
        let (type, payload) = try p.receive()
        guard type == IsolatedDecoder.Reply.opened.rawValue else {
            if type == IsolatedDecoder.Reply.error.rawValue { throw try IsolatedDecoder.decodeError(payload) }
            throw XipperError.corrupt("decoder helper: unexpected reply")
        }
        return p
    }

    /// A helper whose conversation ended in step, ready for the next folder.
    func checkIn(_ p: DecoderProcess) { idle.withLock { $0.append(p) } }

    /// For tests: helpers waiting for a folder.
    var idleCount: Int { idle.withLock { $0.count } }

    /// For tests: a folder whose helper crashes as a decoder bug would.
    func crashing() throws -> ByteSource {
        let process = try spawn()
        try process.send(.crash)
        return IsolatedFolderSource(pool: self, process: process, size: 1)
    }

    // MARK: wire format of a folder

    static func encode(_ f: SZFolder, into w: inout IsolatedDecoder.Writer) {
        w.u32(UInt32(f.coders.count))
        for c in f.coders {
            w.i64(Int64(bitPattern: c.method)); w.u32(UInt32(c.numInStreams)); w.u32(UInt32(c.numOutStreams))
            w.u32(UInt32(c.props.count)); w.bytes += c.props
        }
        w.u32(UInt32(f.bindPairs.count))
        for b in f.bindPairs { w.u32(UInt32(b.inIndex)); w.u32(UInt32(b.outIndex)) }
        w.u32(UInt32(f.packedStreams.count))
        for p in f.packedStreams { w.u32(UInt32(p)) }
        w.u32(UInt32(f.unpackSizes.count))
        for s in f.unpackSizes { w.i64(s) }
        w.u8(f.crc == nil ? 0 : 1); w.u32(f.crc ?? 0)
    }

    static func decodeFolder(_ r: inout IsolatedDecoder.Reader) throws -> SZFolder {
        func count() throws -> Int {
            let n = Int(try r.u32())
            guard n <= 64 else { throw XipperError.corrupt("decoder helper: malformed request") }
            return n
        }
        var f = SZFolder()
        for _ in 0..<(try count()) {
            let method = UInt64(bitPattern: try r.i64())
            let ins = try count(), outs = try count()
            let props = Array(try r.take(Int(try r.u32())))
            f.coders.append(SZCoder(method: method, numInStreams: ins, numOutStreams: outs, props: props))
        }
        for _ in 0..<(try count()) { f.bindPairs.append((Int(try r.u32()), Int(try r.u32()))) }
        for _ in 0..<(try count()) { f.packedStreams.append(Int(try r.u32())) }
        for _ in 0..<(try count()) { f.unpackSizes.append(try r.i64()) }
        let hasCRC = try r.u8(), crc = try r.u32()
        f.crc = hasCRC == 1 ? crc : nil
        return f
    }

    // MARK: helper side

    /// The 7z loop of `xipper-decoder`: one folder per request, until the app closes the pipe.
    static func serve(_ open: [UInt8], input: Int32, output: Int32) -> Int32 {
        let source: SevenZipInput
        do {
            var r = IsolatedDecoder.Reader(open)
            let name = try r.str()
            let count = Int(try r.u32())
            guard (1...9999).contains(count) else { throw XipperError.invalidArgument("volumes") }
            source = try SevenZipInput(path: name, volumes: (0..<count).map { "/dev/fd/\(3 + $0)" })
        } catch {
            _ = IsolatedDecoder.frame(output, IsolatedDecoder.Reply.error.rawValue, IsolatedDecoder.encode(error))
            return 1
        }
        guard IsolatedDecoder.frame(output, IsolatedDecoder.Reply.opened.rawValue) else { return 1 }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: maxChunk, alignment: 16384)
        defer { buf.deallocate() }
        while let (op, n) = IsolatedDecoder.readHeader(input) {
            guard n <= 1 << 20 else { return 2 }
            var b = [UInt8](repeating: 0, count: n)
            guard n == 0 || b.withUnsafeMutableBytes({ IsolatedDecoder.readAll(input, $0.baseAddress!, n) }) else { return 2 }
            switch IsolatedDecoder.Op(rawValue: op) {
            case .folder?: break
            case .crash?: abort()
            default: return 2
            }
            do {
                var r = IsolatedDecoder.Reader(b)
                let folder = try decodeFolder(&r)
                let packs = try (0..<min(Int(try r.u32()), 64)).map { _ in (offset: try r.i64(), size: try r.i64()) }
                var keys: SevenZipKeyCache?
                if try r.u8() == 1 {
                    var known: [[UInt8]: [UInt8]] = [:]
                    for _ in 0..<min(try r.u32(), 64) {
                        let id = Array(try r.take(Int(try r.u32())))
                        known[id] = Array(try r.take(Int(try r.u32())))
                    }
                    keys = SevenZipKeyCache(password: [], known: known)
                }
                let workers = Int(try r.u32())
                let qos = QualityOfService(rawValue: Int(try r.i64())) ?? .userInitiated
                let skip = try r.i64()
                var d = SZFolderDecoder(folder: folder, input: source, packs: packs, keys: keys)
                d.workers = max(1, min(workers, 64))
                d.qos = qos
                let src = try d.open()
                if skip > 0 { try src.skip(skip) }
                while true {
                    let got = try src.read(into: buf, max: maxChunk)
                    if got == 0 { break }
                    guard IsolatedDecoder.frame(output, IsolatedDecoder.Reply.chunk.rawValue, UnsafeRawBufferPointer(start: buf, count: got)) else { return 1 }
                }
                guard IsolatedDecoder.frame(output, IsolatedDecoder.Reply.dataEnd.rawValue) else { return 1 }
            } catch {
                // Folders are independent: after the error the helper takes the next request.
                guard IsolatedDecoder.frame(output, IsolatedDecoder.Reply.error.rawValue, IsolatedDecoder.encode(error)) else { return 1 }
            }
        }
        return 0
    }
}

/// App side: one folder's content as it comes from a helper, exactly `size` bytes. The helper goes
/// back to the pool once its end (or error) frame is read; dropped before that, it is killed.
final class IsolatedFolderSource: ByteSource {
    private let pool: SevenZipDecoderPool
    private var process: DecoderProcess?
    private var left: Int64
    private let buf = UnsafeMutableRawPointer.allocate(byteCount: SevenZipDecoderPool.maxChunk, alignment: 16384)
    private var pos = 0, have = 0

    init(pool: SevenZipDecoderPool, process: DecoderProcess, size: Int64) {
        self.pool = pool
        self.process = process
        left = size
    }

    deinit { buf.deallocate() }

    func read(into dst: UnsafeMutableRawPointer, max: Int) throws -> Int {
        let n: Int
        if pos < have {
            n = min(max, have - pos)
            dst.copyMemory(from: buf + pos, byteCount: n)
            pos += n
        } else {
            if left == 0 {
                if process != nil { _ = try? next(into: nil, max: 0) }  // an empty folder: only its end frame
                return 0
            }
            guard let got = try next(into: dst, max: max) else { throw XipperError.corrupt("7z stream ended early (truncated or corrupt data)") }
            n = got
        }
        // Everything arrived: read the end frame now, so the helper is free for the next folder.
        if pos == have && left == 0 { _ = try? next(into: nil, max: 0) }
        return n
    }

    /// Reads the next chunk into `dst` when it fits (most reads ask for a whole chunk), through
    /// the buffer otherwise; nil at the end of the folder.
    private func next(into dst: UnsafeMutableRawPointer?, max: Int) throws -> Int? {
        guard let p = process else { return nil }
        do {
            let (type, n) = try p.header()
            switch type {
            case IsolatedDecoder.Reply.chunk.rawValue:
                guard n > 0, n <= SevenZipDecoderPool.maxChunk, Int64(n) <= left else { throw XipperError.corrupt("decoder helper: malformed reply") }
                left -= Int64(n)
                if let dst, n <= max {
                    try p.read(into: dst, n)
                    return n
                }
                try p.read(into: buf, n)
                have = n
                pos = min(max, n)
                if let dst { dst.copyMemory(from: buf, byteCount: pos) }
                return pos
            case IsolatedDecoder.Reply.dataEnd.rawValue:
                guard n == 0 else { throw XipperError.corrupt("decoder helper: malformed reply") }
                finish(p)
                return nil
            case IsolatedDecoder.Reply.error.rawValue:
                let payload = try p.payload(n)
                finish(p)
                if payload.first == 11 { throw SZNeedsPassword() }
                throw try IsolatedDecoder.decodeError(payload)
            default:
                throw XipperError.corrupt("decoder helper: unexpected reply")
            }
        } catch {
            process = nil  // out of step (or already back in the pool): dropping it kills the helper
            throw error
        }
    }

    private func finish(_ p: DecoderProcess) {
        process = nil
        pool.checkIn(p)
    }
}
