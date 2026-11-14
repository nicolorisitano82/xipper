import Foundation
import Testing
@testable import XipperKit

/// One delimited file as people really write them, good or bad.
struct TableDialect: CustomTestStringConvertible, Sendable {
    var name: String
    var file: String
    var bytes: @Sendable () -> [UInt8]
    var testDescription: String { name }

    static func rows(_ n: Int, _ f: (Int) -> String) -> [UInt8] {
        var s = ""
        s.reserveCapacity(n * 40)
        for i in 0..<n { s += f(i) }
        return Array(s.utf8)
    }

    static let all: [TableDialect] = [
        TableDialect(name: "crlf", file: "crlf.csv") { rows(20_000) { "\($0),\($0 * 7 % 1000),val\($0 % 9)\r\n" } },
        TableDialect(name: "quotes-and-newlines", file: "quoted.csv") {
            Array("id,text,n\n".utf8) + rows(15_000) { i in "\(i),\"a, \"\"quoted\"\" text\(i % 5 == 0 ? "\nwith a newline" : "")\",\(i % 77)\n" }
        },
        TableDialect(name: "empty-fields", file: "empty.csv") { rows(20_000) { i in "\(i),,\(i % 3 == 0 ? "" : "x"),,\n" } },
        TableDialect(name: "unicode", file: "unicode.csv") { rows(15_000) { i in "\(i),città è perché ✓,日本語\(i % 10),🙂\n" } },
        TableDialect(name: "ragged-rows", file: "ragged.csv") { rows(20_000) { i in i % 25 == 0 ? "\(i),short\n" : "\(i),a,b,c,\(i % 13)\n" } },
        TableDialect(name: "no-final-newline", file: "nofinal.csv") { var b = rows(20_000) { "\($0),\($0 % 11)\n" }; b.removeLast(); return b },
        TableDialect(name: "bom", file: "bom.csv") { [0xEF, 0xBB, 0xBF] + rows(20_000) { "\($0);\($0 % 11);ok\n" } },
        TableDialect(name: "wide-200-columns", file: "wide.csv") { rows(800) { i in (0..<200).map { String(i * $0 % 997) }.joined(separator: ",") + "\n" } },
        TableDialect(name: "huge-cell", file: "hugecell.csv") {
            Array("id,blob\n1,".utf8) + sampleData(1 << 20, seed: 3).map { 0x41 + $0 % 26 } + rows(5_000) { "\n\($0 + 2),x" } + [0x0A]
        },
        TableDialect(name: "numbers-of-every-shape", file: "numbers.csv") {
            rows(20_000) { i in "\(i),-\(i * 31 % 1000).\(i % 100),\(Double(i) * 1.5e-7),00\(i % 1000),0x\(String(i, radix: 16)),1e\(i % 30)\n" }
        },
        TableDialect(name: "european-semicolon", file: "euro.csv") { rows(20_000) { i in "\(i);\(i % 100),\(i % 7);EUR\n" } },
        TableDialect(name: "pipe", file: "data.psv") { rows(20_000) { i in "\(i)|\(i % 17)|row\(i % 5)\n" } },
        TableDialect(name: "bed-with-track-lines", file: "peaks.bed") {
            Array("track name=peaks\nbrowser position chr1:1-1000\n".utf8) + rows(20_000) { i in "chr\(i / 5000 + 1)\t\(i * 300)\t\(i * 300 + 150)\tp\(i)\t\(i % 1000)\t+\n" }
        },
        TableDialect(name: "vcf-like-tsv", file: "calls.tsv") {
            Array("##fileformat=VCFv4.2\n##source=test\n#CHROM\tPOS\tID\tREF\tALT\n".utf8) + rows(20_000) { i in "chr1\t\(i * 50)\trs\(i)\tA\tG\n" }
        },
        TableDialect(name: "line-longer-than-the-cut-margin", file: "longline.csv") {
            // Rows of 1.5 MiB around the 16 MiB cut: the piece is cut inside a row.
            var b = rows(400_000) { "\($0),\($0 % 101)\n" }
            for _ in 0..<3 { b += Array("x,".utf8) + [UInt8](repeating: 0x7A, count: 3 << 19) + [0x0A] }
            b += rows(100_000) { "\($0),\($0 % 7)\n" }
            return b
        },
        TableDialect(name: "exactly-one-piece", file: "exact.csv") {
            var b = rows(1_200_000) { "\($0 % 100000),\($0 % 9)\n" }
            if b.count > TableRecompression.pieceSize { b.removeLast(b.count - TableRecompression.pieceSize) }
            else { b += [UInt8](repeating: 0x0A, count: TableRecompression.pieceSize - b.count) }
            return b
        },
        TableDialect(name: "control-characters", file: "control.csv") { rows(20_000) { i in "\(i),\u{1}\u{7}\u{1B}[0m,\(i % 9)\n" } },
        TableDialect(name: "prose-named-csv", file: "prose.csv") { rows(5_000) { "Questa è una frase qualunque, numero \($0), senza colonne vere.\n" } },
    ]
}

