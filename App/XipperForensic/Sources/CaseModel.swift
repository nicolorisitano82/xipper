import ForensicKit
import Foundation
import SwiftUI
import XipperKit

/// One evidence item as the case window shows it: from its report (fast, no re-verification).
struct EvidenceItem: Identifiable, Sendable {
    var id: String
    var evidence: ForensicCase.Evidence
    var passed: Bool?
    var warnings: Bool
    var method: String
    var description: String
    var model: String
    var serial: String
    var sourceSize: Int64
    var sourceSHA256: String
    var md5: String?
    var sha1: String?
    var archiveSHA256: String
    var archiveBytes: Int64
    var signers: [String]
    var timestamped: Bool
    var custody: Int
    var files: String?
    var skipped: Int

    init(_ e: ForensicCase.Evidence) {
        id = e.id
        evidence = e
        let r = (try? JSONSerialization.jsonObject(with: Data(contentsOf: e.report))) as? [String: Any] ?? [:]
        passed = r["passed"] as? Bool
        let checks = r["checks"] as? [[String: String]] ?? []
        let acq = (r["acquisitions"] as? [[String: String]])?.first ?? [:]
        let dev = (r["devices"] as? [[String: String]])?.first ?? [:]
        let src = (r["source_hashes"] as? [[String: Any]])?.first ?? [:]
        let arc = r["archive"] as? [String: Any] ?? [:]
        let seg = r["segments"] as? [[String: Any]] ?? []
        method = acq["method"] ?? ""
        description = (r["case"] as? [String: String])?["description"] ?? dev["description"] ?? ""
        model = dev["model"] ?? ""
        serial = dev["serial"] ?? ""
        sourceSize = Int64(acq["source_size"] ?? acq["bytes"] ?? "") ?? 0
        sourceSHA256 = src["sha256"] as? String ?? acq["inventory_sha256"] ?? ""
        md5 = src["md5"] as? String
        sha1 = src["sha1"] as? String
        archiveSHA256 = arc["sha256"] as? String ?? ""
        archiveBytes = (arc["bytes"] as? NSNumber)?.int64Value ?? 0
        signers = Array(NSOrderedSet(array: seg.compactMap { $0["signer"] as? String })) as? [String] ?? []
        timestamped = seg.contains { $0["timestamp"] != nil }
        custody = (r["custody"] as? [Any])?.count ?? 0
        files = acq["files"]
        skipped = Int(acq["skipped"] ?? "0") ?? 0
        let unreadable = (r["unreadable"] as? [Any])?.isEmpty == false
        warnings = checks.contains { $0["status"] == "warning" } || unreadable || skipped > 0
    }
}

@MainActor @Observable
final class CaseModel {
    let url: URL
    private(set) var forensicCase: ForensicCase?
    var info: [String: String] = [:]
    var items: [EvidenceItem] = []
    var entries: [ForensicCase.LogEntry] = []
    var verification: ForensicCase.Verification?
    var verifying = false
    var error: String?

    init(url: URL) {
        self.url = url
        do { forensicCase = try ForensicCase(at: url) } catch { self.error = error.localizedDescription }
        reload()
    }

    var title: String { info["case_number"] ?? url.deletingPathExtension().lastPathComponent }

    func reload() {
        guard var c = forensicCase else { return }
        c.reportLanguage = Prefs.shared.reportLanguage
        forensicCase = c
        info = (try? c.info) ?? [:]
        items = ((try? c.evidence()) ?? []).map(EvidenceItem.init)
        entries = (try? c.entries()) ?? []
    }

    func entries(for id: String) -> [ForensicCase.LogEntry] { entries.filter { $0.fields["evidence"] == id } }

