import Foundation
import XipperKit

/// User preferences (Settings window), stored in UserDefaults.
enum PrefKey {
    static let defaultFormat = "defaultFormat"
    static let zipMethod = "zipMethod"
    static let levelPreset = "levelPreset"
    static let storeCompressed = "storeAlreadyCompressed"
    static let keepMacFiles = "keepMacFiles"
    static let revealAfter = "revealInFinderAfter"
    static let propagateQuarantine = "propagateQuarantine"
    static let symlinkPolicy = "symlinkPolicy"
    static let maxRatio = "maxCompressionRatio"
    static let genomicsBGZF = "genomicsUsesBGZF"
    static let bgzfIndex = "writeBGZFIndex"
    static let useEfficiencyCores = "useEfficiencyCores"
    static let mcpFolders = "mcpAllowedFolders"
    static let mcpReadOnly = "mcpReadOnly"
    static let vaultRequiresAuth = "vaultRequiresTouchID"
    static let onboardingDone = "onboardingDone"
    static let updatesAutomatic = "updatesAutomatic"
    static let menuBarExtra = "showMenuBarExtra"
    static let sevenZipEncryptNames = "sevenZipEncryptNames"
    static let sevenZipSolid = "sevenZipSolid"
    static let updatesLastCheck = "updatesLastCheck"
    static let updatesAnnounced = "updatesAnnounced"
}

/// Speed/size trade-off shown in the UI instead of raw per-codec levels.
enum LevelPreset: String, CaseIterable, Identifiable {
    case fast, balanced, best
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fast: String(localized: "Veloce")
        case .balanced: String(localized: "Normale")
        case .best: String(localized: "Massimo")
        }
    }

    /// Concrete level for a format (nil = format default).
    func level(for format: ArchiveFormat, zipMethod: ZipMethod) -> Int? {
        switch (self, format) {
        case (.balanced, _): return nil
        case (.fast, .zip): return zipMethod == .zstd ? 1 : 1
        case (.best, .zip): return zipMethod == .zstd ? 19 : 9
        case (.fast, .tarZstd), (.fast, .zstd): return 1
        case (.best, .tarZstd), (.best, .zstd): return 19
        case (.fast, .tarXz), (.fast, .xz): return 1
        case (.best, .tarXz), (.best, .xz): return 9
        case (.fast, _): return 1
        case (.best, _): return 9
        }
    }
}

enum Preferences {
    static var defaults: UserDefaults { .standard }

    static func register() {
        defaults.register(defaults: [
            PrefKey.defaultFormat: ArchiveFormat.zip.rawValue,
            PrefKey.zipMethod: "deflate",
            PrefKey.levelPreset: LevelPreset.balanced.rawValue,
            PrefKey.storeCompressed: true,
            PrefKey.keepMacFiles: false,
            PrefKey.revealAfter: true,
            PrefKey.propagateQuarantine: true,
            PrefKey.symlinkPolicy: "inside",
            PrefKey.maxRatio: 1000.0,
            PrefKey.genomicsBGZF: true,
            PrefKey.bgzfIndex: false,
            PrefKey.useEfficiencyCores: false,
            PrefKey.mcpReadOnly: false,
            PrefKey.vaultRequiresAuth: true,
            PrefKey.updatesAutomatic: true,
            PrefKey.sevenZipEncryptNames: true,
            PrefKey.sevenZipSolid: true,
        ])
    }

    static var workload: Workload { defaults.bool(forKey: PrefKey.useEfficiencyCores) ? .background : .interactive }

    static var zipMethod: ZipMethod {
        switch defaults.string(forKey: PrefKey.zipMethod) {
        case "zstd": .zstd
        case "store": .store
        default: .deflate
        }
    }

    static func createOptions(format: ArchiveFormat, preset: LevelPreset, password: String?) -> CreateOptions {
        var o = CreateOptions()
        o.format = format
        o.zipMethod = zipMethod
        o.level = preset.level(for: format, zipMethod: o.zipMethod)
        o.password = format.supportsPassword ? password : nil
        o.storeAlreadyCompressed = defaults.bool(forKey: PrefKey.storeCompressed)
        o.scan.excludeMacMetadata = !defaults.bool(forKey: PrefKey.keepMacFiles)
        o.genomicsUsesBGZF = defaults.bool(forKey: PrefKey.genomicsBGZF)
        o.writeBGZFIndex = defaults.bool(forKey: PrefKey.bgzfIndex)
        o.encryptFileNames = defaults.bool(forKey: PrefKey.sevenZipEncryptNames)
        // nil = automatic solid blocks; 0 = one block per file.
        o.solidBlockSize = defaults.bool(forKey: PrefKey.sevenZipSolid) ? nil : 0
        o.workload = workload
        return o
    }

    static func extractOptions(password: String?) -> ExtractOptions {
        var o = ExtractOptions()
        o.password = password
        o.propagateQuarantine = defaults.bool(forKey: PrefKey.propagateQuarantine)
        o.symlinks = switch defaults.string(forKey: PrefKey.symlinkPolicy) {
        case "all": .allowAll
        case "none": .skipAll
        default: .insideDestinationOnly
        }
        o.limits.maxCompressionRatio = defaults.double(forKey: PrefKey.maxRatio)
        o.workload = workload
        return o
    }
}

extension ArchiveFormat {
    /// Name shown in menus.
    var displayName: String {
        switch self {
        case .zip: "ZIP"
        case .tar: "tar"
        case .tarGzip: "tar.gz"
        case .tarBzip2: "tar.bz2"
        case .tarXz: "tar.xz"
        case .tarZstd: "tar.zst"
        case .gzip: "gzip (.gz)"
        case .bgzf: "BGZF (bgzip)"
        case .bzip2: "bzip2 (.bz2)"
        case .xz: "xz (.xz)"
        case .zstd: "zstd (.zst)"
        case .sevenZip: "7z"
        }
    }

    /// Formats offered when compressing several items or a folder.
    static let multiItem: [ArchiveFormat] = [.zip, .sevenZip, .tarZstd, .tarGzip, .tarXz, .tarBzip2, .tar]
    static let singleFile: [ArchiveFormat] = [.gzip, .bgzf, .zstd, .xz, .bzip2]
}

extension Int64 {
    var byteText: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
