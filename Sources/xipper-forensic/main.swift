// xipper-forensic: acquisition, custody and verification of evidence in forensic XIZ archives
// (XIZ 1.10 profile, docs/XIZ_SPEC.md §20; product study in docs/XIPPER_FORENSIC.md).
// Alias: xfor. Disks are opened by the app's helper, or directly with sudo.
import ForensicKit
import Foundation
import Security
import XipperKit

let version = ForensicReport.toolVersion
let usage = """
xipper-forensic \(version) — evidence in forensic XIZ archives (XIZ 1.10)

usage:
  xipper-forensic case new DIR.xfcase --case N --sign KEY [--examiner NAME --organization NAME
                                        --title T --court T --proceeding T --notes T]
  xipper-forensic case show DIR.xfcase [--json]      the record, the evidence and the log
  xipper-forensic case verify DIR.xfcase             log chain and signatures, case record, archives
  xipper-forensic case note DIR.xfcase --text T --sign KEY

  xipper-forensic disks [--json]                    physical disks and partitions that can be acquired
  xipper-forensic acquire --device diskN[sM] (-o OUT.xiz | --in DIR.xfcase [--evidence-id R01]) --sign KEY [options]
      the whole disk or one partition, read raw; never the startup disk nor the destination's disk
      --unmount              unmount its volumes first (refused otherwise while mounted);
                             new mounts are refused until the end
      --confirm-serial SN    required for an internal disk: its serial number
      --errors fast|standard|exhaustive   read errors: 1 try and 64 KiB lost per error, or down
                             to the sector with 2 or 8 tries (default standard)
  xipper-forensic acquire --e01 FILE.E01 (-o OUT.xiz | --in DIR.xfcase [--evidence-id R01]) --sign KEY [options]
      archives an existing E01 (all its segments): MD5 and SHA-1 must equal those stored in it;
      its case fields, segment hashes and unreadable sectors go into the records
  xipper-forensic acquire --image SOURCE (-o OUT.xiz | --in DIR.xfcase [--evidence-id R01]) --sign KEY [options]
  xipper-forensic acquire --logical PATH... (-o OUT.xiz | --in DIR.xfcase [--evidence-id R01]) --sign KEY [options]
      with --in the archive goes to DIR/evidence/R01/R01.xiz with a signed report, and every
      step goes into the case log; the case record fills the case fields
      --name PATH            path of the image in the archive (default image.dd)
      --no-xattrs            logical: leave extended attributes out
      --case N  --evidence N  --examiner NAME  --organization NAME  --location TEXT
      --description TEXT  --notes TEXT
      --device-model T  --device-serial T  --device-interface T  --write-blocker T
      --sector N             logical sector size (default 512); --physical-sector N
      --volume OFFSET        the source is a volume at OFFSET bytes in its device
      --no-md5 --no-sha1     skip the compatibility hashes (SHA-256 is always computed)
      --level N              zstd level, 0 stores (default 3)
      --unreadable OFF:LEN   treat this range as unreadable (zeros + map); repeatable (tests)
      --password-env VAR | --password-stdin   encrypt the archive
      --time ISO8601         fixed time (reproducible test vectors)
  xipper-forensic export ARCHIVE (--raw FILE|- | --e01 BASE [--segment-size MB]) [--password-env VAR | --password-stdin]
  xipper-forensic export --in DIR.xfcase --evidence-id R01 (--raw FILE | --e01 BASE) --sign KEY
      the image as raw bytes (checked against the source hash while written) or as E01 (EnCase 6
      layout: case fields, MD5, SHA-1, unreadable sectors); with --in the export is logged
  xipper-forensic deliver --in DIR.xfcase --evidence-id R01 --to NAME --sign KEY [--format xiz|raw|e01|files]
                         [--recipient-key xizpk1…]... [--copy-password-env VAR] [--file PATH]... [-o FOLDER]
                         [--reason T] [--notes T]
      a copy for someone, in its own folder with a signed receipt (delivery.json); the original gains a
      custody segment. xiz: an image is copied into a new archive for the recipient's keys or a password
      (same image hashes); files: some files of a logical acquisition, each with its inclusion proof
  xipper-forensic custody ARCHIVE --from NAME --to NAME --sign KEY [--reason T] [--seals T] [--notes T]
  xipper-forensic custody --in DIR.xfcase --evidence-id R01 --from NAME --to NAME --sign KEY [...]
  xipper-forensic report ARCHIVE [-o REPORT.json] [--pdf REPORT.pdf [--lang it|en]] [--sign KEY]
                         [--password-env VAR | --password-stdin]
  xipper-forensic report --check REPORT.json|REPORT.pdf   a report's detached signature
      with --in DIR.xfcase, acquire and custody write REPORT.json and REPORT.pdf (--lang it|en)
  xipper-forensic verify ARCHIVE [--expect-sha256 HEX] [--password-env VAR | --password-stdin] [--json]
  xipper-forensic info ARCHIVE [--json]

  xipper-forensic trusted-list [--country IT]       qualified time-stamp services (QTST) in an EU trusted list
  xipper-forensic identities                         certificates with a private key (Keychain, smart cards)

  KEY: a signing key file (xipper keygen --signing) or keychain:NAME; --signer NAME labels it
  (default: the user's full name); --timestamp URL asks an RFC 3161 authority, with
  --timestamp-user U --timestamp-password-env VAR when it wants an account (https only).
  --trusted-list CC (report, acquire/custody --in): say in the reports whether each time-stamp comes
  from a qualified service of that EU trusted list (network: the list is fetched, cached a day).
  --certificate NAME signs with a certificate identity instead (ECDSA P-256 or RSA; a smart card
  asks for its PIN): the archive, the case log and the reports carry the certificate.

exit codes: 0 ok, 1 verification failed or error, 2 usage
"""

