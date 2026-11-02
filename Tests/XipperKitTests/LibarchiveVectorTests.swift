import Foundation
import Testing
@testable import XipperKit

/// libarchive's ZIP and 7z test vectors (Fixtures/libarchive): archives from many tools must test
/// clean, the malformed ones must be refused with an error, never a crash or a hang. The lists
/// follow what libarchive's own tests expect of each file.
@Suite("libarchive ZIP and 7z vectors")
struct LibarchiveVectorTests {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/libarchive")
    static let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != "README.md" }.sorted()

    /// Refused on purpose, as libarchive refuses them (or a deliberately bad CRC/size inside).
    static let refused: Set<String> = [
        "test_read_format_7zip_entries_oom.7z", "test_read_format_7zip_folders_oom.7z", "test_read_format_7zip_issue2765.7z",
        "test_read_format_7zip_malformed.7z", "test_read_format_7zip_malformed2.7z", "test_read_format_7zip_malformed3.7z",
        "test_read_format_7zip_malformed_numfiles_oom.7z", "test_read_format_7zip_null_client_next.7z",
        "test_read_format_7zip_sfx_elf64trunc.elf", "test_read_format_zip.zip", "test_read_format_zip_bz2_hang.zip",
        "test_read_format_zip_lzma_alone_large_size.zip", "test_read_format_zip_lzma_alone_leak.zipx",
        "test_read_format_zip_malformed1.zip", "test_read_format_zip_ppmd8_crash_1.zipx", "test_read_format_zip_ppmd8_crash_2.zipx",
        "test_read_format_zip_size_exceeds_declared_deflate.zip", "test_read_format_zip_size_exceeds_declared_stored.zip",
        "test_read_format_zip_symlink_unsupported_compression.zip", "test_read_format_zip_uncompressed_size_off_by_4gib.zip",
        "test_read_format_zip_zipx_lzma_oom.zipx",
        // PKWARE strong encryption: not supported (libarchive neither).
        "test_read_format_zip_encryption_data.zip", "test_read_format_zip_encryption_header.zip",
        "test_read_format_zip_encryption_partially.zip",
        // No end of central directory at all: libarchive reads it as a stream; Xipper refuses
        // it and `Xipper.repairZip` rebuilds it (ZipRepairTests).
        "test_read_format_zip_extra_padding.zip",
    ]

    static func password(_ name: String) -> String? {
        if name.contains("7zip_encryption") || name.contains("traditional") { return "12345678" }
        if name.contains("winzip_aes") { return "password" }
        if name.contains("ppmd8_aes256") { return "test_password_zipx" }
        return nil
    }

    @Test(arguments: files)
    func readsOrRefusesCleanly(name: String) {
        let url = Self.dir.appendingPathComponent(name)
        let report = Result { try Xipper.test(url, password: Self.password(name)) }
        if Self.refused.contains(name) {
            if case let .success(r) = report { #expect(!r.isOK, "\(name) was accepted") }
        } else {
            switch report {
            case let .success(r): #expect(r.isOK, "\(name): \(r.failures)")
            case let .failure(e): Issue.record("\(name): \(e)")
            }
        }
    }

    @Test func selfExtracting7zAndOddNames() throws {
        let sfx = Self.dir.appendingPathComponent("test_read_format_7zip_sfx_pe.exe")
        #expect(try ArchiveFormat.detect(sfx) == .sevenZip)
        #expect(try Xipper.list(sfx).count == 1)
        #expect(throws: XipperError.self) { try Xipper.edit(sfx, changes: [.makeDirectory("x")]) }
        let names = try Xipper.list(Self.dir.appendingPathComponent("test_read_format_zip_7075_utf8_paths.zip")).map(\.path)
        #expect(names.map(\.precomposedStringWithCanonicalMapping) == ["File 1.txt", "File 2 - ö.txt", "File 3 - ä.txt", "File 4 - å.txt"])
        #expect(try Xipper.list(Self.dir.appendingPathComponent("test_read_format_7zip_empty_archive.7z")).isEmpty)
    }
}
