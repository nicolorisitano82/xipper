import Darwin
import Foundation

/// One filesystem object to be archived.
public struct ArchiveItem: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case file(size: Int64)
        case directory
        case symlink(target: String)
    }

    /// Path inside the archive: "/"-separated, relative, no trailing slash.
    public var name: String
    /// Absolute path on disk.
    public var sourcePath: String
    public var kind: Kind
    /// Permission bits (0o7777).
    public var permissions: UInt16
    public var modified: Date
    public var uid: UInt32
    public var gid: UInt32

    var size: Int64 { if case let .file(s) = kind { return s } else { return 0 } }
}

public struct ScanOptions: Sendable {
    /// Skip Finder/Spotlight droppings (.DS_Store, AppleDouble `._*`, `__MACOSX`, …).
    public var excludeMacMetadata = true
    /// Archive what symlinks point to instead of the links themselves.
    public var followSymlinks = false
    /// Store names in NFC (what Windows and Linux expect); APFS keeps whatever form the file was created with.
    public var normalizeToNFC = true
    /// Additional names to exclude (exact match on the last path component).
    public var excludeNames: Set<String> = []

    public init() {}

    static let macMetadata: Set<String> = [
        ".DS_Store", ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems",
        ".DocumentRevisions-V100", "__MACOSX", "Icon\r",
    ]
}

enum SourceScanner {
    /// Expands `urls` (files or folders) into items, parents before children, siblings sorted.
    /// Each top-level URL becomes a top-level entry named after its last path component.
    static func scan(_ urls: [URL], options: ScanOptions) throws -> [ArchiveItem] {
        var out: [ArchiveItem] = []
        var seenTop = Set<String>()
        for url in urls {
            let path = url.standardizedFileURL.path
            var name = (path as NSString).lastPathComponent
            if options.normalizeToNFC { name = name.precomposedStringWithCanonicalMapping }
            if !seenTop.insert(name).inserted {
                throw XipperError.invalidArgument("two sources are both named \"\(name)\"")
            }
            try walk(path, name: name, options: options, into: &out, top: true)
        }
        return out
    }

    private static func excluded(_ component: String, _ options: ScanOptions) -> Bool {
        if options.excludeNames.contains(component) { return true }
        guard options.excludeMacMetadata else { return false }
        return ScanOptions.macMetadata.contains(component) || component.hasPrefix("._")
    }

    private static func walk(_ path: String, name: String, options: ScanOptions,
                             into out: inout [ArchiveItem], top: Bool) throws {
        var st = stat()
        let r = options.followSymlinks ? stat(path, &st) : lstat(path, &st)
        if r != 0 {
            if top { throw XipperError.posix("stat", path) }
            return  // vanished while scanning
        }
        let modified = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
        func item(_ kind: ArchiveItem.Kind) -> ArchiveItem {
            ArchiveItem(name: name, sourcePath: path, kind: kind, permissions: UInt16(st.st_mode & 0o7777),
                        modified: modified, uid: st.st_uid, gid: st.st_gid)
        }
        switch st.st_mode & S_IFMT {
        case S_IFREG:
            out.append(item(.file(size: Int64(st.st_size))))
        case S_IFLNK:
            var buf = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
            let n = readlink(path, &buf, buf.count - 1)
            if n < 0 { throw XipperError.posix("readlink", path) }
            out.append(item(.symlink(target: String(decoding: buf[0..<n], as: UTF8.self))))
        case S_IFDIR:
            out.append(item(.directory))
            let children: [String]
            do { children = try FileManager.default.contentsOfDirectory(atPath: path) } catch {
                throw XipperError.io("list directory", path: path, errno: EACCES)
            }
            for child in children.sorted() where !excluded(child, options) {
                var childName = child
                if options.normalizeToNFC { childName = childName.precomposedStringWithCanonicalMapping }
                try walk(path + "/" + child, name: name + "/" + childName, options: options, into: &out, top: false)
            }
        default:
            break  // sockets, FIFOs, devices are not archived
        }
    }
}

/// Extensions whose content is already compressed: stored as-is instead of wasting CPU.
enum AlreadyCompressed {
    static let extensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "avif", "jxl",
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "mp3", "m4a", "aac", "flac", "ogg", "opus",
        "zip", "7z", "rar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "zst", "lz4", "br", "lzma",
        "dmg", "pkg", "ipa", "apk", "jar", "aar", "xip",
        "docx", "xlsx", "pptx", "pages", "numbers", "key", "epub", "odt", "ods", "odp", "woff", "woff2",
    ]

    static func matches(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...].lowercased()
        return extensions.contains(ext) || Genomics.compressedExtensions.contains(ext)
    }
}
