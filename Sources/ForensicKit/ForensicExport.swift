import CryptoKit
import Foundation
import XipperKit

/// Ways out of XIZ and into it (docs/FORENSE_3.1.md §4.5): the image as raw bytes (always possible: the
/// way out if a court does not take XIZ), as E01 for tools that read only that, and an existing E01
/// archived as a signed forensic XIZ with its hashes checked.
public enum ForensicExport {
    public struct Result: Sendable {
        public var files: [URL]
        public var bytes: UInt64
        public var sha256: [UInt8]
        public var md5: [UInt8]?
        public var sha1: [UInt8]?
    }

    /// Writes the image to `out` (a file, or standard output when nil). The bytes are checked against the
    /// source hash recorded at acquisition while they are written.
    public static func raw(_ archive: String, to out: URL?, password: String? = nil,
                           progress: ProgressHandler? = nil, cancel: CancellationToken? = nil) throws -> Result {
        let info = try XizForensic.storedImage(archive, password: password)
        let handle: FileHandle
        if let out {
            guard !FileManager.default.fileExists(atPath: out.path) else { throw XipperError.alreadyExists(path: out.path) }
            guard FileManager.default.createFile(atPath: out.path, contents: nil) else { throw XipperError.io("create", path: out.path, errno: errno) }
            handle = try FileHandle(forWritingTo: out)
        } else {
            handle = .standardOutput
        }
        var sha = SHA256()
        do {
            try XizForensic.streamImage(archive, password: password, cancel: cancel, progress: progress) { piece in
                sha.update(bufferPointer: piece)
                try handle.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: piece.baseAddress!), count: piece.count, deallocator: .none))
            }
            if out != nil { try handle.close() }
        } catch {
            if let out { try? FileManager.default.removeItem(at: out) }
            throw error
        }
        return Result(files: out.map { [$0] } ?? [], bytes: info.size, sha256: Array(sha.finalize()), md5: info.source?.md5, sha1: info.source?.sha1)
    }

    /// Writes the image as NAME.E01, NAME.E02… with the case fields, MD5, SHA-1 and the unreadable
    /// sectors (error2). The image must be a whole number of sectors.
    public static func e01(_ archive: String, to base: URL, password: String? = nil, segmentSize: UInt64 = EWF.defaultSegmentSize,
                           progress: ProgressHandler? = nil, cancel: CancellationToken? = nil) throws -> Result {
        let s = try XizForensic.storedImage(archive, password: password)
        let bps = s.logicalSector == 0 ? 512 : s.logicalSector
        guard s.size % UInt64(bps) == 0 else { throw EWF.Problem.notSectorAligned(s.size, bps) }
        let first = base.deletingPathExtension().appendingPathExtension("E01")
        guard !FileManager.default.fileExists(atPath: first.path) else { throw XipperError.alreadyExists(path: first.path) }
        var info = EWF.Info()
        info.caseInfo = s.caseInfo
        if info.caseInfo["description"] == nil, let d = s.device["description"] { info.caseInfo["description"] = d }
        info.model = [s.device["vendor"], s.device["model"]].compactMap { $0 }.joined(separator: " ")
        info.serial = s.device["serial"] ?? ""
        info.acquired = s.source?.started ?? Date()
        info.bytesPerSector = bps
        info.sectors = s.size / UInt64(bps)
        info.removable = s.device["removable"] == "true"
        info.physical = !s.volume
        info.unreadable = s.unreadable
        var sha = SHA256()
        let written: EWF.Info
        do {
            written = try EWF.write(to: base, info: info, segmentSize: segmentSize) { add in
                try XizForensic.streamImage(archive, password: password, cancel: cancel, progress: progress) { piece in
                    sha.update(bufferPointer: piece)
                    try add(piece)
                }
            }
        } catch {
            for n in 1...99 {
                let u = base.deletingPathExtension().appendingPathExtension(String(format: "E%02d", n))
                guard FileManager.default.fileExists(atPath: u.path) else { break }
                try? FileManager.default.removeItem(at: u)
            }
            throw error
        }
        if let m = s.source?.md5, m != written.md5 { throw EWF.Problem.hashMismatch("MD5 of the E01 differs from the acquisition's") }
        return Result(files: written.segments, bytes: s.size, sha256: Array(sha.finalize()), md5: written.md5, sha1: written.sha1)
    }

    /// An E01 opened for import: its fields, and a source that reads its chunks (checksums checked).
    public static func openE01(_ url: URL) throws -> (EWF.Reader, XizForensic.ImageSource) {
        let r = try EWF.Reader(url)
        let source = XizForensic.ImageSource(name: url.lastPathComponent, size: r.info.size, logicalSector: r.info.bytesPerSector,
                                             physicalSector: r.info.bytesPerSector) { off, dst, n in
            do { try r.read(at: off, into: dst, count: n); return nil } catch { return EIO }
        }
        return (r, source)
    }

    /// Options for importing an E01: its header becomes the device and acquisition records, its error2 the
    /// unreadable map; MD5 and SHA-1 must equal the ones stored in the E01.
    public static func importOptions(_ r: EWF.Reader, base o: XizForensic.ImageOptions) throws -> XizForensic.ImageOptions {
        var o = o
        o.name = o.name == "image.dd" ? r.info.segments[0].deletingPathExtension().lastPathComponent + ".dd" : o.name
        o.logicalSector = r.info.bytesPerSector
        o.physicalSector = r.info.bytesPerSector
        o.volume = !r.info.physical
        o.unreadable = r.info.unreadable
        o.readErrors = .init(name: "e01", attempts: 1, granularity: 32768)
        if !r.info.model.isEmpty { o.device["model"] = o.device["model"] ?? r.info.model }
        if !r.info.serial.isEmpty { o.device["serial"] = o.device["serial"] ?? r.info.serial }
        for (k, v) in r.info.caseInfo { o.acquisition["e01_" + k] = v }
        o.acquisition["method"] = "E01 import"
        o.acquisition["e01_segments"] = r.info.segments.map(\.lastPathComponent).joined(separator: ", ")
        o.acquisition["e01_segments_sha256"] = try r.info.segments.map { try ForensicCase.fileSHA256($0) }.joined(separator: ", ")
        if let m = r.info.md5 { o.acquisition["e01_md5"] = XizForensic.hex(m) }
        if let s = r.info.sha1 { o.acquisition["e01_sha1"] = XizForensic.hex(s) }
        o.md5 = true
        o.sha1 = true
        return o
    }

    /// After an import: the hashes computed on the image must be those stored in the E01.
    public static func checkImport(_ r: EWF.Reader, _ rep: XizForensic.ImageReport) throws {
        if rep.unreadableBytes > UInt64(r.info.unreadable.reduce(0) { $0 + $1.length }) {
            throw EWF.Problem.corrupt("chunks that do not decode (\(rep.unreadableBytes) bytes)")
        }
        if let m = r.info.md5, m != rep.md5 { throw EWF.Problem.hashMismatch("MD5 stored in the E01 \(XizForensic.hex(m)), computed \(XizForensic.hex(rep.md5 ?? []))") }
        if let s = r.info.sha1, s != rep.sha1 { throw EWF.Problem.hashMismatch("SHA-1 stored in the E01 \(XizForensic.hex(s)), computed \(XizForensic.hex(rep.sha1 ?? []))") }
    }
}

