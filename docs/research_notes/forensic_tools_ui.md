# Strumenti di acquisizione forense: UI, workflow e funzionalità (stato a novembre 2026)

Note di ricerca per il design di **xipper-forensic** (app macOS: acquisizione disco/volume/logica in un archivio firmato e verificabile, con catena di custodia).
Fuori ambito: formati E01/AFF4 (già coperti), normativa italiana (già coperta).

Convenzioni: `[Rn]` rimanda all'elenco fonti in fondo. **[da verificare]** = affermazione non confermata da fonte primaria (spesso deriva da conoscenza pregressa o da fonti secondarie deboli). I nomi di campi/etichette sono riportati in inglese come appaiono nelle UI.

---

## 0. Sintesi in 10 righe

1. Il **wizard lineare** (sorgente → formato → metadati caso → destinazione/opzioni → avvio → verifica → log) è lo standard de facto da FTK Imager a Belkasoft [R1][R4][R46]. Gli hardware imager (TX1/TX2, Atola) usano invece una **schermata di setup unica a sezioni numerate** modificabili in qualunque ordine, con default intelligenti e auto-selezione se c'è una sola sorgente/destinazione [R30].
2. **Metadati caso minimi universali**: Case Number, Evidence Number, Examiner, Description, Notes (FTK, Guymager, EnCase/E01) [R1][R12]. TX1 riduce a Name / Case ID / Notes [R30].
3. **Hash**: MD5+SHA-1 ancora il default (E01 non supporta SHA-256 nativamente [R30]); SHA-256 opzionale ovunque; TX1 limita a max 2 algoritmi per non degradare le prestazioni [R30].
4. **Verifica** = rilettura dell'immagine e confronto hash (raddoppia i tempi [R58]); Guymager offre anche la **rilettura della sorgente** [R12]. TX2 introduce **parallel hash verification** e **tree hashing** (hash a blocchi + hash di livello superiore) come differenziatore "industry first" [R31]; Atola usa **segmented hashing** e **block-map hash Merkle SHA-512** per AFF4 [R33][R36].
5. **Settori danneggiati**: tre livelli di sofisticazione: (a) zero-fill + log (FTK, Guymager) [R12]; (b) granularità errore + retry (TX1: Standard 32 kB / Exhaustive 1 settore; retry 0…100) [R30]; (c) multi-pass configurabile con timeout/jump/reverse/head-disable e Media Map (Atola) [R34][R35].
6. **Progress**: velocità media/corrente, tempo residuo, % completamento, bad sectors, uso FIFO (Guymager) [R12]; header con data rate/ETA/% e sotto-fasi separate Duplication/Verification (TX1) [R30].
7. **Mac Apple Silicon (2026)**: niente Target Disk Mode; **Share Disk** di recoveryOS espone solo i file via SMB (logico) [R49][R51][R27]. Le immagini "fisiche" decifrate sono in pratica immagini decifrate di **volumi APFS** fatte dal Mac stesso (live o avviato dal dispositivo del vendor, con riduzione della Secure Boot) [R21][R22][R28][R55]. Il prodotto di riferimento è Cellebrite Digital Collector 3.9 (macOS Tahoe 26, M1–M4) [R22]; RECON ITR dichiara M1–M6 e macOS 27 [R28][R29]; Fuji è l'opzione gratuita (ASR/rsync → DMG) [R52][R53].
8. **Catena di custodia** quasi assente come funzione esplicita: si riduce a log testuale/HTML con utente, timestamp, versione firmware, numero di serie [R30][R1]. Nessuno strumento visto firma crittograficamente il pacchetto evidenza con identità dell'operatore → **spazio per xipper-forensic**.
9. **Logging/report**: .txt accanto all'immagine (FTK [R1]), info file Guymager con output smartctl/hdparm [R12], log HTML filtrabili TX1 [R30], report HTML/PDF/CSV RECON [R28], report diagnostica pre/post con tabelle SMART Atola [R35].
10. **Pain point** ricorrenti: lentezza e verifica che raddoppia i tempi, zero-fill silenzioso dei settori illeggibili, incompatibilità E01 tra strumenti, costi alti per Mac (DC, RECON), interruzione della Secure Boot su Apple Silicon e difficoltà a ripristinarla, assenza di uno strumento Mac nativo moderno e gratuito con UX curata.

---

## 1. FTK Imager (Exterro) — Windows; Pro dal 2025

