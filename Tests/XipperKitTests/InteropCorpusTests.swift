import CryptoKit
import Foundation
import Testing
@testable import XipperKit

/// Archives written by other tools (Fixtures/interop, built by scripts/make-interop-corpus.sh from
/// one synthetic tree): Xipper must test each one clean and extract exactly the tree, without
/// needing the tools at test time.
@Suite("Interop corpus (archives from other tools)")
struct InteropCorpusTests {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/interop")

    struct Expected: Decodable { let password: String; let entries: [String: String] }
    static let expected = try! JSONDecoder().decode(Expected.self, from: Data(contentsOf: dir.appendingPathComponent("expected.json")))

    /// Every archive of the corpus; split archives by their first part only.
    static let archives: [String] = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0 != "expected.json" && !($0.range(of: #"\.\d{3}$"#, options: .regularExpression) != nil && !$0.hasSuffix(".001")) }
        .sorted()

    static func snapshot(_ root: String) -> [String: String] {
        var out: [String: String] = [:]
        let fm = FileManager.default
        func walk(_ path: String, _ rel: String) {
            var st = stat()
            guard lstat(path, &st) == 0 else { return }
            if !rel.isEmpty {
                let key = rel.precomposedStringWithCanonicalMapping
                switch st.st_mode & S_IFMT {
                case S_IFDIR: out[key] = "dir"
                case S_IFLNK: out[key] = "link:" + ((try? fm.destinationOfSymbolicLink(atPath: path)) ?? "?")
                default:
                    let digest = SHA256.hash(data: fm.contents(atPath: path) ?? Data()).map { String(format: "%02x", $0) }.joined()
                    out[key] = "file:" + digest + (st.st_mode & 0o100 != 0 ? ":x" : "")
                }
            }
            if st.st_mode & S_IFMT == S_IFDIR {
                for c in (try? fm.contentsOfDirectory(atPath: path)) ?? [] { walk(path + "/" + c, rel.isEmpty ? c : rel + "/" + c) }
            }
        }
        walk(root, "")
        return out
    }

    /// Methods Xipper does not read yet: the test fails when one starts working, so the list
    /// stays true.
    static let unsupported: [String: String] = [
        "7zz-zip-ppmd.zip": "ZIP method 98, PPMd variant I (7z uses variant H, which Xipper reads)",
    ]

    static func password(_ name: String) -> String? {
        ["infozip-zipcrypto.zip", "7zz-zip-aes256.zip", "7zz-aes-encnames.7z", "7zz-aes-plainnames.7z"].contains(name) ? expected.password : nil
    }

    @Test(arguments: archives)
    func testsAndExtractsExactly(name: String) throws {
        let url = Self.dir.appendingPathComponent(name)
        let pw = Self.password(name)
        if let reason = Self.unsupported[name] {
            let test = try? Xipper.test(url, password: pw)
            #expect(test?.isOK != true, "\(name) is now readable: drop it from `unsupported` (\(reason))")
            return
        }
        let test = try Xipper.test(url, password: pw)
        #expect(test.isOK, "\(name): \(test.failures)")

        let t = TempDir()
        t.mkdir("out")
        var eo = ExtractOptions()
        eo.password = pw
        let r = try Xipper.extract(url, to: t.url("out"), mode: .smart, options: eo)
        let got = Self.snapshot(r.destination.path)

        // Single compressed files: the content of data/sample.bin.
        if name.hasSuffix(".bin.gz") || name.hasSuffix(".bin.bz2") || name.hasSuffix(".bin.xz") || name.hasSuffix(".bin.zst") {
            let digest = SHA256.hash(data: try Data(contentsOf: r.destination)).map { String(format: "%02x", $0) }.joined()
            #expect("file:" + digest == Self.expected.entries["data/sample.bin"], "\(name)")
            return
        }
        if name == "py-cp437-name.zip" {
            // One entry: smart extraction leaves it as is, so the destination is the file itself.
            #expect(r.destination.lastPathComponent.precomposedStringWithCanonicalMapping == "Café ñ.txt",
                    "\(name): \(r.destination.lastPathComponent)")
            return
        }
        // Every tool of the corpus keeps links, empty folders and the executable bit: all must match.
        let a = Self.expected.entries, b = got
        let diff = Set(a.keys).union(b.keys).sorted().filter { a[$0] != b[$0] }
            .map { "\($0): want \(a[$0] ?? "missing"), got \(b[$0] ?? "missing")" }
        #expect(diff.isEmpty, "\(name):\n\(diff.joined(separator: "\n"))")
    }
}
