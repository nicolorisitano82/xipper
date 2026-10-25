import CryptoKit
import Foundation

// XIZ 1.3 inclusion proofs (§13.6) and erasable entries (§13.7).

/// RFC 6962 Merkle tree over leaf hashes (already `SHA-256(0x00 ‖ data)`).
enum MerkleTree {
    static func leafHash(_ data: [UInt8]) -> [UInt8] { Xiz.sha256([0x00] + data) }
    static func node(_ l: [UInt8], _ r: [UInt8]) -> [UInt8] { Xiz.sha256([0x01] + l + r) }

    private static func split(_ n: Int) -> Int {
        var k = 1
        while k << 1 < n { k <<= 1 }
        return k
    }

    static func root(_ leaves: ArraySlice<[UInt8]>) -> [UInt8] {
        if leaves.isEmpty { return Xiz.sha256([]) }
        if leaves.count == 1 { return leaves.first! }
        let k = split(leaves.count)
        return node(root(leaves.prefix(k)), root(leaves.dropFirst(k)))
    }

    /// RFC 6962 §2.1.1 audit path of leaf `m`.
    static func path(_ m: Int, _ leaves: ArraySlice<[UInt8]>) -> [[UInt8]] {
        if leaves.count <= 1 { return [] }
        let k = split(leaves.count)
        if m < k { return path(m, leaves.prefix(k)) + [root(leaves.dropFirst(k))] }
        return path(m - k, leaves.dropFirst(k)) + [root(leaves.prefix(k))]
    }

    /// RFC 9162 §2.1.3.2: the root an audit path leads to.
    static func rootFrom(leaf: [UInt8], index: Int, size: Int, path: [[UInt8]]) -> [UInt8]? {
        guard index < size else { return nil }
        var fn = index, sn = size - 1
        var r = leaf
        for p in path {
            if sn == 0 { return nil }
            if fn & 1 == 1 || fn == sn {
                r = node(p, r)
                if fn & 1 == 0 { while fn & 1 == 0 && fn != 0 { fn >>= 1; sn >>= 1 } }
            } else {
                r = node(r, p)
            }
            fn >>= 1
            sn >>= 1
        }
        return sn == 0 ? r : nil
    }
}

enum XizLeaf {
    /// `salt ‖ u16(path length) ‖ path ‖ u8(type) ‖ u64(size) ‖ content SHA-256`.
    static func data(salt: [UInt8], path: String, type: Xiz.EntryType, size: UInt64, sha256: [UInt8]) -> [UInt8] {
        var w = ByteWriter(capacity: 64 + path.utf8.count)
        w.append(salt)
        let p = Array(path.utf8)
        w.u16(UInt16(p.count)); w.append(p); w.u8(type.rawValue); w.u64(size); w.append(sha256)
        return w.bytes
    }

    /// Salt and content hash of an entry: in its catalog, or sealed with its entry key.
    static func proof(_ e: Xiz.Entry, entryKey: SymmetricKey?) -> (salt: [UInt8], sha256: [UInt8])? {
        if let p = e.proof { return p }
        guard let sealed = e.sealedProof, let k = entryKey else { return nil }
        return try? openProof(sealed, entryKey: k)
    }

    static func hash(_ e: Xiz.Entry, entryKey: SymmetricKey?) -> [UInt8] {
        guard let p = proof(e, entryKey: entryKey) else {
            // No proof data (a 1.3 draft archive): a leaf nobody can open, so no proof for it.
            var r = [UInt8](repeating: 0, count: 32)
            arc4random_buf(&r, 32)
            return r
        }
        return MerkleTree.leafHash(data(salt: p.salt, path: e.path, type: e.type, size: e.size, sha256: p.sha256))
    }