    /// Runs `work` off the main actor with the operator's signer, then reloads.
    func signed(_ work: @escaping @Sendable (ForensicCase, XizSigner) throws -> Void) async -> Bool {
        guard let c = forensicCase else { return false }
        do {
            let s = try Prefs.shared.signer()
            let country = Prefs.shared.trustedListCountry
            try await Task.detached {
                var c = c
                // Reports say whether time-stamps are qualified; a list that cannot be fetched only leaves that out.
                if !country.isEmpty { c.trustedList = try? TrustedList.load(country: country) }
                try work(c, s)
            }.value
            reload()
            return true
        } catch {
            self.error = error.localizedDescription
            reload()
            return false
        }
    }

    func note(_ text: String) async {
        _ = await signed { c, s in try c.log("note", ["text": text], signer: s) }
    }

    func update(_ new: [String: String]) async {
        _ = await signed { c, s in try c.update(info: new, signer: s) }
    }

    func verifyCase() async {
        guard let c = forensicCase else { return }
        verifying = true
        defer { verifying = false }
        do { verification = try await Task.detached { try c.verify() }.value } catch { self.error = error.localizedDescription }
    }

    /// Verifies one archive again, logs the outcome and rewrites its reports.
    func reverify(_ id: String) async {
        verifying = true
        defer { verifying = false }
        _ = await signed { c, s in
            guard let e = try c.evidence().first(where: { $0.id == id }) else { return }
            let r = try XizForensic.verify(e.archive.path)
            let failed = r.checks.filter { $0.status == .failed }.map(\.name)
            try c.log("evidence verified", ["evidence": id, "passed": r.passed ? "true" : "false",
                                            "failed": failed.joined(separator: ", ")], signer: s)
            try c.writeReports(e, signer: s)
        }
    }

    var busy: String?

    /// Raw or E01 export of an image, logged.
    func export(_ id: String, raw: URL?, e01: URL?) async -> Bool {
        busy = String(localized: "Exporting…")
        defer { busy = nil }
        return await signed { c, s in _ = try c.export(evidence: id, raw: raw, e01: e01, signer: s) }
    }

    /// A delivery copy, its receipt and the custody segment; the copy's folder on success.
    func deliver(_ id: String, _ o: Delivery.Options) async -> URL? {
        busy = String(localized: "Preparing the copy…")
        defer { busy = nil }
        final class Box: @unchecked Sendable { var url: URL? }
        let box = Box()
        let ok = await signed { c, s in box.url = try c.deliver(evidence: id, options: o, signer: s).folder }
        return ok ? box.url : nil
    }

    func custody(_ id: String, from: String, to: String, fields: [String: String]) async -> Bool {
        await signed { c, s in try c.custody(evidence: id, from: from, to: to, fields: fields, signer: s) }
    }
}

/// Names of log events as the operator reads them.
enum Words {
    static func event(_ e: String) -> String {
        switch e {
        case "case created": String(localized: "Case created")
        case "case updated": String(localized: "Case record changed")
        case "note": String(localized: "Note")
        case "acquisition started": String(localized: "Acquisition started")
        case "acquisition finished": String(localized: "Acquisition finished")
        case "acquisition failed": String(localized: "Acquisition failed")
        case "acquisition interrupted": String(localized: "Acquisition interrupted")
        case "report written": String(localized: "Report written")
        case "custody": String(localized: "Hand-over")
        case "evidence verified": String(localized: "Verified again")
        case "source checks": String(localized: "Checks before starting")
        case "evidence exported": String(localized: "Exported")
        case "evidence delivered": String(localized: "Copy delivered")
        case "import failed": String(localized: "Import failed")
        case "share mounted": String(localized: "Shared disk connected read-only")
        case "disk unmounted": String(localized: "Disk volumes unmounted")
        case "mounts refused": String(localized: "Mounts refused during the acquisition")
        default: e
        }
    }

    static func method(_ m: String) -> String {
        switch m {
        case "logical": String(localized: "logical (files and folders)")
        case "E01 import": String(localized: "E01 imported")
        case "delivery copy": String(localized: "delivery copy")
        case "physical": String(localized: "physical (disk image)")
        case "volume": String(localized: "volume")
        default: m
        }
    }

