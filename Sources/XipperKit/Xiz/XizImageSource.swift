import Darwin
import Foundation

extension XizForensic {
    /// What to do when the source does not read: how many times to try and how small a piece to give up on.
    public struct ReadErrors: Sendable, Hashable {
        /// Reads of the same piece before it is declared unreadable (at least 1).
        public var attempts: Int
        /// The smallest piece declared unreadable; 0 means one logical sector.
        public var granularity: UInt32
        public var name: String

        public init(name: String, attempts: Int, granularity: UInt32) {
            self.name = name; self.attempts = max(1, attempts); self.granularity = granularity
        }

        /// One read, 64 KiB lost per error: for a source that is dying, to save what reads well first.
        public static let fast = ReadErrors(name: "fast", attempts: 1, granularity: 64 << 10)
        /// Down to the sector, two reads each.
        public static let standard = ReadErrors(name: "standard", attempts: 2, granularity: 0)
        /// Down to the sector, eight reads each: slow on a damaged disk, recovers the most.
        public static let exhaustive = ReadErrors(name: "exhaustive", attempts: 8, granularity: 0)

        public static func named(_ s: String) -> ReadErrors? {
            [fast, standard, exhaustive].first { $0.name == s }
        }
    }

    /// The source of an image: a file, or a raw disk (`/dev/rdiskN`, `/dev/rdiskNsM`) opened read-only,
    /// possibly by the privileged helper that hands over its descriptor. Reads that fail are retried and
    /// narrowed down to the unreadable pieces, which come back as ranges (zeros in the image).
    public final class ImageSource: @unchecked Sendable {
        public let name: String
        public let size: UInt64
        public let logicalSector: UInt32
        public let physicalSector: UInt32
        /// A character or block device rather than a file.
        public let isDevice: Bool
        let fd: Int32
        /// Tests only: an error for a read of (offset, length), or nil to read for real.
        var fault: (@Sendable (UInt64, Int) -> Int32?)?
        /// A source that is not a descriptor (an E01 being imported): reads into the buffer, nil or an errno.
        let reader: (@Sendable (UInt64, UnsafeMutableRawPointer, Int) -> Int32?)?

        /// A source read by `read` (offset, buffer, count → nil or an errno), e.g. the image inside an E01.
        public init(name: String, size: UInt64, logicalSector: UInt32 = 512, physicalSector: UInt32 = 512,
                    read: @escaping @Sendable (UInt64, UnsafeMutableRawPointer, Int) -> Int32?) {
            self.name = name; self.size = size; self.logicalSector = logicalSector; self.physicalSector = physicalSector
            isDevice = false; fd = -1; reader = read
        }

        /// Opens `path` read-only.
        public convenience init(path: String) throws {
            let fd = open(path, O_RDONLY | O_CLOEXEC)
            if fd < 0 { throw XipperError.posix("open", path) }
            try self.init(fd: fd, name: path)
        }

        /// Takes ownership of `fd` (closed when the source is released). The descriptor must not be writable.
        public init(fd: Int32, name: String) throws {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, flags & O_ACCMODE == O_RDONLY else {
                close(fd)
                throw XipperError.invalidArgument("\(name): the source must be opened read-only")
            }
            var st = stat()
            guard fstat(fd, &st) == 0 else { let e = XipperError.posix("fstat", name); close(fd); throw e }
            self.fd = fd
            self.name = name
            reader = nil
            let kind = st.st_mode & S_IFMT
            isDevice = kind == S_IFCHR || kind == S_IFBLK
            if isDevice {
                var count: UInt64 = 0, block: UInt32 = 0, physical: UInt32 = 0
                let ok = withUnsafeMutablePointer(to: &count) { ioctl(fd, DKIOCGETBLOCKCOUNT_, $0) } == 0
                    && withUnsafeMutablePointer(to: &block) { ioctl(fd, DKIOCGETBLOCKSIZE_, $0) } == 0
                guard ok, block > 0 else { let e = XipperError.posix("ioctl", name); close(fd); throw e }
                if withUnsafeMutablePointer(to: &physical, { ioctl(fd, DKIOCGETPHYSICALBLOCKSIZE_, $0) }) != 0 || physical == 0 { physical = block }
                size = count * UInt64(block)
                logicalSector = block
                physicalSector = physical
            } else {
                size = UInt64(st.st_size)
                logicalSector = 512
                physicalSector = 512
            }
        }

        deinit { if fd >= 0 { close(fd) } }

        /// Errors that mean the source has gone (cable pulled, disk ejected): stop, do not map them as sectors.
        static let gone: Set<Int32> = [ENXIO, ENODEV, EBADF, ENOENT]

        /// One plain read of the whole piece; the errno on failure (EIO for a short read inside the source).
        func readOnce(at offset: UInt64, into dst: UnsafeMutableRawPointer, count: Int) -> Int32? {
            if let f = fault, let e = f(offset, count) { return e }
            if let reader { return reader(offset, dst, count) }
            var done = 0
            while done < count {
                let n = pread(fd, dst + done, count - done, off_t(offset) + off_t(done))
                if n > 0 { done += n; continue }
                if n == 0 { return EIO }
                if errno == EINTR { continue }
                return errno
            }
            return nil
        }

        /// Reads `count` bytes at `offset` into `dst`. Pieces that still fail after the retries are zeroed
        /// and returned as ranges, in order; a source that has gone throws.
        func read(at offset: UInt64, into dst: UnsafeMutableRawPointer, count: Int, policy: ReadErrors) throws -> [Unreadable.Range] {
            guard let first = readOnce(at: offset, into: dst, count: count) else { return [] }
            if Self.gone.contains(first) { throw XipperError.io("read", path: name, errno: first) }
            let unit = max(UInt64(logicalSector), UInt64(policy.granularity == 0 ? logicalSector : policy.granularity))
            var out: [Unreadable.Range] = []

            /// `failed`: the error of a read of this very piece that already failed, if any.
            func fill(_ off: UInt64, _ len: UInt64, failed: Int32?) throws {
                let p = dst + Int(off - offset)
                if len <= unit {
                    var last = failed ?? EIO
                    for _ in 0..<(policy.attempts - (failed == nil ? 0 : 1)) {
                        guard let e = readOnce(at: off, into: p, count: Int(len)) else { return }
                        if Self.gone.contains(e) { throw XipperError.io("read", path: name, errno: e) }
                        last = e
                    }
                    memset(p, 0, Int(len))
                    if let l = out.last, l.offset + l.length == off, l.error == last {
                        out[out.count - 1].length += len
                    } else {
                        out.append(Unreadable.Range(offset: off, length: len, error: last, attempts: UInt16(policy.attempts)))
                    }
                    return
                }
                if failed == nil {
                    guard let e = readOnce(at: off, into: p, count: Int(len)) else { return }
                    if Self.gone.contains(e) { throw XipperError.io("read", path: name, errno: e) }
                }
                // 64 KiB pieces first, so one bad sector does not cost a sector-by-sector pass over a whole block.
                let step = len > 64 << 10 && unit < 64 << 10 ? UInt64(64 << 10) : unit
                var o = off
                while o < off + len {
                    let n = min(step, off + len - o)
                    try fill(o, n, failed: nil)
                    o += n
                }
            }
            try fill(offset, UInt64(count), failed: first)
            return out
        }
    }
}

// <sys/disk.h> request codes (the macros do not reach Swift).
let DKIOCGETBLOCKSIZE_: UInt = 0x4004_6418
let DKIOCGETBLOCKCOUNT_: UInt = 0x4008_6419
let DKIOCGETPHYSICALBLOCKSIZE_: UInt = 0x4004_644D
