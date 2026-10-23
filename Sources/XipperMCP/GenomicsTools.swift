import Foundation
import XipperKit

// Genomics 2 tools (STUDIO.md §4.6): tabix/CSI indexes, data and index checks, checksum manifests.

private func schema(_ props: [String: JSON], required: [String]) -> JSON {
    ["type": "object", "properties": .object(props), "required": .array(required.map(JSON.string)), "additionalProperties": false]
}
private func str(_ d: String) -> JSON { ["type": "string", "description": .string(d)] }
private func bool(_ d: String) -> JSON { ["type": "boolean", "description": .string(d)] }
private func strArray(_ d: String) -> JSON { ["type": "array", "items": ["type": "string"], "description": .string(d)] }
private func enumeration(_ values: [String], _ d: String) -> JSON {
    ["type": "string", "enum": .array(values.map(JSON.string)), "description": .string(d)]
}
private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
private let pathDoc = "Absolute path (or ~/…) inside one of the folders the user allowed."
private let indexExtensions: Set<String> = ["tbi", "csi", "bai", "gzi", "crai"]

/// True for BGZF data (a compressed FASTA gets a .gzi next to its .fai).
private func BGZFBlockLooksCompressed(_ path: String) -> Bool {
    FileHandle(forReadingAtPath: path)?.readData(ofLength: 2) == Data([0x1F, 0x8B])
}

private func indexJSON(_ r: IndexCheckReport) -> JSON {
    ["index": .string(r.index.path), "data": .string(r.data.path), "kind": .string(r.kind.rawValue), "ok": .bool(r.isOK),
     "references": .int(Int64(r.references)), "offsetsChecked": .int(Int64(r.offsetsChecked)),
     "problems": .array(r.problems.map(JSON.string)), "warnings": .array(r.warnings.map(JSON.string))]
}

private func indexText(_ r: IndexCheckReport) -> String {
    var s = "\(r.index.lastPathComponent): \(r.isOK ? "OK" : "FAILED") (\(r.kind.rawValue), \(r.references) references, \(r.offsetsChecked) offsets checked)"
    for p in r.problems { s += "\n  - \(p)" }
    for w in r.warnings { s += "\n  - warning: \(w)" }
    return s
}

private func algorithms(_ args: [String: JSON]) throws -> [ChecksumAlgorithm]? {
    guard let list = args["algorithms"]?.array?.compactMap(\.string), !list.isEmpty else { return nil }
    return try list.map { n in
        guard let a = ChecksumAlgorithm(name: n) else { throw ToolError("unknown checksum algorithm \(n) (sha-256, md5, crc32c, sha-512, sha-1, sha512t24u)") }
        return a
    }
}

extension XipperTools {
    static var genomics: [Tool] { [genomicsIndex, genomicsCheck, checksumManifest, cramConvert] }