| Aspetto | Dettaglio | Fonte |
|---|---|---|
| Versioni | Download page elenca FTK Imager 8.3 / 8.3.1, FTK Imager Pro 8.2 SP1 / 8.2.0.26 | [R6] |
| Prezzo | Free; **FTK Imager Pro** $499/utente/anno (lancio 25 set 2025), stesso installer, sblocco via licenza | [R7][R8][R63] |
| Piattaforme | Pagina Exterro elenca solo Windows. Nessun build macOS GUI nativo ufficiale trovato; esistevano CLI per macOS 10.5/10.6 (era AccessData 3.1.1). Siti terzi affermano "nessuna build macOS nativa" | [R5][R10][R9] — **build macOS attuale: [da verificare] con Exterro** |
| Avvio workflow | `File > Create Disk Image` | [R1][R4] |
| Wizard (ordine) | 1 Select Source (Physical Drive / Logical Drive / Image File / Contents of a Folder / Fernico Device) → 2 selezione drive → 3 Create Image: lista "Image Destination(s)" con `Add...` + checkbox → 4 Select Image Type (Raw (dd), SMART, E01, AFF) → 5 Evidence Item Information → 6 Select Image Destination (cartella, nome file, Image Fragment Size, Compression, Use AD Encryption) → 7 `Start` | [R1][R4]; tipi sorgente Image File/Contents of a Folder/Fernico, Compression: **[da verificare]** |
| Campi caso (esatti) | `Case Number`, `Evidence Number`, `Unique Description`, `Examiner`, `Notes` | [R1][R2] |
| Opzioni (checkbox) | `Verify images after they are created`; `Precalculate Progress Statistics`; `Create directory listings of all files in the image after they are created` (output enorme su dischi reali) | [R1][R2] |
| Più destinazioni | Più destinazioni/formati per la stessa sorgente nella lista Image Destination(s); esecuzione in coda sequenziale **[da verificare]** | [R1] |
| Split | `Image Fragment Size` (dimensione max dei file segmento) | [R1] — default 1500 MB, 0 = nessuno split **[da verificare]** |
| Hash | MD5 + SHA-1 calcolati e verificati; SHA-256 non nei report classici **[da verificare per 8.x]** | [R2][R4] |
| Verifica | Post-acquisizione automatica (checkbox) o manuale (click destro sull'evidenza → `Verify Drive/Image`). Finestra risultati con MD5/SHA-1 computed vs stored e lista bad sector | [R1][R4] |
| Progress | Finestra con sorgente, destinazione, stato, barra, tempo trascorso/stimato **[da verificare: etichette esatte]** | [R1] |
| Bad sector | Riportati nella finestra di verifica e nel log; nessuna opzione di retry/granularità in UI **[da verificare]** | [R4] |
| Report | `<nome-immagine>.txt` nella stessa cartella: info caso, dettagli drive, hash, tempi inizio/fine, elenco segmenti, risultati verifica | [R1] |
| Cifratura output | "AD Encryption" (AD1 custom content image, password) + `File > Decrypt AD1 Image` | [R4] |
| Triage/preview | Albero evidenze con browsing file prima dell'acquisizione; `Custom Content Image` (AD1) per selezione file; `Capture Memory`; `Obtain Protected Files`; `Detect EFS Encryption`; `Image Mounting`; `Export Files` | [R4][R5] |
| Pro | BitLocker/APFS-FileVault/McAfee/Symantec on-the-fly decryption con credenziali, "Direct Decrypted - Live Data"; iOS logical/advanced logical; Android in roadmap | [R7][R8] |
| NIST CFTT | Ultimo report FTK Imager 4.3.0.18 (01/07/2020); prima 3.4.2.6 (2016) | [R47] |
| Lamentele | Rallentamenti a metà acquisizione, drive cifrati che non comprimono, verifica che raddoppia i tempi su sistemi live | [R58][R59] |

---

## 2. Guymager (Linux, open source, Qt)

Ultima release upstream 0.8.13 (2021), solo rebuild di distro nel 2024–2025 [R16].

| Aspetto | Dettaglio | Fonte |
|---|---|---|
| Finestra principale | **Tabella dispositivi** in alto (pulsante `Rescan`), pannello dettagli in basso per il dispositivo selezionato. Colonne di default: `SerialNr`, `LinuxDevice`, `Model`, `State`, `Size`, `HiddenAreas`, `BadSectors`, `Progress`, `AverageSpeed`, `TimeRemaining`, `FifoUsage`; nascoste: `NativePath`, `ByPath`, `Interface`, `AdditionalStateInfo`, `SectorSizeLog/Phys`, `CurrentSpeed`, `UserField`, `Examiner` | [R11][R12] |
| Protezione disco sbagliato | Dischi locali (da tabella `LocalDevices`: serial/model/path, regex opzionale) mostrati in **rosso chiaro** e non acquisibili; `HiddenDevices` li nasconde | [R11][R12] |
| Flusso | Click destro sul device → `Acquire image` / `Clone device` → **un unico dialog** ("Acquire image of %1") → `Start`. Opz. `Duplicate image...` per una seconda copia con impostazioni proprie | [R13] |
| Gruppi dialog | `File format` (DD / EWF / AFF), `Destination`, `Hash calculation / verification` | [R13] |
| Campi caso (config) | `EwfCaseNumber`, `EwfEvidenceNumber`, `EwfExaminer`, `EwfDescription`, `EwfNotes` (default `%serial%`), `UserField`; destinazione `DestImageDirectory`, `DestImageFilename`, `DestInfoDirectory`, `DestInfoFilename`. Ogni campo può essere `ShowLast` / `ShowDefault` / `Hide` e avere default dinamici | [R12] |
| Campi EWF solo per EWF | Con dd i campi caso sono disabilitati | [R14] |
| Split | `SplitFileSwitch`, `SplitFileSize` (default 2047), `SplitFileUnit` (MiB…EiB); avviso oltre 14.972 segmenti EWF (.ZZZ) | [R12][R13] |
| Hash | `HashCalcMD5` (on), `HashCalcSHA1`, `HashCalcSHA256` (off) | [R12] |
| Verifica | `HashVerifySrc` (**rilegge la sorgente** e confronta, off), `HashVerifyDst` (verifica immagine, on) | [R12] |
| Bad sector | Settori illeggibili sostituiti con zeri, loggati e riportati nell'info file; DirectIO automatico per leggere singoli settori; `JobMaxBadSectors` (200) termina job oltre soglia se `LimitJobs`; throttling log | [R12][R61] |
| Parallelismo | Più acquisizioni simultanee (una per device); `LimitJobs` AUTO = metà CPU max 4, con coda; compressione EWF multi-thread; thread hash separato | [R11][R12] |
| Validazione nomi | Solo `a-z A-Z 0-9 _` di default; dialog d'errore "Special characters", "Files exist", "Destination in use", "Large amount of segment files" | [R12][R13] |
| Info file | `.info` con dati caso, hash, bad sector, output di `smartctl`/`hdparm`; CR/LF | [R12] |
| Integrazione | `RunStats` (template periodici), `CommandAcquisitionEnd` | [R12] |
| Cifratura output | Nessuna **[da verificare]** | — |
| NIST CFTT | 0.8.1 (ottobre 2016); test bad sector: nessun settore buono perso | [R47][R48] |
| Lamentele | Stato "finished successfully (with N bad sectors)" + verifica sorgente fallita: dibattito sul valore probatorio [R15]; errori di verifica E01 Guymager in EnCase [R60]; configurazione via file `.cfg` poco accessibile [R12] |

---

## 3. Magnet ACQUIRE / Magnet AXIOM Process

| Aspetto | Dettaglio | Fonte |
|---|---|---|
| Stato | ACQUIRE (gratuito) è stato incorporato in AXIOM (2016); stato attuale del download standalone **[da verificare]** | [R20] |
| Flusso AXIOM Process | `Evidence Sources > Computer > Windows > Acquire Evidence` → seleziona drive → `Next` → tipo immagine → `Next` → tipo di ricerca (search type) | [R17] |
| Tipi immagine | **Full**: immagine fisica E01 o raw (più lenta) oppure logica "all files and folders" in .zip (senza cancellati/non allocato). **Quick**: logica mirata (file di sistema, profili utente) in .zip, la più veloce | [R17] |
| Cifratura sorgente | Disco cifrato acquisito cifrato, senza decifrare; NAS non rilevabili via rete | [R17] |
| Mac | AXIOM Cyber: agente macOS remoto, **solo logico** (chiamate OS), richiede Remote Login/SSH; target predefiniti (history, quarantine, iOS backup, iCloud, unified log) | [R19] |
| Contenitore logico | **AFF4-L** default per acquisizioni logiche (AXIOM Cyber 4.5, set 2020); esempio Mac mini: 8,4 GB .zip vs 4 GB AFF4-L | [R18] |
| Campi caso, progress, bad sector | Non documentati nelle fonti accessibili **[da verificare]** | — |

---

## 4. Cellebrite Digital Collector (ex BlackBag MacQuisition) — principale concorrente Mac

| Aspetto | Dettaglio | Fonte |
|---|---|---|
| Versione | **3.9**: macOS Tahoe 26, live o avviato dal dispositivo DC, Apple Silicon M1–M4 + T2; salvataggio su destinazioni **SMB** con credenziali di dominio | [R22] |
| 3.8 (ott 2024) | Sequoia 15.x su M1–M3 e T2 | [R23] |
| Forma | Software su **SSD USB dedicato** (capacità a scelta), gira su Windows e macOS, boot del Mac sorgente nel suo ambiente nativo | [R21] |
| Modalità | Triage, live data acquisition (RAM Mac; 26 opzioni di raccolta dati di sistema: processi, stato, coda di stampa), targeted collection (email, chat, rubrica, calendario per utente/volume), imaging (disco intero, parziale, RAM) | [R21][R25] |
| Apple Silicon/T2 | "Unico" a creare immagini fisiche decifrate di T2 (incluso non allocato e Fusion) e di **volumi APFS** su M1–M4; **AFF4** per imaging APFS | [R21] |
| FileVault | Password, Keychain file o Recovery Key → mount **read-only** per triage e raccolta | [R21] |
| Windows | AFF4, E01, RAW; acquisisce dischi cifrati ma non decifra (lo fa Inspector) | [R21] |
| Write protection | Protezione sorgente + R/W destinazione "fully implemented" | [R21] |
| Triage | Browse per metadati o keyword prima della raccolta; anteprime Quick Look su macOS | [R21] |
| Hash | MD5, SHA-1, SHA-256 | [R21] |
| Logging | Log delle acquisizioni e degli attributi del device sorgente durante tutto il processo | [R21] |
| UI (MacQuisition) | Barra superiore `Data Collection` / `Image Device` / `Tools`; collezione dati in cartella o **sparse image** | [R25] |
| Albero decisionale (T2, 3.1) | Mac acceso → live logical (no immagine, modifica la sorgente) · Mac spento + host Mac 2012-2019 → TDM (più forense) · spento senza host → abbassare Secure Boot (serve admin) e avviare DC; FileVault: immagine richiede password o Recovery Key, logico anche keychain | [R24] |
| AFF4-L per logico | Nessuna conferma che DC esporti collezioni logiche Mac in AFF4-L (MacQuisition 3.7 produceva AFF4 fisico letto da AXIOM) | [R18] — **[da verificare]** |
| Prezzo | Non pubblico; percepito come costoso | [R55] |
| Lamentele | Boot environment rotto da aggiornamenti macOS (macOS 13 su Apple Silicon); dipendenza dalla coppia versione DC/versione macOS | [R26][R27] |

---

## 5. SUMURI RECON ITR e PALADIN

| Aspetto | RECON ITR | PALADIN | Fonte |
|---|---|---|---|
| Ruolo | Imaging, Triage, Reporting macOS | Distro Linux forense (LTS 9.4.2), Toolbox GUI | [R28][R29] |
| Apple Silicon | M1–M6 (Pro/Max/Ultra), "MacBook Neo", T2; macOS 27 | Non per Mac moderni (rimanda a RECON) | [R28][R29] |
| Immagine | "Verified, decrypted APFS or Volume image" su evidence drive; bootable e live | dd/E01 via Toolbox **[da verificare]** | [R28] |
| FileVault | Password admin o Recovery Key | — | [R28] |
| Snapshot | Confronto volume vs snapshot locali Time Machine per file modificati/cancellati | — | [R28] |
| Write-protection | Controllo **Disk Arbitration** (blocca auto-mount) | OS modificato: nessun auto-mount, write-block software | [R28][R29] |
| Verifica | Report di completamento con hash; `Verify After Creation` aggiunge l'esito | Logging integrato | [R28][R29] |
| Triage | Quick Triage ordinato per gravità (stato FileVault, snapshot, anti-forensics, device collegati, cloud account), triage backup iOS | Triage/search via Toolbox | [R28][R29] |
| Report | HTML, PDF, CSV, KML | — | [R28] |
| Prezzo | Da $1.295/anno (abbonamento, smette di funzionare se scade), SSD Samsung T7 + PALADIN PRO incluso | "Name your price" (min $25 corporate), PRO $99 | [R28][R29] |
| NIST | — | PALADIN 6.08/6.09 (2016); 6.09 ha forse perso pochi settori leggibili vicino ai bad sector | [R47][R48] |
| Lamentele | Forum: per Apple Silicon "live only", demo che si blocca (era M1) | — | [R27] |

---

## 6. OpenText (ex Tableau) Forensic TX1 / TX2 — hardware imager con UI touch

Fonte primaria: TX1 User Guide 25.4 (rev. 24 set 2025) [R30]; TX2 product overview (05/2025) [R31].

| Aspetto | Dettaglio | Fonte |
|---|---|---|
| UI | Touchscreen "tipo tablet", Home → `Duplicate` / `Hash` / `Logical image` / `Verify` / `Browse` / `Restore` / mobile backup; menu laterale; tab Jobs con aree **Automated Acquisition / Active / Queued / Recent**; interfaccia web remota (HTTPS) | [R30] |
| Setup job | Schermata unica a **step numerati espandibili** (1 Job Notes, 2 Source, 3 Destinations, 4 settings, 5 Image Settings), ordine libero, default visibili; auto-selezione se 1 sorgente e 1 destinazione → `Start Duplication` | [R30] |
| Campi caso | `Name`, `Case ID`, `Notes` (tastiera virtuale o USB) | [R30] |
| Nome cartella | Sottodirectory auto-generata: default Date and Time; opz. Model, Serial, Case ID; base `/tx1_images/` | [R30] |
| Precondizioni | Controllo automatico prima di ogni job: warning (continua/annulla) o fatali | [R30] |
| Indicatori | Lato sorgente **write-blocked** e destinazione R/W etichettati e colorati; triangolo arancione sui drive in uso, bordo arancione se in coda | [R30] |
| Concorrenza | 1 sorgente → fino a 4 destinazioni; **2 job attivi** contemporanei; destinazioni miste clone/immagine/locale/rete (iSCSI, CIFS) | [R30] |
| Formati / split | Ex01, E01, DD, DMG; compressione default su E01/Ex01; segmenti da 2 GB a Unlimited (FAT32 max 2 GB); avviso DMG da settori ≠ 512 B | [R30] |
| Hash | Max 2 tra MD5/SHA-1/SHA-256; **E01 richiede MD5+SHA-1 e non supporta SHA-256** | [R30] |
| Errori lettura | `Error Granularity`: Standard (32 kB, zero-fill) / Exhaustive (fino a 1 settore); `Error retry` (attenzione con 10 o 100) | [R30] |
| Pausa/ripresa | Pause/Resume per E01/Ex01/DD/DMG, anche dopo **perdita di alimentazione** | [R30] |
| Progress | Header: stato, data rate globale, tempo residuo, %; sotto-fasi (Duplication vs Verification), riepilogo impostazioni, tile dei drive → dettagli | [R30] |
| Verifica | Standalone `Verify`: rilegge l'immagine, ricalcola hash, confronta con quello di acquisizione (fisico: hash disco; logico: hash per file) | [R30] |
| Log | Per job: Status (Incomplete/Ok/Error/Cancelled, timestamp, username, job notes, unità e firmware), Source (interfaccia, modello, firmware, seriale, HPA/DCO/AMA, RAID, cifratura, layout, filesystem), Acquisition Results (blocchi, hash, errori lettura), Configuration (formato, segmenti, compressione, criteri di ricerca logica); log HTML filtrabili; `View Log` da job concluso | [R30] |
| Cifratura | Rilevamento Opal/BitLocker/APFS/FileVault/Core Storage/RAID; sblocco BitLocker (anche Clear Key), Opal, APFS (solo sorgente); destinazione cifrata **XTS-AES whole-disk** con password (non recuperabile) | [R30] |
| Utilità | Wipe (NIST 800-88r1), format, rimozione HPA/DCO/AMA, blank check, SMART, browse filesystem | [R30] |
| Utenti | Gestione utenti, blocco sistema con PIN, 802.1X | [R30] |
| Mac | Adattatori per **Target Disk Mode** (USB-C, FireWire, Thunderbolt 2) e troubleshooting TDM: utile solo per Mac Intel | [R30] |
| **TX2** | "Parallel hash verification" (stati hash a inizio/fine blocco → verifica parallela, fallisce subito al primo blocco errato), **tree hashing** (hash a chunk + hash sequenziale dei chunk), fino a 5× più veloce, MFA con YubiKey PIV, gallery thumbnail per triage, riconfigurazione destinazione in un job (HPA/DCO removal + wipe + format + encrypt), avvio automatico job in base alle risorse | [R31] |
| NIST CFTT | TX1 22.3.0 (11/04/2023), 21.3 (2022) | [R47] |

---

## 7. Atola TaskForce / TaskForce 2 / Insight Forensic — riferimento per i settori danneggiati

| Aspetto | Dettaglio | Fonte |
|---|---|---|
| Forma | Hardware con **UI web** (Chrome, più workstation), ruoli Admin/User (2022), LDAP (2025.11), blocco per inattività | [R33][R38] |
| Concorrenza | TaskForce: fino a 18 sessioni parallele, 1 sorgente → 5 target; TF2: 25+ device, 25 TB/h cumulativi; iSCSI (2025.4); fibra 25G | [R32][R39] |
| Formati | E01, RAW/img/dd, AFF4 (block hash nativi + **block map hash SHA-512 Merkle**), target VeraCrypt cifrati | [R32][R33] |
| Hash | MD5, SHA-1, SHA-256, SHA-512; linear (pre/durante/post) o **segmented** (CSV start/end LBA + hash, linkato nel report) | [R32][R36] |
| Multi-pass (Insight) | Preset 5 pass: P1 timeout 1 s, jump 1.000.000, blocco 4096 · P2 5 s, 20.000 · P3 5 s, 4096 · P4 jump 256, blocco 256 · P5 60 s, jump 1, blocco 256. Parametri per pass: `Timeout`, `Jump on error`, `Max read block size`, LBA start/end, `Reverse direction`, `Disable read look-ahead`, `Use PIO mode`; `Add pass` / X / `Save settings` | [R34] |
| Errori | Settori illeggibili saltati o riempiti con pattern (default 00, custom hex o da file); skip dei bad già noti nei pass successivi | [R35] |
| Testine | Diagnostica identifica testine danneggiate → disabilitarle e acquisire con le restanti (es. 7/8 ≈ 87%) | [R35] |
| Media Map | Stato per settore: imaged / unimaged / imaged-without-ECC; Media Map Manager per includere/escludere range; File Recovery mostra file parzialmente acquisiti | [R35] |
| Formato e danni | E01 lineare limita reverse/jump; per sorgenti danneggiate consigliati RAW o AFF4 | [R37] |
| Report | Diagnostica pre-acquisizione (firmware, stima tempo, partizioni, grafico temperatura, HPA/DCO/AMA) + Imaging Results; due report SMART (prima/dopo) | [R33][R35] |
| Casi | Case number condiviso tra drive, note dopo chiusura, export/import caso in un file | [R35] |
| Cifratura | Decifra APFS (password/recovery key); rileva BitLocker; entropia in tempo reale durante l'imaging | [R33] |
| Prezzo | Non pubblico **[da verificare]** | — |

---

## 8. X-Ways Imager e EnCase Imager

| Aspetto | X-Ways Imager | EnCase Imager | Fonte |
|---|---|---|---|
| Natura | Versione ridotta di X-Ways Forensics, portable (USB), a pagamento | Imager di Guidance/OpenText; download gratuito non più disponibile (commento 2018) | [R40][R41] |
| Formati | Raw, E01, conversione tra formati | E01 / Ex01 (Ex01: AES-256 con chiavi o password, compressione, MD5/SHA-1) | [R40][R42] |
| Specialità | Opzione **ometti spazio libero**, aree zero marcate sparse, HPA/DCO, ricostruzione RAID (JBOD/0/5/6), **reverse imaging** per dischi che si bloccano a un certo settore, compressione adattiva che salta i dati incomprimibili, "technical details report" | Campi caso (case number), password/cifratura, hash nel report | [R40][R41] |
| Limiti | Niente contenitori evidenza, skeleton o cleansed image | Campi esatti (Name, Evidence Number, Notes, Error granularity, Block size, Reads from source) **[da verificare]** | [R40] |
| NIST | X-Ways Forensics 18.8 (2016) | EnCase 8.05 / 7.12 (2018) | [R47] |

---

## 9. Autopsy — pattern di gestione caso

| Step | Dettaglio | Fonte |
|---|---|---|
| New Case Wizard | Da Welcome o `Case > Create New Case`: 1) `Case Name` + `Base Directory` (errore se esiste già) 2) Case type (solo multi-user) 3) **info opzionali** (case number, examiner/reviewer; sezione Organization solo con central repository) | [R43][R45] |
| Dopo la creazione | Parte automaticamente `Add Data Source` | [R43][R45] |
| Add Data Source | 1) **Host** (nuovo dal nome sorgente / nome nuovo / esistente) 2) tipo (Disk Image or VM File, Local Disk, Logical Files, Unallocated Space Image, Autopsy Logical Imager Results, XRY) 3) opzioni per tipo: timezone, sector size (Auto Detect), password BitLocker, **hash attesi dell'immagine** (verificati dal Data Source Integrity module), orphan files FAT; Local Disk: crea copia **VHD** durante l'analisi 4) profilo/moduli ingest 5) elaborazione in background, browsing subito | [R44] |
| Modifica | `Case > Case Details > Edit Details` | [R43] |
| Lezione | Separare **caso** (persistente, riusabile) da **sorgente** (N per caso); campi opzionali non bloccanti; hash attesi come input di verifica | — |

