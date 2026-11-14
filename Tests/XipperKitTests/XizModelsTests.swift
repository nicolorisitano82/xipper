import Foundation
import Testing
@testable import XipperKit

/// XIZ 1.11 (§21): AI model weights in OpenZL frames, tensor by tensor, rebuilt byte for byte.
@Suite("XIZ AI model weights (OpenZL)")
struct XizModelsTests {
    /// Weights like a trained layer's: normal values around zero, as float32.
    static func weights32(_ count: Int, seed: UInt64) -> [UInt8] {
        var x = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        var out = [UInt8]()
        out.reserveCapacity(count * 4)
        for _ in 0..<count {
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            let u1 = Double(x >> 11) / Double(1 << 53) + 1e-12
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            let u2 = Double(x >> 11) / Double(1 << 53)
            let v = Float(sqrt(-2 * log(u1)) * cos(2 * .pi * u2) * 0.02)
            withUnsafeBytes(of: v.bitPattern.littleEndian) { out.append(contentsOf: $0) }
        }
        return out
    }

    /// The same values as bfloat16 (the top half of each float32).
    static func weights16(_ count: Int, seed: UInt64) -> [UInt8] {
        let f = weights32(count, seed: seed)
        var out = [UInt8]()
        for i in stride(from: 0, to: f.count, by: 4) { out.append(f[i + 2]); out.append(f[i + 3]) }
        return out
    }

    /// A safetensors file: u64 header length, JSON header, tensors (float32, bfloat16, int64).
    static func safetensors(_ tensors: [(String, String, [UInt8])], metadata: Bool = true) -> [UInt8] {
        var header: [String: Any] = metadata ? ["__metadata__": ["format": "pt"]] : [:]
        var offset = 0
        for (name, dtype, data) in tensors {
            header[name] = ["dtype": dtype, "shape": [data.count], "data_offsets": [offset, offset + data.count]]
            offset += data.count
        }
        var json = try! JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        while json.count % 8 != 0 { json.append(0x20) }
        var out = [UInt8]()
        withUnsafeBytes(of: UInt64(json.count).littleEndian) { out.append(contentsOf: $0) }
        out += json
        for t in tensors { out += t.2 }
        return out
    }

    /// A `torch.save`-like zip: stored entries and a central directory. As torch writes them, the
    /// local headers have no sizes and a data descriptor follows each entry (flags 0x808);
    /// `descriptors: false` puts the sizes in the local headers, `zip64` in a ZIP64 extra there.
    static func torchZip(_ entries: [(String, [UInt8])], descriptors: Bool = true, zip64: Bool = false) -> [UInt8] {
        var out = [UInt8](), central = [UInt8]()
        func u16(_ v: Int, _ b: inout [UInt8]) { b += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func u32(_ v: Int, _ b: inout [UInt8]) { u16(v & 0xFFFF, &b); u16(v >> 16 & 0xFFFF, &b) }
        func u64(_ v: Int, _ b: inout [UInt8]) { u32(v & 0xFFFF_FFFF, &b); u32(v >> 32, &b) }
        for (name, data) in entries {
            let offset = out.count
            let crc = Int(data.withUnsafeBytes { CRC32.checksum($0) })
            var extra = [UInt8]()
            if zip64 { u16(1, &extra); u16(16, &extra); u64(data.count, &extra); u64(data.count, &extra) }
            let flags = descriptors ? 0x808 : 0
            u32(0x0403_4B50, &out); u16(45, &out); u16(flags, &out); u16(0, &out); u16(0, &out); u16(0, &out)
            u32(descriptors ? 0 : crc, &out)
            let local = descriptors ? 0 : zip64 ? 0xFFFF_FFFF : data.count
            u32(local, &out); u32(local, &out)
            u16(name.utf8.count, &out); u16(extra.count, &out)
            out += Array(name.utf8) + extra + data
            if descriptors { u32(0x0807_4B50, &out); u32(crc, &out); u32(data.count, &out); u32(data.count, &out) }
            u32(0x0201_4B50, &central); u16(45, &central); u16(45, &central); u16(flags, &central); u16(0, &central)
            u16(0, &central); u16(0, &central); u32(crc, &central); u32(data.count, &central); u32(data.count, &central)
            u16(name.utf8.count, &central); u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central)
            u32(0, &central); u32(offset, &central); central += Array(name.utf8)
        }
        let cdOffset = out.count
        out += central
        u32(0x0605_4B50, &out); u16(0, &out); u16(0, &out); u16(entries.count, &out); u16(entries.count, &out)
        u32(central.count, &out); u32(cdOffset, &out); u16(0, &out)
        return out
    }

    func create(_ t: TempDir, models: Bool, lzma2: Bool = false, password: String? = nil) throws -> URL {
        var o = CreateOptions()
        o.format = .xiz
        o.xizModels = models
        o.password = password
        if lzma2 { o.xizCodec = .lzma2 }
        let out = t.url("m-\(UUID().uuidString).xiz")
        try Xipper.create(from: [t.url("src")], to: out, options: o)
        return out
    }

