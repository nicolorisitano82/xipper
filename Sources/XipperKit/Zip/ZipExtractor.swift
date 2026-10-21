import CryptoKit
import Foundation
import Synchronization

enum ZipExtractor {
    static func selected(_ archive: ZipArchive, _ selection: Set<String>?) -> [ZipEntryRecord] {
        guard let selection, !selection.isEmpty else { return archive.records }
        return archive.records.filter { r in
            selection.contains(r.entry.path) || selection.contains { r.entry.path.hasPrefix($0 + "/") }
        }
    }

    /// Refuses archives that break the safety limits before anything is written.
    static func precheck(_ records: [ZipEntryRecord], limits: ExtractionLimits, password: [UInt8]?) throws {
        if records.count > limits.maxEntries {
            throw XipperError.limitExceeded("\(records.count) entries (limit \(limits.maxEntries))")
        }
        for r in records where r.entry.kind == .file && r.uncompressedSize > limits.ratioCheckThreshold {
            let ratio = Double(r.uncompressedSize) / Double(max(r.compressedSize, 1))
            if ratio > limits.maxCompressionRatio {
                throw XipperError.limitExceeded("\(r.entry.path) expands \(Int(ratio))× (possible zip bomb)")
            }
        }
        if password == nil, let enc = records.first(where: { $0.entry.isEncrypted && $0.entry.kind == .file }) {
            throw XipperError.passwordRequired(entry: enc.entry.path)
        }
    }

    static func extract(_ archive: ZipArchive, ctx: ExtractionContext, password: [UInt8]?,
                        tracker: ProgressTracker, cancel: CancellationToken?) throws {
        let records = selected(archive, ctx.options.selection)
        try precheck(records, limits: ctx.options.limits, password: password)
        let declared = records.reduce(Int64(0)) { $0 + ($1.entry.kind == .file ? $1.uncompressedSize : 0) }
        // Fail before writing anything when the content cannot fit.
        if declared > ctx.maxBytes && !ctx.options.limits.stopAtLimit { throw ctx.overLimit(needed: declared) }
        tracker.setTotals(bytes: declared, entries: records.count)

        var files: [(ZipEntryRecord, [String])] = []
        for r in records {
            guard let full = ctx.sanitize(r.entry.path) else { continue }
            if ctx.options.flatten && r.entry.kind == .directory { continue }
            let comps = ctx.layout(full)
            switch r.entry.kind {
            case .directory:
                do { try ctx.makeDirectory(comps, permissions: r.entry.permissions, modified: r.entry.modified) } catch let XipperError.unsafeEntry(e, reason) {
                    ctx.skip(e, reason, .throughSymlink)
                }
                tracker.add(bytes: 0, entries: 1)
            case .symlink:
                var target: [UInt8] = []
                if r.uncompressedSize > 4096 { ctx.skip(r.entry.path, "symlink target too long", .invalidName); continue }
                try ZipEntryDecoder.decode(r, in: archive, password: password, cancel: cancel) { target.append(contentsOf: $0) }
                ctx.addSymlink(comps, target: String(decoding: target, as: UTF8.self), modified: r.entry.modified)
                tracker.add(bytes: 0, entries: 1)
            case .file, .hardlink:
                files.append((r, comps))
            }
        }
        // Big entries first for load balance; files under 1 MiB keep archive order, which keeps
        // consecutive creations in the same folder (cheaper for APFS and Endpoint Security agents).
        files = files.enumerated().sorted { a, b in
            let sa = a.element.0.uncompressedSize >> 20, sb = b.element.0.uncompressedSize >> 20
            return sa != sb ? sa > sb : a.offset < b.offset
        }.map(\.element)
        // File creation is latency-bound (kernel, APFS, Endpoint Security), so oversubscribe 2×.
        let ioWorkload: Workload = ctx.options.workload == .background ? .background : .threads(ctx.options.workload.workerCount * 2)
        try parallelFor(files.count, workload: ioWorkload, cancel: cancel) { i in
            let (r, comps) = files[i]
            do {
                try ctx.writeFile(comps, permissions: r.entry.permissions, modified: r.entry.modified,
                                  declaredSize: r.uncompressedSize) { sink in
                    try ZipEntryDecoder.decode(r, in: archive, password: password, cancel: cancel) { chunk in
                        try sink(chunk)
                        tracker.add(bytes: Int64(chunk.count))
                    }
                }
            } catch let XipperError.unsafeEntry(e, reason) {
                ctx.skip(e, reason, .throughSymlink)
            }
            tracker.add(bytes: 0, entries: 1, current: r.entry.path)
        }
        try ctx.finalize()
    }

    /// Decodes every entry without writing; returns the entries that failed and why.
    static func test(_ archive: ZipArchive, password: [UInt8]?, workload: Workload,
                     tracker: ProgressTracker, digests: DigestCollector? = nil, cancel: CancellationToken?) throws -> [SkippedEntry] {
        let records = archive.records.filter { $0.entry.kind != .directory }
            .sorted { $0.uncompressedSize > $1.uncompressedSize }
        tracker.setTotals(bytes: records.reduce(0) { $0 + $1.uncompressedSize }, entries: archive.records.count)
        let failures = Mutex<[SkippedEntry]>([])
        try parallelFor(records.count, workload: workload, cancel: cancel) { i in
            let r = records[i]
            do {
                var hasher = digests != nil && r.entry.kind == .file ? SHA256() : nil
                try ZipEntryDecoder.decode(r, in: archive, password: password, cancel: cancel) { chunk in
                    hasher?.update(bufferPointer: chunk)
                    tracker.add(bytes: Int64(chunk.count))
                }
                if let hasher { digests?.add(r.entry.path, hasher) }
            } catch XipperError.cancelled {
                throw XipperError.cancelled
            } catch let e as XipperError {
                failures.withLock { $0.append(SkippedEntry(path: r.entry.path, error: e)) }
            }
            tracker.add(bytes: 0, entries: 1, current: r.entry.path)
        }
        return failures.withLock { $0 }.sorted { $0.path < $1.path }
    }
}
