import Darwin
import Foundation
import Synchronization

public enum OverwritePolicy: Sendable, Equatable {
    /// Stop with `alreadyExists`.
    case fail
    /// Leave the existing item, report the entry as skipped.
    case skip
    /// Replace existing files (never a directory with a file or vice versa).
    case replace
    /// Write "name 2.ext", "name 3.ext", … (Finder convention).
    case keepBoth
    /// Call `ExtractOptions.conflictHandler` for each existing file (extraction pauses meanwhile).
    case ask
}

/// A file being extracted whose name is already taken on disk.
public struct ExtractConflict: Sendable {
    /// Entry path inside the archive.
    public var entry: String
    /// The existing item on disk.
    public var existing: URL
    public var archiveSize: Int64?
    public var archiveModified: Date?
    public var diskSize: Int64
    public var diskModified: Date?
}

public enum ConflictDecision: Sendable, Equatable { case skip, replace, keepBoth }

public struct ConflictResolution: Sendable {
    public var decision: ConflictDecision
    /// Use the same decision for every later conflict of this extraction.
    public var applyToAll: Bool
    public init(_ decision: ConflictDecision, applyToAll: Bool = false) {
        self.decision = decision
        self.applyToAll = applyToAll
    }
}

/// Called on an extraction thread; may block (e.g. while a dialog is shown). Calls are serialized.
public typealias ConflictHandler = @Sendable (ExtractConflict) -> ConflictResolution

public enum SymlinkPolicy: Sendable, Equatable {
    /// Create links whose target stays inside the destination; skip the others (default).
    case insideDestinationOnly
    /// Create every link as stored (only for trusted archives).
    case allowAll
    /// Never create symlinks.
    case skipAll
}

public struct ExtractionLimits: Sendable {
    /// Maximum bytes written; 0 = free space on the destination volume minus 1 GiB.
    public var maxTotalBytes: Int64 = 0
    public var maxEntries: Int = 2_000_000
    /// Entries bigger than `ratioCheckThreshold` may expand at most this many times (zip-bomb guard).
    public var maxCompressionRatio: Double = 1000
    public var ratioCheckThreshold: Int64 = 64 << 20
    /// Extract until `maxTotalBytes` is reached, then stop (and discard what was written),
    /// instead of refusing up front when the declared size is larger. Used for "extract anyway".
    public var stopAtLimit = false
    /// Keep at least this fraction of the destination volume free (0 = only the 1 GiB margin).
    public var minFreeFraction: Double = 0
    public init() {}
}

public struct ExtractOptions: Sendable {
    public var password: String?
    public var overwrite: OverwritePolicy = .keepBoth
    public var symlinks: SymlinkPolicy = .insideDestinationOnly
    /// Restore stored permission bits (setuid/setgid/sticky are always dropped).
    public var preservePermissions = true
    /// Copy the archive's com.apple.quarantine attribute to everything extracted, so Gatekeeper
    /// still checks downloaded executables.
    public var propagateQuarantine = true
    public var limits = ExtractionLimits()
    /// Extract only these entry paths (directories include their content); nil = everything.
    public var selection: Set<String>?
    /// Put every file directly in the destination, dropping the archive's folders.
    public var flatten = false
    /// Required by `OverwritePolicy.ask`; without it `.ask` behaves like `.keepBoth`.
    public var conflictHandler: ConflictHandler?
    /// When replacing, move the existing file to the Trash instead of overwriting it.
    public var trashReplacedFiles = false
    /// Restore macOS extended attributes stored in the archive (Finder tags, resource forks…).
    public var restoreExtendedAttributes = true
    /// Merge AppleDouble files (`._name`, `__MACOSX/`) into the files they describe instead of
    /// extracting them, as Archive Utility does.
    public var mergeAppleDouble = true
    public var workload: Workload = .interactive
    public init() {}
}

