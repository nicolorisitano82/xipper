import Foundation

/// Disc and disk images, read only (3.4). Two paths, by what the image holds:
/// - **ISO 9660** (Joliet, Rock Ridge, zisofs) without UDF: libarchive's ISO 9660 reader, in the
///   isolated decoder like RAR (`RarReader`, `IsolatedDecoder.rar`);
/// - **UDF** discs and **Apple disk images** (`.dmg`, `.sparseimage`: HFS+, APFS, FAT…): libarchive
///   has no reader for them, so `MountedImageReader` attaches the image with `hdiutil` read only and
///   hidden (`-nobrowse`, never opened in the Finder), walks it like a folder and detaches it. The
///   file system is then parsed by macOS, as when the image is double-clicked.
public enum DiskImage {
    public enum Kind: Sendable, Equatable {
        /// ISO 9660 only: libarchive.
        case iso9660
        /// A disc with UDF (alone or with an ISO 9660 bridge, as Windows and DVD images): hdiutil.
        case udf
        /// An Apple disk image (UDIF `.dmg`, `.sparseimage`), `encrypted` when it has a password.
        case appleImage(encrypted: Bool)
    }

    static let sector = 2048

    /// What `path` is, from its content; nil when it is not a disc or disk image.
    public static func kind(_ path: String) -> Kind? {
        guard let r = try? FileReader(path: path) else { return nil }
        return kind(r)
    }

    static func kind(_ r: FileReader) -> Kind? {
        let size = r.size
        if size >= 8, let head = try? r.read(at: 0, count: 8) {
            if head == Array("encrcdsa".utf8) { return .appleImage(encrypted: true) }  // encrypted, v2
            if head.starts(with: Array("sprs".utf8)) { return .appleImage(encrypted: false) }  // sparse image
        }
        if size >= 512, let tail = try? r.read(at: size - 512, count: 512) {
            if tail.starts(with: Array("koly".utf8)) { return .appleImage(encrypted: false) }  // UDIF trailer
        }
        if size >= 8, let end = try? r.read(at: size - 8, count: 8), end == Array("cdsaencr".utf8) {
            return .appleImage(encrypted: true)  // encrypted, v1
        }
        // Volume recognition sequence from sector 16 (ECMA-119, ECMA-167): "CD001", "BEA01", "NSR0x".
        // Checked before the partition maps: hybrid Linux ISOs also carry an MBR and a GPT.
        if size >= Int64(17 * sector) {
            var iso = false, udf = false
            for s in 16..<min(64, Int(size / Int64(sector))) {
                guard let d = try? r.read(at: Int64(s * sector), count: 6) else { break }
                let id = String(decoding: d[1..<6], as: UTF8.self)
                if id == "CD001" { iso = true } else if id == "NSR02" || id == "NSR03" { udf = true }
                else if id == "BEA01" || id == "TEA01" || id == "BOOT2" || id == "CDW02" { continue }
                else { break }
            }
            if udf { return .udf }
            if iso { return .iso9660 }
        }
        // Raw disk images (`.cdr`, "DVD/CD master"): a GPT or Apple partition map, or a bare HFS+ or APFS volume.
        if size >= 2048, let h = try? r.read(at: 0, count: 2048) {
            if Array(h[512..<520]) == Array("EFI PART".utf8) { return .appleImage(encrypted: false) }
            if h[0] == 0x45, h[1] == 0x52, h[512] == 0x50, h[513] == 0x4D { return .appleImage(encrypted: false) }  // "ER", "PM"
            if (h[1024] == 0x48 && (h[1025] == 0x2B || h[1025] == 0x58)) || Array(h[32..<36]) == Array("NXSB".utf8) {
                return .appleImage(encrypted: false)  // "H+", "HX", APFS container
            }
        }
        return nil
    }

    static func isISO9660(_ path: String) -> Bool { kind(path) == .iso9660 }
}

