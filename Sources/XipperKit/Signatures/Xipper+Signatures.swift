import Foundation

extension Xipper {
    /// A signed document Xipper can check: a `.p7m` (CAdES), a signed PDF (PAdES), an ASiC container.
    public static func isSignedDocument(_ url: URL) -> Bool { signedFormat(url) != nil }

    static func signedFormat(_ url: URL) -> SignedDocument.Format? {
        let ext = url.pathExtension.lowercased()
        guard let r = try? FileReader(path: url.path), r.size > 0 else { return nil }
        if ext == "p7m" || ext == "p7s" {
            guard let all = try? r.read(at: 0, count: Int(min(r.size, 256 << 20))) else { return nil }
            return SignedDocuments.isP7M(all) ? .p7m : nil
        }
        if ext == "pdf" {
            guard r.size <= 512 << 20, let all = try? r.read(at: 0, count: Int(r.size)) else { return nil }
            return PAdES.isSignedPDF(all) ? .pdf : nil
        }
        if ["asics", "asice", "scs", "sce"].contains(ext) { return ASiC.isASiC(url) ? .asic : nil }
        return nil
    }

    /// Checks every signature of a signed document: integrity, the signer's certificate, the time,
    /// qualified or not (with a trusted list), revocation (embedded, or online with `options.online`).
    public static func verifySignedDocument(_ url: URL, options: SignatureCheckOptions = SignatureCheckOptions()) throws -> SignedDocument {
        switch signedFormat(url) {
        case .pdf?: return try PAdES.verify(try [UInt8](Data(contentsOf: url)), name: url.lastPathComponent, options: options)
        case .asic?: return try ASiC.verify(url, options: options)
        default: return try SignedDocuments.verifyP7M(try [UInt8](Data(contentsOf: url)), name: url.lastPathComponent, options: options)
        }
    }

    /// The document inside a `.p7m` (the innermost of nested ones) and its name, without checking.
    public static func signedContent(_ url: URL) throws -> (name: String, data: [UInt8]) {
        let doc = try verifySignedDocument(url)
        guard let content = doc.content else { throw XipperError.unsupported("no content in the signed file") }
        return (doc.contentName, content)
    }
}
