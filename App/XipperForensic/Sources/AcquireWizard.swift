import AppKit
import ForensicKit
import IOKit.ps
import NetFS
import SwiftUI
import XipperKit

/// The guided acquisition (docs/XIPPER_FORENSIC.md §4.3): a fixed sequence, no way to "Start"
/// without the evidence item, the source and the checks. 0.9: files and folders, image files, and
/// a Mac in "Share Disk" mode mounted read-only over SMB. Disks come with the helper (1.0).
@MainActor @Observable
final class Acquisition {
    enum Step: Int, CaseIterable { case item, source, options, checks, running, done }
    enum Kind: String, CaseIterable { case files, image, share }

    let model: CaseModel
    var step = Step.item

    // 1. evidence item
    var id: String
    var description = ""
    var deviceModel = ""
    var serial = ""
    var seals = ""
    var notes = ""

    // 2. source
    var kind = Kind.files
    var files: [URL] = []
    var image: URL?
    var server = "smb://"
    var user = ""
    var sharePassword = ""
    var mountPoint: URL?
    var mounting = false

    // 3. options
    var md5 = true
    var sha1 = true
    var compress = true
    var xattrs = true
    var encrypt = false
    var password = ""
    var password2 = ""

    // 4. checks
    struct Check: Identifiable { let id = UUID(); var state: StatusIcon.State; var text: String }
    var checks: [Check] = []
    var estimating = false
    var estimate: Int64 = 0
    var confirmName = ""

    // 5. running
    var progress: ProgressSnapshot?
    var token = CancellationToken()
    var paused = false
    var interruptReason = ""
    var askingReason = false

    // 6. done
    var outcome: StatusIcon.State = .running
    var resultText = ""
    var result: EvidenceItem?
    var reportChecks: [[String: String]] = []
    var error: String?

    init(model: CaseModel) {
        self.model = model
        id = model.forensicCase?.nextEvidenceID() ?? "R01"
    }

    var sources: [URL] {
        switch kind {
        case .files, .share: files
        case .image: image.map { [$0] } ?? []
        }
    }

    var idTaken: Bool { model.items.contains { $0.id == id } || FileManager.default.fileExists(atPath: model.url.appendingPathComponent("evidence/" + id).path) }
    var idValid: Bool { !id.isEmpty && !id.contains("/") && !id.hasPrefix(".") && !idTaken }

    var canGoOn: Bool {
        switch step {
        case .item: idValid
        case .source: !sources.isEmpty
        case .options: !encrypt || (password.count >= 8 && password == password2)
        case .checks: !estimating && !checks.contains { $0.state == .failed } && confirmName.trimmingCharacters(in: .whitespaces) == Prefs.shared.examiner.trimmingCharacters(in: .whitespaces)
        case .running, .done: false
        }
    }

    // MARK: Share Disk

