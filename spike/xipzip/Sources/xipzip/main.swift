// xipzip — spike: parallel ZIP writer / tester for Apple Silicon.
//
//   xipzip create <out.zip> <dir> [-l level] [-j threads] [--engine libdeflate|zlib] [--chunk MiB]
//   xipzip test   <in.zip> [-j threads]
//
// Not production code: no ZIP64, no xattrs, no streaming >RAM safety beyond batching.
import CCodecs
import Darwin
import Foundation

// MARK: - options

var args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
}
func sysInt(_ name: String) -> Int {
    var v: Int32 = 0; var sz = MemoryLayout<Int32>.size
    sysctlbyname(name, &v, &sz, nil, 0); return Int(v)
}
let pCores = sysInt("hw.perflevel0.physicalcpu"), eCores = sysInt("hw.perflevel1.physicalcpu")
let threads = Int(opt("-j") ?? "") ?? (pCores + eCores)
let level = Int32(opt("-l") ?? "6")!
let engine = opt("--engine") ?? "libdeflate"
let chunkSize = (Int(opt("--chunk") ?? "1") ?? 1) << 20
let bigThreshold = 4 * chunkSize
let batchBytes = 512 << 20

pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)
func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }
func fail(_ m: String) -> Never { FileHandle.standardError.write((m + "\n").data(using: .utf8)!); exit(1) }

/// Runs `body(i)` for i in 0..<n on at most `threads` workers.
func parallelFor(_ n: Int, _ body: @escaping (Int) -> Void) {
    let next = UnsafeMutablePointer<Int>.allocate(capacity: 1); next.initialize(to: 0)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: min(threads, max(n, 1))) { _ in
        while true {
            lock.lock(); let i = next.pointee; next.pointee += 1; lock.unlock()
            if i >= n { break }
            body(i)
        }
    }
    next.deallocate()
}

// MARK: - little-endian writer

struct LE {
    var b = [UInt8]()
    mutating func u16(_ v: UInt16) { b.append(UInt8(v & 0xff)); b.append(UInt8(v >> 8)) }
    mutating func u32(_ v: UInt32) { for s in stride(from: 0, to: 32, by: 8) { b.append(UInt8((v >> UInt32(s)) & 0xff)) } }
    mutating func bytes(_ a: [UInt8]) { b.append(contentsOf: a) }
}

func dosDateTime(_ t: time_t) -> (UInt16, UInt16) {
    var tt = t; var tmv = tm(); localtime_r(&tt, &tmv)
    let time = UInt16(tmv.tm_hour << 11 | tmv.tm_min << 5 | tmv.tm_sec / 2)
    let date = UInt16(max(0, Int(tmv.tm_year) - 80) << 9 | Int(tmv.tm_mon + 1) << 5 | Int(tmv.tm_mday))
    return (time, date)
}

// MARK: - create

enum Kind { case file, dir, symlink }
struct Entry { let rel: String; let path: String; let kind: Kind; let mode: UInt16; let mtime: time_t; let size: Int }

final class Packed {
    var method: UInt16 = 0, crc: UInt32 = 0, csize = 0, usize = 0
    var data: [UInt8] = []
    var chunks: [[UInt8]] = []        // big files: per-chunk deflate output
    var chunkCRC: [(UInt32, Int)] = []
}

/// Maps a file read-only; returns (pointer, length). Caller munmaps.
func mapFile(_ path: String, _ size: Int) -> UnsafeRawPointer? {
    if size == 0 { return nil }
    let fd = open(path, O_RDONLY); if fd < 0 { fail("open \(path)") }
    defer { close(fd) }
    let p = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0)
    if p == MAP_FAILED { fail("mmap \(path)") }
    madvise(p, size, MADV_SEQUENTIAL)
    return UnsafeRawPointer(p)
}

