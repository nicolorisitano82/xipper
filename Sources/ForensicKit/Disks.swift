import DiskArbitration
import Darwin
import Foundation
import IOKit

/// The disks attached to this Mac, as an examiner chooses a source: physical disks (and attached disk
/// images) with their partitions, never the APFS containers synthesized on top of them.
/// Read from IOKit (the media tree) and Disk Arbitration (descriptions, mount and unmount).
public struct Disk: Sendable, Identifiable, Hashable {
    public struct Volume: Sendable, Hashable {
        public var bsd: String
        public var name: String
        public var mountPoint: String
        public var fileSystem: String
    }

    public var id: String { bsd }
    /// `disk4`, or `disk4s2` for a partition.
    public var bsd: String
    public var whole: Bool
    public var size: UInt64
    public var blockSize: UInt32
    public var vendor = ""
    public var model = ""
    public var revision = ""
    public var serial = ""
    /// USB, SATA, PCI-Express, Apple Fabric, Thunderbolt, Virtual Interface (disk images)…
    public var bus = ""
    public var isInternal = false
    public var isRemovable = false
    public var isDiskImage = false
    /// Partition scheme of a whole disk (GUID_partition_scheme…), partition type of a partition.
    public var content = ""
    /// Where a partition starts on its disk.
    public var offset: UInt64 = 0
    public var encrypted = false
    /// Partitions of a whole disk.
    public var partitions: [Disk] = []
    /// Mounted volumes that live on this disk (directly or through an APFS container).
    public var volumes: [Volume] = []
    /// The disk this Mac started from.
    public var isBoot = false

    /// The raw device: unbuffered reads, what an acquisition reads.
    public var devicePath: String { "/dev/r" + bsd }

    public var title: String {
        let name = [vendor, model].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? bsd : name
    }

    /// Fields for the device record of the archive (`forensic/device.json`).
    public var record: [String: String] {
        var d = ["bsd_name": bsd, "size": String(size), "logical_sector": String(blockSize), "bus": bus,
                 "internal": isInternal ? "true" : "false", "removable": isRemovable ? "true" : "false"]
        for (k, v) in [("vendor", vendor), ("model", model), ("revision", revision), ("serial", serial), ("content", content)] where !v.isEmpty { d[k] = v }
        if !whole { d["partition_offset"] = String(offset) }
        if isDiskImage { d["disk_image"] = "true" }
        return d
    }
}

public enum Disks {
    // MARK: listing

    /// Physical disks and attached disk images, with their partitions; boot disk marked.
    public static func list() -> [Disk] {
        let mounts = mountedVolumes()
        let boot = wholeDisk(containing: "/")
        var media: [String: Disk] = [:]
        var parents: [String: String] = [:]
        forEachMedia { service in
            guard let bsd = string(service, "BSD Name") else { return }
            // Synthesized (APFS containers and their volumes) and partitions of synthesized disks: skip.
            let chain = mediaAncestors(service)
            if bool(service, "Whole") {
                guard chain.isEmpty else { return }
            } else {
                guard chain.count == 1, let p = chain.first, isPhysicalWhole(p) else { return }
                parents[bsd] = p
            }
            if var d = describe(bsd) {
                d.volumes = mounts.filter { $0.whole == bsd || $0.partition == bsd }.map(\.volume)
                media[bsd] = d
            }
        }
        var disks = media.values.filter(\.whole)
        for i in disks.indices {
            disks[i].partitions = media.values.filter { parents[$0.bsd] == disks[i].bsd }.sorted { $0.offset < $1.offset }
            disks[i].isBoot = disks[i].bsd == boot
        }
        return disks.sorted { (Int($0.bsd.dropFirst(4)) ?? 0) < (Int($1.bsd.dropFirst(4)) ?? 0) }
    }

