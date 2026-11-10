import CoreGraphics
import CXipShims
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import XipperKit

/// XIZ 1.9 (§19): PNG, PDF and ZIP-based documents with their Deflate streams split by preflate.
@Suite("XIZ document recompression")
struct XizDocumentsTests {
    /// A PNG with photo-like content (ImageIO writes zlib streams).
    static func png(seed: UInt64 = 1, width: Int = 400, height: Int = 300) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var x = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        for i in stride(from: 0, to: pixels.count, by: 4) {
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            let p = i / 4
            pixels[i] = UInt8((p % width * 255 / width + Int(x & 7)) & 255)
            pixels[i + 1] = UInt8((p / width * 255 / height) & 255)
            pixels[i + 2] = UInt8(Int(seed * 50) & 255)
            pixels[i + 3] = 255
        }
        let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let data = NSMutableData()
        let dst = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dst)
        return [UInt8](data as Data)
    }

    /// Text that reads like prose: words drawn from a small vocabulary, so Deflate leaves room.
    static func prose(_ words: Int, seed: UInt64) -> String {
        let vocabulary = ["archivio", "flusso", "Xipper", "documento", "pagina", "immagine", "dati", "ricostruzione", "byte",
                          "identico", "compressione", "Deflate", "tabella", "cartella", "file", "versione", "testo", "riga",
                          "numero", "valore", "colonna", "rapporto", "misura", "sistema", "chiave", "firma", "frame"]
        var x = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        return (0..<words).map { _ in
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            return vocabulary[Int(x % UInt64(vocabulary.count))] + (x % 9 == 0 ? " \(x % 10_000)," : "")
        }.joined(separator: " ")
    }

    /// A PDF whose content streams are zlib streams (FlateDecode), as most PDF writers make them.
    static func pdf(pages: Int = 6) -> [UInt8] {
        var out = Array("%PDF-1.4\n".utf8)
        for p in 0..<pages {
            let text = (0..<70).map { "BT /F1 10 Tf 40 \(800 - $0 * 11) Td (\(prose(12, seed: UInt64(p * 100 + $0)))) Tj ET" }
                .joined(separator: "\n")
            let raw = Array(text.utf8)
            var deflated = [UInt8](repeating: 0, count: xs_deflate_chunk_bound(raw.count))  // system zlib, level 6
            deflated.removeLast(deflated.count - xs_deflate_chunk(raw, raw.count, nil, 0, 6, 1, &deflated, deflated.count))
            var a: UInt32 = 1, b: UInt32 = 0
            for x in raw { a = (a + UInt32(x)) % 65521; b = (b + a) % 65521 }
            let adler = b << 16 | a
            let stream = [0x78, 0x9C] + deflated + [UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)]
            out += Array("\(p + 1) 0 obj\n<< /Length \(stream.count) /Filter /FlateDecode >>\nstream\n".utf8) + stream + Array("\nendstream\nendobj\n".utf8)
        }
        return out + Array("trailer\n<< >>\n%%EOF\n".utf8)
    }

    /// A DOCX-like ZIP made by Info-ZIP (zlib), like most Office files.
    static func docx(_ t: TempDir, name: String) throws -> URL {
        for i in 0..<4 {
            let xml = (0..<400).map { "<w:p><w:r><w:t>\(prose(15, seed: UInt64(i * 1000 + $0)))</w:t></w:r></w:p>" }.joined()
            t.write("parts-\(name)/word/part\(i).xml", "<?xml version=\"1.0\"?><w:document>\(xml)</w:document>")
        }
        let out = t.url(name)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = t.url("parts-\(name)")
        zip.arguments = ["-q", "-r", out.path, "word"]
        try zip.run()
        zip.waitUntilExit()
        return out
    }

    func corpus(_ t: TempDir) throws {
        t.write("src/image.png", Self.png(seed: 1))
        t.write("src/copy.png", Self.png(seed: 1))
        t.write("src/report.pdf", Self.pdf())
        try FileManager.default.moveItem(at: try Self.docx(t, name: "letter.docx"), to: t.url("src/letter.docx"))
        t.write("src/notes.txt", String(repeating: "note\n", count: 5000))
        t.write("src/fake.pdf", "%PDF-1.4 but not really a PDF " + String(repeating: "x", count: 8000))
    }

    func create(_ t: TempDir, documents: Bool, password: String? = nil, level: Int = 12) throws -> URL {
        var o = CreateOptions()
        o.format = .xiz
        o.level = level
        o.xizDocuments = documents
        o.password = password
        o.xizKDF = .minimum
        let a = t.url("a\(documents ? "d" : "")\(level).xiz")
        _ = try Xipper.create(from: [t.url("src")], to: a, options: o)
        return a
    }

    func extracted(_ t: TempDir, _ a: URL, password: String? = nil) throws -> Bool {
        let out = t.url("out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var x = ExtractOptions()
        x.password = password
        _ = try Xipper.extract(a, to: out, mode: .into, options: x)
        return treesEqual(t.path + "/src", out.path + "/src").0
    }

    @Test func splitFormsRebuildExactly() throws {
        let t = TempDir()
        for (name, file) in [("a.png", Self.png(seed: 3)), ("b.pdf", Self.pdf(pages: 2)), ("c.docx", Array(try Data(contentsOf: try Self.docx(t, name: "c.docx"))))] {
            let split = try #require(DeflateRecompression.splitInProcess(file, name: name), "\(name)")
            #expect(try DeflateRecompression.rebuild(split, size: file.count) == file)
            #expect(throws: XipperError.self) { _ = try DeflateRecompression.rebuild(split, size: file.count - 1) }
        }
        #expect(DeflateRecompression.splitInProcess(Array("%PDF-1.4 nothing".utf8) + [UInt8](repeating: 1, count: 5000), name: "x.pdf") == nil)
    }

    @Test(arguments: [3, 12])
    func archivesRoundTrip(level: Int) throws {
        let t = TempDir()
        try corpus(t)
        let a = try create(t, documents: true, level: level)
        let x = try XizArchive(path: a.path)
        #expect(x.superblock.required.contains(.deflate) && x.superblock.minor == 9)
        // image.png, report.pdf, letter.docx: one frame each (copy.png is deduplicated); fake.pdf stays ordinary.
        // At zstd 3 the document gains less than 3% and goes into an ordinary frame.
        #expect(x.catalog.frames.filter { $0.codec == .preflate }.count == (level >= 12 ? 3 : 2))
        #expect(try Xipper.test(a).isOK)
        #expect(try extracted(t, a))
        let plain = try create(t, documents: false, level: level)
        #expect(try !XizArchive(path: plain.path).superblock.required.contains(.deflate))
        #expect(try FileReader(path: a.path).size < FileReader(path: plain.path).size)
    }

    @Test func encryptedAndEdited() throws {
        let t = TempDir()
        try corpus(t)
        let a = try create(t, documents: true, password: "segreto")
        #expect(try extracted(t, a, password: "segreto"))
        t.write("more.png", Self.png(seed: 9))
        try Xipper.edit(a, changes: [.add(t.url("more.png"), as: "src/more.png")], password: "segreto")
        #expect(try Xipper.readEntry(a, path: "src/more.png", password: "segreto", maxBytes: 4 << 20).data == Self.png(seed: 9))
        #expect(try Xipper.test(a, password: "segreto").isOK)
    }

    /// Damaged split forms reach preflate in the helper: errors, never a crash or other bytes.
    @Test func hostileSplitForms() throws {
        let file = Self.pdf(pages: 2)
        let split = try #require(DeflateRecompression.splitInProcess(file, name: "a.pdf"))
        var rng = SystemRandomNumberGenerator()
        for k in 0..<200 {
            var s = split
            if k % 4 == 0 { s.removeLast(Int.random(in: 1..<(s.count - 8), using: &rng)) } else {
                for _ in 0..<(1 + k % 6) { s[Int.random(in: 4..<s.count, using: &rng)] ^= UInt8.random(in: 1...255, using: &rng) }
            }
            if let out = try? DeflateRecompression.rebuildChecked(s, size: file.count) { #expect(out.count == file.count) }
        }
        // A payload whose split size lies is refused before anything is allocated.
        #expect(throws: XipperError.self) { _ = try DeflateRecompression.decode([1, 0xFF, 0xFF, 0xFF, 0x7F, 0, 0], size: 10) }
    }
}
