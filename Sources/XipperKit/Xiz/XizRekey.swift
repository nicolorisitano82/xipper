import CryptoKit
import Foundation

/// Argon2id profiles for XIZ passwords (3.5, docs/STUDIO_XIZ_ATTACCHI.md, phase B).
public enum XizKDFProfile: String, Sendable, CaseIterable {
    /// 256 MiB, 3 passes (RFC 9106's second profile), about 0.2 s.
    case standard
    /// 1 GiB, 4 passes, about 1 s: about 2.5 bits more against guessing, not a substitute for a
    /// strong password.
    case strong

    var kdf: XizKeys.KDF { self == .strong ? .strong : .standard }

    /// Opening a strong archive takes 1 GiB: offered on Macs with at least 8 GB.
    public static var strongIsAvailable: Bool { ProcessInfo.processInfo.physicalMemory >= 8 << 30 }
}

/// The Argon2id parameters of a password stanza, read from its public header.
public struct XizKDFParameters: Sendable, Hashable, CustomStringConvertible {
    public var memoryKiB: Int
    public var iterations: Int
    public var parallelism: Int

    init(_ k: XizKeys.KDF) {
        memoryKiB = Int(k.memoryKiB); iterations = Int(k.iterations); parallelism = Int(k.parallelism)
    }

    var kdf: XizKeys.KDF { XizKeys.KDF(memoryKiB: UInt32(memoryKiB), iterations: UInt32(iterations), parallelism: UInt32(parallelism)) }

    /// Cheaper than 64 MiB, or than 64 MiB × 3 passes: worth re-encrypting (`Xipper.xizRekey`).
    public var isWeak: Bool { kdf.isWeak }
    /// Memory × passes, the cost an attacker pays per guess.
    public var cost: Int { memoryKiB * iterations }
    public var profile: XizKDFProfile? { kdf == .strong ? .strong : kdf == .standard ? .standard : nil }

    public var description: String {
        let mem = memoryKiB % 1024 == 0 ? "\(memoryKiB / 1024) MiB" : "\(memoryKiB) KiB"
        return "\(mem), t=\(iterations), p=\(parallelism)"
    }
}

/// Rewrapping password stanzas in place (3.5): new Argon2id parameters, new salt and optionally a
/// new password, the same keys. A rewrapped stanza has the same length, so the keys block keeps its
/// size and nothing else in the archive changes; signatures do not cover the keys block (§13.5),
/// the recovery record (§15) is rebuilt.
enum XizRekey {
    /// Body offset of the Argon2id header (parameters, salt) of a password stanza, nil for other
    /// stanzas: types 1, 2 and 8 at 0, custodian password shares (type 5, kind 1) at 3.
    static func passwordHeaderOffset(_ type: UInt8, _ body: [UInt8]) -> Int? {
        switch type {
        case 1, 2, 8: return body.count >= 44 ? 0 : nil
        case 5: return body.count >= 47 && body[2] == 1 ? 3 : nil
        default: return nil
        }
    }

