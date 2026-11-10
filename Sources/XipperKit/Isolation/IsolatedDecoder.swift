import Darwin
import Foundation

/// Decoders of external code (libarchive's RAR readers; the C codecs of 7z folders, see
/// IsolatedSevenZip.swift; brunsli, JPEGRecompression.swift) run in `xipper-decoder`, a helper process signed with the App Sandbox
/// and nothing else (2.7): no files of its own, no network, no writes. It gets the archive volumes
/// as already-open read-only descriptors (3, 4, …), the password (RAR) or the derived keys (7z) on
/// its standard input, and sends back entries and data as frames on its standard output. A memory bug
/// in the decoder can at worst crash or fool that process: the app sees a damaged archive, and
/// every entry still goes through Xipper's safe extraction here, in the calling process.
///
/// Without the helper (sandboxed extensions, which cannot start it and are sandboxed already; a
/// build without it; `XIPPER_IN_PROCESS_DECODERS=1`) the same reader runs in process.
enum IsolatedDecoder {
    /// Request frames, app → helper.
    enum Op: UInt8 { case open = 1, next = 2, data = 3, sevenZip = 4, folder = 5, jpeg = 6, jpegEncode = 7, jpegDecode = 8, deflateSplit = 9, deflateRebuild = 10, crash = 0xFF }
    /// Response frames, helper → app.
    enum Reply: UInt8 { case opened = 0x4F, entry = 0x45, end = 0x4E, chunk = 0x44, dataEnd = 0x5A, error = 0x58 }

    static let helperName = "xipper-decoder"

