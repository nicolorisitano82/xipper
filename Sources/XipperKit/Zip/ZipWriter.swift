import CDeflate
import CZstd
import Dispatch
import Foundation
import Synchronization

public enum ZipMethod: Sendable, Equatable {
    case store
    /// Universal compatibility (every unzip tool, Archive Utility, Windows Explorer).
    case deflate
    /// ZIP method 93: much faster/smaller, readable by 7-Zip ≥ 21, WinZip, libarchive; not by Archive Utility.
    case zstd
}

public struct ZipOptions: Sendable {
    public var method: ZipMethod = .deflate
    /// deflate: 1…12 (libdeflate scale, 6 ≈ zip -6); zstd: 1…22.
    public var level: Int = 6
    /// Enables WinZip AES-256 encryption of all file data.
    public var password: String?
    /// Store files with already-compressed extensions (jpg, mp4, zip…) and big files that do not compress.
    public var storeAlreadyCompressed = true
    /// Always write ZIP64 structures (testing / huge-archive interop).
    public var forceZip64 = false
    /// Upper bound for compressed data held in memory (two windows in flight).
    public var memoryBudget: Int = 512 << 20
    public var workload: Workload = .interactive

    public init() {}
}

public struct WriteReport: Sendable {
    public var entries: Int
    public var inputBytes: Int64
    public var outputBytes: Int64
    public var elapsed: Double
}

/// Parallel ZIP writer.
///
/// Files are split into jobs (small files whole, big files in fixed-size chunks), jobs are
/// compressed in parallel window by window, and each window is written in archive order on
/// a serial queue while the next window is being compressed. Big deflate files use
/// pigz-style chunks (32 KiB dictionary, sync flush) so they stay a single standard stream.
enum ZipWriter {
    static let bigFileChunks = 4  // a file larger than this many chunks is split

    static func write(items: [ArchiveItem], to path: String, options: ZipOptions, overwrite: Bool,
                      progress: ProgressHandler?, cancel: CancellationToken?) throws -> WriteReport {
        let tracker = ProgressTracker(totalBytes: items.reduce(0) { $0 + $1.size }, totalEntries: items.count, handler: progress)
        let password = options.password.map(passwordBytes)
        if let p = password, p.isEmpty { throw XipperError.invalidArgument("empty password") }

        // 1. Plan: method and chunking per item.
        let plans = try plan(items, options: options, cancel: cancel)
        var jobs: [Job] = []
        for (i, p) in plans.enumerated() {
            if p.chunkCount > 0 {
                for c in 0..<p.chunkCount { jobs.append(Job(item: i, chunk: c)) }
            } else {
                jobs.append(Job(item: i, chunk: -1))
            }
        }

        // 2. Windows: compute in parallel, emit in order on the writer queue.
        let out = try OutputFile(path: path)
        let emitter = ZipEmitter(out: out, items: items, plans: plans, password: password, options: options)
        let writerQueue = DispatchQueue(label: "xipper.zip.writer", qos: options.workload.qos == .utility ? .utility : .userInitiated)
        let inFlight = DispatchSemaphore(value: 1)
        let writeError = Mutex<Error?>(nil)
        let windowBytes = max(options.memoryBudget / 2, 8 << 20)

        var cursor = 0
        while cursor < jobs.count {
            try cancel?.check()
            if let e = writeError.withLock({ $0 }) { throw e }
            var end = cursor, acc = 0
            while end < jobs.count && (acc < windowBytes || end == cursor) {
                acc += plans[jobs[end].item].jobInputBytes(jobs[end].chunk)
                end += 1
            }
            let window = Array(jobs[cursor..<end])
            let results = Slots<JobResult>(window.count)
            // Largest jobs first for load balance; dirs/symlinks need no compute.
            let order = window.indices.filter { plans[window[$0].item].needsCompute }
                .sorted { plans[window[$0].item].jobInputBytes(window[$0].chunk) > plans[window[$1].item].jobInputBytes(window[$1].chunk) }
            try parallelFor(order.count, workload: options.workload, cancel: cancel) { k in
                let j = window[order[k]]
                let r = try compute(j, item: items[j.item], plan: plans[j.item], options: options, password: password)
                results[order[k]] = r
                tracker.add(bytes: Int64(r.inputLength), entries: r.completesEntry ? 1 : 0, current: items[j.item].name)
            }
            inFlight.wait()
            let w = window
            writerQueue.async {
                defer { inFlight.signal() }
                if writeError.withLock({ $0 }) != nil { return }
                do {
                    for (k, j) in w.enumerated() { try emitter.emit(j, results.take(k)) }
                } catch {
                    writeError.withLock { $0 = error }
                }
            }
            cursor = end
        }
        writerQueue.sync {}
        if let e = writeError.withLock({ $0 }) { throw e }
        try cancel?.check()
        try emitter.finish()
        try out.commit(overwrite: overwrite)
        tracker.finish()
        return WriteReport(entries: items.count, inputBytes: tracker.completedBytes, outputBytes: out.position, elapsed: tracker.elapsed)
    }

