import Darwin
import Foundation

/// Read-only file accessed with `pread`.
///
/// Inputs are deliberately not memory-mapped: a file truncated while we read it
/// would raise SIGBUS on a mapping, while `pread` just returns a short count.
final class FileReader: @unchecked Sendable {
    let fd: Int32
    let path: String
    let size: Int64

    init(path: String) throws {
        fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd < 0 { throw XipperError.posix("open", path) }
        var st = stat()
        if fstat(fd, &st) != 0 { let e = XipperError.posix("fstat", path); close(fd); throw e }
        self.path = path
        size = Int64(st.st_size)
    }

    deinit { close(fd) }

    /// Reads exactly `count` bytes at `offset` into `dst`, or throws (truncated file).
    func read(at offset: Int64, into dst: UnsafeMutableRawPointer, count: Int) throws {
        var done = 0
        while done < count {
            let n = pread(fd, dst + done, count - done, offset + Int64(done))
            if n < 0 {
                if errno == EINTR { continue }
                throw XipperError.posix("read", path)
            }
            if n == 0 { throw XipperError.corrupt("\(path): unexpected end of file") }
            done += n
        }
    }

    func read(at offset: Int64, count: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: count)
        try buf.withUnsafeMutableBytes { try read(at: offset, into: $0.baseAddress!, count: count) }
        return buf
    }

    /// Reads up to `count` bytes; returns the number read (0 at EOF).
    func readSome(at offset: Int64, into dst: UnsafeMutableRawPointer, count: Int) throws -> Int {
        while true {
            let n = pread(fd, dst, count, offset)
            if n >= 0 { return n }
            if errno != EINTR { throw XipperError.posix("read", path) }
        }
    }
}

/// Buffered output file written to a temporary name and renamed into place on `commit()`.
/// If the object is released without `commit()`, the temporary file is removed,
/// so an interrupted job never leaves a half-written archive behind.
final class OutputFile: @unchecked Sendable {
    let finalPath: String
    let tempPath: String
    private var fd: Int32
    private var buffer: UnsafeMutableRawPointer
    private let capacity = 8 << 20
    private var buffered = 0
    private(set) var position: Int64 = 0
    private var committed = false

    init(path: String) throws {
        finalPath = path
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        tempPath = (dir.isEmpty ? "." : dir) + "/.\(name).xiptmp-\(UInt32.random(in: 0...UInt32.max))"
        fd = open(tempPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        if fd < 0 { throw XipperError.posix("create", tempPath) }
        buffer = .allocate(byteCount: capacity, alignment: 16384)
    }

    deinit {
        buffer.deallocate()
        if fd >= 0 { close(fd) }
        if !committed { unlink(tempPath) }
    }

    func write(_ src: UnsafeRawBufferPointer) throws {
        guard let base = src.baseAddress, src.count > 0 else { return }
        if src.count >= capacity {
            try flush()
            try rawWrite(base, src.count)
        } else {
            if buffered + src.count > capacity { try flush() }
            (buffer + buffered).copyMemory(from: base, byteCount: src.count)
            buffered += src.count
        }
        position += Int64(src.count)
    }

    func write(_ bytes: [UInt8]) throws { try bytes.withUnsafeBytes { try write($0) } }

    /// Overwrites already-written bytes (header patching).
    func patch(at offset: Int64, _ bytes: [UInt8]) throws {
        try flush()
        try bytes.withUnsafeBytes { b in
            var done = 0
            while done < b.count {
                let n = pwrite(fd, b.baseAddress! + done, b.count - done, offset + Int64(done))
                if n < 0 { if errno == EINTR { continue }; throw XipperError.posix("write", tempPath) }
                done += n
            }
        }
    }

    func flush() throws {
        if buffered > 0 { try rawWrite(buffer, buffered); buffered = 0 }
    }

    /// Flushes, closes and atomically moves the file to its final path.
    func commit(overwrite: Bool) throws {
        try flush()
        if close(fd) != 0 { fd = -1; throw XipperError.posix("close", tempPath) }
        fd = -1
        let flags: UInt32 = overwrite ? 0 : UInt32(RENAME_EXCL)
        if renamex_np(tempPath, finalPath, flags) != 0 {
            if errno == EEXIST { throw XipperError.alreadyExists(path: finalPath) }
            throw XipperError.posix("rename", finalPath)
        }
        committed = true
    }

    private func rawWrite(_ p: UnsafeRawPointer, _ count: Int) throws {
        var done = 0
        while done < count {
            let n = Darwin.write(fd, p + done, count - done)
            if n < 0 { if errno == EINTR { continue }; throw XipperError.posix("write", tempPath) }
            done += n
        }
    }
}

/// Little-endian byte builder for archive headers.
struct ByteWriter {
    var bytes: [UInt8] = []
    init(capacity: Int = 64) { bytes.reserveCapacity(capacity) }
    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { bytes.append(UInt8(truncatingIfNeeded: v)); bytes.append(UInt8(truncatingIfNeeded: v >> 8)) }
    mutating func u32(_ v: UInt32) { for s in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: v >> UInt32(s))) } }
    mutating func u64(_ v: UInt64) { for s in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8(truncatingIfNeeded: v >> UInt64(s))) } }
    mutating func append(_ b: [UInt8]) { bytes.append(contentsOf: b) }
    mutating func append<S: Sequence>(contentsOf s: S) where S.Element == UInt8 { bytes.append(contentsOf: s) }
}

/// Bounds-checked little-endian reader; every overrun is reported as corruption.
struct ByteReader {
    let base: UnsafeRawBufferPointer
    var pos: Int

    init(_ base: UnsafeRawBufferPointer, at pos: Int = 0) {
        self.base = base
        self.pos = pos
    }

    var remaining: Int { base.count - pos }

    mutating func need(_ n: Int) throws {
        if n < 0 || pos + n > base.count { throw XipperError.corrupt("truncated header") }
    }
    mutating func u8() throws -> UInt8 { try need(1); defer { pos += 1 }; return base[pos] }
    mutating func u16() throws -> UInt16 {
        try need(2); defer { pos += 2 }
        return base.loadUnaligned(fromByteOffset: pos, as: UInt16.self).littleEndian
    }
    mutating func u32() throws -> UInt32 {
        try need(4); defer { pos += 4 }
        return base.loadUnaligned(fromByteOffset: pos, as: UInt32.self).littleEndian
    }
    mutating func u64() throws -> UInt64 {
        try need(8); defer { pos += 8 }
        return base.loadUnaligned(fromByteOffset: pos, as: UInt64.self).littleEndian
    }
    mutating func bytes(_ n: Int) throws -> UnsafeRawBufferPointer {
        try need(n); defer { pos += n }
        return UnsafeRawBufferPointer(rebasing: base[pos..<pos + n])
    }
    mutating func skip(_ n: Int) throws { try need(n); pos += n }
}
