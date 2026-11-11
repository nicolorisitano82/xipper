import CryptoKit
import Foundation
import XipperKit

/// The acquisition report (docs/XIPPER_FORENSIC.md §4.7): a JSON document built from the archive
/// alone (its records and a full verification), signed with a detached Ed25519 signature
/// (`REPORT.sig`). The PDF for the written record is generated from this JSON (P3).
public enum ForensicReport {
    public static let format = "xipper-forensic-report-1"
    public static let toolVersion = "0.9.0"

    /// The report as a JSON object (string keys; values are strings, numbers, booleans, arrays, objects).
    public static func build(archive: URL, password: String? = nil, expectSHA256: [UInt8]? = nil, now: Date? = nil,
                             trustedList: TrustedList? = nil) throws -> [String: Any] {
        let path = archive.path
        let verification = try XizForensic.verify(path, password: password, expectSHA256: expectSHA256)
        let blocks = verification.blocks
        func json(_ t: XizForensic.RecordType) -> [[String: String]] {
            blocks.flatMap { b in b.records(t).map { r in r.json.merging(["segment": String(b.segment)], uniquingKeysWith: { a, _ in a }) } }
        }
        var sources: [[String: Any]] = []
        var unreadable: [[String: Any]] = []
        for b in blocks {
            for r in b.records(.sourceHashes) {
                guard let s = try? XizForensic.SourceHashes(r.value) else { continue }
                var d: [String: Any] = ["path": s.path, "size": s.size, "sha256": XizForensic.hex(s.sha256),
                                        "started": ForensicCase.timestamp(s.started), "finished": ForensicCase.timestamp(s.finished)]
                if let m = s.md5 { d["md5"] = XizForensic.hex(m) }
                if let h = s.sha1 { d["sha1"] = XizForensic.hex(h) }
                sources.append(d)
            }
            for r in b.records(.unreadable) {
                guard let u = try? XizForensic.Unreadable(r.value) else { continue }
                let ranges: [[String: Any]] = u.ranges.map { x -> [String: Any] in
                    ["offset": x.offset, "length": x.length, "error": Int(x.error), "attempts": Int(x.attempts)]
                }
                let bytes: UInt64 = u.ranges.reduce(0) { $0 + $1.length }
                unreadable.append(["path": u.path, "bytes": bytes, "ranges": ranges])
            }
        }
        let segments: [[String: Any]] = verification.signatures.map { s in
            var d: [String: Any] = ["segment": s.segment, "signed": s.signed, "signer": s.label, "key": s.publicKeyText,
                                    "signature_valid": s.valid, "chain_ok": s.chained]
            if let t = s.time { d["time"] = ForensicCase.timestamp(t) }
            if let ts = s.timestamp {
                var td: [String: Any] = ["time": ForensicCase.timestamp(ts.time), "authority": ts.authority, "trusted": ts.trusted]
                if let tl = trustedList {
                    if let q = tl.qualified(ts) { td["qualified"] = ["provider": q.provider, "service": q.name, "list": tl.country] }
                    else { td["qualified"] = false }
                }
                d["timestamp"] = td
            }
            if let c = s.certificate {
                var cd: [String: Any] = ["subject": c.subject, "issuer": c.issuer, "serial": c.serial, "sha256": c.fingerprint,
                                         "trusted": c.trusted, "valid_at_signing": c.validAtSigning,
                                         "algorithm": s.algorithm == 2 ? "ECDSA P-256 SHA-256" : "RSA PKCS#1 v1.5 SHA-256"]
                if let a = c.notBefore { cd["not_before"] = ForensicCase.timestamp(a) }
                if let b = c.notAfter { cd["not_after"] = ForensicCase.timestamp(b) }
                d["certificate"] = cd
            }
            return d
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let name = archive.lastPathComponent
        var commands = ["shasum -a 256 \(name)",
                        "xipper-forensic verify \(name)",
                        "xiz forensic \(name)    # libxiz, an independent implementation of the format"]
        if let s = sources.first, let p = s["path"] as? String {
            commands.append("xiz cat \(name) \(p) | shasum -a 256    # must print \(s["sha256"] as? String ?? "")")
        }
        return [
            "format": format,
            "tool": "xipper-forensic", "tool_version": toolVersion,
            "generated": ForensicCase.timestamp(now ?? Date()),
            "archive": ["name": name, "bytes": (attrs[.size] as? NSNumber)?.int64Value ?? 0, "sha256": try ForensicCase.fileSHA256(archive)] as [String: Any],
            "case": json(.caseInfo).first ?? [:],
            "devices": json(.device),
            "acquisitions": json(.acquisition),
            "source_hashes": sources,
            "unreadable": unreadable,
            "custody": json(.custody),
            "segments": segments,
            "checks": verification.checks.map { ["name": $0.name, "status": $0.status.rawValue, "detail": $0.detail] } + qualifiedCheck(verification, trustedList),
            "passed": verification.passed,
            "how_to_verify": commands,
            "limits": [
                "XIZ makes tampering evident, not impossible: compare the archive's SHA-256 with the one in the written record.",
                "Removing the last segments of an archive leaves a valid archive: the number of custody records belongs in the written record too.",
            ],
        ]
    }

    /// Writes the report and, with a signer, `REPORT.sig` next to it.
    /// "qualified time-stamps": every time-stamp from a service granted in the trusted list at its time.
    static func qualifiedCheck(_ v: XizForensic.Report, _ tl: TrustedList?) -> [[String: String]] {
        guard let tl else { return [] }
        let stamped = v.signatures.compactMap(\.timestamp)
        guard !stamped.isEmpty else { return [] }
        let q = stamped.compactMap { tl.qualified($0) }
        let names = Array(Set(q.map { "\($0.provider): \($0.name)" })).sorted().joined(separator: "; ")
        return [["name": "qualified time-stamps", "status": q.count == stamped.count ? "passed" : "warning",
                 "detail": "\(q.count) of \(stamped.count) from qualified services in the \(tl.country) trusted list no. \(tl.sequence)"
                    + (names.isEmpty ? "" : " (\(names))")]]
    }

    @discardableResult
    public static func write(archive: URL, to report: URL, password: String? = nil, signer: XizSigner?, now: Date? = nil,
                             trustedList: TrustedList? = nil) throws -> [String: Any] {
        var object = try build(archive: archive, password: password, now: now, trustedList: trustedList)
        if let tl = trustedList { object["trusted_list"] = tl.record }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: report, options: .withoutOverwriting)
        if let signer { try sign(report, signer: signer) }
        return object
    }