---

## 10. Belkasoft X / Oxygen (rilevanza limitata)

Belkasoft X: `Add a data source → Acquire → Drive`; lista **Source drive** con identificazione di sistema, seriale, capacità, e drive logici annidati sotto i fisici; opzioni: RAW o E01, checksum SHA-1/SHA-256/MD5, `Verify output`, split in chunk [R46]. Oxygen: non approfondito (focus mobile) **[da verificare se rilevante]**.

---

## 11. macOS e Apple Silicon: stato 2026

| Tema | Stato | Fonte |
|---|---|---|
| Target Disk Mode | Assente su Apple Silicon; TDM resta per Mac Intel (adattatori TX1, workflow DC 3.1) | [R27][R30][R24] |
| **Share Disk** | recoveryOS → `Utilities > Share Disk` → sblocco FileVault → `Start Sharing`; l'altro Mac vede la condivisione in Finder `Network`, connessione come **Guest**. È **SMB a livello di file**, non block device → solo acquisizione logica; Finder monta R/W, serve `mount_smbfs -o ro`; ordine di connessione del cavo/alimentazione conta | [R49][R50][R51] |
| Utilità Share Disk forense | "Relativamente inutile" per scopi forensi secondo alcuni (vede solo file logici) | [R27] |
| Imaging "fisico" | Solo decifrato a livello di volume APFS dal Mac stesso: live, o avviando il tool del vendor con Secure Boot ridotta (serve admin); su Apple Silicon la Secure Boot resta attiva anche da disco esterno; Permissive Security solo da riga di comando | [R21][R24][R56][R57] |
| Prassi 2026 | "Physical imaging of modern Macs is pretty much dead"; si fa logico/FFS con DC, RECON ITR o Fuji; servono credenziali utente; disabilitare Secure Boot richiede poi Wi-Fi per ripristinarla → documentarlo e avvisare il custode; firmware password = blocco | [R55] |
| Vendor-agent | AXIOM Cyber: agente remoto, solo logico, ZIP o AFF4-L | [R19] |
| Binalyze AIR | Imaging macOS: tipicamente disco fisico (volumi APFS problematici), richiede SIP disattivato **[da verificare: pagina non leggibile]** | [R62] |
| **Fuji** (Lazzarotto, GPL-3) | App Python live, Intel e Apple Silicon (anche 10.13), metodi **ASR** e **rsync** (rsync per cartelle specifiche/FS danneggiati), output DMG via sparseimage temporanea; richiede **Full Disk Access** (errore "operation not permitted" altrimenti); FFS logico (solo file esistenti) | [R52][R53][R54] |
| ASLA (Totaro) | Script bash sull'host per Share Disk: cp/rsync → `ACQUISITION.sparseimage`, MD5/SHA-1 opzionali, file .out/.log/.err | [R51] |
| Tool Mac nativi esistenti | Digital Collector (USB dedicato, UI propria), RECON ITR (SSD dedicato), Fuji (GUI semplice), script (ASLA). **Nessun tool commerciale con UI SwiftUI moderna e firma dell'evidenza** trovato | [R21][R28][R53][R51] |
| FTK Imager su Mac | Nessuna versione GUI nativa confermata; consigli: VM Windows, dc3dd/ewfacquire, tool commerciali | [R9][R10] |