    /// One disk or partition, as `list()` describes it (partitions and volumes not filled in).
    public static func describe(_ bsd: String) -> Disk? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let da = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd),
              let desc = DADiskCopyDescription(da) as? [String: Any] else { return nil }
        func s(_ k: CFString) -> String { (desc[k as String] as? String)?.trimmingCharacters(in: .whitespaces) ?? "" }
        func b(_ k: CFString) -> Bool { desc[k as String] as? Bool ?? false }
        var d = Disk(bsd: bsd, whole: b(kDADiskDescriptionMediaWholeKey),
                     size: (desc[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.uint64Value ?? 0,
                     blockSize: (desc[kDADiskDescriptionMediaBlockSizeKey as String] as? NSNumber)?.uint32Value ?? 512)
        d.vendor = s(kDADiskDescriptionDeviceVendorKey)
        d.model = s(kDADiskDescriptionDeviceModelKey)
        d.revision = s(kDADiskDescriptionDeviceRevisionKey)
        d.bus = s(kDADiskDescriptionDeviceProtocolKey)
        d.isInternal = b(kDADiskDescriptionDeviceInternalKey)
        d.isRemovable = b(kDADiskDescriptionMediaRemovableKey) || b(kDADiskDescriptionMediaEjectableKey)
        d.content = s(kDADiskDescriptionMediaContentKey)
        d.encrypted = b(kDADiskDescriptionMediaEncryptedKey)
        d.isDiskImage = d.model == "Disk Image" || d.bus == "Virtual Interface"
        if let service = media(bsd) {
            defer { IOObjectRelease(service) }
            d.offset = (property(service, "Base") as? NSNumber)?.uint64Value ?? 0
            d.serial = serial(service)
        }
        return d
    }

    /// The physical whole disk under `path` (`disk0` for anything on the startup volume), nil off disk.
    public static func wholeDisk(containing path: String) -> String? {
        var st = statfs()
        guard statfs(path, &st) == 0 else { return nil }
        let from = withUnsafeBytes(of: st.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard from.hasPrefix("/dev/") else { return nil }
        return wholeDisk(of: String(from.dropFirst(5)))
    }

    /// The physical whole disk holding `bsd` (a partition, an APFS volume or snapshot, a whole disk).
    public static func wholeDisk(of bsd: String) -> String? {
        guard let service = media(bsd) else { return nil }
        defer { IOObjectRelease(service) }
        var top: String? = bool(service, "Whole") ? bsd : nil
        for a in mediaAncestors(service) where isWhole(a) { top = a }
        return top
    }

    // MARK: unmounting and blocking mounts

    /// Unmounts every volume of a whole disk (or one partition), like `diskutil unmountDisk`.
    public static func unmount(_ bsd: String) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            guard let session = DASessionCreate(kCFAllocatorDefault),
                  let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd) else {
                c.resume(throwing: DiskError.notFound(bsd)); return
            }
            let queue = DispatchQueue(label: "app.xipper.forensic.unmount")
            DASessionSetDispatchQueue(session, queue)
            let box = Unmanaged.passRetained(Resume(c, session)).toOpaque()
            let whole = DADiskCopyWholeDisk(disk).map { CFEqual($0, disk) } ?? false
            DADiskUnmount(disk, DADiskUnmountOptions(whole ? kDADiskUnmountOptionWhole : kDADiskUnmountOptionDefault), { _, dissenter, ctx in
                let r = Unmanaged<Resume>.fromOpaque(ctx!).takeRetainedValue()
                if let dissenter {
                    let status = DADissenterGetStatusString(dissenter) as String? ?? ""
                    r.c.resume(throwing: DiskError.busy(status.isEmpty ? String(format: "0x%x", DADissenterGetStatus(dissenter)) : status))
                } else {
                    r.c.resume()
                }
                DASessionSetDispatchQueue(r.session, nil)
            }, box)
        }
    }

    final class Resume: @unchecked Sendable {
        let c: CheckedContinuation<Void, Error>
        let session: DASession
        init(_ c: CheckedContinuation<Void, Error>, _ s: DASession) { self.c = c; session = s }
    }

    public enum DiskError: LocalizedError {
        case notFound(String), busy(String)
        public var errorDescription: String? {
            switch self {
            case .notFound(let d): "\(d): disk not found"
            case .busy(let s): "the disk could not be unmounted (\(s)): close the apps using it"
            }
        }
    }

    // MARK: IOKit

    static func media(_ bsd: String) -> io_service_t? {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsd))
        return s == 0 ? nil : s
    }

    static func forEachMedia(_ body: (io_service_t) -> Void) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        while case let s = IOIteratorNext(it), s != 0 {
            body(s)
            IOObjectRelease(s)
        }
    }

    /// BSD names of the media above `service` in the service plane, nearest first
    /// (a synthesized APFS disk leads to its physical store, then to the store's whole disk).
    static func mediaAncestors(_ service: io_service_t) -> [String] {
        var out: [String] = []
        var cur = service
        IOObjectRetain(cur)
        while true {
            var parent: io_registry_entry_t = 0
            let r = IORegistryEntryGetParentEntry(cur, kIOServicePlane, &parent)
            IOObjectRelease(cur)
            guard r == KERN_SUCCESS, parent != 0 else { break }
            if IOObjectConformsTo(parent, "IOMedia") != 0, let n = string(parent, "BSD Name") { out.append(n) }
            cur = parent
        }
        return out
    }

    static func isWhole(_ bsd: String) -> Bool {
        guard let s = media(bsd) else { return false }
        defer { IOObjectRelease(s) }
        return bool(s, "Whole")
    }

    static func isPhysicalWhole(_ bsd: String) -> Bool {
        guard let s = media(bsd) else { return false }
        defer { IOObjectRelease(s) }
        return bool(s, "Whole") && mediaAncestors(s).isEmpty
    }

    static func property(_ s: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(s, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func string(_ s: io_registry_entry_t, _ key: String) -> String? { property(s, key) as? String }
    static func bool(_ s: io_registry_entry_t, _ key: String) -> Bool { property(s, key) as? Bool ?? false }

    /// The device's serial number, from the nearest ancestor that has one (USB, NVMe, SATA).
    static func serial(_ s: io_registry_entry_t) -> String {
        let opts = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        func search(_ key: String) -> Any? { IORegistryEntrySearchCFProperty(s, kIOServicePlane, key as CFString, kCFAllocatorDefault, opts) }
        let found = (search("Device Characteristics") as? [String: Any])?["Serial Number"] as? String
            ?? search("USB Serial Number") as? String ?? search("kUSBSerialNumberString") as? String ?? search("Serial Number") as? String
        return found?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    // MARK: mounted volumes

    struct Mounted { var whole: String; var partition: String?; var volume: Disk.Volume }

    static func mountedVolumes() -> [Mounted] {
        var p: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&p, MNT_NOWAIT)
        guard n > 0, let p else { return [] }
        var out: [Mounted] = []
        for i in 0..<Int(n) {
            let st = p[i]
            func str<T>(_ t: T) -> String { withUnsafeBytes(of: t) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } }
            let from = str(st.f_mntfromname)
            guard from.hasPrefix("/dev/disk") else { continue }
            let bsd = String(from.dropFirst(5))
            guard let service = media(bsd) else { continue }
            let chain = [bsd] + mediaAncestors(service)
            IOObjectRelease(service)
            guard let whole = chain.last(where: isWhole) else { continue }
            // The partition of the physical disk the volume sits on (for APFS: the container's store).
            let idx = chain.lastIndex(of: whole) ?? 0
            let partition = idx > 0 ? chain[idx - 1] : nil
            let mp = str(st.f_mntonname)
            out.append(Mounted(whole: whole, partition: partition,
                               volume: .init(bsd: bsd, name: mp == "/" ? "/" : (mp as NSString).lastPathComponent, mountPoint: mp,
                                             fileSystem: str(st.f_fstypename))))
        }
        return out
    }
}

