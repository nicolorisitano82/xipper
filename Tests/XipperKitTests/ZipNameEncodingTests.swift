import Foundation
import Testing
@testable import XipperKit

/// ZIP names written without the UTF-8 flag in a Windows OEM code page: guessed from all names
/// together, CP437 unless another page is clearly better, and forced by hand when the guess fails.
@Suite("ZIP name code pages")
struct ZipNameEncodingTests {
    /// Stored entries with raw name bytes, no UTF-8 flag, made on MS-DOS (host 0) as Windows does.
    static func build(_ names: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = [], cd: [UInt8] = []
        func u16(_ v: UInt16, _ b: inout [UInt8]) { b += [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func u32(_ v: UInt32, _ b: inout [UInt8]) { for i in 0..<4 { b.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
        for (i, name) in names.enumerated() {
            let data = Array("file \(i)\n".utf8), crc = CRC32.checksum(data), offset = UInt32(out.count)
            u32(0x0403_4B50, &out); u16(20, &out); u16(0, &out); u16(0, &out); u16(0, &out); u16(0x21, &out)
            u32(crc, &out); u32(UInt32(data.count), &out); u32(UInt32(data.count), &out)
            u16(UInt16(name.count), &out); u16(0, &out); out += name; out += data
            u32(0x0201_4B50, &cd); u16(20, &cd); u16(20, &cd); u16(0, &cd); u16(0, &cd); u16(0, &cd); u16(0x21, &cd)
            u32(crc, &cd); u32(UInt32(data.count), &cd); u32(UInt32(data.count), &cd)
            u16(UInt16(name.count), &cd); u16(0, &cd); u16(0, &cd); u16(0, &cd); u16(0, &cd); u32(0x20, &cd); u32(offset, &cd)
            cd += name
        }
        let cdOffset = UInt32(out.count)
        out += cd
        u32(0x0605_4B50, &out); u16(0, &out); u16(0, &out); u16(UInt16(names.count), &out); u16(UInt16(names.count), &out)
        u32(UInt32(cd.count), &out); u32(cdOffset, &out); u16(0, &out)
        return out
    }

    static let samples: [(ZipNameEncoding, [String])] = [
        (.cp437, ["Café ñ.txt", "Ångström/über.doc", "résumé.pdf"]),
        (.cp866, ["Документы/отчёт.doc", "Фото/отпуск.jpg"]),
        (.shiftJIS, ["資料/会議メモ.txt", "写真/夏休み.jpg", "見積書.xlsx", "表計算.xls"]),
        (.gbk, ["文档/报告.docx", "照片/旅行.jpg", "合同.pdf"]),
        (.big5, ["文件/報告.docx", "照片/旅遊.jpg"]),
        (.eucKR, ["문서/보고서.docx", "사진/여행.jpg"]),
    ]

    @Test(arguments: samples.map(\.0).filter { $0 != .eucKR })
    func guessesTheCodePage(page: ZipNameEncoding) throws {
        let names = Self.samples.first { $0.0 == page }!.1
        let t = TempDir()
        let url = URL(fileURLWithPath: t.write("x.zip", Self.build(names.map { Array($0.data(using: page.encoding)!) })))
        #expect(try Xipper.zipNameEncoding(of: url)?.encoding == page)
        let listed = try Xipper.list(url).map(\.path).sorted()
        #expect(listed == names.sorted(), "\(page): \(listed)")
        // "表" is 0x95 0x5C in Shift-JIS: the 0x5C is not a Windows path separator.
        t.mkdir("out")
        let r = try Xipper.extract(url, to: t.url("out"))
        #expect(r.files == names.count)
    }

    /// EUC-KR Hangul has the byte structure of GBK Hanzi: the Mac's language decides a tie.
    @Test func koreanAndChineseTieGoesToThePreferredLanguage() {
        let names = Self.samples.first { $0.0 == .eucKR }!.1.map { Array($0.data(using: ZipNameEncoding.eucKR.encoding)!) }
        #expect(ZipNameEncoding.guess(names, languages: ["ko-KR"]) == .eucKR)
        #expect(ZipNameEncoding.guess(names, languages: ["zh-Hans-CN"]) == .gbk)
        #expect(ZipNameEncoding.guess(names, languages: ["it-IT"]) == .gbk)
    }

    @Test func forcingACodePageOverridesTheGuess() throws {
        let t = TempDir()
        // One short Cyrillic name: too little to beat CP437 by guessing.
        let url = URL(fileURLWithPath: t.write("y.zip", Self.build([Array("Ая.txt".data(using: ZipNameEncoding.cp866.encoding)!)])))
        Xipper.setZipNameEncoding(.cp866, for: url)
        defer { Xipper.setZipNameEncoding(nil, for: url) }
        #expect(try Xipper.list(url).map(\.path) == ["Ая.txt"])
        #expect(try Xipper.zipNameEncoding(of: url).map { ($0.encoding, $0.guessed) } ?? (.cp437, true) == (.cp866, false))
    }

    @Test func unicodeArchivesHaveNoCodePage() throws {
        let t = TempDir()
        t.write("src/città.txt", "x")
        var o = CreateOptions()
        o.format = .zip
        try Xipper.create(from: [t.url("src")], to: t.url("u.zip"), options: o)
        #expect(try Xipper.zipNameEncoding(of: t.url("u.zip")) == nil)
    }
}
