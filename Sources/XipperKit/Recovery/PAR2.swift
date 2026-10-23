import CryptoKit
import CXipShims
import Foundation
import Synchronization

/// PAR 2.0 recovery files (Parity Volume Set Specification 2.0, Clements et al. 2003), written
/// from the specification: compatible with par2cmdline, QuickPar and MultiPar.
///
/// - `create` writes `<file>.par2` (index: main, file description, slice checksums, creator) and
///   `<file>.vol00+NN.par2` (the recovery slices, with copies of the critical packets).
/// - `verify` checks every slice of the protected files against its MD5 and CRC-32 where it
///   belongs; slices not found there are searched for at every byte offset of the protected
///   files (rolling CRC-32, then MD5), as par2cmdline does, so data shifted by an insertion or a
///   deletion, or moved, still counts and needs no recovery slice.
/// - `repair` puts moved slices back and rebuilds the missing ones from the recovery slices
///   (Reed-Solomon over GF(2^16)), then replaces each repaired file atomically.
public enum PAR2 {
    public struct FileStatus: Sendable {
        public var name: String
        public var url: URL
        public var size: Int64
        public var slices: Int
        /// Slices not where they belong (moved, damaged or missing).
        public var damagedSlices: Int
        /// Of those, the ones found intact at another offset or in another protected file.
        public var movedSlices: Int = 0
        public var missing: Bool
    }

    public struct Report: Sendable {
        public var files: [FileStatus]
        public var sliceSize: Int
        public var recoverySlices: Int
        public var damagedSlices: Int { files.reduce(0) { $0 + $1.damagedSlices } }
        /// Slices found nowhere: each needs a recovery slice.
        public var missingSlices: Int { files.reduce(0) { $0 + $1.damagedSlices - $1.movedSlices } }
        public var isIntact: Bool { damagedSlices == 0 }
        public var canRepair: Bool { missingSlices <= recoverySlices }
    }

    /// `<archive>.par2` next to the archive, if present.
    public static func indexFile(for file: URL) -> URL? {
        let u = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".par2")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    // MARK: create

