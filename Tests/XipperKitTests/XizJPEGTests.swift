import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import XipperKit

/// XIZ 1.6 (spec §16): JPEG files recompressed with brunsli, one per frame, rebuilt byte for byte.
@Suite("XIZ JPEG recompression")
struct XizJPEGTests {
    /// A photo-like JPEG: gradients and noise, baseline or progressive.
    static func jpeg(width: Int = 640, height: Int = 480, seed: UInt64 = 1, progressive: Bool = false, quality: Double = 0.85) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var x = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        for y in 0..<height {
            for c in 0..<width {
                x ^= x << 13; x ^= x >> 7; x ^= x << 17
                let i = (y * width + c) * 4
                pixels[i] = UInt8((c * 255 / width + Int(x & 15)) & 255)
                pixels[i + 1] = UInt8((y * 255 / height + Int(x >> 8 & 15)) & 255)
                pixels[i + 2] = UInt8(((c + y) * 128 / (width + height) + Int(seed * 40)) & 255)
                pixels[i + 3] = 255
            }
        }
        let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = ctx.makeImage()!
        let data = NSMutableData()
        let dst = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality,
                                      kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: progressive]]
        CGImageDestinationAddImage(dst, image, props as CFDictionary)
        CGImageDestinationFinalize(dst)
        return [UInt8](data as Data)
    }

    func create(_ t: TempDir, jpeg: Bool, password: String? = nil) throws -> URL {
        var o = CreateOptions()
        o.format = .xiz
        o.xizJPEG = jpeg
        o.password = password
        try Xipper.create(from: [t.url("src")], to: t.url("a.xiz"), options: o)
        return t.url("a.xiz")
    }

    func corpus(_ t: TempDir) {
        t.write("src/photo.jpg", Self.jpeg(seed: 1))
        t.write("src/progressive.JPEG", Self.jpeg(seed: 2, progressive: true))
        t.write("src/copy.jpg", Self.jpeg(seed: 1))  // identical to photo.jpg
        t.write("src/notes.txt", sampleData(200_000))
        t.write("src/fake.jpg", sampleData(50_000))  // a .jpg that is not a JPEG
        var truncated = Self.jpeg(seed: 3)
        truncated.removeLast(truncated.count / 3)
        t.write("src/truncated.jpg", truncated)
    }

    func extracted(_ t: TempDir, _ archive: URL, password: String? = nil) throws -> [String: [UInt8]] {
        let dest = t.url("out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var o = ExtractOptions()
        o.password = password
        _ = try Xipper.extract(archive, to: dest, mode: .into, options: o)
        var out: [String: [UInt8]] = [:]
        for f in try FileManager.default.subpathsOfDirectory(atPath: dest.path + "/src") {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dest.path + "/src/" + f, isDirectory: &isDir), !isDir.boolValue {
                out[f] = try [UInt8](Data(contentsOf: URL(fileURLWithPath: dest.path + "/src/" + f)))
            }
        }
        return out
    }

    func original(_ t: TempDir) throws -> [String: [UInt8]] {
        var out: [String: [UInt8]] = [:]
        for f in try FileManager.default.contentsOfDirectory(atPath: t.path + "/src") {
            out[f] = try [UInt8](Data(contentsOf: t.url("src/" + f)))
        }
        return out
    }

    @Test func helperIsUsed() {
        #expect(JPEGCoderPool.shared != nil)
    }

    @Test func roundTripAndLayout() throws {
        let t = TempDir()
        corpus(t)
        let a = try create(t, jpeg: true)
        let x = try XizArchive(path: a.path)
        #expect(x.superblock.required.contains(.jpeg) && x.superblock.minor == 6)
        // photo.jpg and progressive.JPEG: one brunsli frame each (copy.jpg is deduplicated);
        // fake.jpg and truncated.jpg are stored the usual way.
        #expect(x.catalog.frames.filter { $0.codec == .jpeg }.count == 2)
        #expect(try Xipper.test(a).isOK)
        #expect(try extracted(t, a) == original(t))
        let t2 = TempDir()
        corpus(t2)
        #expect(try !XizArchive(path: try create(t2, jpeg: false).path).superblock.required.contains(.jpeg))
        // About 20% smaller than the JPEG.
        let photo = try #require(x.catalog.frames.first { $0.codec == .jpeg })
        #expect(Double(photo.csize) < Double(photo.usize) * 0.9)
    }

    @Test func readEntryAndEncrypted() throws {
        let t = TempDir()
        corpus(t)
        let a = try create(t, jpeg: true, password: "segreto")
        #expect(try Xipper.test(a, password: "segreto").isOK)
        #expect(try extracted(t, a, password: "segreto") == original(t))
        #expect(try Xipper.readEntry(a, path: "src/progressive.JPEG", password: "segreto", maxBytes: 1 << 20).data == original(t)["progressive.JPEG"])
    }

    @Test func editKeepsJPEGFrames() throws {
        let t = TempDir()
        corpus(t)
        let a = try create(t, jpeg: true)
        t.write("more.jpg", Self.jpeg(seed: 7))
        try Xipper.edit(a, changes: [.add(t.url("more.jpg"), as: "src/more.jpg")])
        let x = try XizArchive(path: a.path)
        #expect(x.catalog.frames.filter { $0.codec == .jpeg }.count == 3)
        #expect(try Xipper.readEntry(a, path: "src/more.jpg", maxBytes: 1 << 20).data == Self.jpeg(seed: 7))
        #expect(try Xipper.test(a).isOK)
    }

    @Test func noJPEGNoFeature() throws {
        let t = TempDir()
        t.write("src/notes.txt", sampleData(10_000))
        t.write("src/fake.jpg", sampleData(10_000))
        let a = try create(t, jpeg: true)
        #expect(try !XizArchive(path: a.path).superblock.required.contains(.jpeg))
    }

    /// Hostile brunsli streams and JPEGs reach the helper: errors or other bytes, never a crash or a hang here.
    @Test func hostileStreamsAreErrors() throws {
        let jpeg = Self.jpeg(seed: 4)
        let packed = try #require(JPEGRecompression.encode(jpeg))
        #expect(try JPEGRecompression.decode(packed, size: jpeg.count) == jpeg)
        #expect(throws: (any Error).self) { _ = try JPEGRecompression.decode(packed, size: jpeg.count - 1) }
        var rng = SystemRandomNumberGenerator()
        for k in 0..<300 {
            var p = packed
            if k % 3 == 0 {
                p.removeLast(Int.random(in: 1..<p.count, using: &rng))
            } else {
                for _ in 0..<Int.random(in: 1...8, using: &rng) { p[Int.random(in: 0..<p.count, using: &rng)] ^= UInt8.random(in: 1...255, using: &rng) }
            }
            if let out = try? JPEGRecompression.decode(p, size: jpeg.count) { #expect(out.count == jpeg.count) }
            var j = jpeg
            for _ in 0..<4 { j[Int.random(in: 2..<j.count, using: &rng)] ^= UInt8.random(in: 1...255, using: &rng) }
            if let q = JPEGRecompression.encode(j) { #expect(try JPEGRecompression.decode(q, size: j.count) == j) }
        }
    }
}
