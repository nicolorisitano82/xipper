// xipper — command line front end for XipperKit.
// Hand-written argument parsing: the CLI ships inside Xipper.app with no dependencies.
import Darwin
import Foundation
import XipperKit
import XipperMCP

let usage = """
usage: xipper <command> [options]

  create  [options] <archive> <file|folder>...
      -f, --format FMT     zip (default from name), 7z, tar, tar.gz, tar.bz2, tar.xz, tar.zst, aar, cpio,
                           xiz (BETA), gz, bz2, xz, zst
      -l, --level N        compression level (zip 1-12, zstd 1-22, xz/7z 0-9, bzip2 1-9)
      -m, --method M       zip method: deflate (default), zstd, store
      -p, --password       encrypt (zip, 7z: AES-256); prompts for the password
          --solid SIZE     7z solid block size (e.g. 64m, 2g; "off" = one block per file)
      -v, --volume SIZE    7z: split into volumes of SIZE (name.7z.001, .002, …)
          --plain-names    7z with a password: leave file names readable
          --password-stdin read the password from the first line of stdin
          --zip64          always write ZIP64 structures
          --keep-mac-files keep .DS_Store, ._* and similar files
          --overwrite      replace an existing archive
  extract [options] <archive> [entry...]
      -d, --dest DIR       destination folder (default: next to the archive)
          --into           extract directly into DIR instead of a new folder
          --overwrite P    keep-both (default), replace, skip, fail
          --allow-external-symlinks
          --no-quarantine  do not copy the archive's quarantine attribute
      -p, --password / --password-stdin
  test    [-p | --password-stdin] [--sha256] <archive>
          --sha256         also print a SHA256SUMS manifest of the content (sha256sum -c format)
  list    [--long] [-p | --password-stdin] <archive>   (password: 7z with encrypted names)
  mount   [options] <archive>   mount as a volume (/Volumes/<name>) until ejected or Ctrl-C
          --read-only      do not allow changes
          --discard        drop the changes instead of saving them into the archive
          --at DIR         mount on DIR instead of /Volumes
      -p, --password / --password-stdin
  mcp     [options]               MCP server on stdio for AI agents (see `xipper mcp --help`)
  bgzip   [options] <file>...     BGZF (blocked gzip) for genomics, bgzip-compatible
      (default)            compress FILE to FILE.gz (the original is kept)
      -d, --decompress     decompress (gz, BGZF, bz2, xz, zst)
      -c, --stdout         write to standard output
      -i, --index          also write the .gzi index;  -I, --index-name FILE
      -r, --reindex        (re)build FILE.gzi for an existing BGZF file
      -t, --test           verify every block and the end-of-file marker
      -l, --compress-level N   0-9 as in bgzip (default 6);  -@, --threads N
      -f, --force          overwrite existing files;  -k accepted (originals are always kept)
          --convert        recompress a plain .gz as BGZF in place
          --info           block count, sizes, end-of-file marker
\(genomics2Usage)

common options:
  -j, --threads N          worker threads (default: performance cores)
      --background         run on efficiency cores at low priority
  -q, --quiet              no progress output
"""

struct Usage: Error { let message: String }

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(2) }
args.removeFirst()
if command == "mcp" { runMCP(args) }
if genomics2Commands.contains(command) { runGenomics2(command, args) }

// MARK: argument helpers

var flags = Set<String>()
var values: [String: String] = [:]
var positional: [String] = []
let commonFlags: Set<String> = ["--background", "-q", "--quiet", "-h", "--help"]
let knownFlags: Set<String> = command == "bgzip"
    ? commonFlags.union(["-d", "--decompress", "-c", "--stdout", "-i", "--index", "-r", "--reindex", "-t", "--test",
                         "-f", "--force", "-k", "--keep", "--convert", "--info"])
    : commonFlags.union(["-p", "--password", "--password-stdin", "--zip64", "--keep-mac-files", "--overwrite", "--into",
                         "--allow-external-symlinks", "--no-quarantine", "--long", "--sha256", "--plain-names",
                         "--read-only", "--discard"])
