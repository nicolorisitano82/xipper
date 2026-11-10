import Foundation
import Testing
@testable import XipperKit

/// Versions of an XIZ archive (§11: each appended segment is a version) and updates from a folder.
@Suite("XIZ versions and updates")
struct XizVersionsTests {
    func files(_ a: URL, password: String? = nil) throws -> [String: String] {
        var out: [String: String] = [:]
        for e in try Xipper.list(a, password: password) where e.kind == .file {
            out[e.path] = String(decoding: try Xipper.readEntry(a, path: e.path, password: password, maxBytes: 1 << 20).data, as: UTF8.self)
        }
        return out
    }

    /// Sets a file's modification time `seconds` in the past (updates compare times to the second).
    func age(_ path: String, _ seconds: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: path)
    }

    @Test func updatesMakeVersions() throws {
        let t = TempDir()
        t.write("p/a.txt", "uno\n")
        t.write("p/doc/b.txt", "due\n")
        t.write("p/big.bin", sampleData(2 << 20, seed: 9))
        try age(t.path + "/p/a.txt", 100)
        var o = CreateOptions()
        o.format = .xiz
        let a = t.url("p.xiz")
        _ = try Xipper.create(from: [t.url("p")], to: a, options: o)
        #expect(try Xipper.updatePlan(a, from: [t.url("p")]).isEmpty)
        let size1 = try FileReader(path: a.path).size

        t.write("p/a.txt", "uno, cambiato\n")
        t.write("p/c.txt", "nuovo\n")
        try FileManager.default.removeItem(atPath: t.path + "/p/doc")
        let plan = try Xipper.updatePlan(a, from: [t.url("p")])
        #expect(plan.added == ["p/c.txt"] && plan.changed == ["p/a.txt"] && plan.removed == ["p/doc"])
        let (_, report) = try Xipper.update(a, from: [t.url("p")])
        #expect(report != nil)
        #expect(try Xipper.updatePlan(a, from: [t.url("p")]).isEmpty)
        // The big file did not change: the new version stores only the small ones.
        #expect(try FileReader(path: a.path).size - size1 < 64 << 10)

        let versions = try Xipper.xizVersions(a)
        let size2 = try FileReader(path: a.path).size
        #expect(versions.count == 2 && versions[0].size == size1 && versions[1].size == size2)
        #expect(versions[0].entries == 5 && versions[1].entries == 4)  // p, p/a, p/doc, p/doc/b, p/big → p, a, big, c
        #expect(versions[1].added == 1 && versions[1].changed == 1 && versions[1].removed == 1)

        // Version 1 as an archive of its own: the files as they were.
        let v1 = t.url("v1.xiz")
        try Xipper.xizVersion(a, number: 1, to: v1)
        #expect(try files(v1)["p/a.txt"] == "uno\n" && files(v1)["p/doc/b.txt"] == "due\n")
        #expect(try Xipper.test(v1).isOK)
        #expect(try files(a)["p/a.txt"] == "uno, cambiato\n" && files(a)["p/doc/b.txt"] == nil)
        #expect(try Xipper.withXizVersion(a, number: 1) { try Xipper.list($0).count } == 5)
        #expect(throws: XipperError.self) { try Xipper.xizVersion(a, number: 3, to: t.url("v3.xiz")) }

        // A recovery record after the last footer does not hide the versions.
        _ = try Xipper.addXizRecovery(a, redundancy: 5)
        #expect(try Xipper.xizVersions(a).map(\.size) == versions.map(\.size))
        #expect(try Xipper.withXizVersion(a, number: 2) { try Xipper.test($0).isOK })
    }

    @Test func encryptedAndSignedVersions() throws {
        let t = TempDir()
        t.write("p/a.txt", "uno\n")
        try age(t.path + "/p/a.txt", 100)
        var o = CreateOptions()
        o.format = .xiz
        o.password = "segreto"
        o.xizKDF = .minimum
        o.xizSigner = XizSigner(key: XizSigningKey(), label: "Laboratorio")
        let a = t.url("p.xiz")
        _ = try Xipper.create(from: [t.url("p")], to: a, options: o)
        t.write("p/b.txt", "due\n")
        var e = CreateOptions()
        e.xizSigner = o.xizSigner
        try Xipper.update(a, from: [t.url("p")], password: "segreto", options: e)

        let closed = try Xipper.xizVersions(a)  // no password: counts and signatures only
        #expect(closed.count == 2 && closed[1].added == nil)
        #expect(closed.allSatisfy { $0.signer == "Laboratorio" && $0.date != nil })
        let open = try Xipper.xizVersions(a, password: "segreto")
        #expect(open[1].added == 1 && open[1].changed == 0 && open[1].removed == 0)
        #expect(try Xipper.withXizVersion(a, number: 1) { try Xipper.list($0, password: "segreto").map(\.path) }.contains("p/b.txt") == false)
        #expect(try Xipper.withXizVersion(a, number: 1) { try Xipper.xizHistory($0).count } == 1)
    }

    @Test func updatePlanKinds() throws {
        let t = TempDir()
        t.write("p/x/inside.txt", "a\n")
        t.write("p/y.txt", "b\n")
        try FileManager.default.createSymbolicLink(atPath: t.path + "/p/l", withDestinationPath: "y.txt")
        var o = CreateOptions()
        o.format = .zip  // updates work on every editable format
        let a = t.url("p.zip")
        _ = try Xipper.create(from: [t.url("p")], to: a, options: o)
        // A folder becomes a file, a file becomes a folder, a link changes target.
        try FileManager.default.removeItem(atPath: t.path + "/p/x")
        t.write("p/x", "now a file\n")
        try FileManager.default.removeItem(atPath: t.path + "/p/y.txt")
        t.write("p/y.txt/z.txt", "now a folder\n")
        try FileManager.default.removeItem(atPath: t.path + "/p/l")
        try FileManager.default.createSymbolicLink(atPath: t.path + "/p/l", withDestinationPath: "x")
        try Xipper.update(a, from: [t.url("p")])
        #expect(try Xipper.updatePlan(a, from: [t.url("p")]).isEmpty)
        let entries = Dictionary(uniqueKeysWithValues: try Xipper.list(a).map { ($0.path.hasSuffix("/") ? String($0.path.dropLast()) : $0.path, $0) })
        #expect(entries["p/x"]?.kind == .file && entries["p/y.txt"]?.kind == .directory && entries["p/y.txt/z.txt"] != nil)
        #expect(entries["p/l"]?.kind == .symlink && entries["p/x/inside.txt"] == nil)
        #expect(try Xipper.readEntry(a, path: "p/l").data == Array("x".utf8))
    }
}