    /// Protects `files` (same folder) with `redundancy` percent of recovery data; returns the
    /// files written. `targetSlices`: how many slices the data is cut into (par2cmdline: 2000).
    @discardableResult
    public static func create(for files: [URL], redundancy: Double = 10, targetSlices: Int = 2000,
                              progress: ProgressHandler? = nil, cancel: CancellationToken? = nil) throws -> [URL] {
        guard let first = files.first else { throw XipperError.invalidArgument("nothing to protect") }
        let dir = first.deletingLastPathComponent()
        let sizes = try files.map { try FileReader(path: $0.path).size }
        let total = sizes.reduce(0, +)
        guard total > 0 else { throw XipperError.invalidArgument("nothing to protect (empty files)") }
        // Slice size: a multiple of 4, so that the number of input slices stays ≤ 32768.
        var sliceSize = Int((total + Int64(targetSlices) - 1) / Int64(targetSlices))
        sliceSize = max(4096, (sliceSize + 3) & ~3)  // tiny slices cost more in overhead than they save
        while files.indices.reduce(0, { $0 + Int((sizes[$1] + Int64(sliceSize) - 1) / Int64(sliceSize)) }) > 32768 { sliceSize *= 2 }
        let tracker = ProgressTracker(totalBytes: total * 2, totalEntries: files.count, handler: progress)

        // File descriptions and slice checksums. MD5 is sequential: one task hashes the whole file
        // while the others hash its slices (MD5 + CRC-32 each), so the whole-file hash bounds the time.
        var descs: [FileDesc] = []
        for (i, url) in files.enumerated() {
            try cancel?.check()
            let r = try FileReader(path: url.path)
            let size = r.size
            let count = Int((size + Int64(sliceSize) - 1) / Int64(sliceSize))
            let checks = Slots<(md5: [UInt8], crc: UInt32)>(count)
            let wholes = Mutex<(md5: [UInt8], head: [UInt8])>(([], []))
            try parallelFor(count + 1, workload: .interactive, cancel: cancel) { k in
                if k == 0 {
                    var whole = Insecure.MD5()
                    var head = Insecure.MD5()
                    let chunk = 4 << 20
                    let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
                    defer { buf.deallocate() }
                    var off: Int64 = 0
                    while off < size {
                        try cancel?.check()
                        let n = try r.readSome(at: off, into: buf, count: min(chunk, Int(size - off)))
                        if n == 0 { break }
                        if off < 16384 { head.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: min(n, 16384 - Int(off)))) }
                        whole.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: n))
                        off += Int64(n)
                    }
                    wholes.withLock { $0 = (Array(whole.finalize()), Array(head.finalize())) }
                    return
                }
                let off = Int64(k - 1) * Int64(sliceSize)
                let n = Int(min(Int64(sliceSize), size - off))
                var slice = try r.read(at: off, count: n)
                if n < sliceSize { slice += [UInt8](repeating: 0, count: sliceSize - n) }  // the last slice is padded with zeros
                checks[k - 1] = (Array(Insecure.MD5.hash(data: slice)), CRC32.checksum(slice))
                tracker.add(bytes: Int64(n))
            }
            let (md5, head16) = wholes.withLock { $0 }
            let name = url.lastPathComponent
            var idInput = head16
            idInput += le(UInt64(sizes[i]))
            idInput += Array(name.utf8)
            descs.append(FileDesc(id: Array(Insecure.MD5.hash(data: idInput)), md5: md5, md5_16k: head16,
                                  length: UInt64(sizes[i]), name: name, url: url, slices: (0..<count).map { checks.take($0)! }))
        }
        descs.sort { $0.id.lexicographicallyPrecedes($1.id) }  // slices are numbered in file-ID order

        var mainBody = le(UInt64(sliceSize)) + le(UInt32(descs.count))
        for d in descs { mainBody += d.id }
        let setID = Array(Insecure.MD5.hash(data: mainBody))
        var critical = packet(.main, setID, mainBody)
        for d in descs {
            critical += packet(.fileDesc, setID, d.id + d.md5 + d.md5_16k + le(d.length) + padded(Array(d.name.utf8)))
            critical += packet(.ifsc, setID, d.id + d.slices.flatMap { $0.md5 + le($0.crc) })
        }
        let creator = packet(.creator, setID, padded(Array("Xipper (XipperKit PAR2)".utf8)))

        // Recovery slices: R_e = Σ_i c_i^e · S_i over all input slices i.
        let inputCount = descs.reduce(0) { $0 + $1.slices.count }
        let recoveryCount = max(1, min(65535 - 1, Int((Double(inputCount) * redundancy / 100).rounded(.up))))
        let constants = GF16.inputConstants(inputCount)
        let recovery = try computeRecovery(descs, sliceSize: sliceSize, exponents: Array(0..<recoveryCount),
                                           constants: constants, tracker: tracker, total: total, cancel: cancel)

        let base = dir.appendingPathComponent(descs.count == 1 ? descs[0].name : first.lastPathComponent)
        let index = URL(fileURLWithPath: base.path + ".par2")
        let volume = URL(fileURLWithPath: base.path + ".vol00+\(String(format: "%02d", recoveryCount)).par2")
        try write(index, critical + creator)
        let out = try OutputFile(path: volume.path)
        for (e, data) in recovery.enumerated() {
            try out.write(packetHeader(.recovery, setID, body: le(UInt32(e)), data: data))
            try data.withUnsafeBytes { try out.write($0) }
        }
        try out.write(critical + creator)  // copies of the critical packets in every file, as the spec asks
        try out.commit(overwrite: true)
        tracker.finish()
        return [index, volume]
    }

    // MARK: verify and repair

    public static func verify(_ par2: URL, cancel: CancellationToken? = nil) throws -> Report {
        let set = try RecoverySet(par2)
        return try set.check(cancel: cancel).report
    }

    /// Repairs what `verify` finds damaged; throws `limitExceeded` when the recovery data is not enough.
    @discardableResult
    public static func repair(_ par2: URL, progress: ProgressHandler? = nil, cancel: CancellationToken? = nil) throws -> Report {
        let set = try RecoverySet(par2)
        let state = try set.check(cancel: cancel)
        guard !state.report.isIntact else { return state.report }
        guard state.report.canRepair else {
            throw XipperError.limitExceeded("\(state.report.missingSlices) missing slices, only \(state.report.recoverySlices) recovery slices")
        }
        try set.rebuild(missing: state.badGlobal.filter { state.found[$0] == nil }, found: state.found, progress: progress, cancel: cancel)
        let after = try set.check(cancel: cancel).report
        guard after.isIntact else { throw XipperError.integrity(entry: par2.lastPathComponent, detail: "repair did not verify") }
        return after
    }

    // MARK: packets

    enum PacketType {
        case main, fileDesc, ifsc, recovery, creator
        var bytes: [UInt8] {
            let s: String = switch self {
            case .main: "PAR 2.0\0Main\0\0\0\0"
            case .fileDesc: "PAR 2.0\0FileDesc"
            case .ifsc: "PAR 2.0\0IFSC\0\0\0\0"
            case .recovery: "PAR 2.0\0RecvSlic"
            case .creator: "PAR 2.0\0Creator\0"
            }
            return Array(s.utf8)
        }
    }

    static let magic: [UInt8] = Array("PAR2\0PKT".utf8)

    struct FileDesc {
        var id: [UInt8]
        var md5: [UInt8]
        var md5_16k: [UInt8]
        var length: UInt64
        var name: String
        var url: URL
        var slices: [(md5: [UInt8], crc: UInt32)]
    }

    static func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
    static func padded(_ b: [UInt8]) -> [UInt8] { b + [UInt8](repeating: 0, count: (4 - b.count % 4) % 4) }

    /// Header (64 bytes) whose MD5 covers the set ID, the type and the body (and `data`).
    static func packetHeader(_ type: PacketType, _ setID: [UInt8], body: [UInt8], data: [UInt8] = []) -> [UInt8] {
        var md5 = Insecure.MD5()
        md5.update(data: setID); md5.update(data: type.bytes); md5.update(data: body); md5.update(data: data)
        return magic + le(UInt64(64 + body.count + data.count)) + Array(md5.finalize()) + setID + type.bytes + body
    }

    static func packet(_ type: PacketType, _ setID: [UInt8], _ body: [UInt8]) -> [UInt8] { packetHeader(type, setID, body: body) }

    private static func write(_ url: URL, _ bytes: [UInt8]) throws {
        let out = try OutputFile(path: url.path)
        try out.write(bytes)
        try out.commit(overwrite: true)
    }

    /// Recovery slices for `exponents`, reading the input once: for each window of the slices'
    /// byte range, every input slice is multiplied into every recovery buffer (in parallel by buffer).
    static func computeRecovery(_ descs: [FileDesc], sliceSize: Int, exponents: [Int], constants: [UInt16],
                                tracker: ProgressTracker?, total: Int64, cancel: CancellationToken?) throws -> [[UInt8]] {
        var out = exponents.map { _ in [UInt8](repeating: 0, count: sliceSize) }
        let readers = try descs.map { try FileReader(path: $0.url.path) }
        // Window: all recovery buffers' slices of it stay within ~256 MiB of reads per pass.
        let window = max(4, min(sliceSize, ((256 << 20) / max(1, exponents.count)) & ~3))
        var lo = 0
        while lo < sliceSize {
            let hi = min(sliceSize, lo + window)
            // Input pieces are read in batches of ~32 MiB; each recovery buffer then takes the whole
            // batch on one thread (few, large tasks instead of one per slice).
            var batch: [(piece: [UInt8], constant: UInt16)] = []
            var batchBytes = 0
            func flush() throws {
                guard !batch.isEmpty else { return }
                let items = batch
                try out.withUnsafeMutableBufferPointer { bufs in
                    let b = bufs
                    try parallelFor(exponents.count, workload: .interactive, cancel: cancel) { k in
                        b[k].withUnsafeMutableBytes { dst in
                            let window = UnsafeMutableRawBufferPointer(rebasing: dst[lo..<hi])
                            for item in items {
                                item.piece.withUnsafeBytes { GF16.mulAdd(window, $0, GF16.pow(item.constant, exponents[k])) }
                            }
                        }
                    }
                }
                tracker?.add(bytes: Int64(batchBytes) * total / max(1, Int64(sliceSize) * Int64(constants.count)) * 2)
                batch.removeAll(keepingCapacity: true)
                batchBytes = 0
            }
            var global = 0
            for (f, d) in descs.enumerated() {
                for s in 0..<d.slices.count {
                    try cancel?.check()
                    var piece = [UInt8](repeating: 0, count: hi - lo)
                    let start = Int64(s) * Int64(sliceSize) + Int64(lo)
                    if start < Int64(d.length) {
                        let n = Int(min(Int64(hi - lo), Int64(d.length) - start))
                        try piece.withUnsafeMutableBytes { try readers[f].read(at: start, into: $0.baseAddress!, count: n) }
                    }
                    batch.append((piece, constants[global]))
                    batchBytes += hi - lo
                    if batchBytes >= 32 << 20 { try flush() }
                    global += 1
                }
            }
            try flush()
            lo = hi
        }
        return out
    }
}