    /// The helper next to this executable, in the app's Contents/Helpers, or next to the test bundle.
    static let helperPath: String? = {
        let env = ProcessInfo.processInfo.environment
        if env["XIPPER_IN_PROCESS_DECODERS"] == "1" || env["APP_SANDBOX_CONTAINER_ID"] != nil { return nil }
        if let p = env["XIPPER_DECODER"] { return FileManager.default.isExecutableFile(atPath: p) ? p : nil }
        // The image XipperKit is linked into: the app (Contents/MacOS), the CLI (Contents/Helpers), a test bundle.
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let fname = info.dli_fname else { return nil }
        var image = URL(fileURLWithPath: String(cString: fname)).resolvingSymlinksInPath().deletingLastPathComponent()
        var dirs = [image, image.deletingLastPathComponent().appendingPathComponent("Helpers")]
        while image.path != "/" && !image.pathExtension.isEmpty || image.lastPathComponent == "MacOS" || image.lastPathComponent == "Contents" {
            image.deleteLastPathComponent()
        }
        dirs.append(image)  // next to Name.xctest
        return dirs.map { $0.appendingPathComponent(helperName).path }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Whether RAR archives and 7z folders are decoded in the sandboxed helper.
    static var isAvailable: Bool { helperPath != nil }

    /// A RAR reader: in the helper when there is one, in process otherwise.
    static func rar(path: String, password: String?) throws -> EntryStreamReader {
        guard let helper = helperPath else { return try RarReader(path: path, password: password) }
        return try IsolatedEntryReader(helper: helper, volumes: RarReader.volumes(for: path),
                                       name: (path as NSString).lastPathComponent, password: password)
    }

    // MARK: wire format: [op/reply u8][length u32 LE][payload]

    struct Writer {
        var bytes: [UInt8] = []
        mutating func u8(_ v: UInt8) { bytes.append(v) }
        mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { bytes += $0 } }
        mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { bytes += $0 } }
        mutating func i64(_ v: Int64) { withUnsafeBytes(of: v.littleEndian) { bytes += $0 } }
        mutating func f64(_ v: Double) { i64(Int64(bitPattern: v.bitPattern)) }
        mutating func str(_ s: String) { let u = Array(s.utf8); u32(UInt32(u.count)); bytes += u }
    }

    struct Reader {
        let bytes: [UInt8]
        var pos = 0
        init(_ b: [UInt8]) { bytes = b }
        mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard n >= 0, pos + n <= bytes.count else { throw XipperError.corrupt("decoder helper: malformed reply") }
            defer { pos += n }
            return bytes[pos..<pos + n]
        }
        mutating func u8() throws -> UInt8 { try take(1).first! }
        mutating func int<T: FixedWidthInteger>(_: T.Type) throws -> T {
            try take(MemoryLayout<T>.size).reversed().reduce(T(0)) { $0 << 8 | T($1) }
        }
        mutating func u16() throws -> UInt16 { try int(UInt16.self) }
        mutating func u32() throws -> UInt32 { try int(UInt32.self) }
        mutating func i64() throws -> Int64 { try int(Int64.self) }
        mutating func f64() throws -> Double { Double(bitPattern: UInt64(bitPattern: try i64())) }
        mutating func str() throws -> String {
            let n = Int(try u32())
            guard n <= 1 << 20 else { throw XipperError.corrupt("decoder helper: malformed reply") }
            return String(decoding: try take(n), as: UTF8.self)
        }
    }

    static func encode(_ e: TarReader.Entry) -> [UInt8] {
        var w = Writer()
        w.str(e.header.path); w.u8(e.header.type); w.i64(e.header.size); w.u16(e.header.mode)
        w.f64(e.header.mtime.timeIntervalSince1970); w.str(e.header.linkTarget)
        w.u32(UInt32(e.header.xattrs.count))
        for x in e.header.xattrs { w.str(x.name); w.u32(UInt32(x.value.count)); w.bytes += x.value }
        let a = e.entry
        w.u8([.file: 0, .directory: 1, .symlink: 2, .hardlink: 3][a.kind]!)
        w.i64(a.compressedSize)
        w.u8(a.modified == nil ? 0 : 1); w.f64(a.modified?.timeIntervalSince1970 ?? 0)
        w.u8(a.permissions == nil ? 0 : 1); w.u16(a.permissions ?? 0)
        switch a.encryption {
        case .none: w.u8(0)
        case .zipCrypto: w.u8(1)
        case let .aes(s, v, m): w.u8(2); w.u8(s); w.u16(v); w.u16(m)
        }
        w.str(a.method)
        w.u8(a.linkTarget == nil ? 0 : 1); w.str(a.linkTarget ?? "")
        return w.bytes
    }

    static func decodeEntry(_ b: [UInt8]) throws -> TarReader.Entry {
        var r = Reader(b)
        var h = Tar.Header(path: try r.str(), type: try r.u8(), size: try r.i64(), mode: try r.u16(), uid: 0, gid: 0,
                           mtime: Date(timeIntervalSince1970: try r.f64()), linkTarget: try r.str())
        for _ in 0..<min(try r.u32(), 4096) {
            let name = try r.str()
            h.xattrs.append((name, Array(try r.take(Int(try r.u32())))))
        }
        let kinds: [ArchiveEntry.Kind] = [.file, .directory, .symlink, .hardlink]
        let k = Int(try r.u8())
        guard k < kinds.count else { throw XipperError.corrupt("decoder helper: malformed reply") }
        let compressed = try r.i64()
        let hasDate = try r.u8(), date = try r.f64()
        let hasPerm = try r.u8(), perm = try r.u16()
        let encryption: EntryEncryption
        switch try r.u8() {
        case 0: encryption = .none
        case 1: encryption = .zipCrypto
        default: encryption = .aes(strength: try r.u8(), vendorVersion: try r.u16(), actualMethod: try r.u16())
        }
        let method = try r.str()
        let hasLink = try r.u8(), link = try r.str()
        let entry = ArchiveEntry(path: h.path, kind: kinds[k], uncompressedSize: kinds[k] == .file ? h.size : 0, compressedSize: compressed,
                                 modified: hasDate == 1 ? Date(timeIntervalSince1970: date) : nil, permissions: hasPerm == 1 ? perm : nil,
                                 encryption: encryption, method: method, linkTarget: hasLink == 1 ? link : nil)
        return TarReader.Entry(header: h, entry: entry)
    }

    static func encode(_ error: Error) -> [UInt8] {
        var w = Writer()
        if error is SZNeedsPassword { w.u8(11); return w.bytes }
        switch error as? XipperError {
        case let .corrupt(m)?: w.u8(1); w.str(m)
        case let .unsupported(m)?: w.u8(2); w.str(m)
        case let .passwordRequired(e)?: w.u8(3); w.str(e)
        case let .wrongPassword(e)?: w.u8(4); w.str(e)
        case let .integrity(e, d)?: w.u8(5); w.str(e); w.str(d)
        case let .checksumMismatch(e, x, a)?: w.u8(6); w.str(e); w.u32(x); w.u32(a)
        case let .truncated(e, r, x)?: w.u8(7); w.str(e); w.i64(r); w.i64(x)
        case let .limitExceeded(m)?: w.u8(8); w.str(m)
        case let .codec(m)?: w.u8(9); w.str(m)
        case let .io(op, path, err)?: w.u8(10); w.str(op); w.str(path ?? ""); w.u32(UInt32(bitPattern: err))
        case let e?: w.u8(1); w.str(e.description)
        case nil: w.u8(1); w.str(String(describing: error))
        }
        return w.bytes
    }

    static func decodeError(_ b: [UInt8]) throws -> XipperError {
        var r = Reader(b)
        switch try r.u8() {
        case 2: return .unsupported(try r.str())
        case 3: return .passwordRequired(entry: try r.str())
        case 4: return .wrongPassword(entry: try r.str())
        case 5: return .integrity(entry: try r.str(), detail: try r.str())
        case 6: return .checksumMismatch(entry: try r.str(), expected: try r.u32(), actual: try r.u32())
        case 7: return .truncated(entry: try r.str(), read: try r.i64(), expected: try r.i64())
        case 8: return .limitExceeded(try r.str())
        case 9: return .codec(try r.str())
        case 10:
            let op = try r.str(), path = try r.str()
            return .io(op, path: path.isEmpty ? nil : path, errno: Int32(bitPattern: try r.u32()))
        default: return .corrupt(try r.str())
        }
    }

    static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
        var off = 0
        while off < bytes.count {
            let n = write(fd, bytes.baseAddress! + off, bytes.count - off)
            if n < 0 { if errno == EINTR { continue }; return false }
            off += n
        }
        return true
    }

    static func frame(_ fd: Int32, _ type: UInt8, _ payload: UnsafeRawBufferPointer) -> Bool {
        var head = [type, 0, 0, 0, 0]
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { for i in 0..<4 { head[1 + i] = $0[i] } }
        return head.withUnsafeBytes { writeAll(fd, $0) } && (payload.isEmpty || writeAll(fd, payload))
    }

    static func frame(_ fd: Int32, _ type: UInt8, _ payload: [UInt8] = []) -> Bool {
        payload.withUnsafeBytes { frame(fd, type, $0) }
    }

    /// Reads exactly `count` bytes; false at end of stream.
    static func readAll(_ fd: Int32, _ p: UnsafeMutableRawPointer, _ count: Int) -> Bool {
        var off = 0
        while off < count {
            let n = read(fd, p + off, count - off)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            off += n
        }
        return true
    }

    /// One frame's header: (type, length), or nil at end of stream.
    static func readHeader(_ fd: Int32) -> (UInt8, Int)? {
        var h = [UInt8](repeating: 0, count: 5)
        guard h.withUnsafeMutableBytes({ readAll(fd, $0.baseAddress!, 5) }) else { return nil }
        return (h[0], Int(UInt32(h[1]) | UInt32(h[2]) << 8 | UInt32(h[3]) << 16 | UInt32(h[4]) << 24))
    }
}

