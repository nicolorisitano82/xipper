import CryptoKit
import Foundation
import Security

/// The parts of an X.509 certificate a signature check needs, read from its DER: names (with the
/// Italian tax code in SERIALNUMBER), validity, key usage, the qualified-certificate statements
/// (ETSI EN 319 412-5), the addresses for revocation checks, the key identifiers.
public struct SignerCertificate: Sendable, Equatable {
    public struct Name: Sendable, Equatable {
        /// (OID, value) in order.
        public var attributes: [(String, String)]
        public var commonName: String? { value("2.5.4.3") }
        public var givenName: String? { value("2.5.4.42") }
        public var surname: String? { value("2.5.4.4") }
        public var organization: String? { value("2.5.4.10") }
        public var organizationIdentifier: String? { value("2.5.4.97") }
        public var serialNumber: String? { value("2.5.4.5") }
        public var country: String? { value("2.5.4.6") }
        public func value(_ oid: String) -> String? { attributes.first { $0.0 == oid }?.1 }
        /// A person's name, else the common name, else the organization.
        public var display: String {
            if let g = givenName, let s = surname { return "\(g) \(s)" }
            return commonName ?? organization ?? attributes.first?.1 ?? "?"
        }
        public static func == (a: Name, b: Name) -> Bool { a.attributes.elementsEqual(b.attributes) { $0 == $1 } }
    }

    public var der: [UInt8]
    public var serial: [UInt8]
    public var issuer: Name
    public var subject: Name
    /// The issuer Name as encoded, to match CMS signer identifiers.
    var issuerDER: [UInt8]
    var subjectDER: [UInt8]
    public var notBefore: Date
    public var notAfter: Date
    /// Key usage bit 1: the key signs content with commitment (what legal signatures need).
    public var nonRepudiation: Bool
    public var keyUsagePresent: Bool
    /// QCStatements: EU qualified certificate (QcCompliance), key in a qualified device (QcSSCD),
    /// and the QcType (eSign, eSeal, web).
    public var qcCompliance: Bool
    public var qcSSCD: Bool
    public var qcTypes: [String]
    public var policies: [String]
    public var ocspURLs: [String]
    public var crlURLs: [String]
    public var issuerURLs: [String]
    public var subjectKeyID: [UInt8]?
    public var authorityKeyID: [UInt8]?
    public var sha256: String { Self.hex(Array(SHA256.hash(data: der))) }
    /// The Italian tax code: SERIALNUMBER "TINIT-XXXXXX…" (or "IT:…" on older cards).
    public var taxCode: String? {
        guard let s = subject.serialNumber else { return nil }
        for prefix in ["TINIT-", "IT:"] where s.uppercased().hasPrefix(prefix) { return String(s.dropFirst(prefix.count)) }
        return nil
    }

    public static func == (a: SignerCertificate, b: SignerCertificate) -> Bool { a.der == b.der }

    static let qcCompliance = "0.4.0.1862.1.1", qcSSCD = "0.4.0.1862.1.4", qcType = "0.4.0.1862.1.6"

    public init(der: [UInt8]) throws {
        let a = ASN1(der)
        let cert = try a.root()
        let parts = try a.children(cert)
        guard parts.count >= 3, cert.tag == 0x30 else { throw ASN1.Failure.malformed("certificate") }
        var tbs = try a.children(parts[0])
        if tbs.first?.tag == 0xA0 { tbs.removeFirst() }  // version
        guard tbs.count >= 6 else { throw ASN1.Failure.malformed("tbsCertificate") }
        self.der = Array(a.raw(cert))
        serial = a.integer(tbs[0])
        issuerDER = Array(a.raw(tbs[2]))
        subjectDER = Array(a.raw(tbs[4]))
        issuer = try Self.name(a, tbs[2])
        subject = try Self.name(a, tbs[4])
        let validity = try a.children(tbs[3])
        guard validity.count == 2, let nb = a.time(validity[0]), let na = a.time(validity[1]) else { throw ASN1.Failure.malformed("validity") }
        notBefore = nb
        notAfter = na
        nonRepudiation = false; keyUsagePresent = false
        qcCompliance = false; qcSSCD = false; qcTypes = []; policies = []
        ocspURLs = []; crlURLs = []; issuerURLs = []
        subjectKeyID = nil; authorityKeyID = nil
        guard let extensionsTag = tbs.first(where: { $0.tag == 0xA3 }), let list = try a.children(extensionsTag).first else { return }
        for ext in try a.children(list) {
            // One malformed extension leaves the others (and the certificate) readable.
            guard let e = try? a.children(ext), e.count >= 2, let valueNode = e.last, let octets = try? a.octets(valueNode) else { continue }
            let value = ASN1(octets)
            guard let v = try? value.root() else { continue }
            do { try readExtension(a.oid(e[0]), value, v) } catch { continue }
        }
    }