/// The packets found in a set of .par2 files, and the protected files they describe.
final class RecoverySet {
    let directory: URL
    let setID: [UInt8]
    let sliceSize: Int
    let files: [PAR2.FileDesc]  // in slice-numbering order
    /// Exponent → where its data is (file, offset).
    let recovery: [Int: (URL, Int64)]

    struct State {
        var report: PAR2.Report
        var badGlobal: [Int]
        /// Bad slices found intact elsewhere: global slice → where its bytes are.
        var found: [Int: Source]
    }

    struct Source { var url: URL; var offset: Int64; var length: Int }

    init(_ par2: URL) throws {
        let dir = par2.deletingLastPathComponent()
        directory = dir
        // Every .par2 of the same base name: "x.par2", "x.vol00+10.par2", "x.vol10+20.par2"…
        var base = par2.lastPathComponent
        if base.hasSuffix(".par2") { base.removeLast(5) }
        if let r = base.range(of: ".vol", options: .backwards), base[r.upperBound...].contains("+") { base = String(base[..<r.lowerBound]) }
        let candidates = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix(base) && $0.lowercased().hasSuffix(".par2") }
            .map { dir.appendingPathComponent($0) }
        var main: [UInt8]?
        var mainSet: [UInt8]?
        var descs: [[UInt8]: (md5: [UInt8], md5_16k: [UInt8], length: UInt64, name: String)] = [:]
        var ifsc: [[UInt8]: [(md5: [UInt8], crc: UInt32)]] = [:]
        var rec: [Int: (URL, Int64)] = [:]
        for url in candidates {
            let r = try FileReader(path: url.path)
            var off: Int64 = 0
            while off + 64 <= r.size {
                let head = try r.read(at: off, count: 64)
                guard Array(head[0..<8]) == PAR2.magic else { off += 4; continue }  // resynchronize on damage
                let length = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self).littleEndian }
                guard length >= 64, length % 4 == 0, Int64(length) <= r.size - off, length < (1 << 32) else { off += 4; continue }
                let packet = try r.read(at: off, count: Int(length))
                guard Array(Insecure.MD5.hash(data: packet[32...])) == Array(head[16..<32]) else { off += 4; continue }
                let set = Array(head[32..<48]), type = Array(head[48..<64])
                let body = Array(packet[64...])
                if mainSet != nil && set != mainSet! { off += Int64(length); continue }
                switch type {
                case PAR2.PacketType.main.bytes:
                    if Array(Insecure.MD5.hash(data: body)) == set, body.count >= 12 { main = body; mainSet = set }
                case PAR2.PacketType.fileDesc.bytes where body.count >= 56:
                    let id = Array(body[0..<16])
                    let len = body.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 48, as: UInt64.self).littleEndian }
                    let name = String(decoding: body[56...].prefix { $0 != 0 }, as: UTF8.self)
                    descs[id] = (Array(body[16..<32]), Array(body[32..<48]), len, name)
                case PAR2.PacketType.ifsc.bytes where body.count >= 16 && (body.count - 16) % 20 == 0:
                    let id = Array(body[0..<16])
                    ifsc[id] = stride(from: 16, to: body.count, by: 20).map { i in
                        (Array(body[i..<(i + 16)]), body.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i + 16, as: UInt32.self).littleEndian })
                    }
                case PAR2.PacketType.recovery.bytes where body.count >= 4:
                    let e = Int(body.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian })
                    rec[e] = rec[e] ?? (url, off + 68)
                default: break
                }
                off += Int64(length)
            }
        }
        guard let main, let mainSet else { throw XipperError.corrupt("no valid PAR2 main packet") }
        setID = mainSet
        let size = Int(main.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self).littleEndian })
        sliceSize = size
        let count = Int(main.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian })
        guard size > 0, size % 4 == 0, size <= 1 << 30, main.count >= 12 + count * 16 else {
            throw XipperError.corrupt("invalid PAR2 main packet")
        }
        var list: [PAR2.FileDesc] = []
        for k in 0..<count {
            let id = Array(main[(12 + k * 16)..<(28 + k * 16)])
            guard let d = descs[id], let checks = ifsc[id] else { throw XipperError.corrupt("PAR2 file description missing") }
            guard d.name.split(separator: "/").allSatisfy({ $0 != ".." }), !d.name.hasPrefix("/") else {
                throw XipperError.unsafeEntry(entry: d.name, reason: "PAR2 name escapes the folder")
            }
            list.append(PAR2.FileDesc(id: id, md5: d.md5, md5_16k: d.md5_16k, length: d.length, name: d.name,
                                      url: dir.appendingPathComponent(d.name), slices: checks))
        }
        files = list
        // Recovery data must match the slice size.
        recovery = rec.filter { (_, place) in
            ((try? FileReader(path: place.0.path).size) ?? 0) >= place.1 + Int64(size)
        }
    }

    func check(cancel: CancellationToken?) throws -> State {
        var damaged: [Int] = []
        var bad: [Int] = []
        var global = 0
        let buf = UnsafeMutableRawPointer.allocate(byteCount: sliceSize, alignment: 16)
        defer { buf.deallocate() }
        let readers = files.map { try? FileReader(path: $0.url.path) }
        for (f, d) in files.enumerated() {
            var count = 0
            for (s, expected) in d.slices.enumerated() {
                try cancel?.check()
                var ok = false
                if let reader = readers[f] {
                    let start = Int64(s) * Int64(sliceSize)
                    let want = Int(min(Int64(sliceSize), Int64(d.length) - start))
                    let n = start < reader.size ? (try? reader.readSome(at: start, into: buf, count: want)) ?? 0 : 0
                    if n == want {
                        memset(buf + n, 0, sliceSize - n)
                        let slice = UnsafeRawBufferPointer(start: buf, count: sliceSize)
                        ok = CRC32.checksum(slice) == expected.crc && Array(Insecure.MD5.hash(data: slice)) == expected.md5
                    }
                }
                if !ok { count += 1; bad.append(global) }
                global += 1
            }
            // Extra bytes at the end: the last slice is rewritten (found in place, truncated).
            if let reader = readers[f], reader.size != Int64(d.length), count == 0, !d.slices.isEmpty { count = 1; bad.append(global - 1) }
            damaged.append(count)
        }
        let found = bad.isEmpty ? [:] : try search(Set(bad), cancel: cancel)
        var statuses: [PAR2.FileStatus] = []
        global = 0
        for (f, d) in files.enumerated() {
            let range = global..<(global + d.slices.count)
            global += d.slices.count
            statuses.append(PAR2.FileStatus(name: d.name, url: d.url, size: Int64(d.length), slices: d.slices.count,
                                            damagedSlices: damaged[f], movedSlices: found.keys.filter(range.contains).count,
                                            missing: readers[f] == nil))
        }
        return State(report: PAR2.Report(files: statuses, sliceSize: sliceSize, recoverySlices: recovery.count), badGlobal: bad, found: found)
    }

    /// Looks for the `wanted` slices at every byte offset of the protected files: a rolling CRC-32
    /// over a slice-sized window, filtered through a 2^24-bit table, confirmed by the slice's MD5.
    /// After a match the scan jumps a whole slice, as par2cmdline does. A short last slice (padded
    /// with zeros in its checksums) is tried right after its predecessor and at the end of each file.
    private func search(_ wanted: Set<Int>, cancel: CancellationToken?) throws -> [Int: Source] {
        let L = sliceSize
        var full: [UInt32: [(global: Int, md5: [UInt8])]] = [:]
        var short: [(global: Int, length: Int, crc: UInt32, md5: [UInt8])] = []
        var global = 0
        for d in files {
            for (s, c) in d.slices.enumerated() {
                defer { global += 1 }
                guard wanted.contains(global) else { continue }
                let length = Int(min(Int64(L), Int64(d.length) - Int64(s) * Int64(L)))
                if length == L { full[c.crc, default: []].append((global, c.md5)) } else { short.append((global, length, c.crc, c.md5)) }
            }
        }
        var found: [Int: Source] = [:]
        if !full.isEmpty {
            var filter = [UInt64](repeating: 0, count: 1 << 18)
            for crc in full.keys { filter[Int(crc & 0xFFFFFF) >> 6] |= 1 << (crc & 63) }
            let roll = RollingCRC32(window: L)
            for url in Set(files.map(\.url)) {
                guard found.count < wanted.count,
                      let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count >= L else { continue }
                try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    let p = raw.bindMemory(to: UInt8.self).baseAddress!
                    let n = raw.count
                    var pos = 0
                    var crc = CRC32.checksum(UnsafeRawBufferPointer(start: p, count: L))
                    var steps = 0
                    while true {
                        if filter[Int(crc & 0xFFFFFF) >> 6] & (1 << (crc & 63)) != 0, let list = full[crc] {
                            let md5 = Array(Insecure.MD5.hash(data: UnsafeRawBufferPointer(start: p + pos, count: L)))
                            let hits = list.filter { $0.md5 == md5 && found[$0.global] == nil }
                            if !hits.isEmpty {
                                for h in hits { found[h.global] = Source(url: url, offset: Int64(pos), length: L) }
                                pos += L
                                guard pos + L <= n else { break }
                                crc = CRC32.checksum(UnsafeRawBufferPointer(start: p + pos, count: L))
                                continue
                            }
                        }
                        guard pos + L < n else { break }
                        crc = roll.slide(crc, out: p[pos], in: p[pos + L])
                        pos += 1
                        steps += 1
                        if steps & 0xFFFFF == 0 { try cancel?.check() }
                    }
                }
            }
        }
        // Short last slices.
        let pad = UnsafeMutableRawPointer.allocate(byteCount: L, alignment: 16)
        defer { pad.deallocate() }
        for s in short {
            var places: [(URL, Int64)] = []
            if let prev = found[s.global - 1] { places.append((prev.url, prev.offset + Int64(L))) }
            for url in Set(files.map(\.url)) {
                if let size = try? FileReader(path: url.path).size, size >= Int64(s.length) { places.append((url, size - Int64(s.length))) }
            }
            for (url, off) in places {
                guard let r = try? FileReader(path: url.path), off >= 0, off + Int64(s.length) <= r.size,
                      (try? r.readSome(at: off, into: pad, count: s.length)) == s.length else { continue }
                memset(pad + s.length, 0, L - s.length)
                let slice = UnsafeRawBufferPointer(start: pad, count: L)
                if CRC32.checksum(slice) == s.crc && Array(Insecure.MD5.hash(data: slice)) == s.md5 {
                    found[s.global] = Source(url: url, offset: off, length: s.length)
                    break
                }
            }
        }
        return found
    }

    /// Solves for the missing slices and writes the repaired files.
    func rebuild(missing: [Int], found: [Int: Source], progress: ProgressHandler?, cancel: CancellationToken?) throws {
        let inputCount = files.reduce(0) { $0 + $1.slices.count }
        let constants = GF16.inputConstants(inputCount)
        let exps = Array(recovery.keys.sorted().prefix(missing.count))
        let m = missing.count
        // A[j][k] = c_{missing k} ^ e_j; invert it.
        var a = (0..<m).map { j in (0..<m).map { k in GF16.pow(constants[missing[k]], exps[j]) } }
        let inv = try GF16.invert(&a)

        // B_j = R_j − Σ_{good i} c_i^{e_j} · S_i (subtraction is XOR).
        var b = try exps.map { e -> [UInt8] in
            let (url, off) = recovery[e]!
            return try FileReader(path: url.path).read(at: off, count: sliceSize)
        }
        let missingSet = Set(missing)
        let tracker = ProgressTracker(totalBytes: Int64(inputCount) * Int64(sliceSize), totalEntries: files.count, handler: progress)
        var batch: [(slice: [UInt8], constant: UInt16)] = []
        var batchBytes = 0
        func flush() throws {
            guard !batch.isEmpty else { return }
            let items = batch
            try b.withUnsafeMutableBufferPointer { bufs in
                let bb = bufs
                try parallelFor(m, workload: .interactive, cancel: cancel) { j in
                    bb[j].withUnsafeMutableBytes { dst in
                        for item in items { item.slice.withUnsafeBytes { GF16.mulAdd(dst, $0, GF16.pow(item.constant, exps[j])) } }
                    }
                }
            }
            batch.removeAll(keepingCapacity: true)
            batchBytes = 0
        }
        // Where each present slice is: in place, or where the search found it.
        var readers: [URL: FileReader] = [:]
        func reader(_ url: URL) -> FileReader? {
            if let r = readers[url] { return r }
            let r = try? FileReader(path: url.path)
            readers[url] = r
            return r
        }
        func read(_ global: Int, _ d: PAR2.FileDesc, _ s: Int, into slice: inout [UInt8]) throws {
            let start = Int64(s) * Int64(sliceSize)
            let n = Int(min(Int64(sliceSize), Int64(d.length) - start))
            let place = found[global] ?? Source(url: d.url, offset: start, length: n)
            guard let r = reader(place.url) else { throw XipperError.corrupt("\(d.name) cannot be read") }
            try slice.withUnsafeMutableBytes { try r.read(at: place.offset, into: $0.baseAddress!, count: n) }
        }
        var global = 0
        for d in files where m > 0 {
            for s in 0..<d.slices.count {
                try cancel?.check()
                defer { global += 1 }
                tracker.add(bytes: Int64(sliceSize))
                guard !missingSet.contains(global), reader(d.url) != nil || found[global] != nil else { continue }
                var slice = [UInt8](repeating: 0, count: sliceSize)
                try read(global, d, s, into: &slice)
                batch.append((slice, constants[global]))
                batchBytes += sliceSize
                if batchBytes >= 32 << 20 { try flush() }
            }
        }
        try flush()
        // S_{missing k} = Σ_j inv[k][j] · B_j.
        var rebuilt: [Int: [UInt8]] = [:]
        for k in 0..<m {
            var s = [UInt8](repeating: 0, count: sliceSize)
            s.withUnsafeMutableBytes { dst in
                for j in 0..<m { b[j].withUnsafeBytes { GF16.mulAdd(dst, $0, inv[k][j]) } }
            }
            rebuilt[missing[k]] = s
        }
        // Write each affected file: a copy with the moved and rebuilt slices, then an atomic
        // replace. All are written before any is replaced: a moved slice may come from another file.
        global = 0
        var outs: [OutputFile] = []
        var slice = [UInt8](repeating: 0, count: sliceSize)
        for d in files {
            let range = global..<(global + d.slices.count)
            global += d.slices.count
            guard range.contains(where: { rebuilt[$0] != nil || found[$0] != nil }) else { continue }
            let out = try OutputFile(path: d.url.path)
            outs.append(out)
            for s in 0..<d.slices.count {
                try cancel?.check()
                let n = Int(min(Int64(sliceSize), Int64(d.length) - Int64(s) * Int64(sliceSize)))
                if let data = rebuilt[range.lowerBound + s] {
                    try data.withUnsafeBytes { try out.write(UnsafeRawBufferPointer(rebasing: $0[..<n])) }
                } else {
                    try read(range.lowerBound + s, d, s, into: &slice)
                    try slice.withUnsafeBytes { try out.write(UnsafeRawBufferPointer(rebasing: $0[..<n])) }
                }
            }
        }
        for out in outs { try out.commit(overwrite: true) }
        tracker.finish()
    }
}