/// An entry not extracted (blocked for safety, or already existing) or found damaged by a test.
public struct SkippedEntry: Sendable, Equatable {
    public var path: String
    /// English, technical: for the CLI, MCP and logs.
    public var reason: String
    /// The same cause in structured form, for localized UI.
    public var problem: Problem

    public init(path: String, reason: String, problem: Problem = .other) {
        self.path = path
        self.reason = reason
        self.problem = problem
    }

    public init(path: String, error: XipperError) {
        self.init(path: path, reason: error.description, problem: Problem(error))
    }

    public enum Problem: Sendable, Equatable {
        // Blocked during extraction (never extractable on request).
        case escapesDestination
        case invalidName
        case throughSymlink
        case symlinkOutside(target: String)
        case symlinksDisabled
        case specialFile
        case alreadyExists
        // Found by a test.
        case checksumMismatch(expected: UInt32, actual: UInt32)
        case truncated(read: Int64?, expected: Int64?)
        case authenticationFailed
        case missingEndMarker
        case wrongPassword
        case passwordRequired
        case unsupported
        case damaged
        case other

        /// True for entries blocked by the extraction guards (6.3).
        public var isSecurityBlock: Bool {
            switch self {
            case .escapesDestination, .invalidName, .throughSymlink, .symlinkOutside, .symlinksDisabled, .specialFile: true
            default: false
            }
        }

        init(_ e: XipperError) {
            switch e {
            case let .checksumMismatch(_, x, a): self = .checksumMismatch(expected: x, actual: a)
            case let .truncated(_, r, x): self = .truncated(read: r, expected: x)
            case let .integrity(_, d) where d.contains("AES"): self = .authenticationFailed
            case .integrity: self = .damaged
            case let .corrupt(m) where m.contains("end-of-file marker"): self = .missingEndMarker
            case let .corrupt(m) where m.contains("truncated"): self = .truncated(read: nil, expected: nil)
            case .corrupt: self = .damaged
            case .wrongPassword: self = .wrongPassword
            case .passwordRequired: self = .passwordRequired
            case .unsupported: self = .unsupported
            case let .unsafeEntry(_, r) where r.contains("symlink or a file"): self = .throughSymlink
            default: self = .other
            }
        }
    }
}

public struct ExtractReport: Sendable {
    /// Where the content ended up (the folder created for it, or the single top-level item).
    public var destination: URL
    public var files: Int
    public var directories: Int
    public var symlinks: Int
    public var bytes: Int64
    public var skipped: [SkippedEntry]
    public var elapsed: Double
}

/// Safe writer for extracted entries, shared by every archive format.
///
/// - every path is sanitized (no absolute paths, no `..`, no empty/oversized components);
/// - parent directories are opened component by component with `O_NOFOLLOW`, so no entry can
///   be written through a symlink, whether it came from the archive or was already on disk;
/// - symlinks and hard links are created only after all regular files;
/// - files are written to a temporary name and renamed into place;
/// - the total amount written is capped (zip bombs, full disks).
final class ExtractionContext: @unchecked Sendable {
    let rootPath: String
    let options: ExtractOptions
    private let rootFD: Int32
    private let quarantine: [UInt8]?
    /// Bytes that may still be written: an explicit limit, or free space minus 1 GiB.
    let maxBytes: Int64
    /// True when `maxBytes` comes from the free space rather than from a configured limit.
    let limitIsFreeSpace: Bool
    private let written = Atomic<Int64>(0)
    private let counts = Mutex<(files: Int, dirs: Int, links: Int)>((0, 0, 0))
    private let skippedList = Mutex<[SkippedEntry]>([])
    private let deferredLinks = Mutex<[(path: [String], target: String, hard: Bool, mtime: Date?)]>([])
    private let deferredDirs = Mutex<[String: (perm: UInt16?, mtime: Date?)]>([:])
    private let appleDoubles = Mutex<[(target: String, data: [UInt8])]>([])