---

## 12. Sintesi trasversale

### 12.1 Must-have (presenti in quasi tutti i tool)

| # | Funzione | Dove |
|---|---|---|
| M1 | Lista dispositivi con modello, seriale, dimensione, interfaccia; protezione contro il disco sbagliato (disco di sistema evidenziato/non selezionabile) | Guymager [R12], Belkasoft [R46], TX1 [R30] |
| M2 | Indicatore chiaro di sola lettura/write-block su sorgente e R/W su destinazione | TX1 [R30], DC [R21], PALADIN/RECON [R28][R29] |
| M3 | Campi caso: Case Number, Evidence Number, Examiner, Description, Notes (con "ricorda l'ultimo valore") | FTK [R1], Guymager [R12] |
| M4 | Scelta formato + split (dimensione segmento) + compressione | tutti |
| M5 | Hash multipli (MD5/SHA-1 + SHA-256) calcolati durante l'acquisizione | tutti |
| M6 | Verifica post-acquisizione (rilettura immagine) | FTK, Guymager, TX1, Belkasoft |
| M7 | Progress con %, velocità, ETA, contatore bad sector | Guymager [R12], TX1 [R30] |
| M8 | Settori illeggibili: zero-fill + elenco nel log | Guymager [R12], TX1 [R30] |
| M9 | Log/report testuale accanto all'immagine con hash, tempi, info device, versione tool | FTK [R1], TX1 [R30], Guymager [R12] |
| M10 | Rilevamento cifratura sorgente (BitLocker/FileVault/APFS) | TX1 [R30], DC [R21], Atola [R33] |
| M11 | Triage/preview del filesystem prima di acquisire | FTK [R5], DC [R21], TX1 [R30] |
| M12 | Acquisizione logica (file/cartelle) oltre a quella fisica | FTK, DC, TX1, AXIOM |

