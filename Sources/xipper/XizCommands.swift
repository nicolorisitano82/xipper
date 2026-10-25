// XIZ 1.3 on the command line: identities and signing keys, access policies, signed history.
import Darwin
import Foundation
import XipperKit

let xizUsage = """
  keygen  [--signing] -o FILE     new XIZ identity (X25519, to receive archives) or signing key
                                  (Ed25519, --signing); writes the secret to FILE (mode 600) and
                                  prints the public key
  history <archive.xiz>           signed changes of an XIZ archive: signer, time, checks, time-stamp

XIZ access and signatures (create, edit, and everything that opens an archive):
      --access POLICY.json   create: access groups, recipients, custodians (docs/XIZ_SPEC.md §13)
      --identity FILE        an XIZ identity to open archives with (repeatable)
      --sign FILE            sign the archive (create) or the change (edit) with this signing key
      --signer NAME          the signer's name shown in the history (default: the user's name)
      --timestamp URL        RFC 3161 time-stamp authority for the signature (network: opt-in)
      --password-stdin       the first line is the password; further lines are more passwords
                             (custodians of a k-of-n group each give theirs)
"""

/// Every value of a repeatable option, in order.
@MainActor func allValues(_ name: String) -> [String] {
    var out: [String] = []
    var k = 0
    while k < args.count {
        if args[k] == name, k + 1 < args.count { out.append(args[k + 1]); k += 2 } else { k += 1 }
    }
    return out
}

/// Loads the `--identity` files into the credentials XIZ tries.
@MainActor func loadXizIdentities() {
    for path in allValues("--identity") {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read identity \(path)") }
        do { XizCredentials.shared.add(identity: try XizIdentity(secretText: text)) } catch { fail("\(path): \(error)") }
    }
}

@MainActor func xizSigner() -> XizSigner? {
    guard let path = value("--sign") else {
        if value("--timestamp") != nil { fail("--timestamp needs --sign", code: 2) }
        return nil
    }
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read signing key \(path)") }
    let key: XizSigningKey
    do { key = try XizSigningKey(secretText: text) } catch { fail("\(path): \(error)") }
    var url: URL?
    if let t = value("--timestamp") {
        guard let u = URL(string: t), u.scheme == "https" || u.scheme == "http" else { fail("invalid time-stamp URL \(t)", code: 2) }
        url = u
    }
    return XizSigner(key: key, label: value("--signer") ?? NSFullUserName(), timestampURL: url)
}

/// An access policy from JSON. Passwords never sit in the file: `password_env` names an
/// environment variable, `password_prompt` asks on the terminal.
///
///     { "groups": [ { "name": "referti", "folders": ["caso/referti"] } ],
///       "recipients": [ { "label": "Laboratorio", "password_prompt": true },
///                       { "label": "Clinico", "password_env": "CLIN_PW", "groups": ["referti"] },
///                       { "label": "Ricerca", "public_key": "xizpk1…", "groups": [""] } ],
///       "thresholds": [ { "label": "Dati grezzi", "k": 2, "groups": ["grezzi"],
///                         "custodians": [ { "label": "DPO", "password_prompt": true }, … ] } ] }
@MainActor func loadAccessPolicy(_ path: String) -> XizAccess {
    guard let data = FileManager.default.contents(atPath: path),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { fail("cannot read access policy \(path)") }
    func credential(_ o: [String: Any], _ label: String) -> XizAccess.Credential {
        if let k = o["public_key"] as? String {
            do { return .publicKey(try XizIdentity.publicKey(fromText: k)) } catch { fail("\(label): \(error)") }
        }
        if let env = o["password_env"] as? String {
            guard let pw = ProcessInfo.processInfo.environment[env], !pw.isEmpty else { fail("\(label): $\(env) is not set") }
            return .password(pw)
        }
        if o["password_prompt"] as? Bool == true {
            var buf = [CChar](repeating: 0, count: 1024)
            guard readpassphrase("Password for \(label): ", &buf, buf.count, RPP_ECHO_OFF | RPP_REQUIRE_TTY) != nil else { fail("cannot read password") }
            defer { memset_s(&buf, buf.count, 0, buf.count) }
            let pw = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if pw.isEmpty { fail("\(label): empty password") }
            return .password(pw)
        }
        if o["password"] != nil { fail("\(label): passwords cannot be written in the policy (use password_env or password_prompt)") }
        fail("\(label): needs public_key, password_env or password_prompt")
    }
    func recipient(_ o: [String: Any]) -> XizAccess.Recipient {
        let label = o["label"] as? String ?? ""
        return XizAccess.Recipient(label: label, credential: credential(o, label.isEmpty ? "recipient" : label), groups: o["groups"] as? [String])
    }
    var access = XizAccess()
    for g in root["groups"] as? [[String: Any]] ?? [] {
        access.groups.append(XizAccess.Group(name: g["name"] as? String ?? "", prefixes: g["folders"] as? [String] ?? []))
    }
    access.recipients = (root["recipients"] as? [[String: Any]] ?? []).map(recipient)
    for t in root["thresholds"] as? [[String: Any]] ?? [] {
        access.thresholds.append(XizAccess.Threshold(label: t["label"] as? String ?? "", k: t["k"] as? Int ?? 0,
                                                     custodians: (t["custodians"] as? [[String: Any]] ?? []).map(recipient),
                                                     groups: t["groups"] as? [String]))
    }
    return access
}

@MainActor func runKeygen() -> Never {
    guard let out = value("-o", "--output") else { fail("keygen needs -o FILE", code: 2) }
    if FileManager.default.fileExists(atPath: out) { fail("\(out) already exists") }
    let signing = flag("--signing")
    let (text, publicText) = signing ? { let k = XizSigningKey(); return (k.fileText, k.publicText) }()
                                     : { let k = XizIdentity(); return (k.fileText, k.publicText) }()
    let fd = open(out, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0 else { fail("cannot create \(out)") }
    let ok = text.utf8CString.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count - 1) == $0.count - 1 }
    close(fd)
    guard ok else { fail("cannot write \(out)") }
    print(publicText)
    exit(0)
}

@MainActor func runHistory() -> Never {
    guard positional.count == 1 else { fail("history needs one XIZ archive", code: 2) }
    do {
        let h = try Xipper.xizHistory(URL(fileURLWithPath: positional[0]))
        if h.isEmpty { print("not a signed XIZ archive (XIZ 1.3)"); exit(0) }
        let df = ISO8601DateFormatter()
        var bad = false
        for s in h {
            guard s.signed else { print("#\(s.segment)  unsigned"); continue }
            let check = s.valid ? (s.chained ? "OK" : "OK, chain broken") : "INVALID"
            if !s.valid || !s.chained { bad = true }
            var line = "#\(s.segment)  \(check)  \(s.label.isEmpty ? "?" : s.label)  \(s.time.map(df.string) ?? "")  \(s.publicKeyText)"
            if let ts = s.timestamp {
                line += "\n      time-stamp \(df.string(from: ts.time)) by \(ts.authority.isEmpty ? "?" : ts.authority)"
                    + (ts.valid ? (ts.trusted ? "" : " (authority not trusted by this Mac)") : " INVALID")
                if !ts.valid { bad = true }
            }
            print(line)
        }
        exit(bad ? 3 : 0)
    } catch {
        fail("\(error)")
    }
}
