import Foundation
import Synchronization
import Testing
@testable import XipperKit

@Suite("Extraction conflicts and layout")
struct ConflictTests {
    func archive(_ t: TempDir) throws -> URL {
        t.write("src/a.txt", "new a")
        t.write("src/sub/b.txt", "new b")
        t.write("src/sub/deep/c.txt", "new c")
        let zip = t.url("src.zip")
        try Xipper.create(from: [t.url("src")], to: zip)
        return zip
    }

    @Test func askDecidesPerFile() throws {
        let t = TempDir()
        let zip = try archive(t)
        t.write("dest/src/a.txt", "old a")
        t.write("dest/src/sub/b.txt", "old b")
        #expect(try Set(Xipper.plannedConflicts(zip, into: t.url("dest"))) == ["src/a.txt", "src/sub/b.txt"])
        let seen = Mutex<[String]>([])
        var o = ExtractOptions()
        o.overwrite = .ask
        o.workload = .threads(1)
        o.conflictHandler = { c in
            seen.withLock { $0.append(c.entry) }
            #expect(c.diskSize == 5 && c.archiveSize == 5)
            return ConflictResolution(c.entry == "src/a.txt" ? .keepBoth : .replace)
        }
        try Xipper.extract(zip, to: t.url("dest"), mode: .into, options: o)
        #expect(seen.withLock { $0.sorted() } == ["src/a.txt", "src/sub/b.txt"])
        func read(_ p: String) -> String? { (try? String(contentsOfFile: t.path + "/dest/" + p, encoding: .utf8)) }
        #expect(read("src/a.txt") == "old a")
        #expect(read("src/a 2.txt") == "new a")
        #expect(read("src/sub/b.txt") == "new b")
        #expect(read("src/sub/deep/c.txt") == "new c")
    }

    @Test func applyToAllAsksOnce() throws {
        let t = TempDir()
        let zip = try archive(t)
        for p in ["a.txt", "sub/b.txt", "sub/deep/c.txt"] { t.write("dest/src/" + p, "old") }
        let calls = Mutex(0)
        var o = ExtractOptions()
        o.overwrite = .ask
        o.conflictHandler = { _ in
            calls.withLock { $0 += 1 }
            return ConflictResolution(.skip, applyToAll: true)
        }
        let r = try Xipper.extract(zip, to: t.url("dest"), mode: .into, options: o)
        #expect(calls.withLock { $0 } == 1)
        #expect(r.skipped.count == 3)
        #expect((try? String(contentsOfFile: t.path + "/dest/src/a.txt", encoding: .utf8)) == "old")
    }

    @Test func flattenPutsFilesInDestination() throws {
        let t = TempDir()
        let zip = try archive(t)
        t.mkdir("flat")
        var o = ExtractOptions()
        o.flatten = true
        try Xipper.extract(zip, to: t.url("flat"), mode: .into, options: o)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: t.path + "/flat")) == ["a.txt", "b.txt", "c.txt"])
        // Same for tar.
        var c = CreateOptions()
        c.format = .tarZstd
        try Xipper.create(from: [t.url("src")], to: t.url("src.tar.zst"), options: c)
        t.mkdir("flat2")
        try Xipper.extract(t.url("src.tar.zst"), to: t.url("flat2"), mode: .into, options: o)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: t.path + "/flat2")) == ["a.txt", "b.txt", "c.txt"])
        #expect(try Xipper.plannedConflicts(zip, into: t.url("flat"), flatten: true).count == 3)
    }
}
