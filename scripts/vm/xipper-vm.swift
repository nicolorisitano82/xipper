// xipper-vm: a macOS virtual machine for the tests that need a whole Mac to be switched off
// (docs/ROADMAP.md, 3.2 A). Virtualization.framework only, Apple's restore image only.
//
//   xipper-vm url                       URL and size of the newest restore image this Mac can run
//   xipper-vm install DIR IPSW          creates the VM in DIR (80 GB sparse disk) and installs macOS
//   xipper-vm run DIR [--gui]           starts it; --gui opens a window (first setup); headless
//                                       otherwise. SIGUSR1 = power cut (hard stop, nothing flushed by
//                                       the guest survives); SIGTERM = ask the guest to shut down.
//   xipper-vm mac DIR                   the VM's MAC address (to find its IP in /var/db/dhcpd_leases)
//
// DIR/share is shared with the guest (it appears as /Volumes/My Shared Files).
import AppKit
import Foundation
import Virtualization

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data(("xipper-vm: " + s + "\n").utf8)); exit(1) }
func say(_ s: String) { print(s); fflush(stdout) }

struct Bundle {
    let dir: URL
    var disk: URL { dir.appendingPathComponent("Disk.img") }
    var aux: URL { dir.appendingPathComponent("AuxiliaryStorage") }
    var model: URL { dir.appendingPathComponent("HardwareModel") }
    var machine: URL { dir.appendingPathComponent("MachineIdentifier") }
    var mac: URL { dir.appendingPathComponent("MACAddress") }
    var share: URL { dir.appendingPathComponent("share") }

    func configuration(hardware: VZMacHardwareModel, machineID: VZMacMachineIdentifier, aux: VZMacAuxiliaryStorage,
                       cpus: Int, memory: UInt64) throws -> VZVirtualMachineConfiguration {
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardware
        platform.machineIdentifier = machineID
        platform.auxiliaryStorage = aux
        let c = VZVirtualMachineConfiguration()
        c.platform = platform
        c.bootLoader = VZMacOSBootLoader()
        c.cpuCount = cpus
        c.memorySize = memory
        let g = VZMacGraphicsDeviceConfiguration()
        g.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 110)]
        c.graphicsDevices = [g]
        // Guest flushes reach the disk image file: what the guest flushed survives a hard stop,
        // what it only had in its own memory does not.
        let attachment = try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false, cachingMode: .uncached,
                                                                synchronizationMode: .full)
        c.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        if let text = try? String(contentsOf: mac, encoding: .utf8), let m = VZMACAddress(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            net.macAddress = m
        } else {
            let m = VZMACAddress.randomLocallyAdministered()
            try m.string.write(to: mac, atomically: true, encoding: .utf8)
            net.macAddress = m
        }
        c.networkDevices = [net]
        c.keyboards = [VZMacKeyboardConfiguration()]
        c.pointingDevices = [VZMacTrackpadConfiguration()]
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        let fs = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        fs.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: share, readOnly: false))
        c.directorySharingDevices = [fs]
        c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        try c.validate()
        return c
    }

    func load() throws -> VZVirtualMachineConfiguration {
        guard let hw = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: model)),
              let id = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: machine)) else { fail("not a VM folder: \(dir.path)") }
        return try configuration(hardware: hw, machineID: id, aux: VZMacAuxiliaryStorage(url: aux), cpus: 4, memory: 8 << 30)
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: xipper-vm url | install DIR IPSW | run DIR [--gui] | mac DIR") }

switch args[1] {
case "url":
    VZMacOSRestoreImage.fetchLatestSupported { r in
        switch r {
        case let .success(img):
            let v = img.operatingSystemVersion
            say("\(img.url.absoluteString)\nmacOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion) (\(img.buildVersion))")
            exit(0)
        case let .failure(e): fail("\(e)")
        }
    }
    dispatchMain()

case "install":
    guard args.count == 4 else { fail("usage: xipper-vm install DIR IPSW") }
    let b = Bundle(dir: URL(fileURLWithPath: args[2]))
    let ipsw = URL(fileURLWithPath: args[3])
    if FileManager.default.fileExists(atPath: b.disk.path) { fail("\(b.disk.path) exists: the VM is already there") }
    try FileManager.default.createDirectory(at: b.dir, withIntermediateDirectories: true)
    VZMacOSRestoreImage.load(from: ipsw) { r in
        guard case let .success(img) = r else { fail("restore image: \(r)") }
        guard let req = img.mostFeaturefulSupportedConfiguration, req.hardwareModel.isSupported else { fail("this Mac cannot run that macOS") }
        DispatchQueue.main.async {
            do {
                try req.hardwareModel.dataRepresentation.write(to: b.model)
                let id = VZMacMachineIdentifier()
                try id.dataRepresentation.write(to: b.machine)
                let aux = try VZMacAuxiliaryStorage(creatingStorageAt: b.aux, hardwareModel: req.hardwareModel, options: [])
                guard FileManager.default.createFile(atPath: b.disk.path, contents: nil) else { fail("cannot create the disk") }
                let h = try FileHandle(forWritingTo: b.disk)
                try h.truncate(atOffset: 80 << 30)  // sparse: takes only what the guest writes
                try h.close()
                let c = try b.configuration(hardware: req.hardwareModel, machineID: id, aux: aux,
                                            cpus: max(4, req.minimumSupportedCPUCount), memory: max(8 << 30, req.minimumSupportedMemorySize))
                let vm = VZVirtualMachine(configuration: c)
                let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
                var last = -1
                let obs = installer.progress.observe(\.fractionCompleted) { p, _ in
                    let pct = Int(p.fractionCompleted * 100)
                    if pct != last { last = pct; say("install \(pct)%") }
                }
                installer.install { r in
                    obs.invalidate()
                    if case let .failure(e) = r { fail("install: \(e)") }
                    say("installed")
                    exit(0)
                }
            } catch { fail("\(error)") }
        }
    }
    dispatchMain()

case "run":
    guard args.count >= 3 else { fail("usage: xipper-vm run DIR [--gui]") }
    let b = Bundle(dir: URL(fileURLWithPath: args[2]))
    let gui = args.contains("--gui")
    let c = try b.load()
    let vm = VZVirtualMachine(configuration: c)

    final class Delegate: NSObject, VZVirtualMachineDelegate {
        func guestDidStop(_ vm: VZVirtualMachine) { say("guest stopped"); exit(0) }
        func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) { fail("stopped: \(error)") }
    }
    let delegate = Delegate()
    vm.delegate = delegate

    // Power cut: stop() ends the VM at once, like pulling the plug.
    signal(SIGUSR1, SIG_IGN)
    let cut = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    cut.setEventHandler {
        say("power cut")
        vm.stop { _ in say("off"); exit(0) }
    }
    cut.resume()
    signal(SIGTERM, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    term.setEventHandler {
        say("shutdown requested")
        try? vm.requestStop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { vm.stop { _ in exit(0) } }
    }
    term.resume()

    vm.start { r in
        if case let .failure(e) = r { fail("start: \(e)") }
        say("running")
    }
    if gui {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Xipper test VM"
        let view = VZVirtualMachineView()
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime((delegate, cut, term)) { app.run() }
    } else {
        withExtendedLifetime((delegate, cut, term)) { dispatchMain() }
    }

case "mac":
    guard args.count == 3 else { fail("usage: xipper-vm mac DIR") }
    say((try? String(contentsOf: Bundle(dir: URL(fileURLWithPath: args[2])).mac, encoding: .utf8)) ?? "")

default:
    fail("unknown command \(args[1])")
}
