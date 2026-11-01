import Foundation
import Testing
@testable import XipperKit

/// ZIP files that different readers interpret differently ("My ZIP isn't your ZIP", USENIX Security
/// 2025): Xipper refuses each one instead of picking an interpretation, and still reads the
/// legitimate variants next to them.
@Suite("ZIP ambiguities")
struct ZipAmbiguityTests {
    struct Entry {
        var name: String
        var data: [UInt8]
        var cdName: String? = nil      // a different name in the central directory
        var lhSize: UInt32? = nil      // a different size in the local header
        var lhMethod: UInt16? = nil    // a different method in the local header
        var flags: UInt16 = 0
        var cdExtra: [UInt8] = []
        var inDirectory = true         // false: a local header no central entry points to
    }

    /// A stored-only ZIP with knobs on every redundant field.
    static func build(_ entries: [Entry], countDelta: Int = 0, cdTrailing: [UInt8] = [], comment: [UInt8] = [],
                      zip64Count: UInt64? = nil, appended: [UInt8] = []) -> [UInt8] {
        var out: [UInt8] = [], cd: [UInt8] = []
        func u16(_ v: UInt16, _ b: inout [UInt8]) { b += [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func u32(_ v: UInt32, _ b: inout [UInt8]) { for i in 0..<4 { b.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
        func u64(_ v: UInt64, _ b: inout [UInt8]) { for i in 0..<8 { b.append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) } }
        var listed = 0
        for e in entries {
            let offset = UInt32(out.count)
            let crc = CRC32.checksum(e.data)
            let name = Array(e.name.utf8)
            u32(0x0403_4B50, &out); u16(20, &out); u16(e.flags, &out); u16(e.lhMethod ?? 0, &out)
            u16(0, &out); u16(0x21, &out); u32(crc, &out)
            u32(e.lhSize ?? UInt32(e.data.count), &out); u32(e.lhSize ?? UInt32(e.data.count), &out)
            u16(UInt16(name.count), &out); u16(0, &out); out += name; out += e.data
            guard e.inDirectory else { continue }
            listed += 1
            let cdName = Array((e.cdName ?? e.name).utf8)
            u32(0x0201_4B50, &cd); u16(0x031E, &cd); u16(20, &cd); u16(e.flags, &cd); u16(0, &cd)
            u16(0, &cd); u16(0x21, &cd); u32(crc, &cd); u32(UInt32(e.data.count), &cd); u32(UInt32(e.data.count), &cd)
            u16(UInt16(cdName.count), &cd); u16(UInt16(e.cdExtra.count), &cd); u16(0, &cd); u16(0, &cd); u16(0, &cd)
            u32(0o100644 << 16, &cd); u32(offset, &cd); cd += cdName; cd += e.cdExtra
        }
        cd += cdTrailing
        let cdOffset = UInt32(out.count)
        out += cd
        let count = UInt16(listed + countDelta)
        if let zip64Count {
            let recAt = UInt64(out.count)
            u32(0x0606_4B50, &out); u64(44, &out); u16(45, &out); u16(45, &out); u32(0, &out); u32(0, &out)
            u64(zip64Count, &out); u64(zip64Count, &out); u64(UInt64(cd.count), &out); u64(UInt64(cdOffset), &out)
            u32(0x0706_4B50, &out); u32(0, &out); u64(recAt, &out); u32(1, &out)
        }
        u32(0x0605_4B50, &out); u16(0, &out); u16(0, &out); u16(count, &out); u16(count, &out)
        u32(UInt32(cd.count), &out); u32(cdOffset, &out); u16(UInt16(comment.count), &out)
        return out + comment + appended
    }

    static let a = Entry(name: "a.txt", data: Array("first\n".utf8))
    static let b = Entry(name: "b.txt", data: Array("second\n".utf8))

    func open(_ bytes: [UInt8]) throws -> (ZipArchive, TempDir) {
        let t = TempDir()
        let path = t.write("x.zip", bytes)
        return (try ZipArchive(path: path), t)
    }

    func expectAmbiguous(_ bytes: [UInt8], _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let t = TempDir()
        let url = URL(fileURLWithPath: t.write("x.zip", bytes))
        var refused = false
        do {
            let report = try Xipper.test(url)
            refused = !report.isOK && report.failures.contains { $0.reason.contains("ambiguous ZIP") }
        } catch {
            refused = "\(error)".contains("ambiguous ZIP")
        }
        #expect(refused, "\(what) was accepted", sourceLocation: sourceLocation)
    }

    @Test func legitimateVariantsStillRead() throws {
        for (what, bytes) in [("plain", Self.build([Self.a, Self.b])),
                              ("bytes appended after the archive", Self.build([Self.a, Self.b], appended: Array(repeating: 0, count: 100))),
                              ("comment", Self.build([Self.a], comment: Array("hello PK".utf8))),
                              ("consistent ZIP64 record", Self.build([Self.a, Self.b], zip64Count: 2))] {
            let t = TempDir()
            let url = URL(fileURLWithPath: t.write("x.zip", bytes))
            let report = try Xipper.test(url)
            #expect(report.isOK, "\(what): \(report.failures)")
        }
    }

    @Test func localHeaderMustMatchCentralDirectory() {
        var renamed = Self.a; renamed.cdName = "evil.txt"
        expectAmbiguous(Self.build([renamed, Self.b]), "different name in the local header")
        var resized = Self.a; resized.lhSize = 3
        expectAmbiguous(Self.build([resized, Self.b]), "different size in the local header")
        var method = Self.a; method.lhMethod = 8
        expectAmbiguous(Self.build([method, Self.b]), "different method in the local header")
    }

    @Test func endRecordMustBeUnique() {
        // A second, complete end record at the very end of the first one's comment.
        let inner = Array(Self.build([Self.b]).suffix(22))
        expectAmbiguous(Self.build([Self.a, Self.b], comment: inner), "end record hidden in the comment")
    }

    @Test func entryCountMustMatch() {
        expectAmbiguous(Self.build([Self.a, Self.b], countDelta: -1), "count lower than the entries")
        expectAmbiguous(Self.build([Self.a, Self.b], countDelta: 1), "count higher than the entries")
        expectAmbiguous(Self.build([Self.a, Self.b], cdTrailing: Array(repeating: 0x41, count: 60)), "bytes after the last central entry")
        expectAmbiguous(Self.build([Self.a, Self.b], zip64Count: 3), "ZIP64 count disagreeing with the classic one")
    }

    @Test func namesMustBeUnambiguous() {
        var dup = Self.b; dup.name = "a.txt"
        expectAmbiguous(Self.build([Self.a, dup]), "two entries with the same name")
        var nfd = Self.b; nfd.name = "cafe\u{301}.txt"
        var nfc = Self.a; nfc.name = "caf\u{E9}.txt"
        expectAmbiguous(Self.build([nfc, nfd]), "the same name in NFC and NFD")
        var nul = Self.a; nul.name = "a.txt\u{0}.exe"
        expectAmbiguous(Self.build([nul]), "NUL in a name")
        // UTF-8 flag plus an Info-ZIP Unicode name (0x7075) that says something else.
        var two = Self.a; two.flags = Zip.Flag.utf8
        let other = Array("other.txt".utf8)
        var extra: [UInt8] = [0x75, 0x70, UInt8(5 + other.count), 0, 1]
        let crc = CRC32.checksum(Array("a.txt".utf8))
        for i in 0..<4 { extra.append(UInt8((crc >> (8 * UInt32(i))) & 0xFF)) }
        two.cdExtra = extra + other
        expectAmbiguous(Self.build([two]), "UTF-8 name with a different Unicode extra name")
    }

    @Test func hiddenLocalHeaderIsReported() {
        var hidden = Self.a; hidden.name = "hidden.txt"; hidden.inDirectory = false
        expectAmbiguous(Self.build([Self.a, hidden, Self.b]), "local header no entry points to")
    }

    @Test func caseOnlyDifferenceIsNotAmbiguous() throws {
        // Legitimate on Linux; on a case-insensitive volume the extraction keeps both.
        var upper = Self.b; upper.name = "A.txt"
        let t = TempDir()
        let url = URL(fileURLWithPath: t.write("x.zip", Self.build([Self.a, upper])))
        #expect(try Xipper.test(url).isOK)
        t.mkdir("out")
        let r = try Xipper.extract(url, to: t.url("out"))
        #expect(r.files == 2)
    }
}
