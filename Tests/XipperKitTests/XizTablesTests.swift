import Foundation
import Testing
@testable import XipperKit

/// XIZ 1.11 (spec §21): delimited tables in OpenZL frames, pieces of whole rows, rebuilt byte for byte.
@Suite("XIZ tables (OpenZL)")
struct XizTablesTests {
    /// A sensor log: timestamps, ids, decimals, a status column, quoted text with commas.
    static func csv(rows: Int, seed: UInt64 = 1, separator: String = ",") -> [UInt8] {
        var x = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        func r() -> UInt64 { x ^= x << 13; x ^= x >> 7; x ^= x << 17; return x }
        var s = ["timestamp", "sensor", "temperature", "humidity", "status", "note"].joined(separator: separator) + "\n"
        s.reserveCapacity(rows * 60)
        for i in 0..<rows {
            let note = r() % 50 == 0 ? "\"check, valve \(r() % 9)\"" : ""
            s += "\(1_767_225_600 + i * 10)\(separator)S\(String(format: "%03d", i % 16))\(separator)"
            s += String(format: "%.2f", 20 + Double(r() % 500) / 100) + separator + String(format: "%.1f", 40 + Double(r() % 300) / 10)
            s += separator + (r() % 40 == 0 ? "WARN" : "OK") + separator + note + "\n"
        }
        return Array(s.utf8)
    }

    func create(_ t: TempDir, tables: Bool, password: String? = nil, lzma2: Bool = false) throws -> URL {
        var o = CreateOptions()
        o.format = .xiz
        o.xizTables = tables
        o.password = password
        if lzma2 { o.xizCodec = .lzma2 }
        let out = t.url("a-\(UUID().uuidString).xiz")
        try Xipper.create(from: [t.url("src")], to: out, options: o)
        return out
    }

    func roundTrip(_ t: TempDir, _ archive: URL, password: String? = nil) throws {
        let dest = t.url("out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var o = ExtractOptions()
        o.password = password
        _ = try Xipper.extract(archive, to: dest, mode: .into, options: o)
        for f in try FileManager.default.contentsOfDirectory(atPath: t.path + "/src") {
            #expect(FileManager.default.contents(atPath: dest.path + "/src/" + f) == FileManager.default.contents(atPath: t.path + "/src/" + f), "\(f)")
        }
    }

    func codecs(_ archive: URL, password: String? = nil) throws -> [Xiz.Codec] { try XizArchive(path: archive.path, password: password).catalog.frames.map(\.codec) }

    @Test func separatorIsSniffed() {
        #expect(TableRecompression.separator(in: Self.csv(rows: 50), declared: 0) == UInt8(ascii: ","))
        #expect(TableRecompression.separator(in: Self.csv(rows: 50, separator: ";"), declared: 0) == UInt8(ascii: ";"))
        #expect(TableRecompression.separator(in: Self.csv(rows: 50, separator: "\t"), declared: UInt8(ascii: "\t")) == UInt8(ascii: "\t"))
        #expect(TableRecompression.separator(in: Array("just some prose\nwith lines\nand no columns\n".utf8), declared: 0) == nil)
        #expect(TableRecompression.separator(in: [0x61, 0x2C, 0x00, 0x0A, 0x61, 0x2C, 0x0A], declared: 0) == nil)
    }

    @Test func tablesAreSmallerAndRebuilt() throws {
        let t = TempDir()
        t.write("src/sensors.csv", Self.csv(rows: 60_000))
        t.write("src/sensors.tsv", Self.csv(rows: 30_000, seed: 2, separator: "\t"))
        t.write("src/copy.csv", Self.csv(rows: 60_000))  // identical: stored once
        t.write("src/notes.txt", sampleData(200_000))
        t.write("src/fake.csv", sampleData(100_000))  // not a table
        let plain = try create(t, tables: false)
        let tables = try create(t, tables: true)
        #expect(try XizArchive(path: tables.path).superblock.required.contains(.tables))
        #expect(!(try XizArchive(path: plain.path).superblock.required.contains(.tables)))
        #expect(try codecs(tables).filter { $0 == .openzl }.count == 2)
        let a = try FileManager.default.attributesOfItem(atPath: plain.path)[.size] as! Int
        let b = try FileManager.default.attributesOfItem(atPath: tables.path)[.size] as! Int
        #expect(b * 10 < a * 8, "\(b) vs \(a)")
        try roundTrip(t, tables)
        #expect(try Xipper.test(tables).isOK)
    }

    @Test func bigTableIsCutAtRows() throws {
        let t = TempDir()
        let big = Self.csv(rows: 600_000, seed: 3)
        #expect(big.count > TableRecompression.pieceSize)
        t.write("src/big.csv", big)
        let pieces = try TableRecompression.pieces(path: t.path + "/src/big.csv", size: Int64(big.count))
        #expect(pieces.count == 2 && pieces[0].lowerBound == 0 && pieces.last!.upperBound == Int64(big.count))
        #expect(big[Int(pieces[0].upperBound) - 1] == UInt8(ascii: "\n"))
        let archive = try create(t, tables: true, password: "segreto", lzma2: true)
        #expect(try codecs(archive, password: "segreto").filter { $0 == .openzl }.count == 2)
        try roundTrip(t, archive, password: "segreto")
    }

    @Test func noTablesNoFeature() throws {
        let t = TempDir()
        t.write("src/a.txt", sampleData(100_000))
        t.write("src/small.csv", Self.csv(rows: 100))  // under the minimum
        let archive = try create(t, tables: true)
        #expect(!(try XizArchive(path: archive.path).superblock.required.contains(.tables)))
        try roundTrip(t, archive)
    }

    @Test func hostileFramesFailCleanly() throws {
        let piece = Self.csv(rows: 20_000)
        let frame = try #require(TableRecompression.encode(piece, separator: UInt8(ascii: ","), header: true, level: 15))
        #expect(try TableRecompression.decode(frame, size: piece.count) == piece)
        #expect(throws: XipperError.self) { _ = try TableRecompression.decode(frame, size: piece.count - 1) }
        #expect(throws: XipperError.self) { _ = try TableRecompression.decode(Array(frame.prefix(frame.count / 2)), size: piece.count) }
        var x: UInt64 = 7
        for k in 0..<300 {
            var bad = frame
            for _ in 0..<(1 + k % 4) {
                x ^= x << 13; x ^= x >> 7; x ^= x << 17
                let i = Int(x % UInt64(bad.count))
                bad[i] ^= UInt8(truncatingIfNeeded: x >> 32) | 1
            }
            // Either an error or, rarely, a decoding whose checksum still matches: never a crash.
            if let out = try? TableRecompression.decode(bad, size: piece.count) { #expect(out.count == piece.count) }
        }
        for n in [0, 1, 4, 16, 64] {
            var junk = [UInt8](repeating: 0, count: n)
            arc4random_buf(&junk, n)
            #expect(throws: XipperError.self) { _ = try TableRecompression.decode(junk, size: 1000) }
        }
    }
}