extension ForensicCase {
    /// Exports an evidence item's image (raw or E01) and logs it with the hashes of what was written.
    public func export(evidence id: String, raw: URL? = nil, e01: URL? = nil, password: String? = nil, signer: XizSigner,
                       progress: ProgressHandler? = nil, cancel: CancellationToken? = nil) throws -> ForensicExport.Result {
        guard let e = try evidence().first(where: { $0.id == id }) else { throw XipperError.invalidArgument("no evidence \(id) in the case") }
        let r: ForensicExport.Result
        if let e01 {
            r = try ForensicExport.e01(e.archive.path, to: e01, password: password, progress: progress, cancel: cancel)
        } else if let raw {
            r = try ForensicExport.raw(e.archive.path, to: raw, password: password, progress: progress, cancel: cancel)
        } else {
            throw XipperError.invalidArgument("export needs raw or e01")
        }
        var f = ["evidence": id, "format": e01 != nil ? "E01" : "raw", "files": r.files.map(\.lastPathComponent).joined(separator: ", "),
                 "sha256": Self.hex(r.sha256), "bytes": String(r.bytes)]
        if let m = r.md5 { f["md5"] = Self.hex(m) }
        if let s = r.sha1 { f["sha1"] = Self.hex(s) }
        f["files_sha256"] = try r.files.map { try Self.fileSHA256($0) }.joined(separator: ", ")
        try log("evidence exported", f, signer: signer)
        return r
    }

    /// Imports an E01 as a new evidence item: hashes checked against the E01's, the E01's fields recorded.
    public func importE01(_ url: URL, evidence id: String, options: XizForensic.ImageOptions, signer: XizSigner,
                          progress: ProgressHandler? = nil, cancel: CancellationToken? = nil) throws -> (Evidence, XizForensic.ImageReport) {
        let (r, source) = try ForensicExport.openE01(url)
        let o = try ForensicExport.importOptions(r, base: options)
        let (e, rep) = try acquireImage(from: source, evidence: id, options: o, signer: signer, progress: progress, cancel: cancel)
        do { try ForensicExport.checkImport(r, rep) } catch {
            try? log("import failed", ["evidence": id, "error": error.localizedDescription], signer: signer)
            throw error
        }
        return (e, rep)
    }
}