    static func signatureURL(_ report: URL) -> URL { URL(fileURLWithPath: report.path + ".sig") }

    /// A detached signature: `{"file","sha256","signer","key","signature"}`.
    public static func sign(_ file: URL, signer: XizSigner) throws {
        let bytes = try Data(contentsOf: file)
        let sig = try signer.sign(Array(bytes))
        let d = ["file": file.lastPathComponent, "sha256": ForensicCase.hex(Array(SHA256.hash(data: bytes))), "signer": signer.label,
                 "key": ForensicCase.keyText(signer), "signature": ForensicCase.base64url(Array(sig))]
        try Data(ForensicCase.json(d)).write(to: signatureURL(file), options: .atomic)
    }

    public struct Signature: Sendable {
        public var valid: Bool
        public var signer: String
        public var key: String
        public var certificate: XizCertificateInfo?
    }

    public static func verifySignature(_ file: URL) throws -> Signature {
        let d = try ForensicCase.object(Array(Data(contentsOf: signatureURL(file))))
        let bytes = try Data(contentsOf: file)
        guard let key = d["key"], let sig = d["signature"].flatMap(ForensicCase.unbase64url) else {
            return Signature(valid: false, signer: d["signer"] ?? "", key: d["key"] ?? "")
        }
        return Signature(valid: ForensicCase.verifySignature(key: key, message: Array(bytes), signature: sig), signer: d["signer"] ?? "",
                         key: ForensicCase.keyID(key), certificate: ForensicCase.certificate(key))
    }
}