    // MARK: planning

    struct Job { let item: Int; let chunk: Int }  // chunk -1 = whole item

    struct Plan {
        var method: Zip.Method  // .store / .deflate / .zstd (before encryption)
        var chunkSize: Int
        var chunkCount: Int  // 0 = not chunked
        var size: Int64
        var needsCompute: Bool
        var zip64: Bool

        func jobInputBytes(_ chunk: Int) -> Int {
            if chunk < 0 { return Int(size) }
            return Int(min(Int64(chunkSize), size - Int64(chunk) * Int64(chunkSize)))
        }
    }

    private static func plan(_ items: [ArchiveItem], options: ZipOptions, cancel: CancellationToken?) throws -> [Plan] {
        let base: Zip.Method = switch options.method { case .store: .store; case .deflate: .deflate; case .zstd: .zstd }
        let chunk = base == .deflate ? Deflate.chunkSize : 4 << 20
        var plans = items.map { item -> Plan in
            guard case let .file(size) = item.kind else {
                return Plan(method: .store, chunkSize: 0, chunkCount: 0, size: 0, needsCompute: false, zip64: options.forceZip64)
            }
            var method = base
            if size == 0 || (options.storeAlreadyCompressed && AlreadyCompressed.matches(item.name)) { method = .store }
            let big = size > Int64(chunk * bigFileChunks)
            return Plan(method: method, chunkSize: chunk, chunkCount: big ? Int((size + Int64(chunk) - 1) / Int64(chunk)) : 0,
                        size: size, needsCompute: true,
                        // Chunked entries are written before their compressed size is known: leave headroom.
                        zip64: options.forceZip64 || size >= 0xF000_0000)
        }
        // Big files of unknown type: probe 256 KiB, store if it does not compress.
        guard options.storeAlreadyCompressed else { return plans }
        let probe = plans.indices.filter { plans[$0].chunkCount > 0 && plans[$0].method != .store }
        let verdict = Slots<Bool>(probe.count)
        try parallelFor(probe.count, workload: options.workload, cancel: cancel) { k in
            let item = items[probe[k]]
            let r = try FileReader(path: item.sourcePath)
            let n = Int(min(r.size, 256 << 10))
            let sample = try r.read(at: 0, count: n)
            let packed = sample.withUnsafeBytes { Deflate.compress($0, level: 1) }
            verdict[k] = (packed?.count ?? n) > n * 97 / 100
        }
        for (k, i) in probe.enumerated() where verdict[k] == true { plans[i].method = .store }
        return plans
    }

    // MARK: compute (worker threads)

    struct JobResult {
        var payload: [UInt8]
        var crc: UInt32
        var inputLength: Int
        /// Whole entries: method actually used (may fall back to store).
        var method: Zip.Method
        var completesEntry: Bool
    }

