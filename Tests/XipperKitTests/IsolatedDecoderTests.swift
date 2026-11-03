import Foundation
import Synchronization
import Testing
@testable import XipperKit

/// RAR archives are read in the `xipper-decoder` helper process (IsolatedDecoder.swift): same
/// entries, data and errors as libarchive in process, and a crashing decoder is a damaged archive.
@Suite("Isolated decoders")
struct IsolatedDecoderTests {
    struct Item: Equatable { var entry: ArchiveEntry; var data: [UInt8]? }

    /// Every entry with its data (nil when reading it fails), and the error that ended the stream.
    func drain(_ r: EntryStreamReader) -> ([Item], String?) {
        var out: [Item] = []
        do {
            while let e = try r.next() {
                var d: [UInt8]? = []
                do { try r.readData(cancel: nil) { d!.append(contentsOf: $0) } } catch { d = nil; return (out + [Item(entry: e.entry, data: d)], "\(error)") }
                out.append(Item(entry: e.entry, data: d))
            }
            return (out, nil)
        } catch { return (out, "\(error)") }
    }

    func isolated(_ name: String, password: String? = nil) throws -> IsolatedEntryReader {
        let path = RarTests.url(name).path
        return try IsolatedEntryReader(helper: try #require(IsolatedDecoder.helperPath), volumes: RarReader.volumes(for: path),
                                       name: name, password: password)
    }

    @Test func helperIsUsed() throws {
        #expect(IsolatedDecoder.isAvailable)
        #expect(try IsolatedDecoder.rar(path: RarTests.url("rar_unicode.rar").path, password: nil) is IsolatedEntryReader)
    }

    @Test(arguments: [("rar_compress_normal.rar", nil), ("rar5_multiple_files_solid.rar", nil), ("rar_unicode.rar", nil),
                      ("rar5_blake2.rar", nil), ("rar5_compressed.rar", nil), ("rar_filter.rar", nil), ("rar5_arm.rar", nil),
                      ("rar_subblock.rar", nil), ("rar5_multiarchive.part03.rar", nil), ("rar5_bad_tables.rar", nil),
                      ("rar5_encrypted.rar", nil), ("rar5_encrypted.rar", "password"), ("rar5_solid_encrypted.rar", "password"),
                      ("rar5_solid_encrypted_filenames.rar", "password"), ("rar5_solid_encrypted_filenames.rar", "wrong"),
                      ("rar5_encrypted_filenames.rar", nil)] as [(String, String?)])
    func sameAsInProcess(name: String, password: String?) throws {
        let path = RarTests.url(name).path
        let inProcess: ([Item], String?)
        do { inProcess = drain(try RarReader(path: path, password: password)) } catch { inProcess = ([], "\(error)") }
        let outside: ([Item], String?)
        do { outside = drain(try isolated(name, password: password)) } catch { outside = ([], "\(error)") }
        #expect(outside.0 == inProcess.0)
        #expect(outside.1 == inProcess.1)
    }

    /// Entries listed without reading their data: nothing is decoded, encrypted ones included.
    @Test(arguments: [("rar5_encrypted.rar", nil), ("rar5_solid_encrypted.rar", nil), ("rar5_solid_encrypted.rar", "password"),
                      ("rar5_multiarchive.part01.rar", nil), ("rar_compress_normal.rar", nil)] as [(String, String?)])
    func headersOnlyAsInProcess(name: String, password: String?) throws {
        func headers(_ r: EntryStreamReader) throws -> [ArchiveEntry] {
            var out: [ArchiveEntry] = []
            while let e = try r.next() { out.append(e.entry) }
            return out
        }
        let path = RarTests.url(name).path
        #expect(try headers(try isolated(name, password: password)) == headers(try RarReader(path: path, password: password)))
        // Reading only some entries' data, as readEntry does.
        let r = try isolated(name, password: password)
        var i = 0
        while let e = try r.next() {
            defer { i += 1 }
            if i % 2 == 1, !e.entry.isEncrypted || password != nil { try r.readData(cancel: nil) { _ in } }
        }
    }

    @Test func skippedDataAndEarlyStop() throws {
        // Headers only: the data the caller does not read is dropped in order.
        let r = try isolated("rar5_multiple_files_solid.rar")
        var names: [String] = []
        while let e = try r.next() { names.append(e.entry.path) }
        #expect(names == (try Xipper.list(RarTests.url("rar5_multiple_files_solid.rar")).map(\.path)))
        // A sink that stops mid-entry ends the conversation: later calls fail, nothing hangs.
        let s = try isolated("rar5_multiple_files_solid.rar")
        while let e = try s.next(), e.entry.kind != .file {}
        struct Stop: Error {}
        #expect(throws: Stop.self) { try s.readData(cancel: nil) { _ in throw Stop() } }
        #expect(throws: XipperError.self) { _ = try s.next() }
        // readEntry stops early on purpose (maxBytes): through the helper too.
        let big = try #require(Xipper.list(RarTests.url("rar5_compressed.rar")).filter { $0.kind == .file }.max { $0.uncompressedSize < $1.uncompressedSize })
        #expect(try Xipper.readEntry(RarTests.url("rar5_compressed.rar"), path: big.path, maxBytes: 10).data.count == min(10, Int(big.uncompressedSize)))
    }

    @Test func crashingDecoderIsADamagedArchive() throws {
        let r = try isolated("rar_unicode.rar")
        _ = try r.next()
        try r.crashHelper()
        do {
            _ = try r.next()
            Issue.record("no error after the helper crashed")
        } catch let XipperError.corrupt(m) {
            #expect(m.contains("rar_unicode.rar") && m.contains("crashed"), "\(m)")
        }
        // The next archive gets a fresh helper.
        #expect(try Xipper.test(RarTests.url("rar_unicode.rar")).isOK)
    }

    @Test func manyReadersInParallel() throws {
        let archive = RarTests.url("rar5_multiple_files_solid.rar")
        let expected = try Xipper.list(archive)
        let failures = Mutex<Int>(0)
        DispatchQueue.concurrentPerform(iterations: 24) { _ in
            if (try? Xipper.test(archive).isOK) != true || (try? Xipper.list(archive)) != expected { failures.withLock { $0 += 1 } }
        }
        #expect(failures.withLock { $0 } == 0)
    }
}
