import CryptoKit
import Foundation
import Security
import XipperKit

/// An EU trusted list (ETSI TS 119 612), to tell whether a time-stamp came from a **qualified** time-stamp
/// authority (eIDAS art. 42: presumption of accuracy of the date). Only the services of type
/// `Svctype/TSA/QTST` are kept, with their certificates and status history.
///
/// Limits, stated in reports: the list's own XML signature is not verified here (the list is fetched
/// over https from the address in the EU list of lists, and its SHA-256 is recorded so that it can be
/// checked afterwards); revocation of the authority's certificate is not checked.
public struct TrustedList: Sendable {
    public struct Service: Sendable {
        public var provider: String
        public var name: String
        public var certificates: [[UInt8]]
        /// (status URI, since), oldest first.
        public var history: [(String, Date)]

        /// The status at `time`: the last one that started at or before it.
        public func status(at time: Date) -> String? { history.last { $0.1 <= time }?.0 }
    }

    public var country: String
    public var url: URL
    public var sequence: String
    public var issued: Date?
    public var nextUpdate: Date?
    /// SHA-256 of the list as fetched.
    public var sha256: String
    public var services: [Service]

    public static let granted = "http://uri.etsi.org/TrstSvc/TrustedList/Svcstatus/granted"
    static let qtst = "http://uri.etsi.org/TrstSvc/Svctype/TSA/QTST"
    /// National lists, from the EU list of lists (https://ec.europa.eu/tools/lotl/eu-lotl.xml).
    public static let known: [String: URL] = ["IT": URL(string: "https://eidas.agid.gov.it/TL/TSL-IT.xml")!]
    static let lotl = URL(string: "https://ec.europa.eu/tools/lotl/eu-lotl.xml")!

    public enum Problem: LocalizedError {
        case unknownCountry(String), notAList, fetch(String)
        public var errorDescription: String? {
            switch self {
            case .unknownCountry(let c): "no trusted list for \(c) in the EU list of lists"
            case .notAList: "the file is not an ETSI trusted list"
            case .fetch(let m): "trusted list: \(m)"
            }
        }
    }

    /// Parses a list (XML bytes).
    public init(xml: Data, country: String, url: URL) throws {
        let p = Parser()
        let x = XMLParser(data: xml)
        x.delegate = p
        x.shouldProcessNamespaces = true
        guard x.parse(), p.isList else { throw Problem.notAList }
        self.country = country
        self.url = url
        sequence = p.sequence
        issued = p.issued.flatMap(Self.date)
        nextUpdate = p.nextUpdate.flatMap(Self.date)
        sha256 = ForensicCase.hex(Array(SHA256.hash(data: xml)))
        services = p.services
    }

