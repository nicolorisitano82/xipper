import Foundation
import Testing
@testable import XipperKit

/// «Copia come comando»: the command line does what the app's job does.
@Suite("Copy as command")
struct ShellCommandTests {
    @Test func quoting() {
        #expect(ShellCommand.quote("a/b-c_1.zip") == "a/b-c_1.zip")
        #expect(ShellCommand.quote("Le mie foto") == "'Le mie foto'")
        #expect(ShellCommand.quote("l'archivio $HOME") == "'l'\\''archivio $HOME'")
        #expect(ShellCommand.quote("") == "''")
    }

    @Test func passwordsNeverAppear() {
        var o = CreateOptions()
        o.format = .sevenZip
        o.password = "segretissimo"
        o.encryptFileNames = false
        let c = ShellCommand.create([URL(fileURLWithPath: "/tmp/src")], to: URL(fileURLWithPath: "/tmp/a.7z"), options: o)
        #expect(!c.line().contains("segretissimo"))
        #expect(c.arguments.contains("-p") && c.arguments.contains("--plain-names"))
        var x = ExtractOptions()
        x.password = "segretissimo"
        #expect(!ShellCommand.extract(URL(fileURLWithPath: "/tmp/a.7z"), to: nil, mode: .smart, options: x).line().contains("segretissimo"))
    }

    @Test func whatTheCommandLineCannotSayIsNoted() {
        var x = ExtractOptions()
        x.overwrite = .ask
        x.symlinks = .skipAll
        x.limits.maxCompressionRatio = 100
        let c = ShellCommand.extract(URL(fileURLWithPath: "/tmp/a.zip"), to: nil, mode: .smart, options: x)
        #expect(c.notes.count == 3)
        // Windows names apply to ZIP and 7z only: the CLI refuses them elsewhere.
        var o = CreateOptions()
        o.format = .tarZstd
        o.windowsCompatibleNames = true
        #expect(!ShellCommand.create([], to: URL(fileURLWithPath: "/tmp/a.tar.zst"), options: o).arguments.contains("--windows-names"))
    }

    /// Runs `line` through /bin/sh with the built CLI.
    func shell(_ line: String, cwd: String) -> ToolResult { run("/bin/sh", ["-c", line], cwd: cwd) }

    @Test(.enabled(if: CLITests.exe != nil))
    func createCommandsMakeTheSameArchive() throws {
        let t = TempDir()
        makeTree(t, root: "le mie cose", bigSize: 1 << 20)
        var o = CreateOptions()
        o.format = .zip
        o.zipMethod = .zstd
        o.level = 9
        o.windowsCompatibleNames = true
        o.storeAlreadyCompressed = false
        let target = t.url("nuovo archivio.dat")  // the name does not say the format: -f is needed
        let c = ShellCommand.create([t.url("le mie cose")], to: target, options: o, recoveryPercent: 5)
        let r = shell(c.line(executable: CLITests.exe!), cwd: t.path)
        #expect(r.status == 0, "\(r.output)")
        let z = try ZipArchive(path: target.path)
        #expect(z.records.first { $0.entry.path.hasSuffix("data/big.bin") }?.method == Zip.Method.zstd.rawValue)
        #expect(z.records.contains { $0.entry.path.hasPrefix("le mie cose/") })
        #expect(FileManager.default.fileExists(atPath: target.path + ".par2"))
    }

    @Test(.enabled(if: CLITests.exe != nil))
    func xizRecoveryGoesInsideTheArchive() throws {
        let t = TempDir()
        makeTree(t, root: "src", bigSize: 1 << 20)
        var o = CreateOptions()
        o.format = .xiz
        let target = t.url("a.xiz")
        let c = ShellCommand.create([t.url("src")], to: target, options: o, recoveryPercent: 15)
        #expect(c.line(executable: "xipper").contains("--recovery 15"))
        #expect(!c.line(executable: "xipper").contains("par2"))
        let r = shell(c.line(executable: CLITests.exe!), cwd: t.path)
        #expect(r.status == 0, "\(r.output)")
        #expect(Xipper.xizRecoveryInfo(target).map { abs($0.redundancy - 15) < 1 } == true)
        let s = shell("\"\(CLITests.exe!)\" scrub a.xiz", cwd: t.path)
        #expect(s.status == 0 && s.output.contains("all bytes intact"), "\(s.output)")
    }

    @Test(.enabled(if: CLITests.exe != nil))
    func extractAndConvertCommands() throws {
        let t = TempDir()
        makeTree(t, bigSize: 1 << 20)
        try Xipper.create(from: [t.url("src")], to: t.url("a.zip"), options: CreateOptions())
        var x = ExtractOptions()
        x.flatten = true
        x.selection = ["src/readme.txt", "src/data/small.bin"]
        t.mkdir("dest folder")
        let e = ShellCommand.extract(t.url("a.zip"), to: t.url("dest folder"), mode: .into, options: x)
        #expect(shell(e.line(executable: CLITests.exe!), cwd: t.path).status == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.path + "/dest folder").sorted() == ["readme.txt", "small.bin"])

        var o = CreateOptions()
        o.format = .tarZstd
        let c = ShellCommand.convert(t.url("a.zip"), to: t.url("b.tar.zst"), options: o, password: false, trashOriginal: false)
        #expect(shell(c.line(executable: CLITests.exe!), cwd: t.path).status == 0)
        #expect(try ArchiveFormat.detect(t.url("b.tar.zst")) == .tarZstd)
    }
}
