import Foundation
@testable import XipperKit

/// Temporary directory removed at deinit.
final class TempDir {
    let path: String
    init() {
        path = NSTemporaryDirectory() + "xipper-test-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }
    func url(_ rel: String) -> URL { URL(fileURLWithPath: path + "/" + rel) }

    @discardableResult
    func write(_ rel: String, _ data: [UInt8], mode: Int = 0o644) -> String {
        let p = path + "/" + rel
        try! FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: p, contents: Data(data), attributes: [.posixPermissions: mode])
        return p
    }
    func write(_ rel: String, _ text: String) { write(rel, Array(text.utf8)) }
    func mkdir(_ rel: String) { try! FileManager.default.createDirectory(atPath: path + "/" + rel, withIntermediateDirectories: true) }
    func symlink(_ rel: String, to target: String) { try! FileManager.default.createSymbolicLink(atPath: path + "/" + rel, withDestinationPath: target) }
}

/// Deterministic mixed-compressibility data: text-like runs and pseudo-random bytes.
func sampleData(_ n: Int, seed: UInt64 = 42) -> [UInt8] {
    var x = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    var out = [UInt8](); out.reserveCapacity(n)
    let words = Array("lorem ipsum dolor sit amet xipper archiver apple silicon ".utf8)
    while out.count < n {
        x ^= x << 13; x ^= x >> 7; x ^= x << 17
        if x % 4 == 0 {
            for _ in 0..<64 where out.count < n { x ^= x << 13; x ^= x >> 7; x ^= x << 17; out.append(UInt8(truncatingIfNeeded: x)) }
        } else {
            let start = Int(x % UInt64(words.count))
            for i in 0..<48 where out.count < n { out.append(words[(start + i) % words.count]) }
        }
    }
    return out
}

struct ToolResult { let status: Int32; let output: String }

@discardableResult
func run(_ tool: String, _ args: [String], stdin: String? = nil, cwd: String? = nil) -> ToolResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    // Tools like 7zz convert non-ASCII passwords through the locale.
    p.environment = ["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "PATH": "/usr/bin:/bin"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    if let stdin {
        let inPipe = Pipe()
        p.standardInput = inPipe
        inPipe.fileHandleForWriting.write(stdin.data(using: .utf8)!)
        try? inPipe.fileHandleForWriting.close()
    }
    try! p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return ToolResult(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
}

func toolExists(_ path: String) -> Bool { FileManager.default.isExecutableFile(atPath: path) }
let sevenZip = ["/opt/homebrew/bin/7zz", "/usr/local/bin/7zz"].first(where: toolExists)

/// Builds a small tree covering the interesting cases.
func makeTree(_ t: TempDir, root: String = "src", bigSize: Int = 9 << 20) {
    t.write("\(root)/readme.txt", "hello xipper\n")
    t.write("\(root)/empty.bin", [])
    t.write("\(root)/data/big.bin", sampleData(bigSize))
    t.write("\(root)/data/small.bin", sampleData(5000, seed: 7))
    t.write("\(root)/data/random.jpg", sampleData(100_000, seed: 3))
    t.write("\(root)/script.sh", Array("#!/bin/sh\necho hi\n".utf8), mode: 0o755)
    t.write("\(root)/città/è unicode ✓.txt", "unicode name\n")
    t.mkdir("\(root)/emptydir")
    t.symlink("\(root)/link-to-readme", to: "readme.txt")
}

/// Recursive tree comparison: names compared in NFC (ditto/Finder may store NFD),
/// file contents, symlink targets and the executable bit.
func treesEqual(_ a: String, _ b: String) -> (Bool, String) {
    func snapshot(_ root: String) -> [String: String] {
        var out: [String: String] = [:]
        let fm = FileManager.default
        func walk(_ path: String, _ rel: String) {
            var st = stat()
            guard lstat(path, &st) == 0 else { return }
            let key = rel.precomposedStringWithCanonicalMapping
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                out[key] = "dir"
                for c in (try? fm.contentsOfDirectory(atPath: path)) ?? [] { walk(path + "/" + c, rel.isEmpty ? c : rel + "/" + c) }
            case S_IFLNK:
                out[key] = "link:" + ((try? fm.destinationOfSymbolicLink(atPath: path)) ?? "?")
            default:
                let data = fm.contents(atPath: path) ?? Data()
                out[key] = "file:\(data.count):\(data.hashValue):x\(st.st_mode & 0o100 != 0)"
            }
        }
        walk(root, "")
        return out
    }
    let sa = snapshot(a), sb = snapshot(b)
    if sa == sb { return (true, "") }
    let keys = Set(sa.keys).union(sb.keys).sorted().filter { sa[$0] != sb[$0] }
    return (false, keys.prefix(10).map { "\($0): \(sa[$0] ?? "missing") vs \(sb[$0] ?? "missing")" }.joined(separator: "\n"))
}
