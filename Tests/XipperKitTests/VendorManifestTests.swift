import CryptoKit
import Foundation
import Testing

/// The vendored codec sources are exactly those recorded in Vendor/MANIFEST.json: a file changed,
/// added or removed without regenerating the manifest (scripts/make-vendor-manifest.py) fails here,
/// so every change to third-party code shows up in review as a manifest diff.
@Suite("Vendored sources")
struct VendorManifestTests {
    static let vendor = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Vendor")

    struct Manifest: Decodable {
        struct Library: Decodable {
            struct File: Decodable { let sha256: String }
            let name: String
            let version: String
            let files: [String: File]
        }
        let libraries: [Library]
    }

    @Test func sourcesMatchTheManifest() throws {
        let m = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: Self.vendor.appendingPathComponent("MANIFEST.json")))
        var listed = Set<String>()
        var changed: [String] = []
        for lib in m.libraries {
            for (rel, f) in lib.files {
                listed.insert(rel)
                guard let data = FileManager.default.contents(atPath: Self.vendor.appendingPathComponent(rel).path) else {
                    changed.append("missing: \(rel)")
                    continue
                }
                if SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() != f.sha256 { changed.append("changed: \(rel)") }
            }
        }
        for lib in m.libraries {
            let base = Self.vendor.appendingPathComponent(lib.name).path
            for case let p as String in FileManager.default.enumerator(atPath: base) ?? NSEnumerator() {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: base + "/" + p, isDirectory: &isDir)
                if !isDir.boolValue, (p as NSString).lastPathComponent != ".DS_Store", !listed.contains(lib.name + "/" + p) {
                    changed.append("not in the manifest: \(lib.name)/\(p)")
                }
            }
        }
        #expect(changed.isEmpty, "regenerate with scripts/make-vendor-manifest.py after checking:\n\(changed.prefix(20).joined(separator: "\n"))")
        #expect(m.libraries.count >= 9)
    }
}
