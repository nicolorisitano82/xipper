import CryptoKit
import Foundation
import XipperKit

/// A copy of an evidence item for someone (docs/XIPPER_FORENSIC.md §4.7): what, to whom, in which
/// format; the copy goes into its own folder with a signed receipt, and the original archive gains a
/// custody segment that names the recipient and the copy's hash.
public enum Delivery {
    public enum Format: String, Sendable, CaseIterable {
        /// A forensic XIZ: an image is copied into a new archive (same image hashes, new access, signed by
        /// whoever delivers it, "derived from" the original); a logical acquisition is copied as it is.
        case xiz
        /// The image as raw bytes, with a text file of its hashes.
        case raw
        /// The image as E01.
        case e01
        /// Logical acquisitions: some files, each with its inclusion proof (xiz-proof-1) against the
        /// signed archive, without the rest.
        case files
    }

    public struct Options: Sendable {
        /// Who receives it (name, office): in the receipt and in the custody segment.
        public var recipient: String
        public var format: Format = .xiz
        /// XIZ copy of an image: a password told to the recipient separately.
        public var password: String?
        /// XIZ copy of an image: the recipient's public keys (`xizpk1…`, `xizpq1…` post-quantum).
        public var recipientKeys: [String] = []
        /// `.files`: paths inside the archive.
        public var files: [String] = []
        /// Folder for the copy; default: CASE/deliveries/ID-recipient-date.
        public var destination: URL?
        public var reason = ""
        public var notes = ""
        public init(recipient: String) { self.recipient = recipient }
    }

    public struct Result: Sendable {
        public var folder: URL
        /// Every file of the copy with its SHA-256 (hex).
        public var files: [(URL, String)]
        public var receipt: URL
    }

    public static let receiptFormat = "xipper-forensic-delivery-1"
}

