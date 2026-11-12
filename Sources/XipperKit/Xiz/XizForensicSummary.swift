import Foundation

extension XizForensic {
    /// What an archiver shows about a forensic archive (XIZ 1.10) without any forensic function:
    /// the case and evidence numbers, the source hashes, unreadable bytes and the hand-overs.
    /// Read from the forensic blocks only: no key to the content is needed.
    public struct Summary: Sendable, Equatable {
        public struct Source: Sendable, Equatable {
            public var path: String
            public var size: UInt64
            public var sha256: String
        }
        public struct HandOver: Sendable, Equatable {
            public var segment: Int
            public var from: String
            public var to: String
            public var time: String
        }
        public var caseNumber: String
        public var evidenceNumber: String
        public var description: String
        public var examiner: String
        public var sources: [Source]
        public var unreadableBytes: UInt64
        public var handOvers: [HandOver]
    }

    /// nil for an archive without the forensic profile.
    public static func summary(_ path: String) throws -> Summary? {
        let sb = try Xiz.Superblock.decode(try FileReader(path: path).read(at: 0, count: Xiz.superblockSize))
        guard sb.required.contains(.forensic) else { return nil }
        let blocks = try blocks(path)
        var s = Summary(caseNumber: "", evidenceNumber: "", description: "", examiner: "",
                        sources: [], unreadableBytes: 0, handOvers: [])
        for b in blocks {
            for r in b.records(.caseInfo) {
                let j = r.json
                s.caseNumber = j["case_number"] ?? s.caseNumber
                s.evidenceNumber = j["evidence_number"] ?? s.evidenceNumber
                s.description = j["description"] ?? s.description
                s.examiner = j["examiner"] ?? s.examiner
            }
            for r in b.records(.sourceHashes) {
                guard let h = try? SourceHashes(r.value) else { continue }
                s.sources.removeAll { $0.path == h.path }
                s.sources.append(Summary.Source(path: h.path, size: h.size, sha256: hex(h.sha256)))
            }
            for r in b.records(.unreadable) {
                if let u = try? Unreadable(r.value) { s.unreadableBytes += u.ranges.reduce(0) { $0 + $1.length } }
            }
            for r in b.records(.custody) {
                let j = r.json
                s.handOvers.append(Summary.HandOver(segment: Int(b.segment), from: j["from"] ?? "", to: j["to"] ?? "",
                                                    time: j["time"] ?? ""))
            }
        }
        return s
    }
}