    /// Mounts the share read-only (MNT_RDONLY) with no UI; refuses a mount that is not read-only.
    func mountShare() async {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespaces)), url.scheme == "smb" || url.scheme == "afp" else {
            error = String(localized: "Enter the address shown by the Mac in Share Disk mode, e.g. smb://192.168.1.20/Macintosh HD")
            return
        }
        mounting = true
        defer { mounting = false }
        let user = self.user, pass = sharePassword
        let result: Result<URL, Error> = await Task.detached {
            let open = NSMutableDictionary()
            open[kNAUIOptionKey] = kNAUIOptionNoUI
            let mount = NSMutableDictionary()
            mount[kNetFSMountFlagsKey] = NSNumber(value: MNT_RDONLY | MNT_NOEXEC | MNT_NOSUID | MNT_NODEV)
            mount[kNetFSAllowSubMountsKey] = true
            var points: Unmanaged<CFArray>?
            let rc = NetFSMountURLSync(url as CFURL, nil, user.isEmpty ? nil : user as CFString, pass.isEmpty ? nil : pass as CFString,
                                       open, mount, &points)
            guard rc == 0, let first = (points?.takeRetainedValue() as? [String])?.first else {
                return .failure(NSError(domain: NSPOSIXErrorDomain, code: Int(rc), userInfo: [NSLocalizedDescriptionKey:
                    String(format: String(localized: "Could not connect (error %d)."), rc)]))
            }
            return .success(URL(fileURLWithPath: first))
        }.value
        switch result {
        case let .failure(e): error = e.localizedDescription
        case let .success(point):
            guard Self.readOnly(point) else {
                _ = unmount(point.path, MNT_FORCE)
                error = String(localized: "The share was mounted writable (it was probably already connected): disconnect it in the Finder and try again.")
                return
            }
            mountPoint = point
            sharePassword = ""
            let server = url.host() ?? ""
            _ = await model.signed { c, s in
                try c.log("share mounted", ["server": server, "share": url.lastPathComponent, "mount_point": point.path, "flags": "rdonly,noexec,nosuid,nodev"], signer: s)
            }
        }
    }

    static func readOnly(_ u: URL) -> Bool {
        var st = statfs()
        guard statfs(u.path, &st) == 0 else { return false }
        return st.f_flags & UInt32(MNT_RDONLY) != 0
    }

    // MARK: checks

    func runChecks() async {
        estimating = true
        let srcs = sources
        let caseURL = model.url
        let total = await Task.detached { Self.size(of: srcs) }.value
        estimate = total
        estimating = false
        var out: [Check] = []
        let fm = FileManager.default
        for s in srcs {
            if !fm.isReadableFile(atPath: s.path) {
                out.append(Check(state: .failed, text: String(format: String(localized: "%@ cannot be read"), s.path)))
            }
            let a = s.resolvingSymlinksInPath().path, b = caseURL.resolvingSymlinksInPath().path
            if a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") {
                out.append(Check(state: .failed, text: String(format: String(localized: "%@ and the case folder overlap: the archive would be written into the source"), s.lastPathComponent)))
            }
        }
        if !out.contains(where: { $0.state == .failed }) {
            out.append(Check(state: .passed, text: String(format: String(localized: "Sources readable: %@ to read"), Words.bytes(total))))
        }
        let ro = srcs.allSatisfy(Self.readOnly)
        out.append(ro ? Check(state: .passed, text: String(localized: "Sources mounted read-only"))
                      : Check(state: .warning, text: String(localized: "The sources are on a writable volume: Xipper Forensic does not write to them, but macOS may (Spotlight, .DS_Store). For original media use a write blocker.")))
        let free = (try? caseURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        if free < total + 64 << 20 {
            out.append(Check(state: compress ? .warning : .failed, text: String(format: String(localized: "Free space at the destination: %@ for up to %@ (compression usually needs less)"), Words.bytes(free), Words.bytes(total))))
        } else {
            out.append(Check(state: .passed, text: String(format: String(localized: "Free space at the destination: %@"), Words.bytes(free))))
        }
        do {
            _ = try Prefs.shared.signer()
            out.append(Check(state: .passed, text: String(format: String(localized: "Signing key “%@” unlocked"), Prefs.shared.keyName)))
        } catch {
            out.append(Check(state: .failed, text: error.localizedDescription))
        }
        out.append(Prefs.shared.timestampURL.isEmpty
                   ? Check(state: .warning, text: String(localized: "Offline mode: no time-stamp, the time is the Mac's clock (declared in the report)"))
                   : Check(state: .passed, text: String(format: String(localized: "Time-stamp from %@"), Prefs.shared.timestampURL)))
        if Self.onBattery() {
            out.append(Check(state: .warning, text: String(localized: "The Mac is on battery: connect the power adapter for a long acquisition")))
        }
        if encrypt { out.append(Check(state: .passed, text: String(localized: "Archive encrypted with a password: verification of structure, signatures and hashes works without it"))) }
        checks = out
    }

    nonisolated static func size(of urls: [URL]) -> Int64 {
        var total: Int64 = 0
        for u in urls {
            var st = stat()
            guard lstat(u.path, &st) == 0 else { continue }
            if st.st_mode & S_IFMT != S_IFDIR { total += Int64(st.st_size); continue }
            let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [], errorHandler: { _, _ in true })
            while let f = e?.nextObject() as? URL {
                if let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true { total += Int64(v.fileSize ?? 0) }
            }
        }
        return total
    }

    static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }

    // MARK: acquisition

    func start() {
        guard let c = model.forensicCase else { return }
        let signer: XizSigner
        do { signer = try Prefs.shared.signer() } catch { self.error = error.localizedDescription; return }
        step = .running
        token = CancellationToken()
        let token = self.token
        let id = self.id, srcs = sources, kind = self.kind
        var caseInfo = ["description": description, "notes": notes].filter { !$0.value.isEmpty }
        caseInfo["examiner"] = Prefs.shared.examiner
        var device = ["model": deviceModel, "serial": serial, "seals_found": seals].filter { !$0.value.isEmpty }
        if kind == .share {
            device["interface"] = "SMB (Share Disk), read-only"
            device["server"] = URL(string: server)?.host() ?? server
        }
        let acquisition = ["tool_version": ForensicReport.toolVersion, "app": "Xipper Forensic",
                           "os": ProcessInfo.processInfo.operatingSystemVersionString,
                           "confirmed_by": confirmName, "time_source": Prefs.shared.timestampURL.isEmpty ? "local clock (offline)" : "RFC 3161"]
        let caseFields = caseInfo, deviceFields = device
        let pw = encrypt ? password : nil
        let level = compress ? 3 : 0
        let md5 = self.md5, sha1 = self.sha1, xattrs = self.xattrs
        let checkLines = checks.map { c in (c.state == .passed ? "ok: " : c.state == .warning ? "warning: " : "blocked: ") + c.text }
        let progress: ProgressHandler = { snap in Task { @MainActor in self.progress = snap } }
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Forensic acquisition")
        Task {
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                let pdf = try await Task.detached { () throws -> URL in
                    try c.log("source checks", ["evidence": id, "checks": checkLines.joined(separator: " | "), "confirmed_by": acquisition["confirmed_by"]!],
                              signer: signer)
                    if kind == .image {
                        var o = XizForensic.ImageOptions()
                        o.name = srcs[0].lastPathComponent
                        o.md5 = md5; o.sha1 = sha1; o.level = level; o.password = pw
                        o.caseInfo = caseFields; o.device = deviceFields; o.acquisition = acquisition
                        let (e, _) = try c.acquireImage(from: srcs[0].path, evidence: id, options: o, signer: signer, progress: progress, cancel: token)
                        return e.pdf
                    } else {
                        var o = XizForensic.LogicalOptions()
                        o.level = level; o.password = pw; o.extendedAttributes = xattrs
                        o.caseInfo = caseFields; o.device = deviceFields; o.acquisition = acquisition
                        let (e, _) = try c.acquireLogical(srcs, evidence: id, options: o, signer: signer, progress: progress, cancel: token)
                        return e.pdf
                    }
                }.value
                _ = pdf
                model.reload()
                finish()
            } catch {
                if token.isCancelled {
                    let reason = interruptReason
                    _ = await model.signed { c, s in try c.log("acquisition interrupted", ["evidence": id, "reason": reason], signer: s) }
                    outcome = .failed
                    resultText = String(localized: "Acquisition interrupted. Nothing was kept; the reason is in the case log.")
                } else {
                    model.reload()
                    outcome = .failed
                    resultText = String(format: String(localized: "Acquisition failed: %@"), error.localizedDescription)
                }
                step = .done
            }
        }
    }

    func finish() {
        guard let i = model.items.first(where: { $0.id == id }) else { outcome = .failed; step = .done; return }
        result = i
        let r = (try? JSONSerialization.jsonObject(with: Data(contentsOf: i.evidence.report))) as? [String: Any] ?? [:]
        reportChecks = r["checks"] as? [[String: String]] ?? []
        if i.passed != true {
            outcome = .failed
            resultText = String(localized: "Acquisition finished, but the verification FAILED: see the checks below.")
        } else if i.warnings {
            outcome = .warning
            let n = (r["unreadable"] as? [Any])?.count ?? 0
            resultText = i.skipped > 0
                ? String(format: String(localized: "Complete, with %lld items not acquired (listed in the signed inventory)."), i.skipped)
                : String(format: String(localized: "Complete, with %lld unreadable ranges (zeros and map in the archive)."), n)
        } else {
            outcome = .passed
            resultText = String(localized: "Complete and verified.")
        }
        step = .done
    }

    func interrupt() {
        token.cancel()
    }
}