    /// `__MACOSX` folders of Finder-made ZIPs: never created when AppleDouble files are merged.
    func isAppleDoubleFolder(_ path: String) -> Bool {
        options.mergeAppleDouble && (path == "__MACOSX" || path.hasPrefix("__MACOSX/"))
    }

    /// The file an AppleDouble entry describes ("a/._b" and "__MACOSX/a/._b" → "a/b"), or nil.
    func appleDoubleTarget(_ path: String, size: Int64) -> String? {
        guard options.mergeAppleDouble, size <= AppleDouble.maxSize else { return nil }
        var comps = path.split(separator: "/").map(String.init)
        if comps.first == "__MACOSX" { comps.removeFirst() }
        guard let last = comps.last, last.hasPrefix("._"), last.count > 2 else { return nil }
        comps[comps.count - 1] = String(last.dropFirst(2))
        return comps.joined(separator: "/")
    }

    func stashAppleDouble(target: String, data: [UInt8]) {
        appleDoubles.withLock { $0.append((target, data)) }
    }

    /// Applies the stashed AppleDouble attributes to the extracted files and folders.
    private func mergeAppleDoubles() {
        guard options.restoreExtendedAttributes else { return }
        for (target, data) in appleDoubles.withLock({ $0 }) {
            let attrs = AppleDouble.attributes(data)
            guard !attrs.isEmpty, let full = sanitize(target) else { continue }
            let comps = layout(full)
            guard let dirFD = try? openDirectory(comps.dropLast(), entry: target) else { continue }
            defer { close(dirFD) }
            let fd = openat(dirFD, comps.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }  // orphan "._" file: dropped, as Archive Utility does
            ExtendedAttributes.apply(attrs, fd: fd)
            close(fd)
        }
    }

    init(root: String, archivePath: String, options: ExtractOptions) throws {
        rootPath = root
        self.options = options
        rootFD = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if rootFD < 0 { throw XipperError.posix("open destination", root) }
        quarantine = options.propagateQuarantine ? Self.readXattr(archivePath, "com.apple.quarantine") : nil
        let space = Self.volumeSpace(root, fd: rootFD)
        var cap: Int64
        var fromFreeSpace = options.limits.maxTotalBytes <= 0
        if options.limits.maxTotalBytes > 0 {
            cap = options.limits.maxTotalBytes
        } else {
            cap = space.map { max(0, $0.free - (1 << 30)) } ?? .max
        }
        if options.limits.minFreeFraction > 0, let space {
            let room = max(0, space.free - Int64(Double(space.total) * options.limits.minFreeFraction))
            if room < cap { cap = room; fromFreeSpace = true }
        }
        limitIsFreeSpace = fromFreeSpace
        maxBytes = cap
    }

