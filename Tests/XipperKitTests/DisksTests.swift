import CryptoKit
import Foundation
import Testing
@testable import ForensicKit
@testable import XipperKit

/// Real disks, through a disk image attached with hdiutil (the user's own device: no helper needed).
/// Attaching disks is slow and visible to the system, so these run only with XIPPER_DISK_TESTS=1.
@Suite("Disks", .enabled(if: ProcessInfo.processInfo.environment["XIPPER_DISK_TESTS"] == "1"), .serialized)
struct DisksTests {
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        if p.terminationStatus != 0 { throw XipperError.invalidArgument("\(tool) \(args.joined(separator: " ")): \(text)") }
        return text
    }

    /// A 16 MiB FAT disk image attached without mounting; returns its whole disk (diskN).
    static func attach(_ t: TempDir) throws -> String {
        let img = t.path + "/d.dmg"
        _ = try run("/usr/bin/hdiutil", ["create", "-size", "16m", "-fs", "MS-DOS FAT16", "-volname", "XF", "-layout", "MBRSPUD", img, "-quiet"])
        let out = try run("/usr/bin/hdiutil", ["attach", "-nomount", img])
        guard let first = out.split(separator: "\n").first(where: { $0.hasPrefix("/dev/disk") }),
              let dev = first.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else { throw XipperError.corrupt(out) }
        return String(dev.dropFirst(5))
    }

    static func detach(_ disk: String) { _ = try? run("/usr/bin/hdiutil", ["detach", "-force", disk]) }

    @Test func listsBlocksMountsAndReads() async throws {
        let t = TempDir()
        let disk = try Self.attach(t)
        defer { Self.detach(disk) }
        let (whole, target) = try #require(Disks.find(disk + "s1"))
        #expect(whole.bsd == disk && target.bsd == disk + "s1" && !target.whole && target.offset > 0)
        #expect(whole.isDiskImage && !whole.isBoot)
        #expect(Disks.wholeDisk(of: disk + "s1") == disk)
        #expect(Disks.refusals(whole: whole, destination: t.path + "/out.xiz").isEmpty)
        #expect(!Disks.refusals(whole: Disks.list().first(where: \.isBoot)!, destination: t.path).isEmpty)

        // Mounts refused while the blocker lives, allowed again after.
        let blocker = try #require(MountBlocker(wholeDisks: [disk]))
        #expect(throws: (any Error).self) { _ = try Self.run("/usr/sbin/diskutil", ["mount", disk + "s1"]) }
        #expect(blocker.refused.contains(disk + "s1"))
        blocker.stop()
        _ = try Self.run("/usr/sbin/diskutil", ["mount", disk + "s1"])
        #expect(Disks.find(disk)?.whole.volumes.isEmpty == false)
        try await Disks.unmount(disk)
        #expect(Disks.find(disk)?.whole.volumes.isEmpty == true)

        // Read raw: the image's hash is the device's.
        let (src, route) = try DeviceAccess.open(target.devicePath)
        #expect(route == .direct && src.isDevice && src.size == target.size && src.logicalSector == 512)
        let r = try XizForensic.acquireImage(from: src, to: t.path + "/p.xiz", options: .init(), signer: XizSigner(key: XizSigningKey(), label: "T"))
        let fh = try #require(FileHandle(forReadingAtPath: target.devicePath))
        let raw = try fh.read(upToCount: Int(target.size)) ?? Data()
        #expect(raw.count == Int(target.size))
        #expect(r.sha256 == Array(SHA256.hash(data: raw)))
        #expect(throws: DeviceAccess.Problem.self) { _ = try DeviceAccess.open("/etc/passwd") }
    }
}
