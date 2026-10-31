import Foundation
import Testing
@testable import XipperKit

@Suite("Missing volumes")
struct MissingVolumeTests {
    static func split(_ t: TempDir, _ format: ArchiveFormat, style: ZipVolumeStyle = .spanned) throws -> URL {
        t.write("src/big.bin", sampleData(600_000, seed: 7))
        var o = CreateOptions()
        o.format = format
        o.level = 0
        o.zipMethod = .store
        o.volumeSize = 128 << 10
        o.zipVolumeStyle = style
        let out = t.url("a." + format.fileExtension)
        _ = try Xipper.create(from: [t.url("src")], to: out, options: o)
        return out
    }

    @Test func spannedZipNamesTheMissingPart() throws {
        let t = TempDir()
        let zip = try Self.split(t, .zip)
        #expect(Xipper.missingVolume(of: zip) == nil)
        try FileManager.default.removeItem(atPath: t.path + "/a.z02")
        #expect(Xipper.missingVolume(of: zip) == t.path + "/a.z02")
        #expect(throws: (any Error).self) { _ = try Xipper.test(zip) }
    }

    @Test func spannedZipWithoutItsLastPart() throws {
        let t = TempDir()
        _ = try Self.split(t, .zip)
        try FileManager.default.removeItem(atPath: t.path + "/a.zip")
        #expect(Xipper.missingVolume(of: t.url("a.z01")) == t.path + "/a.zip")
    }

    @Test(arguments: [ArchiveFormat.sevenZip, .zip])
    func numberedPiecesNameTheGap(_ format: ArchiveFormat) throws {
        let t = TempDir()
        _ = try Self.split(t, format, style: .numbered)
        let first = t.path + "/a.\(format.fileExtension).001"
        #expect(FileManager.default.fileExists(atPath: first))
        try FileManager.default.removeItem(atPath: t.path + "/a.\(format.fileExtension).002")
        #expect(Xipper.missingVolume(of: URL(fileURLWithPath: first)) == t.path + "/a.\(format.fileExtension).002")
    }
}