/// One running helper and its two pipes; killed when released.
final class DecoderProcess: @unchecked Sendable {
    let pid: pid_t
    let toHelper: Int32
    let fromHelper: Int32
    /// The archive's name, for errors.
    let name: String

    init(helper: String, volumes: [String], name: String) throws {
        self.name = name
        // Volumes become descriptors 3, 4, …; nothing else of this process reaches the helper. Every
        // descriptor handed over is first moved above those numbers, so no dup2 overwrites another.
        let base = Int32(3 + volumes.count)
        func high(_ fd: Int32) -> Int32 {
            let h = fcntl(fd, F_DUPFD_CLOEXEC, base)
            close(fd)
            return h
        }
        var fds: [Int32] = []
        defer { fds.forEach { close($0) } }
        for v in volumes {
            let fd = open(v, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { throw XipperError.posix("open", v) }
            let h = high(fd)
            guard h >= 0 else { throw XipperError.posix("fcntl", v) }
            fds.append(h)
        }
        var req: [Int32] = [0, 0], rep: [Int32] = [0, 0]
        guard pipe(&req) == 0 else { throw XipperError.posix("pipe") }
        req = req.map(high)
        guard pipe(&rep) == 0 else { req.forEach { close($0) }; throw XipperError.posix("pipe") }
        rep = rep.map(high)
        guard !(req + rep).contains(where: { $0 < 0 }) else { (req + rep).forEach { close($0) }; throw XipperError.posix("fcntl") }
        defer { close(req[0]); close(rep[1]) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, req[0], 0)
        posix_spawn_file_actions_adddup2(&actions, rep[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        for (i, fd) in fds.enumerated() { posix_spawn_file_actions_adddup2(&actions, fd, Int32(3 + i)) }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))  // only the descriptors above
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(helper), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = [strdup("LC_ALL=en_US.UTF-8"), nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        let r = posix_spawn(&pid, helper, &actions, &attr, argv, envp)
        guard r == 0 else {
            close(req[1]); close(rep[0])
            throw XipperError.io("posix_spawn", path: helper, errno: r)
        }
        self.pid = pid
        toHelper = req[1]
        fromHelper = rep[0]
        _ = fcntl(toHelper, F_SETNOSIGPIPE, 1)  // a dead helper is an error, not a SIGPIPE here
    }

    deinit {
        close(toHelper)
        close(fromHelper)
        kill(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    }

    func send(_ op: IsolatedDecoder.Op, _ payload: [UInt8] = []) throws {
        guard IsolatedDecoder.frame(toHelper, op.rawValue, payload) else { throw died() }
    }

    func header() throws -> (UInt8, Int) {
        guard let h = IsolatedDecoder.readHeader(fromHelper) else { throw died() }
        return h
    }

    func read(into p: UnsafeMutableRawPointer, _ n: Int) throws {
        guard IsolatedDecoder.readAll(fromHelper, p, n) else { throw died() }
    }

    func payload(_ n: Int) throws -> [UInt8] {
        guard n <= 16 << 20 else { throw XipperError.corrupt("decoder helper: malformed reply") }
        var b = [UInt8](repeating: 0, count: n)
        if n > 0 { try b.withUnsafeMutableBytes { try read(into: $0.baseAddress!, n) } }
        return b
    }

    func receive() throws -> (UInt8, [UInt8]) {
        let (type, n) = try header()
        return (type, try payload(n))
    }

    /// The helper's stream ended: it crashed (a decoder bug the archive triggered) or was killed.
    func died() -> XipperError {
        var status: Int32 = 0
        var r: pid_t
        repeat { r = waitpid(pid, &status, WNOHANG) } while r < 0 && errno == EINTR
        if r == 0 { usleep(50_000); r = waitpid(pid, &status, WNOHANG) }
        let signal = status & 0x7F
        let how = r == pid && signal != 0 ? "crashed (signal \(signal))" : "stopped"
        return .corrupt("\(name): the isolated decoder \(how) reading this archive; it is damaged or crafted to exploit a decoder bug")
    }
}

/// App side: an entry stream read from the helper. One helper process per reader; it ends with the reader.
final class IsolatedEntryReader: EntryStreamReader {
    private let process: DecoderProcess
    /// Set once the conversation is out of step (an error, a cancellation mid-entry): every later call fails.
    private var broken: XipperError?
    private var pendingData = false
    private static let maxChunk = 4 << 20

    init(helper: String, volumes: [String], name: String, password: String?) throws {
        process = try DecoderProcess(helper: helper, volumes: volumes, name: name)
        var w = IsolatedDecoder.Writer()
        w.str(name); w.u32(UInt32(volumes.count))
        w.u8(password == nil ? 0 : 1); w.str(password ?? "")
        try send(.open, w.bytes)
        let (type, payload) = try receive()
        guard type == IsolatedDecoder.Reply.opened.rawValue else { throw try unexpected(type, payload) }
    }

    /// For tests: makes the helper crash as a decoder bug would.
    func crashHelper() throws { try send(.crash) }

    func next() throws -> TarReader.Entry? {
        // Data not asked for was never sent: the helper's reader skips it, as libarchive does in process.
        pendingData = false
        try send(.next)
        let (type, payload) = try receive()
        switch type {
        case IsolatedDecoder.Reply.entry.rawValue:
            let e = try IsolatedDecoder.decodeEntry(payload)
            pendingData = e.entry.kind == .file
            return e
        case IsolatedDecoder.Reply.end.rawValue: return nil
        default: throw try unexpected(type, payload)
        }
    }

    func readData(cancel: CancellationToken?, _ sink: ByteSink) throws {
        guard pendingData else { return }
        pendingData = false
        try send(.data)
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Self.maxChunk, alignment: 16384)
        defer { buf.deallocate() }
        while true {
            let (type, n) = try checked { try process.header() }
            switch type {
            case IsolatedDecoder.Reply.chunk.rawValue:
                guard n <= Self.maxChunk else { throw fail(.corrupt("decoder helper: malformed reply")) }
                try checked { try process.read(into: buf, n) }
                do {
                    try cancel?.check()
                    try sink(UnsafeRawBufferPointer(start: buf, count: n))
                } catch {
                    // The helper is still sending this entry: the conversation cannot go on.
                    broken = broken ?? .cancelled
                    throw error
                }
            case IsolatedDecoder.Reply.dataEnd.rawValue:
                guard n == 0 else { throw fail(.corrupt("decoder helper: malformed reply")) }
                return
            default:
                throw try unexpected(type, try checked { try process.payload(n) })
            }
        }
    }

    /// Runs one exchange with the helper; any failure ends the conversation.
    private func checked<T>(_ body: () throws -> T) throws -> T {
        if let broken { throw broken }
        do { return try body() } catch let e as XipperError { throw fail(e) }
    }

    private func send(_ op: IsolatedDecoder.Op, _ payload: [UInt8] = []) throws {
        try checked { try process.send(op, payload) }
    }

    private func receive() throws -> (UInt8, [UInt8]) {
        try checked { try process.receive() }
    }

    /// An error reply ends the conversation (the helper stops after it); anything else is out of step.
    private func unexpected(_ type: UInt8, _ payload: [UInt8]) throws -> XipperError {
        if type == IsolatedDecoder.Reply.error.rawValue { return fail(try IsolatedDecoder.decodeError(payload)) }
        return fail(.corrupt("decoder helper: unexpected reply"))
    }

    private func fail(_ e: XipperError) -> XipperError {
        broken = broken ?? e
        return e
    }
}

/// Helper side: the loop of `xipper-decoder`. Runs in the sandbox, reads only descriptors 3, 4, ….
public enum DecoderService {
    public static func serve() -> Never {
        signal(SIGPIPE, SIG_IGN)
        exit(run(input: 0, output: 1))
    }

    static func run(input: Int32, output: Int32) -> Int32 {
        guard let (op, n) = IsolatedDecoder.readHeader(input), n <= 1 << 20 else { return 2 }
        var b = [UInt8](repeating: 0, count: n)
        guard n == 0 || b.withUnsafeMutableBytes({ IsolatedDecoder.readAll(input, $0.baseAddress!, n) }) else { return 2 }
        if op == IsolatedDecoder.Op.sevenZip.rawValue { return SevenZipDecoderPool.serve(b, input: input, output: output) }
        if op == IsolatedDecoder.Op.jpeg.rawValue { return JPEGCoderPool.serve(input: input, output: output) }
        guard op == IsolatedDecoder.Op.open.rawValue else { return 2 }
        let reader: EntryStreamReader
        do {
            var r = IsolatedDecoder.Reader(b)
            let name = try r.str()
            let count = Int(try r.u32())
            let hasPassword = try r.u8() == 1
            let password = try r.str()
            guard (1...4096).contains(count) else { throw XipperError.invalidArgument("volumes") }
            reader = try RarReader(path: "/dev/fd/3", password: hasPassword ? password : nil,
                                   volumes: (0..<count).map { "/dev/fd/\(3 + $0)" }, displayName: name)
        } catch {
            _ = IsolatedDecoder.frame(output, IsolatedDecoder.Reply.error.rawValue, IsolatedDecoder.encode(error))
            return 1
        }
        guard IsolatedDecoder.frame(output, IsolatedDecoder.Reply.opened.rawValue) else { return 1 }
        var skip = [UInt8](repeating: 0, count: 64)
        while let (op, n) = IsolatedDecoder.readHeader(input) {
            if n > 0 {  // requests carry no payload after open
                if n > skip.count { return 2 }
                guard skip.withUnsafeMutableBytes({ IsolatedDecoder.readAll(input, $0.baseAddress!, n) }) else { return 2 }
            }
            do {
                switch IsolatedDecoder.Op(rawValue: op) {
                case .next?:
                    if let e = try reader.next() {
                        guard IsolatedDecoder.frame(output, IsolatedDecoder.Reply.entry.rawValue, IsolatedDecoder.encode(e)) else { return 1 }
                    } else {
                        guard IsolatedDecoder.frame(output, IsolatedDecoder.Reply.end.rawValue) else { return 1 }
                    }
                case .data?:
                    try reader.readData(cancel: nil) { chunk in
                        guard IsolatedDecoder.frame(output, IsolatedDecoder.Reply.chunk.rawValue, chunk) else { throw XipperError.cancelled }
                    }
                    guard IsolatedDecoder.frame(output, IsolatedDecoder.Reply.dataEnd.rawValue) else { return 1 }
                case .crash?:
                    abort()
                default:
                    return 2
                }
            } catch {
                _ = IsolatedDecoder.frame(output, IsolatedDecoder.Reply.error.rawValue, IsolatedDecoder.encode(error))
                return 1
            }
        }
        return 0
    }
}