    static let genomicsIndex = Tool(
        name: "genomics_index", title: "Index genomics files",
        description: "Genomics: builds the usual htslib-compatible index next to a coordinate-sorted file: BAM → .bai (or .csi), CRAM → .crai, BCF → .csi, FASTA/FASTQ (plain or BGZF) → .fai (+ .gzi), BGZF VCF/BED/GFF/SAM → tabix .tbi (or .csi). samtools, bcftools and tabix read them. Unsorted files and plain gzip are refused with a clear message (use bgzf_convert first). CSI is needed for positions beyond 512 Mbp.",
        inputSchema: schema(["path": str(pathDoc),
                             "preset": enumeration(TabixConfig.Preset.allCases.map(\.rawValue), "Tabix files only: the type (default: from the name)."),
                             "csi": bool("BAM and tabix files: write a CSI index (.csi) instead of .bai/.tbi."),
                             "overwrite": bool("Replace an existing index. Requires the user's confirmation.")],
                            required: ["path"]),
        readOnly: false, destructive: false, idempotent: true
    ) { args, ctx in
        let path = try ctx.policy.resolve(try args.requiredString("path"), mustExist: true)
        let url = URL(fileURLWithPath: path)
        let csi = args.optionalBool("csi")
        let preset = try args["preset"]?.string.map { p -> TabixConfig.Preset in
            guard let preset = TabixConfig.Preset(rawValue: p) else { throw ToolError("unknown preset \(p)") }
            return preset
        }
        let target: (url: URL, kind: String) = preset != nil ? (URL(fileURLWithPath: path + (csi ? ".csi" : ".tbi")), csi ? "csi" : "tbi") : try Xipper.defaultIndex(for: url, csi: csi)
        let dest = try ctx.policy.resolve(target.url.path, mustExist: false)
        if FileManager.default.fileExists(atPath: dest) {
            guard args.optionalBool("overwrite") else { throw ToolError("\(dest) already exists (pass overwrite: true to rebuild it, after asking the user)") }
            guard try ctx.confirm("Allow the assistant to rebuild the index \(dest)?") else { throw ToolError("the user declined replacing \(dest)") }
        }
        if let preset {
            let r = try Xipper.tabixIndex(url, config: TabixConfig(preset: preset), csi: csi, to: URL(fileURLWithPath: dest), overwrite: true,
                                          workload: ctx.config.workload, progress: ctx.progress, cancel: ctx.cancel)
            let names = r.sequences.prefix(30).joined(separator: ", ") + (r.sequences.count > 30 ? ", …" : "")
            return ToolResult(text: "Indexed \(r.records) records on \(r.sequences.count) sequences (\(names)) → \(dest) in \(String(format: "%.2f", r.elapsed)) s",
                              structured: ["index": .string(dest), "kind": .string(r.kind.rawValue), "records": .int(Int64(r.records)),
                                           "sequences": .array(r.sequences.map(JSON.string)), "seconds": .double(r.elapsed)])
        }
        if target.kind == "fai", BGZFBlockLooksCompressed(path) { _ = try ctx.policy.resolve(path + ".gzi", mustExist: false) }
        let r = try Xipper.buildIndex(url, csi: csi, to: URL(fileURLWithPath: dest), overwrite: true,
                                      workload: ctx.config.workload, progress: ctx.progress, cancel: ctx.cancel)
        return ToolResult(text: "Indexed \(r.records) records on \(r.sequences) sequences → \(dest) (\(r.kind)) in \(String(format: "%.2f", r.elapsed)) s",
                          structured: ["index": .string(dest), "kind": .string(r.kind), "records": .int(Int64(r.records)),
                                       "sequenceCount": .int(Int64(r.sequences)), "seconds": .double(r.elapsed)])
    }

