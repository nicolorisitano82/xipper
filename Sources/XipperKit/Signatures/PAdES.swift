import CryptoKit
import Foundation

/// Signed PDF files (PAdES, ISO 32000 §12.8): each signature dictionary names the byte ranges it
/// covers (`/ByteRange [a b c d]`: everything except the hex string of its own `/Contents`), and holds
/// a detached CMS signature over them. Signatures are listed in the order they were added; a file
/// longer than the last signed range was changed after that signature (an incremental update).
enum PAdES {
    struct Field {
        var ranges: [(Int, Int)]
        var cms: [UInt8]
        var subFilter: String
    }

    static func isSignedPDF(_ b: [UInt8]) -> Bool {
        b.starts(with: Array("%PDF-".utf8)) && find(Array("/ByteRange".utf8), in: b, from: 0) != nil
    }

    /// Every signature field of the file, in file order.
    static func fields(_ b: [UInt8]) -> [Field] {
        var out: [Field] = []
        var at = 0
        let key = Array("/ByteRange".utf8)
        while let p = find(key, in: b, from: at) {
            at = p + key.count
            guard let open = b[at...].prefix(64).firstIndex(of: UInt8(ascii: "[")),
                  let close = b[open...].prefix(128).firstIndex(of: UInt8(ascii: "]")) else { continue }
            let numbers = String(decoding: b[(open + 1)..<close], as: UTF8.self).split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" })
                .compactMap { Int($0) }
            guard numbers.count == 4 else { continue }
            let (a, l1, c, l2) = (numbers[0], numbers[1], numbers[2], numbers[3])
            guard a == 0, l1 > 0, c > l1, l2 >= 0, c + l2 <= b.count, l1 <= c else { continue }
            // Between the two ranges: the /Contents hex string, "<...>".
            let gap = b[l1..<c]
            guard gap.first == UInt8(ascii: "<"), gap.last == UInt8(ascii: ">") else { continue }
            guard let cms = hex(gap.dropFirst().dropLast()) else { continue }
            // The /SubFilter of this dictionary: searched around the ranges' gap.
            let window = b[max(0, l1 - 4096)..<min(b.count, c + 4096)]
            let sub = name(after: "/SubFilter", in: Array(window)) ?? "adbe.pkcs7.detached"
            out.append(Field(ranges: [(a, l1), (c, l2)], cms: trimDER(cms), subFilter: sub))
        }
        return out
    }

    /// Verifies every signature (and document time-stamp) of a signed PDF.
    static func verify(_ b: [UInt8], name: String, options: SignatureCheckOptions) throws -> SignedDocument {
        let fields = fields(b)
        guard !fields.isEmpty else { throw XipperError.unsupported("no signature in this PDF") }
        var signatures: [DocumentSignature] = []
        for (i, f) in fields.enumerated() {
            var signed: [UInt8] = []
            for (start, length) in f.ranges { signed += b[start..<(start + length)] }
            let coversAll = f.ranges.last.map { $0.0 + $0.1 } == b.count
            guard let cms = try? CMSSignedData(der: f.cms) else {
                var bad = DocumentSignature.unreadable("signature \(i + 1): not a CMS signature")
                bad.depth = i
                signatures.append(bad)
                continue
            }
            if f.subFilter == "ETSI.RFC3161" {
                // A document time-stamp: its imprint is the hash of the covered bytes.
                var ts = DocumentSignature.unreadable("")
                ts.problems = []
                ts.kind = .documentTimestamp
                ts.depth = i
                if let t = SignedDocuments.verifyTimestamp(f.cms, over: signed, options: options) {
                    ts.timestamp = t
                    ts.integrity = t.valid
                    ts.referenceTime = t.time
                    ts.level = t.valid ? (t.qualified ? .qualified : .advanced) : .invalid
                } else {
                    ts.problems.append("the document time-stamp does not verify")
                }
                signatures.append(ts)
                continue
            }
            for s in cms.signers {
                var d = SignedDocuments.check(cms, s, detached: signed, depth: i, options: options)
                if !coversAll { d.problems.append("the PDF was changed after this signature (later revisions: annotations, form fields or further signatures)") }
                d.coversWholeFile = coversAll
                signatures.append(d)
            }
        }
        return SignedDocument(format: .pdf, signatures: signatures, content: nil, contentName: name,
                              trustedList: options.trustedList?.record)
    }

    // MARK: helpers

    static func find(_ needle: [UInt8], in hay: [UInt8], from: Int) -> Int? {
        guard needle.count <= hay.count, from <= hay.count - needle.count else { return nil }
        let first = needle[0]
        var i = from
        while i <= hay.count - needle.count {
            if hay[i] == first, hay[i..<(i + needle.count)].elementsEqual(needle) { return i }
            i += 1
        }
        return nil
    }

    static func hex<C: Collection>(_ s: C) -> [UInt8]? where C.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(s.count / 2)
        var high: UInt8?
        for c in s {
            let v: UInt8
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): v = c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): v = c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): v = c - UInt8(ascii: "A") + 10
            case 0x20, 0x0A, 0x0D, 0x09: continue
            default: return nil
            }
            if let h = high { out.append(h << 4 | v); high = nil } else { high = v }
        }
        return out
    }

    /// /Contents is padded with zeros after the DER: keep the element only.
    static func trimDER(_ b: [UInt8]) -> [UInt8] {
        let a = ASN1(b)
        guard let n = try? a.root() else { return b }
        return Array(b[0..<n.next])
    }

    /// The PDF name after `key` ("/SubFilter /ETSI.CAdES.detached" → "ETSI.CAdES.detached").
    static func name(after key: String, in b: [UInt8]) -> String? {
        guard let p = find(Array(key.utf8), in: b, from: 0) else { return nil }
        var i = p + key.utf8.count
        while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
        guard i < b.count, b[i] == UInt8(ascii: "/") else { return nil }
        i += 1
        var end = i
        while end < b.count, !"/ <>[]()\n\r\t".utf8.contains(b[end]) { end += 1 }
        return String(decoding: b[i..<end], as: UTF8.self)
    }
}