let valueOptions: Set<String> = command == "bgzip"
    ? ["-I", "--index-name", "-@", "-l", "--compress-level", "-j", "--threads"]
    : ["-f", "--format", "-l", "--level", "-m", "--method", "-d", "--dest", "-j", "--threads", "--overwrite",
       "--solid", "-v", "--volume", "--at"]
do {
    var i = 0
    while i < args.count {
        let a = args[i]
        if a == "--" { positional += args[(i + 1)...]; break }
        if a.hasPrefix("-") && a.count > 1 {
            if a == "--overwrite" && command == "create" { flags.insert(a); i += 1; continue }
            if valueOptions.contains(a) {
                guard i + 1 < args.count else { throw Usage(message: "\(a) needs a value") }
                values[a] = args[i + 1]
                i += 2
                continue
            }
            guard knownFlags.contains(a) else { throw Usage(message: "unknown option \(a)") }
            flags.insert(a)
        } else {
            positional.append(a)
        }
        i += 1
    }
    // `create --overwrite` is a flag (handled above), `extract --overwrite P` takes a value.
} catch let u as Usage {
    fputs("xipper: \(u.message)\n", stderr)
    exit(2)
}

@MainActor func value(_ names: String...) -> String? { names.lazy.compactMap { values[$0] }.first }
@MainActor func flag(_ names: String...) -> Bool { names.contains { flags.contains($0) } }

/// "512k", "64m", "2g", "1000" → bytes.
func parseSize(_ s: String) -> Int64? {
    let units: [Character: Int64] = ["k": 1 << 10, "m": 1 << 20, "g": 1 << 30, "t": 1 << 40]
    var t = s.lowercased()
    if t.hasSuffix("b") { t.removeLast() }
    let mult = t.last.flatMap { units[$0] } ?? 1
    if mult > 1 { t.removeLast() }
    guard let n = Int64(t), n >= 0 else { return nil }
    let (v, overflow) = n.multipliedReportingOverflow(by: mult)
    return overflow ? nil : v
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    fputs("xipper: \(message)\n", stderr)
    exit(code)
}

let workload: Workload = {
    if let j = value("-j", "--threads", "-@") {
        guard let n = Int(j), n > 0 else { fail("invalid thread count \(j)", code: 2) }
        return .threads(n)
    }
    return flag("--background") ? .background : .interactive
}()