func compressSmall(_ e: Entry, _ out: Packed) {
    out.usize = e.size
    guard let p = mapFile(e.path, e.size) else { out.method = 0; return }
    defer { munmap(UnsafeMutableRawPointer(mutating: p), e.size) }
    let src = p.assumingMemoryBound(to: UInt8.self)
    out.crc = UInt32(libdeflate_crc32(0, src, e.size))
    var buf: [UInt8]; var n = 0
    if engine == "zlib" {
        let cap = xz_deflate_chunk_bound(e.size); buf = [UInt8](repeating: 0, count: cap)
        n = buf.withUnsafeMutableBufferPointer { xz_deflate_chunk(src, e.size, nil, 0, level, 1, $0.baseAddress, cap) }
    } else {
        let c = libdeflate_alloc_compressor(level); defer { libdeflate_free_compressor(c) }
        let cap = libdeflate_deflate_compress_bound(c, e.size); buf = [UInt8](repeating: 0, count: cap)
        n = buf.withUnsafeMutableBufferPointer { libdeflate_deflate_compress(c, src, e.size, $0.baseAddress, cap) }
    }
    if n == 0 || n >= e.size {  // incompressible → store
        out.method = 0; out.data = Array(UnsafeBufferPointer(start: src, count: e.size)); out.csize = e.size
    } else {
        buf.removeSubrange(n...); out.method = 8; out.data = buf; out.csize = n
    }
}

func compressChunk(_ e: Entry, _ k: Int, _ out: Packed) {
    let off = k * chunkSize, len = min(chunkSize, e.size - off), last = off + len == e.size
    let fd = open(e.path, O_RDONLY); defer { close(fd) }
    // map the chunk plus up to 32 KiB of preceding dictionary
    let dictLen = min(off, 32768)
    let pageOff = (off - dictLen) & ~(16384 - 1)
    let mapLen = off + len - pageOff
    let base = mmap(nil, mapLen, PROT_READ, MAP_PRIVATE, fd, off_t(pageOff))!
    defer { munmap(base, mapLen) }
    let src = (base + (off - pageOff)).assumingMemoryBound(to: UInt8.self)
    let dict = dictLen > 0 ? (base + (off - dictLen - pageOff)).assumingMemoryBound(to: UInt8.self) : nil
    let cap = xz_deflate_chunk_bound(len)
    var buf = [UInt8](repeating: 0, count: cap)
    let n = buf.withUnsafeMutableBufferPointer { xz_deflate_chunk(src, len, dict, dictLen, level, last ? 1 : 0, $0.baseAddress, cap) }
    if n == 0 { fail("deflate chunk \(e.rel)#\(k)") }
    buf.removeSubrange(n...)
    out.chunks[k] = buf
    out.chunkCRC[k] = (UInt32(libdeflate_crc32(0, src, len)), len)
}

