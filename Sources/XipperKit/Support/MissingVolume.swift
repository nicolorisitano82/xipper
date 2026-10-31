import Foundation

extension Xipper {
    /// The first missing part of a split archive (the path where Xipper looks for it), nil when
    /// none is missing or the archive is not split. Spanned ZIPs (`name.z01`…`name.zip`) know how
    /// many parts they have; numbered pieces (`name.7z.001`, `name.zip.001`, …) do not, so a gap
    /// counts, and otherwise the piece after the last one is suggested: call this only after
    /// reading failed because data ends early.
    public static func missingVolume(of archive: URL) -> String? {
        let path = archive.standardizedFileURL.path
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let stem = url.deletingPathExtension().path
        if ext.count >= 3, ext.allSatisfy(\.isNumber) {
            // Numbered pieces: the first gap, or the one after the last present.
            let dir = (path as NSString).deletingLastPathComponent
            let prefix = (stem as NSString).lastPathComponent + "."
            let present = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).compactMap { name -> Int? in
                guard name.hasPrefix(prefix) else { return nil }
                let n = name.dropFirst(prefix.count)
                return n.count >= 3 && n.allSatisfy(\.isNumber) ? Int(n) : nil
            }
            guard let top = present.max() else { return nil }
            let have = Set(present)
            let missing = (1...top).first { !have.contains($0) } ?? top + 1
            return stem + "." + String(format: "%03d", missing)
        }
        let isZPart = ext.count == 3 && ext.hasPrefix("z") && ext.dropFirst().allSatisfy(\.isNumber)
        guard ext == "zip" || isZPart else { return nil }
        let last = stem + ".zip"
        guard let disks = zipDiskCount(last), disks > 1 else {
            // Without the last part nothing says how many there are, but it is the one missing.
            return isZPart && !fm.fileExists(atPath: last) ? last : nil
        }
        for n in 1..<disks where !fm.fileExists(atPath: stem + ".z" + String(format: "%02d", n)) {
            return stem + ".z" + String(format: "%02d", n)
        }
        return nil
    }

    /// Parts of a spanned ZIP, from the end of central directory record in its last part.
    static func zipDiskCount(_ lastPart: String) -> Int? {
        guard let r = try? FileReader(path: lastPart), r.size >= 22 else { return nil }
        let tail = Int(min(r.size, 22 + 65_535))
        guard let b = try? r.read(at: r.size - Int64(tail), count: tail) else { return nil }
        var i = b.count - 22
        while i >= 0 {
            if b[i] == 0x50, b[i + 1] == 0x4B, b[i + 2] == 0x05, b[i + 3] == 0x06 {
                let disk = Int(b[i + 4]) | Int(b[i + 5]) << 8
                return disk == 0xFFFF ? nil : disk + 1
            }
            i -= 1
        }
        return nil
    }
}