### 12.2 Differenziatori

| # | Funzione | Chi | Rilevanza per xipper-forensic |
|---|---|---|---|
| D1 | Hash ad albero/a segmenti + verifica parallela che fallisce subito | TX2 [R31], Atola [R33][R36] | **Alta**: Xipper ha già hash per blocco → Merkle root firmata |
| D2 | Pausa/ripresa anche dopo blackout | TX1 [R30] | Alta (laptop in campo) |
| D3 | Multi-pass configurabile, reverse, timeout, head disable, Media Map | Atola [R34][R35], X-Ways reverse [R40] | Media (SSD Mac: meno rilevante; dischi esterni sì) |
| D4 | Più job simultanei + coda + avvio automatico in base alle risorse | TX1/TX2, Guymager, Atola | Media |
| D5 | Più destinazioni simultanee (copia di lavoro + copia master) | TX1 (4), Atola (5), Guymager "Duplicate image" | **Alta** (best practice due copie) |
| D6 | Preconditions check con warning/fatal prima dello start | TX1 [R30] | **Alta**, a basso costo |
| D7 | Rilettura della sorgente per verifica | Guymager `HashVerifySrc` [R12] | Media |
| D8 | Report diagnostico pre/post con SMART | Atola [R35], Guymager info file [R12] | Media (SMART su NVMe esterni) |
| D9 | MFA/utenti/ruoli/blocco schermo | TX2 YubiKey [R31], TX1 PIN [R30], Atola ruoli [R33] | Media: identità operatore = firma |
| D10 | Albero decisionale guidato per Mac (acceso/spento, FileVault, TDM) | DC 3.1 [R24] | **Alta**: Apple Silicon è confuso per i non specialisti |
| D11 | Quick Triage ordinato per gravità (FileVault, snapshot, anti-forensics, cloud) | RECON [R28] | Alta |
| D12 | Snapshot APFS / Time Machine locali | RECON [R28] | Alta su Mac |
| D13 | Destinazione cifrata (XTS-AES, AES-256 Ex01, VeraCrypt) | TX1 [R30], Ex01 [R42], Atola [R32] | **Alta** (archivio cifrato Xipper) |
| D14 | Hash attesi in input per verificare un'evidenza ricevuta | Autopsy [R44] | Media (verifica in ingresso) |
| D15 | Entropia in tempo reale (cifratura) | Atola Insight [R33] | Bassa-media |
| D16 | AFF4-L come contenitore logico (metà della dimensione di ZIP) | AXIOM [R18] | Riferimento di confronto per XIZ logico |
| D17 | Salta spazio libero / aree a zero come sparse | X-Ways [R40] | Alta (Xipper comprime già) |
| D18 | Gallery thumbnail per triage | TX2 [R31], DC Quick Look [R21] | Media (Quick Look nativo su macOS = gratis) |

