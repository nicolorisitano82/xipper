import Foundation

/// How a ZIP split into volumes is laid out on disk.
public enum ZipVolumeStyle: Sendable {
    /// PKWARE / Info-ZIP split archive (APPNOTE 8.5, `zip -s`): `name.z01`, `name.z02`, …, `name.zip`
    /// last. Offsets are per volume and headers never straddle two volumes; read by 7-Zip,
    /// WinZip, WinRAR and Info-ZIP (`zip -s 0` joins it).
    case spanned
    /// Plain pieces `name.zip.001`, `.002`, … (as 7-Zip writes): joined with `cat` they are an
    /// ordinary ZIP.
    case numbered
}

/// The output of ZipWriter: one file, or volumes. Positions are global (the sum of the volumes
/// before); `place` turns one into the volume number and the offset in it that ZIP headers store.
final class ZipOutput {
    private let path: String
    private let volumeSize: Int64?
    private let style: ZipVolumeStyle
    private var files: [OutputFile] = []
    /// Global position of each volume's first byte.
    private var starts: [Int64] = []
    private(set) var position: Int64 = 0

    static let splitSignature: UInt32 = 0x0807_4B50
    /// APPNOTE 8.5.4: a split archive that ended up in one volume.
    static let singleSegmentMarker: UInt32 = 0x3030_4B50
    static let minimumVolume: Int64 = 64 << 10

    init(path: String, volumeSize: Int64?, style: ZipVolumeStyle) throws {
        if let v = volumeSize, v < Self.minimumVolume { throw XipperError.invalidArgument("ZIP volumes must be at least 64 KiB") }
        self.path = path
        self.volumeSize = volumeSize
        self.style = style
        try open()
        if volumeSize != nil && style == .spanned {
            var w = ByteWriter()
            w.u32(Self.splitSignature)
            try write(w.bytes)
        }
    }

    private var spanned: Bool { volumeSize != nil && style == .spanned }

    /// Volume `n` (0-based) of `count`.
    private func volumePath(_ n: Int, of count: Int) -> String {
        guard volumeSize != nil else { return path }
        switch style {
        case .numbered:
            return path + "." + String(format: "%03d", n + 1)
        case .spanned:
            if n == count - 1 { return path }
            let base = path.lowercased().hasSuffix(".zip") ? String(path.dropLast(4)) : path
            return base + ".z" + String(format: "%02d", n + 1)
        }
    }

    private func open() throws {
        if files.count >= 0xFFFE { throw XipperError.limitExceeded("too many ZIP volumes (choose a bigger volume size)") }
        // Provisional name: the last volume of a spanned set is renamed to `path` on commit.
        files.append(try OutputFile(path: volumePath(files.count, of: Int.max)))
        starts.append(position)
    }

    func write(_ bytes: [UInt8]) throws { try bytes.withUnsafeBytes { try write($0) } }

    func write(_ b: UnsafeRawBufferPointer) throws {
        var rest = b
        while !rest.isEmpty {
            var room = rest.count
            if let v = volumeSize {
                if files.last!.position == v { try open() }
                room = Int(min(Int64(rest.count), v - files.last!.position))
            }
            try files.last!.write(UnsafeRawBufferPointer(rebasing: rest[0..<room]))
            position += Int64(room)
            rest = UnsafeRawBufferPointer(rebasing: rest[room...])
        }
    }

    /// A header of `count` bytes follows: in a spanned archive it starts a new volume rather than
    /// being cut in two.
    func keepTogether(_ count: Int) throws {
        guard spanned, let v = volumeSize else { return }
        if files.last!.position + Int64(count) > v && files.last!.position > 0 { try open() }
    }

    /// Volume number and offset in it of global position `p` (for spanned archives; otherwise 0, p).
    func place(_ p: Int64) -> (disk: UInt32, offset: Int64) {
        guard spanned else { return (0, p) }
        var i = starts.count - 1
        while i > 0 && starts[i] > p { i -= 1 }
        return (UInt32(i), p - starts[i])
    }

    /// Number of the last volume (the one the end records go in).
    var lastDisk: UInt32 { spanned ? UInt32(files.count - 1) : 0 }

    /// Overwrites already-written bytes at global position `p` (they may cross into the next piece).
    func patch(at p: Int64, _ bytes: [UInt8]) throws {
        var done = 0
        while done < bytes.count {
            let g = p + Int64(done)
            var i = starts.count - 1
            while i > 0 && starts[i] > g { i -= 1 }
            let local = g - starts[i]
            let n = Int(min(Int64(bytes.count - done), files[i].position - local))
            try files[i].patch(at: local, Array(bytes[done..<(done + n)]))
            done += n
        }
    }

    func flush() throws { try files.last!.flush() }

    func commit(overwrite: Bool) throws {
        if spanned && files.count == 1 {
            var w = ByteWriter()
            w.u32(Self.singleSegmentMarker)
            try files[0].patch(at: 0, w.bytes)
        }
        let names = files.indices.map { volumePath($0, of: files.count) }
        for (f, name) in zip(files, names) { f.finalPath = name }
        if !overwrite, let taken = names.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            throw XipperError.alreadyExists(path: taken)
        }
        for f in files { try f.commit(overwrite: overwrite) }
        // Volumes left over from a bigger set that was replaced would be read as part of this one.
        if volumeSize != nil && overwrite {
            var n = files.count
            while true {
                let stale = style == .numbered ? volumePath(n, of: Int.max) : volumePath(n - 1, of: Int.max)
                if unlink(stale) != 0 { break }
                n += 1
            }
        }
    }
}
