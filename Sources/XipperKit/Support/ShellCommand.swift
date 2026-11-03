import Foundation

/// «Copia come comando»: the `xipper` command line that does what an app job does, for a
/// script or a terminal. Passwords never appear: `-p` makes the command ask for it. What the
/// command line cannot express is listed in `notes` (and left out of the command).
public struct ShellCommand: Sendable, Equatable {
    public var arguments: [String]
    /// Commands to run after it (`&& …`), e.g. the PAR2 recovery data.
    public var then: [[String]] = []
    public var notes: [String] = []

    /// One line for a POSIX shell, every argument quoted when needed.
    public func line(executable: String = "xipper") -> String {
        ([[executable] + arguments] + then.map { [executable] + $0 })
            .map { $0.map(Self.quote).joined(separator: " ") }
            .joined(separator: " && ")
    }

    /// Single quotes unless the word is made only of characters a shell leaves alone.
    public static func quote(_ s: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./,:=+@%")
        if !s.isEmpty, s.unicodeScalars.allSatisfy(plain.contains) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func size(_ n: Int64) -> String {
        for (unit, shift) in [("g", 30), ("m", 20), ("k", 10)] where n % (1 << shift) == 0 { return "\(n >> shift)\(unit)" }
        return String(n)
    }

    // MARK: per command

    public static func create(_ sources: [URL], to archive: URL, options o: CreateOptions, recoveryPercent: Double? = nil) -> ShellCommand {
        var a = ["create"]
        var notes: [String] = []
        if ArchiveFormat.inferred(fromFileName: archive.lastPathComponent) != o.format { a += ["-f", o.format.rawValue] }
        if let l = o.level { a += ["-l", String(l)] }
        let isZip = o.format == .zip, is7z = o.format == .sevenZip
        if isZip && o.zipMethod != .deflate { a += ["-m", o.zipMethod.name] }
        if o.password != nil { a.append("-p") }
        if is7z, let s = o.solidBlockSize { a += ["--solid", s == 0 ? "off" : size(s)] }
        if let v = o.volumeSize { a += ["-v", size(v)] }
        if isZip && o.volumeSize != nil && o.zipVolumeStyle == .numbered { a.append("--numbered") }
        if is7z && o.password != nil && !o.encryptFileNames { a.append("--plain-names") }
        if o.format == .xiz && !o.xizDictionary { a.append("--no-dictionary") }
        if o.format == .xiz && o.xizCodec == .lzma2 { a.append("--lzma2") }
        if o.format == .xiz, let p = recoveryPercent ?? (o.xizRecovery > 0 ? o.xizRecovery : nil) { a += ["--recovery", String(Int(p))] }
        if o.forceZip64 { a.append("--zip64") }
        if !o.scan.excludeMacMetadata { a.append("--keep-mac-files") }
        if (isZip || is7z) && o.windowsCompatibleNames { a.append("--windows-names") }
        if isZip && o.zipAppleDouble { a.append("--apple-double") }
        if !o.storeAlreadyCompressed { a.append("--recompress-all") }
        if !o.genomicsUsesBGZF { a.append("--no-bgzf") }
        if o.writeBGZFIndex { a.append("--bgzf-index") }
        if isZip && o.password != nil && o.legacyZipCrypto { a.append("--zipcrypto") }
        if o.overwrite { a.append("--overwrite") }
        if o.xizAccess != nil { notes.append("XIZ access groups and recipients are not part of the command: use --access with a policy file") }
        if o.xizSigner != nil { notes.append("the XIZ signature is not part of the command: use --sign with your identity") }
        a.append(archive.path)
        a += sources.map(\.path)
        var c = ShellCommand(arguments: a, notes: notes)
        if let p = recoveryPercent, o.format != .xiz { c.then.append(["par2", "create", "--redundancy", String(Int(p)), archive.path]) }
        return c
    }

    public static func extract(_ archive: URL, to destination: URL?, mode: ExtractionMode, options o: ExtractOptions) -> ShellCommand {
        var a = ["extract"]
        var notes: [String] = []
        if let d = destination { a += ["-d", d.path] }
        if mode == .into { a.append("--into") }
        if o.flatten { a.append("--flatten") }
        switch o.overwrite {
        case .keepBoth: break
        case .replace: a += ["--overwrite", "replace"]
        case .skip: a += ["--overwrite", "skip"]
        case .fail: a += ["--overwrite", "fail"]
        case .ask: notes.append("asking file by file is not available on the command line: existing files are kept and the new ones renamed")
        }
        switch o.symlinks {
        case .allowAll: a.append("--allow-external-symlinks")
        case .insideDestinationOnly: break
        case .skipAll: notes.append("skipping every symlink is not available on the command line")
        }
        if !o.propagateQuarantine { a.append("--no-quarantine") }
        if o.nestedDepth > 0 { a += ["-r", String(o.nestedDepth)] }
        if o.nestedDepth > 0 && o.keepNestedArchives { a.append("--keep-nested") }
        if o.password != nil { a.append("-p") }
        if o.limits.maxCompressionRatio != ExtractionLimits().maxCompressionRatio {
            notes.append("the zip-bomb limit of \(Int(o.limits.maxCompressionRatio)):1 is not part of the command (it uses 1000:1)")
        }
        a.append(archive.path)
        a += (o.selection ?? []).sorted()
        return ShellCommand(arguments: a, notes: notes)
    }

    public static func test(_ archive: URL, password: Bool) -> ShellCommand {
        ShellCommand(arguments: ["test"] + (password ? ["-p"] : []) + [archive.path])
    }

    public static func convert(_ source: URL, to target: URL, options o: CreateOptions, password: Bool, trashOriginal: Bool) -> ShellCommand {
        var a = ["convert", "--to", o.format.rawValue, "-o", target.path]
        if o.format == .zip && o.zipMethod != .deflate { a += ["-m", o.zipMethod.name] }
        if let l = o.level { a += ["-l", String(l)] }
        if password { a.append("-p") }
        if trashOriginal { a.append("--trash-original") }
        a.append(source.path)
        return ShellCommand(arguments: a)
    }
}
