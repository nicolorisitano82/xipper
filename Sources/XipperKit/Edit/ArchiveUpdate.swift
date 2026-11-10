import Foundation

/// What `Xipper.update` changes to bring an archive in line with folders on disk.
public struct UpdatePlan: Sendable, Equatable {
    /// Paths inside the archive, sorted.
    public var added: [String] = []
    public var changed: [String] = []
    public var removed: [String] = []
    public var changes: [ArchiveChange] = []
    public var isEmpty: Bool { changes.isEmpty }
}

extension Xipper {
    /// The changes that make `archive` hold what `sources` hold now, as `create` would store them
    /// (each source is a top-level entry named after it; Finder droppings are left out as in
    /// `options.scan`). A file counts as changed when its size, modification time (to the second)
    /// or link target differ. Entries outside the sources' top-level names are left alone.
    public static func updatePlan(_ archive: URL, from sources: [URL], password: String? = nil,
                                  options: CreateOptions = CreateOptions()) throws -> UpdatePlan {
        let items = try SourceScanner.scan(sources, options: options.scan)
        let tops = Set(items.map { $0.name.split(separator: "/", maxSplits: 1)[0] }.map(String.init))
        var inArchive: [String: ArchiveEntry] = [:]
        for e in try list(archive, password: password) {
            let p = e.path.hasSuffix("/") ? String(e.path.dropLast()) : e.path
            if let top = p.split(separator: "/", maxSplits: 1).first, tops.contains(String(top)) { inArchive[p] = e }
        }
        func second(_ d: Date?) -> Int64 { Int64((d?.timeIntervalSince1970 ?? 0).rounded(.down)) }

        var plan = UpdatePlan()
        var onDisk = Set<String>()
        for item in items {
            onDisk.insert(item.name)
            let old = inArchive[item.name]
            let url = URL(fileURLWithPath: item.sourcePath)
            switch item.kind {
            case .directory:
                if old == nil {
                    plan.added.append(item.name)
                    plan.changes.append(.makeDirectory(item.name))
                } else if old?.kind != .directory {
                    plan.changed.append(item.name)
                    plan.changes += [.delete(item.name), .makeDirectory(item.name)]
                }
            case let .file(size):
                guard let old else {
                    plan.added.append(item.name)
                    plan.changes.append(.add(url, as: item.name))
                    continue
                }
                if old.kind != .file || old.uncompressedSize != size || second(old.modified) != second(item.modified) {
                    plan.changed.append(item.name)
                    if old.kind == .directory { plan.changes.append(.delete(item.name)) }
                    plan.changes.append(.add(url, as: item.name))
                }
            case let .symlink(target):
                guard let old else {
                    plan.added.append(item.name)
                    plan.changes.append(.add(url, as: item.name))
                    continue
                }
                // ZIP listings do not carry link targets: then size (the target's length) and time.
                let differs = old.linkTarget.map { $0 != target }
                    ?? (old.uncompressedSize != Int64(target.utf8.count) || second(old.modified) != second(item.modified))
                if old.kind != .symlink || differs {
                    plan.changed.append(item.name)
                    if old.kind == .directory { plan.changes.append(.delete(item.name)) }
                    plan.changes.append(.add(url, as: item.name))
                }
            }
        }
        // Gone from disk: only the topmost path of each missing subtree is deleted.
        for p in inArchive.keys.sorted() where !onDisk.contains(p) {
            if let parent = plan.removed.last, p.hasPrefix(parent + "/") { continue }
            plan.removed.append(p)
        }
        // Deletions first: a folder that became a file (or the reverse) is removed, then added.
        plan.changes = plan.removed.map { .delete($0) } + plan.changes
        plan.added.sort()
        plan.changed.sort()
        return plan
    }

    /// Brings `archive` in line with `sources` (see `updatePlan`) in one edit: an XIZ archive gains a
    /// new segment, i.e. a new version (§11), and stores only the new and changed files; content it
    /// already holds is deduplicated. Returns the plan and the edit's report (nil when nothing changed).
    @discardableResult
    public static func update(_ archive: URL, from sources: [URL], password: String? = nil, options: CreateOptions = CreateOptions(),
                              progress: ProgressHandler? = nil, cancel: CancellationToken? = nil) throws -> (UpdatePlan, EditReport?) {
        let plan = try updatePlan(archive, from: sources, password: password, options: options)
        guard !plan.isEmpty else { return (plan, nil) }
        let report = try edit(archive, changes: plan.changes, password: password, options: options, progress: progress, cancel: cancel)
        return (plan, report)
    }
}
