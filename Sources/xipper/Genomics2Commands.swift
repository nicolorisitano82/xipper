// Genomics 2 commands (STUDIO.md §4.6): tabix/CSI indexes, index and file checks, checksum manifests.
import Darwin
import Foundation
import XipperKit

let genomics2Commands: Set<String> = ["tabix", "index-check", "manifest", "cram", "index"]

let genomics2Usage = """
  tabix   [options] <file.gz>...  build a tabix (.tbi) or CSI index (htslib-compatible)
      -p, --preset P       vcf, bed, gff, sam (default: from the file name)
      -C, --csi            CSI index (positions beyond 512 Mbp);  -m, --min-shift N (default 14)
      -s, --sequence N  -b, --begin N  -e, --end N   1-based columns for other formats
      -0, --zero-based     coordinates are 0-based half-open (BED-like);  -c, --comment C (default #)
      -S, --skip-lines N   skip the first N lines
          --bgzip          compress an uncompressed file with BGZF first (FILE → FILE.gz)
      -f, --force          overwrite an existing index
  index-check [options] <file>...  verify data files and their indexes
      (data file)          VCF.gz, BCF, BAM, CRAM or BGZF: blocks, headers, CRAM CRCs and EOF
                           container, plus every .tbi/.csi/.bai/.gzi/.crai next to it
      (index file)         .tbi, .csi, .bai, .gzi, .crai against its data file
          --data FILE      data file of the index (default: from the index name)
          --no-index       do not look for indexes next to data files
  manifest create [options] -o MANIFEST <file|folder>...
      -o, --output FILE    .sha256, .md5 (md5sum), .crc32c, .sha512, … or .json (DRS fields)
      -a, --algorithms L   comma-separated: sha-256, md5, crc32c, sha-512, sha-1, sha512t24u
                           (default: from the name; JSON: sha-256,md5,crc32c)
      -f, --force          overwrite an existing manifest
  manifest verify [-a ALGO] <manifest>...   .json, sha256sum/md5sum or BSD-style text
  index   [options] <file>...    the usual index, as htslib tools build it:
                           BAM → .bai (-C: .csi), CRAM → .crai, BCF → .csi, FASTA/FASTQ → .fai (+ .gzi),
                           VCF/BED/GFF/SAM .gz → .tbi (-C: .csi)
      -C, --csi            CSI instead of .bai/.tbi;  -m, --min-shift N (default 14)
      -o, --output FILE    index path (one input only)
  cram    [options] <file.bam|file.cram>...   BAM → CRAM 3.1, or CRAM 3.0/3.1 → BAM
      -r, -T, --reference FASTA   reference (uncompressed, .fai used if present); required for BAM → CRAM
      -o, --output FILE    output (default: same name with .cram or .bam)
          --version 3.0    write CRAM 3.0 (rANS 4x8 and gzip only, for older readers)
          --no-md          CRAM → BAM: do not add the MD/NM tags samtools regenerates
      -f, --force          overwrite the output
"""