    /// Free and total bytes of the destination volume as the Finder counts them (purgeable space
    /// is free: macOS reclaims it when we write); statfs when the volume does not report them.
    static func volumeSpace(_ path: String, fd: Int32) -> (free: Int64, total: Int64)? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        if let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
           let free = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity, total > 0 {
            return (free, Int64(total))
        }
        var fs = statfs()
        guard fstatfs(fd, &fs) == 0 else { return nil }
        return (Int64(fs.f_bavail) * Int64(fs.f_bsize), Int64(fs.f_blocks) * Int64(fs.f_bsize))
    }

    deinit {
        closeCachedDirectories()
        close(rootFD)
    }

    var bytesWritten: Int64 { written.load(ordering: .relaxed) }
    var skipped: [SkippedEntry] { skippedList.withLock { $0 } }
    var stats: (files: Int, dirs: Int, links: Int) { counts.withLock { $0 } }

    func overLimit(needed: Int64) -> XipperError {
        limitIsFreeSpace ? .insufficientSpace(needed: needed, available: maxBytes)
                         : .limitExceeded("extraction would write more than \(maxBytes) bytes")
    }

    // MARK: conflicts

    private let askLock = NSLock()
    private let remembered = Mutex<ConflictDecision?>(nil)

    /// What to do with an entry whose name exists: from the policy, a remembered answer or the handler.
    private func decide(entry: String, dirFD: Int32, name: String, size: Int64?, modified: Date?) throws -> ConflictDecision {
        switch options.overwrite {
        case .fail: throw XipperError.alreadyExists(path: entry)
        case .skip: return .skip
        case .replace: return .replace
        case .keepBoth: return .keepBoth
        case .ask: break
        }
        if let r = remembered.withLock({ $0 }) { return r }
        guard let handler = options.conflictHandler else { return .keepBoth }
        askLock.lock()
        defer { askLock.unlock() }
        if let r = remembered.withLock({ $0 }) { return r }  // answered while we waited
        var st = stat()
        fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW)
        let conflict = ExtractConflict(
            entry: entry, existing: URL(fileURLWithPath: rootPath + "/" + entry), archiveSize: size, archiveModified: modified,
            diskSize: Int64(st.st_size),
            diskModified: Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9))
        let answer = handler(conflict)
        if answer.applyToAll { remembered.withLock { $0 = answer.decision } }
        return answer.decision
    }

    /// Lays out an entry: full path, or only its name when flattening.
    func layout(_ comps: [String]) -> [String] { options.flatten ? [comps.last!] : comps }

    func skip(_ path: String, _ reason: String, _ problem: SkippedEntry.Problem = .other) {
        skippedList.withLock { $0.append(SkippedEntry(path: path, reason: reason, problem: problem)) }
    }

    // MARK: path sanitizing

    /// Splits an archive path into safe components, or returns nil (and records why).
    func sanitize(_ raw: String, backslashIsSeparator: Bool = false) -> [String]? {
        var s = raw
        if backslashIsSeparator { s = s.replacingOccurrences(of: "\\", with: "/") }
        // Windows drive prefix ("C:") is meaningless here.
        if s.count >= 2, s.dropFirst().first == ":", s.first!.isLetter { s.removeFirst(2) }
        var comps: [String] = []
        for c in s.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { skip(raw, "path escapes the destination (..)", .escapesDestination); return nil }
            if c.utf8.count > 255 || c.contains("\0") { skip(raw, "invalid path component", .invalidName); return nil }
            comps.append(String(c))
        }
        if comps.isEmpty { skip(raw, "empty path", .invalidName); return nil }
        return comps
    }

    // MARK: directories

    /// Directory fds kept open for reuse, keyed by relative path (bounded: the default
    /// soft limit is 256 descriptors). Opening and mkdir-ing every path component for every file
    /// is expensive when an Endpoint Security agent inspects each call.
    private let dirCache = Mutex<[String: Int32]>([:])
    private let knownDirs = Mutex<Set<String>>([])
    private static let dirCacheLimit = 64
    private static let processUmask: mode_t = { let m = umask(0); umask(m); return m }()

    /// Opens (creating as needed) the directory at `comps` below the root, refusing symlinks.
    /// The caller owns (and closes) the returned descriptor.
    private func openDirectory(_ comps: ArraySlice<String>, entry: String) throws -> Int32 {
        let key = comps.joined(separator: "/")
        if let cached = dirCache.withLock({ $0[key] }) { return dup(cached) }
        var fd = dup(rootFD)
        var rel = ""
        for c in comps {
            rel = rel.isEmpty ? c : rel + "/" + c
            let known = knownDirs.withLock { $0.contains(rel) }
            if !known && mkdirat(fd, c, 0o755) != 0 && errno != EEXIST {
                let e = XipperError.posix("mkdir", entry); close(fd); throw e
            }
            let next = openat(fd, c, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            if next < 0 {
                if errno == ELOOP || errno == ENOTDIR {
                    throw XipperError.unsafeEntry(entry: entry, reason: "a parent folder is a symlink or a file")
                }
                throw XipperError.posix("open folder", entry)
            }
            if !known { knownDirs.withLock { _ = $0.insert(rel) } }
            fd = next
        }
        if !key.isEmpty {
            dirCache.withLock { cache in
                if cache.count < Self.dirCacheLimit && cache[key] == nil { cache[key] = dup(fd) }
            }
        }
        return fd
    }

    private func closeCachedDirectories() {
        dirCache.withLock { cache in
            for fd in cache.values { close(fd) }
            cache.removeAll()
        }
    }

    /// Extended attributes of a folder created by `makeDirectory` (applied by path, without following links).
    func setAttributes(_ xattrs: [(name: String, value: [UInt8])], onDirectory comps: [String]) {
        guard options.restoreExtendedAttributes, !xattrs.isEmpty, !comps.isEmpty,
              let fd = try? openDirectory(comps[...], entry: comps.joined(separator: "/")) else { return }
        defer { close(fd) }
        ExtendedAttributes.apply(xattrs, fd: fd)
    }

    func makeDirectory(_ comps: [String], permissions: UInt16?, modified: Date?) throws {
        let fd = try openDirectory(comps[...], entry: comps.joined(separator: "/"))
        close(fd)
        if let q = quarantine { _ = q.withUnsafeBytes { setxattr(rootPath + "/" + comps.joined(separator: "/"), "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) } }
        deferredDirs.withLock { $0[comps.joined(separator: "/")] = (permissions, modified) }
        counts.withLock { $0.dirs += 1 }
    }

    // MARK: files

    /// Writes one regular file. `produce` streams the content into the provided sink.
    ///
    /// The file is created directly under its final name (O_EXCL): atomicity comes from the
    /// staging folder in smart mode, and a failed entry is removed. Only when a file of that name
    /// already exists is a temporary file written and moved according to the overwrite policy.
    func writeFile(_ comps: [String], permissions: UInt16?, modified: Date?, declaredSize: Int64? = nil,
                   xattrs: [(name: String, value: [UInt8])] = [], produce: (ByteSink) throws -> Void) throws {
        let entry = comps.joined(separator: "/")
        let dirFD = try openDirectory(comps.dropLast(), entry: entry)
        defer { close(dirFD) }
        let name = comps.last!
        let mode = mode_t(fileMode(permissions, defaultMode: 0o644))
        var tmp: String?
        var decision = ConflictDecision.keepBoth
        var fd = openat(dirFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        if fd < 0 {
            guard errno == EEXIST else { throw XipperError.posix("create", entry) }
            decision = try decide(entry: entry, dirFD: dirFD, name: name, size: declaredSize, modified: modified)
            if decision == .skip { skip(entry, "already exists", .alreadyExists); return }
            let t = ".xip-\(UInt32.random(in: 0...UInt32.max)).part"
            fd = openat(dirFD, t, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
            if fd < 0 { throw XipperError.posix("create", entry) }
            tmp = t
        }
        var ok = false
        defer {
            if !ok { unlinkat(dirFD, tmp ?? name, 0) }
        }
        do {
            let w = FDWriter(fd: fd, entry: entry)
            try produce { chunk in
                let total = self.written.add(Int64(chunk.count), ordering: .relaxed).newValue
                if total > self.maxBytes { throw self.overLimit(needed: total) }
                try w.write(chunk)
            }
            try w.flush()
            if mode & ~Self.processUmask != mode { fchmod(fd, mode) }
            if options.restoreExtendedAttributes && !xattrs.isEmpty { ExtendedAttributes.apply(xattrs, fd: fd) }
            if let modified { var ts = Self.timespecs(modified); futimens(fd, &ts) }
            if let q = quarantine { _ = q.withUnsafeBytes { fsetxattr(fd, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) } }
            close(fd)
        } catch {
            close(fd)
            throw error
        }
        if let tmp {
            guard try place(dirFD: dirFD, tmp: tmp, name: name, entry: entry, decision: decision) else { ok = true; return }
        }
        ok = true
        counts.withLock { $0.files += 1 }
    }

    /// Moves `tmp` to `name` according to `decision` (nil: from the policy, `.ask` meaning keep both).
    /// Returns false if skipped.
    private func place(dirFD: Int32, tmp: String, name: String, entry: String, decision: ConflictDecision? = nil) throws -> Bool {
        if renameatx_np(dirFD, tmp, dirFD, name, UInt32(RENAME_EXCL)) == 0 { return true }
        guard errno == EEXIST else { throw XipperError.posix("rename", entry) }
        let d: ConflictDecision
        if let decision {
            d = decision
        } else {
            switch options.overwrite {
            case .fail: throw XipperError.alreadyExists(path: entry)
            case .skip: d = .skip
            case .replace: d = .replace
            case .keepBoth, .ask: d = .keepBoth
            }
        }
        switch d {
        case .skip:
            skip(entry, "already exists", .alreadyExists)
            unlinkat(dirFD, tmp, 0)
            return false
        case .replace:
            var st = stat()
            if fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 && st.st_mode & S_IFMT == S_IFDIR {
                throw XipperError.alreadyExists(path: entry)
            }
            if options.trashReplacedFiles {
                // Best effort: if the Trash is unavailable (other volume), fall back to replacing.
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: rootPath + "/" + entry), resultingItemURL: nil)
            }
            if renameat(dirFD, tmp, dirFD, name) != 0 { throw XipperError.posix("rename", entry) }
            return true
        case .keepBoth:
            let (stem, ext) = Self.split(name)
            for n in 2...10_000 {
                let candidate = "\(stem) \(n)\(ext)"
                if renameatx_np(dirFD, tmp, dirFD, candidate, UInt32(RENAME_EXCL)) == 0 { return true }
                if errno != EEXIST { throw XipperError.posix("rename", entry) }
            }
            throw XipperError.alreadyExists(path: entry)
        }
    }

    static func split(_ name: String) -> (String, String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }

    // MARK: links (deferred)

    func addSymlink(_ comps: [String], target: String, modified: Date?) {
        switch options.symlinks {
        case .skipAll:
            skip(comps.joined(separator: "/"), "symlinks are disabled", .symlinksDisabled)
            return
        case .insideDestinationOnly:
            if !Self.staysInside(link: comps, target: target) {
                skip(comps.joined(separator: "/"), "symlink points outside the destination (\(target))", .symlinkOutside(target: target))
                return
            }
        case .allowAll:
            break
        }
        deferredLinks.withLock { $0.append((comps, target, false, modified)) }
    }

    func addHardLink(_ comps: [String], target: [String]) {
        deferredLinks.withLock { $0.append((comps, target.joined(separator: "/"), true, nil)) }
    }

    /// Lexically resolves `target` relative to the link's folder and checks it stays below the root.
    static func staysInside(link: [String], target: String) -> Bool {
        if target.hasPrefix("/") || target.isEmpty { return false }
        var stack = Array(link.dropLast())
        for c in target.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." {
                if stack.isEmpty { return false }
                stack.removeLast()
            } else {
                stack.append(String(c))
            }
        }
        return true
    }

    /// Creates deferred links, then applies directory permissions/times deepest-first.
    func finalize() throws {
        mergeAppleDoubles()
        // Hard links first: their targets must not be resolved through symlinks created here.
        let links = deferredLinks.withLock { $0 }.enumerated().sorted { ($0.element.hard ? 0 : 1, $0.offset) < ($1.element.hard ? 0 : 1, $1.offset) }.map(\.element)
        for l in links {
            let entry = l.path.joined(separator: "/")
            let dirFD: Int32
            do { dirFD = try openDirectory(l.path.dropLast(), entry: entry) } catch {
                skip(entry, "\(error)"); continue
            }
            defer { close(dirFD) }
            let tmp = ".xip-\(UInt32.random(in: 0...UInt32.max)).link"
            let r: Int32
            if l.hard {
                r = linkat(rootFD, l.target, dirFD, tmp, 0)  // target was sanitized by the caller
            } else {
                r = symlinkat(l.target, dirFD, tmp)
            }
            if r != 0 { skip(entry, "cannot create link: \(String(cString: strerror(errno)))"); continue }
            if !l.hard {
                if let q = quarantine { q.withUnsafeBytes { fsetxattrNoFollow(dirFD, tmp, $0) } }
                if let m = l.mtime { var ts = Self.timespecs(m); utimensat(dirFD, tmp, &ts, AT_SYMLINK_NOFOLLOW) }
            }
            do {
                if try place(dirFD: dirFD, tmp: tmp, name: l.path.last!, entry: entry) { counts.withLock { $0.links += 1 } }
            } catch {
                unlinkat(dirFD, tmp, 0)
                throw error
            }
        }
        let dirs = deferredDirs.withLock { $0 }.sorted { $0.key.count > $1.key.count }
        for (rel, meta) in dirs {
            if options.preservePermissions, let p = meta.perm {
                // Keep the owner able to enter and modify the folder.
                fchmodat(rootFD, rel, mode_t(fileMode(p, defaultMode: 0o755) | 0o700), AT_SYMLINK_NOFOLLOW)
            }
            if let m = meta.mtime { var ts = Self.timespecs(m); utimensat(rootFD, rel, &ts, AT_SYMLINK_NOFOLLOW) }
        }
    }

    private func fsetxattrNoFollow(_ dirFD: Int32, _ name: String, _ value: UnsafeRawBufferPointer) {
        let fd = openat(dirFD, name, O_RDONLY | O_SYMLINK | O_CLOEXEC)
        if fd >= 0 { fsetxattr(fd, "com.apple.quarantine", value.baseAddress, value.count, 0, 0); close(fd) }
    }

    // MARK: helpers

    private func fileMode(_ permissions: UInt16?, defaultMode: UInt16) -> UInt16 {
        guard options.preservePermissions, let p = permissions, p & 0o777 != 0 else { return defaultMode }
        return p & 0o777  // setuid, setgid and sticky are never restored
    }

    static func timespecs(_ d: Date) -> [timespec] {
        let t = d.timeIntervalSince1970
        let s = Int(t.rounded(.down))
        let ts = timespec(tv_sec: s, tv_nsec: Int((t - Double(s)) * 1e9))
        return [ts, ts]
    }

    static func readXattr(_ path: String, _ name: String) -> [UInt8]? {
        let n = getxattr(path, name, nil, 0, 0, 0)
        guard n > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: n)
        return getxattr(path, name, &buf, n, 0, 0) == n ? buf : nil
    }
}

/// Small buffered writer over a raw file descriptor.
private final class FDWriter {
    let fd: Int32
    let entry: String
    private let cap = 1 << 20
    private let buf: UnsafeMutableRawPointer
    private var used = 0

    init(fd: Int32, entry: String) {
        self.fd = fd
        self.entry = entry
        buf = .allocate(byteCount: cap, alignment: 16384)
    }
    deinit { buf.deallocate() }

    func write(_ chunk: UnsafeRawBufferPointer) throws {
        guard let base = chunk.baseAddress, chunk.count > 0 else { return }
        if chunk.count >= cap {
            try flush()
            try raw(base, chunk.count)
            return
        }
        if used + chunk.count > cap { try flush() }
        (buf + used).copyMemory(from: base, byteCount: chunk.count)
        used += chunk.count
    }

    func flush() throws {
        if used > 0 { try raw(buf, used); used = 0 }
    }

    private func raw(_ p: UnsafeRawPointer, _ n: Int) throws {
        var done = 0
        while done < n {
            let r = Darwin.write(fd, p + done, n - done)
            if r < 0 { if errno == EINTR { continue }; throw XipperError.posix("write", entry) }
            done += r
        }
    }
}