    static func proofKey(_ entryKey: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: entryKey, info: Data("xiz/1.3/proof".utf8), outputByteCount: 32)
    }

    static func sealProof(salt: [UInt8], sha256: [UInt8], entryKey: SymmetricKey) throws -> [UInt8] {
        let box = try AES.GCM.seal(salt + sha256, using: proofKey(entryKey), authenticating: Data("XIZ13proof".utf8))
        return Array(box.nonce) + Array(box.ciphertext) + Array(box.tag)
    }

    static func openProof(_ b: [UInt8], entryKey: SymmetricKey) throws -> (salt: [UInt8], sha256: [UInt8]) {
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: b[0..<12]), ciphertext: b[12..<60], tag: b[60..<76])
        let p = Array(try AES.GCM.open(box, using: proofKey(entryKey), authenticating: Data("XIZ13proof".utf8)))
        return (Array(p[0..<16]), Array(p[16..<48]))
    }

    static func randomSalt() -> [UInt8] {
        var s = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&s, 16)
        return s
    }
}

/// Key slots (§13.7).
enum XizSlots {
    static let size = 60

    static func aad(archiveID: [UInt8], segment: UInt32, index: UInt32) -> Data {
        var w = ByteWriter(capacity: 32)
        w.append(Array("XIZ13slot".utf8)); w.append(archiveID); w.u32(segment); w.u32(index)
        return Data(w.bytes)
    }

    static func seal(_ entryKey: SymmetricKey, group: XizKeys, segment: UInt32, index: UInt32) throws -> [UInt8] {
        let box = try entryKey.withUnsafeBytes {
            try AES.GCM.seal(Data($0), using: group.slotKey, authenticating: aad(archiveID: group.archiveID, segment: segment, index: index))
        }
        return Array(box.nonce) + Array(box.ciphertext) + Array(box.tag)
    }

    static func open(_ slot: [UInt8], group: XizKeys, segment: UInt32, index: UInt32) throws -> SymmetricKey {
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: slot[0..<12]), ciphertext: slot[12..<44], tag: slot[44..<60])
        return SymmetricKey(data: try AES.GCM.open(box, using: group.slotKey, authenticating: aad(archiveID: group.archiveID, segment: segment, index: index)))
    }
}

/// What a proof check found.
public struct XizProofResult: Sendable {
    public var path: String
    public var size: UInt64
    /// The file given has the content the archive committed to, under that name.
    public var contentMatches: Bool
    /// The leaf leads to the root of the segment's directory.
    public var inTree: Bool
    /// The segment is signed and the signature checks.
    public var signed: Bool
    public var signerLabel: String
    public var signerKey: String
    public var signedAt: Date?
    public var timestamp: XizTimestamp?
    public var segment: Int
    public var archiveID: String
    /// All of the above hold (a signed proof).
    public var valid: Bool { contentMatches && inTree && signed }
}

enum XizProof {
    static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    static func unhex(_ s: String) -> [UInt8]? {
        var out: [UInt8] = []
        var it = s.makeIterator()
        while let a = it.next() {
            guard let b = it.next(), let v = UInt8(String([a, b]), radix: 16) else { return nil }
            out.append(v)
        }
        return out
    }