    /// The list for `country`, from the cache (`cache` folder) when fresh, else downloaded (https).
    /// Network only when this is called: the reports say when and which list was used.
    public static func load(country: String = "IT", cache: URL? = nil, maxAge: TimeInterval = 86400) throws -> TrustedList {
        let dir = cache ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("app.xipper.forensic")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("TL-\(country).xml")
        let url = try known[country] ?? listURL(country)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path), let m = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(m) < maxAge, let data = try? Data(contentsOf: file),
           let list = try? TrustedList(xml: data, country: country, url: url), (list.nextUpdate ?? .distantFuture) > Date() {
            return list
        }
        let data = try fetch(url)
        let list = try TrustedList(xml: data, country: country, url: url)
        try? data.write(to: file, options: .atomic)
        return list
    }

    static func listURL(_ country: String) throws -> URL {
        let data = try fetch(lotl)
        let text = String(decoding: data, as: UTF8.self)
        // Each pointer: <TSLLocation>URL</TSLLocation> … <SchemeTerritory>CC</SchemeTerritory>.
        for part in text.components(separatedBy: "<OtherTSLPointer>").dropFirst() {
            guard part.contains("<SchemeTerritory>\(country)</SchemeTerritory>"),
                  let a = part.range(of: "<TSLLocation>"), let b = part.range(of: "</TSLLocation>"),
                  let u = URL(string: String(part[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespaces)),
                  u.pathExtension.lowercased() == "xml" else { continue }
            return u
        }
        throw Problem.unknownCountry(country)
    }

    static func fetch(_ url: URL) throws -> Data {
        guard url.scheme == "https" else { throw Problem.fetch("not https: \(url)") }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<Data, Error> = .failure(Problem.fetch("timed out"))
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 30)) { d, r, e in
            if let e { result = .failure(e) } else if let h = r as? HTTPURLResponse, h.statusCode != 200 {
                result = .failure(Problem.fetch("HTTP \(h.statusCode) from \(url.host() ?? "")"))
            } else { result = .success(d ?? Data()) }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }

    /// The qualified service a time-stamp comes from: its signing certificate is listed, or chains (at
    /// the token's time) to a listed certificate, and the service was "granted" at that time.
    public func qualified(_ t: XizTimestamp) -> Service? {
        guard !t.certificate.isEmpty, let leaf = SecCertificateCreateWithData(nil, Data(t.certificate) as CFData) else { return nil }
        let issuers = t.issuers.compactMap { SecCertificateCreateWithData(nil, Data($0) as CFData) }
        for s in services where s.status(at: t.time) == Self.granted {
            for der in s.certificates {
                if der == t.certificate { return s }
                guard let anchor = SecCertificateCreateWithData(nil, Data(der) as CFData) else { continue }
                var trust: SecTrust?
                guard SecTrustCreateWithCertificates(([leaf] + issuers) as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
                      let trust else { continue }
                SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, true)
                SecTrustSetVerifyDate(trust, t.time as CFDate)
                SecTrustSetNetworkFetchAllowed(trust, false)
                if SecTrustEvaluateWithError(trust, nil) { return s }
            }
        }
        return nil
    }

    /// For reports: which list, when, and its hash.
    public var record: [String: String] {
        var d = ["country": country, "url": url.absoluteString, "sequence": sequence, "sha256": sha256,
                 "signature_checked": "no (list fetched over https; its SHA-256 lets anyone check it against the published list)"]
        if let i = issued { d["issued"] = ForensicCase.timestamp(i) }
        return d
    }

    static func date(_ s: String) -> Date? { ISO8601DateFormatter().date(from: s.trimmingCharacters(in: .whitespacesAndNewlines)) }

    // MARK: XML

    final class Parser: NSObject, XMLParserDelegate {
        var isList = false
        var sequence = "", issued: String?, nextUpdate: String?
        var services: [Service] = []
        var path: [String] = []
        var text = ""
        var provider = ""
        var providerNameTaken = false
        // current service
        var type = "", name = "", certs: [[UInt8]] = [], status = "", since = ""
        var history: [(String, Date)] = []
        var hType = "", hStatus = "", hSince = ""

        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            path.append(e)
            text = ""
            switch e {
            case "TrustServiceStatusList": isList = true
            case "TrustServiceProvider": provider = ""; providerNameTaken = false
            case "TSPService": type = ""; name = ""; certs = []; status = ""; since = ""; history = []
            case "ServiceHistoryInstance": hType = ""; hStatus = ""; hSince = ""
            default: break
            }
        }

        func parser(_ p: XMLParser, foundCharacters s: String) { text += s }

        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let inHistory = path.contains("ServiceHistoryInstance")
            let inService = path.contains("TSPService")
            switch e {
            case "TSLSequenceNumber": sequence = v
            case "ListIssueDateTime": issued = v
            case "NextUpdate" where path.contains("SchemeInformation"): nextUpdate = nil
            case "dateTime" where path.contains("NextUpdate"): nextUpdate = v
            case "Name" where path.contains("TSPName") && !providerNameTaken: provider = v; providerNameTaken = true
            case "Name" where inService && path.contains("ServiceName") && !inHistory && name.isEmpty: name = v
            case "ServiceTypeIdentifier": if inHistory { hType = v } else if inService { type = v }
            case "ServiceStatus": if inHistory { hStatus = v } else if inService { status = v }
            case "StatusStartingTime": if inHistory { hSince = v } else if inService { since = v }
            case "X509Certificate" where inService && !inHistory:
                if let d = Data(base64Encoded: v, options: .ignoreUnknownCharacters) { certs.append(Array(d)) }
            case "ServiceHistoryInstance":
                if hType == TrustedList.qtst || hType.isEmpty, let d = TrustedList.date(hSince) { history.append((hStatus, d)) }
            case "TSPService":
                if type == TrustedList.qtst {
                    var h = history
                    if let d = TrustedList.date(since) { h.append((status, d)) }
                    services.append(Service(provider: provider, name: name, certificates: certs, history: h.sorted { $0.1 < $1.1 }))
                }
            default: break
            }
            path.removeLast()
            text = ""
        }
    }
}
