import Foundation
import Testing
@testable import XipperKit
@testable import XipperMCP

@Suite("MCP genomics tools")
struct Genomics2MCPTests {
    func harness(_ t: TempDir, readOnly: Bool = false) -> MCPHarness {
        var c = MCPConfig()
        c.allowedRoots = [t.path + "/allowed"]
        c.readOnly = readOnly
        c.auditLogPath = nil
        c.workload = .threads(4)
        return MCPHarness(config: c)
    }

    @Test func indexCheckAndManifestTools() throws {
        let t = TempDir()
        t.write("allowed/calls.vcf", richVCF(perContig: 1500))
        t.write("outside/x.txt", "secret")
        _ = run("/bin/sh", ["-c", "/usr/bin/gzip -c '\(t.path)/allowed/calls.vcf' > '\(t.path)/allowed/plain.vcf.gz'"])
        let h = harness(t)
        h.initializeLegacy(elicitation: true)
        let dir = t.path + "/allowed"
        let tools = (h.request("tools/list")["result"]?["tools"]?.array ?? [])
        let index = tools.first { $0["name"]?.string == "genomics_index" }
        #expect(index?["annotations"]?["readOnlyHint"]?.bool == false)
        #expect(tools.first { $0["name"]?.string == "genomics_check" }?["annotations"]?["readOnlyHint"]?.bool == true)

        #expect(h.call("bgzf_compress", ["path": .string(dir + "/calls.vcf")])["isError"]?.bool == false)
        let ix = h.call("genomics_index", ["path": .string(dir + "/calls.vcf.gz")])
        #expect(ix["isError"]?.bool == false, "\(text(ix))")
        #expect(ix["structuredContent"]?["records"]?.int == 4500)
        #expect(FileManager.default.fileExists(atPath: dir + "/calls.vcf.gz.tbi"))
        // Existing index: refused without overwrite, rebuilt after the user's confirmation.
        #expect(h.call("genomics_index", ["path": .string(dir + "/calls.vcf.gz")])["isError"]?.bool == true)
        h.elicitationAnswer.withLock { $0 = ["action": "accept", "content": ["confirm": true]] }
        #expect(h.call("genomics_index", ["path": .string(dir + "/calls.vcf.gz"), "overwrite": true])["isError"]?.bool == false)
        let plain = h.call("genomics_index", ["path": .string(dir + "/plain.vcf.gz")])
        #expect(plain["isError"]?.bool == true && text(plain).contains("bgzf_convert"))

        let check = h.call("genomics_check", ["path": .string(dir + "/calls.vcf.gz")])
        #expect(check["structuredContent"]?["ok"]?.bool == true, "\(text(check))")
        #expect(check["structuredContent"]?["kind"]?.string == "vcf")
        #expect(check["structuredContent"]?["indexes"]?.array?.count == 1)
        let tbi = h.call("genomics_check", ["path": .string(dir + "/calls.vcf.gz.tbi")])
        #expect(tbi["structuredContent"]?["ok"]?.bool == true, "\(text(tbi))")
        #expect(h.call("genomics_check", ["path": .string(t.path + "/outside/x.txt")])["isError"]?.bool == true)

        let mk = h.call("checksum_manifest", ["action": "create", "manifest": .string(dir + "/m.json"),
                                              "sources": .array([.string(dir + "/calls.vcf.gz"), .string(dir + "/calls.vcf.gz.tbi")]),
                                              "algorithms": ["sha256", "md5", "crc32c"]])
        #expect(mk["isError"]?.bool == false, "\(text(mk))")
        let ok = h.call("checksum_manifest", ["action": "verify", "manifest": .string(dir + "/m.json")])
        #expect(ok["structuredContent"]?["ok"]?.bool == true, "\(text(ok))")
        // A manifest pointing outside the allowed folders: refused, and no hint about the file.
        t.write("allowed/evil.sha256", "0000000000000000000000000000000000000000000000000000000000000000  sub/../../outside/x.txt\n")
        t.write("allowed/link.sha256", "0000000000000000000000000000000000000000000000000000000000000000  ln/x.txt\n")
        t.symlink("allowed/ln", to: t.path + "/outside")
        for m in ["evil.sha256", "link.sha256"] {
            let r = h.call("checksum_manifest", ["action": "verify", "manifest": .string(dir + "/" + m)])
            #expect(r["structuredContent"]?["ok"]?.bool == false)
            #expect(r["structuredContent"]?["refused"]?.array?.count == 1, "\(m): \(text(r))")
        }
        // Read-only mode: index creation is hidden, verification still works, create refused.
        let ro = harness(t, readOnly: true)
        ro.initializeLegacy()
        let names = (ro.request("tools/list")["result"]?["tools"]?.array ?? []).compactMap { $0["name"]?.string }
        #expect(!names.contains("genomics_index") && names.contains("checksum_manifest") && names.contains("genomics_check"))
        #expect(ro.call("checksum_manifest", ["action": "verify", "manifest": .string(dir + "/m.json")])["structuredContent"]?["ok"]?.bool == true)
        let roCreate = ro.call("checksum_manifest", ["action": "create", "manifest": .string(dir + "/n.json"), "sources": .array([.string(dir + "/calls.vcf")])])
        #expect(roCreate["isError"]?.bool == true)
    }
    @Test func cramConvertAndAlignmentIndexes() throws {
        let t = TempDir()
        try FileManager.default.createDirectory(atPath: t.path + "/allowed", withIntermediateDirectories: true)
        let sub = TempDir()
        let (bam, ref, recs) = try CRAMTests().dataset(sub, reads: 600)
        for (from, to) in [(bam, "in.bam"), (ref, "ref.fa")] { try FileManager.default.copyItem(at: from, to: t.url("allowed/" + to)) }
        let h = harness(t)
        h.initializeLegacy(elicitation: true)
        let dir = t.path + "/allowed"
        // BAM → CRAM needs the reference; then CRAM → BAM; outside paths refused.
        #expect(h.call("cram_convert", ["path": .string(dir + "/in.bam")])["isError"]?.bool == true)
        let enc = h.call("cram_convert", ["path": .string(dir + "/in.bam"), "reference": .string(dir + "/ref.fa")])
        #expect(enc["isError"]?.bool == false, "\(text(enc))")
        #expect(enc["structuredContent"]?["records"]?.int == recs.count)
        let dec = h.call("cram_convert", ["path": .string(dir + "/in.cram"), "reference": .string(dir + "/ref.fa"), "output": .string(dir + "/back.bam")])
        #expect(dec["isError"]?.bool == false, "\(text(dec))")
        #expect(h.call("cram_convert", ["path": .string(dir + "/in.bam"), "reference": .string(dir + "/ref.fa"),
                                        "output": .string(t.path + "/elsewhere.cram")])["isError"]?.bool == true)
        #expect(h.call("cram_convert", ["path": .string(dir + "/in.bam"), "reference": .string(dir + "/ref.fa")])["isError"]?.bool == true)  // exists
        for (file, kind) in [("in.bam", "bai"), ("in.cram", "crai"), ("ref.fa", "fai")] {
            let r = h.call("genomics_index", ["path": .string(dir + "/" + file)])
            #expect(r["structuredContent"]?["kind"]?.string == kind, "\(file): \(text(r))")
        }
        let ro = harness(t, readOnly: true)
        ro.initializeLegacy()
        #expect(!(ro.request("tools/list")["result"]?["tools"]?.array ?? []).contains { $0["name"]?.string == "cram_convert" })
    }
}
