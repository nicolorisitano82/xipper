import Foundation
import Testing
@testable import XipperKit

/// XIZ 1.8 (§18): frames compressed with Apple's LZRAVEN and LZMESH, macOS 27 only.
@Suite("XIZ Apple codecs", .enabled(if: XizCodec.appleCodecsAvailable))
struct XizAppleCodecsTests {
    func tree(_ t: TempDir) {
        for i in 0..<30 { t.write("src/t\(i).txt", String(repeating: "Xipper riga \(i) di testo ripetuto. ", count: 2_000)) }
        t.write("src/big.bin", sampleData(6 << 20, seed: 4))  // more than one frame
        t.write("src/random.bin", (0..<200_000).map { _ in UInt8.random(in: 0...255) })  // stored
    }

    @Test(arguments: [XizCodec.lzraven, .lzmesh])
    func roundTrip(_ codec: XizCodec) throws {
        let t = TempDir()
        tree(t)
        var o = CreateOptions()
        o.format = .xiz
        o.xizCodec = codec
        let a = t.url("a.xiz")
        _ = try Xipper.create(from: [t.url("src")], to: a, options: o)
        let x = try XizArchive(path: a.path)
        #expect(x.superblock.required.contains(.apple) && x.superblock.minor == 8)
        let want: Xiz.Codec = codec == .lzraven ? .lzraven : .lzmesh
        #expect(x.catalog.frames.contains { $0.codec == want })
        #expect(x.catalog.frames.allSatisfy { $0.codec == want || $0.codec == .store })
        #expect(try Xipper.test(a).isOK)
        t.mkdir("out")
        _ = try Xipper.extract(a, to: t.url("out"), mode: .into, options: ExtractOptions())
        #expect(treesEqual(t.path + "/src", t.path + "/out/src").0)

        // Encrypted, and appended to: the bit stays, new frames may use any codec.
        o.password = "segreto"
        o.xizKDF = .minimum
        let e = t.url("e.xiz")
        _ = try Xipper.create(from: [t.url("src")], to: e, options: o)
        t.write("extra.txt", "aggiunto\n")
        try Xipper.edit(e, changes: [.add(t.url("extra.txt"), as: "src/extra.txt")], password: "segreto")
        #expect(try Xipper.test(e, password: "segreto").isOK)
        #expect(try Xipper.readEntry(e, path: "src/t7.txt", password: "segreto", maxBytes: 1 << 20).data
                == Array(String(repeating: "Xipper riga 7 di testo ripetuto. ", count: 2_000).utf8))
    }

    /// Wrong sizes and damaged streams are errors, never more or fewer bytes.
    @Test func hostileFrames() throws {
        let data = [UInt8](String(repeating: "Xipper LZRAVEN e LZMESH ", count: 20_000).utf8)
        for codec in [Xiz.Codec.lzraven, .lzmesh] {
            let packed = try #require(data.withUnsafeBytes { Xiz.appleCompress($0, codec: codec) })
            #expect(packed.count < data.count / 10)
            #expect(try packed.withUnsafeBytes { try Xiz.appleDecompress($0, size: data.count, codec: codec) } == data)
            #expect(throws: XipperError.self) { _ = try packed.withUnsafeBytes { try Xiz.appleDecompress($0, size: data.count - 1, codec: codec) } }
            #expect(throws: XipperError.self) { _ = try packed.withUnsafeBytes { try Xiz.appleDecompress($0, size: data.count + 1, codec: codec) } }
            for k in 0..<300 {
                var p = packed
                if k % 3 == 0 { p.removeLast(Int.random(in: 1..<p.count)) } else {
                    for _ in 0..<(1 + k % 6) { p[Int.random(in: 0..<p.count)] ^= UInt8.random(in: 1...255) }
                }
                if let out = try? p.withUnsafeBytes({ try Xiz.appleDecompress($0, size: data.count, codec: codec) }) { #expect(out.count == data.count) }
            }
        }
        // Incompressible data: nil, the frame is stored.
        let noise = (0..<100_000).map { _ in UInt8.random(in: 0...255) }
        #expect(noise.withUnsafeBytes { Xiz.appleCompress($0, codec: .lzraven) } == nil)
    }
}
