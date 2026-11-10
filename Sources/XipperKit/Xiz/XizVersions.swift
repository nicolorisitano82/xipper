import Darwin
import Foundation

/// One version of an XIZ archive: the archive as it was after its first write (version 1) or after
/// each change appended to it (§11). Version N is exactly the file's first `size` bytes, up to the
/// end of that segment's footer, so it can be read, extracted or mounted like any archive.
public struct XizVersion: Sendable, Equatable {
    public var number: Int
    /// The archive's size at this version.
    public var size: Int64
    public var entries: Int
    public var totalBytes: Int64
    /// From the segment's signature (1.3), when it is signed; nil otherwise.
    public var signer: String?
    public var date: Date?
    /// Differences from the previous version (files), when its catalog could be read.
    public var added: Int?
    public var removed: Int?
    public var changed: Int?
}

extension Xipper {
    /// Every version of an XIZ archive, oldest first. The counts come from the footers (no password
    /// needed); differences between versions need the password of encrypted archives, and stay nil
    /// without it. An archive never changed has one version.
    public static func xizVersions(_ archive: URL, password: String? = nil) throws -> [XizVersion] {
        let path = archive.standardizedFileURL.path
        let reader = try FileReader(path: path)
        let sb = try Xiz.Superblock.decode(try reader.read(at: 0, count: Xiz.superblockSize))
        let dataStart = Int64(Xiz.superblockSize) + Int64(sb.keysLength)
        var (at, footer) = try XizArchive.lastFooter(reader, dataStart: dataStart)
        var chain: [(end: Int64, footer: Xiz.Footer)] = [(at + Int64(Xiz.footerSize), footer)]
        while footer.previousFooter != 0 {
            let prev = Int64(bitPattern: footer.previousFooter)
            guard prev >= dataStart, prev < at, chain.count < 65535 else { throw XipperError.corrupt("XIZ segment chain") }
            footer = try Xiz.Footer.decode(try reader.read(at: prev, count: Xiz.footerSize))
            at = prev
            chain.append((prev + Int64(Xiz.footerSize), footer))
        }
        chain.reverse()
        let signatures = sb.required.contains(.directory) ? ((try? XizSignature.history(path)) ?? []) : []

        var versions: [XizVersion] = []
        var previous: [String: [UInt8]]?
        for (i, c) in chain.enumerated() {
            var v = XizVersion(number: i + 1, size: c.end, entries: Int(c.footer.entryCount), totalBytes: Int64(c.footer.totalBytes))
            if let s = signatures.first(where: { $0.segment == i }), s.signed {
                v.signer = s.label
                v.date = s.time
            }
            // Files by path → digest (size and time when there is no digest), to count changes.
            let current: [String: [UInt8]]? = try? {
                let a = try XizArchive(path: path, password: password, limit: c.end)
                var m: [String: [UInt8]] = [:]
                for e in a.catalog.entries where e.type == .file || e.type == .symlink {
                    m[e.path] = e.sha256 ?? Array("\(e.size)/\(e.mtimeSec)/\(e.link)".utf8)
                }
                return m
            }()
            if let current, let previous {
                v.added = current.keys.filter { previous[$0] == nil }.count
                v.removed = previous.keys.filter { current[$0] == nil }.count
                v.changed = current.filter { kv in previous[kv.key].map { $0 != kv.value } ?? false }.count
            }
            previous = current
            versions.append(v)
        }
        return versions
    }

    /// Writes version `number` of an XIZ archive to `destination` as an archive of its own: an APFS
    /// clone cut to that version's size (instant, no extra space), or a copy of those bytes on
    /// other file systems. Erased files (§13.7) stay erased in every version.
    public static func xizVersion(_ archive: URL, number: Int, to destination: URL) throws {
        let versions = try xizVersions(archive)
        guard number >= 1, number <= versions.count else {
            throw XipperError.invalidArgument("version \(number) does not exist (the archive has \(versions.count))")
        }
        let size = versions[number - 1].size
        let src = archive.standardizedFileURL.path, dst = destination.standardizedFileURL.path
        if clonefile(src, dst, 0) == 0 {
            guard truncate(dst, off_t(size)) == 0 else {
                let e = XipperError.posix("truncate", dst)
                unlink(dst)
                throw e
            }
            return
        }
        let reader = try FileReader(path: src)
        let fd = open(dst, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw XipperError.posix("open", dst) }
        defer { close(fd) }
        var at: Int64 = 0
        while at < size {
            let chunk = try reader.read(at: at, count: Int(min(Int64(8 << 20), size - at)))
            guard chunk.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == chunk.count else {
                let e = XipperError.posix("write", dst)
                unlink(dst)
                throw e
            }
            at += Int64(chunk.count)
        }
    }

    /// Runs `body` on version `number` of `archive`, written next to it (same volume, so an APFS
    /// clone) in a temporary folder removed afterwards.
    public static func withXizVersion<T>(_ archive: URL, number: Int, _ body: (URL) throws -> T) throws -> T {
        let dir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                              appropriateFor: archive.standardizedFileURL, create: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = archive.deletingPathExtension().lastPathComponent
        let copy = dir.appendingPathComponent("\(base) (versione \(number)).\(archive.pathExtension)")
        try xizVersion(archive, number: number, to: copy)
        return try body(copy)
    }
}
