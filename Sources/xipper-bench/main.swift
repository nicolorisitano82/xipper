// Codec bench (ROADMAP 2.6): ratio and single-core speed of the codecs Xipper has or could use,
// on independent blocks like XIZ frames. Not shipped: a developer tool.
//   swift run -c release xipper-bench <file-or-folder>... [--block 4m] [--runs 3]
// Each argument is one corpus; folders are read whole (regular files, in path order).
//   swift run -c release xipper-bench --jpeg <file-or-folder>...
// JPEG recompression (brunsli): each file on its own, rebuilt and compared byte for byte.
import CBrunsli
import CDeflate
import CLZ4
import CLZMA
import CZstd
import Compression
import Foundation

struct Codec {
    let name: String
    let compress: (UnsafeRawBufferPointer, UnsafeMutableRawBufferPointer) -> Int  // 0 = failed
    let decompress: (UnsafeRawBufferPointer, UnsafeMutableRawBufferPointer) -> Int
}

func zstd(_ level: Int32) -> Codec {
    Codec(name: "zstd -\(level)", compress: { s, d in
        let n = ZSTD_compress(d.baseAddress, d.count, s.baseAddress, s.count, level)
        return ZSTD_isError(n) != 0 ? 0 : n
    }, decompress: { s, d in
        let n = ZSTD_decompress(d.baseAddress, d.count, s.baseAddress, s.count)
        return ZSTD_isError(n) != 0 ? 0 : n
    })
}

func lz4(hc level: Int32?) -> Codec {
    Codec(name: level.map { "LZ4 HC \($0)" } ?? "LZ4", compress: { s, d in
        let src = s.baseAddress!.assumingMemoryBound(to: CChar.self), dst = d.baseAddress!.assumingMemoryBound(to: CChar.self)
        return Int(level.map { LZ4_compress_HC(src, dst, Int32(s.count), Int32(d.count), $0) }
                   ?? LZ4_compress_default(src, dst, Int32(s.count), Int32(d.count)))
    }, decompress: { s, d in
        Int(max(0, LZ4_decompress_safe(s.baseAddress!.assumingMemoryBound(to: CChar.self), d.baseAddress!.assumingMemoryBound(to: CChar.self),
                                       Int32(s.count), Int32(d.count))))
    })
}

func lzma2(_ preset: UInt32) -> Codec {
    func filters(_ opts: UnsafeMutablePointer<lzma_options_lzma>) -> [lzma_filter] {
        [lzma_filter(id: 0x21, options: UnsafeMutableRawPointer(opts)), lzma_filter(id: lzma_vli.max, options: nil)]
    }
    let opts = UnsafeMutablePointer<lzma_options_lzma>.allocate(capacity: 1)
    _ = lzma_lzma_preset(opts, preset)
    return Codec(name: "LZMA2 -\(preset)", compress: { s, d in
        var f = filters(opts)
        var pos = 0
        let r = lzma_raw_buffer_encode(&f, nil, s.baseAddress!.assumingMemoryBound(to: UInt8.self), s.count,
                                       d.baseAddress!.assumingMemoryBound(to: UInt8.self), &pos, d.count)
        return r == LZMA_OK ? pos : 0
    }, decompress: { s, d in
        var f = filters(opts)
        var inPos = 0, outPos = 0
        let r = lzma_raw_buffer_decode(&f, nil, s.baseAddress!.assumingMemoryBound(to: UInt8.self), &inPos, s.count,
                                       d.baseAddress!.assumingMemoryBound(to: UInt8.self), &outPos, d.count)
        return r == LZMA_OK || r == LZMA_STREAM_END ? outPos : 0
    })
}

func deflate(_ level: Int32) -> Codec {
    Codec(name: "Deflate -\(level) (libdeflate)", compress: { s, d in
        guard let c = libdeflate_alloc_compressor(level) else { return 0 }
        defer { libdeflate_free_compressor(c) }
        return libdeflate_deflate_compress(c, s.baseAddress, s.count, d.baseAddress, d.count)
    }, decompress: { s, d in
        guard let x = libdeflate_alloc_decompressor() else { return 0 }
        defer { libdeflate_free_decompressor(x) }
        var out = 0
        return libdeflate_deflate_decompress(x, s.baseAddress, s.count, d.baseAddress, d.count, &out) == LIBDEFLATE_SUCCESS ? out : 0
    })
}

func apple(_ name: String, _ algorithm: compression_algorithm) -> Codec {
    Codec(name: name + " (Apple)", compress: { s, d in
        compression_encode_buffer(d.baseAddress!.assumingMemoryBound(to: UInt8.self), d.count,
                                  s.baseAddress!.assumingMemoryBound(to: UInt8.self), s.count, nil, algorithm)
    }, decompress: { s, d in
        compression_decode_buffer(d.baseAddress!.assumingMemoryBound(to: UInt8.self), d.count,
                                  s.baseAddress!.assumingMemoryBound(to: UInt8.self), s.count, nil, algorithm)
    })
}

// MARK: corpus

var args = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
let jpegMode = args.contains("--jpeg")
args.removeAll { $0 == "--jpeg" }
let block = (option("--block").flatMap { Int($0.dropLast()) } ?? 4) << 20
let runs = Int(option("--runs") ?? "3") ?? 3
guard !args.isEmpty else {
    FileHandle.standardError.write(Data("usage: xipper-bench <file-or-folder>... [--block 4m] [--runs 3]\n".utf8))
    exit(2)
}