@MainActor func runGenomics2(_ command: String, _ rawArgs: [String]) -> Never {
    var args = rawArgs
    var sub = ""
    if command == "manifest" {
        guard let s = args.first, ["create", "verify"].contains(s) else { fail("usage: xipper manifest create|verify …\n\(genomics2Usage)", code: 2) }
        sub = s
        args.removeFirst()
    }
    let valueOptions: Set<String> = ["-p", "--preset", "-m", "--min-shift", "-s", "--sequence", "-b", "--begin", "-e", "--end",
                                     "-c", "--comment", "-S", "--skip-lines", "--data", "-o", "--output", "-a", "--algorithms",
                                     "-r", "-T", "--reference", "--version",
                                     "-j", "--threads"]
    let flagOptions: Set<String> = ["-C", "--csi", "-0", "--zero-based", "--bgzip", "-f", "--force", "--no-index",
                                    "-q", "--quiet", "--background", "-h", "--help", "--no-md"]
    var flags = Set<String>(), values: [String: String] = [:], files: [String] = []
    var i = 0
    while i < args.count {
        let a = args[i]
        if a == "--" { files += args[(i + 1)...]; break }
        if a.hasPrefix("-") && a.count > 1 {
            if valueOptions.contains(a) {
                guard i + 1 < args.count else { fail("\(a) needs a value", code: 2) }
                values[a] = args[i + 1]
                i += 2
                continue
            }
            guard flagOptions.contains(a) else { fail("unknown option \(a)", code: 2) }
            flags.insert(a)
        } else {
            files.append(a)
        }
        i += 1
    }
    func value(_ names: String...) -> String? { names.lazy.compactMap { values[$0] }.first }
    func flag(_ names: String...) -> Bool { names.contains { flags.contains($0) } }
    func int(_ names: String...) -> Int? {
        guard let s = names.lazy.compactMap({ values[$0] }).first else { return nil }
        guard let n = Int(s) else { fail("invalid number \(s)", code: 2) }
        return n
    }
    if flag("-h", "--help") { print(genomics2Usage); exit(0) }
    guard !files.isEmpty else { fail("\(command) needs at least one file\n\(genomics2Usage)", code: 2) }

    let workload: Workload
    if let j = int("-j", "--threads") { workload = .threads(max(1, j)) } else { workload = flag("--background") ? .background : .interactive }
    let cancel = CancellationToken()
    let sigint = cancelOnInterrupt(cancel)
    let quiet = flag("-q", "--quiet")
    let showProgress = !quiet && isatty(STDERR_FILENO) != 0
    let progress: ProgressHandler? = showProgress ? progressPrinter() : nil
    func clear() { if showProgress { fputs("\r\u{1B}[K", stderr) } }

    var failed = false
    do {
        switch (command, sub) {
        case ("tabix", _):
            var config: TabixConfig?
            if let p = value("-p", "--preset") {
                guard let preset = TabixConfig.Preset(rawValue: p.lowercased()) else { fail("unknown preset \(p) (vcf, bed, gff, sam)", code: 2) }
                config = TabixConfig(preset: preset)
            }
            if let s = int("-s", "--sequence"), let b = int("-b", "--begin") {
                config = TabixConfig(format: flag("-0", "--zero-based") ? 0x10000 : 0, sequenceColumn: Int32(s), beginColumn: Int32(b),
                                     endColumn: Int32(int("-e", "--end") ?? 0))
            } else if value("-s", "--sequence", "-b", "--begin", "-e", "--end") != nil {
                fail("custom columns need both -s and -b", code: 2)
            }
            if var c = config {
                if let m = value("-c", "--comment") { c.metaChar = m.utf8.first ?? UInt8(ascii: "#") }
                if let s = int("-S", "--skip-lines") { c.skipLines = Int32(s) }
                config = c
            }
            let csi = flag("-C", "--csi") || value("-m", "--min-shift") != nil
            for path in files {
                var url = URL(fileURLWithPath: path)
                if flag("--bgzip"), let head = FileHandle(forReadingAtPath: path)?.readData(ofLength: 2), head != Data([0x1f, 0x8b]) {
                    var o = CreateOptions()
                    o.format = .bgzf
                    o.overwrite = flag("-f", "--force")
                    o.workload = workload
                    url = URL(fileURLWithPath: path + ".gz")
                    try Xipper.create(from: [URL(fileURLWithPath: path)], to: url, options: o, progress: progress, cancel: cancel)
                    clear()
                }
                let dest = url.path + (csi ? ".csi" : ".tbi")
                if FileManager.default.fileExists(atPath: dest) && !flag("-f", "--force") {
                    fail("\(dest) already exists (use -f to overwrite)")
                }
                var c = config
                if c == nil, let p = TabixConfig.preset(forFileName: url.lastPathComponent) {
                    c = TabixConfig(preset: p)
                    if let m = value("-c", "--comment") { c!.metaChar = m.utf8.first ?? UInt8(ascii: "#") }
                    if let s = int("-S", "--skip-lines") { c!.skipLines = Int32(s) }
                }
                let r = try Xipper.tabixIndex(url, config: c, csi: csi, minShift: int("-m", "--min-shift") ?? 14, overwrite: true,
                                              workload: workload, progress: progress, cancel: cancel)
                clear()
                if !quiet {
                    print(String(format: "%@: %d records, %d sequences in %.2fs", r.index.path, r.records, r.sequences.count, r.elapsed))
                }
            }

        case ("index-check", _):
            for path in files {
                let url = URL(fileURLWithPath: path)
                if ["tbi", "csi", "bai", "gzi", "crai"].contains(url.pathExtension.lowercased()) {
                    let r = try Xipper.checkIndex(url, data: value("--data").map { URL(fileURLWithPath: $0) }, cancel: cancel)
                    printIndex(r)
                    failed = failed || !r.isOK
                    continue
                }
                let r = try Xipper.genomicsCheck(url, checkIndexes: !flag("--no-index"), workload: workload, progress: progress, cancel: cancel)
                clear()
                print("\(path): \(r.problems.isEmpty ? "OK" : "FAILED") (\(r.detail))")
                for p in r.problems { print("  error: \(p)") }
                for w in r.warnings { print("  warning: \(w)") }
                r.indexes.forEach(printIndex)
                failed = failed || !r.isOK
            }

        case ("manifest", "create"):
            guard let out = value("-o", "--output") else { fail("manifest create needs -o MANIFEST", code: 2) }
            let algos = try value("-a", "--algorithms").map { list in
                try list.split(separator: ",").map { n -> ChecksumAlgorithm in
                    guard let a = ChecksumAlgorithm(name: String(n)) else { throw XipperError.invalidArgument("unknown algorithm \(n)") }
                    return a
                }
            }
            let r = try Xipper.createManifest(of: files.map { URL(fileURLWithPath: $0) }, to: URL(fileURLWithPath: out), algorithms: algos,
                                              overwrite: flag("-f", "--force"), workload: workload, progress: progress, cancel: cancel)
            clear()
            if !quiet {
                print(String(format: "%@: %d files, %@ (%@) in %.2fs", r.manifest.path, r.entries.count, r.bytes.bytesText,
                             r.algorithms.map(\.rawValue).joined(separator: ", "), r.elapsed))
            }

        case ("manifest", "verify"):
            let algo = try value("-a", "--algorithms").map { n -> ChecksumAlgorithm in
                guard let a = ChecksumAlgorithm(name: n) else { throw XipperError.invalidArgument("unknown algorithm \(n)") }
                return a
            }
            for path in files {
                let r = try Xipper.verifyManifest(URL(fileURLWithPath: path), algorithm: algo, workload: workload, progress: progress, cancel: cancel)
                clear()
                for m in r.mismatches { print("FAILED \(m.path): \(m.algorithm.rawValue) \(m.actual), expected \(m.expected)") }
                for m in r.missing { print("MISSING \(m)") }
                for m in r.refused { print("REFUSED \(m) (absolute path or ..)") }
                for m in r.sizeMismatches { print("SIZE \(m)") }
                if !r.skippedTypes.isEmpty { fputs("note: checksum types not verified: \(r.skippedTypes.joined(separator: ", "))\n", stderr) }
                print(r.isOK ? String(format: "%@: OK, %d files (%@) in %.2fs", path, r.checked, r.bytes.bytesText, r.elapsed)
                             : "\(path): \(r.mismatches.count) mismatched, \(r.missing.count) missing, \(r.refused.count) refused, \(r.checked) checked")
                failed = failed || !r.isOK
            }

        case ("index", _):
            guard files.count == 1 || value("-o", "--output") == nil else { fail("-o needs a single input", code: 2) }
            for path in files {
                let r = try Xipper.buildIndex(URL(fileURLWithPath: path), csi: flag("-C", "--csi"), minShift: int("-m", "--min-shift") ?? 14,
                                              to: value("-o", "--output").map { URL(fileURLWithPath: $0) }, overwrite: true,
                                              workload: workload, progress: progress, cancel: cancel)
                clear()
                if !quiet { print(String(format: "%@: %d records, %d sequences in %.2fs", r.index.path, r.records, r.sequences, r.elapsed)) }
            }

        case ("cram", _):
            let ref = value("-r", "-T", "--reference").map { URL(fileURLWithPath: $0) }
            guard files.count == 1 || value("-o", "--output") == nil else { fail("-o needs a single input", code: 2) }
            for path in files {
                let url = URL(fileURLWithPath: path)
                let isCRAM = (FileHandle(forReadingAtPath: path)?.readData(ofLength: 4)).map { $0 == Data("CRAM".utf8) } ?? false
                let out = value("-o", "--output").map { URL(fileURLWithPath: $0) }
                    ?? url.deletingPathExtension().appendingPathExtension(isCRAM ? "bam" : "cram")
                let r: CRAMConversionReport
                if isCRAM {
                    r = try Xipper.cramToBAM(url, output: out, reference: ref, overwrite: flag("-f", "--force"),
                                             regenerateMDNM: !flag("--no-md"), workload: workload, progress: progress, cancel: cancel)
                } else {
                    guard let ref else { fail("BAM → CRAM needs the reference: -r FASTA", code: 2) }
                    let minor: UInt8 = switch value("--version") { case nil, "3.1": 1; case "3.0": 0; case let v?: fail("unsupported CRAM version \(v) (3.0, 3.1)", code: 2) }
                    r = try Xipper.bamToCRAM(url, output: out, reference: ref, minor: minor, overwrite: flag("-f", "--force"),
                                             workload: workload, progress: progress, cancel: cancel)
                }
                clear()
                if !quiet {
                    print(String(format: "%@ → %@: %lld records, %@ → %@ in %.2fs", path, out.lastPathComponent, r.records,
                                 r.inputBytes.bytesText, r.outputBytes.bytesText, r.elapsed))
                }
            }

        default:
            fail("unknown command \(command)", code: 2)
        }
    } catch XipperError.cancelled {
        clear()
        fail("cancelled", code: 130)
    } catch {
        clear()
        fail("\(error)")
    }
    exit(failed ? 3 : 0)
}

func printIndex(_ r: IndexCheckReport) {
    print("\(r.index.path): \(r.isOK ? "OK" : "FAILED") (\(r.kind.rawValue), \(r.references) references, \(r.offsetsChecked) offsets checked)")
    for p in r.problems { print("  error: \(p)") }
    for w in r.warnings { print("  warning: \(w)") }
}

/// Ctrl-C cancels `token` instead of killing the process (so mounts unmount and save, and partial
/// outputs are removed). Built outside any actor: the handler runs on a dispatch queue, and a
/// closure isolated to the main actor (as everything in main.swift is) would trap there.
func cancelOnInterrupt(_ token: CancellationToken) -> DispatchSourceSignal {
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    source.setEventHandler { token.cancel() }
    source.resume()
    return source
}