@MainActor func readPassword(confirm: Bool) -> String? {
    if flag("--password-stdin") {
        guard let line = readLine(strippingNewline: true), !line.isEmpty else { fail("no password on stdin") }
        return line
    }
    guard flag("-p", "--password") else { return nil }
    func ask(_ prompt: String) -> String {
        var buf = [CChar](repeating: 0, count: 1024)
        guard readpassphrase(prompt, &buf, buf.count, RPP_ECHO_OFF | RPP_REQUIRE_TTY) != nil else { fail("cannot read password") }
        defer { memset_s(&buf, buf.count, 0, buf.count) }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    let pw = ask("Password: ")
    if pw.isEmpty { fail("empty password") }
    if confirm && ask("Repeat password: ") != pw { fail("passwords do not match") }
    return pw
}

// MARK: progress & cancellation

let cancel = CancellationToken()
signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
sigint.setEventHandler { cancel.cancel() }
sigint.resume()

let showProgress = !flag("-q", "--quiet") && isatty(STDERR_FILENO) != 0
let progress: ProgressHandler? = showProgress ? progressPrinter() : nil

func progressPrinter() -> ProgressHandler {
    { p in
        let pct = p.totalBytes > 0 ? "\(Int(p.fraction * 100))%" : ""
        let speed = Int(p.bytesPerSecond / 1e6)
        let name = String((p.currentEntry ?? "").suffix(40))
        fputs("\r\u{1B}[K\(pct.leftPad(4)) \(p.completedBytes.bytesText.leftPad(9)) \(String(speed).leftPad(6)) MB/s  \(name)", stderr)
    }
}

func endProgress() { if showProgress { fputs("\r\u{1B}[K", stderr) } }


func run(_ body: () throws -> Void) -> Never {
    do {
        try body()
        exit(0)
    } catch XipperError.cancelled {
        endProgress()
        fail("cancelled", code: 130)
    } catch let e as XipperError {
        endProgress()
        switch e {
        case .passwordRequired: fail("\(e) (use -p or --password-stdin)", code: 4)
        case .wrongPassword: fail("\(e)", code: 4)
        default: fail("\(e)")
        }
    } catch {
        endProgress()
        fail("\(error)")
    }
}

// MARK: commands

switch command {
case "create", "c":
    guard positional.count >= 2 else { fail("create needs an archive and at least one source", code: 2) }
    let archive = URL(fileURLWithPath: positional[0])
    var o = CreateOptions()
    if let f = value("-f", "--format") {
        guard let fmt = ArchiveFormat(rawValue: f.lowercased()) else { fail("unknown format \(f)", code: 2) }
        o.format = fmt
    } else if let fmt = ArchiveFormat.inferred(fromFileName: archive.lastPathComponent) {
        o.format = fmt
    }
    if let l = value("-l", "--level") { guard let n = Int(l) else { fail("invalid level \(l)", code: 2) }; o.level = n }
    switch value("-m", "--method")?.lowercased() {
    case nil, "deflate": o.zipMethod = .deflate
    case "zstd": o.zipMethod = .zstd
    case "store": o.zipMethod = .store
    case let m?: fail("unknown method \(m)", code: 2)
    }
    o.forceZip64 = flag("--zip64")
    if let v = value("--solid") {
        guard let n = v.lowercased() == "off" ? 0 : parseSize(v) else { fail("invalid solid block size \(v)", code: 2) }
        o.solidBlockSize = n
    }
    if let v = value("-v", "--volume") {
        guard let n = parseSize(v), n > 0 else { fail("invalid volume size \(v)", code: 2) }
        o.volumeSize = n
    }
    o.encryptFileNames = !flag("--plain-names")
    o.overwrite = flag("--overwrite")
    o.scan.excludeMacMetadata = !flag("--keep-mac-files")
    o.workload = workload
    o.password = readPassword(confirm: true)
    if o.format == .zip, let pw = o.password, pw.utf8.contains(where: { $0 >= 0x80 }) {
        fputs("xipper: warning: non-ASCII passwords cannot be entered in 7-Zip\n", stderr)
    }
    run {
        let r = try Xipper.create(from: positional.dropFirst().map { URL(fileURLWithPath: $0) }, to: archive,
                                  options: o, progress: progress, cancel: cancel)
        endProgress()
        let ratio = r.inputBytes > 0 ? Double(r.outputBytes) / Double(r.inputBytes) * 100 : 0
        print(String(format: "%@: %d entries, %@ → %@ (%.1f%%) in %.2fs, %.0f MB/s", archive.lastPathComponent, r.entries,
                     r.inputBytes.bytesText, r.outputBytes.bytesText, ratio, r.elapsed,
                     r.elapsed > 0 ? Double(r.inputBytes) / r.elapsed / 1e6 : 0))
    }

case "extract", "x":
    guard positional.count >= 1 else { fail("extract needs an archive", code: 2) }
    let archive = URL(fileURLWithPath: positional[0])
    var o = ExtractOptions()
    o.workload = workload
    o.propagateQuarantine = !flag("--no-quarantine")
    if flag("--allow-external-symlinks") { o.symlinks = .allowAll }
    switch value("--overwrite") {
    case nil, "keep-both": o.overwrite = .keepBoth
    case "replace": o.overwrite = .replace
    case "skip": o.overwrite = .skip
    case "fail": o.overwrite = .fail
    case let p?: fail("unknown overwrite policy \(p)", code: 2)
    }
    if positional.count > 1 { o.selection = Set(positional.dropFirst()) }
    o.password = readPassword(confirm: false)
    let dest = value("-d", "--dest").map { URL(fileURLWithPath: $0) }
    run {
        let r = try Xipper.extract(archive, to: dest, mode: flag("--into") ? .into : .smart, options: o,
                                   progress: progress, cancel: cancel)
        endProgress()
        print("\(r.destination.path): \(r.files) files, \(r.directories) folders, \(r.symlinks) links, \(r.bytes.bytesText) in \(String(format: "%.2f", r.elapsed))s")
        for s in r.skipped { fputs("skipped \(s.path): \(s.reason)\n", stderr) }
        if !r.skipped.isEmpty { exit(3) }
    }

case "test", "t":
    guard positional.count == 1 else { fail("test needs one archive", code: 2) }
    let pw = readPassword(confirm: false)
    run {
        let sums = flag("--sha256")
        let r = try Xipper.test(URL(fileURLWithPath: positional[0]), password: pw, workload: workload, digests: sums,
                                progress: progress, cancel: cancel)
        endProgress()
        if sums {
            // The manifest goes to stdout alone, so it can be redirected to a SHA256SUMS file.
            print(r.sha256sums, terminator: "")
            for f in r.failures { fputs("FAILED \(f.path): \(f.reason)\n", stderr) }
            if !r.isOK { exit(3) }
            return
        }
        for f in r.failures { print("FAILED \(f.path): \(f.reason)") }
        print(r.isOK ? "OK: \(r.entries) entries, \(r.bytes.bytesText) verified in \(String(format: "%.2f", r.elapsed))s"
                     : "\(r.failures.count) of \(r.entries) entries failed")
        if !r.isOK { exit(3) }
    }

case "list", "l":
    guard positional.count == 1 else { fail("list needs one archive", code: 2) }
    let pw = readPassword(confirm: false)
    run {
        let entries = try Xipper.list(URL(fileURLWithPath: positional[0]), password: pw, workload: workload)
        let long = flag("--long")
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        for e in entries {
            let name = e.kind == .directory ? e.path + "/" : e.path
            if long {
                let kind = switch e.kind { case .directory: "d"; case .symlink: "l"; case .hardlink: "h"; case .file: "-" }
                let lock = e.isEncrypted ? "🔒" : "  "
                let size = e.uncompressedSize >= 0 ? String(e.uncompressedSize) : "?"
                print("\(kind) \(lock) \(size.leftPad(12)) \(e.modified.map(df.string) ?? "                ") \(e.method.leftPad(8))  \(name)\(e.linkTarget.map { " -> \($0)" } ?? "")")
            } else {
                print(name)
            }
        }
    }

case "mount":
    guard positional.count == 1 else { fail("mount needs one archive", code: 2) }
    let pw = readPassword(confirm: false)
    run {
        let archive = URL(fileURLWithPath: positional[0])
        let m = try ArchiveMount(archive: archive, password: pw, writable: !flag("--read-only"))
        let point = try m.mount(at: value("--at").map { URL(fileURLWithPath: $0, isDirectory: true) })
        print("mounted \(archive.lastPathComponent) on \(point.path)\(m.tree.writable ? "" : " (read-only)")")
        print("eject it from the Finder, or press Ctrl-C, to unmount\(m.tree.writable && !flag("--discard") ? " and save the changes" : "")")
        m.waitUntilUnmounted(cancel: cancel)
        if m.isMounted {
            do { try m.unmount() } catch {
                fputs("xipper: the volume is in use; close the files on it and eject it from the Finder\n", stderr)
                m.waitUntilUnmounted()
            }
        }
        let save = !flag("--discard")
        if save && m.tree.hasChanges { print("saving the changes into \(archive.lastPathComponent)…") }
        else if m.tree.hasChanges { print("changes discarded") }
        try m.finish(save: save, progress: progress)
        endProgress()
        print("unmounted")
    }

case "bgzip":
    guard !positional.isEmpty else { fail("bgzip needs at least one file", code: 2) }
    let level = value("-l", "--compress-level").map { s -> Int in
        guard let n = Int(s), (0...9).contains(n) else { fail("invalid level \(s) (0-9)", code: 2) }
        return n
    }
    let toStdout = flag("-c", "--stdout")
    let force = flag("-f", "--force")
    run {
        for path in positional {
            let url = URL(fileURLWithPath: path)
            if flag("--info") {
                let i = try Xipper.bgzfInfo(url)
                print("\(path): BGZF, \(i.blocks) blocks, \(i.compressedSize.bytesText) → \(i.uncompressedSize.bytesText), EOF marker \(i.endsWithEOFMarker ? "present" : "MISSING")")
            } else if flag("-t", "--test") {
                let r = try Xipper.test(url, workload: workload, progress: progress, cancel: cancel)
                endProgress()
                for f in r.failures { print("FAILED \(f.path): \(f.reason)") }
                if !r.isOK { exit(3) }
                print("\(path): OK")
            } else if flag("-r", "--reindex") {
                let dest = value("-I", "--index-name").map { URL(fileURLWithPath: $0) }
                print(try Xipper.writeBGZFIndex(for: url, to: dest).path)
            } else if flag("--convert") {
                let r = try Xipper.convert(url, format: .bgzf, level: level, writeIndex: flag("-i", "--index"),
                                           workload: workload, progress: progress, cancel: cancel)
                endProgress()
                print("\(path): converted to BGZF (\(r.outputBytes.bytesText))")
                for s in r.staleIndexes { fputs("warning: \(s.lastPathComponent) no longer matches \(url.lastPathComponent): rebuild it (tabix/samtools index)\n", stderr) }
            } else if toStdout {
                try Xipper.stream(url, compress: !flag("-d", "--decompress"), level: level, workload: workload, cancel: cancel) { chunk in
                    var done = 0
                    while done < chunk.count {
                        let n = write(STDOUT_FILENO, chunk.baseAddress! + done, chunk.count - done)
                        if n < 0 { if errno == EINTR { continue }; throw XipperError.io("write", path: "stdout", errno: errno) }
                        done += n
                    }
                }
            } else if flag("-d", "--decompress") {
                let dest = try Xipper.decompressSingle(url, overwrite: force, workload: workload, progress: progress, cancel: cancel)
                endProgress()
                if !flag("-q", "--quiet") { print(dest.path) }
            } else {
                var o = CreateOptions()
                o.format = .bgzf
                o.level = level
                o.overwrite = force
                o.workload = workload
                o.writeBGZFIndex = flag("-i", "--index") && value("-I", "--index-name") == nil
                let dest = URL(fileURLWithPath: path + ".gz")
                let r = try Xipper.create(from: [url], to: dest, options: o, progress: progress, cancel: cancel)
                if let name = value("-I", "--index-name"), flag("-i", "--index") {
                    try Xipper.writeBGZFIndex(for: dest, to: URL(fileURLWithPath: name))
                }
                endProgress()
                if !flag("-q", "--quiet") {
                    print(String(format: "%@ → %@ (%.1f%%) in %.2fs", path, dest.lastPathComponent,
                                 r.inputBytes > 0 ? Double(r.outputBytes) / Double(r.inputBytes) * 100 : 0, r.elapsed))
                }
            }
        }
    }

case "help", "-h", "--help":
    print(usage)

case "version", "--version":
    print("xipper \(MCPServer.serverVersion) (XipperKit, arm64)")

default:
    fail("unknown command \(command)\n\(usage)", code: 2)
}

extension Int64 {
    var bytesText: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}

// MARK: - mcp

let mcpUsage = """
usage: xipper mcp [--allow DIR]... [--read-only] [--allow-password-argument] [--config FILE] [--no-audit] [-- DIR...]
       xipper mcp password set|delete NAME     store an archive password in the Keychain (agents use password_ref)
       xipper mcp password list
       xipper mcp install                      print how to register the server in Claude Code / Claude Desktop
       xipper mcp bundle [-o Xipper.mcpb]      build an MCP Bundle for Claude Desktop (contains this binary)

Runs a Model Context Protocol server on stdin/stdout. Agents can only touch files inside the
allowed folders (from --allow and from ~/Library/Application Support/Xipper/mcp.json).
Tool calls are logged to ~/Library/Logs/Xipper/mcp-audit.jsonl (no passwords, no file contents).
"""

func runMCP(_ args: [String]) -> Never {
    if args.first == "password" {
        guard args.count >= 2 else { fail(mcpUsage, code: 2) }
        switch (args[1], args.count) {
        case ("list", 2):
            PasswordStore.names().forEach { print($0) }
        case ("set", 3):
            var buf = [CChar](repeating: 0, count: 1024)
            guard readpassphrase("Password for \(args[2]): ", &buf, buf.count, RPP_ECHO_OFF | RPP_REQUIRE_TTY) != nil else { fail("cannot read password") }
            let pw = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            memset_s(&buf, buf.count, 0, buf.count)
            if pw.isEmpty { fail("empty password") }
            do { try PasswordStore.set(args[2], password: pw) } catch { fail("\(error)") }
            print("stored \"\(args[2])\": agents can now use password_ref: \"\(args[2])\"")
        case ("delete", 3):
            if !PasswordStore.delete(args[2]) { fail("no password named \(args[2])") }
        default:
            fail(mcpUsage, code: 2)
        }
        exit(0)
    }
    let me = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    if args.first == "install" {
        let exe = (try? FileManager.default.destinationOfSymbolicLink(atPath: me)) ?? me
        print("""
        Claude Code (all projects):
          claude mcp add --transport stdio --scope user xipper -- \(exe) mcp --allow ~/Documents

        Claude Desktop (~/Library/Application Support/Claude/claude_desktop_config.json):
          "mcpServers": { "xipper": { "command": "\(exe)", "args": ["mcp", "--allow", "\(NSHomeDirectory())/Documents"] } }

        Replace ~/Documents with the folders the assistant may use (repeat --allow for each).
        """)
        exit(0)
    }
    if args.first == "bundle" {
        let out = args.count >= 3 && args[1] == "-o" ? args[2] : "Xipper.mcpb"
        do { try buildBundle(executable: me, output: out) } catch { fail("\(error)") }
        print("\(out): open it with Claude Desktop (Settings › Extensions) to install")
        exit(0)
    }
    var configPath = MCPConfig.defaultConfigPath
    var extraRoots: [String] = []
    var readOnly = false, allowPassword = false, noAudit = false
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--allow":
            guard i + 1 < args.count else { fail("--allow needs a folder", code: 2) }
            extraRoots.append(args[i + 1]); i += 1
        case "--config":
            guard i + 1 < args.count else { fail("--config needs a file", code: 2) }
            configPath = args[i + 1]; i += 1
        case "--read-only": readOnly = true
        case "--read-only-value":  // for .mcpb user_config booleans ("true"/"false")
            guard i + 1 < args.count else { fail("--read-only-value needs true or false", code: 2) }
            readOnly = readOnly || args[i + 1] == "true"; i += 1
        case "--":
            extraRoots += args[(i + 1)...].filter { !$0.isEmpty }
            i = args.count
        case "--allow-password-argument": allowPassword = true
        case "--no-audit": noAudit = true
        case "-h", "--help": print(mcpUsage); exit(0)
        default: fail("unknown option \(args[i])\n\(mcpUsage)", code: 2)
        }
        i += 1
    }
    var config: MCPConfig
    do { config = try MCPConfig.load(path: configPath) } catch { fail("invalid config \(configPath): \(error)") }
    config.allowedRoots += extraRoots
    config.readOnly = config.readOnly || readOnly
    config.allowPasswordArgument = config.allowPasswordArgument || allowPassword
    if noAudit { config.auditLogPath = nil }
    if config.allowedRoots.isEmpty {
        fputs("xipper mcp: warning: no allowed folders; every file operation will be refused (use --allow DIR)\n", stderr)
    }
    fputs("xipper mcp \(MCPServer.serverVersion): serving on stdio, allowed: \(config.allowedRoots.joined(separator: ", "))\(config.readOnly ? " (read-only)" : "")\n", stderr)
    let final = config
    StdioTransport.run { send in MCPServer(config: final, send: send) }
    exit(0)
}

