// xipper — command line front end for XipperKit.
// Hand-written argument parsing: the CLI ships inside Xipper.app with no dependencies.
import Darwin
import Foundation
import XipperKit

let usage = """
usage: xipper <command> [options]

  create  [options] <archive> <file|folder>...
      -f, --format FMT     zip (default from name), tar, tar.gz, tar.bz2, tar.xz, tar.zst, gz, bz2, xz, zst
      -l, --level N        compression level (zip 1-12, zstd 1-22, xz 0-9, bzip2 1-9)
      -m, --method M       zip method: deflate (default), zstd, store
      -p, --password       encrypt (zip, AES-256); prompts for the password
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
  test    [-p | --password-stdin] <archive>
  list    [--long] <archive>

common options:
  -j, --threads N          worker threads (default: performance cores)
      --background         run on efficiency cores at low priority
  -q, --quiet              no progress output
"""

struct Usage: Error { let message: String }

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(2) }
args.removeFirst()

// MARK: argument helpers

var flags = Set<String>()
var values: [String: String] = [:]
var positional: [String] = []
let knownFlags: Set<String> = ["-p", "--password", "--password-stdin", "--zip64", "--keep-mac-files", "--overwrite", "--into",
                                "--allow-external-symlinks", "--no-quarantine", "--long", "--background", "-q", "--quiet",
                                "-h", "--help"]
let valueOptions: Set<String> = ["-f", "--format", "-l", "--level", "-m", "--method", "-d", "--dest", "-j", "--threads", "--overwrite"]
do {
    var i = 0
    while i < args.count {
        let a = args[i]
        if a == "--" { positional += args[(i + 1)...]; break }
        if a.hasPrefix("-") && a.count > 1 {
            if valueOptions.contains(a) {
                guard i + 1 < args.count else { throw Usage(message: "\(a) needs a value") }
                values[a] = args[i + 1]
                i += 2
                continue
            }
            if a == "--overwrite" && command == "create" { flags.insert(a); i += 1; continue }
            guard knownFlags.contains(a) else { throw Usage(message: "unknown option \(a)") }
            flags.insert(a)
        } else {
            positional.append(a)
        }
        i += 1
    }
    // `create --overwrite` is a flag, `extract --overwrite P` takes a value.
    if command == "create", let v = values.removeValue(forKey: "--overwrite") {
        flags.insert("--overwrite")
        positional.insert(v, at: 0)
    }
} catch let u as Usage {
    fputs("xipper: \(u.message)\n", stderr)
    exit(2)
}

@MainActor func value(_ names: String...) -> String? { names.lazy.compactMap { values[$0] }.first }
@MainActor func flag(_ names: String...) -> Bool { names.contains { flags.contains($0) } }

func fail(_ message: String, code: Int32 = 1) -> Never {
    fputs("xipper: \(message)\n", stderr)
    exit(code)
}

let workload: Workload = {
    if let j = value("-j", "--threads") {
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
    o.overwrite = flag("--overwrite")
    o.scan.excludeMacMetadata = !flag("--keep-mac-files")
    o.workload = workload
    o.password = readPassword(confirm: true)
    if let pw = o.password, pw.utf8.contains(where: { $0 >= 0x80 }) {
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
        let r = try Xipper.test(URL(fileURLWithPath: positional[0]), password: pw, workload: workload, progress: progress, cancel: cancel)
        endProgress()
        for f in r.failures { print("FAILED \(f.path): \(f.reason)") }
        print(r.isOK ? "OK: \(r.entries) entries, \(r.bytes.bytesText) verified in \(String(format: "%.2f", r.elapsed))s"
                     : "\(r.failures.count) of \(r.entries) entries failed")
        if !r.isOK { exit(3) }
    }

case "list", "l":
    guard positional.count == 1 else { fail("list needs one archive", code: 2) }
    run {
        let entries = try Xipper.list(URL(fileURLWithPath: positional[0]), workload: workload)
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

case "help", "-h", "--help":
    print(usage)

case "version", "--version":
    print("xipper 0.1.0 (XipperKit, arm64)")

default:
    fail("unknown command \(command)\n\(usage)", code: 2)
}

extension Int64 {
    var bytesText: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}