struct AcquireWizard: View {
    @State private var a: Acquisition
    @Environment(\.dismiss) private var dismiss
    let done: (String?) -> Void

    init(model: CaseModel, done: @escaping (String?) -> Void) {
        _a = State(initialValue: Acquisition(model: model))
        self.done = done
    }

    var body: some View {
        VStack(spacing: 0) {
            StepBar(step: a.step)
            Divider()
            Group {
                switch a.step {
                case .item: ItemStep(a: a)
                case .source: SourceStep(a: a)
                case .options: OptionsStep(a: a)
                case .checks: ChecksStep(a: a)
                case .running: RunningStep(a: a)
                case .done: DoneStep(a: a)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                if a.step == .running {
                    Button(a.paused ? "Resume" : "Pause") {
                        a.paused.toggle()
                        a.paused ? a.token.pause() : a.token.resume()
                    }
                    Spacer()
                    Button("Interrupt…", role: .destructive) { a.askingReason = true }
                } else if a.step == .done {
                    if let r = a.result {
                        Button("Open Report (PDF)") { NSWorkspace.shared.open(r.evidence.pdf) }
                    }
                    Spacer()
                    Button("Close") { done(a.result?.id); dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }
                    Spacer()
                    if a.step != .item {
                        Button("Back") { a.step = Acquisition.Step(rawValue: a.step.rawValue - 1)! }
                    }
                    if a.step == .checks {
                        Button("Start Acquisition") { a.start() }
                            .keyboardShortcut(.defaultAction).disabled(!a.canGoOn)
                    } else {
                        Button("Continue") {
                            a.step = Acquisition.Step(rawValue: a.step.rawValue + 1)!
                            if a.step == .checks { Task { await a.runChecks() } }
                        }
                        .keyboardShortcut(.defaultAction).disabled(!a.canGoOn)
                    }
                }
            }
            .padding()
        }
        .frame(width: 720, height: 600)
        .interactiveDismissDisabled(a.step == .running)
        .alert("Interrupt the acquisition?", isPresented: $a.askingReason) {
            TextField("Reason (goes into the case log)", text: $a.interruptReason)
            Button("Interrupt", role: .destructive) { a.interrupt() }
                .disabled(a.interruptReason.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Continue Acquiring", role: .cancel) {}
        } message: {
            Text("The partial archive is deleted; the interruption and its reason stay in the case log.")
        }
        .alert("Error", isPresented: Binding(get: { a.error != nil }, set: { if !$0 { a.error = nil } })) {
            Button("OK") { a.error = nil }
        } message: { Text(a.error ?? "") }
    }
}

struct StepBar: View {
    let step: Acquisition.Step

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Acquisition.Step.allCases, id: \.self) { s in
                HStack(spacing: 6) {
                    Image(systemName: s.rawValue < step.rawValue ? "checkmark.circle.fill" : "\(s.rawValue + 1).circle\(s == step ? ".fill" : "")")
                        .foregroundStyle(s.rawValue <= step.rawValue ? Color.accentColor : .secondary)
                    Text(title(s)).font(.callout.weight(s == step ? .semibold : .regular))
                        .foregroundStyle(s == step ? .primary : .secondary)
                }
                if s != Acquisition.Step.allCases.last { Spacer(minLength: 4) }
            }
        }
        .padding(.horizontal).padding(.vertical, 12)
    }

    func title(_ s: Acquisition.Step) -> String {
        switch s {
        case .item: String(localized: "Evidence item")
        case .source: String(localized: "Source")
        case .options: String(localized: "Options")
        case .checks: String(localized: "Checks")
        case .running: String(localized: "Acquisition")
        case .done: String(localized: "Outcome")
        }
    }
}