    static func stanzas(_ b: [UInt8]) throws -> [(type: UInt8, body: [UInt8])] {
        guard b.count >= 10, b.starts(with: Xiz.keysMagic) else { throw XipperError.corrupt("XIZ keys block") }
        let crc = b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: b.count - 4, as: UInt32.self).littleEndian }
        guard crc == Xiz.crc32c(Array(b[..<(b.count - 4)])) else { throw XipperError.corrupt("XIZ keys block checksum mismatch") }
        return try b.withUnsafeBytes { raw in
            var r = ByteReader(UnsafeRawBufferPointer(rebasing: raw[..<(raw.count - 4)]), at: 4)
            var out: [(UInt8, [UInt8])] = []
            for _ in 0..<Int(try r.u16()) {
                let type = try r.u8(), len = Int(try r.u16())
                out.append((type, Array(try r.bytes(len))))
            }
            guard r.remaining == 0 else { throw XipperError.corrupt("XIZ keys block") }
            return out
        }
    }

    static func block(_ s: [(type: UInt8, body: [UInt8])]) -> [UInt8] {
        var w = ByteWriter(capacity: 6 + s.reduce(0) { $0 + 3 + $1.body.count } + 4)
        w.append(Xiz.keysMagic); w.u16(UInt16(s.count))
        for (t, b) in s { w.u8(t); w.u16(UInt16(b.count)); w.append(b) }
        w.u32(Xiz.crc32c(w.bytes))
        return w.bytes
    }

    static func kdf(_ body: [UInt8], at p: Int) -> XizKeys.KDF {
        func u32(_ o: Int) -> UInt32 { UInt32(body[p + o]) | UInt32(body[p + o + 1]) << 8 | UInt32(body[p + o + 2]) << 16 | UInt32(body[p + o + 3]) << 24 }
        return XizKeys.KDF(memoryKiB: u32(0), iterations: u32(4), parallelism: u32(8))
    }

    /// Argon2id parameters of every password stanza of a keys block.
    static func passwordKDFs(_ keysBlock: [UInt8]) -> [XizKDFParameters] {
        guard let s = try? stanzas(keysBlock) else { return [] }
        return s.compactMap { t, b in passwordHeaderOffset(t, b).map { XizKDFParameters(kdf(b, at: $0)) } }
    }

    /// End of a stanza's header (what its AAD covers), nil when malformed.
    static func headerEnd(_ type: UInt8, _ body: [UInt8], at p: Int) -> Int? {
        func label(_ q: Int) -> Int? { q < body.count && q + 1 + Int(body[q]) <= body.count ? q + 1 + Int(body[q]) : nil }
        switch type {
        case 1: return 44
        case 2: return label(44)
        case 8: return body.count >= 52 ? label(52) : nil
        case 5: return label(p + 44)
        default: return nil
        }
    }

    static func backupURL(_ path: String) -> String { path + ".keys-backup" }

    /// A run cut short between writing the backup and removing it: put the old block back when the
    /// block on disk does not check, drop the backup otherwise.
    static func recoverInterrupted(_ path: String) throws {
        let backup = backupURL(path)
        guard FileManager.default.fileExists(atPath: backup) else { return }
        let old = Array(try Data(contentsOf: URL(fileURLWithPath: backup)))
        let r = try FileReader(path: path)
        let sb = try Xiz.Superblock.decode(try r.read(at: 0, count: Xiz.superblockSize))
        guard Int(sb.keysLength) == old.count else { throw XipperError.corrupt("\(backup) does not belong to this archive") }
        let current = try r.read(at: Int64(Xiz.superblockSize), count: old.count)
        if (try? stanzas(current)) == nil, (try? stanzas(old)) != nil { try write(old, to: path) }
        try FileManager.default.removeItem(atPath: backup)
    }

    static func write(_ block: [UInt8], to path: String) throws {
        let fd = open(path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { throw XipperError.posix("open", path) }
        defer { close(fd) }
        let n = block.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, off_t(Xiz.superblockSize)) }
        guard n == block.count else { throw XipperError.posix("write", path) }
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { throw XipperError.posix("fsync", path) }
    }

    /// Rewraps every password stanza `password` (with `factors` for type 8) opens; returns how many.
    static func rekey(_ path: String, password: String, newPassword: String?, factors: [[UInt8]], kdf newKDF: XizKeys.KDF) throws -> Int {
        try recoverInterrupted(path)
        let r = try FileReader(path: path)
        let sbBytes = try r.read(at: 0, count: Xiz.superblockSize)
        let sb = try Xiz.Superblock.decode(sbBytes)
        guard sb.required.contains(.encrypted), sb.keysLength > 0 else { throw XipperError.invalidArgument("the archive is not encrypted") }
        let oldBlock = try r.read(at: Int64(Xiz.superblockSize), count: Int(sb.keysLength))
        let name = URL(fileURLWithPath: path).lastPathComponent
        let directory = sb.required.contains(.directory)

        // The credentials open the archive as it is, key commitment included.
        func keys(_ b: [UInt8], _ pw: String) throws -> [UInt16: [UInt8]] {
            if directory {
                let o = try XizAccessKeys.open(b, superblock: sbBytes, passwords: [pw], identities: [], factors: factors)
                return o.groupKeys.mapValues { $0.withUnsafeBytes { Array($0) } }
            }
            return [0: try XizKeys.open(keysBlock: b, superblock: sbBytes, password: pw).withUnsafeBytes { Array($0) }]
        }
        let before: [UInt16: [UInt8]]
        do { before = try keys(oldBlock, password) } catch XipperError.wrongPassword { throw XipperError.wrongPassword(entry: name) }
        guard !before.isEmpty else { throw XipperError.wrongPassword(entry: name) }

        let prefix = Array(sbBytes[0..<60]), archiveID = Array(sbBytes[16..<32])
        let target = (newPassword ?? password).precomposedStringWithCanonicalMapping
        var list = try stanzas(oldBlock)
        var changed = 0
        for i in list.indices {
            let (type, body) = list[i]
            guard let p = passwordHeaderOffset(type, body), let end = headerEnd(type, body, at: p), body.count >= end + 28 else { continue }
            let old = kdf(body, at: p)
            guard old.isAcceptable else { continue }
            let matching = type == 8 ? factors.filter { XizAccessKeys.factorID($0) == Array(body[44..<52]) } : [[]]
            guard !matching.isEmpty else { continue }
            let aad = prefix + [type] + Array(body[..<end])
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: body[end..<(end + 12)]),
                                            ciphertext: body[(end + 12)..<(body.count - 16)], tag: body[(body.count - 16)...])
            var opened: (plain: Data, factor: [UInt8])?
            search: for form in XizKeys.passwordForms(password) {
                let argon = try XizKeys.argon2id(form, salt: Array(body[(p + 12)..<(p + 44)]), old)
                for f in matching {
                    let kek = type == 8 ? XizAccessKeys.factorKEK(argon, factor: f, archiveID: archiveID) : argon
                    if let plain = try? AES.GCM.open(box, using: kek, authenticating: Data(aad)) { opened = (plain, f); break search }
                }
            }
            guard let opened else { continue }
            var salt = [UInt8](repeating: 0, count: 32)
            arc4random_buf(&salt, 32)
            var h = ByteWriter(capacity: end)
            h.append(Array(body[..<p])); h.u32(newKDF.memoryKiB); h.u32(newKDF.iterations); h.u32(newKDF.parallelism); h.append(salt)
            h.append(Array(body[(p + 44)..<end]))
            let argon = try XizKeys.argon2id(target, salt: salt, newKDF)
            let kek = type == 8 ? XizAccessKeys.factorKEK(argon, factor: opened.factor, archiveID: archiveID) : argon
            let sealed = try AES.GCM.seal(opened.plain, using: kek, authenticating: Data(prefix + [type] + h.bytes))
            let newBody = h.bytes + Array(sealed.nonce) + Array(sealed.ciphertext) + Array(sealed.tag)
            guard newBody.count == body.count else { throw XipperError.corrupt("XIZ stanza") }
            list[i].body = newBody
            changed += 1
        }
        guard changed > 0 else { throw XipperError.wrongPassword(entry: name) }
        let newBlock = block(list)
        guard newBlock.count == oldBlock.count else { throw XipperError.corrupt("XIZ keys block") }
        // The new block opens to the same keys before it reaches the disk.
        let after = try keys(newBlock, newPassword ?? password)
        guard before.allSatisfy({ after[$0.key] == $0.value }) else { throw XipperError.corrupt("XIZ keys block: rewrapped keys differ") }

        let recovery = XizRecovery.locate(r)?.header.info.redundancy
        let backup = backupURL(path)
        guard FileManager.default.createFile(atPath: backup, contents: Data(oldBlock), attributes: [.posixPermissions: 0o600]) else {
            throw XipperError.posix("create", backup)
        }
        if let h = FileHandle(forWritingAtPath: backup) { try? h.synchronize(); try? h.close() }
        do {
            try write(newBlock, to: path)
            let check = try FileReader(path: path).read(at: Int64(Xiz.superblockSize), count: newBlock.count)
            guard check == newBlock else { throw XipperError.corrupt("XIZ keys block: written bytes differ") }
        } catch {
            try? write(oldBlock, to: path)
            try? FileManager.default.removeItem(atPath: backup)
            throw error
        }
        try FileManager.default.removeItem(atPath: backup)
        if let recovery { _ = try XizRecovery.add(path, redundancy: recovery, progress: nil, cancel: nil) }
        return changed
    }
}