/// Refuses every mount of a volume on the given disks while it lives (Disk Arbitration approval callback):
/// macOS would otherwise mount an evidence disk as soon as it appears or is unmounted.
public final class MountBlocker: @unchecked Sendable {
    let session: DASession
    let queue = DispatchQueue(label: "app.xipper.forensic.mountblocker")
    let disks: Set<String>
    private let lock = NSLock()
    private var _refused: [String] = []
    /// Volumes whose mount was refused, by BSD name.
    public var refused: [String] { lock.withLock { _refused } }
    private var context: UnsafeMutableRawPointer?

    public init?(wholeDisks: Set<String>) {
        guard let s = DASessionCreate(kCFAllocatorDefault) else { return nil }
        session = s
        disks = wholeDisks
        DASessionSetDispatchQueue(session, queue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        context = ctx
        DARegisterDiskMountApprovalCallback(session, nil, Self.approve, ctx)
    }

    static let approve: DADiskMountApprovalCallback = { disk, ctx in
        let me = Unmanaged<MountBlocker>.fromOpaque(ctx!).takeUnretainedValue()
        guard let name = DADiskGetBSDName(disk).map({ String(cString: $0) }),
              let whole = Disks.wholeDisk(of: name), me.disks.contains(whole) else { return nil }
        me.lock.withLock { me._refused.append(name) }
        let d = DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnExclusiveAccess), "Xipper Forensic: evidence being acquired" as CFString)
        return Unmanaged.passRetained(d)
    }

    /// Stops refusing mounts (also when released).
    public func stop() {
        guard let ctx = context else { return }
        context = nil
        DAUnregisterCallback(session, unsafeBitCast(Self.approve, to: UnsafeMutableRawPointer.self), ctx)
        queue.sync {}
        DASessionSetDispatchQueue(session, nil)
    }

    deinit { stop() }
}

extension Disks {
    /// A source chosen by BSD name: the whole disk it belongs to and the disk or partition itself.
    public static func find(_ bsd: String) -> (whole: Disk, target: Disk)? {
        let name = bsd.hasPrefix("/dev/") ? String(bsd.dropFirst(5)).replacingOccurrences(of: "rdisk", with: "disk") : bsd
        for d in list() {
            if d.bsd == name { return (d, d) }
            if let p = d.partitions.first(where: { $0.bsd == name }) { return (d, p) }
        }
        return nil
    }

    /// Why this source cannot be acquired to `destination` at all (empty when it can).
    public static func refusals(whole: Disk, destination: String) -> [String] {
        var out: [String] = []
        if whole.isBoot { out.append("\(whole.bsd) is the disk this Mac started from") }
        var dir = URL(fileURLWithPath: destination).standardizedFileURL.path
        while !FileManager.default.fileExists(atPath: dir), dir.count > 1 { dir = (dir as NSString).deletingLastPathComponent }
        if wholeDisk(containing: dir) == whole.bsd { out.append("the destination is on the source disk \(whole.bsd)") }
        return out
    }
}