/// Writes an MCP Bundle (.mcpb, manifest 0.3): a zip with manifest.json and this binary.
func buildBundle(executable: String, output: String) throws {
    let stage = NSTemporaryDirectory() + "xipper-mcpb-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: stage) }
    try FileManager.default.createDirectory(atPath: stage + "/server", withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: executable, toPath: stage + "/server/xipper")
    let tools: [[String: String]] = [
        ["name": "archive_info", "description": "Format, entries, sizes and encryption of an archive"],
        ["name": "archive_list", "description": "List archive contents (paginated, glob filter)"],
        ["name": "archive_test", "description": "Verify archive integrity"],
        ["name": "archive_read_entry", "description": "Read one entry without extracting"],
        ["name": "archive_extract", "description": "Extract safely into an allowed folder"],
        ["name": "archive_create", "description": "Create zip / 7z / tar.* / gz / BGZF archives"],
        ["name": "bgzf_compress", "description": "Genomics: compress with BGZF (bgzip)"],
        ["name": "bgzf_check", "description": "Genomics: verify BGZF, BAM, BCF"],
        ["name": "bgzf_convert", "description": "Genomics: convert plain gzip to BGZF"],
        ["name": "genomics_index", "description": "Genomics: build tabix (.tbi) / CSI indexes of VCF, BED, GFF"],
        ["name": "genomics_check", "description": "Genomics: verify VCF.gz, BCF, BAM, CRAM and their indexes"],
        ["name": "checksum_manifest", "description": "Create and verify sha-256 / md5 / crc32c manifests (DRS names)"],
    ]
    let manifest: [String: Any] = [
        "manifest_version": "0.3",
        "name": "xipper",
        "display_name": "Xipper",
        "version": MCPServer.serverVersion,
        "description": "Create, list, verify and extract archives (zip, 7z, tar.*, gz, BGZF for genomics) on your Mac, only inside the folders you choose.",
        "author": ["name": "nicolorisitano82", "url": "https://github.com/nicolorisitano82/xipper"],
        "repository": ["type": "git", "url": "https://github.com/nicolorisitano82/xipper"],
        "license": "MIT",
        "server": [
            "type": "binary",
            "entry_point": "server/xipper",
            "mcp_config": [
                "command": "${__dirname}/server/xipper",
                "args": ["mcp", "--read-only-value", "${user_config.read_only}", "--", "${user_config.allowed_directories}"],
            ],
        ],
        "tools": tools,
        "user_config": [
            "allowed_directories": [
                "type": "directory", "title": "Allowed folders", "multiple": true, "required": true,
                "description": "Folders Claude may read archives from and write archives to. Everything else is refused.",
                "default": ["${DOCUMENTS}"],
            ],
            "read_only": [
                "type": "boolean", "title": "Read-only", "default": false,
                "description": "Only list, inspect and verify archives; never write files.",
            ],
        ],
        "compatibility": ["platforms": ["darwin"]],
    ]
    let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    FileManager.default.createFile(atPath: stage + "/manifest.json", contents: json)
    var o = CreateOptions()
    o.format = .zip
    o.overwrite = true
    try Xipper.create(from: [URL(fileURLWithPath: stage + "/manifest.json"), URL(fileURLWithPath: stage + "/server")],
                      to: URL(fileURLWithPath: output), options: o)
}
