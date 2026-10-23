import Foundation
import XipperKit

/// What a tool handler needs from the server for one call.
struct ToolContext: Sendable {
    let config: MCPConfig
    let policy: PathPolicy
    let cancel: CancellationToken
    /// Progress handler wired to `notifications/progress` when the client sent a progress token.
    let progress: ProgressHandler?
    /// Asks the human (through the client) to confirm a destructive action. Returns false if declined;
    /// throws if the client cannot ask.
    let confirm: @Sendable (String) throws -> Bool
}

struct ToolResult {
    var text: String
    var structured: JSON?
    /// Extra content blocks (e.g. an image) placed after the text block.
    var extraContent: [JSON] = []
}

struct Tool: Sendable {
    let name: String
    let title: String
    let description: String
    let inputSchema: JSON
    let readOnly: Bool
    let destructive: Bool
    let idempotent: Bool
    let handler: @Sendable ([String: JSON], ToolContext) throws -> ToolResult

    var definition: JSON {
        [
            "name": .string(name), "title": .string(title), "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": ["title": .string(title), "readOnlyHint": .bool(readOnly), "destructiveHint": .bool(destructive),
                            "idempotentHint": .bool(idempotent), "openWorldHint": false],
        ]
    }
}

// MARK: - schema helpers

private func schema(_ props: [String: JSON], required: [String]) -> JSON {
    ["type": "object", "properties": .object(props), "required": .array(required.map(JSON.string)), "additionalProperties": false]
}
private func str(_ d: String) -> JSON { ["type": "string", "description": .string(d)] }
private func bool(_ d: String) -> JSON { ["type": "boolean", "description": .string(d)] }
private func int(_ d: String, min: Int, max: Int) -> JSON {
    ["type": "integer", "description": .string(d), "minimum": .int(Int64(min)), "maximum": .int(Int64(max))]
}
private func strArray(_ d: String) -> JSON { ["type": "array", "items": ["type": "string"], "description": .string(d)] }

private let pathDoc = "Absolute path (or ~/…) inside one of the folders the user allowed."
private let passwordRefDoc = "Name of an archive password stored in the user's Keychain (never ask the user to type a password in chat)."

// MARK: - argument helpers

extension Dictionary where Key == String, Value == JSON {
    func requiredString(_ k: String) throws -> String {
        guard let v = self[k]?.string, !v.isEmpty else { throw MCPError(code: MCPError.invalidParams, message: "missing argument \(k)") }
        return v
    }
    func optionalBool(_ k: String) -> Bool { self[k]?.bool ?? false }
}

private func password(_ args: [String: JSON], _ ctx: ToolContext) throws -> String? {
    if let ref = args["password_ref"]?.string { return try PasswordStore.get(ref) }
    if let pw = args["password"]?.string {
        guard ctx.config.allowPasswordArgument else {
            throw ToolError("clear-text passwords are disabled; store the password in the Keychain and pass password_ref")
        }
        return pw
    }
    return nil
}

private func iso(_ d: Date?) -> JSON { d.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null }

private func entryJSON(_ e: ArchiveEntry) -> JSON {
    var o: [String: JSON] = [
        "path": .string(e.path), "kind": .string("\(e.kind)"), "size": .int(e.uncompressedSize),
        "compressedSize": .int(e.compressedSize), "method": .string(e.method), "encrypted": .bool(e.isEncrypted),
        "modified": iso(e.modified),
    ]
    if let t = e.linkTarget { o["linkTarget"] = .string(t) }
    return .object(o)
}

private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

// MARK: - tools