extension ForensicCase {
    /// Makes the copy, signs the receipt, appends the custody segment to the original and logs it all.
    public func deliver(evidence id: String, options o: Delivery.Options, signer: XizSigner, password: String? = nil,
                        progress: ProgressHandler? = nil, cancel: CancellationToken? = nil) throws -> Delivery.Result {
        guard !o.recipient.trimmingCharacters(in: .whitespaces).isEmpty else { throw XipperError.invalidArgument("delivery needs a recipient") }
        guard let e = try evidence().first(where: { $0.id == id }) else { throw XipperError.invalidArgument("no evidence \(id) in the case") }
        let image = try? XizForensic.storedImage(e.archive.path, password: password)
        switch o.format {
        case .raw, .e01: guard image != nil else { throw XipperError.invalidArgument("\(id) is a logical acquisition: deliver it as xiz or files") }
        case .files: guard image == nil, !o.files.isEmpty else { throw XipperError.invalidArgument("files: a logical acquisition and at least one path") }
        case .xiz: break
        }
        let now = Date()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd-HHmmss"
        let slug = o.recipient.map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce("") { $0 + String($1) }.prefix(40)
        let folder = o.destination ?? url.appendingPathComponent("deliveries/\(id)-\(slug)-\(f.string(from: now))")
        guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent("delivery.json").path) else { throw XipperError.alreadyExists(path: folder.path) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [URL] = []
        var access = "none"
        do {
            switch o.format {
            case .xiz where image != nil:
                let info = image!
                var io = XizForensic.ImageOptions()
                io.name = info.name
                io.logicalSector = info.logicalSector; io.physicalSector = info.physicalSector
                io.volume = info.volume; io.volumeOffset = info.volumeOffset
                io.md5 = info.source?.md5 != nil; io.sha1 = info.source?.sha1 != nil
                io.unreadable = info.unreadable
                io.readErrors = .init(name: "copy", attempts: 1, granularity: 0)
                io.caseInfo = info.caseInfo.merging(["delivered_to": o.recipient], uniquingKeysWith: { _, n in n })
                io.device = info.device
                var acq: [String: String] = ["method": "delivery copy", "recipient": o.recipient,
                                             "derived_from": "\(id) \(e.archive.lastPathComponent)",
                                             "derived_from_archive_sha256": Self.hex(info.archiveSHA256),
                                             "tool_version": ForensicReport.toolVersion]
                for (k, v) in info.acquisition where !["method", "started", "finished", "tool"].contains(k) { acq["original_" + k] = v }
                if let s = info.acquisition["started"] { acq["original_started"] = s }
                io.acquisition = acq
                var recipients: [XizAccess.Recipient] = []
                for k in o.recipientKeys { recipients.append(.init(label: o.recipient, credential: .publicKey(try XizIdentity.publicKey(fromText: k)))) }
                if !recipients.isEmpty {
                    if let p = o.password { recipients.append(.init(label: o.recipient + " (password)", credential: .password(p))) }
                    io.access = XizAccess(recipients: recipients)
                    access = "recipient keys" + (o.password != nil ? " and a password" : "")
                } else if let p = o.password {
                    io.password = p
                    access = "password (told separately)"
                }
                let out = folder.appendingPathComponent("\(id).xiz")
                let source = try XizForensic.imageSource(e.archive.path, password: password)
                let r = try XizForensic.acquireImage(from: source, to: out.path, options: io, signer: signer, progress: progress, cancel: cancel)
                guard let s = info.source, r.sha256 == s.sha256 else {
                    throw XipperError.integrity(entry: out.lastPathComponent, detail: "the copy's image differs from the acquired source")
                }
                files = [out]
            case .xiz:
                let out = folder.appendingPathComponent("\(id).xiz")
                try FileManager.default.copyItem(at: e.archive, to: out)
                access = password == nil ? "as acquired" : "as acquired (password of the original, told separately)"
                files = [out]
            case .raw:
                let out = folder.appendingPathComponent("\(id).dd")
                let r = try ForensicExport.raw(e.archive.path, to: out, password: password, progress: progress, cancel: cancel)
                let side = folder.appendingPathComponent("\(id).dd.hashes.txt")
                var text = "SHA-256  \(Self.hex(r.sha256))  \(out.lastPathComponent)\n"
                if let m = r.md5 { text += "MD5      \(Self.hex(m))  \(out.lastPathComponent)\n" }
                if let h = r.sha1 { text += "SHA-1    \(Self.hex(h))  \(out.lastPathComponent)\n" }
                try Data(text.utf8).write(to: side)
                files = [out, side]
            case .e01:
                files = try ForensicExport.e01(e.archive.path, to: folder.appendingPathComponent(id), password: password,
                                               progress: progress, cancel: cancel).files
            case .files:
                var x = ExtractOptions()
                x.password = password
                x.selection = Set(o.files)
                x.propagateQuarantine = false
                let content = folder.appendingPathComponent("files")
                try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
                _ = try Xipper.extract(e.archive, to: content, mode: .into, options: x, progress: progress, cancel: cancel)
                let proofs = folder.appendingPathComponent("proofs")
                try FileManager.default.createDirectory(at: proofs, withIntermediateDirectories: true)
                for p in o.files {
                    let proof = proofs.appendingPathComponent(p.replacingOccurrences(of: "/", with: "__") + ".proof.json")
                    try Xipper.xizProof(e.archive, path: p, password: password).write(to: proof)
                    let file = content.appendingPathComponent(p)
                    guard FileManager.default.fileExists(atPath: file.path) else { throw XipperError.invalidArgument("\(p) is not a file in \(id)") }
                    _ = try Xipper.xizVerifyProof(try Data(contentsOf: proof), file: file)
                    files += [file, proof]
                }
                access = "plain files with inclusion proofs"
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        // The receipt: what was handed over, signed.
        let hashed = try files.map { ($0, try Self.fileSHA256($0)) }
        let original = try Self.fileSHA256(e.archive)
        var receipt: [String: Any] = [
            "format": Delivery.receiptFormat, "case_number": (try? info)?["case_number"] ?? "", "evidence": id,
            "recipient": o.recipient, "delivery_format": o.format.rawValue, "access": access,
            "delivered_by": signer.label, "key": Self.keyID(Self.keyText(signer)), "time": Self.timestamp(now),
            "original_archive": e.archive.lastPathComponent, "original_archive_sha256": original,
            "files": hashed.map { ["name": String($0.0.path.dropFirst(folder.path.count + 1)), "sha256": $0.1,
                                   "bytes": ((try? FileManager.default.attributesOfItem(atPath: $0.0.path)[.size]) as? NSNumber)?.int64Value ?? 0] as [String: Any] }]
        if let s = image?.source { receipt["source_sha256"] = XizForensic.hex(s.sha256) }
        if !o.reason.isEmpty { receipt["reason"] = o.reason }
        if !o.notes.isEmpty { receipt["notes"] = o.notes }
        let receiptURL = folder.appendingPathComponent("delivery.json")
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: receiptURL)
        try ForensicReport.sign(receiptURL, signer: signer)
        let receiptSHA = try Self.fileSHA256(receiptURL)
        try log("evidence delivered", ["evidence": id, "recipient": o.recipient, "format": o.format.rawValue,
                                       "folder": relative(folder).isEmpty ? folder.path : (folder.path.hasPrefix(url.path) ? relative(folder) : folder.path),
                                       "receipt_sha256": receiptSHA, "files_sha256": hashed.map(\.1).joined(separator: ", ")], signer: signer)
        // The original remembers: a custody segment naming the recipient and the copy.
        var c: [String: String] = ["reason": o.reason.isEmpty ? "delivery copy" : o.reason, "format": o.format.rawValue,
                                   "receipt_sha256": receiptSHA, "copy_sha256": hashed.first?.1 ?? ""]
        if !o.notes.isEmpty { c["notes"] = o.notes }
        try custody(evidence: id, from: signer.label, to: o.recipient, fields: c, signer: signer, password: password)
        return Delivery.Result(folder: folder, files: hashed, receipt: receiptURL)
    }
}
