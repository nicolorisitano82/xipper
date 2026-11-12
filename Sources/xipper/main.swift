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
                           xiz, gz, bz2, xz, zst
      -l, --level N        compression level (zip 1-12, zstd 1-22, xz/7z 0-9, bzip2 1-9)
      -m, --method M       zip method: deflate (default), zstd, bzip2, lzma, xz, deflate64, store
      -p, --password       encrypt (zip, 7z, xiz: AES-256; aar: AEA); prompts for the password
          --solid SIZE     7z solid block size (e.g. 64m, 2g; "off" = one block per file)
      -v, --volume SIZE    split into volumes of SIZE (7z: name.7z.001, .002, …; zip: name.z01, …, name.zip)
          --numbered       zip volumes as name.zip.001, .002, … (joined with cat)
          --plain-names    7z with a password: leave file names readable
          --no-dictionary  xiz: no zstd dictionary for small files
          --lzma2          xiz: LZMA2 frames (XIZ 1.4: ~10% smaller, slower to open; needs Xipper 2.6+)
          --lzraven        xiz: Apple LZRAVEN frames (XIZ 1.8: like LZMA2, opens ~3× faster; macOS 27+ and Xipper 3.0+ only)
          --lzmesh         xiz: Apple LZMESH frames (XIZ 1.8: zstd 9 ratio at zstd 3 speed; macOS 27+ and Xipper 3.0+ only)
          --jpeg           xiz: recompress JPEG photos losslessly (XIZ 1.6: ~20% smaller, rebuilt byte for byte; needs Xipper 2.7+)
          --documents      xiz: recompress the Deflate streams of PNG, PDF and Office/EPUB files losslessly
                           (XIZ 1.9, preflate: rebuilt byte for byte; needs Xipper 3.0+)
          --tables         xiz: compress CSV, TSV and BED tables column by column with OpenZL
                           (XIZ 1.11: 10-30% smaller than xz on numeric tables; needs Xipper 3.1+)
          --recovery N     xiz: append N percent of Reed–Solomon recovery data (XIZ 1.5, readable by any XIZ reader)
          --password-stdin read the password from the first line of stdin
          --zip64          always write ZIP64 structures
          --keep-mac-files keep .DS_Store, ._* and similar files
          --windows-names  zip, 7z: rename entries Windows cannot extract (a:b, why?, CON.txt, trailing dots, case clashes)
          --apple-double   zip: also store tags and attributes in __MACOSX/ (like the Finder)
          --recompress-all also compress files that are already compressed (photos, videos, archives)
          --no-bgzf        gz of genomic text: plain gzip instead of BGZF
          --bgzf-index     with BGZF output, also write the .gzi index
          --zipcrypto      zip: weak ZipCrypto instead of AES-256 (only for receivers without AES)
          --overwrite      replace an existing archive
  extract [options] <archive> [entry...]
      -d, --dest DIR       destination folder (default: next to the archive)
          --into           extract directly into DIR instead of a new folder
          --flatten        put every file directly in DIR, without the archive's folders
          --overwrite P    keep-both (default), replace, skip, fail
          --allow-external-symlinks
          --no-quarantine  do not copy the archive's quarantine attribute
      -r, --recursive [N]  also extract archives found inside, N levels deep (default 3); each goes
                           next to itself and is removed once extracted cleanly
          --keep-nested    with --recursive: keep the nested archives
      -p, --password / --password-stdin
  --version N            (extract, test, list, mount) XIZ: work on version N of the archive (see
                         `versions`); mount is then read-only
  --names-encoding ENC   (extract, test, list, convert, mount) code page of ZIP names written
                         without the UTF-8 flag, instead of the automatic guess: cp437, cp850,
                         cp866, windows1252, windows1251, shiftjis, gbk, big5, euckr
  test    [-p | --password-stdin] [--sha256] <archive>
          --sha256         also print a SHA256SUMS manifest of the content (sha256sum -c format)
  scrub   [--repair] <archive.xiz>   check every byte against the archive's recovery record; with
                         --repair, rebuild the damaged bytes in place (no password needed)
  recovery add [--redundancy N] | remove | info <archive.xiz>   the recovery record (N percent, default 10)
  repair  <archive.xiz>  same as scrub --repair
  repair  [-o FILE] [-p | --password-stdin] <archive.zip>   rebuild a damaged ZIP without recovery data:
                         the directory is rebuilt from the local headers, entries are copied without
                         recompressing, those failing their CRC are left out. The original is untouched
                         (default output: "name (riparato).zip").
  hash    [-a ALG[,ALG…]] [--contents] [--bsd] [-o LIST] <file|folder|archive>...
                         digests of files (folders walked), or with --contents of the files inside
                         archives. ALG: sha256 (default), sha512, sha3-256, blake3, xxh128, xxh3, sha1,
                         md5, crc32, crc32c. One algorithm prints sha256sum/b3sum lines, several print
                         BSD-tagged lines; -o writes a list (SHA256SUMS, B3SUMS, list.json for all).
  hash -c LIST           verify a list (sha256sum -c, b3sum -c, BSD tags, JSON manifests)
  list    [--long] [-p | --password-stdin] <archive>   (password: 7z with encrypted names)
  versions [-p | --password-stdin] <archive.xiz>   every version of an XIZ archive (one per change):
                         size, files, signer and date when signed, and with the password what changed
  update  [--dry-run] [-p | --password-stdin] <archive> <file|folder>...   bring the archive in line with
                         the sources as `create` stores them: new and changed files (size, time, link)
                         are added, missing ones removed; XIZ keeps the previous state as a version
  edit    [options] <archive>   change an archive in place (ZIP: untouched entries are not recompressed;
                                XIZ: changes are appended; other formats are rebuilt). Repeatable, in order:
          --delete PATH    remove a file or folder
          --rename OLD:NEW rename a file or folder
          --add FILE[:PATH]  add a file or folder from disk (folders merge, files replace)
          --mkdir PATH     add an empty folder
          --compact        XIZ: rewrite the archive, dropping deleted data
      -p, --password / --password-stdin
  convert [options] <archive>   change the format; entries whose codec both formats have keep their
                                compressed bytes (ZIP ↔ 7z: store, Deflate, Deflate64, bzip2, LZMA; 7z LZMA2
                                → ZIP xz; ZIP Deflate/bzip2/zstd/xz → tar.gz/.bz2/.zst/.xz), the rest is
                                recompressed. The new archive is verified before it gets its name.
          --to FMT         zip, 7z, tar, tar.gz, tar.bz2, tar.xz, tar.zst, aar, cpio, xiz (required)
      -o, --output FILE    the new archive (default: next to the original, with the new extension)
      -m, -l               method and level for recompressed entries
      -p, --password / --password-stdin   the original's password
          --encrypt        protect the new archive with a password (prompted)
          --dry-run        print the plan (what is copied, what is recompressed, space needed) and stop
          --json           plan or result as JSON
          --trash-original move the original to the Trash once the new archive is verified
          --accept-losses  go on when signatures, access groups or the password would be lost
          --overwrite      replace an existing file at the output path
          --lzma2, --lzraven, --lzmesh, --jpeg, --documents, --tables   XIZ: as in create
          --little-space   ZIP or 7z → XIZ when the disk cannot hold both archives: a batch at a time,
                           each batch's bytes released from the original once it is safe in the new
                           archive; the original is removed at the end. Interrupted (even by a power
                           cut), the same command resumes it
          --abandon        give up an interrupted --little-space conversion (only before any of the
                           original was released)
  par2    create [--redundancy N] <file> | verify <file.par2> | repair <file.par2>
          PAR2 recovery data (compatible with par2cmdline): N percent, default 10
  mount   [options] <archive>   mount as a volume (/Volumes/<name>) until ejected or Ctrl-C
          --read-only      do not allow changes
          --discard        drop the changes instead of saving them into the archive
          --at DIR         mount on DIR instead of /Volumes
          --no-quarantine  do not show the archive's quarantine attribute on the volume's items
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
\(xizUsage)
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
    : commonFlags.union(["-p", "--password", "--password-stdin", "--zip64", "--keep-mac-files", "--windows-names", "--overwrite", "--into",
                         "--allow-external-symlinks", "--no-quarantine", "--long", "--sha256", "--plain-names", "--no-dictionary", "--lzma2", "--lzraven", "--lzmesh", "--jpeg", "--documents", "--tables", "--apple-double", "--recompress-all", "--no-bgzf", "--bgzf-index", "--zipcrypto", "--flatten", "--contents", "--bsd", "-r", "--recursive", "--keep-nested",
                         "--read-only", "--discard", "--compact", "--numbered", "--signing", "--pq",
                         "--dry-run", "--json", "--encrypt", "--trash-original", "--accept-losses", "--repair", "--little-space", "--abandon"])
