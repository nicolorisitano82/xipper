import Foundation
import Testing
@testable import XipperKit

/// Names that pretend to be documents: right-to-left override, document extension before an
/// executable one, spaces hiding the real extension.
@Suite("Deceptive names")
struct DeceptiveNameTests {
    static let rlo = "\u{202E}"

    @Test func detectsDisguises() {
        #expect(DeceptiveName.check("fattura\(Self.rlo)fdp.app") == .bidiControl)
        #expect(DeceptiveName.check("doc\u{2067}x.exe") == .bidiControl)
        #expect(DeceptiveName.check("fattura.pdf.app") == .doubleExtension(shown: "pdf", real: "app"))
        #expect(DeceptiveName.check("Foto.JPG.command") == .doubleExtension(shown: "jpg", real: "command"))
        #expect(DeceptiveName.check("invoice.docx.exe") == .doubleExtension(shown: "docx", real: "exe"))
        #expect(DeceptiveName.check("report.pdf                    .app") == .paddedExtension(real: "app"))
    }

    @Test func leavesOrdinaryNamesAlone() {
        for name in ["fattura.pdf", "Xipper.app", "build.sh", "archive.tar.gz", "v1.2.app", "notes.txt.bak",
                     "my.pdf.zip", "script.min.js", "a  b.app", "Read Me.pdf"] {
            #expect(DeceptiveName.check(name) == nil, "\(name)")
        }
    }

    @Test func visibleSpellsOutTheTrick() {
        #expect(DeceptiveName.visible("fattura\(Self.rlo)fdp.app") == "fattura⟨U+202E⟩fdp.app")
        #expect(DeceptiveName.visible("a.pdf          .app") == "a.pdf␣…␣.app")
        #expect(DeceptiveName.visible("a b.txt") == "a b.txt")
    }

    @Test func extractionReportsThemOncePerItem() throws {
        let t = TempDir()
        t.write("src/fattura.pdf.app/Contents/MacOS/run", "x")
        t.write("src/fattura.pdf.app/Contents/Info.plist", "y")
        t.write("src/photo\(Self.rlo)gpj.command", "z")
        t.write("src/ok.txt", "fine")
        var o = CreateOptions()
        o.format = .zip
        try Xipper.create(from: [t.url("src")], to: t.url("a.zip"), options: o)
        t.mkdir("out")
        let r = try Xipper.extract(t.url("a.zip"), to: t.url("out"))
        #expect(r.deceptive.map { ($0 as NSString).lastPathComponent }.sorted() == ["fattura.pdf.app", "photo\(Self.rlo)gpj.command"].sorted())
        #expect(r.files == 4)  // a warning, not a block
    }
}