    private static func compute(_ job: Job, item: ArchiveItem, plan: Plan, options: ZipOptions, password: [UInt8]?) throws -> JobResult {
        let reader = try FileReader(path: item.sourcePath)
        if job.chunk < 0 {
            // Whole file. Size taken now: a file that grew or shrank since the scan is archived as it is.
            let size = Int(reader.size)
            let data = try reader.read(at: 0, count: size)
            let crc = CRC32.checksum(data)
            var method = plan.method
            var payload: [UInt8] = data
            if method == .deflate {
                if let c = data.withUnsafeBytes({ Deflate.compress($0, level: options.level) }) { payload = c } else { method = .store }
            } else if method == .zstd {
                if let c = data.withUnsafeBytes({ zstdCompress($0, level: options.level) }) { payload = c } else { method = .store }
            }
            if let password {
                let enc = try WinZipAESEncryptor(password: password)
                enc.encrypt(&payload)
                payload = enc.header + payload + enc.trailer
            }
            return JobResult(payload: payload, crc: crc, inputLength: size, method: method, completesEntry: true)
        }

        // Chunk of a big file.
        let offset = Int64(job.chunk) * Int64(plan.chunkSize)
        let len = plan.jobInputBytes(job.chunk)
        let last = job.chunk == plan.chunkCount - 1
        let dictLen = plan.method == .deflate ? Int(min(Int64(Deflate.windowSize), offset)) : 0
        if offset + Int64(len) > reader.size || (last && reader.size != plan.size) {
            throw XipperError.io("read (file changed while archiving)", path: item.sourcePath, errno: EAGAIN)
        }
        let buf = try reader.read(at: offset - Int64(dictLen), count: dictLen + len)
        return try buf.withUnsafeBytes { all in
            let data = UnsafeRawBufferPointer(rebasing: all[dictLen...])
            let crc = CRC32.checksum(data)
            let payload: [UInt8]
            switch plan.method {
            case .deflate:
                let dict = dictLen > 0 ? UnsafeRawBufferPointer(rebasing: all[..<dictLen]) : nil
                payload = try Deflate.compressChunk(data, dict: dict, level: min(options.level, 9), last: last)
            case .zstd:
                // Each chunk is an independent zstd frame; decoders read concatenated frames.
                payload = zstdCompress(data, level: options.level, allowExpansion: true)!
            default:
                payload = Array(data)
            }
            return JobResult(payload: payload, crc: crc, inputLength: len, method: plan.method, completesEntry: last)
        }
    }

    /// ZIP AES passwords are UTF-8 in NFC (WinZip convention). 7-Zip refuses non-ASCII
    /// ZIP passwords altogether, so the UI warns when one is used.
    static func passwordBytes(_ s: String) -> [UInt8] { Array(s.precomposedStringWithCanonicalMapping.utf8) }

    static func zstdCompress(_ src: UnsafeRawBufferPointer, level: Int, allowExpansion: Bool = false) -> [UInt8]? {
        let bound = ZSTD_compressBound(src.count)
        let out = [UInt8](unsafeUninitializedCapacity: bound) { buf, n in
            let r = ZSTD_compress(buf.baseAddress, bound, src.baseAddress, src.count, Int32(max(1, min(22, level))))
            n = ZSTD_isError(r) != 0 ? 0 : r
        }
        if out.isEmpty || (!allowExpansion && out.count >= src.count) { return nil }
        return out
    }
}

// MARK: - Emitter (writer queue only)

/// Writes local headers, data and collects central directory records, strictly in archive order.
private final class ZipEmitter: @unchecked Sendable {
    let out: OutputFile
    let items: [ArchiveItem]
    let plans: [ZipWriter.Plan]
    let password: [UInt8]?
    let options: ZipOptions
    private var central = ByteWriter(capacity: 1 << 20)
    private var count = 0
    private var open: OpenEntry?

    /// State of a chunked entry being streamed across windows.
    private struct OpenEntry {
        var item: Int
        var headerOffset: Int64
        var header: HeaderFields
        var crc: UInt32 = 0
        var compressed: Int64 = 0
        var uncompressed: Int64 = 0
        var encryptor: WinZipAESEncryptor?
    }

    init(out: OutputFile, items: [ArchiveItem], plans: [ZipWriter.Plan], password: [UInt8]?, options: ZipOptions) {
        self.out = out
        self.items = items
        self.plans = plans
        self.password = password
        self.options = options
    }

    func emit(_ job: ZipWriter.Job, _ result: ZipWriter.JobResult?) throws {
        let item = items[job.item]
        let plan = plans[job.item]
        switch item.kind {
        case .directory:
            try writeWhole(item, method: .store, crc: 0, usize: 0, payload: [], encrypted: false, zip64: plan.zip64, isDir: true)
        case let .symlink(target):
            let data = Array(target.utf8)
            try writeWhole(item, method: .store, crc: CRC32.checksum(data), usize: Int64(data.count), payload: data,
                           encrypted: false, zip64: plan.zip64, isDir: false)
        case .file:
            guard let r = result else { throw XipperError.codec("missing job result") }
            if job.chunk < 0 {
                try writeWhole(item, method: r.method, crc: r.crc, usize: Int64(r.inputLength), payload: r.payload,
                               encrypted: password != nil, zip64: plan.zip64 || Int64(r.payload.count) >= 0xFFFF_FFFF, isDir: false)
            } else {
                try writeChunk(job, r)
            }
        }
    }

    // MARK: entries

    private struct HeaderFields {
        var name: [UInt8]
        var method: Zip.Method
        var encrypted: Bool
        var aesVersion: UInt16
        var flags: UInt16
        var dosTime: UInt16
        var dosDate: UInt16
        var mtime: UInt32
        var zip64: Bool
        var mode: UInt32
        var isDir: Bool