/// CRC-32 (IEEE, as zlib) of a sliding window of fixed length: slide() drops the oldest byte and
/// takes a new one in O(1). The CRC is affine in its input, so the outgoing byte's contribution
/// depends only on that byte and the window length: a 256-entry table built from 9 CRCs.
struct RollingCRC32 {
    private let table: [UInt32]
    private let outgoing: [UInt32]

    init(window: Int) {
        var t = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            t[i] = c
        }
        table = t
        // out[b] = crc(0^L) ^ step(crc(b·0^(L-1)), 0); affine in b, so 0 and the 8 bits suffice.
        var zeros = [UInt8](repeating: 0, count: window)
        let base = CRC32.checksum(zeros)
        func term(_ b: UInt8) -> UInt32 {
            zeros[0] = b
            let c = CRC32.checksum(zeros)
            return base ^ (t[Int(c & 0xFF)] ^ (c >> 8))
        }
        let t0 = term(0)
        let bits = (0..<8).map { term(1 << $0) ^ t0 }
        outgoing = (0..<256).map { b in (0..<8).reduce(t0) { b >> $1 & 1 != 0 ? $0 ^ bits[$1] : $0 } }
    }

    @inline(__always)
    func slide(_ crc: UInt32, out: UInt8, in byte: UInt8) -> UInt32 {
        table.withUnsafeBufferPointer { t in
            outgoing.withUnsafeBufferPointer { o in t[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) ^ o[Int(out)] }
        }
    }
}

