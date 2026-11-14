import CryptoKit
import Foundation

/// ASiC containers (ETSI EN 319 162) with CAdES signatures: a ZIP whose first entry `mimetype` says
/// `application/vnd.etsi.asic-s+zip` or `…asic-e+zip`.
/// - ASiC-S: one data file, `META-INF/signature.p7s` is a detached CMS over it;
/// - ASiC-E: `META-INF/signature*.p7s` each signs `META-INF/ASiCManifest*.xml`, which lists the data
///   files with their digests (checked here too).
/// XAdES signatures (`signatures*.xml`) are reported, not verified.
enum ASiC {
    static func isASiC(_ url: URL) -> Bool {
        guard let e = try? Xipper.readEntry(url, path: "mimetype", maxBytes: 128) else { return false }
        return String(decoding: e.data, as: UTF8.self).hasPrefix("application/vnd.etsi.asic-")
    }

    static func verify(_ url: URL, options: SignatureCheckOptions) throws -> SignedDocument {
        let mime = String(decoding: try Xipper.readEntry(url, path: "mimetype", maxBytes: 128).data, as: UTF8.self)
        let entries = try Xipper.list(url).filter { $0.kind == .file }
        func read(_ path: String) throws -> [UInt8] { try Xipper.readEntry(url, path: path, maxBytes: 1 << 30).data }
        let meta = entries.filter { $0.path.hasPrefix("META-INF/") }
        let data = entries.filter { !$0.path.hasPrefix("META-INF/") && $0.path != "mimetype" }
        var signatures: [DocumentSignature] = []
        var problems: [String] = []
        if mime.contains("asic-s") {
            guard let sig = meta.first(where: { $0.path.lowercased().hasSuffix(".p7s") }), let file = data.first, data.count == 1 else {
                throw XipperError.unsupported("ASiC-S: one file and META-INF/signature.p7s expected")
            }
            let cms = try CMSSignedData(der: try read(sig.path))
            let content = try read(file.path)
            for s in cms.signers { signatures.append(SignedDocuments.check(cms, s, detached: content, depth: 0, options: options)) }
            return SignedDocument(format: .asic, signatures: signatures, content: content, contentName: file.path,
                                  trustedList: options.trustedList?.record)
        }
        // ASiC-E: every signature over its manifest, every manifest's digests over the files.
        for (i, sig) in meta.filter({ $0.path.lowercased().hasSuffix(".p7s") }).enumerated() {
            let manifestName = sig.path.replacingOccurrences(of: "signature", with: "ASiCManifest", options: .caseInsensitive)
                .replacingOccurrences(of: ".p7s", with: ".xml")
            guard let manifest = meta.first(where: { $0.path == manifestName }) ?? meta.first(where: { $0.path.contains("ASiCManifest") }) else {
                problems.append("\(sig.path): no ASiCManifest")
                continue
            }
            let manifestBytes = try read(manifest.path)
            let cms = try CMSSignedData(der: try read(sig.path))
            let refs = references(manifestBytes)
            var digestProblems: [String] = []
            for r in refs {
                guard let f = Self.hash(r.method) else { digestProblems.append("\(r.uri): digest method not supported"); continue }
                guard let bytes = try? read(r.uri) else { digestProblems.append("\(r.uri): listed but missing"); continue }
                if f(bytes) != r.digest { digestProblems.append("\(r.uri): changed after signing") }
            }
            let unlisted = data.map(\.path).filter { p in !refs.contains { $0.uri == p } }
            if !unlisted.isEmpty { digestProblems.append("not covered by the signature: " + unlisted.joined(separator: ", ")) }
            for s in cms.signers {
                var d = SignedDocuments.check(cms, s, detached: manifestBytes, depth: i, options: options)
                if !digestProblems.isEmpty { d.integrity = false; d.level = .invalid; d.problems += digestProblems }
                signatures.append(d)
            }
        }
        if meta.contains(where: { $0.path.lowercased().hasSuffix(".xml") && $0.path.lowercased().contains("signatures") }) {
            var x = DocumentSignature.unreadable("XAdES signature (XML): not verified by this version")
            x.level = .untrustedSigner
            signatures.append(x)
        }
        if signatures.isEmpty { throw XipperError.unsupported("ASiC-E without CAdES signatures" + (problems.isEmpty ? "" : ": " + problems.joined(separator: "; "))) }
        return SignedDocument(format: .asic, signatures: signatures, content: nil, contentName: url.lastPathComponent,
                              trustedList: options.trustedList?.record)
    }

    struct Reference { var uri: String; var method: String; var digest: [UInt8] }

    /// `<DataObjectReference URI="…"><ds:DigestMethod Algorithm="…"/><ds:DigestValue>…</ds:DigestValue>`.
    static func references(_ xml: [UInt8]) -> [Reference] {
        final class P: NSObject, XMLParserDelegate {
            var out: [Reference] = []
            var uri: String?, method = "", text = "", inValue = false
            func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
                switch e {
                case "DataObjectReference": uri = a["URI"]?.removingPercentEncoding; method = ""
                case "DigestMethod": method = a["Algorithm"] ?? ""
                case "DigestValue": inValue = true; text = ""
                default: break
                }
            }
            func parser(_ p: XMLParser, foundCharacters s: String) { if inValue { text += s } }
            func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
                if e == "DigestValue" {
                    inValue = false
                    if let u = uri, let d = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        out.append(Reference(uri: u, method: method, digest: Array(d)))
                    }
                }
            }
        }
        let p = P()
        let x = XMLParser(data: Data(xml))
        x.shouldProcessNamespaces = true
        x.delegate = p
        x.parse()
        return p.out
    }

    static func hash(_ uri: String) -> (([UInt8]) -> [UInt8])? {
        switch uri {
        case "http://www.w3.org/2001/04/xmlenc#sha256": { Array(SHA256.hash(data: $0)) }
        case "http://www.w3.org/2001/04/xmldsig-more#sha384": { Array(SHA384.hash(data: $0)) }
        case "http://www.w3.org/2001/04/xmlenc#sha512": { Array(SHA512.hash(data: $0)) }
        case "http://www.w3.org/2000/09/xmldsig#sha1": { Array(Insecure.SHA1.hash(data: $0)) }
        default: nil
        }
    }
}
