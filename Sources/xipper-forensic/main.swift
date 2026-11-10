// xipper-forensic: acquisition, custody and verification of evidence in forensic XIZ archives
// (XIZ 1.10 profile, docs/XIZ_SPEC.md §20; product study in docs/XIPPER_FORENSIC.md).
// Alias: xfor. This version acquires image files and folders; devices come with the helper (P4).
import ForensicKit
import Foundation
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
  xipper-forensic custody ARCHIVE --from NAME --to NAME --sign KEY [--reason T] [--seals T] [--notes T]
  xipper-forensic custody --in DIR.xfcase --evidence-id R01 --from NAME --to NAME --sign KEY [...]
  xipper-forensic report ARCHIVE [-o REPORT.json] [--sign KEY] [--password-env VAR | --password-stdin]
  xipper-forensic report --check REPORT.json         the report's detached signature
  xipper-forensic verify ARCHIVE [--expect-sha256 HEX] [--password-env VAR | --password-stdin] [--json]
  xipper-forensic info ARCHIVE [--json]

  KEY: a signing key file (xipper keygen --signing) or keychain:NAME; --signer NAME labels it
  (default: the user's full name); --timestamp URL asks an RFC 3161 authority.

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
@MainActor func signer() -> XizSigner {
    guard let spec = value("--sign") else { fail("--sign KEY is required: every segment of a forensic archive is signed", code: 2) }
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
    var url: URL?
    if let t = value("--timestamp") {
        guard let u = URL(string: t), u.scheme == "https" || u.scheme == "http" else { fail("invalid time-stamp URL \(t)", code: 2) }
        url = u
    }
    return XizSigner(key: key, label: value("--signer") ?? NSFullUserName(), timestampURL: url)
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
case "acquire":
    let image = value("--image")
    var logical: [String] = []
    if flag("--logical") {
        while let f = args.first, !f.hasPrefix("-") { logical.append(f); args.removeFirst() }
        guard !logical.isEmpty else { fail("--logical needs at least one file or folder", code: 2) }
    }
    guard (image == nil) != logical.isEmpty else { fail("acquire needs --image SOURCE or --logical PATH... (devices come with xipper-forensic 1.0)", code: 2) }
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
    let forensicCase: ForensicCase? = caseDir.map { d in
        do { return try ForensicCase(at: URL(fileURLWithPath: d)) } catch { fail("\(error)") }
    }
    if let image {
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
        o.password = password()
        let s = signer()
        done()
        do {
            let r: XizForensic.ImageReport
            var target = out ?? ""
            if let forensicCase {
                let (e, rep) = try forensicCase.acquireImage(from: image, evidence: evidenceID ?? forensicCase.nextEvidenceID(), options: o, signer: s)
                r = rep
                target = e.archive.path
            } else {
                r = try XizForensic.acquireImage(from: image, to: target, options: o, signer: s)
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

case "custody":
    var archive = ""
    var forensicCase: ForensicCase?
    if let d = value("--in") {
        do { forensicCase = try ForensicCase(at: URL(fileURLWithPath: d)) } catch { fail("\(error)") }
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
    let pw = password()
    let s: XizSigner? = args.contains("--sign") ? signer() : nil
    done()
    do {
        let u = URL(fileURLWithPath: archive)
        if let out {
            try ForensicReport.write(archive: u, to: URL(fileURLWithPath: out), password: pw, signer: s)
            print("report written to \(out)\(s == nil ? "" : " (signed)")")
        } else {
            let o = try ForensicReport.build(archive: u, password: pw)
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