/// GF(2^16) with the PAR2 generator polynomial x^16 + x^12 + x^3 + x + 1 (0x1100B).
enum GF16 {
    static let tables: (log: [UInt16], exp: [UInt16]) = {
        var log = [UInt16](repeating: 0, count: 65536), exp = [UInt16](repeating: 0, count: 65536)
        var b: UInt32 = 1
        for l in 0..<65535 {
            exp[l] = UInt16(b)
            log[Int(b)] = UInt16(l)
            b <<= 1
            if b & 0x10000 != 0 { b ^= 0x1100B }
        }
        exp[65535] = exp[0]
        return (log, exp)
    }()

    static func mul(_ a: UInt16, _ b: UInt16) -> UInt16 {
        if a == 0 || b == 0 { return 0 }
        let s = Int(tables.log[Int(a)]) + Int(tables.log[Int(b)])
        return tables.exp[s % 65535]
    }

    static func pow(_ a: UInt16, _ e: Int) -> UInt16 {
        if e == 0 { return 1 }
        if a == 0 { return 0 }
        return tables.exp[(Int(tables.log[Int(a)]) * e) % 65535]
    }

    static func inverse(_ a: UInt16) -> UInt16 { tables.exp[(65535 - Int(tables.log[Int(a)])) % 65535] }