    private mutating func readExtension(_ oid: String, _ value: ASN1, _ v: ASN1.Node) throws {
        do {
            switch oid {
            case "2.5.29.15":  // keyUsage BIT STRING: first byte unused bits, then bits from the top
                keyUsagePresent = true
                let bits = value.content(v)
                if bits.count >= 2 { nonRepudiation = bits[bits.startIndex + 1] & 0x40 != 0 }
            case "2.5.29.14":
                subjectKeyID = Array(value.content(v))
            case "2.5.29.35":  // [0] keyIdentifier
                if let k = try value.children(v).first(where: { $0.tag == 0x80 }) { authorityKeyID = Array(value.content(k)) }
            case "1.3.6.1.5.5.7.1.3":  // QCStatements
                for st in try value.children(v) {
                    let s = try value.children(st)
                    guard let id = s.first else { continue }
                    switch value.oid(id) {
                    case Self.qcCompliance: qcCompliance = true
                    case Self.qcSSCD: qcSSCD = true
                    case Self.qcType:
                        if s.count > 1 { qcTypes += try value.children(s[1]).map { value.oid($0) } }
                    default: break
                    }
                }
            case "2.5.29.32":  // certificatePolicies
                for p in try value.children(v) { if let id = try value.children(p).first { policies.append(value.oid(id)) } }
            case "1.3.6.1.5.5.7.1.1":  // authorityInfoAccess
                for ad in try value.children(v) {
                    let x = try value.children(ad)
                    guard x.count == 2, x[1].tag == 0x86 else { continue }
                    let uri = String(decoding: value.content(x[1]), as: UTF8.self)
                    switch value.oid(x[0]) {
                    case "1.3.6.1.5.5.7.48.1": ocspURLs.append(uri)
                    case "1.3.6.1.5.5.7.48.2": issuerURLs.append(uri)
                    default: break
                    }
                }
            case "2.5.29.31":  // CRL distribution points: every URI inside
                crlURLs += Self.uris(value, v)
            default: break
            }
        }
    }

    static func name(_ a: ASN1, _ n: ASN1.Node) throws -> Name {
        var out: [(String, String)] = []
        for rdn in try a.children(n) {
            for atv in try a.children(rdn) {
                let p = try a.children(atv)
                if p.count == 2 { out.append((a.oid(p[0]), a.string(p[1]))) }
            }
        }
        return Name(attributes: out)
    }

    static func uris(_ a: ASN1, _ n: ASN1.Node) -> [String] {
        if n.tag == 0x86 { return [String(decoding: a.content(n), as: UTF8.self)] }
        guard n.constructed, let kids = try? a.children(n) else { return [] }
        return kids.flatMap { uris(a, $0) }
    }

    /// The certificate's public key, for Security.
    var secKey: SecKey? {
        guard let c = SecCertificateCreateWithData(nil, Data(der) as CFData) else { return nil }
        return SecCertificateCopyKey(c)
    }

    var secCertificate: SecCertificate? { SecCertificateCreateWithData(nil, Data(der) as CFData) }

    /// Valid at `date` by its own dates.
    public func isValid(at date: Date) -> Bool { notBefore <= date && date <= notAfter }

    static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
}