/// An image attached with `hdiutil`, read only and hidden, presented as an archive: entries are
/// the files of every mounted volume (the volume name in front when there are several).
final class MountedImageReader: EntryStreamReader {
    private let name: String
    private var devices: [String] = []
    private let mountRoot: URL
    private var entries: [(TarReader.Entry, URL?)] = []
    private var index = -1

    /// File system bookkeeping at the root of a volume: never shown as content.
    static let hiddenRootNames: Set<String> = [".Trashes", ".fseventsd", ".Spotlight-V100", ".DocumentRevisions-V100",
                                                ".TemporaryItems", ".HFS+ Private Directory Data\r", ".journal",
                                                ".journal_info_block", ".PKInstallSandboxManager", "$RECYCLE.BIN",
                                                "System Volume Information"]

    init(path: String, password: String?) throws {
        name = (path as NSString).lastPathComponent
        mountRoot = FileManager.default.temporaryDirectory.appendingPathComponent("xipper-image-\(UUID().uuidString)")
        if case .appleImage(true)? = DiskImage.kind(path), password == nil { throw XipperError.passwordRequired(entry: name) }
        try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
        do {
            try attach(path, password: password)
            try walk()
        } catch {
            detach()
            throw error
        }
    }

    deinit { detach() }

    private static let hdiutil = "/usr/bin/hdiutil"

    private func attach(_ path: String, password: String?) throws {
        var args = ["attach", "-readonly", "-nobrowse", "-noautoopen", "-noautofsck",
                    "-mountrandom", mountRoot.path, "-plist"]
        if password != nil { args.append("-stdinpass") }
        args.append(path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.hdiutil)
        p.arguments = args
        let out = Pipe(), err = Pipe(), input = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = input
        try p.run()
        if let password {
            // -stdinpass reads the password up to a NUL byte.
            input.fileHandleForWriting.write(Data(password.utf8) + [0])
        }
        try? input.fileHandleForWriting.close()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let plist = (try? PropertyListSerialization.propertyList(from: outData, format: nil)) as? [String: Any]
        for e in plist?["system-entities"] as? [[String: Any]] ?? [] {
            if let dev = e["dev-entry"] as? String { devices.append(dev) }
        }
        guard p.terminationStatus == 0 else {
            // hdiutil's messages follow the system language, and its exit status is 1 for every failure.
            let message = String(decoding: errData, as: UTF8.self).split(whereSeparator: \.isNewline)
                .filter { !$0.contains("deprecated") }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = message.lowercased()
            let authWords = ["authentication", "passphrase", "autenticazione", "authentifizierung", "authentification",
                             "autenticación", "認証", "认证"]
            if authWords.contains(where: { lower.contains($0) }) {
                throw password == nil ? XipperError.passwordRequired(entry: name) : XipperError.wrongPassword(entry: name)
            }
            throw XipperError.corrupt("\(name): the image cannot be attached (\(message.isEmpty ? "hdiutil \(p.terminationStatus)" : message))")
        }
    }