@Suite("Exhaustive: OpenZL tables", .enabled(if: Exhaustive.enabled))
struct ExhaustiveTablesTests {
    @Test(arguments: TableDialect.all)
    func dialectRoundTrips(_ d: TableDialect) throws {
        let t = TempDir()
        let data = d.bytes()
        t.write("src/\(d.file)", data)
        t.write("src/other.txt", sampleData(70_000))
        for codec in [XizCodec.zstd, .lzma2] {
            var o = CreateOptions()
            o.format = .xiz
            o.xizTables = true
            o.xizCodec = codec
            let archive = t.url("\(d.name)-\(codec.rawValue).xiz")
            try Xipper.create(from: [t.url("src")], to: archive, options: o)
            #expect(try Xipper.test(archive).isOK, "\(d.name) \(codec)")
            let dest = t.url("x-\(codec.rawValue)")
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            _ = try Xipper.extract(archive, to: dest, mode: .into, options: ExtractOptions())
            #expect(FileManager.default.contents(atPath: dest.path + "/src/" + d.file) == Data(data), "\(d.name) \(codec): content")
            if codec == .zstd, let out = Exhaustive.outDir {
                let base = out + "/tables-" + d.name
                try? FileManager.default.removeItem(atPath: base + ".xiz")
                try? FileManager.default.removeItem(atPath: base + ".expected")
                try FileManager.default.copyItem(atPath: archive.path, toPath: base + ".xiz")
                try FileManager.default.copyItem(atPath: t.path + "/src", toPath: base + ".expected")
                try "password=0\nsigned=0\napple=0\n".write(toFile: base + ".case", atomically: true, encoding: .utf8)
            }
        }
    }