        var versionNeeded: UInt16 {
            var v: UInt16 = 20
            if zip64 { v = max(v, 45) }
            if encrypted { v = max(v, 51) }
            if method == .zstd { v = max(v, 63) }
            return v
        }

        var storedMethod: UInt16 { encrypted ? Zip.Method.aes.rawValue : method.rawValue }

        func extras(central: Bool, usize: Int64, csize: Int64, offset: Int64) -> [UInt8] {
            var w = ByteWriter()
            if central {
                // Only fields that overflow (or all of them when forced) go into the ZIP64 extra.
                var z = ByteWriter()
                if zip64 || UInt64(usize) >= Zip.max32 { z.u64(UInt64(usize)) }
                if zip64 || UInt64(csize) >= Zip.max32 { z.u64(UInt64(csize)) }
                if zip64 || UInt64(offset) >= Zip.max32 { z.u64(UInt64(offset)) }
                if !z.bytes.isEmpty { w.u16(Zip.Extra.zip64); w.u16(UInt16(z.bytes.count)); w.append(z.bytes) }
            } else if zip64 {
                w.u16(Zip.Extra.zip64); w.u16(16); w.u64(UInt64(usize)); w.u64(UInt64(csize))
            }
            w.u16(Zip.Extra.extendedTimestamp); w.u16(5); w.u8(1); w.u32(mtime)
            if encrypted {
                w.u16(Zip.Extra.aes); w.u16(7); w.u16(aesVersion)
                w.u8(UInt8(ascii: "A")); w.u8(UInt8(ascii: "E")); w.u8(WinZipAES.Strength.aes256.rawValue)
                w.u16(method.rawValue)
            }
            return w.bytes
        }

        func local(crc: UInt32, csize: Int64, usize: Int64) -> [UInt8] {
            var w = ByteWriter(capacity: 30 + name.count + 64)
            let ext = extras(central: false, usize: usize, csize: csize, offset: 0)
            w.u32(Zip.localSignature); w.u16(versionNeeded); w.u16(flags); w.u16(storedMethod)
            w.u16(dosTime); w.u16(dosDate); w.u32(crc)
            w.u32(zip64 ? UInt32.max : UInt32(csize)); w.u32(zip64 ? UInt32.max : UInt32(usize))
            w.u16(UInt16(name.count)); w.u16(UInt16(ext.count))
            w.append(name); w.append(ext)
            return w.bytes
        }

        func centralRecord(crc: UInt32, csize: Int64, usize: Int64, offset: Int64) -> [UInt8] {
            var w = ByteWriter(capacity: 46 + name.count + 64)
            let ext = extras(central: true, usize: usize, csize: csize, offset: offset)
            func field(_ v: Int64) -> UInt32 { zip64 || UInt64(v) >= Zip.max32 ? UInt32.max : UInt32(v) }
            w.u32(Zip.centralSignature); w.u16(Zip.versionMadeBy); w.u16(versionNeeded); w.u16(flags); w.u16(storedMethod)
            w.u16(dosTime); w.u16(dosDate); w.u32(crc)
            w.u32(field(csize)); w.u32(field(usize))
            w.u16(UInt16(name.count)); w.u16(UInt16(ext.count)); w.u16(0)  // comment
            w.u16(0); w.u16(0)  // disk, internal attributes
            w.u32(mode << 16 | (isDir ? 0x10 : 0))
            w.u32(field(offset))
            w.append(name); w.append(ext)
            return w.bytes
        }
    }

    private func fields(_ item: ArchiveItem, method: Zip.Method, encrypted: Bool, aesVersion: UInt16, zip64: Bool, isDir: Bool) throws -> HeaderFields {
        var name = Array(item.name.utf8)
        if isDir { name.append(UInt8(ascii: "/")) }
        if name.count > 0xFFFF { throw XipperError.invalidArgument("path too long: \(item.name)") }
        let (t, d) = DOSDateTime.encode(item.modified)
        let typeBits: UInt32 = switch item.kind { case .directory: 0o040000; case .symlink: 0o120000; case .file: 0o100000 }
        var flags = Zip.Flag.utf8
        if encrypted { flags |= Zip.Flag.encrypted }
        return HeaderFields(name: name, method: method, encrypted: encrypted, aesVersion: aesVersion, flags: flags,
                            dosTime: t, dosDate: d,
                            mtime: UInt32(clamping: Int64(max(0, item.modified.timeIntervalSince1970))),
                            zip64: zip64, mode: typeBits | UInt32(item.permissions), isDir: isDir)
    }