struct ItemStep: View {
    @Bindable var a: Acquisition

    var body: some View {
        Form {
            Section {
                TextField("Evidence number", text: $a.id)
                if a.idTaken { Text("This number is already used in the case.").foregroundStyle(.red).font(.caption) }
                TextField("Description", text: $a.description, prompt: Text("e.g. USB stick found on the desk"))
                TextField("Make and model", text: $a.deviceModel)
                TextField("Serial number", text: $a.serial)
                TextField("Seals found", text: $a.seals, prompt: Text("e.g. intact, no. 4471"))
                TextField("Notes", text: $a.notes, axis: .vertical).lineLimit(2...4)
            } footer: {
                Text("These go into the signed records of the archive and into the report.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct SourceStep: View {
    @Bindable var a: Acquisition

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $a.kind) {
                Text("Files and folders").tag(Acquisition.Kind.files)
                Text("Image file").tag(Acquisition.Kind.image)
                Text("Mac via Share Disk").tag(Acquisition.Kind.share)
            }
            .pickerStyle(.segmented).labelsHidden()
            .onChange(of: a.kind) { a.files = []; a.image = nil }

            switch a.kind {
            case .files:
                Text("Logical acquisition: every file and folder found is listed in a signed inventory with its metadata, including what cannot be read.")
                    .font(.callout).foregroundStyle(.secondary)
                fileList
                Button("Add Files or Folders…") { add(at: nil) }
            case .image:
                Text("A raw image (.dd, .img, .raw, .001…) acquired as it is: MD5, SHA-1 and SHA-256 of the whole image, and a hash for every 4 MiB block.")
                    .font(.callout).foregroundStyle(.secondary)
                if let i = a.image {
                    Label(i.path, systemImage: "doc").lineLimit(1).truncationMode(.middle)
                }
                Button("Choose Image File…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = false
                    if p.runModal() == .OK { a.image = p.url }
                }
            case .share:
                Text("On the Mac to acquire: start recoveryOS, choose Utilities › Share Disk, select the disk and start sharing. Connect this Mac to it with a cable or on the same network, then enter the address it shows. The share is mounted read-only.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let m = a.mountPoint {
                    Label(String(format: String(localized: "Connected read-only at %@"), m.path), systemImage: "lock.fill").foregroundStyle(.green)
                    fileList
                    Button("Choose Folders on the Shared Disk…") { add(at: m) }
                } else {
                    Form {
                        TextField("Address", text: $a.server, prompt: Text("smb://…"))
                        TextField("User", text: $a.user)
                        SecureField("Password", text: $a.sharePassword)
                    }
                    .formStyle(.grouped)
                    HStack {
                        Button("Connect Read-Only") { Task { await a.mountShare() } }.disabled(a.mounting)
                        if a.mounting { ProgressView().controlSize(.small) }
                    }
                }
            }
            Spacer()
        }
        .padding()
    }

    var fileList: some View {
        List {
            ForEach(a.files, id: \.self) { u in
                HStack {
                    Image(systemName: u.hasDirectoryPath ? "folder" : "doc")
                    Text(u.path).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { a.files.removeAll { $0 == u } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
        }
        .frame(minHeight: 140)
        .overlay { if a.files.isEmpty { Text("Nothing chosen yet").foregroundStyle(.secondary) } }
    }

    func add(at dir: URL?) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.directoryURL = dir
        if p.runModal() == .OK {
            for u in p.urls where !a.files.contains(u) {
                if let dir, !u.standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path) { continue }
                a.files.append(u)
            }
        }
    }
}

struct OptionsStep: View {
    @Bindable var a: Acquisition

    var body: some View {
        Form {
            Section("Hashes") {
                Toggle("SHA-256", isOn: .constant(true)).disabled(true)
                if a.kind == .image {
                    Toggle("MD5 (compatibility)", isOn: $a.md5)
                    Toggle("SHA-1 (compatibility)", isOn: $a.sha1)
                } else {
                    Text("Every file has its SHA-256 in the signed inventory.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Archive") {
                Toggle("Compress (zstd; the hashes are of the original data)", isOn: $a.compress)
                if a.kind != .image { Toggle("Keep extended attributes (quarantine, tags, resource forks)", isOn: $a.xattrs) }
                Toggle("Encrypt with a password", isOn: $a.encrypt)
                if a.encrypt {
                    SecureField("Password (at least 8 characters)", text: $a.password)
                    SecureField("Repeat password", text: $a.password2)
                    if !a.password2.isEmpty && a.password != a.password2 { Text("The passwords differ.").foregroundStyle(.red).font(.caption) }
                }
            }
            Section("Signature") {
                LabeledContent("Signed by", value: Prefs.shared.examiner)
                LabeledContent("Key", value: Prefs.shared.keyName)
                LabeledContent("Time-stamp", value: Prefs.shared.timestampURL.isEmpty ? String(localized: "none (offline)") : Prefs.shared.timestampURL)
            }
        }
        .formStyle(.grouped)
    }
}

struct ChecksStep: View {
    @Bindable var a: Acquisition

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Checks before starting").font(.title3.bold())
                if a.estimating {
                    HStack { ProgressView().controlSize(.small); Text("Measuring the sources…") }
                }
                ForEach(a.checks) { c in
                    HStack(alignment: .firstTextBaseline) {
                        StatusIcon(c.state)
                        Text(c.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider().padding(.vertical, 6)
                Text("Summary").font(.title3.bold())
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow { Text("Evidence item").foregroundStyle(.secondary); Text(a.id + (a.description.isEmpty ? "" : " · " + a.description)) }
                    GridRow { Text("Case").foregroundStyle(.secondary); Text(a.model.title) }
                    GridRow { Text("Sources").foregroundStyle(.secondary); Text(a.sources.map(\.path).joined(separator: "\n")).lineLimit(6) }
                    GridRow { Text("Destination").foregroundStyle(.secondary); Text(a.model.url.appendingPathComponent("evidence/\(a.id)/\(a.id).xiz").path).lineLimit(2) }
                }
                Divider().padding(.vertical, 6)
                Text("Warnings do not stop you and stay in the log. To start, type your name as in Settings: the checks and your confirmation go into the case log.")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("Operator", text: $a.confirmName, prompt: Text(Prefs.shared.examiner))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
            }
            .padding()
        }
    }
}

struct RunningStep: View {
    let a: Acquisition

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(a.id + (a.description.isEmpty ? "" : " · " + a.description)).font(.title2.bold())
            if let p = a.progress {
                ProgressView(value: p.fraction)
                HStack {
                    Text(String(format: "%.0f%%", p.fraction * 100)).monospacedDigit()
                    Text(Words.bytes(p.completedBytes) + " / " + Words.bytes(p.totalBytes)).monospacedDigit()
                    Spacer()
                    Text(Words.bytes(Int64(p.bytesPerSecond)) + "/s").monospacedDigit()
                    if p.bytesPerSecond > 0, p.totalBytes > p.completedBytes {
                        Text(String(format: String(localized: "about %@ left"),
                                    Duration.seconds(Double(p.totalBytes - p.completedBytes) / p.bytesPerSecond).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))))
                    }
                }
                .font(.callout)
                if let c = p.currentEntry { Text(c).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            } else {
                ProgressView().progressViewStyle(.linear)
                Text("Starting…").foregroundStyle(.secondary)
            }
            if a.paused { Label("Paused", systemImage: "pause.circle").foregroundStyle(.orange) }
            Text("SHA-256, MD5 and SHA-1 are computed while reading; at the end the archive is read back and verified, then the reports are signed. The Mac does not go to sleep meanwhile.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }
}

struct DoneStep: View {
    let a: Acquisition

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    StatusIcon(a.outcome).font(.largeTitle)
                    Text(a.resultText).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(a.reportChecks.enumerated()), id: \.offset) { _, c in
                    HStack(alignment: .firstTextBaseline) {
                        StatusIcon(check: XizForensic.Check.Status(rawValue: c["status"] ?? "") ?? .skipped)
                        Text(Words.check(c["name"] ?? "")).bold()
                        Text(c["detail"] ?? "").foregroundStyle(.secondary)
                    }
                }
                if let r = a.result {
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                        GridRow { Text(r.method == "logical" ? "Inventory SHA-256" : "Source SHA-256").foregroundStyle(.secondary)
                            Text(r.sourceSHA256).font(.system(.callout, design: .monospaced)).textSelection(.enabled) }
                        if let m = r.md5 { GridRow { Text("MD5").foregroundStyle(.secondary); Text(m).font(.system(.callout, design: .monospaced)).textSelection(.enabled) } }
                        GridRow { Text("Archive SHA-256").foregroundStyle(.secondary)
                            Text(r.archiveSHA256).font(.system(.callout, design: .monospaced)).textSelection(.enabled) }
                    }
                    Text("Write the archive's SHA-256 into the written record.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }
}