    /// Every volume mounted under `mountRoot`, walked without following symbolic links.
    private func walk() throws {
        let fm = FileManager.default
        let volumes = (try? fm.contentsOfDirectory(at: mountRoot, includingPropertiesForKeys: nil))?
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        guard !volumes.isEmpty else { throw XipperError.unsupported("\(name): the image has no volume macOS can read") }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        for volume in volumes {
            let prefix = volumes.count > 1 ? volume.lastPathComponent + "/" : ""
            if !prefix.isEmpty { add(path: String(prefix.dropLast()), url: nil, kind: .directory, size: 0, mtime: Date(), mode: 0o755, link: nil) }
            let base = volume.resolvingSymlinksInPath().path
            guard let it = fm.enumerator(at: volume, includingPropertiesForKeys: keys, options: []) else { continue }
            for case let url as URL in it {
                let full = url.path
                var rel = full.hasPrefix(volume.path + "/") ? String(full.dropFirst(volume.path.count + 1))
                    : full.hasPrefix(base + "/") ? String(full.dropFirst(base.count + 1)) : url.lastPathComponent
                if it.level == 1, Self.hiddenRootNames.contains(url.lastPathComponent) {
                    it.skipDescendants()
                    continue
                }
                rel = prefix + rel
                let v = try? url.resourceValues(forKeys: Set(keys))
                let attrs = try? fm.attributesOfItem(atPath: full)
                let mode = (attrs?[.posixPermissions] as? NSNumber).map { UInt16(truncatingIfNeeded: $0.intValue) & 0o7777 }
                let mtime = v?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
                if v?.isSymbolicLink == true {
                    // readlink(2), not FileManager: on some UDF volumes Foundation traps on the errno it gets.
                    var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                    let n = readlink(full, &buf, Int(PATH_MAX))
                    guard n > 0 else { continue }  // an unreadable link is left out, like other non-content
                    let target = String(decoding: buf[..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    add(path: rel, url: nil, kind: .symlink, size: 0, mtime: mtime, mode: mode ?? 0o755, link: target)
                } else if v?.isDirectory == true {
                    add(path: rel, url: nil, kind: .directory, size: 0, mtime: mtime, mode: mode ?? 0o755, link: nil)
                } else if v?.isRegularFile == true {
                    add(path: rel, url: url, kind: .file, size: Int64(v?.fileSize ?? 0), mtime: mtime, mode: mode ?? 0o644, link: nil)
                }
                // Devices, sockets and pipes on an image are not content: left out.
            }
        }
    }

    private func add(path: String, url: URL?, kind: ArchiveEntry.Kind, size: Int64, mtime: Date, mode: UInt16, link: String?) {
        let type: UInt8 = switch kind {
        case .directory: Tar.TypeFlag.directory.rawValue
        case .symlink: Tar.TypeFlag.symlink.rawValue
        default: Tar.TypeFlag.file.rawValue
        }
        let header = Tar.Header(path: path, type: type, size: size, mode: mode, uid: 0, gid: 0, mtime: mtime, linkTarget: link ?? "")
        let entry = ArchiveEntry(path: path, kind: kind, uncompressedSize: size, compressedSize: 0, modified: mtime, permissions: mode,
                                 encryption: .none, method: "image", linkTarget: link)
        entries.append((TarReader.Entry(header: header, entry: entry), url))
    }

    func next() throws -> TarReader.Entry? {
        index += 1
        return index < entries.count ? entries[index].0 : nil
    }

    func readData(cancel: CancellationToken?, _ sink: ByteSink) throws {
        guard index >= 0, index < entries.count, let url = entries[index].1 else { return }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw XipperError.io("cannot read \(entries[index].0.entry.path) in \(name)", path: url.path, errno: errno) }
        defer { close(fd) }
        let chunk = 1 << 20
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16384)
        defer { buf.deallocate() }
        while true {
            try cancel?.check()
            let n = read(fd, buf, chunk)
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                throw XipperError.io("read error in \(name)", path: url.path, errno: errno)
            }
            try sink(UnsafeRawBufferPointer(start: buf, count: n))
        }
    }

    /// Detaches what was attached (forced if a first try fails) and removes the empty mount folders
    /// with rmdir only: nothing is ever deleted inside a volume that is still attached.
    private func detach() {
        // The whole disk (/dev/diskN, the shortest entry) detaches every partition with it.
        for dev in devices.min(by: { $0.count < $1.count }).map({ [$0] }) ?? [] {
            for force in [false, true] {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: Self.hdiutil)
                p.arguments = ["detach", dev, "-quiet"] + (force ? ["-force"] : [])
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { break }
                p.waitUntilExit()
                if p.terminationStatus == 0 { break }
            }
        }
        devices = []
        for sub in (try? FileManager.default.contentsOfDirectory(atPath: mountRoot.path)) ?? [] {
            rmdir(mountRoot.appendingPathComponent(sub).path)
        }
        rmdir(mountRoot.path)
    }
}