    static func check(_ c: String) -> String {
        switch c {
        case "structure": String(localized: "File structure")
        case "segments": String(localized: "Segments")
        case "frame hashes": String(localized: "Hash of every frame")
        case "signatures": String(localized: "Segment signatures and chain")
        case "time-stamps": String(localized: "Time-stamps")
        case "images": String(localized: "Image: source hash")
        case "files": String(localized: "Files: signed inventory")
        case "expected SHA-256": String(localized: "SHA-256 from the written record")
        case "content": String(localized: "Content")
        case "certificates": String(localized: "Signer certificates")
        case "qualified time-stamps": String(localized: "Qualified time-stamps (EU trusted list)")
        default: c
        }
    }

    static func field(_ k: String) -> String {
        switch k {
        case "case_number": String(localized: "Case number")
        case "title": String(localized: "Title")
        case "proceeding": String(localized: "Proceeding")
        case "court": String(localized: "Authority")
        case "examiner": String(localized: "Examiner")
        case "organization": String(localized: "Organization")
        case "location": String(localized: "Location")
        case "notes": String(localized: "Notes")
        default: k.replacingOccurrences(of: "_", with: " ")
        }
    }

    static func readErrors(_ r: XizForensic.ReadErrors) -> String {
        switch r.name {
        case "fast": String(localized: "Fast: one read, 64 KiB given up per error")
        case "exhaustive": String(localized: "Exhaustive: down to the sector, 8 reads each")
        default: String(localized: "Standard: down to the sector, 2 reads each")
        }
    }

    static func access(_ p: DeviceAccess.Problem) -> String {
        switch p {
        case .helperMissing: String(localized: "The disk helper is not installed: install it in Settings")
        case .helperNeedsApproval: String(localized: "The disk helper waits for approval: System Settings › General › Login Items & Extensions")
        case .fullDiskAccess: String(localized: "The disk helper needs Full Disk Access: System Settings › Privacy & Security › Full Disk Access, then add xipper-forensic-helper")
        default: p.localizedDescription
        }
    }

    /// Common partition types by their GUID or name.
    static func partition(_ content: String) -> String {
        switch content.uppercased() {
        case "7C3457EF-0000-11AA-AA11-00306543ECAC", "APPLE_APFS": "APFS"
        case "48465300-0000-11AA-AA11-00306543ECAC", "APPLE_HFS": "Mac OS Extended (HFS+)"
        case "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", "MICROSOFT BASIC DATA": String(localized: "Windows data (FAT, exFAT, NTFS)")
        case "C12A7328-F81F-11D2-BA4B-00A0C93EC93B", "EFI": "EFI"
        case "0FC63DAF-8483-4772-8E79-3D69D8477DE4": "Linux"
        case "69646961-6700-11AA-AA11-00306543ECAC": "Apple ISC"
        case "52637672-7900-11AA-AA11-00306543ECAC": "Apple Recovery"
        case "DOS_FAT_32": "FAT32"
        case "DOS_FAT_16": "FAT16"
        case "WINDOWS_NTFS": "NTFS"
        default: content.isEmpty ? String(localized: "partition") : content
        }
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    static func time(_ iso: String) -> String {
        let p = ISO8601DateFormatter()
        p.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = p.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return iso }
        var f = Date.FormatStyle(date: .abbreviated, time: .standard)
        f.timeZone = TimeZone(identifier: "UTC")!
        return d.formatted(f) + " UTC"
    }
}

/// ✔ ⚠ ✖ as icons, everywhere the same.
struct StatusIcon: View {
    enum State { case passed, warning, failed, skipped, running }
    let state: State

    var body: some View {
        switch state {
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        }
    }

    init(_ s: State) { state = s }
    init(check s: XizForensic.Check.Status) {
        state = switch s { case .passed: .passed; case .warning: .warning; case .failed: .failed; case .skipped: .skipped }
    }
}
