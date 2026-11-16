# Studio: un'app Windows che apre e crea archivi XIZ

Stato: analisi, 16/11/2026. Nessun codice scritto.

## 1. Scopo e confini

Chi riceve un `.xiz` su Windows oggi può solo usare `xiz.exe` dal prompt. Serve un'app che:

- **apra ed estragga** gli archivi XIZ con doppio clic o dal menu di Esplora file;
- gestisca **tutte le opzioni del formato che un destinatario incontra**: password, chiavi, fattori,
  custodi, gruppi, firme, recovery record, codec diversi;
- **crei** archivi XIZ con tutto quello che si può fare su Windows (§12), leggibili da Xipper su Mac
  e da `xiz` ovunque;
- non diventi un secondo Xipper: niente ZIP, 7z o altri formati.

Fuori dallo scopo: profilo forense come prodotto (quello è xipper-forensic), Linux (c'è già `xiz`),
store di Microsoft.

## 2. Da dove si parte

Quasi tutto il lavoro difficile esiste già in **libxiz** (`libxiz/`, C99, MIT):

- implementazione **indipendente** dalla spec, non dal codice Swift; legge fino alla 1.14;
- **API C con handle opachi** (`include/xiz.h`), I/O tramite callback, `xiz_source_file` già con le
  API wide di Windows;
- **estrazione sicura già pensata per Windows**: prefisso `\\?\`, niente reparse point nei
  componenti, nomi resi validi (`xiz_windows_name`: `<>:"|?*\`, `CON`, `COM1`, punti e spazi finali);
- tutta la crittografia **portabile e compilata dai sorgenti** (BearSSL, Monocypher, mlkem-native,
  mldsa-native, Argon2 di riferimento): niente CryptoKit, niente dipendenze di sistema;
- `xiz.exe` x86_64 **già costruito** da `scripts/build-xiz-portable.sh` (zig, dal Mac) e pubblicato
  (`dist/xiz-campaign/xiz-campaign-windows-x86_64.zip`, 1,4 MB con brunsli, preflate e OpenZL);
- **già provato sotto Wine 10**: 114 controlli su 114 (`scripts/windows-wine.sh`), compresi nomi e
  password non ASCII e lettere di unità.

L'app Windows è quindi soprattutto **un'interfaccia sopra libxiz**, più l'integrazione con Windows.
Il formato non va reimplementato.

## 3. Le opzioni del formato e cosa deve fare l'app

| Opzione XIZ | Dove nella spec | libxiz oggi | Cosa fa l'app |
|---|---|---|---|
| Archivio in chiaro, zstd, store | §4 | sì | apre senza chiedere nulla |
| Dizionari zstd | §12 | sì | trasparente |
| LZMA2, ARM64 + LZMA2 | §14 | sì | trasparente |
| JPEG ricompressi (brunsli) | §16 | sì (`XIZ_JPEG`) | trasparente; build con C++ |
| Documenti con Deflate ricompresso (preflate) | §19 | sì (`XIZ_PREFLATE`) | trasparente; build con C++ |
| Tabelle e pesi di modelli (OpenZL) | §21 | sì (`XIZ_OPENZL`) | trasparente |
| **LZRAVEN, LZMESH** (codec Apple) | §18 | **solo macOS 27** | **impossibile su Windows**: messaggio chiaro, vedi §9 |
| Bit `genomic_codecs` (XIG) | §3 | non specificato | rifiuto con messaggio |
| Password (Argon2id, AES-GCM) | §6 | sì | finestra password |
| Profilo Forte (1 GiB, t=4) | §6.2 | sì | serve RAM libera: avviso se < 2 GiB disponibili |
| Password in NFC | §24.2 | **no**, byte così come arrivano | **l'app normalizza**: `NormalizeString(NormalizationC)` di Win32, poi UTF-8 |
| Password con secondo fattore (stanza 8) | §24.3 | sì (`factors`) | chiede il file `.xizfactor` quando l'archivio lo richiede |
| Commitment delle chiavi (stanza 9) | §24.1 | sì | trasparente; un archivio ≥ 1.14 senza commitment è rifiutato |
| Destinatari X25519, identità age | §13.3 | sì (`identities`) | «Apri con file di chiave…» |
| Destinatari post-quantum X-Wing | §17 | sì (`pq_identities`) | come sopra, `XIZ-SECRET-KEY-PQ-1-…` |
| Soglie k-di-n (custodi, Shamir) | §13.3 | sì | raccoglie più password o chiavi, mostra «2 di 3 forniti» |
| Gruppi di accesso | §13.2 | sì | mostra solo le cartelle che le credenziali aprono, le altre come «bloccate» |
| `XIZ_OPEN_NO_KEYS` | §13 | sì | senza credenziali mostra comunque struttura, gruppi e firme |
| Firme dei segmenti (Ed25519, P-256 + X.509, RSA) | §13.5 | sì | pannello «Firme» con firmatario e catena |
| Firme ibride Ed25519 + ML-DSA-65 | §22 | sì | come sopra, etichetta «post-quantum» |
| Firme Secure Enclave (P-256 + ML-DSA-65) | §23 | sì (algoritmo 5) | come sopra |
| Marca temporale RFC 3161 | §13.5 | rilevata, **non verificata** | la mostra come «presente, non verificata» |
| Prove di inclusione (`xiz-proof-1`) | §13.6 | sì | «Verifica prova…»: file JSON + file |
| Voci cancellabili, slot azzerati | §13.7 | sì | voce mostrata come «cancellata» |
| Segmenti aggiunti, append interrotto | §11 | sì | trasparente; cronologia nel pannello Firme |
| Recovery record | §15 | sì (scrub e riparazione) | «Verifica» e, se danneggiato, «Ripara» (con copia di sicurezza) |
| PAR2 accanto all'archivio | §3 | no | fuori scopo: si indica lo strumento PAR2 |
| Profilo forense | §20 | lettura e verifica | estrazione normale; la verifica forense resta a xipper-forensic |
| xattr macOS | §5.2 | letti, non applicati | ignorati; mai in ADS (vedi §5) |

Riassunto: **tutte le opzioni tranne i codec Apple sono già decodificabili da libxiz**. L'unico
pezzo crittografico mancante è la normalizzazione NFC, che su Windows dà il sistema.

## 4. Architettura raccomandata

### Scelta: app nativa Win32 in C++, libxiz collegata staticamente

```
XipperReader.exe  (un solo file, ~4 MB, nessun runtime)
├─ UI Win32 + Common Controls v6 (ListView, TreeView, TaskDialog, IFileDialog)
├─ thread di lavoro: apertura, test, estrazione (un xiz_archive per thread)
├─ integrazione shell: associazione .xiz, verbi «Estrai qui» / «Estrai in…» (HKCU)
└─ libxiz statica (+ zstd, liblzma, Argon2, brunsli, preflate, OpenZL)
```

Perché:

- **si costruisce dal Mac** con la stessa catena zig di `build-xiz-portable.sh` (`zig c++ -target
  x86_64-windows-gnu` e `aarch64-windows-gnu`): niente macchina Windows per compilare;
- **un eseguibile portabile**, nessun .NET da installare, avvio istantaneo;
- stesso linguaggio di libxiz: niente marshalling e niente copia delle stringhe UTF-8;
- superficie d'attacco minima: l'app legge file non fidati, meno strati meglio.

### Alternative scartate

| Opzione | Contro principale |
|---|---|
| C# / WPF o WinUI 3 + `xiz.dll` via P/Invoke | runtime .NET o pacchetto self-contained da 60–150 MB; WinUI 3 vuole il Windows App SDK; due linguaggi da mantenere |
| Electron / Tauri | peso, WebView, superficie d'attacco per un semplice estrattore |
| Solo `xiz.exe` + script `.bat` di associazione | nessuna gestione interattiva di password, custodi, gruppi, conflitti |
| Plugin per 7-Zip | lo usa solo chi ha 7-Zip; la sua API dei plugin è pensata per formati senza identità e firme |
| Port di XipperKit in Swift per Windows | Swift su Windows è immaturo per la UI; XipperKit dipende da CryptoKit e Foundation di Apple |

Un **plugin per 7-Zip** resta una seconda fase possibile per gli archivi semplici (solo password),
come canale di diffusione: non sostituisce l'app.

## 5. Interfaccia e flussi

**Apertura** (doppio clic, trascinamento, `XipperReader.exe archivio.xiz`):

1. `xiz_open` con `XIZ_OPEN_NO_KEYS` se l'archivio ha la directory (§13): si legge struttura e firme
   prima di chiedere credenziali.
2. Dalle stanza (`xiz_get_stanza`) l'app capisce **cosa chiedere**, invece di una finestra generica:
   - solo password → campo password;
   - password con fattore → campo password + «File del secondo fattore…»;
   - destinatari a chiave → «File di chiave…» (con elenco dei key id attesi);
   - soglia → elenco dei custodi, ciascuno con password o chiave, contatore «k di n»;
   - più gruppi → si apre con quello che si ha, il resto appare bloccato.
3. Errori distinti: password sbagliata, fattore mancante (`XIZ_E_FACTOR_REQUIRED`), fattore
   sbagliato, codec non disponibile, versione più nuova.

**Finestra principale**: albero delle cartelle + elenco (nome, dimensione, data, gruppo, stato);
barra con *Estrai tutto*, *Estrai selezione*, *Verifica*, *Firme*, *Proprietà*. Trascinamento verso
Esplora file tramite estrazione in una cartella temporanea (`IDataObject` con `CFSTR_FILEDESCRIPTOR`
in una fase successiva).

**Estrazione**: destinazione proposta «accanto all'archivio, in una cartella col suo nome»;
conflitti con «Sovrascrivi / Salta / Rinomina / per tutti»; avanzamento in byte, annullabile;
rapporto finale con le voci saltate e il perché (percorso non sicuro, nome reso valido, link non
creato).

**Verifica**: `xiz_test` con avanzamento; se l'archivio ha un recovery record, `xiz scrub` e
proposta di riparazione **su una copia** (mai sul file originale senza conferma).

**Firme**: per ogni segmento algoritmo, firmatario (certificato o key id), stato (valida, non
valida, algoritmo sconosciuto), catena, marca temporale «presente, non verificata».

**Lingue**: le 6 dell'app Mac, stesse stringhe dove possibile (riuso del catalogo).

**Riga di comando** dell'app, per l'integrazione: `/x <archivio> [/d DIR]` estrai qui senza
finestre salvo credenziali, `/t` verifica. `xiz.exe` resta lo strumento per gli script.

## 6. Cose specifiche di Windows

| Tema | Decisione |
|---|---|
| **Mark of the Web** | se l'archivio ha lo stream `Zone.Identifier`, copiarlo su ogni file estratto (come Esplora file e 7-Zip). È **sicurezza**: senza, un `.exe` scaricato dentro un `.xiz` perde l'avviso di SmartScreen. Default attivo |
| Percorsi lunghi | già `\\?\` in libxiz; manifest con `longPathAware` |
| Nomi non validi, nomi riservati | già `xiz_windows_name`; il rapporto elenca i nomi cambiati |
| **Maiuscole e minuscole** | NTFS non distingue `A.txt` da `a.txt`: rilevare le collisioni prima di scrivere e rinominare la seconda (`a (2).txt`), con avviso |
| Link simbolici | servono privilegio o Modalità sviluppatore: se mancano, saltati e riportati; mai giunzioni |
| Permessi POSIX | solo «sola lettura»; setuid ecc. già azzerati |
| xattr macOS | ignorati; niente ADS (scrivere stream arbitrari da un archivio è un rischio senza beneficio) |
| Date | mtime ripristinata; creazione = ora dell'estrazione |
| Password non ASCII | campo UTF-16 → NFC con `NormalizeString` → UTF-8 a libxiz. Risolve anche il limite noto della code page ANSI di `--password-stdin` |
| Memoria per Argon2id | 1 GiB del profilo Forte: controllo con `GlobalMemoryStatusEx` e messaggio chiaro invece di un crash |
| Console | l'app è GUI (`/SUBSYSTEM:WINDOWS`); `xiz.exe` resta per la console |
| ARM64 (Snapdragon) | build nativa aarch64; sotto Wine non parte, va provata su macchina vera |
| Defender | la scansione rallenta l'estrazione di molti file piccoli: niente da fare, solo misurarlo |

## 7. Lavoro da fare in libxiz

**Fase 0 fatta il 16/11/2026** (punti 1–5 e 7): `xiz_test_progress`; in `xiz_extract_options` le
callback `bytes` (avanzamento e annullamento), `written` (nome su disco) e `conflict`
(`XIZ_CONFLICT_SKIP/OVERWRITE/RENAME/CANCEL`); collisioni di maiuscole rinominate («nome (2).ext»,
sempre su Windows, con `XIZ_EXTRACT_FOLD_CASE` altrove); nella CLI `--keep-both` e `--fold-case`.
Test in `tests/security.c` e in `scripts/windows-wine.sh`. Resta il punto 6.

Piccolo, e utile anche alla CLI:

1. **Annullamento**: la callback `progress` restituisce `void`. Aggiungere un `int (*cancel)(void*)`
   o far restituire `int` a una nuova callback, controllata tra un frame e l'altro.
2. **Avanzamento in byte dentro un file**: oggi arriva dopo ogni voce; un file da 10 GB resta fermo.
3. **Percorso su disco nella callback**: l'app deve sapere il nome reale scritto (dopo
   `xiz_windows_name`) per copiare il Mark of the Web e per il rapporto.
4. **Conflitti interattivi**: callback «esiste già: sovrascrivi / salta / rinomina» invece del solo
   flag `XIZ_EXTRACT_OVERWRITE`.
5. **Collisioni di maiuscole** su Windows (vedi §6), dentro `extract.c` dove si conoscono tutti i nomi.
6. **Estrazione parallela** (facoltativa): un `xiz_archive` per thread, voci divise per frame.
   Utile sugli archivi grandi; non blocca la prima versione.
7. **Aggiornare `libxiz/README.md`**: la tabella dice ancora preflate «non ancora» e non cita
   OpenZL, firme ibride e Secure Enclave, che invece sono supportati.

Nessuna nuova libreria esterna: `NormalizeString`, `IFileDialog`, `TaskDialog` sono di Windows.

## 8. Build, firma, distribuzione

- **Build**: nuovo target `xipper-reader` in `libxiz/` o in `windows/`, CMake + zig, x86_64 e aarch64,
  aggiunto a `build-xiz-portable.sh` e alla campagna (passo `windows`).
- **Risorse**: manifest (DPI per monitor, `longPathAware`, Common Controls v6), icona `.xiz`
  ricavata dalle icone dell'app Mac, versione nei metadati.
- **Firma**: coerente con la distribuzione attuale, **nessun certificato commerciale**. Conseguenza:
  SmartScreen mostra «Windows ha protetto il PC» al primo avvio finché l'eseguibile non acquista
  reputazione. Alternativa a pagamento (Azure Trusted Signing o un certificato OV): decisione tua.
- **Pacchetti**: ZIP portabile (eseguibile + `xiz.exe` + licenze) e installer per utente, senza
  diritti di amministratore, che registra `.xiz` in `HKCU\Software\Classes`. Per l'installer serve
  uno strumento esterno (Inno Setup o WiX): da approvare, oppure un `/register` scritto nell'app
  stessa, che evita l'installer.
- **Menu contestuale**: verbi classici in HKCU. Su Windows 11 compaiono sotto «Mostra altre
  opzioni»; il menu moderno (`IExplorerCommand`) richiede un pacchetto MSIX firmato: rinviato.
- **Rilascio** accanto a Xipper Forensic su GitHub, con SHA-256.
- **Licenze**: riconoscimenti di BearSSL, Monocypher, mlkem-native, mldsa-native, zstd, liblzma,
  brunsli, Brotli, preflate, OpenZL, Argon2 in una finestra «Informazioni».

## 9. Codec Apple: rimedio lato Xipper

LZRAVEN e LZMESH esistono solo nel framework Compression di macOS 27: nessuna implementazione
pubblica, quindi **un archivio così non si apre su Windows né su Linux**. Oggi sono opzionali
(`--lzraven`, `--lzmesh`, default zstd), ma chi li sceglie potrebbe non saperlo.

Proposta per Xipper Mac:

- avviso nel pannello di creazione e nella CLI: «non leggibile fuori da macOS 27»;
- in Proprietà dell'archivio: riga «Leggibile su Windows e Linux: sì / no (motivo)»;
- `xipper convert --to xiz` ricomprime in zstd (firme e gruppi di accesso si perdono, serve
  `--accept-losses`): l'app Windows nel messaggio d'errore indica al destinatario di chiedere al
  mittente questo comando, o meglio di ricreare l'archivio senza codec Apple.

## 10. Test

- **Wine in container** (già esistente): avvio dell'app in modalità `/x` e `/t` senza finestre, sulle
  fixture di `run_fixtures.sh` e sulla matrice della campagna. La parte grafica non si prova lì.
- **Windows reale**: indispensabile per NTFS, ACL, link simbolici, Mark of the Web, SmartScreen,
  DPI, ARM64. Opzione più semplice dal Mac: Windows 11 ARM in una VM (UTM/Parallels) per le prove
  manuali prima di ogni rilascio; x86_64 in emulazione o su un PC.
- **Matrice delle opzioni**: per ogni riga della tabella del §3 una fixture e un controllo, comprese
  quelle negative (fattore sbagliato, k-1 custodi, codec Apple, bit sconosciuto).
- **Fuzzing**: già coperto da libxiz (`fuzz_open`); l'app non aggiunge parser propri.
- **Interop inversa**: archivi creati da ogni versione di Xipper 3.x aperti dall'app.

## 11. Fasi e stima

**Fase 1 fatta il 16/11/2026**, in `windows/` con nome di lavoro «Xipper XIZ» (`XipperXIZ.exe`,
versione 0.1.0, 3,7 MB x86_64, 3,2 MB ARM64): finestra con elenco (ListView virtuale, icone di
sistema), Apri / trascinamento, password in NFC, secondo fattore, Estrai / Estrai selezione con
destinazione, avanzamento e Annulla (anche sulla barra delle applicazioni), conflitti con «Sostituisci /
Mantieni entrambi / Salta / per tutti», Verifica, Mark of the Web, associazione `.xiz` per utente con
«Estrai qui» ed «Estrai in…», modalità `/x`, `/xto`, `/t`, `/register`; testi italiano e inglese;
DPI per monitor. Build dal Mac: `windows/build.sh [--pack]`; prove: `windows/test-wine.sh` (16 controlli
più schermate in `.build/windows-app/shots/`), passo `windows-app` della campagna. Non provata su
Windows vero: Mark of the Web, menu di Esplora file e SmartScreen restano da vedere lì.

| Fase | Contenuto | Stima |
|---|---|---|
| 0 | API di libxiz del §7 (punti 1–5), README aggiornato | 2–3 giorni |
| 1 | App minima: apertura, password con NFC, fattore, elenco, estrai tutto/selezione, avanzamento, annullamento, Mark of the Web, associazione `.xiz` | 1–2 settimane |
| 2 | Chiavi, custodi, gruppi, pannello Firme, Verifica e riparazione, collisioni, conflitti | 1–2 settimane |
| 3 | Lingue, menu contestuale, trascinamento verso Esplora file, aarch64, prove su Windows reale | 1 settimana |
| 4 (facoltativa) | Plugin 7-Zip per gli archivi semplici; estrazione parallela | da valutare |
| C1–C4 | Creazione, vedi §12.6 | 5–8 settimane |

Più l'avviso sui codec Apple in Xipper Mac (§9): mezza giornata.

## 12. Creazione di archivi XIZ

### 12.1 Cosa si può fare su Windows

Il formato è quasi tutto portabile: le uniche parti legate al Mac sono i codec Apple e la Secure
Enclave. Il resto dipende da librerie C/C++ che sono **già in `Vendor/`** (encoder compresi) o da
crittografia già in `libxiz/third_party`.

| Opzione | Possibile su Windows | Writer di libxiz oggi | Cosa manca |
|---|---|---|---|
| zstd, livelli 1–22, frame da 4 MiB | sì | **sì** | multithread (`threads` «unused for now») |
| Deduplica | sì | per file intero | per chunk come Xipper: facoltativa |
| Store per i frame incomprimibili | sì | **sì** (frame per frame) | — |
| Password, Argon2id Standard | sì | **sì** (scrive 1.0) | — |
| Profilo Forte (1 GiB, t=4) | sì | sì (parametri liberi) | solo l'interfaccia |
| **Commitment delle chiavi (1.14)** | sì (HKDF) | **no** | da aggiungere: senza, l'archivio è 1.0 e non ha la protezione del §24.1 |
| **Password in NFC (1.14)** | sì (`NormalizeString`) | no | nell'app, prima di libxiz |
| Password con secondo fattore | sì | no | stanza 8 + generazione del file `.xizfactor` |
| Robustezza della password | sì (zxcvbn-c, C, MIT, già in `Vendor/`) | — | solo l'interfaccia; lista italiana GPL: vedi §12.4 |
| Recovery record | sì | **sì** (`xiz_recovery_add`, dopo la creazione) | opzione nella finestra di creazione |
| Append, rimozione, cartelle | sì | **sì** (archivi senza directory) | append su archivi 1.3 |
| Destinatari X25519 / age | sì (Monocypher) | no | strutture 1.3 (directory) nel writer |
| Destinatari post-quantum X-Wing | sì (mlkem-native) | no | come sopra + incapsulamento, oggi escluso con `MLK_CONFIG_NO_ENCAPS_API` |
| Custodi k-di-n (Shamir) | sì (codice proprio) | no | divisione del segreto + strutture 1.3 |
| Gruppi di accesso | sì | no | strutture 1.3 |
| Firma Ed25519, ibrida Ed25519 + ML-DSA-65 | sì (Monocypher, mldsa-native) | no | firma e generazione chiavi, oggi escluse con `MLD_CONFIG_NO_KEYPAIR_API` |
| Firma con certificato (P-256 / RSA + X.509) | sì, dal **certificato Windows** (CNG, smart card, token) | no | BearSSL verifica soltanto: la firma passa da `NCryptSignHash` |
| Marca temporale RFC 3161 | sì | no | richiesta a un TSA in rete: fase successiva |
| Prove di inclusione, voci cancellabili | sì | no | strutture 1.3 |
| Dizionari zstd | sì (`zdict` in `Vendor/zstd`) | no | — |
| LZMA2 | sì (`Vendor/xz` completo) | no | encoder |
| ARM64 + LZMA2 | sì | no | utile solo per binari ARM64; poco interesse su Windows |
| JPEG ricompressi (brunsli) | sì (`Vendor/brunsli`) | no | encoder (C++) |
| Documenti con Deflate ricompresso (preflate) | sì (`Vendor/preflate`) | no | encoder (C++) + riconoscimento dei formati (DOCX, XLSX, PDF, PNG…) da portare dallo Swift |
| Tabelle e pesi di modelli (OpenZL) | sì (`Vendor/openzl`) | no | compressore + riconoscimento di CSV/TSV e pesi da portare dallo Swift |
| **LZRAVEN, LZMESH** | **no**: solo framework Apple | — | mai |
| **Firme Secure Enclave** | **no** | — | mai: l'equivalente Windows (TPM) non fa ML-DSA, servirebbe un algoritmo nuovo nella spec |
| Profilo forense | sì, in teoria | no | fuori scopo (xipper-forensic) |
| xattr | non esistono su Windows | — | niente; gli ADS non si archiviano |

### 12.2 Regole di compatibilità

- **Ogni archivio creato su Windows si apre su Mac e ovunque**: niente codec Apple, per definizione.
  Va comunque provato a ogni rilascio (§10, interop inversa).
- **Profilo predefinito**: zstd livello 9, versione 1.14 con commitment, password in NFC, recovery
  record al 5 %. Il resto si attiva con opzioni, come nell'app Mac.
- `version_minor` e bit delle feature impostati solo per quello che l'archivio usa davvero, così un
  archivio semplice resta leggibile anche da Xipper vecchi.

### 12.3 Metadati che vengono da Windows

| Tema | Decisione |
|---|---|
| Separatore | `\` → `/`; nel formato `\` è un carattere normale (§5.3) |
| Nomi | UTF-16 → UTF-8; lettere di unità e prefissi `\\?\` tolti; percorsi sempre relativi |
| Permessi | Windows non ha i bit POSIX: file `0644`, cartelle `0755`; «sola lettura» → senza `w`. Gli eseguibili restano `0644`: su Mac vanno resi eseguibili a mano. Opzione «rendi eseguibili gli script `.sh`» |
| Proprietario | uid/gid 0, mai le ACL o i SID |
| Date | mtime con i 100 ns di Windows convertiti |
| Link simbolici | archiviati come link; giunzioni e altri reparse point **saltati** con avviso (puntano spesso fuori, a `C:\…`) |
| File nascosti e di sistema | inclusi; `desktop.ini`, `Thumbs.db` esclusi per default, come `.DS_Store` su Mac |
| File aperti da altri programmi | lettura con condivisione; se bloccati, saltati e riportati; niente Volume Shadow Copy (servono diritti di amministratore) |
| ADS e Mark of the Web dei file sorgente | non archiviati |

### 12.4 Interfaccia

- **Creazione**: trascinare file sull'app o «Aggiungi a archivio XIZ…» dal menu di Esplora file;
  finestra con nome, livello (Veloce / Normale / Massimo), password con indicatore di robustezza,
  profilo Forte, recovery record, opzioni avanzate (destinatari, custodi, firma, codec
  specializzati) per le fasi successive.
- **Archivio esistente**: aggiungere, togliere, nuove cartelle (append, §11).
- **Chiavi**: generazione delle identità e dei fattori; salvataggio protetto con **DPAPI** o
  Gestione credenziali di Windows, l'equivalente del Portachiavi.
- **Passphrase Diceware**: con la lista EFF (CC BY). La lista italiana di Gamberini è **GPL-3.0**:
  in un'app MIT distribuita come binario va tenuta come file dati separato, come nell'app Mac, o
  esclusa. Da decidere.

### 12.5 Dove scrivere il codice

Due strade:

1. **Estendere il writer di libxiz** (C) con tutto ciò che manca. Vantaggio: la CLI `xiz` e Linux
   ottengono le stesse funzioni; è già la seconda implementazione indipendente. Svantaggio: la parte
   di riconoscimento dei contenuti (documenti, tabelle, modelli) è logica Swift da riscrivere in C.
2. **Writer nuovo solo per l'app Windows**. Nessun vantaggio reale: scartato.

Scelta: **la 1**, con le funzioni divise in moduli opzionali di CMake come oggi i decoder
(`XIZ_JPEG`, `XIZ_PREFLATE`, `XIZ_OPENZL`). Ogni archivio scritto da libxiz va riletto da Xipper
nei test (`XIPPER=…/xipper` in `run_fixtures.sh`, già previsto) e viceversa. Vanno aggiunti a libxiz
anche gli encoder delle librerie già approvate (xz, brunsli, preflate, OpenZL): sono le stesse
librerie, ma è una superficie nuova da compilare e testare.

### 12.6 Fasi della creazione

| Fase | Contenuto | Stima |
|---|---|---|
| C1 | App: creazione e append con il writer attuale, zstd, password NFC, profilo Forte, robustezza, recovery record, menu «Aggiungi a archivio XIZ» | 1–2 settimane |
| C1 | libxiz: commitment 1.14, compressione multithread | ~1 settimana |
| C2 | libxiz: strutture 1.3 (directory, gruppi), destinatari X25519 / age / X-Wing, custodi, secondo fattore; app: chiavi con DPAPI | 2–3 settimane |
| C3 | Firme Ed25519 e ibride, firma con certificato Windows (CNG); append su archivi 1.3 | 1–2 settimane |
| C4 | Codec specializzati: LZMA2, dizionari, brunsli, preflate, OpenZL, con il riconoscimento dei contenuti | 2–3 settimane |

C1 da sola copre già il caso comune: un utente Windows che manda una cartella cifrata a un utente Mac.

## 13. Decisioni aperte

1. Nome dell'app: «Xipper Reader», «XIZ Viewer», altro. Con la creazione «Reader» non va più bene:
   forse «Xipper per Windows» o «XIZ for Windows».
2. Firma del codice: restare self-signed (avviso SmartScreen) o pagare un certificato.
3. Installer: strumento esterno (Inno Setup / WiX, da approvare) o registrazione fatta dall'app.
4. Macchina Windows per le prove: VM sul Mac o PC fisico.
5. Se la verifica forense (§20) deve comparire anche qui o restare solo in xipper-forensic.
6. Fin dove arrivare con la creazione: solo C1, fino a C3, o tutto.
7. Lista Diceware italiana (GPL) nell'app Windows: file dati separato o esclusa.