    static let cramConvert = Tool(
        name: "cram_convert", title: "Convert BAM ↔ CRAM",
        description: "Genomics: converts BAM → CRAM 3.1 (or 3.0) and CRAM 3.0/3.1 → BAM, with the reference FASTA the reads were aligned to (uncompressed; its .fai is used when present). Writing CRAM checks @SQ M5 against the reference and adds the missing ones; reading checks each slice's MD5 and regenerates MD/NM like samtools (no_md: false). Records round-trip unchanged (samtools reads the output).",
        inputSchema: schema(["path": str(pathDoc + " A .bam or .cram file."),
                             "reference": str("Reference FASTA (required for BAM → CRAM and for CRAM files that use it)."),
                             "output": str("Output path (default: same name with .cram or .bam)."),
                             "version": enumeration(["3.1", "3.0"], "CRAM version to write (default 3.1; 3.0 for older readers)."),
                             "no_md": bool("CRAM → BAM: do not add the MD/NM tags samtools regenerates."),
                             "overwrite": bool("Replace an existing output. Requires the user's confirmation.")],
                            required: ["path"]),
        readOnly: false, destructive: false, idempotent: true
    ) { args, ctx in
        let path = try ctx.policy.resolve(try args.requiredString("path"), mustExist: true)
        let url = URL(fileURLWithPath: path)
        let isCRAM = FileHandle(forReadingAtPath: path)?.readData(ofLength: 4) == Data("CRAM".utf8)
        let reference = try args["reference"]?.string.map { URL(fileURLWithPath: try ctx.policy.resolve($0, mustExist: true)) }
        let outArg = args["output"]?.string ?? url.deletingPathExtension().appendingPathExtension(isCRAM ? "bam" : "cram").path
        let output = try ctx.policy.resolve(outArg, mustExist: false)
        var overwrite = false
        if FileManager.default.fileExists(atPath: output) {
            guard args.optionalBool("overwrite") else { throw ToolError("\(output) already exists (pass overwrite: true to replace it, after asking the user)") }
            guard try ctx.confirm("Allow the assistant to replace \(output)?") else { throw ToolError("the user declined replacing \(output)") }
            overwrite = true
        }
        let r: CRAMConversionReport
        if isCRAM {
            r = try Xipper.cramToBAM(url, output: URL(fileURLWithPath: output), reference: reference, overwrite: overwrite,
                                     regenerateMDNM: !args.optionalBool("no_md"), workload: ctx.config.workload, progress: ctx.progress, cancel: ctx.cancel)
        } else {
            guard let reference else { throw ToolError("BAM → CRAM needs the reference FASTA (reference)") }
            let minor: UInt8 = args["version"]?.string == "3.0" ? 0 : 1
            r = try Xipper.bamToCRAM(url, output: URL(fileURLWithPath: output), reference: reference, minor: minor, overwrite: overwrite,
                                     workload: ctx.config.workload, progress: ctx.progress, cancel: ctx.cancel)
        }
        return ToolResult(text: "\(url.lastPathComponent) → \(output): \(r.records) records, \(bytes(r.inputBytes)) → \(bytes(r.outputBytes)) in \(String(format: "%.2f", r.elapsed)) s",
                          structured: ["output": .string(output), "records": .int(r.records), "inputBytes": .int(r.inputBytes),
                                       "outputBytes": .int(r.outputBytes), "containers": .int(Int64(r.containers)), "seconds": .double(r.elapsed)])
    }