func create(_ outPath: String, _ root: String) {
    let t0 = now()
    // 1. walk
    var entries: [Entry] = []
    let rootURL = URL(fileURLWithPath: root).standardizedFileURL
    let prefix = rootURL.lastPathComponent
    guard let en = FileManager.default.enumerator(atPath: rootURL.path) else { fail("walk") }
    var rels = [""]; while let r = en.nextObject() as? String { rels.append(r) }
    rels.sort()
    for r in rels {
        let p = r.isEmpty ? rootURL.path : rootURL.path + "/" + r
        var st = stat(); if lstat(p, &st) != 0 { continue }
        let name = r.isEmpty ? prefix : prefix + "/" + r
        let fmt = st.st_mode & S_IFMT
        let kind: Kind = fmt == S_IFDIR ? .dir : fmt == S_IFLNK ? .symlink : .file
        if fmt != S_IFDIR && fmt != S_IFLNK && fmt != S_IFREG { continue }
        if (r as NSString).lastPathComponent == ".DS_Store" { continue }
        entries.append(Entry(rel: kind == .dir ? name + "/" : name, path: p, kind: kind,
                             mode: st.st_mode, mtime: st.st_mtimespec.tv_sec, size: Int(st.st_size)))
    }
    let totalIn = entries.reduce(0) { $0 + ($1.kind == .file ? $1.size : 0) }
    let t1 = now()

    // 2. compress in batches, write in order
    guard let fp = fopen(outPath, "wb") else { fail("fopen \(outPath)") }
    setvbuf(fp, nil, _IOFBF, 8 << 20)
    var offset = 0
    var central = LE()
    var count = 0
    var i = 0
    var bigFiles = 0, chunkJobs = 0
    while i < entries.count {
        // batch [i, j)
        var j = i, acc = 0
        while j < entries.count && (acc < batchBytes || j == i) { acc += entries[j].size; j += 1 }
        let batch = Array(entries[i..<j])
        let packed = batch.map { _ in Packed() }
        // flatten jobs: (entryIndex, chunk or -1)
        var jobs: [(Int, Int)] = []
        for (k, e) in batch.enumerated() where e.kind == .file {
            if e.size > bigThreshold {
                let nc = (e.size + chunkSize - 1) / chunkSize
                packed[k].chunks = Array(repeating: [], count: nc)
                packed[k].chunkCRC = Array(repeating: (0, 0), count: nc)
                for c in 0..<nc { jobs.append((k, c)) }
                bigFiles += 1; chunkJobs += nc
            } else { jobs.append((k, -1)) }
        }
        // biggest jobs first for better load balance
        jobs.sort { (a, b) in
            let sa = a.1 >= 0 ? chunkSize : batch[a.0].size, sb = b.1 >= 0 ? chunkSize : batch[b.0].size
            return sa > sb
        }
        let jobsC = jobs
        parallelFor(jobsC.count) { n in
            let (k, c) = jobsC[n]
            if c < 0 { compressSmall(batch[k], packed[k]) } else { compressChunk(batch[k], c, packed[k]) }
        }
        // finalize big files: combine CRCs, choose store if not worth it
        for (k, e) in batch.enumerated() where e.kind == .file && e.size > bigThreshold {
            let p = packed[k]
            var crc: uLong = 0
            for (c, (cc, len)) in p.chunkCRC.enumerated() { crc = c == 0 ? uLong(cc) : crc32_combine(crc, uLong(cc), len) }
            p.crc = UInt32(crc); p.usize = e.size
            let cs = p.chunks.reduce(0) { $0 + $1.count }
            if cs >= e.size {
                let src = mapFile(e.path, e.size)!
                p.method = 0; p.data = Array(UnsafeBufferPointer(start: src.assumingMemoryBound(to: UInt8.self), count: e.size))
                munmap(UnsafeMutableRawPointer(mutating: src), e.size); p.chunks = []; p.csize = e.size
            } else { p.method = 8; p.csize = cs }
        }
        // write
        for (k, e) in batch.enumerated() {
            let p = packed[k]
            if e.kind == .symlink {
                var buf = [Int8](repeating: 0, count: Int(PATH_MAX))
                let n = readlink(e.path, &buf, buf.count)
                p.data = buf[0..<max(n, 0)].map { UInt8(bitPattern: $0) }
                p.usize = p.data.count; p.csize = p.data.count
                p.crc = UInt32(p.data.withUnsafeBufferPointer { libdeflate_crc32(0, $0.baseAddress, $0.count) })
            }
            if offset > 0xFFFF_FFFE || p.csize > 0xFFFF_FFFE { fail("ZIP64 needed: not in spike") }
            let name = Array(e.rel.utf8)
            let (dt, dd) = dosDateTime(e.mtime)
            var h = LE()
            h.u32(0x0403_4b50); h.u16(20); h.u16(0x0800); h.u16(p.method); h.u16(dt); h.u16(dd)
            h.u32(p.crc); h.u32(UInt32(p.csize)); h.u32(UInt32(p.usize)); h.u16(UInt16(name.count)); h.u16(0)
            h.bytes(name)
            fwrite(h.b, 1, h.b.count, fp)
            if !p.chunks.isEmpty { for c in p.chunks { fwrite(c, 1, c.count, fp) } } else if !p.data.isEmpty { fwrite(p.data, 1, p.data.count, fp) }
            central.u32(0x0201_4b50); central.u16(3 << 8 | 63); central.u16(20); central.u16(0x0800); central.u16(p.method)
            central.u16(dt); central.u16(dd); central.u32(p.crc); central.u32(UInt32(p.csize)); central.u32(UInt32(p.usize))
            central.u16(UInt16(name.count)); central.u16(0); central.u16(0); central.u16(0); central.u16(0)
            central.u32(UInt32(e.mode) << 16 | (e.kind == .dir ? 0x10 : 0)); central.u32(UInt32(offset)); central.bytes(name)
            offset += h.b.count + p.csize
            count += 1
        }
        i = j
    }
    var eocd = LE()
    eocd.u32(0x0605_4b50); eocd.u16(0); eocd.u16(0); eocd.u16(UInt16(count)); eocd.u16(UInt16(count))
    eocd.u32(UInt32(central.b.count)); eocd.u32(UInt32(offset)); eocd.u16(0)
    fwrite(central.b, 1, central.b.count, fp); fwrite(eocd.b, 1, eocd.b.count, fp)
    fclose(fp)
    let t2 = now()
    let outSize = offset + central.b.count + eocd.b.count
    print(String(format: "create: %d entries, %.1f MB -> %.1f MB (%.2f%%), walk %.2fs, total %.2fs, %.0f MB/s, threads %d, engine %@, big files %d (%d chunks)",
                 count, Double(totalIn) / 1e6, Double(outSize) / 1e6, 100.0 * Double(outSize) / Double(totalIn),
                 t1 - t0, t2 - t0, Double(totalIn) / (t2 - t0) / 1e6, threads, engine, bigFiles, chunkJobs))
}

