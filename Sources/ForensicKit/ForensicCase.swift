import CryptoKit
import Foundation
import Security
import XipperKit

/// A case folder (`NAME.xfcase`, docs/XIPPER_FORENSIC.md §3.2): the case record, a signed,
/// hash-chained log of every operator action, and one folder per evidence item with its forensic
/// XIZ archive and report. The archives are self-contained; the folder is the working index.
///
/// ```
/// 2026-117.xfcase/
///   case.json            the case record (its SHA-256 is in the log at every change)
///   case.log             JSON Lines, append-only: seq, t, event, by, key, prev, …, sig
///   evidence/R01/R01.xiz, R01.report.json, R01.report.pdf (each report with its .sig)
/// ```
public struct ForensicCase: Sendable {
    public let url: URL
    public static let fileExtension = "xfcase"
    /// The language of the printable reports this case writes.
    public var reportLanguage: ForensicPDF.Language = .it
    /// When set, reports say whether each time-stamp comes from a qualified service of this list.
    public var trustedList: TrustedList?

    var caseFile: URL { url.appendingPathComponent("case.json") }
    var logFile: URL { url.appendingPathComponent("case.log") }
    var evidenceFolder: URL { url.appendingPathComponent("evidence") }

    public init(at url: URL) throws {
        self.url = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: caseFile.path), FileManager.default.fileExists(atPath: logFile.path) else {
            throw XipperError.invalidArgument("\(url.path) is not a case folder (case.json and case.log missing)")
        }
    }

    private init(new url: URL) { self.url = url.standardizedFileURL }

    /// Creates the folder, the case record and the first log entry.
    public static func create(at url: URL, info: [String: String], signer: XizSigner, now: Date? = nil) throws -> ForensicCase {
        guard info["case_number"]?.isEmpty == false else { throw XipperError.invalidArgument("a case needs a case number") }
        if FileManager.default.fileExists(atPath: url.path) { throw XipperError.alreadyExists(path: url.path) }
        let c = ForensicCase(new: url)
        try FileManager.default.createDirectory(at: c.evidenceFolder, withIntermediateDirectories: true)
        let bytes = Self.json(info)
        try Data(bytes).write(to: c.caseFile, options: .withoutOverwriting)
        FileManager.default.createFile(atPath: c.logFile.path, contents: nil)
        try c.log("case created", ["case_number": info["case_number"]!, "case_sha256": Self.hex(Array(SHA256.hash(data: bytes)))],
                  signer: signer, now: now)
        return c
    }

    public var info: [String: String] {
        get throws { try Self.object(Array(Data(contentsOf: caseFile))) }
    }

    /// Replaces the case record; the log keeps the old and new hashes.
    public func update(info new: [String: String], signer: XizSigner, now: Date? = nil) throws {
        let old = try Array(Data(contentsOf: caseFile))
        let bytes = Self.json(new)
        try Data(bytes).write(to: caseFile, options: .atomic)
        try log("case updated", ["previous_sha256": Self.hex(Array(SHA256.hash(data: old))), "case_sha256": Self.hex(Array(SHA256.hash(data: bytes)))],
                signer: signer, now: now)
    }

    // MARK: log

    public struct LogEntry: Sendable {
        public var seq: Int
        public var time: String
        public var event: String
        public var by: String
        public var key: String
        public var fields: [String: String]
        public var line: String
    }

    static let reserved: Set<String> = ["seq", "t", "event", "by", "key", "prev", "sig"]

    /// Appends a signed entry chained to the previous one: `prev` is the SHA-256 of the previous
    /// line, `sig` an Ed25519 signature of the line up to it.
    public func log(_ event: String, _ fields: [String: String] = [:], signer: XizSigner, now: Date? = nil) throws {
        let handle = try FileHandle(forUpdating: logFile)
        defer { try? handle.close() }
        guard flock(handle.fileDescriptor, LOCK_EX) == 0 else { throw XipperError.invalidArgument("case log is locked") }
        let existing = try handle.readToEnd() ?? Data()
        let lines = existing.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        let prev = lines.last.map { Self.hex(Array(SHA256.hash(data: $0))) } ?? String(repeating: "0", count: 64)
        var d = fields.filter { !Self.reserved.contains($0.key) }
        d["seq"] = String(lines.count + 1)
        d["t"] = Self.timestamp(now ?? Date())
        d["event"] = event
        d["by"] = signer.label
        d["key"] = Self.keyText(signer)
        d["prev"] = prev
        let body = Self.json(d)
        let sig = try signer.sign(body)
        let line = Array(body.dropLast()) + Array(",\"sig\":\"\(Self.base64url(Array(sig)))\"}\n".utf8)
        if !existing.isEmpty && existing.last != UInt8(ascii: "\n") { try handle.write(contentsOf: Data([UInt8(ascii: "\n")])) }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line))
        try handle.synchronize()
    }

    public func entries() throws -> [LogEntry] {
        let data = try Data(contentsOf: logFile)
        return try data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).map { raw in
            let o = try Self.object(Array(raw))
            return LogEntry(seq: Int(o["seq"] ?? "") ?? 0, time: o["t"] ?? "", event: o["event"] ?? "", by: o["by"] ?? "",
                            key: o["key"] ?? "", fields: o.filter { !Self.reserved.contains($0.key) }, line: String(decoding: raw, as: UTF8.self))
        }
    }

    public struct Verification: Sendable {
        public var entries: Int
        public var problems: [String]
        /// Signing keys seen in the log, with their labels.
        public var signers: [String: String]
        public var passed: Bool { problems.isEmpty }
    }

    /// Checks the log (sequence, chain, signatures), the case record against its last logged hash,
    /// and every archive and report the log names against the SHA-256 logged when it was written.
    public func verify() throws -> Verification {
        var problems: [String] = []
        var signers: [String: String] = [:]
        let data = try Data(contentsOf: logFile)
        if !data.isEmpty && data.last != UInt8(ascii: "\n") { problems.append("the log does not end with a complete line") }
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        var prev = String(repeating: "0", count: 64)
        var caseSHA: String?
        var archives: [String: String] = [:]
        for (i, raw) in lines.enumerated() {
            let bytes = Array(raw)
            guard let o = try? Self.object(bytes) else { problems.append("line \(i + 1): not JSON"); continue }
            if o["seq"] != String(i + 1) { problems.append("line \(i + 1): sequence \(o["seq"] ?? "?")") }
            if o["prev"] != prev { problems.append("line \(i + 1): chain broken (a line was removed, changed or inserted before it)") }
            let marker = Array(",\"sig\":\"".utf8)
            if let at = Self.lastRange(of: marker, in: bytes), let sig = o["sig"].flatMap(Self.unbase64url), let key = o["key"] {
                let body = Array(bytes[..<at]) + [UInt8(ascii: "}")]
                if !Self.verifySignature(key: key, message: body, signature: sig) { problems.append("line \(i + 1): signature invalid") }
                signers[Self.keyID(key)] = o["by"] ?? ""
            } else {
                problems.append("line \(i + 1): unsigned")
            }
            if let s = o["case_sha256"] { caseSHA = s }
            for k in ["archive", "report", "pdf"] { if let a = o[k], let s = o[k + "_sha256"] { archives[a] = s } }
            prev = Self.hex(Array(SHA256.hash(data: bytes)))
        }
        if lines.isEmpty { problems.append("empty log") }
        if let caseSHA, let bytes = try? Data(contentsOf: caseFile), Self.hex(Array(SHA256.hash(data: bytes))) != caseSHA {
            problems.append("case.json differs from the version recorded in the log")
        }
        for (rel, sha) in archives.sorted(by: { $0.key < $1.key }) {
            let u = url.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: u.path) else { problems.append("\(rel): missing"); continue }
            if let h = try? Self.fileSHA256(u), h != sha {
                // Custody segments append to the archive: the log records the new hash each time.
                problems.append("\(rel): SHA-256 differs from the last one logged")
            }
        }
        return Verification(entries: lines.count, problems: problems, signers: signers)
    }

    // MARK: evidence

    public struct Evidence: Sendable {
        public var id: String
        public var folder: URL
        public var archive: URL
        public var report: URL
        /// The printable report next to the JSON one, rendered from it.
        public var pdf: URL { URL(fileURLWithPath: String(report.path.dropLast(5)) + ".pdf") }
    }

    public func evidence() throws -> [Evidence] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: evidenceFolder.path)) ?? []
        return names.sorted().compactMap { id in
            let folder = evidenceFolder.appendingPathComponent(id)
            let archive = folder.appendingPathComponent(id + ".xiz")
            guard FileManager.default.fileExists(atPath: archive.path) else { return nil }
            return Evidence(id: id, folder: folder, archive: archive, report: folder.appendingPathComponent(id + ".report.json"))
        }
    }

    /// R01, R02, … (the first number not used by a folder).
    public func nextEvidenceID() -> String {
        let used = Set((try? FileManager.default.contentsOfDirectory(atPath: evidenceFolder.path)) ?? [])
        var n = 1
        while used.contains(String(format: "R%02d", n)) { n += 1 }
        return String(format: "R%02d", n)
    }

    func prepare(_ id: String) throws -> Evidence {
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else { throw XipperError.invalidArgument("invalid evidence number \(id)") }
        let folder = evidenceFolder.appendingPathComponent(id)
        if FileManager.default.fileExists(atPath: folder.path) { throw XipperError.alreadyExists(path: folder.path) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Evidence(id: id, folder: folder, archive: folder.appendingPathComponent(id + ".xiz"),
                        report: folder.appendingPathComponent(id + ".report.json"))
    }

    func relative(_ u: URL) -> String { String(u.standardizedFileURL.path.dropFirst(url.path.count + 1)) }

    /// Acquires an image into evidence/ID/ID.xiz, with the case record, then writes the signed report.
    public func acquireImage(from source: String, evidence id: String, options: XizForensic.ImageOptions, signer: XizSigner,
                             progress: ProgressHandler? = nil, cancel: CancellationToken? = nil) throws -> (Evidence, XizForensic.ImageReport) {
        try acquireImage(from: XizForensic.ImageSource(path: source), evidence: id, options: options, signer: signer,
                         progress: progress, cancel: cancel)
    }

    /// Acquires an opened source (a disk through `DeviceAccess`) into evidence/ID/ID.xiz.
    public func acquireImage(from reader: XizForensic.ImageSource, evidence id: String, options: XizForensic.ImageOptions, signer: XizSigner,
                             progress: ProgressHandler? = nil, cancel: CancellationToken? = nil) throws -> (Evidence, XizForensic.ImageReport) {
        let source = reader.name
        var o = options
        o.caseInfo = try info.merging(["evidence_number": id], uniquingKeysWith: { _, n in n }).merging(options.caseInfo, uniquingKeysWith: { _, n in n })
        let e = try prepare(id)
        try log("acquisition started", ["evidence": id, "method": o.volume ? "volume" : "physical",
                                        "source": (source as NSString).lastPathComponent], signer: signer, now: o.now)
        let r: XizForensic.ImageReport
        do {
            r = try XizForensic.acquireImage(from: reader, to: e.archive.path, options: o, signer: signer, progress: progress, cancel: cancel)
        } catch {
            try? log("acquisition failed", ["evidence": id, "error": "\(error)"], signer: signer)
            try? FileManager.default.removeItem(at: e.folder)
            throw error
        }
        var fields = ["source_sha256": Self.hex(r.sha256), "size": String(r.size)]
        if r.unreadableBytes > 0 { fields["unreadable_bytes"] = String(r.unreadableBytes) }
        try finishAcquisition(e, fields: fields, password: o.password, signer: signer, now: o.now)
        return (e, r)
    }

    /// Acquires files and folders into evidence/ID/ID.xiz, then writes the signed report.
    public func acquireLogical(_ sources: [URL], evidence id: String, options: XizForensic.LogicalOptions, signer: XizSigner,
                               progress: ProgressHandler? = nil, cancel: CancellationToken? = nil) throws -> (Evidence, XizForensic.LogicalReport) {
        var o = options
        o.caseInfo = try info.merging(["evidence_number": id], uniquingKeysWith: { _, n in n }).merging(options.caseInfo, uniquingKeysWith: { _, n in n })
        let e = try prepare(id)
        try log("acquisition started", ["evidence": id, "method": "logical", "sources": sources.map(\.lastPathComponent).joined(separator: ", ")],
                signer: signer, now: o.now)
        let r: XizForensic.LogicalReport
        do {
            r = try XizForensic.acquireLogical(sources, to: e.archive.path, options: o, signer: signer, progress: progress, cancel: cancel)
        } catch {
            try? log("acquisition failed", ["evidence": id, "error": "\(error)"], signer: signer)
            try? FileManager.default.removeItem(at: e.folder)
            throw error
        }
        try finishAcquisition(e, fields: ["files": String(r.files), "bytes": String(r.bytes), "skipped": String(r.skipped.count),
                                          "inventory_sha256": Self.hex(r.inventorySHA256)], password: o.password, signer: signer, now: o.now)
        return (e, r)
    }

    func finishAcquisition(_ e: Evidence, fields: [String: String], password: String?, signer: XizSigner, now: Date?) throws {
        var f = fields
        f["evidence"] = e.id
        f["archive"] = relative(e.archive)
        f["archive_sha256"] = try Self.fileSHA256(e.archive)
        try log("acquisition finished", f, signer: signer, now: now)
        try writeReports(e, password: password, signer: signer, now: now)
    }

    /// The JSON report and the PDF rendered from it, both with a detached signature, replacing
    /// earlier ones; their hashes go into the log.
    public func writeReports(_ e: Evidence, password: String? = nil, signer: XizSigner, now: Date? = nil) throws {
        for u in [e.report, e.pdf] {
            try? FileManager.default.removeItem(at: u)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: u.path + ".sig"))
        }
        let object = try ForensicReport.write(archive: e.archive, to: e.report, password: password, signer: signer, now: now,
                                              trustedList: trustedList)
        try ForensicPDF.render(object, language: reportLanguage).write(to: e.pdf, options: .withoutOverwriting)
        try ForensicReport.sign(e.pdf, signer: signer)
        try log("report written", ["evidence": e.id, "report": relative(e.report), "report_sha256": try Self.fileSHA256(e.report),
                                   "pdf": relative(e.pdf), "pdf_sha256": try Self.fileSHA256(e.pdf)], signer: signer, now: now)
    }

    /// Records a hand-over in the archive (custody segment) and in the case log, and refreshes the report.
    public func custody(evidence id: String, from: String, to: String, fields: [String: String] = [:], signer: XizSigner,
                        password: String? = nil, now: Date? = nil) throws {
        guard let e = try evidence().first(where: { $0.id == id }) else { throw XipperError.invalidArgument("no evidence \(id) in the case") }
        var c = fields
        c["from"] = from
        c["to"] = to
        try XizForensic.appendCustody(to: e.archive.path, custody: c, signer: signer, now: now)
        var l = c
        l["evidence"] = id
        l["archive"] = relative(e.archive)
        l["archive_sha256"] = try Self.fileSHA256(e.archive)
        try log("custody", l, signer: signer, now: now)
        try writeReports(e, password: password, signer: signer, now: now)
    }

    // MARK: helpers

    static func json(_ d: [String: String]) -> [UInt8] {
        Array((try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8))
    }

    static func object(_ b: [UInt8]) throws -> [String: String] {
        guard let o = try JSONSerialization.jsonObject(with: Data(b)) as? [String: Any] else { throw XipperError.corrupt("not a JSON object") }
        return o.compactMapValues { ($0 as? String) ?? ($0 as? NSNumber)?.stringValue }
    }

    static func timestamp(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    public static func fileSHA256(_ u: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: u)
        defer { try? h.close() }
        var sha = SHA256()
        while let d = try h.read(upToCount: 8 << 20), !d.isEmpty { sha.update(data: d) }
        return hex(Array(sha.finalize()))
    }

    static func base64url(_ b: [UInt8]) -> String {
        Data(b).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func unbase64url(_ s: String) -> [UInt8]? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t).map { Array($0) }
    }

    /// `xizsig1…` → the 32-byte Ed25519 public key.
    /// The signer as written next to a signature: `xizsig1…` (Ed25519) or `x509:` + the certificate (DER, base64url).
    public static func keyText(_ signer: XizSigner) -> String {
        if let c = signer.certificate, let leaf = c.chain.first { return "x509:" + base64url(leaf) }
        return signer.key.publicText
    }

    /// A short, stable name for a key text: the Ed25519 key itself, or `x509:` + the certificate's SHA-256.
    public static func keyID(_ text: String) -> String {
        guard text.hasPrefix("x509:"), let der = unbase64url(String(text.dropFirst(5))) else { return text }
        return "x509:" + hex(Array(SHA256.hash(data: der)))
    }

    /// The certificate behind a key text, when it is one.
    public static func certificate(_ text: String) -> XizCertificateInfo? {
        guard text.hasPrefix("x509:"), let der = unbase64url(String(text.dropFirst(5))) else { return nil }
        return XizCertificateInfo(der)
    }

    /// Checks a detached signature made by `keyText` (Ed25519, or the certificate's ECDSA P-256 / RSA key).
    public static func verifySignature(key text: String, message: [UInt8], signature: [UInt8]) -> Bool {
        if let pub = publicKey(text), let k = try? Curve25519.Signing.PublicKey(rawRepresentation: pub) {
            return k.isValidSignature(signature, for: message)
        }
        guard text.hasPrefix("x509:"), let der = unbase64url(String(text.dropFirst(5))),
              let cert = SecCertificateCreateWithData(nil, Data(der) as CFData), let key = SecCertificateCopyKey(cert),
              let attrs = SecKeyCopyAttributes(key) as? [String: Any], let type = attrs[kSecAttrKeyType as String] as? String else { return false }
        let alg: SecKeyAlgorithm = type == (kSecAttrKeyTypeECSECPrimeRandom as String) ? .ecdsaSignatureMessageX962SHA256 : .rsaSignatureMessagePKCS1v15SHA256
        return SecKeyVerifySignature(key, alg, Data(message) as CFData, Data(signature) as CFData, nil)
    }

    static func publicKey(_ text: String) -> [UInt8]? {
        guard text.hasPrefix("xizsig1"), let k = unbase64url(String(text.dropFirst(7))), k.count == 32 else { return nil }
        return k
    }

    static func lastRange(of needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        var i = hay.count - needle.count
        while i >= 0 {
            if Array(hay[i..<(i + needle.count)]) == needle { return i }
            i -= 1
        }
        return nil
    }
}