    func roundTrip(_ t: TempDir, _ archive: URL, password: String? = nil) throws {
        let dest = t.url("x-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var o = ExtractOptions()
        o.password = password
        _ = try Xipper.extract(archive, to: dest, mode: .into, options: o)
        let (same, diff) = treesEqual(t.path + "/src", dest.path + "/src")
        #expect(same, "\(diff)")
    }

    func corpus(_ t: TempDir) {
        t.write("src/model.safetensors", Self.safetensors([
            ("layer.0.weight", "F32", Self.weights32(300_000, seed: 1)),
            ("layer.1.weight", "BF16", Self.weights16(500_000, seed: 2)),
            ("position_ids", "I64", [UInt8](repeating: 0, count: 8000)),
        ]))
        t.write("src/model.pt", Self.torchZip([
            ("archive/data.pkl", Array("pickled structure, not executed".utf8)),
            ("archive/data/0", Self.weights32(400_000, seed: 3)),
            ("archive/data/1", Self.weights16(300_000, seed: 4)),
            ("archive/version", Array("3\n".utf8)),
        ]))
        t.write("src/notes.txt", sampleData(100_000))
        t.write("src/fake.bin", sampleData(2 << 20))  // .bin that is not a model
    }

    @Test func piecesFollowTheTensors() throws {
        let t = TempDir()
        corpus(t)
        let st = t.path + "/src/model.safetensors"
        let size = Int64(try FileManager.default.attributesOfItem(atPath: st)[.size] as! Int)
        let p = try #require(try ModelRecompression.pieces(name: "model.safetensors", path: st, size: size))
        #expect(p.first?.range.lowerBound == 0 && p.last?.range.upperBound == size)
        for (a, b) in zip(p, p.dropFirst()) { #expect(a.range.upperBound == b.range.lowerBound) }
        #expect(p.filter { $0.floats == [.float32] }.count == 1 && p.filter { $0.floats == [.bfloat16] }.count == 1)
        #expect(p.allSatisfy { $0.floats.isEmpty || $0.range.count % Int($0.floats[0].width) == 0 })
        let pt = t.path + "/src/model.pt"
        let ptSize = Int64(try FileManager.default.attributesOfItem(atPath: pt)[.size] as! Int)
        let q = try #require(try ModelRecompression.pieces(name: "model.pt", path: pt, size: ptSize))
        #expect(q.filter { !$0.floats.isEmpty }.count == 2)
        #expect(try ModelRecompression.pieces(name: "fake.bin", path: t.path + "/src/fake.bin", size: 2 << 20) == nil)
    }

    @Test func modelsAreSmallerAndRebuilt() throws {
        let t = TempDir()
        corpus(t)
        let plain = try create(t, models: false)
        let models = try create(t, models: true)
        let a = try XizArchive(path: models.path)
        #expect(a.superblock.required.contains(.tables))
        #expect(a.catalog.frames.filter { $0.codec == .openzl }.count == 4, "\(a.catalog.frames.map(\.codec))")
        let sp = try FileManager.default.attributesOfItem(atPath: plain.path)[.size] as! Int
        let sm = try FileManager.default.attributesOfItem(atPath: models.path)[.size] as! Int
        #expect(sm * 100 < sp * 95, "\(sm) vs \(sp)")
        try roundTrip(t, models)
        #expect(try Xipper.test(models).isOK)
    }

    @Test func zip64AndEncryptedAndLZMA2() throws {
        let t = TempDir()
        t.write("src/big.pth", Self.torchZip([("model/data/0", Self.weights32(600_000, seed: 5)), ("model/data.pkl", [1, 2, 3])],
                                             descriptors: false, zip64: true))
        let pt = t.path + "/src/big.pth"
        let size = Int64(try FileManager.default.attributesOfItem(atPath: pt)[.size] as! Int)
        #expect(try ModelRecompression.pieces(name: "big.pth", path: pt, size: size)?.contains { !$0.floats.isEmpty } == true)
        let a = try create(t, models: true, lzma2: true, password: "segreto")
        #expect(try XizArchive(path: a.path, password: "segreto").catalog.frames.contains { $0.codec == .openzl })
        try roundTrip(t, a, password: "segreto")
    }

    @Test func brokenModelsAreStoredAsUsual() throws {
        let t = TempDir()
        var bad = Self.safetensors([("w", "F32", Self.weights32(300_000, seed: 6))])
        bad[0] = 0xFF; bad[7] = 0x7F  // header length beyond the file
        t.write("src/a.safetensors", bad)
        var outOfRange = Self.safetensors([("w", "F32", Self.weights32(300_000, seed: 7))])
        outOfRange.removeLast(1000)  // offsets beyond the end
        t.write("src/b.safetensors", outOfRange)
        var truncated = Self.torchZip([("m/data/0", Self.weights32(300_000, seed: 8))])
        truncated.removeLast(5000)  // cut inside the tensor: neither its end nor a central directory
        t.write("src/c.pt", truncated)
        for n in ["a.safetensors", "b.safetensors", "c.pt"] {
            let p = t.path + "/src/" + n
            let size = Int64(try FileManager.default.attributesOfItem(atPath: p)[.size] as! Int)
            #expect(try ModelRecompression.pieces(name: n, path: p, size: size) == nil, "\(n)")
        }
        let a = try create(t, models: true)
        #expect(!(try XizArchive(path: a.path).superblock.required.contains(.tables)))
        try roundTrip(t, a)
    }

    /// Weights that do not compress (random bytes in a valid safetensors file): the usual codec.
    @Test func incompressibleTensorsKeepTheUsualCodec() throws {
        let t = TempDir()
        t.write("src/r.safetensors", Self.safetensors([("w", "F32", sampleData(3 << 20, seed: 9))]))
        let a = try create(t, models: true)
        #expect(!(try XizArchive(path: a.path).catalog.frames.contains { $0.codec == .openzl }))
        try roundTrip(t, a)
    }
}