---

## 13. Pain point UX che xipper-forensic potrebbe risolvere

| # | Problema osservato | Evidenza | Idea per xipper-forensic |
|---|---|---|---|
| P1 | Verifica sequenziale che **raddoppia i tempi**; errore scoperto solo alla fine | [R58][R31] | Hash Merkle per blocco calcolato in streaming; verifica parallela su tutti i core con fallimento immediato (come TX2) e verifica incrementale ripresa |
| P2 | Zero-fill silenzioso: "finished successfully (with 40 bad sectors)" ambiguo, dibattito sull'ammissibilità | [R15][R30] | Esito a tre stati (OK / OK con settori illeggibili / fallito), mappa dei settori illeggibili firmata nell'archivio, elenco file impattati (come File Recovery Atola [R35]) |
| P3 | E01 limita: niente SHA-256 nativo, niente reverse/jump, problemi di compatibilità tra tool | [R30][R37][R60] | Formato proprio con SHA-256/BLAKE3 per blocco e accesso casuale; export E01/AFF4 come conversione separata e verificata |
| P4 | Configurazione nascosta in file `.cfg` (Guymager), opzioni che nessuno trova | [R12] | Preferenze in UI con profili salvabili per laboratorio ("profilo procura", "profilo aziendale") |
| P5 | Apple Silicon: workflow confuso (TDM sparito, Share Disk solo logico, Secure Boot da abbassare e poi ripristinare con Wi-Fi) | [R49][R51][R55][R56] | Assistente decisionale (stile DC 3.1 [R24]) che chiede: Mac acceso? FileVault? credenziali? → propone il metodo e **registra nel verbale** ogni modifica allo stato del dispositivo (Secure Boot, SIP) |
| P6 | Share Disk montato R/W da Finder per default | [R51] | Montaggio forzato read-only (`mount_smbfs -o ro`) automatico e verificato prima di leggere |
| P7 | Costo elevato e hardware dedicato (DC, RECON $1.295/anno che smette di funzionare a scadenza) | [R28][R55] | App macOS standalone; licenza che non blocca la verifica di archivi esistenti (verifier gratuito) |
| P8 | Catena di custodia = solo log testuale modificabile | [R1][R30] | Manifest firmato (identità operatore, orario, device, hash radice) + log append-only con hash concatenati + PDF verbale generato; ogni trasferimento/accesso successivo aggiunge una firma |
| P9 | Mancanza di pausa/ripresa su tool software (FTK) | [R30] — FTK: **[da verificare]** | Ripresa da checkpoint (blocchi già hashati) anche dopo crash o disconnessione |
| P10 | Rallentamenti con dati incomprimibili/cifrati | [R58][R59] | Rilevamento entropia per blocco → store senza compressione (Xipper lo fa già), ETA basata sulla velocità reale |
| P11 | Nomi file limitati / errori "Special characters", "Files exist" a fine wizard | [R12][R13] | Validazione inline mentre si digita, naming automatico da Case ID + Evidence + seriale + data (come TX1 [R30]) |
| P12 | Il disco di sistema dell'esaminatore è selezionabile per errore | [R11] | Disco di boot e destinazione esclusi automaticamente; conferma esplicita con seriale per i dischi interni |
| P13 | Destinazione non verificata (spazio, filesystem FAT32 2 GB, settori ≠ 512 per DMG) | [R30] | Preconditions check con warning/fatal prima dello start [R30] |
| P14 | Report sparsi in più file in formati diversi | [R1][R12][R30] | Un solo archivio firmato contenente immagine + report HTML/PDF + log JSON macchina-leggibile |
| P15 | Snapshot APFS e Time Machine ignorati dai tool generalisti | [R28] | Elenco e acquisizione opzionale degli snapshot locali |