    /// AE-1 (CRC kept) for normal files; AE-2 (CRC hidden) under 20 bytes, as WinZip does.
    private func aesVersion(_ usize: Int64) -> UInt16 { usize < 20 ? 2 : 1 }

    private func writeWhole(_ item: ArchiveItem, method: Zip.Method, crc: UInt32, usize: Int64, payload: [UInt8],
                            encrypted: Bool, zip64: Bool, isDir: Bool) throws {
        let av = aesVersion(usize)
        let f = try fields(item, method: method, encrypted: encrypted, aesVersion: av, zip64: zip64, isDir: isDir)
        let storedCRC = encrypted && av == 2 ? 0 : crc
        let offset = out.position
        try out.write(f.local(crc: storedCRC, csize: Int64(payload.count), usize: usize))
        try out.write(payload)
        central.append(f.centralRecord(crc: storedCRC, csize: Int64(payload.count), usize: usize, offset: offset))
        count += 1
    }

    private func writeChunk(_ job: ZipWriter.Job, _ r: ZipWriter.JobResult) throws {
        let item = items[job.item]
        let plan = plans[job.item]
        if job.chunk == 0 {
            let enc = try password.map { try WinZipAESEncryptor(password: $0) }
            let f = try fields(item, method: plan.method, encrypted: enc != nil, aesVersion: aesVersion(plan.size),
                               zip64: plan.zip64, isDir: false)
            open = OpenEntry(item: job.item, headerOffset: out.position, header: f, encryptor: enc)
            try out.write(f.local(crc: 0, csize: 0, usize: 0))  // patched when the entry closes
            if let enc { try out.write(enc.header); open!.compressed += Int64(enc.header.count) }
        }
        guard var e = open, e.item == job.item else { throw XipperError.codec("chunk out of order") }
        var payload = r.payload
        e.encryptor?.encrypt(&payload)
        try out.write(payload)
        e.crc = e.uncompressed == 0 ? r.crc : CRC32.combine(e.crc, r.crc, lengthB: Int64(r.inputLength))
        e.compressed += Int64(payload.count)
        e.uncompressed += Int64(r.inputLength)
        if job.chunk == plan.chunkCount - 1 {
            if let enc = e.encryptor { let t = enc.trailer; try out.write(t); e.compressed += Int64(t.count) }
            if !e.header.zip64 && (UInt64(e.compressed) >= Zip.max32 || UInt64(e.uncompressed) >= Zip.max32) {
                throw XipperError.codec("entry outgrew its non-ZIP64 header: \(item.name)")
            }
            let storedCRC = e.header.encrypted && e.header.aesVersion == 2 ? 0 : e.crc
            try out.patch(at: e.headerOffset, e.header.local(crc: storedCRC, csize: e.compressed, usize: e.uncompressed))
            central.append(e.header.centralRecord(crc: storedCRC, csize: e.compressed, usize: e.uncompressed, offset: e.headerOffset))
            count += 1
            open = nil
        } else {
            open = e
        }
    }

    // MARK: end of central directory

    func finish() throws {
        let cdOffset = out.position
        try out.write(central.bytes)
        let cdSize = Int64(central.bytes.count)
        let needs64 = options.forceZip64 || UInt64(count) >= Zip.max16 || UInt64(cdOffset) >= Zip.max32 || UInt64(cdSize) >= Zip.max32
        var w = ByteWriter()
        if needs64 {
            let z64Offset = out.position
            w.u32(Zip.zip64EndSignature); w.u64(44); w.u16(Zip.versionMadeBy); w.u16(45)
            w.u32(0); w.u32(0); w.u64(UInt64(count)); w.u64(UInt64(count)); w.u64(UInt64(cdSize)); w.u64(UInt64(cdOffset))
            w.u32(Zip.zip64LocatorSignature); w.u32(0); w.u64(UInt64(z64Offset)); w.u32(1)
        }
        let n16 = needs64 ? UInt16.max : UInt16(count)
        w.u32(Zip.endSignature); w.u16(0); w.u16(0); w.u16(n16); w.u16(n16)
        w.u32(needs64 ? UInt32.max : UInt32(cdSize)); w.u32(needs64 ? UInt32.max : UInt32(cdOffset)); w.u16(0)
        try out.write(w.bytes)
        try out.flush()
    }
}
