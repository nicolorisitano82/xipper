import Foundation
import Testing
@testable import XipperKit

@Suite("Windows-compatible names")
struct WindowsNamesTests {
    @Test(arguments: [
        ("a:b.txt", "a_b.txt"), ("why?", "why_"), ("x<y>|z*\"q\\", "x_y__z__q_"), ("tab\there", "tab_here"),
        ("notes.", "notes"), ("trail .. ", "trail"), ("...", "_"), ("CON", "_CON"), ("con.txt", "_con.txt"),
        ("Nul .tar.gz", "_Nul .tar.gz"), ("COM1", "_COM1"), ("lpt²", "_lpt²"), ("COM10", "COM10"), ("CONSOLE", "CONSOLE"),
        ("città.txt", "città.txt"), (" leading", " leading"),
    ])
    func component(_ input: String, _ expected: String) {
        #expect(WindowsNames.component(input) == expected)
    }

    @Test func clashesAndFoldersAreRenamedConsistently() {
        func item(_ name: String, _ kind: ArchiveItem.Kind) -> ArchiveItem {
            ArchiveItem(name: name, sourcePath: "/x/" + name, kind: kind, permissions: 0o644, modified: Date(), uid: 0, gid: 0)
        }
        let (out, renamed) = WindowsNames.apply([
            item("d:1", .directory), item("d:1/f?.txt", .file(size: 1)), item("d_1", .directory),
            item("d_1/F.txt", .file(size: 1)), item("d_1/f.txt", .file(size: 1)), item("link", .symlink(target: "../d:1/f?.txt")),
        ])
        // d_1 is valid, so it keeps its name and d:1 moves aside; f.txt clashes with F.txt only in case.
        #expect(out.map(\.name) == ["d_1 2", "d_1 2/f_.txt", "d_1", "d_1/F.txt", "d_1/f 2.txt", "link"])
        #expect(out[5].kind == .symlink(target: "../d_1/f_.txt"))
        #expect(renamed == 3)
    }

    @Test(arguments: [ArchiveFormat.zip, .sevenZip])
    func createdArchivesHoldOnlyWindowsNames(_ format: ArchiveFormat) throws {
        let t = TempDir()
        t.write("src/report: final?.txt", "a")
        t.write("src/a_b/x.txt", "b")
        t.write("src/a:b/x.txt", "c")
        t.write("src/AUX.md", "d")
        t.write("src/ok.txt", "e")
        var o = CreateOptions()
        o.format = format
        o.windowsCompatibleNames = true
        let archive = t.url("out." + format.fileExtension)
        let r = try Xipper.create(from: [t.url("src")], to: archive, options: o)
        #expect(r.renamedForWindows == 4)  // report, a:b (folder and its file), AUX; a_b keeps its name
        let names = try Xipper.list(archive).map(\.path).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        #expect(Set(names) == ["src", "src/report_ final_.txt", "src/a_b", "src/a_b/x.txt", "src/a_b 2", "src/a_b 2/x.txt",
                               "src/_AUX.md", "src/ok.txt"])
        // Content follows the renamed entries.
        t.mkdir("x")
        _ = try Xipper.extract(archive, to: t.url("x"))
        #expect(try String(contentsOf: t.url("x/src/a_b 2/x.txt"), encoding: .utf8) == "c")
        #expect(try String(contentsOf: t.url("x/src/a_b/x.txt"), encoding: .utf8) == "b")
    }

    @Test func offByDefault() throws {
        let t = TempDir()
        t.write("src/a:b.txt", "a")
        let r = try Xipper.create(from: [t.url("src")], to: t.url("out.zip"))
        #expect(r.renamedForWindows == 0)
        #expect(try Xipper.list(t.url("out.zip")).contains { $0.path == "src/a:b.txt" })
    }
}