---

## 14. Implicazioni dirette per il wizard di xipper-forensic (proposta)

1. **Caso** (persistente, riutilizzabile; campi: Case Number, Evidence Number, Examiner, Organization, Description, Notes; tutti opzionali tranne Case/Evidence; "ricorda ultimo").
2. **Sorgente**: lista device con modello, seriale, dimensione, interfaccia, schema partizioni, stato cifratura (FileVault/BitLocker), badge read-only; tab separate Disco fisico / Volume APFS / Cartelle e file / Mac via Share Disk.
3. **Assistente Mac** (solo se rilevante): albero decisionale [R24] e registrazione delle modifiche di stato.
4. **Destinazioni** (1–N), formato XIZ (+ export E01/AFF4 opzionale), split, cifratura, compressione.
5. **Hash e verifica**: SHA-256 di default + MD5/SHA-1 per compatibilità; Merkle per blocco; verifica immagine (default on) e rilettura sorgente (opzionale).
6. **Errori di lettura**: preset (Rapido / Standard / Esaustivo) che mappano su retry e granularità [R30][R34].
7. **Preconditions check** → riepilogo → Start.
8. **Progress**: %, velocità corrente/media, ETA, settori illeggibili, fasi (acquisizione/verifica), grafico throughput; pausa/riprendi.
9. **Fine**: esito a tre stati, verbale PDF + log JSON firmati dentro l'archivio, pulsante "verifica di nuovo".

---

## Fonti