enum XipperTools {
    /// UTF-8 text with few control characters, else nil (binary). A truncated read may end in
    /// the middle of a multi-byte character, so up to 3 trailing bytes are tolerated.
    static func decodeText(_ data: [UInt8], truncated: Bool) -> String? {
        if data.contains(0) { return nil }
        var text = String(bytes: data, encoding: .utf8)
        if text == nil && truncated {
            for cut in 1...3 where data.count > cut {
                if let t = String(bytes: data.dropLast(cut), encoding: .utf8) { text = t; break }
            }
        }
        guard let text else { return nil }
        let controls = text.unicodeScalars.filter { $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t" }.count
        return controls * 100 > max(text.unicodeScalars.count, 1) ? nil : text
    }

    static func all(readOnly: Bool) -> [Tool] {
        let tools = [info, list, test, readEntry, bgzfCheck, extract, create, bgzfCompress, bgzfConvert] + genomics
        return readOnly ? tools.filter(\.readOnly) + [checksumManifestVerifyOnly] : tools
    }

    static let info = Tool(
        name: "archive_info", title: "Archive information",
        description: "Format, entry count, sizes and encryption of an archive (zip, 7z, tar, tar.gz/bz2/xz/zst, gz, RAR/RAR5 read-only, BGZF incl. BAM/BCF). Fast: does not extract.",
        inputSchema: schema(["path": str(pathDoc), "password_ref": str(passwordRefDoc + " Only needed for 7z archives with encrypted file names.")],
                            required: ["path"]),
        readOnly: true, destructive: false, idempotent: true
    ) { args, ctx in
        let path = try ctx.policy.resolve(try args.requiredString("path"), mustExist: true)
        let url = URL(fileURLWithPath: path)
        guard let format = try ArchiveFormat.detect(url) else { throw ToolError("not a recognized archive") }
        let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        var o: [String: JSON] = ["path": .string(path), "format": .string(format.rawValue), "compressedSize": .int(size)]
        var text = "\(url.lastPathComponent): \(format.rawValue), \(bytes(size))"
        if format == .bgzf {
            let i = try Xipper.bgzfInfo(url)
            o["bgzf"] = ["blocks": .int(Int64(i.blocks)), "endsWithEOFMarker": .bool(i.endsWithEOFMarker)]
            o["uncompressedSize"] = .int(i.uncompressedSize)
            text += ", BGZF \(i.blocks) blocks, \(bytes(i.uncompressedSize)) uncompressed" + (i.endsWithEOFMarker ? "" : ", EOF MARKER MISSING (truncated?)")
        } else {
            let entries = try Xipper.list(url, password: try password(args, ctx), workload: ctx.config.workload)
            let files = entries.filter { $0.kind == .file }
            let total = files.reduce(Int64(0)) { $0 + max(0, $1.uncompressedSize) }
            let encrypted = entries.contains(where: \.isEncrypted)
            o["entries"] = .int(Int64(entries.count))
            o["files"] = .int(Int64(files.count))
            o["directories"] = .int(Int64(entries.filter { $0.kind == .directory }.count))
            o["uncompressedSize"] = .int(total)
            o["encrypted"] = .bool(encrypted)
            text += ", \(entries.count) entries (\(files.count) files), \(bytes(total)) uncompressed" + (encrypted ? ", encrypted" : "")
        }
        return ToolResult(text: text, structured: .object(o))
    }

    static let list = Tool(
        name: "archive_list", title: "List archive contents",
        description: "Lists entries of an archive, paginated. Use `glob` (fnmatch pattern on the entry path, e.g. \"*.vcf.gz\") to filter.",
        inputSchema: schema(["path": str(pathDoc), "glob": str("Optional fnmatch pattern on entry paths."),
                             "cursor": str("Opaque cursor from a previous call."), "limit": int("Entries per page (default 200).", min: 1, max: 1000),
                             "password_ref": str(passwordRefDoc + " Only needed for 7z archives with encrypted file names.")],
                            required: ["path"]),
        readOnly: true, destructive: false, idempotent: true
    ) { args, ctx in
        let path = try ctx.policy.resolve(try args.requiredString("path"), mustExist: true)
        var entries = try Xipper.list(URL(fileURLWithPath: path), password: try password(args, ctx), workload: ctx.config.workload)
        if let g = args["glob"]?.string { entries = entries.filter { fnmatch(g, $0.path, 0) == 0 } }
        let start = Int(args["cursor"]?.string ?? "0") ?? 0
        let limit = min(args["limit"]?.int ?? 200, ctx.config.maxListEntries)
        let page = Array(entries.dropFirst(start).prefix(limit))
        let next = start + page.count < entries.count ? String(start + page.count) : nil
        var o: [String: JSON] = ["entries": .array(page.map(entryJSON)), "totalCount": .int(Int64(entries.count))]
        if let next { o["nextCursor"] = .string(next) }
        let lines = page.map { ($0.kind == .directory ? $0.path + "/" : $0.path) + ($0.kind == .file ? "  (\(bytes(max(0, $0.uncompressedSize))))" : "") }
        let text = lines.joined(separator: "\n") + "\n— \(page.count) of \(entries.count) entries" + (next.map { ", next cursor \($0)" } ?? "")
        return ToolResult(text: text, structured: .object(o))
    }

    static let test = Tool(
        name: "archive_test", title: "Verify archive integrity",
        description: "Decodes every entry and checks CRC/authentication codes (ZIP), codec checksums (tar.*), every block and the end-of-file marker (BGZF/BAM/BCF). Writes nothing.",
        inputSchema: schema(["path": str(pathDoc), "password_ref": str(passwordRefDoc)], required: ["path"]),
        readOnly: true, destructive: false, idempotent: true
    ) { args, ctx in
        let path = try ctx.policy.resolve(try args.requiredString("path"), mustExist: true)
        let r = try Xipper.test(URL(fileURLWithPath: path), password: try password(args, ctx), workload: ctx.config.workload,
                                progress: ctx.progress, cancel: ctx.cancel)
        let failures: [JSON] = r.failures.map { ["path": .string($0.path), "reason": .string($0.reason)] }
        let text = r.isOK
            ? "OK: \(r.entries) entries verified (\(bytes(r.bytes))) in \(String(format: "%.2f", r.elapsed)) s"
            : "\(r.failures.count) problem(s):\n" + r.failures.map { "- \($0.path): \($0.reason)" }.joined(separator: "\n")
        return ToolResult(text: text, structured: ["ok": .bool(r.isOK), "entries": .int(Int64(r.entries)), "bytes": .int(r.bytes),
                                                   "failures": .array(failures), "seconds": .double(r.elapsed)])
    }

    static let readEntry = Tool(
        name: "archive_read_entry", title: "Read one entry",
        description: "Returns the beginning of one entry without extracting: text as text, PNG/JPEG/GIF/WebP as an image. Binary data is refused.",
        inputSchema: schema(["path": str(pathDoc), "entry": str("Entry path as returned by archive_list (ignored for .gz/.bgzf single files)."),
                             "max_bytes": int("Maximum bytes to read (default 65536).", min: 1, max: 1 << 20),
                             "password_ref": str(passwordRefDoc)],
                            required: ["path", "entry"]),
        readOnly: true, destructive: false, idempotent: true
    ) { args, ctx in
        let path = try ctx.policy.resolve(try args.requiredString("path"), mustExist: true)
        let entry = try args.requiredString("entry")
        let maxBytes = args["max_bytes"]?.int ?? (64 << 10)
        let c = try Xipper.readEntry(URL(fileURLWithPath: path), path: entry, password: try password(args, ctx), maxBytes: maxBytes,
                                     workload: ctx.config.workload)
        let meta: JSON = ["entry": .string(c.entry.path), "bytesReturned": .int(Int64(c.data.count)), "truncated": .bool(c.truncated)]
        let lower = entry.lowercased()
        let images = [("png", "image/png"), ("jpg", "image/jpeg"), ("jpeg", "image/jpeg"), ("gif", "image/gif"), ("webp", "image/webp")]
        if let mime = images.first(where: { lower.hasSuffix("." + $0.0) })?.1 {
            if c.truncated { throw ToolError("image larger than max_bytes (\(maxBytes)); raise max_bytes up to 1048576") }
            return ToolResult(text: "\(entry): \(bytes(Int64(c.data.count))) image", structured: meta,
                              extraContent: [["type": "image", "mimeType": .string(mime), "data": .string(Data(c.data).base64EncodedString())]])
        }
        guard let text = Self.decodeText(c.data, truncated: c.truncated) else {
            throw ToolError("\(entry) is binary; extract it instead")
        }
        return ToolResult(text: text + (c.truncated ? "\n… [truncated at \(c.data.count) bytes]" : ""), structured: meta)
    }

    static let bgzfCheck = Tool(
        name: "bgzf_check", title: "Check BGZF / BAM / BCF",
        description: "Genomics: verifies a BGZF file (bgzip'ed VCF/BED/FASTA, BAM, BCF): block chain, every block CRC and the end-of-file marker that reveals truncated transfers.",
        inputSchema: schema(["path": str(pathDoc)], required: ["path"]),
        readOnly: true, destructive: false, idempotent: true
    ) { args, ctx in
        let path = try ctx.policy.resolve(try args.requiredString("path"), mustExist: true)
        let url = URL(fileURLWithPath: path)
        guard try ArchiveFormat.detect(url) == .bgzf else { throw ToolError("\(url.lastPathComponent) is not BGZF (plain gzip? use bgzf_convert)") }
        let i = try Xipper.bgzfInfo(url)
        let r = try Xipper.test(url, workload: ctx.config.workload, progress: ctx.progress, cancel: ctx.cancel)
        let text = r.isOK ? "OK: BGZF, \(i.blocks) blocks, \(bytes(i.uncompressedSize)) uncompressed, EOF marker present"
                          : "FAILED: " + r.failures.map(\.reason).joined(separator: "; ")
        return ToolResult(text: text, structured: ["ok": .bool(r.isOK), "blocks": .int(Int64(i.blocks)),
                                                   "uncompressedSize": .int(i.uncompressedSize), "endsWithEOFMarker": .bool(i.endsWithEOFMarker),
                                                   "failures": .array(r.failures.map { .string($0.reason) })])
    }

    static let extract = Tool(
        name: "archive_extract", title: "Extract archive",
        description: "Extracts an archive into `destination` (an allowed folder). By default creates a new folder (or places a single top-level item) without touching existing files. Unsafe entries (paths escaping the destination, external symlinks) are skipped and reported.",
        inputSchema: schema(["path": str(pathDoc), "destination": str("Existing folder inside the allowed folders."),
                             "entries": strArray("Only these entry paths (folders include their content)."),
                             "overwrite": bool("Merge into `destination` replacing existing files. Requires the user's confirmation."),
                             "password_ref": str(passwordRefDoc)],
                            required: ["path", "destination"]),
        readOnly: false, destructive: true, idempotent: false
    ) { args, ctx in
        let path = try ctx.policy.resolve(try args.requiredString("path"), mustExist: true)
        let dest = try ctx.policy.resolve(try args.requiredString("destination"), mustExist: true)
        var o = ExtractOptions()
        o.password = try password(args, ctx)
        o.limits = ctx.config.extractionLimits
        o.workload = ctx.config.workload
        if let sel = args["entries"]?.array?.compactMap(\.string), !sel.isEmpty { o.selection = Set(sel) }
        var mode = ExtractionMode.smart
        if args.optionalBool("overwrite") {
            guard try ctx.confirm("Allow the assistant to extract \((path as NSString).lastPathComponent) into \(dest), replacing existing files?") else {
                throw ToolError("the user declined overwriting files in \(dest)")
            }
            mode = .into
            o.overwrite = .replace
        }
        let r = try Xipper.extract(URL(fileURLWithPath: path), to: URL(fileURLWithPath: dest), mode: mode, options: o,
                                   progress: ctx.progress, cancel: ctx.cancel)
        let skipped: [JSON] = r.skipped.map { ["path": .string($0.path), "reason": .string($0.reason)] }
        var text = "Extracted to \(r.destination.path): \(r.files) files, \(r.directories) folders, \(r.symlinks) links, \(bytes(r.bytes))"
        if !r.skipped.isEmpty { text += "\nSkipped \(r.skipped.count):\n" + r.skipped.prefix(20).map { "- \($0.path): \($0.reason)" }.joined(separator: "\n") }
        return ToolResult(text: text, structured: ["destination": .string(r.destination.path), "files": .int(Int64(r.files)),
                                                   "directories": .int(Int64(r.directories)), "symlinks": .int(Int64(r.symlinks)),
                                                   "bytes": .int(r.bytes), "skipped": .array(skipped)])
    }

    static let create = Tool(
        name: "archive_create", title: "Create archive",
        description: "Creates an archive from files/folders. Format from `format` or the output extension: zip, 7z, tar, tar.gz, tar.bz2, tar.xz, tar.zst, gz, bgzf, bz2, xz, zst. Fails if `output` exists unless overwrite is confirmed by the user. Encryption (zip or 7z, AES-256) needs password_ref; 7z then also hides the file names.",
        inputSchema: schema(["sources": strArray("Files or folders to archive (allowed folders only)."), "output": str("Archive path to create."),
                             "format": ["type": "string", "enum": .array(ArchiveFormat.allCases.map { .string($0.rawValue) })],
                             "level": int("Compression level (format default if omitted).", min: 0, max: 22),
                             "password_ref": str(passwordRefDoc + " Encrypts a zip or 7z with AES-256."),
                             "solid": bool("7z only: one solid block (default, smaller) or false for one block per file (faster partial extraction)."),
                             "overwrite": bool("Replace an existing archive. Requires the user's confirmation.")],
                            required: ["sources", "output"]),
        readOnly: false, destructive: false, idempotent: false
    ) { args, ctx in
        guard let rawSources = args["sources"]?.array?.compactMap(\.string), !rawSources.isEmpty else {
            throw MCPError(code: MCPError.invalidParams, message: "missing argument sources")
        }
        let sources = try rawSources.map { URL(fileURLWithPath: try ctx.policy.resolve($0, mustExist: true)) }
        let output = try ctx.policy.resolve(try args.requiredString("output"), mustExist: false)
        var o = CreateOptions()
        if let f = args["format"]?.string {
            guard let fmt = ArchiveFormat(rawValue: f) else { throw ToolError("unknown format \(f)") }
            o.format = fmt
        } else if let fmt = ArchiveFormat.inferred(fromFileName: output) {
            o.format = fmt
        }
        o.level = args["level"]?.int
        if let solid = args["solid"]?.bool, !solid { o.solidBlockSize = 0 }
        o.password = try password(args, ctx)
        o.workload = ctx.config.workload
        if FileManager.default.fileExists(atPath: output) {
            guard args.optionalBool("overwrite") else { throw ToolError("\(output) already exists (pass overwrite: true to replace it, after asking the user)") }
            guard try ctx.confirm("Allow the assistant to replace the existing archive \(output)?") else {
                throw ToolError("the user declined replacing \(output)")
            }
            o.overwrite = true
        }
        let r = try Xipper.create(from: sources, to: URL(fileURLWithPath: output), options: o, progress: ctx.progress, cancel: ctx.cancel)
        return ToolResult(text: "Created \(output): \(r.entries) entries, \(bytes(r.inputBytes)) → \(bytes(r.outputBytes)) in \(String(format: "%.2f", r.elapsed)) s",
                          structured: ["output": .string(output), "format": .string(o.format.rawValue), "entries": .int(Int64(r.entries)),
                                       "inputBytes": .int(r.inputBytes), "outputBytes": .int(r.outputBytes), "seconds": .double(r.elapsed)])
    }

    static let bgzfCompress = Tool(
        name: "bgzf_compress", title: "Compress with BGZF (bgzip)",
        description: "Genomics: compresses one file (VCF, BED, GFF, FASTA, FASTQ, SAM…) to BGZF (`<path>.gz`), the format tabix/bcftools/samtools require. Keeps the original. Optionally writes the .gzi index.",
        inputSchema: schema(["path": str(pathDoc), "output": str("Output path (default: <path>.gz)."),
                             "level": int("bgzip level 0-9 (default 6).", min: 0, max: 9), "index": bool("Also write <output>.gzi.")],
                            required: ["path"]),
        readOnly: false, destructive: false, idempotent: false
    ) { args, ctx in
        let input = try ctx.policy.resolve(try args.requiredString("path"), mustExist: true)
        let output = try ctx.policy.resolve(args["output"]?.string ?? input + ".gz", mustExist: false)
        if FileManager.default.fileExists(atPath: output) { throw ToolError("\(output) already exists") }
        var o = CreateOptions()
        o.format = .bgzf
        o.level = args["level"]?.int
        o.writeBGZFIndex = args.optionalBool("index")
        o.workload = ctx.config.workload
        let r = try Xipper.create(from: [URL(fileURLWithPath: input)], to: URL(fileURLWithPath: output), options: o,
                                  progress: ctx.progress, cancel: ctx.cancel)
        return ToolResult(text: "Created \(output) (BGZF): \(bytes(r.inputBytes)) → \(bytes(r.outputBytes))" + (o.writeBGZFIndex ? " + .gzi" : ""),
                          structured: ["output": .string(output), "inputBytes": .int(r.inputBytes), "outputBytes": .int(r.outputBytes),
                                       "index": o.writeBGZFIndex ? .string(output + ".gzi") : .null])
    }

    static let bgzfConvert = Tool(
        name: "bgzf_convert", title: "Convert gzip to BGZF",
        description: "Genomics: recompresses a plain-gzip file (e.g. a .vcf.gz that tabix rejects) as BGZF. Writes `output`, or replaces the file when in_place is true (requires the user's confirmation). Reports tabix/csi indexes that must be rebuilt.",
        inputSchema: schema(["path": str(pathDoc), "output": str("Output path (required unless in_place)."),
                             "in_place": bool("Replace the input file. Requires the user's confirmation."),
                             "index": bool("Also write the .gzi index.")],
                            required: ["path"]),
        readOnly: false, destructive: true, idempotent: true
    ) { args, ctx in
        let input = try ctx.policy.resolve(try args.requiredString("path"), mustExist: true)
        var output: URL?
        if args.optionalBool("in_place") {
            guard try ctx.confirm("Allow the assistant to rewrite \(input) as BGZF (same content, new compression)?") else {
                throw ToolError("the user declined rewriting \(input)")
            }
        } else {
            guard let out = args["output"]?.string else { throw ToolError("pass output, or in_place: true") }
            let resolved = try ctx.policy.resolve(out, mustExist: false)
            if FileManager.default.fileExists(atPath: resolved) { throw ToolError("\(resolved) already exists") }
            output = URL(fileURLWithPath: resolved)
        }
        let r = try Xipper.convert(URL(fileURLWithPath: input), to: output, format: .bgzf, writeIndex: args.optionalBool("index"),
                                   workload: ctx.config.workload, progress: ctx.progress, cancel: ctx.cancel)
        var text = "Converted to BGZF: \(r.output.path) (\(bytes(r.outputBytes)))"
        if !r.staleIndexes.isEmpty {
            text += "\nThese indexes no longer match and must be rebuilt (tabix -p vcf / samtools index): " + r.staleIndexes.map(\.lastPathComponent).joined(separator: ", ")
        }
        return ToolResult(text: text, structured: ["output": .string(r.output.path), "outputBytes": .int(r.outputBytes),
                                                   "staleIndexes": .array(r.staleIndexes.map { .string($0.path) })])
    }
}