    /// The constants of the first `count` input slices: 2^n for the n coprime with 65535.
    static func inputConstants(_ count: Int) -> [UInt16] {
        var out: [UInt16] = []
        out.reserveCapacity(count)
        var n = 1
        while out.count < count {
            if n % 3 != 0 && n % 5 != 0 && n % 17 != 0 && n % 257 != 0 { out.append(tables.exp[n]) }
            n += 1
        }
        return out
    }

    /// dst ^= factor · src, over little-endian 16-bit words. Regions go through the NEON kernel
    /// (CXipShims/gf16.c: nibble tables and TBL, 64 bytes per step); tiny ones multiply through
    /// log/exp directly, since building the tables would cost more than the region.
    static func mulAdd(_ dst: UnsafeMutableRawBufferPointer, _ src: UnsafeRawBufferPointer, _ factor: UInt16) {
        guard factor != 0 else { return }
        let words = min(dst.count, src.count) / 2
        if words >= 64 {
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 128) { t in
                xs_gf16_tables(factor, t.baseAddress!)
                xs_gf16_muladd(dst.baseAddress!.assumingMemoryBound(to: UInt8.self), src.baseAddress!.assumingMemoryBound(to: UInt8.self),
                               words * 2, t.baseAddress!)
            }
            return
        }
        let d = dst.baseAddress!.assumingMemoryBound(to: UInt16.self)
        let s = src.baseAddress!
        let lf = Int(tables.log[Int(factor)])
        tables.log.withUnsafeBufferPointer { log in
            tables.exp.withUnsafeBufferPointer { exp in
                for i in 0..<words {
                    let w = UInt16(littleEndian: s.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
                    if w == 0 { continue }
                    var l = Int(log[Int(w)]) + lf
                    if l >= 65535 { l -= 65535 }
                    d[i] = (UInt16(littleEndian: d[i]) ^ exp[l]).littleEndian
                }
            }
        }
    }

    /// Inverts a square matrix in place (Gauss-Jordan); throws when it is singular.
    static func invert(_ a: inout [[UInt16]]) throws -> [[UInt16]] {
        let n = a.count
        var inv = (0..<n).map { i in (0..<n).map { UInt16($0 == i ? 1 : 0) } }
        for col in 0..<n {
            guard let pivot = (col..<n).first(where: { a[$0][col] != 0 }) else { throw XipperError.corrupt("PAR2 recovery matrix is singular") }
            a.swapAt(col, pivot); inv.swapAt(col, pivot)
            let p = inverse(a[col][col])
            for k in 0..<n { a[col][k] = mul(a[col][k], p); inv[col][k] = mul(inv[col][k], p) }
            for r in 0..<n where r != col && a[r][col] != 0 {
                let f = a[r][col]
                for k in 0..<n { a[r][k] ^= mul(f, a[col][k]); inv[r][k] ^= mul(f, inv[col][k]) }
            }
        }
        return inv
    }
}