func load(_ path: String) -> Data {
    var isDir: ObjCBool = false
    FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
    guard isDir.boolValue else { return (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data() }
    var out = Data()
    let files = (FileManager.default.subpaths(atPath: path) ?? []).sorted()
    for f in files {
        let p = path + "/" + f
        var st = stat()
        guard lstat(p, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { continue }
        if let d = try? Data(contentsOf: URL(fileURLWithPath: p)) { out.append(d) }
    }
    return out
}

var codecs: [Codec] = [lz4(hc: nil), lz4(hc: 9), zstd(1), zstd(3), zstd(9), zstd(19), deflate(6), lzma2(6), lzma2(9),
                       apple("LZ4", COMPRESSION_LZ4_RAW), apple("LZFSE", COMPRESSION_LZFSE), apple("LZBITMAP", COMPRESSION_LZBITMAP),
                       apple("zlib", COMPRESSION_ZLIB), apple("LZMA", COMPRESSION_LZMA)]
if #available(macOS 27, *) {
    codecs += [apple("LZMESH", COMPRESSION_LZMESH), apple("LZRAVEN", COMPRESSION_LZRAVEN)]
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

/// brunsli on every JPEG under the arguments, against zstd -19 on the same files.
func jpegBench(_ paths: [String]) {
    var files: [String] = []
    for p in paths {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
        if !isDir.boolValue { files.append(p); continue }
        for f in (FileManager.default.subpaths(atPath: p) ?? []).sorted() where ["jpg", "jpeg"].contains((f as NSString).pathExtension.lowercased()) {
            files.append(p + "/" + f)
        }
    }
    var okBytes = 0, input = 0, output = 0, zstdOut = 0, encTime = 0.0, decTime = 0.0, ok = 0, refused = 0, mismatch = 0
    final class Sink { var bytes: [UInt8] = [] }
    let collect: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Int = { ctx, buf, n in
        Unmanaged<Sink>.fromOpaque(ctx!).takeUnretainedValue().bytes.append(contentsOf: UnsafeBufferPointer(start: buf, count: n))
        return n
    }
    for f in files {
        guard let data = try? [UInt8](Data(contentsOf: URL(fileURLWithPath: f))), !data.isEmpty else { continue }
        let packed = Sink(), rebuilt = Sink()
        let t0 = now()
        let e = data.withUnsafeBufferPointer { EncodeBrunsli($0.count, $0.baseAddress, Unmanaged.passUnretained(packed).toOpaque(), collect) }
        let t1 = now()
        var z = [UInt8](repeating: 0, count: ZSTD_compressBound(data.count))
        let zn = ZSTD_compress(&z, z.count, data, data.count, 19)
        zstdOut += ZSTD_isError(zn) != 0 ? data.count : min(zn, data.count)
        input += data.count
        guard e == 1 else { refused += 1; output += data.count; continue }
        let t2 = now()
        let d = packed.bytes.withUnsafeBufferPointer { DecodeBrunsli($0.count, $0.baseAddress, Unmanaged.passUnretained(rebuilt).toOpaque(), collect) }
        let t3 = now()
        guard d == 1, rebuilt.bytes == data else { mismatch += 1; output += data.count; continue }
        ok += 1
        okBytes += data.count
        output += packed.bytes.count
        encTime += t1 - t0
        decTime += t3 - t2
    }
    let mb = Double(input) / 1e6
    print("\(files.count) JPEG, \(String(format: "%.1f", mb)) MB: \(ok) recompressed, \(refused) refused, \(mismatch) not identical")
    print(String(format: "brunsli %.2f%% of the original (zstd -19: %.2f%%), encode %.1f MB/s, decode %.1f MB/s (one core, recompressed files)",
                 Double(output) / Double(input) * 100, Double(zstdOut) / Double(input) * 100,
                 Double(okBytes) / 1e6 / max(encTime, 1e-9), Double(okBytes) / 1e6 / max(decTime, 1e-9)))
}

if jpegMode {
    jpegBench(args)
    exit(0)
}

for path in args {
    let data = load(path)
    guard !data.isEmpty else { continue }
    let label = (path as NSString).lastPathComponent
    print("\n### \(label): \(String(format: "%.1f", Double(data.count) / 1e6)) MB, blocks of \(block >> 20) MiB, best of \(runs)\n")
    print("| Codec | Ratio | Compress MB/s | Decompress MB/s |")
    print("|---|---|---|---|")
    let blocks = stride(from: 0, to: data.count, by: block).map { data[$0..<min($0 + block, data.count)] }
    for c in codecs {
        var packed: [Data] = []
        var bestC = Double.infinity, bestD = Double.infinity
        var ok = true
        for _ in 0..<runs {
            packed.removeAll(keepingCapacity: true)
            let t0 = now()
            for b in blocks {
                var out = Data(count: b.count + b.count / 8 + (64 << 10))
                let n = b.withUnsafeBytes { s in out.withUnsafeMutableBytes { d in c.compress(s, d) } }
                if n == 0 { ok = false; break }
                packed.append(out.prefix(n))
            }
            bestC = min(bestC, now() - t0)
            if !ok { break }
        }
        guard ok else { print("| \(c.name) | — | failed | — |"); continue }
        var out = Data(count: block)
        for _ in 0..<runs {
            let t0 = now()
            for (p, b) in zip(packed, blocks) {
                let n = p.withUnsafeBytes { s in out.withUnsafeMutableBytes { d in c.decompress(s, d) } }
                if n != b.count || out.prefix(n) != b { ok = false }
            }
            bestD = min(bestD, now() - t0)
        }
        let size = packed.reduce(0) { $0 + $1.count }
        let mb = Double(data.count) / 1e6
        print(String(format: "| %@ | %.2f%% | %.0f | %@ |", c.name, Double(size) / Double(data.count) * 100, mb / bestC,
                     ok ? String(format: "%.0f", mb / bestD) : "MISMATCH"))
    }
}