    @Test func piecesAlwaysCoverTheFileInOrder() throws {
        let t = TempDir()
        for d in TableDialect.all {
            let data = d.bytes()
            let path = t.write(d.file, data)
            let pieces = try TableRecompression.pieces(path: path, size: Int64(data.count))
            #expect(pieces.first?.lowerBound == 0 && pieces.last?.upperBound == Int64(data.count), "\(d.name)")
            for (a, b) in zip(pieces, pieces.dropFirst()) { #expect(a.upperBound == b.lowerBound && !a.isEmpty, "\(d.name)") }
            #expect(pieces.allSatisfy { $0.count <= TableRecompression.pieceSize }, "\(d.name)")
        }
    }

    /// Thousands of damaged frames: an error, or (rarely) the right size; never a crash or a hang.
    @Test func mutatedFramesNeverCrash() throws {
        let iterations = Int(ProcessInfo.processInfo.environment["XIPPER_FUZZ_ITERATIONS"] ?? "") ?? 3000
        var x: UInt64 = 0x5EED
        func r() -> UInt64 { x ^= x << 13; x ^= x >> 7; x ^= x << 17; return x }
        for d in TableDialect.all.prefix(8) {
            let piece = d.bytes()
            guard piece.count <= TableRecompression.pieceSize,
                  let sep = TableRecompression.separator(in: Array(piece.prefix(64 << 10)), declared: 0),
                  let frame = TableRecompression.encode(piece, separator: sep, header: true, level: 15) else { continue }
            for k in 0..<(iterations / 8) {
                var bad = frame
                switch k % 4 {
                case 0: bad[Int(r() % UInt64(bad.count))] ^= UInt8(truncatingIfNeeded: r()) | 1
                case 1: for _ in 0..<8 { bad[Int(r() % UInt64(bad.count))] = UInt8(truncatingIfNeeded: r()) }
                case 2: bad.removeLast(Int(r() % UInt64(bad.count)))
                default:
                    let at = Int(r() % UInt64(bad.count))
                    bad.insert(contentsOf: (0..<16).map { _ in UInt8(truncatingIfNeeded: r()) }, at: at)
                }
                if let out = try? TableRecompression.decode(bad, size: piece.count) { #expect(out.count == piece.count) }
            }
        }
    }
}

@Suite("Exhaustive: forensic archives in Xipper", .enabled(if: Exhaustive.enabled))
struct ExhaustiveForensicInXipperTests {
    static let examiner = XizSigner(key: XizSigningKey(), label: "Esaminatore")

    func image(_ t: TempDir) -> (String, [UInt8]) {
        var d = sampleData(XizForensic.blockSize + 12_345, seed: 9)
        d += [UInt8](repeating: 0, count: XizForensic.blockSize)
        return (t.write("disk.img", d), d)
    }

    @Test(arguments: [nil, "segreto"] as [String?])
    func imageWithManyHandOvers(_ password: String?) throws {
        let t = TempDir()
        let (src, data) = image(t)
        let out = t.path + "/r.xiz"
        var o = XizForensic.ImageOptions()
        o.caseInfo = ["case_number": "2026-900", "evidence_number": "R07", "description": "chiavetta"]
        o.password = password
        o.unreadable = [XizForensic.Unreadable.Range(offset: 8192, length: 4096)]
        _ = try XizForensic.acquireImage(from: src, to: out, options: o, signer: Self.examiner)
        let people = ["Esaminatore", "Corriere", "Laboratorio", "Perito", "Cancelleria", "Tribunale", "Archivio", "Perito di parte", "Corriere 2", "Deposito", "Tribunale"]
        for (a, b) in zip(people, people.dropFirst()) {
            try XizForensic.appendCustody(to: out, custody: ["from": a, "to": b], signer: XizSigner(key: XizSigningKey(), label: a))
        }
        let url = URL(fileURLWithPath: out)
        // What the inspector shows.
        let s = try #require(try XizForensic.summary(out))
        #expect(s.caseNumber == "2026-900" && s.evidenceNumber == "R07" && s.description == "chiavetta")
        #expect(s.handOvers.count == 10 && s.handOvers.map(\.segment) == Array(1...10) && s.handOvers.last?.to == "Tribunale")
        #expect(s.unreadableBytes == 4096 && s.sources.count == 1 && s.sources[0].size == UInt64(data.count))
        // Signed history: 11 segments, chained.
        let h = try Xipper.xizHistory(url)
        #expect(h.count == 11 && h.allSatisfy { $0.valid && $0.chained })
        // Read like any XIZ.
        #expect(try Xipper.test(url, password: password).isOK)
        let dest = t.url("x")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var eo = ExtractOptions()
        eo.password = password
        _ = try Xipper.extract(url, to: dest, mode: .into, options: eo)
        var expected = data
        expected.replaceSubrange(8192..<12288, with: [UInt8](repeating: 0, count: 4096))
        #expect(FileManager.default.contents(atPath: dest.path + "/image.dd") == Data(expected))
        // Never edited by Xipper, and still valid afterwards.
        t.write("extra.txt", "x")
        #expect(throws: XipperError.self) { try Xipper.edit(url, changes: [.add(t.url("extra.txt"), as: "extra.txt")], password: password) }
        #expect(throws: XipperError.self) { try Xipper.edit(url, changes: [.delete("image.dd")], password: password) }
        #expect(try XizForensic.verify(out, password: password).passed)
        // Converted to another format: the content stays, the forensic records come along as files.
        var co = CreateOptions()
        co.format = .zip
        _ = try Xipper.convert(url, to: t.url("r.zip"), password: password, options: co)
        #expect(try Xipper.test(t.url("r.zip")).isOK)
    }

    @Test func logicalAcquisitionReadByXipper() throws {
        let t = TempDir()
        makeTree(t, root: "case", bigSize: 5 << 20)
        let out = t.path + "/l.xiz"
        var o = XizForensic.LogicalOptions()
        o.caseInfo = ["case_number": "2026-901", "evidence_number": "R08"]
        _ = try XizForensic.acquireLogical([t.url("case")], to: out, options: o, signer: Self.examiner)
        let s = try #require(try XizForensic.summary(out))
        #expect(s.caseNumber == "2026-901" && s.handOvers.isEmpty)
        let dest = t.url("x")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        _ = try Xipper.extract(URL(fileURLWithPath: out), to: dest, mode: .into, options: ExtractOptions())
        let (same, diff) = treesEqual(t.path + "/case", dest.path + "/evidence/case")
        #expect(same, "\(diff)")
    }

    /// Damage in a forensic archive: Xipper's test refuses it, like the forensic verification.
    @Test func damageIsRefused() throws {
        let t = TempDir()
        let (src, _) = image(t)
        let out = t.path + "/d.xiz"
        _ = try XizForensic.acquireImage(from: src, to: out, options: XizForensic.ImageOptions(), signer: Self.examiner)
        let size = try FileManager.default.attributesOfItem(atPath: out)[.size] as! Int
        for offset in [1000, size / 3, size / 2, size - 200] {
            let copy = t.path + "/d\(offset).xiz"
            try FileManager.default.copyItem(atPath: out, toPath: copy)
            let h = try FileHandle(forUpdating: URL(fileURLWithPath: copy))
            try h.seek(toOffset: UInt64(offset))
            let b = try #require(try h.read(upToCount: 1))
            try h.seek(toOffset: UInt64(offset))
            try h.write(contentsOf: Data([b[0] ^ 0x40]))
            try h.close()
            #expect((try? Xipper.test(URL(fileURLWithPath: copy)))?.isOK != true, "offset \(offset)")
            #expect((try? XizForensic.verify(copy))?.passed != true, "offset \(offset)")
        }
    }
}