// MARK: - test (parallel integrity check)

func rd16(_ p: UnsafeRawPointer, _ o: Int) -> Int { Int(p.loadUnaligned(fromByteOffset: o, as: UInt16.self).littleEndian) }
func rd32(_ p: UnsafeRawPointer, _ o: Int) -> Int { Int(p.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian) }

func test(_ path: String) {
    let t0 = now()
    var st = stat(); if stat(path, &st) != 0 { fail("stat") }
    let size = Int(st.st_size)
    let p = mapFile(path, size)!
    var e = size - 22
    while e >= max(0, size - 65557) && rd32(p, e) != 0x0605_4b50 { e -= 1 }
    if e < 0 || rd32(p, e) != 0x0605_4b50 { fail("no EOCD") }
    let n = rd16(p, e + 10), cdOff = rd32(p, e + 16)
    struct CD { let method, crc, csize, usize, lho: Int; let name: String }
    var cds: [CD] = []; var o = cdOff
    for _ in 0..<n {
        if rd32(p, o) != 0x0201_4b50 { fail("bad CD") }
        let nl = rd16(p, o + 28), el = rd16(p, o + 30), cl = rd16(p, o + 32)
        let name = String(decoding: UnsafeRawBufferPointer(start: p + o + 46, count: nl), as: UTF8.self)
        cds.append(CD(method: rd16(p, o + 10), crc: rd32(p, o + 16), csize: rd32(p, o + 20), usize: rd32(p, o + 24), lho: rd32(p, o + 42), name: name))
        o += 46 + nl + el + cl
    }
    let bad = UnsafeMutablePointer<Int>.allocate(capacity: 1); bad.initialize(to: 0)
    let lock = NSLock()
    let order = cds.indices.sorted { cds[$0].usize > cds[$1].usize }
    parallelFor(order.count) { k in
        let c = cds[order[k]]
        let lh = c.lho
        let data = p + lh + 30 + rd16(p, lh + 26) + rd16(p, lh + 28)
        var crc: UInt32 = 0
        if c.method == 0 {
            crc = UInt32(libdeflate_crc32(0, data, c.csize))
        } else if c.method == 8 {
            let d = libdeflate_alloc_decompressor(); defer { libdeflate_free_decompressor(d) }
            let out = UnsafeMutableRawPointer.allocate(byteCount: max(c.usize, 1), alignment: 16); defer { out.deallocate() }
            var got = 0
            let r = libdeflate_deflate_decompress(d, data, c.csize, out, c.usize, &got)
            if r != LIBDEFLATE_SUCCESS || got != c.usize { lock.lock(); bad.pointee += 1; lock.unlock(); print("FAIL inflate \(c.name)"); return }
            crc = UInt32(libdeflate_crc32(0, out, c.usize))
        } else { print("SKIP method \(c.method) \(c.name)"); return }
        if crc != UInt32(c.crc) { lock.lock(); bad.pointee += 1; lock.unlock(); print("FAIL crc \(c.name)") }
    }
    let total = cds.reduce(0) { $0 + $1.usize }
    let t1 = now()
    print(String(format: "test: %d entries, %.1f MB uncompressed, %d errors, %.2fs, %.0f MB/s, threads %d",
                 n, Double(total) / 1e6, bad.pointee, t1 - t0, Double(total) / (t1 - t0) / 1e6, threads))
    if bad.pointee > 0 { exit(2) }
}

guard args.count >= 2 else { fail("usage: xipzip create <out.zip> <dir> | test <in.zip>") }
switch args[0] {
case "create": create(args[1], args[2])
case "test": test(args[1])
default: fail("unknown command")
}
