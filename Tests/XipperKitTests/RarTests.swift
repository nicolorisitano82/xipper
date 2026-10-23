import Foundation
import Testing
@testable import XipperKit

/// RAR 4.x and RAR5, read only, on libarchive's test vectors (Fixtures/rar); the system bsdtar
/// (libarchive) extracts the same archives as an independent reference.
@Suite("RAR (read only)")
struct RarTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/rar")
    static func url(_ name: String) -> URL { fixtures.appendingPathComponent(name) }

    @Test(arguments: ["rar_compress_normal.rar", "rar5_multiple_files_solid.rar", "rar_unicode.rar", "rar5_blake2.rar",
                      "rar5_compressed.rar", "rar_filter.rar", "rar5_arm.rar", "rar_subblock.rar"])
    func extractsLikeBsdtar(name: String) throws {
        let t = TempDir()
        let archive = Self.url(name)
        #expect(try ArchiveFormat.detect(archive) == .rar)
        #expect(try Xipper.test(archive).isOK)
        t.mkdir("ours"); t.mkdir("bsd")
        try Xipper.extract(archive, to: t.url("ours"), mode: .into)
        let r = run("/usr/bin/tar", ["-xf", archive.path, "-C", t.path + "/bsd"])
        #expect(r.status == 0, "\(r.output)")
        let (same, diff) = treesEqual(t.path + "/bsd", t.path + "/ours")
        #expect(same, "\(diff)")
        // Listing and single-entry reads agree with the extraction.
        let files = try Xipper.list(archive).filter { $0.kind == .file }
        #expect(!files.isEmpty)
        if let f = files.first {
            let c = try Xipper.readEntry(archive, path: f.path, maxBytes: 1 << 20)
            let onDisk = try [UInt8](Data(contentsOf: t.url("ours/" + f.path)))
            #expect(c.data == Array(onDisk.prefix(1 << 20)))
        }
    }

    @Test func multiVolumeFromAnyPart() throws {
        for part in ["01", "04", "08"] {
            let archive = Self.url("rar5_multiarchive.part\(part).rar")
            let report = try Xipper.test(archive)
            #expect(report.isOK && report.entries == 2, "part \(part): \(report.failures)")
        }
        #expect(RarReader.volumes(for: Self.url("rar5_multiarchive.part03.rar").path).count == 8)
        #expect(Xipper.baseName("film.part03.rar") == "film" && Xipper.baseName("film.rar") == "film" && Xipper.baseName("film.r07") == "film")
    }

    @Test func encryptedAndDamagedAreReported() throws {
        // Encrypted RAR5 entries need the password (Rar5CryptoTests covers reading them).
        #expect(throws: XipperError.passwordRequired(entry: "rar5_encrypted.rar")) { try Xipper.test(Self.url("rar5_encrypted.rar")) }
        let bad = try Xipper.test(Self.url("rar5_bad_tables.rar"))
        #expect(!bad.isOK)
        #expect(!ArchiveFormat.rar.canCreate)
        let t = TempDir()
        #expect(throws: XipperError.self) { try Xipper.extract(Self.url("rar5_bad_tables.rar"), to: t.url(""), mode: .into) }
    }
}