- [R1] SANS, Forensics 101: Acquiring an Image with FTK Imager — https://www.sans.org/blog/forensics-101-acquiring-an-image-with-ftk-imager/
- [R2] CloudNine, How to Create an Image Using FTK Imager — https://cloudnine.com/ediscoverydaily/how-to-create-an-image-using-ftk-imager-ediscovery-best-practices/
- [R3] MIT Archives, FTK Imager — https://wikis.mit.edu/confluence/display/ARCHIVESPROCESSING/FTKImager
- [R4] Hacking Articles, Comprehensive Guide on FTK Imager — https://www.hackingarticles.in/comprehensive-guide-on-ftk-imager
- [R5] Exterro, FTK Imager — https://www.exterro.com/digital-forensics-software/ftk-imager
- [R6] Exterro, FTK downloads — https://exterro.com/ftk-downloads
- [R7] Forensic Focus, Exterro Launches FTK Imager Pro — https://www.forensicfocus.com/news/exterro-launches-ftk-imager-pro-unlocking-faster-access-to-encrypted-evidence-for-investigators-worldwide/
- [R8] 4N6 BEAT, FTK Imager Pro how-to — https://4n6beat-com.pages.dev/posts/ftk-imager-pro-adds-bitlocker-decrypted-imaging-and-ios-advanced-logical-a-dfir-how-to
- [R9] ftkcore.com FAQ (sito terzo, affidabilità bassa) — https://ftkcore.com/faq
- [R10] Forensic Focus forum, How can I run FTK Imager on Mac — https://www.forensicfocus.com/forums/general/how-can-i-run-ftk-imager-on-mac-systems/
- [R11] Guymager homepage — https://guymager.sourceforge.io/
- [R12] guymager.cfg 0.8.13 (Debian) — https://sources.debian.org/src/guymager/0.8.13-3/guymager.cfg
- [R13] dlgacquire.cpp 0.8.13 (Debian) — https://sources.debian.org/src/guymager/0.8.13-3/dlgacquire.cpp
- [R14] Linux Magazine 168, Guymager — https://www.linux-magazine.com/Issues/2014/168/Guymager-Forensic-Backup
- [R15] Forensic Focus forum, Source verification failure in Guymager — https://www.forensicfocus.com/forums/general/understanding-source-verification-failure-in-guymager-acquisition/
- [R16] Launchpad, guymager 0.8.13-1 — https://answers.launchpad.net/ubuntu/+source/guymager/0.8.13-1
- [R17] Magnet AXIOM docs, Acquiring and loading evidence — https://docs.magnetforensics.com/docs/axiom/html/Content/en-us/acquire-computer/acquiring-loading-evidence.htm
- [R18] Magnet, Introducing AFF4-L Support — https://www.magnetforensics.com/blog/introducing-aff4-l-support-in-magnet-axiom/
- [R19] Magnet, Remote Acquisition of M1 endpoints — https://www.magnetforensics.com/blog/remote-acquisition-of-apples-new-m1-based-endpoints-with-magnet-axiom-cyber/
- [R20] Magnet, AXIOM now available — https://www.magnetforensics.com/blog/magnet-axiom-now-available/
- [R21] Cellebrite, Digital Collector Solution Overview (nov 2025) — https://cellebrite.com/wp-content/uploads/2025/11/SolutionOverview_DigitalCollector_web_november_2025.pdf
- [R22] Cellebrite, What's New in Digital Collector 3.9 — https://cellebrite.com/en/whats-new-cellebrite-digital-collector/
- [R23] Cellebrite, Digital Collector 3.8 — https://cellebrite.com/en/productupdates/now-available-cellebrite-digital-collector-3-8/
- [R24] Cellebrite, Workflow Aids: Digital Collector 3.1 — https://cellebrite.com/en/productupdates/workflow-aids-digital-collector-3-1
- [R25] Forensic Focus, How To Acquire Data From A Mac Using MacQuisition — https://www.forensicfocus.com/articles/how-to-acquire-data-from-a-mac-using-macquisition/
- [R26] Forensic Focus webinar, macOS 13 and iOS 16 — https://www.forensicfocus.com/webinars/what-you-need-to-know-now-about-macos-13-and-ios-16/
- [R27] Forensic Focus forum, Apple Silicon M1 chip based computers — https://www.forensicfocus.com/forums/general/apple-silicon-m1-chip-based-computers/
- [R28] SUMURI, RECON ITR — https://sumuri.com/software/recon-itr/
- [R29] SUMURI, PALADIN — https://sumuri.com/software/paladin/
- [R30] OpenText Forensic TX1 Imager User Guide 25.4 (ISTX250400-UGD-EN-1) — https://res.cloudinary.com/digitalintelligence/image/upload/fl_attachment/v1761661493/hdrwhmblstau9lh2alpl.pdf
- [R31] OpenText Forensic TX2 Imager product overview — https://www-akamai.opentext.com/media/product-overview/opentext-forensic-tx2-imager-po-en.pdf
- [R32] Forensics Wiki, Atola TaskForce — https://forensics.wiki/atola_taskforce/
- [R33] Forensic Focus, Q&A about Atola Imagers 2022 — https://www.forensicfocus.com/news/questions-and-answers-about-atola-imagers-from-digital-forensic-events-in-2022/
- [R34] Atola, Multipass imaging — https://atola.com/products/insight/manual/multipass-imaging.html
- [R35] Atola, Insight FAQ — https://atola.com/products/insight/manual/faq.html
- [R36] Atola, Segmented hashing — https://atola.com/products/insight/manual/segmented-hashing.html
- [R37] Atola, Imaging cheat sheet — https://atola.com/products/insight/manual/imaging-cheat-sheet.html
- [R38] Forensic Focus, Atola TaskForce 2025.11 — https://www.forensicfocus.com/news/atola-introduces-zfs-and-ldap-support-in-taskforce-2025-11/
- [R39] Forensic Focus, Atola launches TaskForce 2 — https://www.forensicfocus.com/news/atola-technology-launches-taskforce-2-a-new-generation-of-high-performance-forensic-imagers/
- [R40] X-Ways Imager — https://www.x-ways.net/imager/
- [R41] Hacking Articles, Forensic Imaging through EnCase Imager — https://www.hackingarticles.in/forensic-imaging-encase/
- [R42] FileInfo, .EX01 — https://fileinfo.com/extension/ex01
- [R43] Autopsy 4.23 docs, Cases — https://sleuthkit.org/autopsy/docs/user-docs/4.23.0/cases_page.html
- [R44] Autopsy 4.23 docs, Data Sources — https://sleuthkit.org/autopsy/docs/user-docs/4.23.0/ds_page.html
- [R45] Autopsy 4.4 Quick Start — https://sleuthkit.org/autopsy/docs/user-docs/4.4/quick_start_guide.html
- [R46] Belkasoft X Help, Acquiring disk drive — https://belkasoft.com/acquiring_disk_drive
- [R47] DHS S&T, CFTT Disk Imaging reports — https://www.dhs.gov/publication/st-disk-imaging
- [R48] NIST (Lyle), AAFS 2017 notes — https://www.nist.gov/system/files/documents/2017/05/08/aafs-2017-lyle-notes.pdf
- [R49] Apple, Transfer files between a Mac with Apple silicon and another Mac — https://support.apple.com/guide/mac-help/transfer-files-a-mac-apple-silicon-mchlb37e8ca7/14.0/mac/14.0
- [R50] Apple, Use macOS Recovery on a Mac with Apple silicon — https://support.apple.com/guide/mac-help/macos-recovery-a-mac-apple-silicon-mchl82829c17/mac
- [R51] G. Totaro, Forensic logical acquisition of Apple Silicon (2024) — https://giuseppetotaro.github.io/mac/forensics/2024/02/23/forensic-logical-acquisition-of-apple-silicon.html
- [R52] SANS DFIR Europe 2024, Fuji — https://www.sans.org/presentations/fuji-a-new-open-source-tool-for-full-file-system-acquisition-of-mac-computers/
- [R53] GitHub, Lazza/Fuji — https://github.com/Lazza/Fuji
- [R54] Forensic Focus forum, Fuji — https://www.forensicfocus.com/forums/general/fuji-open-source-tool-for-the-forensic-acquisition-of-intel-and-apple-silicon-macs-m1-m2-m3/
- [R55] Reddit (snapshot apr 2026), imaging MacBook Air M2 — https://reddit.sentinel-team.org/posts/1sqm26b/snapshots/2026-04-20T17%3A23%3A52.618817Z
- [R56] Eclectic Light, Mastering Secure Boot on Apple silicon — https://eclecticlight.co/2024/09/09/mastering-secure-boot-on-apple-silicon/
- [R57] Apple Platform Security, boot security policy — https://support.apple.com/guide/security/secac71d5623
- [R58] Forensic Focus forum, Extremely slow acquisition with FTK Imager — https://www.forensicfocus.com/forums/general/extremely-slow-acquisition-with-ftk-imager/
- [R59] ElcomSoft, When Speed Matters: Optimizing Disk Imaging (2024) — https://blog.elcomsoft.com/2024/09/when-speed-matters-optimizing-disk-imaging
- [R60] Forensic Focus forum, EnCase verification errors on Guymager E01 — https://www.forensicfocus.com/forums/general/encase-verification-errors-e01-image-imaged-using-guymager/
- [R61] Cybrary, Guymager tutorial — https://www.cybrary.it/blog/creating-a-forensic-disk-image-using-the-linux-guymager-utility
- [R62] Binalyze KB, macOS Disk Imaging — https://kb.binalyze.com/air/features/acquisition/disk-and-volume-imaging/macos-disk-imaging
- [R63] Exterro Store, FTK Imager Pro — https://store.exterro.com/products/ftk-imager-pro

Nota metodologica: alcune pagine (Forensic Focus forum/webinar, MyCellebrite, docs AXIOM PDF) hanno restituito 403/404 o erano dietro login; le affermazioni da quelle fonti derivano da snippet di ricerca e vanno ricontrollate. Manuali utente DC, RECON ITR e Magnet ACQUIRE sono riservati ai clienti: campi esatti e schermate di progress di questi tool restano **[da verificare]**.