    /// The proof for `path`, as JSON (`xiz-proof-1`).
    static func make(_ a: XizArchive, path: String) throws -> [UInt8] {
        guard let dir = a.directory, dir.version >= 2, dir.leafCount > 0 else {
            throw XipperError.unsupported("this XIZ archive has no inclusion tree (create it with XIZ 1.3)")
        }
        guard let e = a.catalog.entries.first(where: { $0.path == path || MountedArchive.normalize($0.path) == MountedArchive.normalize(path) }) else {
            throw XipperError.invalidArgument("no entry named \(path)")
        }
        guard let p = XizLeaf.proof(e, entryKey: a.entryKey(e)) else { throw XipperError.unsupported("\(path) has no proof data") }
        let leaf = MerkleTree.leafHash(XizLeaf.data(salt: p.salt, path: e.path, type: e.type, size: e.size, sha256: p.sha256))
        let leaves = try a.leafTable()
        guard let index = leaves.firstIndex(of: leaf), MerkleTree.root(leaves[...]) == dir.merkleRoot else {
            throw XipperError.corrupt("XIZ leaf table does not match the directory")
        }
        let doc: [String: Any] = [
            "format": "xiz-proof-1",
            "archive_id": hex(a.superblock.archiveID),
            "segment": a.segments - 1,
            "previous_footer": String(a.footer.previousFooter),
            "directory": Data(dir.signedPart).base64EncodedString(),
            "signature": Data(dir.signature).base64EncodedString(),
            "entry": ["path": e.path, "type": Int(e.type.rawValue), "size": String(e.size),
                      "salt": hex(p.salt), "sha256": hex(p.sha256)],
            "index": index,
            "tree_size": leaves.count,
            "audit_path": MerkleTree.path(index, leaves[...]).map(hex),
        ]
        return Array(try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]))
    }

    /// Checks a proof against the file it is about. Needs nothing else: no archive, no key.
    static func verify(_ json: [UInt8], content: URL) throws -> XizProofResult {
        guard let o = try JSONSerialization.jsonObject(with: Data(json)) as? [String: Any], o["format"] as? String == "xiz-proof-1",
              let idHex = o["archive_id"] as? String, let archiveID = unhex(idHex), archiveID.count == 16,
              let segment = o["segment"] as? Int, let pf = (o["previous_footer"] as? String).flatMap({ UInt64($0) }),
              let dirB64 = o["directory"] as? String, let dirBytes = Data(base64Encoded: dirB64),
              let sigB64 = o["signature"] as? String, let sig = Data(base64Encoded: sigB64),
              let entry = o["entry"] as? [String: Any], let path = entry["path"] as? String,
              let typeRaw = entry["type"] as? Int, let type = Xiz.EntryType(rawValue: UInt8(clamping: typeRaw)),
              let size = (entry["size"] as? String).flatMap({ UInt64($0) }),
              let salt = (entry["salt"] as? String).flatMap(unhex), let sha = (entry["sha256"] as? String).flatMap(unhex),
              let index = o["index"] as? Int, let treeSize = o["tree_size"] as? Int,
              let audit = (o["audit_path"] as? [String])?.compactMap(unhex) else {
            throw XipperError.invalidArgument("not an XIZ proof")
        }
        // The directory: its signed part plus an empty signature and a checksum, to reuse the decoder.
        var full = ByteWriter(capacity: dirBytes.count + 8)
        full.append(Array(dirBytes)); full.u32(0)
        full.u32(Xiz.crc32c(full.bytes))
        let dir = try XizDirectory.decode(full.bytes)
        guard dir.signedPart == Array(dirBytes) else { throw XipperError.invalidArgument("XIZ proof directory") }

        // The file: its SHA-256 (or the link target's) must be the committed one.
        var actual = [UInt8](repeating: 0, count: 32)
        var actualSize: UInt64 = 0
        switch type {
        case .file:
            let r = try FileReader(path: content.path)
            var h = SHA256()
            var off: Int64 = 0
            while off < r.size {
                let b = try r.read(at: off, count: Int(min(Int64(4 << 20), r.size - off)))
                h.update(data: b)
                off += Int64(b.count)
            }
            actual = Array(h.finalize())
            actualSize = UInt64(r.size)
        case .symlink:
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: content.path)
            actual = Xiz.sha256(Array(target.utf8))
        case .directory:
            break
        }
        let leaf = MerkleTree.leafHash(XizLeaf.data(salt: salt, path: path, type: type, size: size, sha256: sha))
        let inTree = MerkleTree.rootFrom(leaf: leaf, index: index, size: treeSize, path: audit) == dir.merkleRoot
            && treeSize == Int(dir.leafCount)
        var result = XizProofResult(path: path, size: size, contentMatches: actual == sha && (type != .file || actualSize == size),
                                    inTree: inTree, signed: false, signerLabel: "", signerKey: "", signedAt: nil, timestamp: nil,
                                    segment: segment, archiveID: hex(archiveID))
        if !sig.isEmpty, let rec = try? XizSignature.Record.decode(Array(sig)) {
            var d = dir
            d.signature = Array(sig)
            let m = XizSignature.message(archiveID: archiveID, segment: UInt32(segment), directory: d, previousFooter: pf, rec)
            result.signed = (try? Curve25519.Signing.PublicKey(rawRepresentation: rec.publicKey))?.isValidSignature(rec.signature, for: m) ?? false
            result.signerLabel = rec.label
            result.signerKey = XizSigningKey.publicText(rec.publicKey)
            result.signedAt = Date(timeIntervalSince1970: Double(rec.time))
            if !rec.token.isEmpty { result.timestamp = try? RFC3161.verify(rec.token, imprint: Xiz.sha256(rec.signature)) }
        }
        return result
    }
}