    static let genomicsCheck = Tool(
        name: "genomics_check", title: "Check genomics file and indexes",
        description: "Genomics: verifies a VCF.gz, BCF, BAM, CRAM 3.0/3.1 or other BGZF file without decoding records (BGZF blocks and EOF marker; ##fileformat/#CHROM header or BCF magic; CRAM container and block CRC32s and EOF container) and every .tbi/.csi/.bai/.gzi/.crai next to it: offsets on valid BGZF boundaries, index not older than the data. Also accepts an index file directly.",
        inputSchema: schema(["path": str(pathDoc + " A data file or an index (.tbi/.csi/.bai/.gzi/.crai)."),
                             "check_indexes": bool("Also check the indexes next to a data file (default true).")],
                            required: ["path"]),
        readOnly: true, destructive: false, idempotent: true
    ) { args, ctx in
        let path = try ctx.policy.resolve(try args.requiredString("path"), mustExist: true)
        let url = URL(fileURLWithPath: path)
        if indexExtensions.contains(url.pathExtension.lowercased()) {
            guard let data = Xipper.dataFile(forIndex: url) else { throw ToolError("cannot find the data file of \(url.lastPathComponent)") }
            let dataPath = try ctx.policy.resolve(data.path, mustExist: true)
            let r = try Xipper.checkIndex(url, data: URL(fileURLWithPath: dataPath), cancel: ctx.cancel)
            return ToolResult(text: indexText(r), structured: ["ok": .bool(r.isOK), "indexes": .array([indexJSON(r)])])
        }
        var r = try Xipper.genomicsCheck(url, checkIndexes: false, workload: ctx.config.workload, progress: ctx.progress, cancel: ctx.cancel)
        if args["check_indexes"]?.bool ?? true {
            for idx in Xipper.indexes(for: url) {
                // Sibling indexes may be symlinks: they must stay inside the allowed folders too.
                guard let allowed = try? ctx.policy.resolve(idx.path, mustExist: true) else { continue }
                do { r.indexes.append(try Xipper.checkIndex(URL(fileURLWithPath: allowed), data: url, cancel: ctx.cancel)) } catch let e as XipperError where e != .cancelled {
                    r.indexes.append(IndexCheckReport(index: idx, data: url, kind: IndexCheckReport.Kind(rawValue: idx.pathExtension.lowercased()) ?? .tbi,
                                                      references: 0, offsetsChecked: 0, problems: [e.description], warnings: []))
                }
            }
        }
        var text = "\(url.lastPathComponent): \(r.problems.isEmpty ? "OK" : "FAILED") (\(r.detail))"
        for p in r.problems { text += "\n- \(p)" }
        for w in r.warnings { text += "\n- warning: \(w)" }
        if r.indexes.isEmpty && args["check_indexes"]?.bool ?? true { text += "\nNo index next to the file." }
        for i in r.indexes { text += "\n" + indexText(i) }
        var o: [String: JSON] = ["ok": .bool(r.isOK), "kind": .string(r.kind.rawValue), "detail": .string(r.detail),
                                 "problems": .array(r.problems.map(JSON.string)), "warnings": .array(r.warnings.map(JSON.string)),
                                 "indexes": .array(r.indexes.map(indexJSON)), "seconds": .double(r.elapsed)]
        if let c = r.cram {
            o["cram"] = ["version": .string(c.version), "containers": .int(Int64(c.containers)), "blocks": .int(Int64(c.blocks)),
                         "records": .int(c.records), "eofContainer": .bool(c.hasEOFContainer)]
        }
        return ToolResult(text: text, structured: .object(o))
    }

    private static let manifestDescription = "Checksum manifests with GA4GH DRS / IANA names (sha-256, md5, crc32c, sha-512, sha-1, sha512t24u; `sha256` is accepted too). action \"create\": checksums `sources` into `manifest` — .json (DRS objects: id, name, size, created_time, updated_time, checksums), or one-algorithm text in sha256sum/md5sum format (.sha256, .md5, .crc32c…); paths are relative to the manifest's folder. action \"verify\": recomputes every listed file (json, sha256sum/md5sum or BSD text) and reports mismatches and missing files."

