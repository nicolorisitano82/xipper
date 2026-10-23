import Foundation
import Testing

/// The `xipper` binary itself (built by `swift build`; skipped when it is not there).
@Suite("CLI")
struct CLITests {
    static let exe: String? = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return [".build/debug/xipper", ".build/arm64-apple-macosx/debug/xipper", ".build/release/xipper"]
            .map { root.path + "/" + $0 }.first(where: toolExists)
    }()

    /// Regression: the SIGINT handler built in main.swift was isolated to the main actor and
    /// trapped on its dispatch queue, so Ctrl-C crashed instead of cancelling (and a mounted
    /// volume was left behind unsaved).
    @Test(.enabled(if: exe != nil), .timeLimit(.minutes(1)))
    func ctrlCCancelsCleanly() throws {
        let t = TempDir()
        t.write("big.bin", sampleData(64 << 20, seed: 11))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.exe!)
        p.arguments = ["create", "-q", "-l", "9", "-f", "tar.xz", t.path + "/out.tar.xz", t.path + "/big.bin"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        Thread.sleep(forTimeInterval: 0.8)
        kill(p.processIdentifier, SIGINT)
        p.waitUntilExit()
        #expect(p.terminationReason == .exit && p.terminationStatus == 130, "\(p.terminationReason.rawValue) \(p.terminationStatus)")
        let left = try FileManager.default.contentsOfDirectory(atPath: t.path).filter { $0.contains("out.tar.xz") }
        #expect(left.isEmpty, "\(left)")
    }
}