var args = Array(CommandLine.arguments.dropFirst())
@MainActor func fail(_ m: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("xipper-forensic: \(m)\n".utf8))
    exit(code)
}
@MainActor func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
@MainActor func value(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("\(name) needs a value", code: 2) }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
@MainActor func values(_ name: String) -> [String] {
    var out: [String] = []
    while let v = value(name) { out.append(v) }
    return out
}
@MainActor func password() -> String? {
    if let v = value("--password-env") {
        guard let p = ProcessInfo.processInfo.environment[v] else { fail("environment variable \(v) is not set", code: 2) }
        return p
    }
    if flag("--password-stdin") {
        guard let line = readLine(strippingNewline: true), !line.isEmpty else { fail("no password on stdin", code: 2) }
        return line
    }
    return nil
}
/// --lang it|en: the language of the printable report (default it).
@MainActor func language() -> ForensicPDF.Language {
    guard let v = value("--lang") else { return .it }
    guard let l = ForensicPDF.Language(rawValue: v) else { fail("--lang it or en", code: 2) }
    return l
}
/// --trusted-list CC: check time-stamps against that EU trusted list (fetched over https, cached a day).
@MainActor func trustedList() -> TrustedList? {
    guard let c = value("--trusted-list") else { return nil }
    do { return try TrustedList.load(country: c.uppercased()) } catch { fail(describe(error)) }
}
@MainActor func signer() -> XizSigner {
    // A certificate identity (Keychain, smart card): segments, log and reports are signed with its key.
    var certificate: XizCertificateSigner?
    if let name = value("--certificate") {
        guard let id = XizCertificateSigner.identity(named: name) else {
            fail("no identity \"\(name)\" in the Keychain or on a smart card (see xipper-forensic identities)")
        }
        do { certificate = try XizCertificateSigner(identity: id) } catch { fail("\(name): \(describe(error))") }
    }
    var url: URL?
    if let t = value("--timestamp") {
        guard let u = URL(string: t), u.scheme == "https" || u.scheme == "http" else { fail("invalid time-stamp URL \(t)", code: 2) }
        url = u
    }
    var credentials: (user: String, password: String)?
    if let user = value("--timestamp-user") {
        guard let v = value("--timestamp-password-env"), let p = ProcessInfo.processInfo.environment[v] else {
            fail("--timestamp-user needs --timestamp-password-env VAR", code: 2)
        }
        credentials = (user, p)
    }
    let label = value("--signer") ?? certificate.map { $0.subject } ?? NSFullUserName()
    guard let spec = value("--sign") else {
        guard let certificate else { fail("--sign KEY or --certificate NAME is required: every segment of a forensic archive is signed", code: 2) }
        var s = XizSigner(key: XizSigningKey(), label: label, timestampURL: url, certificate: certificate)
        s.timestampCredentials = credentials
        return s
    }
    let text: String
    if spec.hasPrefix("keychain:") {
        guard let t = XizKeychain.secret(.signing, name: String(spec.dropFirst(9))) else { fail("no signing key \"\(spec.dropFirst(9))\" in the Keychain") }
        text = t
    } else {
        guard let t = try? String(contentsOfFile: spec, encoding: .utf8) else { fail("cannot read signing key \(spec)") }
        text = t
    }
    let key: XizSigningKey
    do { key = try XizSigningKey(secretText: text) } catch { fail("\(spec): \(error)") }
    var s = XizSigner(key: key, label: label, timestampURL: url, certificate: certificate)
    s.timestampCredentials = credentials
    return s
}
@MainActor func date(_ s: String?) -> Date? {
    guard let s else { return nil }
    guard let d = ISO8601DateFormatter().date(from: s) else { fail("invalid time \(s) (ISO 8601, e.g. 2026-11-10T09:00:00Z)", code: 2) }
    return d
}
@MainActor func hexBytes(_ s: String) -> [UInt8]? {
    let c = Array(s.lowercased().utf8)
    guard c.count % 2 == 0 else { return nil }
    var out: [UInt8] = []
    for i in stride(from: 0, to: c.count, by: 2) {
        guard let b = UInt8(String(decoding: c[i..<(i + 2)], as: UTF8.self), radix: 16) else { return nil }
        out.append(b)
    }
    return out
}
/// A LocalizedError's own text, else the error's description (XipperError is CustomStringConvertible).
func describe(_ e: Error) -> String { (e as? LocalizedError)?.errorDescription ?? "\(e)" }
@MainActor func done() { if let extra = args.first { fail("unexpected argument \(extra)", code: 2) } }
@MainActor func printJSON(_ o: Any) {
    let d = (try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    print(String(decoding: d, as: UTF8.self))
}

guard let command = args.first else { print(usage); exit(2) }
args.removeFirst()
if command == "--version" || command == "version" { print("xipper-forensic \(version)"); exit(0) }
if command == "help" || command == "--help" || command == "-h" { print(usage); exit(0) }

switch command {
case "trusted-list":
    let c = (value("--country") ?? "IT").uppercased()
    done()
    do {
        let tl = try TrustedList.load(country: c)
        print("\(c) trusted list no. \(tl.sequence), issued \(tl.issued.map { ISO8601DateFormatter().string(from: $0) } ?? "?"), SHA-256 \(tl.sha256)")
        print("\(tl.url)")
        for sv in tl.services {
            let now = sv.status(at: Date()) == TrustedList.granted ? "granted" : (sv.status(at: Date())?.components(separatedBy: "/").last ?? "?")
            print("  \(now.padding(toLength: 10, withPad: " ", startingAt: 0)) \(sv.provider) — \(sv.name) (\(sv.certificates.count) cert.)")
        }
    } catch { fail(describe(error)) }

case "identities":
    done()
    let ids = XizCertificateSigner.identities()
    if ids.isEmpty { print("no certificate identities (import a .p12, or insert a smart card)") }
    for (name, id) in ids {
        var cert: SecCertificate?
        SecIdentityCopyCertificate(id, &cert)
        let info = cert.map { XizCertificateInfo(Array(SecCertificateCopyData($0) as Data)) }
        // From the certificate only: listing must not use (or unlock) anyone's private key.
        let attrs = cert.flatMap { SecCertificateCopyKey($0) }.flatMap { SecKeyCopyAttributes($0) as? [String: Any] } ?? [:]
        let type = attrs[kSecAttrKeyType as String] as? String, bits = attrs[kSecAttrKeySizeInBits as String] as? Int ?? 0
        let usable = (type == (kSecAttrKeyTypeECSECPrimeRandom as String) && bits == 256) || (type == (kSecAttrKeyTypeRSA as String) && bits >= 2048)
        print("\(name)  issuer \(info?.issuer ?? "?")  until \(info?.notAfter.map { ISO8601DateFormatter().string(from: $0) } ?? "?")\(usable ? "" : "  (not usable: key type)")")
    }

case "disks":
    let json = flag("--json")
    done()
    let disks = Disks.list()
    if json {
        let a = disks.map { d -> [String: Any] in
            var o: [String: Any] = d.record
            o["boot"] = d.isBoot
            o["partitions"] = d.partitions.map { p -> [String: Any] in
                var r: [String: Any] = p.record
                r["volumes"] = p.volumes.map { ["name": $0.name, "mount_point": $0.mountPoint, "file_system": $0.fileSystem] }
                return r
            }
            o["volumes"] = d.volumes.map { ["name": $0.name, "mount_point": $0.mountPoint, "file_system": $0.fileSystem] }
            return o
        }
        let data = try! JSONSerialization.data(withJSONObject: a, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } else {
        let f = ByteCountFormatter()
        for d in disks {
            var flags = [d.isInternal ? "internal" : "external", d.bus]
            if d.isDiskImage { flags.append("disk image") }
            if d.isBoot { flags.append("STARTUP DISK") }
            print("\(d.bsd)  \(f.string(fromByteCount: Int64(d.size)))  \(d.title)  serial \(d.serial.isEmpty ? "-" : d.serial)  [\(flags.filter { !$0.isEmpty }.joined(separator: ", "))]")
            for p in d.partitions {
                let vols = p.volumes.map { "\($0.name) (\($0.mountPoint))" }.joined(separator: ", ")
                print("  \(p.bsd)  \(f.string(fromByteCount: Int64(p.size)))  \(p.content)\(vols.isEmpty ? "" : "  mounted: " + vols)")
            }
        }
    }

case "acquire":
    let image = value("--image")
    let deviceName = value("--device")
    let e01Source = value("--e01")
    var logical: [String] = []
    if flag("--logical") {
        while let f = args.first, !f.hasPrefix("-") { logical.append(f); args.removeFirst() }
        guard !logical.isEmpty else { fail("--logical needs at least one file or folder", code: 2) }
    }
    guard [image != nil, !logical.isEmpty, deviceName != nil, e01Source != nil].filter({ $0 }).count == 1 else {
        fail("acquire needs one of --device diskN, --image SOURCE, --e01 FILE.E01, --logical PATH...", code: 2)
    }
    let out = value("-o") ?? value("--output")
    let caseDir = value("--in")
    guard (out == nil) != (caseDir == nil) else { fail("acquire needs -o OUT.xiz or --in DIR.xfcase", code: 2) }
    var caseInfo: [String: String] = [:], device: [String: String] = [:], acquisition: [String: String] = [:]
    let caseKeys = ["case": "case_number", "evidence": "evidence_number", "examiner": "examiner", "organization": "organization",
                    "location": "location", "description": "description", "notes": "notes"]
    for (opt, key) in caseKeys { if let v = value("--" + opt) { caseInfo[key] = v } }
    let deviceKeys = ["device-model": "model", "device-serial": "serial", "device-interface": "interface", "write-blocker": "write_blocker"]
    for (opt, key) in deviceKeys { if let v = value("--" + opt) { device[key] = v } }
    var level = 3
    if let v = value("--level") { guard let n = Int(v), (0...19).contains(n) else { fail("--level 0…19", code: 2) }; level = n }
    acquisition["tool_version"] = version
    acquisition["os"] = ProcessInfo.processInfo.operatingSystemVersionString
    let now = date(value("--time"))
    let evidenceID = value("--evidence-id")
    let lang = language()
    let forensicCase: ForensicCase? = caseDir.map { d in
        do { var c = try ForensicCase(at: URL(fileURLWithPath: d)); c.reportLanguage = lang; c.trustedList = trustedList(); return c } catch { fail("\(error)") }
    }
    if image != nil || deviceName != nil || e01Source != nil {
        var o = XizForensic.ImageOptions()
        o.caseInfo = caseInfo; o.device = device; o.acquisition = acquisition; o.level = level; o.now = now
        o.name = value("--name") ?? o.name
        if let v = value("--sector") { guard let n = UInt32(v) else { fail("--sector N", code: 2) }; o.logicalSector = n; o.physicalSector = n }
        if let v = value("--physical-sector") { guard let n = UInt32(v) else { fail("--physical-sector N", code: 2) }; o.physicalSector = n }
        if let v = value("--volume") { guard let n = UInt64(v) else { fail("--volume OFFSET", code: 2) }; o.volume = true; o.volumeOffset = n }
        if flag("--no-md5") { o.md5 = false }
        if flag("--no-sha1") { o.sha1 = false }
        for r in values("--unreadable") {
            let p = r.split(separator: ":")
            guard p.count == 2, let off = UInt64(p[0]), let len = UInt64(p[1]) else { fail("--unreadable OFFSET:LENGTH", code: 2) }
            o.unreadable.append(.init(offset: off, length: len))
        }
        if let v = value("--errors") { guard let e = XizForensic.ReadErrors.named(v) else { fail("--errors fast|standard|exhaustive", code: 2) }; o.readErrors = e }
        let unmount = flag("--unmount")
        let confirmSerial = value("--confirm-serial")
        o.password = password()
        let s = signer()
        done()
        // A disk: checks, unmount, mounts refused while reading, opened read-only (directly or by the helper).
        var blocker: MountBlocker?
        var opened: XizForensic.ImageSource?
        if let deviceName {
            guard let (whole, target) = Disks.find(deviceName) else { fail("\(deviceName): no such disk (see xipper-forensic disks)") }
            let dest = forensicCase?.url.path ?? out!
            let refused = Disks.refusals(whole: whole, destination: dest)
            if !refused.isEmpty { fail(refused.joined(separator: "; ")) }
            if whole.isInternal && !whole.isDiskImage {
                guard let c = confirmSerial, !whole.serial.isEmpty, c == whole.serial else {
                    fail("\(whole.bsd) is an internal disk: confirm with --confirm-serial and its serial number")
                }
            }
            blocker = MountBlocker(wholeDisks: [whole.bsd])
            let mounted = whole.volumes
            if !mounted.isEmpty {
                guard unmount else { fail("mounted: \(mounted.map { $0.mountPoint }.joined(separator: ", ")); add --unmount") }
                let sem = DispatchSemaphore(value: 0)
                nonisolated(unsafe) var err: Error?
                Task.detached { do { try await Disks.unmount(whole.bsd) } catch { err = error }; sem.signal() }
                sem.wait()
                if let err { fail("\(err.localizedDescription)") }
                try? forensicCase?.log("disk unmounted", ["disk": whole.bsd, "volumes": mounted.map(\.mountPoint).joined(separator: ", ")], signer: s)
            }
            let route: DeviceAccess.Route
            do { (opened, route) = try DeviceAccess.open(target.devicePath) } catch { fail(describe(error)) }
            o.device = target.record.merging(device, uniquingKeysWith: { _, cli in cli })
            if !target.whole { o.device["whole_disk"] = whole.bsd; o.volume = true; o.volumeOffset = target.offset }
            o.acquisition["device_access"] = route.rawValue
            if o.name == "image.dd" { o.name = "\(target.bsd).dd" }
        }
        var e01: EWF.Reader?
        if let e01Source {
            do {
                let (r, src) = try ForensicExport.openE01(URL(fileURLWithPath: e01Source))
                e01 = r
                opened = src
                o = try ForensicExport.importOptions(r, base: o)
            } catch { fail(describe(error)) }
        }
        do {
            let reader = try opened ?? XizForensic.ImageSource(path: image!)
            let r: XizForensic.ImageReport
            var target = out ?? ""
            if let forensicCase {
                let (e, rep) = try forensicCase.acquireImage(from: reader, evidence: evidenceID ?? forensicCase.nextEvidenceID(), options: o, signer: s)
                r = rep
                target = e.archive.path
            } else {
                r = try XizForensic.acquireImage(from: reader, to: target, options: o, signer: s)
            }
            if let e01 {
                do { try ForensicExport.checkImport(e01, r) } catch {
                    if forensicCase == nil { try? FileManager.default.removeItem(atPath: target) }
                    try? forensicCase?.log("import failed", ["archive": target, "error": error.localizedDescription], signer: s)
                    fail(describe(error))
                }
                print("E01 hashes match: MD5 and SHA-1 equal to those stored in \(e01.info.segments.count) segment(s)")
            }
            if let blocker {
                blocker.stop()
                if !blocker.refused.isEmpty {
                    print("mounts refused during the acquisition: \(blocker.refused.joined(separator: ", "))")
                    try? forensicCase?.log("mounts refused", ["volumes": blocker.refused.joined(separator: ", ")], signer: s)
                }
            }
            print("acquired \(r.size) bytes into \(target) (\(r.archiveBytes) bytes, \(r.frames) frames, \(r.zeroBlocks) zero blocks)")
            print("SHA-256  \(XizForensic.hex(r.sha256))")
            if let m = r.md5 { print("MD5      \(XizForensic.hex(m))") }
            if let h = r.sha1 { print("SHA-1    \(XizForensic.hex(h))") }
            if r.unreadableBytes > 0 { print("unreadable: \(r.unreadableBytes) bytes filled with zeros (listed in the archive)") }
        } catch { fail("\(error)") }
    } else {
        var o = XizForensic.LogicalOptions()
        o.caseInfo = caseInfo; o.device = device; o.acquisition = acquisition; o.level = level; o.now = now
        if flag("--no-xattrs") { o.extendedAttributes = false }
        o.password = password()
        let s = signer()
        done()
        let urls = logical.map { URL(fileURLWithPath: $0) }
        do {
            let r: XizForensic.LogicalReport
            var target = out ?? ""
            if let forensicCase {
                let (e, rep) = try forensicCase.acquireLogical(urls, evidence: evidenceID ?? forensicCase.nextEvidenceID(), options: o, signer: s)
                r = rep
                target = e.archive.path
            } else {
                r = try XizForensic.acquireLogical(urls, to: target, options: o, signer: s)
            }
            print("acquired \(r.files) files, \(r.folders) folders, \(r.links) links, \(r.bytes) bytes into \(target) (\(r.archiveBytes) bytes)")
            print("inventory SHA-256  \(XizForensic.hex(r.inventorySHA256))")
            if !r.skipped.isEmpty {
                print("not acquired: \(r.skipped.count) (listed in forensic/inventory.jsonl)")
                for x in r.skipped.prefix(20) { print("  \(x.path): \(x.reason)") }
            }
        } catch { fail("\(error)") }
    }

case "export":
    let caseDir = value("--in")
    let id = value("--evidence-id")
    let raw = value("--raw")
    let e01 = value("--e01")
    var segment = EWF.defaultSegmentSize
    if let v = value("--segment-size") { guard let n = UInt64(v), n >= 8 else { fail("--segment-size MB (at least 8)", code: 2) }; segment = n << 20 }
    guard (raw == nil) != (e01 == nil) else { fail("export needs --raw FILE|- or --e01 BASE", code: 2) }
    let pw = password()
    if let caseDir {
        guard let id else { fail("--in needs --evidence-id", code: 2) }
        let s = signer()
        done()
        do {
            let c = try ForensicCase(at: URL(fileURLWithPath: caseDir))
            let r = try c.export(evidence: id, raw: raw.map { URL(fileURLWithPath: $0) }, e01: e01.map { URL(fileURLWithPath: $0) }, password: pw, signer: s)
            for f in r.files { print(f.path) }
            print("SHA-256  \(XizForensic.hex(r.sha256))")
            if let m = r.md5 { print("MD5      \(XizForensic.hex(m))") }
            if let h = r.sha1 { print("SHA-1    \(XizForensic.hex(h))") }
        } catch { fail(describe(error)) }
    } else {
        guard let archive = args.first else { fail("export ARCHIVE …", code: 2) }
        args.removeFirst()
        done()
        do {
            if let e01 {
                let r = try ForensicExport.e01(archive, to: URL(fileURLWithPath: e01), password: pw, segmentSize: segment)
                for f in r.files { print(f.path) }
                print("SHA-256  \(XizForensic.hex(r.sha256))")
                if let m = r.md5 { print("MD5      \(XizForensic.hex(m))") }
                if let h = r.sha1 { print("SHA-1    \(XizForensic.hex(h))") }
            } else {
                let toStdout = raw == "-"
                let r = try ForensicExport.raw(archive, to: toStdout ? nil : URL(fileURLWithPath: raw!), password: pw)
                if !toStdout { print("\(r.bytes) bytes  SHA-256 \(XizForensic.hex(r.sha256))") }
            }
        } catch { fail(describe(error)) }
    }

case "deliver":
    guard let caseDir = value("--in"), let id = value("--evidence-id"), let to = value("--to") else {
        fail("deliver needs --in DIR.xfcase --evidence-id R01 --to NAME", code: 2)
    }
    var o = Delivery.Options(recipient: to)
    if let f = value("--format") { guard let x = Delivery.Format(rawValue: f) else { fail("--format xiz|raw|e01|files", code: 2) }; o.format = x }
    o.recipientKeys = values("--recipient-key")
    o.files = values("--file")
    if let v = value("--copy-password-env") {
        guard let p = ProcessInfo.processInfo.environment[v], !p.isEmpty else { fail("\(v) is not set", code: 2) }
        o.password = p
    }
    if let d = value("-o") { o.destination = URL(fileURLWithPath: d) }
    o.reason = value("--reason") ?? ""
    o.notes = value("--notes") ?? ""
    let lang = language()
    let tl = trustedList()
    let pw = password()
    let s = signer()
    done()
    do {
        var c = try ForensicCase(at: URL(fileURLWithPath: caseDir))
        c.reportLanguage = lang
        c.trustedList = tl
        let r = try c.deliver(evidence: id, options: o, signer: s, password: pw)
        print("delivered \(id) to \(to) in \(r.folder.path)")
        for (f, h) in r.files { print("  \(h)  \(f.lastPathComponent)") }
        print("receipt \(r.receipt.lastPathComponent) (signed); custody segment added to the original")
    } catch { fail(describe(error)) }

case "custody":
    var archive = ""
    var forensicCase: ForensicCase?
    if let d = value("--in") {
        do { forensicCase = try ForensicCase(at: URL(fileURLWithPath: d)); forensicCase?.reportLanguage = language(); forensicCase?.trustedList = trustedList() } catch { fail("\(error)") }
    } else {
        guard let a = args.first, !a.hasPrefix("-") else { fail("custody needs the archive (or --in DIR.xfcase --evidence-id R01)", code: 2) }
        args.removeFirst()
        archive = a
    }
    let evidenceID = value("--evidence-id")
    guard let from = value("--from"), let to = value("--to") else { fail("custody needs --from and --to", code: 2) }
    var c: [String: String] = [:]
    for k in ["reason", "seals", "notes"] { if let v = value("--" + k) { c[k] = v } }
    let now = date(value("--time"))
    let pw = password()
    let s = signer()
    done()
    do {
        if let forensicCase {
            guard let id = evidenceID else { fail("custody --in needs --evidence-id", code: 2) }
            try forensicCase.custody(evidence: id, from: from, to: to, fields: c, signer: s, password: pw, now: now)
        } else {
            try XizForensic.appendCustody(to: archive, custody: c.merging(["from": from, "to": to], uniquingKeysWith: { _, n in n }), signer: s, now: now)
        }
        print("custody recorded: \(from) → \(to), signed by \(s.label)")
    } catch { fail("\(error)") }

case "case":
    guard let sub = args.first else { fail("case new | show | verify | note", code: 2) }
    args.removeFirst()
    guard let dir = args.first, !dir.hasPrefix("-") else { fail("case \(sub) needs the case folder", code: 2) }
    args.removeFirst()
    let url = URL(fileURLWithPath: dir)
    switch sub {
    case "new":
        var info: [String: String] = [:]
        let keys = ["case": "case_number", "examiner": "examiner", "organization": "organization", "title": "title",
                    "court": "court", "proceeding": "proceeding", "location": "location", "notes": "notes"]
        for (opt, key) in keys { if let v = value("--" + opt) { info[key] = v } }
        guard info["case_number"] != nil else { fail("case new needs --case NUMBER", code: 2) }
        let now = date(value("--time"))
        let s = signer()
        done()
        do {
            _ = try ForensicCase.create(at: url, info: info, signer: s, now: now)
            print("case \(info["case_number"]!) created in \(url.path)")
        } catch { fail("\(error)") }
    case "note":
        guard let text = value("--text") else { fail("case note needs --text", code: 2) }
        let now = date(value("--time"))
        let s = signer()
        done()
        do { try ForensicCase(at: url).log("note", ["text": text], signer: s, now: now) } catch { fail("\(error)") }
    case "show":
        let json = flag("--json")
        done()
        do {
            let c = try ForensicCase(at: url)
            let info = try c.info, ev = try c.evidence(), log = try c.entries()
            if json {
                printJSON(["case": info, "evidence": ev.map { ["id": $0.id, "archive": $0.archive.path] },
                           "log": log.map { ["seq": $0.seq, "t": $0.time, "event": $0.event, "by": $0.by, "fields": $0.fields] as [String: Any] }])
            } else {
                print("case " + info.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
                for e in ev { print("evidence \(e.id): \(e.archive.lastPathComponent)") }
                for l in log {
                    print("  \(l.seq)  \(l.time)  \(l.by): \(l.event)  " + l.fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
                }
            }
        } catch { fail("\(error)") }
    case "verify":
        done()
        do {
            let c = try ForensicCase(at: url)
            let v = try c.verify()
            print("log: \(v.entries) entries, signed by " + v.signers.values.sorted().joined(separator: ", "))
            for p in v.problems { print("FAIL  \(p)") }
            var ok = v.passed
            for e in try c.evidence() {
                let r = try XizForensic.verify(e.archive.path)
                let sig = (try? ForensicReport.verifySignature(e.report))?.valid ?? false
                print("\(r.passed ? "ok  " : "FAIL")  \(e.id): archive \(r.passed ? "verified" : "FAILED"), report signature \(sig ? "valid" : "INVALID or missing")")
                ok = ok && r.passed && sig
            }
            print(ok ? "case verified" : "CASE VERIFICATION FAILED")
            exit(ok ? 0 : 1)
        } catch { fail("\(error)") }
    default:
        fail("unknown case command \(sub)", code: 2)
    }

case "report":
    if let r = value("--check") {
        done()
        do {
            let s = try ForensicReport.verifySignature(URL(fileURLWithPath: r))
            print(s.valid ? "signature valid: \(s.signer) \(s.key)" : "SIGNATURE INVALID (\(s.signer) \(s.key))")
            exit(s.valid ? 0 : 1)
        } catch { fail("\(error)") }
    }
    guard let archive = args.first, !archive.hasPrefix("-") else { fail("report needs the archive", code: 2) }
    args.removeFirst()
    let out = value("-o") ?? value("--output")
    let pdf = value("--pdf")
    let lang = language()
    let pw = password()
    let tl = trustedList()
    let s: XizSigner? = args.contains("--sign") || args.contains("--certificate") ? signer() : nil
    done()
    do {
        let u = URL(fileURLWithPath: archive)
        if let pdf {
            var o = try ForensicReport.build(archive: u, password: pw, trustedList: tl)
            if let tl { o["trusted_list"] = tl.record }
            if let out {
                let data = try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                try data.write(to: URL(fileURLWithPath: out), options: .withoutOverwriting)
                if let s { try ForensicReport.sign(URL(fileURLWithPath: out), signer: s) }
            }
            try ForensicPDF.render(o, language: lang).write(to: URL(fileURLWithPath: pdf), options: .withoutOverwriting)
            if let s { try ForensicReport.sign(URL(fileURLWithPath: pdf), signer: s) }
            print("report written to \(pdf)\(out.map { " and \($0)" } ?? "")\(s == nil ? "" : " (signed)")")
        } else if let out {
            try ForensicReport.write(archive: u, to: URL(fileURLWithPath: out), password: pw, signer: s, trustedList: tl)
            print("report written to \(out)\(s == nil ? "" : " (signed)")")
        } else {
            var o = try ForensicReport.build(archive: u, password: pw, trustedList: tl)
            if let tl { o["trusted_list"] = tl.record }
            printJSON(o)
        }
    } catch { fail("\(error)") }

case "verify":
    guard let archive = args.first, !archive.hasPrefix("-") else { fail("verify needs the archive", code: 2) }
    args.removeFirst()
    let json = flag("--json")
    var expect: [UInt8]?
    if let h = value("--expect-sha256") { guard let b = hexBytes(h), b.count == 32 else { fail("--expect-sha256 needs 64 hex digits", code: 2) }; expect = b }
    let pw = password()
    done()
    do {
        let r = try XizForensic.verify(archive, password: pw, expectSHA256: expect)
        if json {
            printJSON(["passed": r.passed, "checks": r.checks.map { ["name": $0.name, "status": $0.status.rawValue, "detail": $0.detail] }])
        } else {
            for c in r.checks {
                let mark = switch c.status { case .passed: "ok  "; case .warning: "warn"; case .failed: "FAIL"; case .skipped: "skip" }
                print("\(mark)  \(c.name): \(c.detail)")
            }
            print(r.passed ? "verified" : "VERIFICATION FAILED")
        }
        exit(r.passed ? 0 : 1)
    } catch { fail("\(error)") }

case "info":
    guard let archive = args.first, !archive.hasPrefix("-") else { fail("info needs the archive", code: 2) }
    args.removeFirst()
    let json = flag("--json")
    done()
    do {
        let blocks = try XizForensic.blocks(archive)
        if json {
            printJSON(blocks.map { b in
                ["segment": Int(b.segment), "records": b.records.map { r -> [String: Any] in
                    var d: [String: Any] = ["type": String(format: "0x%04x", r.type)]
                    if let t = XizForensic.RecordType(rawValue: r.type) { d["name"] = "\(t)" }
                    switch XizForensic.RecordType(rawValue: r.type) {
                    case .caseInfo?, .device?, .custody?, .acquisition?: d["value"] = r.json
                    case .log?: d["value"] = r.text
                    default: d["length"] = r.value.count
                    }
                    return d
                }]
            })
        } else {
            for b in blocks {
                print("segment \(b.segment)")
                for r in b.records {
                    switch XizForensic.RecordType(rawValue: r.type) {
                    case .caseInfo?, .device?, .custody?, .acquisition?:
                        print("  \(XizForensic.RecordType(rawValue: r.type)!): " + r.json.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
                    case .log?: for l in r.text.split(separator: "\n") { print("  log: \(l)") }
                    case let t?: print("  \(t): \(r.value.count) bytes")
                    case nil: print("  record 0x\(String(r.type, radix: 16)): \(r.value.count) bytes")
                    }
                }
            }
        }
    } catch { fail("\(error)") }

default:
    fail("unknown command \(command)\n\n\(usage)", code: 2)
}