let valueOptions: Set<String> = command == "bgzip"
    ? ["-I", "--index-name", "-@", "-l", "--compress-level", "-j", "--threads"]
    : ["-f", "--format", "-l", "--level", "-m", "--method", "-d", "--dest", "-j", "--threads", "--overwrite", "-a", "--algorithm", "-c", "--check",
       "--solid", "-v", "--volume", "--at", "--redundancy", "--delete", "--rename", "--add", "--mkdir",
       "--recovery", "--access", "--identity", "--sign", "--signer", "--timestamp", "--aea-pem", "-o", "--output", "--keychain", "--to",
       "--names-encoding", "--version"]
do {
    var i = 0
    while i < args.count {
        let a = args[i]
        if a == "--" { positional += args[(i + 1)...]; break }
        if a.hasPrefix("-") && a.count > 1 {
            if a == "--overwrite" && (command == "create" || command == "convert") { flags.insert(a); i += 1; continue }
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

// ZIP names without the UTF-8 flag: the code page, instead of the automatic guess.
if let e = values["--names-encoding"], command != "bgzip" {
    guard let enc = ZipNameEncoding(rawValue: e.lowercased()) else {
        fputs("xipper: unknown --names-encoding \(e) (\(ZipNameEncoding.allCases.map(\.rawValue).joined(separator: ", ")))\n", stderr)
        exit(2)
    }
    for p in positional.prefix(1) { Xipper.setZipNameEncoding(enc, for: URL(fileURLWithPath: p)) }
}
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
        // Further lines: more passwords (custodians of an XIZ k-of-n group).
        while let more = readLine(strippingNewline: true) { if !more.isEmpty { XizCredentials.shared.add(password: more) } }
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
let sigint = cancelOnInterrupt(cancel)
loadXizIdentities()
if command == "keygen" { runKeygen() }
if command == "history" { runHistory() }
if command == "erase" { runErase() }
if command == "prove" { runProve() }
if command == "verify-proof" { runVerifyProof() }

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

func describe(_ i: XizRecoveryInfo) -> String {
    "recovery record: \(i.recordBytes.bytesText), \(i.recoverySlices) recovery slices for \(i.dataSlices) slices of \(Int64(i.sliceSize).bytesText) "
        + "(\(String(format: "%.0f", i.redundancy))%): repairs up to \(i.recoverySlices) damaged places, \((Int64(i.recoverySlices) * Int64(i.sliceSize)).bytesText) in all"
}

/// scrub and repair of XIZ archives with a recovery record; exit 3 when damage remains.
func scrub(_ file: URL, repair: Bool) throws {
    let r = try Xipper.scrubXiz(file, repair: repair, progress: progress, cancel: cancel)
    endProgress()
    guard let info = r.info else {
        print("no recovery record (add one with: xipper recovery add \(file.lastPathComponent))")
        exit(3)
    }
    print(describe(info))
    for range in r.damagedRanges { print("DAMAGED bytes \(range.lowerBound)–\(range.upperBound - 1)") }
    if r.damagedRecoverySlices > 0 { print("DAMAGED \(r.damagedRecoverySlices) recovery slices") }
    if r.damagedMetadata > 0 { print("DAMAGED \(r.damagedMetadata) of 3 copies of the record's index") }
    if r.isClean { print("all bytes intact"); return }
    if r.repaired { print("repaired"); return }
    print(r.repairable ? "repair possible: run xipper scrub --repair" : "repair NOT possible: \(r.damagedRanges.count) damaged slices, only \(info.recoverySlices - r.damagedRecoverySlices) intact recovery slices")
    exit(3)
}


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

/// `--version N`: runs `body` on that version of the XIZ archive (a clone next to it), else on the archive.
@MainActor func versioned<T>(_ archive: URL, _ body: (URL) throws -> T) throws -> T {
    guard let v = value("--version") else { return try body(archive) }
    guard let n = Int(v), n >= 1 else { fail("--version needs a number from 1", code: 2) }
    return try Xipper.withXizVersion(archive, number: n, body)
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
    if let m = value("-m", "--method") {
        guard let method = ZipMethod(name: m) else { fail("unknown method \(m)", code: 2) }
        o.zipMethod = method
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
    if flag("--numbered") { o.zipVolumeStyle = .numbered }
    o.encryptFileNames = !flag("--plain-names")
    o.xizDictionary = !flag("--no-dictionary")
    if flag("--jpeg") {
        if o.format != .xiz { fail("--jpeg needs the xiz format", code: 2) }
        o.xizJPEG = true
    }
    if flag("--documents") {
        if o.format != .xiz { fail("--documents needs the xiz format", code: 2) }
        o.xizDocuments = true
    }
    if flag("--tables") {
        if o.format != .xiz { fail("--tables needs the xiz format", code: 2) }
        o.xizTables = true
    }
    if flag("--lzma2") {
        if o.format != .xiz { fail("--lzma2 needs the xiz format", code: 2) }
        o.xizCodec = .lzma2
    }
    for (name, codec) in [("--lzraven", XizCodec.lzraven), ("--lzmesh", .lzmesh)] where flag(name) {
        if o.format != .xiz { fail("\(name) needs the xiz format", code: 2) }
        if !XizCodec.appleCodecsAvailable { fail("\(name) needs macOS 27 or later", code: 2) }
        o.xizCodec = codec
    }

    if let v = value("--recovery") {
        guard o.format == .xiz else { fail("--recovery needs the xiz format (other formats: xipper par2 create)", code: 2) }
        guard let pct = Double(v.hasSuffix("%") ? String(v.dropLast()) : v), pct > 0, pct <= 100 else { fail("invalid recovery percent (1-100)", code: 2) }
        o.xizRecovery = pct
    }
    o.overwrite = flag("--overwrite")
    o.zipAppleDouble = flag("--apple-double")
    o.storeAlreadyCompressed = !flag("--recompress-all")
    o.genomicsUsesBGZF = !flag("--no-bgzf")
    o.writeBGZFIndex = flag("--bgzf-index")
    o.legacyZipCrypto = flag("--zipcrypto")
    o.scan.excludeMacMetadata = !flag("--keep-mac-files")
    o.windowsCompatibleNames = flag("--windows-names")
    if o.windowsCompatibleNames && o.format != .zip && o.format != .sevenZip { fail("--windows-names needs the zip or 7z format", code: 2) }
    o.workload = workload
    if let p = value("--access") {
        guard o.format == .xiz else { fail("--access needs the xiz format", code: 2) }
        o.xizAccess = loadAccessPolicy(p)
    }
    o.xizSigner = xizSigner()
    if o.xizSigner != nil && o.format != .xiz && o.format != .appleArchive { fail("--sign needs the xiz or aar format", code: 2) }
    if o.xizSigner?.timestampURL != nil && o.format == .appleArchive { fail("--timestamp is for xiz only (AEA has no place for it)", code: 2) }
    o.password = o.xizAccess != nil && !flag("-p", "--password", "--password-stdin") ? nil : readPassword(confirm: true)
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
        if r.renamedForWindows > 0 { print("\(r.renamedForWindows) names changed for Windows") }
    }

case "extract", "x":
    guard positional.count >= 1 else { fail("extract needs an archive", code: 2) }
    var o = ExtractOptions()
    o.workload = workload
    o.propagateQuarantine = !flag("--no-quarantine")
    o.flatten = flag("--flatten")
    if flag("--allow-external-symlinks") { o.symlinks = .allowAll }
    switch value("--overwrite") {
    case nil, "keep-both": o.overwrite = .keepBoth
    case "replace": o.overwrite = .replace
    case "skip": o.overwrite = .skip
    case "fail": o.overwrite = .fail
    case let p?: fail("unknown overwrite policy \(p)", code: 2)
    }
    if flag("-r") || flag("--recursive") {
        // An optional depth after the flag arrives as a positional argument (a number that is not a file).
        if let i = positional.firstIndex(where: { Int($0) != nil && !FileManager.default.fileExists(atPath: $0) }), i <= 1 {
            let n = Int(positional[i])!
            guard (1...16).contains(n) else { fail("--recursive depth must be 1-16", code: 2) }
            o.nestedDepth = n
            positional.remove(at: i)
        } else {
            o.nestedDepth = 3
        }
        o.keepNestedArchives = flag("--keep-nested")
    }
    guard !positional.isEmpty else { fail("extract needs an archive", code: 2) }
    let archive = URL(fileURLWithPath: positional[0])
    if positional.count > 1 { o.selection = Set(positional.dropFirst()) }
    o.password = readPassword(confirm: false)
    // A version is read from a temporary clone: by default it goes next to the archive, not the clone.
    let dest = value("-d", "--dest").map { URL(fileURLWithPath: $0) } ?? (value("--version") != nil ? archive.deletingLastPathComponent() : nil)
    run {
        let r = try versioned(archive) { try Xipper.extract($0, to: dest, mode: flag("--into") ? .into : .smart, options: o,
                                                            progress: progress, cancel: cancel) }
        endProgress()
        print("\(r.destination.path): \(r.files) files, \(r.directories) folders, \(r.symlinks) links, \(r.bytes.bytesText) in \(String(format: "%.2f", r.elapsed))s")
        if !r.nested.isEmpty { print("nested archives extracted: \(r.nested.count)") }
        for s in r.skipped { fputs("skipped \(s.path): \(s.reason)\n", stderr) }
        for d in r.deceptive {
            fputs("warning: deceptive name \(DeceptiveName.visible(d)): \(describe(DeceptiveName.check(path: d)!.reason))\n", stderr)
        }
        if !r.skipped.isEmpty { exit(3) }
    }

case "test", "t":
    guard positional.count == 1 else { fail("test needs one archive", code: 2) }
    let pw = readPassword(confirm: false)
    run {
        let sums = flag("--sha256")
        let r = try versioned(URL(fileURLWithPath: positional[0])) {
            try Xipper.test($0, password: pw, workload: workload, digests: sums, progress: progress, cancel: cancel)
        }
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

case "hash":
    run {
        if let list = value("-c", "--check") {
            let r = try Xipper.verifyManifest(URL(fileURLWithPath: list), algorithm: value("-a", "--algorithm").flatMap(ChecksumAlgorithm.init(name:)),
                                              workload: workload, progress: progress, cancel: cancel)
            endProgress()
            for m in r.mismatches { print("\(m.path): FAILED (\(m.algorithm.title))") }
            for m in r.missing { print("\(m): MISSING") }
            for m in r.refused { print("\(m): REFUSED (absolute path or ..)") }
            for m in r.sizeMismatches { print("\(m): SIZE DIFFERS") }
            print(r.isOK ? "OK: \(r.checked) files, \(r.bytes.bytesText) verified" : "\(r.mismatches.count + r.missing.count) of \(r.checked + r.missing.count) files do not match")
            if !r.isOK { exit(3) }
            return
        }
        guard !positional.isEmpty else { fail("hash needs files, folders or archives", code: 2) }
        var algorithms: [ChecksumAlgorithm] = []
        for n in (value("-a", "--algorithm") ?? "sha256").split(separator: ",") {
            guard let a = ChecksumAlgorithm(name: String(n)) else { fail("unknown algorithm \(n)", code: 2) }
            algorithms.append(a)
        }
        let urls = positional.map { URL(fileURLWithPath: $0) }
        var entries: [ManifestEntry] = []
        if flag("--contents") {
            let pw = readPassword(confirm: false)
            for u in urls {
                let inner = try Xipper.hashContents(u, algorithms: algorithms, password: pw, workload: workload, progress: progress, cancel: cancel)
                entries += urls.count > 1 ? inner.map { var e = $0; e.path = u.lastPathComponent + "/" + e.path; return e } : inner
            }
        } else {
            entries = try Xipper.hashFiles(urls, algorithms: algorithms, workload: workload, progress: progress, cancel: cancel)
        }
        endProgress()
        if let out = value("-o", "--output") {
            // A list file: written next to its files, paths relative to it (createManifest).
            if flag("--contents") {
                try Xipper.checksumLines(entries, algorithms: algorithms, bsd: flag("--bsd")).write(toFile: out, atomically: true, encoding: .utf8)
            } else {
                try Xipper.createManifest(of: urls, to: URL(fileURLWithPath: out), algorithms: algorithms, overwrite: true,
                                          workload: workload, cancel: cancel)
            }
            print("\(out): \(entries.count) files")
        } else {
            print(Xipper.checksumLines(entries, algorithms: algorithms, bsd: flag("--bsd")), terminator: "")
        }
    }

case "scrub":
    guard positional.count == 1 else { fail("scrub needs one XIZ archive", code: 2) }
    run { try scrub(URL(fileURLWithPath: positional[0]), repair: flag("--repair")) }

case "recovery":
    guard positional.count == 2, ["add", "remove", "info"].contains(positional[0]) else {
        fail("recovery needs add, remove or info and a XIZ archive", code: 2)
    }
    run {
        let file = URL(fileURLWithPath: positional[1])
        switch positional[0] {
        case "add":
            guard let pct = Double(value("--redundancy") ?? "10"), pct > 0, pct <= 100 else { fail("invalid redundancy (1-100)", code: 2) }
            let info = try Xipper.addXizRecovery(file, redundancy: pct, progress: progress, cancel: cancel)
            endProgress()
            print(describe(info))
        case "remove":
            print(try Xipper.removeXizRecovery(file) ? "recovery record removed" : "no recovery record")
        default:
            guard let info = Xipper.xizRecoveryInfo(file) else { print("no recovery record"); exit(3) }
            print(describe(info))
        }
    }

case "repair" where positional.first.map({ $0.lowercased().hasSuffix(".xiz") }) ?? false:
    guard positional.count == 1 else { fail("repair needs one archive", code: 2) }
    run { try scrub(URL(fileURLWithPath: positional[0]), repair: true) }

case "repair":
    guard positional.count == 1 else { fail("repair needs one ZIP archive", code: 2) }
    let pw = readPassword(confirm: false)
    run {
        let r = try Xipper.repairZip(URL(fileURLWithPath: positional[0]), to: value("-o", "--output").map { URL(fileURLWithPath: $0) },
                                     password: pw, progress: progress, cancel: cancel)
        endProgress()
        for p in r.lost { print("LOST \(p)") }
        for p in r.superseded { print("OLDER COPY \(p)") }
        for p in r.unverified { print("NOT VERIFIED (encrypted) \(p)") }
        print("\(r.output.lastPathComponent): \(r.recovered) entries recovered, \(r.lost.count) lost, in \(String(format: "%.2f", r.elapsed))s")
        if !r.lost.isEmpty { exit(3) }
    }

case "list", "l":
    guard positional.count == 1 else { fail("list needs one archive", code: 2) }
    let pw = readPassword(confirm: false)
    run {
        let entries = try versioned(URL(fileURLWithPath: positional[0])) { try Xipper.list($0, password: pw, workload: workload) }
        if let access = try? Xipper.xizAccess(URL(fileURLWithPath: positional[0]), password: pw), access.hidden > 0 {
            fputs("xipper: \(access.hidden) access group(s) of this archive are not opened by these credentials\n", stderr)
        }
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

case "versions":
    guard positional.count == 1 else { fail("versions needs one archive", code: 2) }
    let pw = readPassword(confirm: false)
    run {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        for v in try Xipper.xizVersions(URL(fileURLWithPath: positional[0]), password: pw) {
            var line = "\(String(v.number).leftPad(4))  \(v.size.bytesText.leftPad(10))  \(String(v.entries).leftPad(7)) entries  \(v.totalBytes.bytesText.leftPad(10))"
            if let a = v.added, let c = v.changed, let r = v.removed { line += "  +\(a) ~\(c) -\(r)" }
            if let s = v.signer { line += "  signed by \(s)\(v.date.map { " on " + df.string(from: $0) } ?? "")" }
            print(line)
        }
    }

case "update":
    guard positional.count >= 2 else { fail("update needs an archive and at least one source", code: 2) }
    let pw = readPassword(confirm: false)
    run {
        let archive = URL(fileURLWithPath: positional[0])
        let sources = positional.dropFirst().map { URL(fileURLWithPath: $0) }
        var o = CreateOptions()
        o.xizSigner = xizSigner()
        if flag("--dry-run") {
            let plan = try Xipper.updatePlan(archive, from: sources, password: pw, options: o)
            for p in plan.added { print("+ \(p)") }
            for p in plan.changed { print("~ \(p)") }
            for p in plan.removed { print("- \(p)") }
            print(plan.isEmpty ? "up to date" : "\(plan.added.count) to add, \(plan.changed.count) changed, \(plan.removed.count) to remove")
            return
        }
        let (plan, report) = try Xipper.update(archive, from: sources, password: pw, options: o, progress: progress, cancel: cancel)
        endProgress()
        guard let report else { print("\(archive.lastPathComponent): up to date"); return }
        print("\(archive.lastPathComponent): \(plan.added.count) added, \(plan.changed.count) changed, \(plan.removed.count) removed; \(report.entries) entries, \(report.outputBytes.bytesText)")
    }

case "edit":
    guard positional.count == 1 else { fail("edit needs one archive", code: 2) }
    // The changes, in the order given (the generic parser keeps only the last value of each option).
    var changes: [ArchiveChange] = []
    var k = 0
    while k + 1 < args.count {
        let (opt, v) = (args[k], args[k + 1])
        switch opt {
        case "--delete": changes.append(.delete(v)); k += 2
        case "--mkdir": changes.append(.makeDirectory(v)); k += 2
        case "--rename":
            guard let c = v.firstIndex(of: ":") else { fail("--rename needs OLD:NEW", code: 2) }
            changes.append(.rename(String(v[..<c]), to: String(v[v.index(after: c)...]))); k += 2
        case "--add":
            // FILE or FILE:PATH; a ":" that belongs to the file name needs the PATH part.
            let parts = v.split(separator: ":", maxSplits: 1).map(String.init)
            let url = URL(fileURLWithPath: parts[0])
            changes.append(.add(url, as: parts.count > 1 ? parts[1] : url.lastPathComponent)); k += 2
        default: k += 1
        }
    }
    guard !changes.isEmpty || flag("--compact") else { fail("edit needs at least one change", code: 2) }
    let pw = readPassword(confirm: false)
    run {
        let archive = URL(fileURLWithPath: positional[0])
        var o = CreateOptions()
        o.xizSigner = xizSigner()
        let r = try Xipper.edit(archive, changes: changes, password: pw, options: o, compact: flag("--compact"), progress: progress, cancel: cancel)
        endProgress()
        print("\(archive.lastPathComponent): \(r.entries) entries, \(r.copied) kept as they were, \(r.compressed) written\(r.rebuilt ? " (rebuilt)" : ""), \(r.outputBytes.bytesText)")
    }

case "convert":
    guard positional.count == 1 else { fail("convert needs one archive", code: 2) }
    guard let to = value("--to"), let fmt = ArchiveFormat(rawValue: to.lowercased()) else {
        fail("convert needs --to FORMAT (zip, 7z, tar.zst, xiz, aar, …)", code: 2)
    }
    let source = URL(fileURLWithPath: positional[0])
    var o = CreateOptions()
    o.format = fmt
    if fmt == .xiz {
        if flag("--lzma2") { o.xizCodec = .lzma2 }
        if flag("--lzraven") { o.xizCodec = .lzraven }
        if flag("--lzmesh") { o.xizCodec = .lzmesh }
        o.xizJPEG = flag("--jpeg")
        o.xizDocuments = flag("--documents")
        o.xizTables = flag("--tables")
    }
    if flag("--abandon") {
        run {
            guard let s = Xipper.interruptedConversion(of: source) else { fail("no interrupted conversion of \(source.lastPathComponent)") }
            try Xipper.abandonConversion(s.journal)
            print("\(source.lastPathComponent): conversion abandoned, the original is as it was")
        }
    }
    if !flag("--little-space"), let s = Xipper.interruptedConversion(of: source) {
        fail("\(source.lastPathComponent): a conversion to \(s.target.lastPathComponent) was interrupted (\(s.batchesDone) of \(s.batches) batches): "
             + "run it again with --little-space to finish it" + (s.released ? "" : ", or give it up with --abandon"), code: 2)
    }
    if let l = value("-l", "--level") { guard let n = Int(l) else { fail("invalid level \(l)", code: 2) }; o.level = n }
    if let m = value("-m", "--method") {
        guard let method = ZipMethod(name: m) else { fail("unknown method \(m)", code: 2) }
        o.zipMethod = method
    }
    o.overwrite = flag("--overwrite")
    o.workload = workload
    let target: URL = value("-o", "--output").map { URL(fileURLWithPath: $0) } ?? {
        var name = source.lastPathComponent
        if let f = try? ArchiveFormat.detect(source), name.lowercased().hasSuffix("." + f.fileExtension) {
            name.removeLast(f.fileExtension.count + 1)
        } else {
            name = (name as NSString).deletingPathExtension
        }
        return source.deletingLastPathComponent().appendingPathComponent(name + "." + fmt.fileExtension)
    }()
    let pw = readPassword(confirm: false)
    if flag("--encrypt") {
        guard fmt.supportsPassword else { fail("\(fmt.rawValue) has no password protection", code: 2) }
        var buf = [CChar](repeating: 0, count: 1024), again = [CChar](repeating: 0, count: 1024)
        guard readpassphrase("New password: ", &buf, buf.count, RPP_ECHO_OFF | RPP_REQUIRE_TTY) != nil,
              readpassphrase("Repeat new password: ", &again, again.count, RPP_ECHO_OFF | RPP_REQUIRE_TTY) != nil else { fail("cannot read password") }
        let a = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let b = String(decoding: again.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        memset_s(&buf, buf.count, 0, buf.count); memset_s(&again, again.count, 0, again.count)
        guard !a.isEmpty, a == b else { fail("passwords empty or different") }
        o.password = a
    }
    if flag("--little-space") {
        run {
            if let s = Xipper.interruptedConversion(of: source) {
                print("\(source.lastPathComponent) → \(s.target.lastPathComponent): resuming (\(s.batchesDone) of \(s.batches) batches done)")
                let r = try Xipper.resumeConversion(s.journal, password: pw, newPassword: o.password, progress: progress, cancel: cancel)
                endProgress()
                print(String(format: "%@: %@, verified, in %.2fs; original removed", r.output.lastPathComponent, r.outputBytes.bytesText, r.elapsed))
                return
            }
            if let problem = Xipper.lowSpaceConversionProblem(source, to: fmt, password: pw) { fail(problem) }
            print("\(source.lastPathComponent) → \(target.lastPathComponent): converting a batch at a time; the original is released as it goes and removed at the end")
            let r = try Xipper.convertWithLittleSpace(source, to: target, password: pw, options: o, progress: progress, cancel: cancel)
            endProgress()
            if flag("--json") {
                let json: [String: Any] = ["output": r.output.path, "outputBytes": r.outputBytes, "elapsed": r.elapsed, "originalRemoved": true]
                print(String(decoding: try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
            } else {
                print(String(format: "%@: %@, verified, in %.2fs; original removed", r.output.lastPathComponent, r.outputBytes.bytesText, r.elapsed))
            }
        }
    }
    run {
        let plan = try Xipper.conversionPlan(source, to: fmt, password: pw, options: o)
        func lossText(_ l: ConversionPlan.Loss) -> String {
            switch l {
            case .signatures: return "signatures (the new archive is not signed)"
            case .accessGroups: return "XIZ access groups (everything under one password, or none)"
            case let .recoveryData(f): return "recovery data \(f) (protects the original only)"
            case .encryption: return "the password (the new archive is not encrypted)"
            }
        }
        if flag("--json") && flag("--dry-run") {
            let json: [String: Any] = [
                "source": source.path, "target": target.path, "from": plan.sourceFormat.rawValue, "to": fmt.rawValue,
                "copied": plan.copied, "recompressed": plan.recompressed, "bytesCopied": plan.bytesCopied,
                "bytesRecompressed": plan.bytesRecompressed, "spaceNeeded": plan.spaceNeeded, "losses": plan.losses.map(lossText),
                "items": plan.items.map { ["path": $0.path, "action": $0.action.rawValue, "size": $0.size, "reason": ($0.reason as Any?) ?? NSNull()] as [String: Any] },
            ]
            print(String(decoding: try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
            return
        }
        print("\(source.lastPathComponent) → \(target.lastPathComponent): \(plan.copied) entries copied (\(plan.bytesCopied.bytesText)), "
              + "\(plan.recompressed) recompressed (\(plan.bytesRecompressed.bytesText)), up to \(plan.spaceNeeded.bytesText) of free space needed")
        for l in plan.losses { print("  lost: \(lossText(l))") }
        if flag("--dry-run") {
            for i in plan.items { print("  \(i.action == .copied ? "copy " : "recomp") \(i.path)\(i.reason.map { "  (\($0))" } ?? "")") }
            return
        }
        let serious = plan.losses.filter { if case .recoveryData = $0 { false } else { true } }
        if !serious.isEmpty && !flag("--accept-losses") { fail("the new archive would lose what is listed above: add --accept-losses to go on", code: 2) }
        let r = try Xipper.convert(source, to: target, password: pw, options: o, trashOriginal: flag("--trash-original"),
                                   progress: progress, cancel: cancel)
        endProgress()
        if flag("--json") {
            let json: [String: Any] = ["output": r.output.path, "outputBytes": r.outputBytes, "copied": r.plan.copied,
                                       "recompressed": r.plan.recompressed, "elapsed": r.elapsed, "originalTrashed": r.originalTrashed]
            print(String(decoding: try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        } else {
            print(String(format: "%@: %@, verified, in %.2fs%@", r.output.lastPathComponent, r.outputBytes.bytesText, r.elapsed,
                         r.originalTrashed ? "; original moved to the Trash" : ""))
        }
    }

case "par2":
    guard positional.count == 2, ["create", "verify", "repair"].contains(positional[0]) else {
        fail("par2 needs create, verify or repair and a file", code: 2)
    }
    run {
        let file = URL(fileURLWithPath: positional[1])
        func show(_ r: PAR2.Report) {
            for f in r.files {
                let moved = f.movedSlices > 0 ? ", \(f.movedSlices) found moved" : ""
                print("\(f.missing ? "MISSING" : f.damagedSlices == 0 ? "OK     " : "DAMAGED") \(f.name)\(f.damagedSlices > 0 && !f.missing ? " (\(f.damagedSlices) of \(f.slices) slices\(moved))" : "")")
            }
            print(r.isIntact ? "all files are intact (\(r.recoverySlices) recovery slices available)"
                  : r.canRepair ? "repair possible: \(r.missingSlices) missing slices, \(r.recoverySlices) recovery slices"
                  : "repair NOT possible: \(r.missingSlices) missing slices, only \(r.recoverySlices) recovery slices")
        }
        switch positional[0] {
        case "create":
            guard let pct = Double(value("--redundancy") ?? "10"), pct > 0, pct <= 100 else { fail("invalid redundancy (1-100)", code: 2) }
            let written = try PAR2.create(for: [file], redundancy: pct, progress: progress, cancel: cancel)
            endProgress()
            for w in written { print("wrote \(w.lastPathComponent)") }
        case "verify":
            let r = try PAR2.verify(file, cancel: cancel)
            show(r)
            if !r.isIntact { exit(3) }
        default:
            let r = try PAR2.repair(file, progress: progress, cancel: cancel)
            endProgress()
            show(r)
        }
    }

case "mount":
    guard positional.count == 1 else { fail("mount needs one archive", code: 2) }
    let pw = readPassword(confirm: false)
    run {
        let archive = URL(fileURLWithPath: positional[0])
        if value("--version") != nil {  // an earlier version: read-only, from a clone removed on unmount
            try versioned(archive) { clone in
                let m = try ArchiveMount(archive: clone, password: pw, writable: false, propagateQuarantine: !flag("--no-quarantine"))
                let point = try m.mount(at: value("--at").map { URL(fileURLWithPath: $0, isDirectory: true) })
                print("mounted version \(value("--version")!) of \(archive.lastPathComponent) on \(point.path) (read-only)")
                m.waitUntilUnmounted(cancel: cancel)
                if m.isMounted { try? m.unmount(); m.waitUntilUnmounted() }
                try m.finish(save: false, progress: nil)
                print("unmounted")
            }
            return
        }
        let m = try ArchiveMount(archive: archive, password: pw, writable: !flag("--read-only"),
                                 propagateQuarantine: !flag("--no-quarantine"))
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
        ["name": "genomics_index", "description": "Genomics: build .bai/.csi, .crai, .fai and tabix indexes"],
        ["name": "cram_convert", "description": "Genomics: convert BAM ↔ CRAM 3.1 with a reference FASTA"],
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

func describe(_ r: DeceptiveName.Reason) -> String {
    switch r {
    case .bidiControl: return "contains right-to-left control characters that disguise its end"
    case let .doubleExtension(shown, real): return "looks like .\(shown) but is .\(real)"
    case let .paddedExtension(real): return "spaces hide its real extension .\(real)"
    }
}