    private static func manifestHandler(_ args: [String: JSON], _ ctx: ToolContext, allowCreate: Bool) throws -> ToolResult {
        let action = try args.requiredString("action")
        let manifestArg = try args.requiredString("manifest")
        switch action {
        case "create" where allowCreate:
            guard let raw = args["sources"]?.array?.compactMap(\.string), !raw.isEmpty else { throw ToolError("create needs sources") }
            let sources = try raw.map { URL(fileURLWithPath: try ctx.policy.resolve($0, mustExist: true)) }
            let manifest = try ctx.policy.resolve(manifestArg, mustExist: false)
            var overwrite = false
            if FileManager.default.fileExists(atPath: manifest) {
                guard args.optionalBool("overwrite") else { throw ToolError("\(manifest) already exists (pass overwrite: true to replace it, after asking the user)") }
                guard try ctx.confirm("Allow the assistant to replace the checksum manifest \(manifest)?") else { throw ToolError("the user declined replacing \(manifest)") }
                overwrite = true
            }
            let r = try Xipper.createManifest(of: sources, to: URL(fileURLWithPath: manifest), algorithms: try algorithms(args), overwrite: overwrite,
                                              workload: ctx.config.workload, progress: ctx.progress, cancel: ctx.cancel)
            return ToolResult(text: "Wrote \(manifest): \(r.entries.count) files, \(bytes(r.bytes)), \(r.algorithms.map(\.rawValue).joined(separator: ", ")) in \(String(format: "%.2f", r.elapsed)) s",
                              structured: ["manifest": .string(manifest), "files": .int(Int64(r.entries.count)), "bytes": .int(r.bytes),
                                           "algorithms": .array(r.algorithms.map { .string($0.rawValue) }), "seconds": .double(r.elapsed)])
        case "verify":
            let manifest = try ctx.policy.resolve(manifestArg, mustExist: true)
            let algo = try algorithms(args)?.first
            let r = try Xipper.verifyManifest(URL(fileURLWithPath: manifest), algorithm: algo,
                                              resolve: { try ctx.policy.resolve($0, mustExist: false) },
                                              workload: ctx.config.workload, progress: ctx.progress, cancel: ctx.cancel)
            var text = r.isOK ? "OK: \(r.checked) files verified (\(bytes(r.bytes))) in \(String(format: "%.2f", r.elapsed)) s"
                              : "FAILED: \(r.mismatches.count) mismatched, \(r.missing.count) missing, \(r.refused.count) refused, \(r.checked) checked"
            for m in r.mismatches.prefix(50) { text += "\n- \(m.path): \(m.algorithm.rawValue) is \(m.actual), manifest says \(m.expected)" }
            for m in r.missing.prefix(50) { text += "\n- missing: \(m)" }
            for m in r.refused.prefix(50) { text += "\n- refused (absolute, .. or outside the allowed folders): \(m)" }
            for m in r.sizeMismatches.prefix(50) { text += "\n- size: \(m)" }
            if !r.skippedTypes.isEmpty { text += "\nNot verified (unsupported types): \(r.skippedTypes.joined(separator: ", "))" }
            let mism: [JSON] = r.mismatches.map { ["path": .string($0.path), "type": .string($0.algorithm.rawValue), "expected": .string($0.expected), "actual": .string($0.actual)] }
            return ToolResult(text: text, structured: ["ok": .bool(r.isOK), "checked": .int(Int64(r.checked)), "bytes": .int(r.bytes),
                                                       "mismatches": .array(mism), "missing": .array(r.missing.map(JSON.string)),
                                                       "refused": .array(r.refused.map(JSON.string)), "sizeMismatches": .array(r.sizeMismatches.map(JSON.string)),
                                                       "skippedTypes": .array(r.skippedTypes.map(JSON.string)), "seconds": .double(r.elapsed)])
        case "create":
            throw ToolError("the server is in read-only mode: only action \"verify\" is available")
        default:
            throw ToolError("unknown action \(action) (create or verify)")
        }
    }

    static let checksumManifest = Tool(
        name: "checksum_manifest", title: "Checksum manifest (create / verify)",
        description: manifestDescription,
        inputSchema: schema(["action": enumeration(["create", "verify"], "create or verify"),
                             "manifest": str("Manifest path (.json, .sha256, .md5, .crc32c…)."),
                             "sources": strArray("create: files or folders to checksum (inside the manifest's folder)."),
                             "algorithms": strArray("create: algorithms (default from the name; JSON: sha-256, md5, crc32c). verify: force the algorithm of a text manifest."),
                             "overwrite": bool("create: replace an existing manifest. Requires the user's confirmation.")],
                            required: ["action", "manifest"]),
        readOnly: false, destructive: false, idempotent: false
    ) { args, ctx in try manifestHandler(args, ctx, allowCreate: true) }

    /// Same tool in read-only mode: verification only.
    static let checksumManifestVerifyOnly = Tool(
        name: "checksum_manifest", title: "Verify checksum manifest",
        description: manifestDescription + " (Read-only mode: only \"verify\".)",
        inputSchema: schema(["action": enumeration(["verify"], "verify"),
                             "manifest": str("Manifest path (.json, .sha256, .md5, .crc32c…)."),
                             "algorithms": strArray("Force the algorithm of a text manifest.")],
                            required: ["action", "manifest"]),
        readOnly: true, destructive: false, idempotent: true
    ) { args, ctx in try manifestHandler(args, ctx, allowCreate: false) }
}
