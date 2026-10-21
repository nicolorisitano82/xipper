import SwiftUI
import XipperKit

/// Settings: standard grouped forms, no custom glass.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Generali", systemImage: "gearshape") { GeneralSettings() }
            Tab("Formati", systemImage: "archivebox") { FormatSettings() }
            Tab("Sicurezza", systemImage: "lock") { SecuritySettings() }
            Tab("Integrazioni", systemImage: "square.stack.3d.up") { IntegrationSettings() }
            Tab("Genomica", systemImage: "testtube.2") { GenomicsSettings() }
            Tab("Prestazioni", systemImage: "cpu") { PerformanceSettings() }
        }
        .frame(width: 560, height: 420)
    }
}

private struct GeneralSettings: View {
    @AppStorage(PrefKey.defaultFormat) private var format = ArchiveFormat.zip.rawValue
    @AppStorage(PrefKey.levelPreset) private var preset = LevelPreset.balanced.rawValue
    @AppStorage(PrefKey.revealAfter) private var reveal = true
    @AppStorage(PrefKey.updatesAutomatic) private var updates = true

    var body: some View {
        Form {
            Picker("Formato predefinito", selection: $format) {
                ForEach(ArchiveFormat.multiItem) { Text($0.displayName).tag($0.rawValue) }
            }
            Picker("Compressione", selection: $preset) {
                ForEach(LevelPreset.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Toggle("Mostra il risultato nel Finder al termine", isOn: $reveal)
            Section("Aggiornamenti") {
                Toggle("Cerca aggiornamenti ogni giorno", isOn: $updates)
                LabeledContent("Versione", value: Updates.runningVersion)
                Button("Cerca aggiornamenti…") { UpdateController.shared.checkForUpdates() }
                Text("Xipper chiede a GitHub se c'è una versione nuova e la scarica solo se glielo dici. L'installazione resta manuale: trascini Xipper in Applicazioni come la prima volta.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct FormatSettings: View {
    @AppStorage(PrefKey.zipMethod) private var method = "deflate"
    @AppStorage(PrefKey.storeCompressed) private var store = true
    @AppStorage(PrefKey.keepMacFiles) private var keepMac = false
    @AppStorage(PrefKey.sevenZipEncryptNames) private var encryptNames = true
    @AppStorage(PrefKey.zipAppleDouble) private var appleDouble = false
    @AppStorage(PrefKey.sevenZipSolid) private var solid = true

    var body: some View {
        Form {
            Section("ZIP") {
                Picker("Metodo", selection: $method) {
                    Text("Deflate (compatibile ovunque)").tag("deflate")
                    Text("Zstandard (più veloce, 7-Zip/WinZip)").tag("zstd")
                    Text("Nessuna compressione").tag("store")
                }
                Toggle("Non ricomprimere file già compressi (foto, video, archivi)", isOn: $store)
                Toggle("Includi file nascosti del Mac (.DS_Store, ._*)", isOn: $keepMac)
            Toggle("Salva tag e attributi del Mac (cartella __MACOSX, come il Finder)", isOn: $appleDouble)
            }
            Section("7z") {
                Toggle("Compressione solid (archivi più piccoli, estrazione di un singolo file più lenta)", isOn: $solid)
                Toggle("Con la password, cifra anche i nomi dei file", isOn: $encryptNames)
            }
            Section {
                Text("Gli archivi tar.zst sono i più veloci e compatti per backup e scambio tra Mac e Linux; ZIP resta il più compatibile con Windows.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SecuritySettings: View {
    @AppStorage(PrefKey.propagateQuarantine) private var quarantine = true
    @AppStorage(PrefKey.symlinkPolicy) private var symlinks = "inside"
    @AppStorage(PrefKey.maxRatio) private var ratio = 1000.0
    @AppStorage(PrefKey.vaultRequiresAuth) private var vaultAuth = true
    @State private var savedPasswords = PasswordVault.count

    var body: some View {
        Form {
            Toggle("Applica la quarantena ai file estratti da archivi scaricati", isOn: $quarantine)
            Picker("Collegamenti simbolici", selection: $symlinks) {
                Text("Solo dentro la cartella di destinazione").tag("inside")
                Text("Tutti (archivi fidati)").tag("all")
                Text("Nessuno").tag("none")
            }
            Picker("Protezione zip bomb", selection: $ratio) {
                Text("Standard (1000:1)").tag(1000.0)
                Text("Rigida (100:1)").tag(100.0)
                Text("Permissiva (100 000:1)").tag(100_000.0)
            }
            Section("Password degli archivi") {
                Toggle("Chiedi Touch ID per usare le password salvate", isOn: $vaultAuth)
                LabeledContent("Salvate nel Portachiavi", value: "\(savedPasswords)")
                Button("Dimentica tutte le password", role: .destructive) {
                    PasswordVault.removeAll()
                    savedPasswords = PasswordVault.count
                }
                .disabled(savedPasswords == 0)
            }
            Section {
                Text("Xipper non scrive mai fuori dalla cartella di destinazione, non segue collegamenti durante l'estrazione e rimuove i permessi setuid.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct GenomicsSettings: View {
    @AppStorage(PrefKey.genomicsBGZF) private var bgzf = true
    @AppStorage(PrefKey.bgzfIndex) private var index = false

    var body: some View {
        Form {
            Toggle("Comprimi VCF, BED, GFF, FASTA, FASTQ e SAM in BGZF", isOn: $bgzf)
            Toggle("Crea anche l'indice .gzi", isOn: $index)
            Section {
                Text("BGZF (bgzip) è leggibile da qualsiasi gunzip ed è il formato richiesto da tabix, bcftools e samtools. BAM, CRAM e BCF non vengono mai ricompressi dentro gli archivi.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct IntegrationSettings: View {
    @AppStorage(PrefKey.mcpFolders) private var foldersRaw = ""
    @AppStorage(PrefKey.mcpReadOnly) private var readOnly = false
    @AppStorage(PrefKey.menuBarExtra) private var menuBar = false
    @State private var copied = false

    private var folders: [String] { foldersRaw.split(separator: "\n").map(String.init) }
    private var cli: String { Bundle.main.bundlePath + "/Contents/Helpers/xipper" }

    var body: some View {
        Form {
            Section {
                Toggle("Icona nella barra dei menu", isOn: $menuBar)
                Text("Mostra i lavori in corso e apre Xipper dalla barra dei menu.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                ForEach(folders, id: \.self) { f in
                    HStack {
                        Label(f, systemImage: "folder").lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Rimuovi", systemImage: "minus.circle") {
                            foldersRaw = folders.filter { $0 != f }.joined(separator: "\n")
                        }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
                Button("Aggiungi cartella consentita…", systemImage: "plus") { addFolder() }
                Toggle("Sola lettura (solo elencare e verificare)", isOn: $readOnly)
                Button(copied ? String(localized: "Comando copiato") : String(localized: "Copia comando per Claude Code"), systemImage: copied ? "checkmark" : "doc.on.doc") {
                    let args = folders.map { "--allow \"\($0)\"" }.joined(separator: " ") + (readOnly ? " --read-only" : "")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("claude mcp add --transport stdio --scope user xipper -- \"\(cli)\" mcp \(args)", forType: .string)
                    copied = true
                }
                .disabled(folders.isEmpty)
            } header: {
                Label("Assistenti AI (MCP)", systemImage: "point.3.connected.trianglepath.dotted")
            }
            Section {
                Text("Gli assistenti possono usare solo le cartelle elencate. Le password non passano mai dalla chat: restano nel Portachiavi. Ogni operazione è registrata in ~/Library/Logs/Xipper/mcp-audit.jsonl.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Consenti")
        guard panel.runModal() == .OK, let u = panel.url, !folders.contains(u.path) else { return }
        foldersRaw = (folders + [u.path]).joined(separator: "\n")
    }
}

private struct PerformanceSettings: View {
    @AppStorage(PrefKey.useEfficiencyCores) private var efficiency = false

    var body: some View {
        Form {
            LabeledContent("Core ad alte prestazioni", value: "\(CPUTopology.performanceCores)")
            LabeledContent("Core ad alta efficienza", value: "\(CPUTopology.efficiencyCores)")
            Toggle("Lavora in background sui core ad alta efficienza", isOn: $efficiency)
            Section {
                Text("Di norma Xipper usa i core ad alte prestazioni, che rendono di più quando aspetti il risultato. In background consuma meno energia ma impiega più tempo.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
