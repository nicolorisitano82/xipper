import Foundation
import Testing
@testable import ForensicKit
@testable import XipperKit

/// EU trusted lists (ETSI TS 119 612): QTST services, their status at the time-stamp's time, matching
/// the authority's certificate. A small list written here; the real Italian list is read by
/// `xipper-forensic trusted-list` (network).
@Suite("Trusted list")
struct TrustedListTests {
    func list(cert: [UInt8], history: [(String, String)], type: String = "http://uri.etsi.org/TrstSvc/Svctype/TSA/QTST") throws -> TrustedList {
        let b64 = Data(cert).base64EncodedString()
        let current = history.last!, older = history.dropLast()
        let hist = older.map { """
            <ServiceHistoryInstance><ServiceTypeIdentifier>\(type)</ServiceTypeIdentifier><ServiceName><Name xml:lang="en">Old</Name></ServiceName>
            <ServiceStatus>http://uri.etsi.org/TrstSvc/TrustedList/Svcstatus/\($0.0)</ServiceStatus><StatusStartingTime>\($0.1)</StatusStartingTime></ServiceHistoryInstance>
            """ }.joined()
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><TrustServiceStatusList xmlns="http://uri.etsi.org/02231/v2#">
        <SchemeInformation><TSLSequenceNumber>7</TSLSequenceNumber><ListIssueDateTime>2026-11-01T00:00:00Z</ListIssueDateTime>
        <NextUpdate><dateTime>2099-01-01T00:00:00Z</dateTime></NextUpdate></SchemeInformation>
        <TrustServiceProviderList><TrustServiceProvider><TSPInformation><TSPName><Name xml:lang="it">Prova S.p.A.</Name></TSPName></TSPInformation>
        <TSPServices><TSPService><ServiceInformation><ServiceTypeIdentifier>\(type)</ServiceTypeIdentifier>
        <ServiceName><Name xml:lang="en">CN=Prova TSA</Name></ServiceName>
        <ServiceDigitalIdentity><DigitalId><X509Certificate>\(b64)</X509Certificate></DigitalId></ServiceDigitalIdentity>
        <ServiceStatus>http://uri.etsi.org/TrstSvc/TrustedList/Svcstatus/\(current.0)</ServiceStatus><StatusStartingTime>\(current.1)</StatusStartingTime>
        </ServiceInformation><ServiceHistory>\(hist)</ServiceHistory></TSPService></TSPServices></TrustServiceProvider></TrustServiceProviderList>
        </TrustServiceStatusList>
        """
        return try TrustedList(xml: Data(xml.utf8), country: "IT", url: URL(string: "https://example.test/TL.xml")!)
    }

    func stamp(_ cert: [UInt8], _ iso: String) -> XizTimestamp {
        var t = XizTimestamp(time: ISO8601DateFormatter().date(from: iso)!, authority: "Prova TSA", valid: true, trusted: true)
        t.certificate = cert
        return t
    }

    @Test func qualifiedOnlyWhileGranted() throws {
        let cert = try XizCertificateTests.identity(rsa: false, cn: "Prova TSA").chain[0]
        let tl = try list(cert: cert, history: [("granted", "2020-01-01T00:00:00Z"), ("withdrawn", "2026-06-01T00:00:00Z")])
        #expect(tl.sequence == "7" && tl.services.count == 1 && tl.services[0].provider == "Prova S.p.A.")
        #expect(tl.qualified(stamp(cert, "2025-03-01T10:00:00Z"))?.name == "CN=Prova TSA")
        #expect(tl.qualified(stamp(cert, "2026-07-01T10:00:00Z")) == nil)      // withdrawn by then
        #expect(tl.qualified(stamp(cert, "2019-07-01T10:00:00Z")) == nil)      // not yet granted
        let other = try XizCertificateTests.identity(rsa: false, cn: "Altra TSA").chain[0]
        #expect(tl.qualified(stamp(other, "2025-03-01T10:00:00Z")) == nil)
        #expect(tl.record["sequence"] == "7" && tl.record["sha256"]?.count == 64)
    }

    @Test func otherServiceTypesIgnored() throws {
        let cert = try XizCertificateTests.identity(rsa: false, cn: "CA").chain[0]
        let tl = try list(cert: cert, history: [("granted", "2020-01-01T00:00:00Z")], type: "http://uri.etsi.org/TrstSvc/Svctype/CA/QC")
        #expect(tl.services.isEmpty)
        #expect(throws: TrustedList.Problem.self) { _ = try TrustedList(xml: Data("<html/>".utf8), country: "IT", url: URL(string: "https://x.test")!) }
    }
}
