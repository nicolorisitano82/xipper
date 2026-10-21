import ExtensionFoundation
import Foundation
import FSKit

@main
struct XipperFSExtension: UnaryFileSystemExtension {
    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations { XipperFileSystem() }
}

final class XipperFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard let r = resource as? FSPathURLResource else { return replyHandler(.notRecognized, nil) }
        replyHandler(.usable(name: r.url.lastPathComponent, containerID: FSContainerIdentifier(uuid: UUID())), nil)
    }

    func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        guard let r = resource as? FSPathURLResource else { return replyHandler(nil, fs_errorForPOSIXError(EINVAL)) }
        containerStatus = .ready
        replyHandler(SpikeVolume(url: r.url), nil)
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping ((any Error)?) -> Void) {
        replyHandler(nil)
    }
}

final class SpikeItem: FSItem {
    let id: UInt64
    let name: String
    let isDir: Bool
    let data: Data
    init(id: UInt64, name: String, isDir: Bool, data: Data = Data()) {
        self.id = id; self.name = name; self.isDir = isDir; self.data = data
    }
}

final class SpikeVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations, FSVolume.OpenCloseOperations {
    let root = SpikeItem(id: FSItem.Identifier.rootDirectory.rawValue, name: "", isDir: true)
    let info: SpikeItem

    init(url: URL) {
        var text = "archive: \(url.path)\n"
        if let h = FileHandle(forReadingAtPath: url.path) {
            let head = h.readData(ofLength: 16)
            text += "size: \((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) ?? "?")\n"
            text += "head: \(head.map { String(format: "%02x", $0) }.joined(separator: " "))\n"
        } else {
            text += "open failed: errno \(errno)\n"
        }
        info = SpikeItem(id: FSItem.Identifier.rootDirectory.rawValue + 1, name: "info.txt", isDir: false, data: Data(text.utf8))
        super.init(volumeID: FSVolume.Identifier(uuid: UUID()), volumeName: FSFileName(string: url.lastPathComponent))
    }

    // MARK: path conf
    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let c = FSVolume.SupportedCapabilities()
        c.supportsHiddenFiles = true
        c.caseFormat = .insensitiveCasePreserving
        return c
    }

    var volumeStatistics: FSStatFSResult {
        let s = FSStatFSResult(fileSystemTypeName: "xipperfs")
        s.blockSize = 4096; s.ioSize = 65536; s.totalBlocks = 1; s.availableBlocks = 0; s.freeBlocks = 0
        s.totalFiles = 2; s.freeFiles = 0
        return s
    }

    func attributes(_ item: SpikeItem) -> FSItem.Attributes {
        let a = FSItem.Attributes()
        a.type = item.isDir ? .directory : .file
        a.mode = item.isDir ? UInt32(S_IFDIR | 0o555) : UInt32(S_IFREG | 0o444)
        a.linkCount = item.isDir ? 2 : 1
        a.uid = getuid(); a.gid = getgid()
        a.size = UInt64(item.data.count); a.allocSize = UInt64(item.data.count)
        a.fileID = FSItem.Identifier(rawValue: item.id) ?? .invalid
        a.parentID = .rootDirectory
        let now = timespec(tv_sec: time(nil), tv_nsec: 0)
        a.modifyTime = now; a.changeTime = now; a.accessTime = now; a.birthTime = now
        return a
    }

    func activate(options: FSTaskOptions, replyHandler: @escaping (FSItem?, (any Error)?) -> Void) { replyHandler(root, nil) }
    func deactivate(options: FSDeactivateOptions = [], replyHandler: @escaping ((any Error)?) -> Void) { replyHandler(nil) }
    func mount(options: FSTaskOptions, replyHandler: @escaping ((any Error)?) -> Void) { replyHandler(nil) }
    func unmount(replyHandler: @escaping () -> Void) { replyHandler() }
    func synchronize(flags: FSSyncFlags, replyHandler: @escaping ((any Error)?) -> Void) { replyHandler(nil) }
    func reclaimItem(_ item: FSItem, replyHandler: @escaping ((any Error)?) -> Void) { replyHandler(nil) }

    func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem, replyHandler: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        guard let i = item as? SpikeItem else { return replyHandler(nil, fs_errorForPOSIXError(EIO)) }
        replyHandler(attributes(i), nil)
    }
    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem, replyHandler: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        replyHandler(nil, fs_errorForPOSIXError(EROFS))
    }
    func lookupItem(named name: FSFileName, inDirectory directory: FSItem, replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        if name.string == info.name { replyHandler(info, name, nil) } else { replyHandler(nil, nil, fs_errorForPOSIXError(ENOENT)) }
    }
    func readSymbolicLink(_ item: FSItem, replyHandler: @escaping (FSFileName?, (any Error)?) -> Void) { replyHandler(nil, fs_errorForPOSIXError(EINVAL)) }
    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest, replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        replyHandler(nil, nil, fs_errorForPOSIXError(EROFS))
    }
    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName, replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        replyHandler(nil, nil, fs_errorForPOSIXError(EROFS))
    }
    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem, replyHandler: @escaping (FSFileName?, (any Error)?) -> Void) {
        replyHandler(nil, fs_errorForPOSIXError(EROFS))
    }
    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem, replyHandler: @escaping ((any Error)?) -> Void) {
        replyHandler(fs_errorForPOSIXError(EROFS))
    }
    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?, replyHandler: @escaping (FSFileName?, (any Error)?) -> Void) {
        replyHandler(nil, fs_errorForPOSIXError(EROFS))
    }
    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker, replyHandler: @escaping (FSDirectoryVerifier, (any Error)?) -> Void) {
        let entries: [(String, SpikeItem)] = [(".", root), ("..", root), (info.name, info)]
        var i = Int(cookie.rawValue)
        while i < entries.count {
            let (n, item) = entries[i]
            let ok = packer.packEntry(name: FSFileName(string: n), itemType: item.isDir ? .directory : .file,
                                      itemID: FSItem.Identifier(rawValue: item.id) ?? .invalid,
                                      nextCookie: FSDirectoryCookie(rawValue: UInt64(i + 1)),
                                      attributes: attributes != nil ? self.attributes(item) : nil)
            if !ok { break }
            i += 1
        }
        replyHandler(FSDirectoryVerifier(rawValue: 1), nil)
    }

    // MARK: open/close, read
    func openItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler: @escaping ((any Error)?) -> Void) { replyHandler(nil) }
    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler: @escaping ((any Error)?) -> Void) { replyHandler(nil) }
    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer, replyHandler: @escaping (Int, (any Error)?) -> Void) {
        guard let i = item as? SpikeItem, !i.isDir else { return replyHandler(0, fs_errorForPOSIXError(EISDIR)) }
        let start = min(Int(offset), i.data.count), end = min(start + length, i.data.count)
        let n = buffer.withUnsafeMutableBytes { dst in
            i.data.copyBytes(to: dst, from: start..<end)
        }
        replyHandler(n, nil)
    }
    func write(contents: Data, to item: FSItem, at offset: off_t, replyHandler: @escaping (Int, (any Error)?) -> Void) {
        replyHandler(0, fs_errorForPOSIXError(EROFS))
    }
}
