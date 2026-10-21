# Xipper: fase 1 (core XipperKit e CLI)

*21 ottobre 2026 · Apple M3 Max (10 P-core + 4 E-core) · macOS 27.2 · Swift 6.4 · Jamf Protect attivo*

## Cosa c'è

| Area | Stato |
|---|---|
| Codec compilati dentro SwiftPM (zstd, libdeflate, liblzma) + zlib/bzip2 di sistema | ✅ nessuna dipendenza di terzi a runtime (`otool -L`: solo librerie di sistema; CLI da 1,3 MB) |
| **ZIP, scrittura** | ✅ parallela, per finestre di memoria limitate, con scrittura sovrapposta al calcolo |
| | ✅ deflate (libdeflate per file interi, blocchi pigz per i file grandi) |
| | ✅ zstd (metodo 93) e store |
| | ✅ ZIP64 (automatico e forzabile) |
| | ✅ AES-256 WinZip (AE-1 per file normali, AE-2 sotto i 20 byte) |
| | ✅ nomi UTF-8 in NFC, permessi, symlink, timestamp esteso |
| | ✅ "smart store" per file già compressi e file grandi incomprimibili |
| **ZIP, lettura** | ✅ EOCD/ZIP64, archivi con dati in testa (SFX), nomi UTF-8 e CP437, extra Unicode Path |
| | ✅ metodi store, deflate, bzip2, LZMA, zstd, xz |
| | ✅ AES (AE-1/AE-2) e ZipCrypto in sola lettura |
| | ✅ rifiuto delle voci sovrapposte (zip bomb) |
| | ❌ Deflate64, archivi divisi in più volumi |
| **tar** | ✅ ustar + pax (nomi lunghi o Unicode, dimensioni oltre 8 GiB, mtime frazionario) |
| | ✅ lettura di header GNU (nomi e link lunghi) e base-256 |
| | ✅ gz (parallelo, stile pigz), bz2 (parallelo, flussi concatenati), xz (multi-thread), zst (multi-thread) |
| **File singoli** | ✅ .gz / .bz2 / .xz / .zst |
| **Estrazione sicura** (comune a tutti i formati) | ✅ zip-slip, path assoluti e lettere di unità |
| | ✅ niente scritture attraverso symlink (`O_NOFOLLOW` su ogni componente, link creati per ultimi) |
| | ✅ symlink verso l'esterno scartati, hardlink solo interni |
| | ✅ limite sul rapporto di compressione e sullo spazio libero |
| | ✅ quarantena propagata, setuid/setgid rimossi |
| | ✅ modalità "smart" come Archive Utility, con cartella di staging ripulita in caso di errore |
| | ✅ politiche di sovrascrittura |
| **Verifica** | ✅ ZIP: CRC/HMAC in parallelo, con l'elenco delle voci fallite |
| | ✅ tar: checksum dei codec (CRC gzip, CRC64 xz, XXH64 zstd, CRC bzip2) |
| **CLI `xipper`** | ✅ create / extract / test / list, password da prompt o da stdin, progresso, Ctrl-C, codici d'uscita |
| **Test** | ✅ 22 test (oltre 40 casi): interoperabilità con unzip, ditto, Python, bsdtar e 7-Zip, sicurezza, corruzione, ZIP64, regressioni |

## Prestazioni

Corpus dello spike: 465 MB, 11.688 voci, cache calda.

### Creazione

| Formato | Xipper | Strumento di sistema |
|---|---|---|
| ZIP deflate -6 | **0,86 s** (544 MB/s) → 191,9 MB | `zip -6` 10,5 s · `ditto` 10,0 s (spike: prototipo 1,41 s) |
| ZIP zstd -3 | **0,24 s** (1,9 GB/s) → 185,0 MB | — |
| tar.gz -6 | **1,56 s** → 184,4 MB | `bsdtar -czf` 9,77 s → 184,6 MB (**6,3×**) |
| tar.zst -3 | **0,45 s** (1,0 GB/s) → 174,4 MB | — |
| tar.xz -6 | **14,8 s** → 134,5 MB | `bsdtar -cJf` 110,1 s → 133,8 MB (**7,4×**) |
| tar.bz2 -9 | **3,48 s** → 167,1 MB | — |

### Verifica

| Archivio | Xipper | Riferimento |
|---|---|---|
| ZIP creato da Info-ZIP | **0,09 s** | `unzip -t` 2,49 s (**27×**) |
| tar.xz | **0,41 s** | — |
| tar.zst | **0,34 s** | — |

### Estrazione

Su questo Mac l'estrazione è limitata dal costo di creazione dei file, che **Jamf Protect** (Endpoint Security) ispeziona uno per uno, circa 0,5 ms a file. Vale per tutti gli strumenti.

| Caso | Xipper | `unzip` | `ditto` | bsdtar |
|---|---|---|---|---|
| Corpus da ZIP | **7,3 s** | 9,5 s | 11,8 s | — |
| Corpus da tar.gz | 8,3 s | — | — | **7,6 s** |
| 10.000 file da 1 KB, tar | **2,7 s** | — | — | 14,5 s |
| 10.000 file da 1 KB, ZIP | **4,8 s** | 6,0 s | — | — |

Ottimizzazioni arrivate dalle misure:
- creazione diretta del file con `O_EXCL`; temporaneo + rinomina solo se il nome esiste già (la rinomina costa circa 0,34 ms a file sotto Endpoint Security);
- cache dei descrittori delle cartelle;
- permessi impostati alla creazione;
- I/O sovradimensionato a 2× i P-core;
- nel tar, file piccoli scritti da un pool mentre lo stream viene letto.

## Decisioni e scoperte
- **Password non ASCII:** 7-Zip le rifiuta del tutto per ZIP AES (`E_INVALIDARG`). Xipper usa UTF-8 in NFC, come WinZip, e la CLI e l'app avvisano quando una password contiene caratteri non ASCII.
- **Bug corretto in fase di benchmark:** un frame zstd che termina esattamente al confine del buffer d'uscita veniva segnalato come troncato. C'è un test di regressione.
- **La CLI rifiuta le opzioni sconosciute.** Prima un `"-m zstd"` passato come argomento unico da zsh veniva ignorato in silenzio.
- Il corpus contiene 8 symlink che puntano fuori dalla destinazione: Xipper li scarta e lo segnala, come fa `unzip`.

## Rimandato (fase 1 → successive)
- **Metadati macOS nell'archivio** (xattr, ACL, resource fork, AppleDouble `__MACOSX` opzionale): l'estrazione oggi ripristina permessi, mtime e quarantena.
- **zlib-ng o patch a libdeflate** per i blocchi dei file grandi in deflate (oggi zlib di sistema, circa 390 MB/s per file).
- **Indice dei blocchi in un extra field** per decomprimere in parallelo le voci grandi dei nostri ZIP.
- **ZIP con 10.000 file piccoli** (4,8 s contro 2,7 s del tar): da profilare.
- ~~7z (fase 3)~~ fatto, vedi sotto; Deflate64 in lettura, ZIP multi-volume, RAR (valutazione legale).
- CLI + server MCP (fase 1.5, vedi STUDIO.md §6-ter).

---

# Fase 3: 7z

*21 ottobre 2026 · stessa macchina · 7-Zip 26.03 (Homebrew `7zz`, solo nei test) come riferimento*

## Cosa c'è
- **Modulo `SevenZip/`** (header, coder, reader, writer) più `Crypto/SevenZipAES.swift`. Nessuna libreria 7-Zip: il contenitore è nostro, i codec sono quelli già vendorizzati più il decoder PPMd del LZMA SDK.
- **Lettura:**
  - header semplici, compressi (`kEncodedHeader`) e cifrati (`-mhe`), annidati fino a 4 livelli;
  - archivi solid, con ogni voce localizzata nel suo blocco;
  - metodi LZMA, LZMA2, PPMd (variante H), BZip2, Deflate, Copy e, in più, zstd (7-Zip ZS/NanaZip);
  - filtri BCJ (x86), BCJ2 (4 flussi), ARM64, ARM, ARMT, PPC, SPARC, RISC-V e Delta. Il grafo dei coder è generico, con controllo di cicli, legami doppi e coder non usati;
  - AES-256 (`06F10701`) con KDF SHA-256 a 2^NumCyclesPower iterazioni (fino a 2^24), password in UTF-16LE;
  - CRC-32 di ogni voce e dei blocchi;
  - multi-volume: `.7z.001`, `.002`… letti come un unico flusso; anche aprire `.7z.002` funziona. Un volume mancante dà un errore chiaro.
- **Scrittura:**
  - LZMA2 multi-thread: blocchi indipendenti (3× il dizionario, come xz) compressi da un pool mentre si leggono i successivi, e uniti con un reset del dizionario. È lo stesso schema del LZMA2 multi-thread di 7-Zip, quindi anche 7-Zip li decomprime in parallelo;
  - blocco solid configurabile (`CreateOptions.solidBlockSize`: automatico 64× il dizionario, cioè 512 MiB al livello 6; `0` = un blocco per file);
  - filtro ARM64 per gli eseguibili arm64 (Mach-O thin o universal, ELF AArch64), riconosciuti dall'intestazione e messi in blocchi separati;
  - file già compressi (jpg, mp4, zip…) memorizzati con Copy in blocchi a parte;
  - AES-256-CBC con IV casuale per blocco, 2^19 iterazioni, e **header cifrato di default** quando c'è una password (`encryptFileNames`), così senza password non si vedono nemmeno i nomi;
  - CRC di ogni voce, permessi Unix e symlink nello stile p7zip (contenuto = destinazione, `S_IFLNK` negli attributi): `7zz x -snl` li ricrea;
  - volumi (`CreateOptions.volumeSize`), con pulizia dei volumi in eccesso di un vecchio set sovrascritto.
- **Integrazione:**
  - `ArchiveFormat.sevenZip` (`7z`), riconosciuto dai magic byte `7z\xBC\xAF\x27\x1C`;
  - `Xipper.create`, `extract`, `test`, `list` e `readEntry`. `list` e `plannedConflicts` hanno un parametro `password` per gli archivi con nomi cifrati;
  - estrazione tramite `ExtractionContext` con tutte le protezioni (zip-slip, `..` e `\` di Windows, symlink, limiti, quarantena, conflitti, flatten, selezione);
  - blocchi decompressi in parallelo, e i file piccoli scritti da un pool mentre il blocco solid viene decodificato;
  - progresso e annullamento in creazione, estrazione e verifica;
  - CLI: `-f 7z` o estensione `.7z`, `--solid SIZE|off`, `-v/--volume SIZE`, `--plain-names`, `list -p`;
  - MCP: `archive_create` con `format: "7z"` e `solid`, `password_ref` anche in `archive_info`/`archive_list`.
- **Decoder LZMA/LZMA2 in assembly ARM64:** di default si usa `LzmaDec` del LZMA SDK con il ciclo principale in assembly di 7-Zip (`Vendor/lzma-sdk/Asm/arm64/LzmaDecOpt.S`); liblzma resta il percorso portabile (`XIPPER_PORTABLE_LZMA=1` lo forza). I flussi senza reset vengono decodificati su un thread dedicato, pochi MiB avanti rispetto a chi consuma l'output.
- **Test:** 21 nuovi test (51 casi) più uno MCP. In totale 68 test, tutti verdi:
  - round trip solid, non solid e a blocchi piccoli, livelli 0/1/9, selezione, flatten, conflitti, progresso, annullamento, quarantena;
  - password e nomi cifrati: password mancante, sbagliata e giusta, nomi assenti dai byte dell'archivio;
  - `7zz t` e `7zz x` sui nostri archivi: solid, non solid, cifrati con header cifrato, Copy cifrato, volumi;
  - lettura di 22 varianti create da `7zz`: LZMA2, LZMA, PPMd (anche ordine 32), BZip2, Deflate, Copy, BCJ, BCJ2, ARM64, ARM, ARMT, PPC, SPARC, Delta, non solid, LZMA2 multi-thread, header cifrati, dati cifrati, volumi (anche cifrati), header non compressi;
  - decodifica parallela per segmenti, con e senza ARM64, anche su archivi multi-thread di 7-Zip;
  - archivi troncati in 7 punti e con byte alterati, PPMd/BCJ2/Delta/BZip2 danneggiati, header ostili (offset oltre la fine, un miliardo di file, grafo di coder ciclico);
  - zip-slip, path assoluti, `..\`, symlink verso l'esterno e scrittura attraverso symlink dentro un 7z, solid e non; rifiuto delle compression bomb;
  - filtri BCJ in andata e ritorno a pezzi di 1, 7, 4096 byte e 1 MiB; codifica dei numeri 7z;
  - decoder in assembly contro liblzma: LZMA2 (due blocchi uniti da un reset) e LZMA1 con e senza marker di fine, su testo, dati misti, casuali e zeri, con input a pezzi da 1 byte a 1 MiB; flussi troncati e alterati (mai un crash, e stesso output quando entrambi accettano); archivi LZMA, LZMA2 e BCJ2 di `7zz` decodificati in entrambi i modi.

## Prestazioni
Corpus dello spike: 465 MB, 11.688 voci, cache calda. Durante le misure altre sessioni usavano la macchina (load average 6–7), quindi i tempi sono indicativi.

### Creazione

| Archivio | Xipper | 7-Zip 26.03 |
|---|---|---|
| Livello 6 (default di Xipper) | **14,6 s** → 124,5 MB | `-mx6` 45,7 s → 120,7 MB |
| Default di 7-Zip (`-mx5`) | — | 27,9 s → 123,1 MB |
| Livello 9 | **39,6 s** → **112,1 MB** | `-mx9` 55,1 s → 118,8 MB |
| Livello 6, non solid | 16,2 s → 135,6 MB | — |
| Livello 6 con password e nomi cifrati | 19,6 s → 124,5 MB | — |
| Riferimento: tar.xz -6 (fase 1) | 14,8 s → 134,5 MB | — |

Al livello 6 siamo 3,1× più veloci di `-mx6` con un archivio più grande del 3%. 7-Zip ha un dizionario più grande e meno blocchi indipendenti; al livello 9 il nostro archivio è anche più piccolo.

### Verifica ed estrazione

| Caso | Xipper | 7-Zip 26.03 |
|---|---|---|
| Verifica, archivio Xipper -6 | 0,49 s | `7zz t` **0,38 s** |
| Verifica, archivio Xipper -6 cifrato | 0,63 s | — |
| Verifica, archivio Xipper -9 | **0,58 s** | 0,97 s |
| Verifica, archivio `7zz -mx5` | 0,79 s | 0,79 s |
| Verifica, archivio `7zz -mx6` (due blocchi da 256 MiB) | 1,27 s | 1,28 s |
| Verifica, archivio `7zz -mx9` | 1,28 s | 1,27 s |
| Estrazione, archivio Xipper -6 | **5,4 s** | `7zz x` 8,7 s |

La verifica e l'estrazione dividono il flusso LZMA2 ai reset del dizionario (anche dietro AES) e decodificano i segmenti in parallelo: prima di questa ottimizzazione la verifica dell'archivio cifrato durava 1,66 s. L'estrazione è dominata dalla creazione dei file, ispezionati uno per uno da Jamf Protect (vedi la fase 1).

**Assembly ARM64 contro liblzma**, stessi archivi e stessa macchina:

| Verifica | `LzmaDecOpt.S` (default) | liblzma (portabile) |
|---|---|---|
| `7zz -mx6`, `-mx9` | **1,6 s** su un thread, 1,27 s in parallelo | 2,0 s |
| Xipper -6 | **0,49 s** | 0,61 s |
| Xipper -6, un thread | **1,70 s** | 2,09 s |

Su un thread il decoder in assembly va come `7zz t -mmt=1` (1,66 s contro 1,66 s) ed è circa il 20% più veloce di liblzma. Il resto della differenza che c'era con 7-Zip non dipendeva dal decoder: i blocchi da 256 MiB di 7-Zip superavano il limite dei nostri segmenti, che ora arriva a 256 MiB compressi e 1 GiB decompressi (entro 1/32 e 1/16 della RAM).

## Decisioni e scoperte
- **Ordine dei coder** come lo scrive 7-Zip, dal lato compresso: `[7zAES] → LZMA2 → [ARM64]`, ognuno legato al precedente. I blocchi Copy cifrati hanno il solo AES.
- **7z non ha un verificatore della password:** un errore di decodifica o di CRC in un blocco cifrato viene riportato come `wrongPassword`, come fa 7-Zip ("Wrong password?").
- **Dizionario dichiarato = min(dizionario del livello, dimensione del blocco):** il decoder alloca quanto dichiarato, così gli archivi piccoli richiedono poca memoria. In lettura lo limitiamo allo stesso modo, anche per archivi altrui.
- **I file già compressi non passano da LZMA2:** 7-Zip li comprime comunque, sprecando tempo.
- **Dal LZMA SDK 26.05** (pubblico dominio, `Vendor/lzma-sdk`) vengono solo il decoder PPMd e il decoder LZMA/LZMA2 con il ciclo in assembly ARM64, ciascuno dietro un piccolo wrapper C. BCJ2 è scritto in Swift; i filtri x86, ARM, ARMT, PPC e SPARC sono portati da liblzma; ARM64 e RISC-V usano le funzioni a chiamata singola di liblzma 5.8.
- **Nomi con `\`** (archivi creati su Windows) trattati come separatori.
- **`ArchiveEntry.encryption`** per 7z vale `.aes(strength: 3, vendorVersion: 0, actualMethod: 0)`: `vendorVersion` 0 indica 7z AES-256-CBC, così l'etichetta "AES-256" dell'app funziona senza modifiche.
- **Bug di liblzma aggirato:** con LZMA1 a dimensione nota, un marker di fine diviso fra due blocchi d'input veniva rifiutato come dato non valido dopo aver prodotto tutto l'output. Lo trovano i test di confronto con l'input a pezzi da 7 byte. Ora il decoder portabile si ferma quando ha prodotto la dimensione dichiarata, e la correzione vale anche per il metodo LZMA (14) dei ZIP.
- **In debug** il linker avvisa "could not associate debug note" per le costanti `.equ` di `LzmaDecOpt.S`. È innocuo e in release non compare; il file vendorizzato resta invariato.
- **Bug della CLI corretto:** `create --overwrite` si mangiava l'opzione successiva (per esempio `--password-stdin`), che diventava il nome dell'archivio.

## Rimandato
- **App:** aggiungere `.sevenZip` agli `switch` esaustivi su `ArchiveFormat` (`Preferences.displayName`), passare la password a `Xipper.list` per i nomi cifrati e mostrare le opzioni solid, volumi e "cifra i nomi". Se ne occupa la sessione dell'app.
- **Scrittura di PPMd e BCJ2** (oggi solo lettura) e ordinamento dei file per estensione (`-mqs`), che migliorerebbe il rapporto sui sorgenti.
- **Lettura di Deflate64, IA64, SWAP2/4 e degli archivi SFX** (7z con eseguibile davanti).
- **Decodifica parallela dei flussi senza reset:** impossibile per costruzione. Il decoder è già quello in assembly di 7-Zip.
- **GPU:** LZMA, PPMd e BCJ2 sono sequenziali per natura e non si prestano a Metal.
- **Aggiornamento sul posto** (aggiungere o togliere voci senza riscrivere l'archivio) e metadati macOS (xattr, ACL) nell'archivio.

---

# Fase 1.6: BGZF / bgzip (genomica)

*21 ottobre 2026 · stessa macchina · htslib 1.24 (Homebrew, compilato con libdeflate) come riferimento*

## Cosa c'è
- **Codec BGZF** (`Codecs/BGZF.swift`):
  - encoder parallelo con blocchi da 0xFF00 byte, blocco *stored* quando la compressione non conviene, marker EOF sempre scritto;
  - decoder parallelo che ricava i confini dei blocchi da `BSIZE`, conosce la dimensione d'uscita da `ISIZE` e controlla il CRC di ogni blocco.
- **Riconoscimento dal contenuto:** un gzip con extra field `BC` viene riconosciuto come BGZF, anche per `.bam` e `.bcf`.
- **Livelli** sulla scala 0–9 di bgzip, con la stessa tabella zlib→libdeflate di htslib (1,2,3,5,6,7,8,10,12): le dimensioni d'uscita coincidono con quelle di `bgzip -l N`.
- **API:**
  - `ArchiveFormat.bgzf`;
  - `CreateOptions.genomicsUsesBGZF`: gzip di VCF/BED/GFF/FASTA/FASTQ/SAM produce BGZF, attivo di default;
  - `CreateOptions.writeBGZFIndex`;
  - `Xipper.bgzfInfo`: blocchi, dimensioni e marker EOF, senza decomprimere;
  - `Xipper.writeBGZFIndex`: `.gzi` identico a `bgzip -r`;
  - `Xipper.convert`: gzip↔BGZF, anche sul posto, con l'elenco degli indici `.tbi`/`.csi`/`.gzi` non più validi;
  - `Xipper.decompressSingle` e `Xipper.stream`.
- **Verifica:** CRC di ogni blocco più il marker EOF. Un file troncato esattamente a un confine di blocco viene comunque segnalato. Funziona anche su BAM e BCF; la loro estrazione invece viene rifiutata, con un messaggio chiaro.
- **Smart store:** BAM, CRAM, BCF, `.bgz`, SRA e gli indici (`.bai`, `.crai`, `.tbi`, `.csi`, `.gzi`) non vengono ricompressi negli ZIP.
- **CLI `xipper bgzip`:** `-c`, `-d`, `-i`, `-I`, `-r`, `-t`, `-l 0-9`, `-@`, `-f`, `-k` (gli originali sono sempre conservati), `--convert`, `--info`.
- **Test:** 8 nuovi test (12 casi):
  - confini dei blocchi (0, 1, 65280, 65281 byte, 3 MB) e dati incomprimibili;
  - compatibilità con gunzip;
  - htslib: `bgzip -t`, `tabix` con query per regione, `.gzi` identico byte per byte, lettura dell'output di bgzip;
  - livelli entro l'1% di bgzip;
  - preferenza Genomica;
  - conversione sul posto con indice tabix segnalato come non valido;
  - troncamento e corruzione;
  - BAM creato con samtools.
  
  Totale: 30 test, tutti verdi.

## Prestazioni
VCF sintetico da 243 MB (320.000 varianti × 6), cache calda.

| Operazione | Xipper | htslib 1.24 |
|---|---|---|
| Compressione, livello 6 (default) | **0,59 s** → 50,13 MB | `bgzip -@10` 0,58 s → 50,14 MB |
| Compressione, livello 9 | 8,79 s → 45,40 MB | `bgzip -@10 -l 9` 8,44 s → 45,40 MB |
| Decompressione | **0,05–0,06 s** | `bgzip -d -@10` 0,05 s · `bgzip -d` 0,19 s · `gunzip` 0,20 s |
| Verifica | **0,04 s** | `bgzip -t` 0,17 s (4× più lento) |

Siamo alla pari con htslib multi-thread, che usa la stessa libdeflate, e 4 volte più veloci nella verifica. Il vantaggio per l'utente Mac sta nel non dover installare htslib e nell'integrazione con Finder e Comandi Rapidi; la conversione automatica gzip→BGZF evita gli errori di `tabix`/`bcftools`.

## Note
- htslib 1.24 allinea i blocchi alle righe nei file di testo. Xipper usa blocchi fissi da 0xFF00 byte: entrambe le scelte sono valide per la specifica, e tabix e bcftools funzionano con entrambe.
- Rimandato a v2: la creazione di indici tabix (`.tbi`/`.csi`), che richiede di interpretare VCF/BED/GFF, e la decompressione di BAM/BCF in forma non compressa.

---

# Fase 1.5: server MCP (`xipper mcp`)

*21 ottobre 2026 · verificato con Claude Code 2.1.236*

## Cosa c'è
- **Modulo `XipperMCP`:** solo Foundation, CryptoKit e Security; nessuno SDK. Il server JSON-RPC 2.0 gira su stdio, un messaggio per riga, con i log su stderr. Il framing è separato dal server, quindi si testa in-process.
- **Doppia versione del protocollo nello stesso processo:**
  - **2026-07-28** (senza stato): `server/discover`; `_meta` per richiesta (versione, capability del client, clientInfo); errore -32022 con `supported`/`requested` per le versioni non supportate; -32602 se mancano le capability; `resultType` su ogni risultato; `ttlMs`/`cacheScope` su discover e `tools/list`; `serverInfo` nel `_meta` dei risultati.
  - **2025-11-25 / 2025-06-18 / 2025-03-26** (con sessione): `initialize` negozia la versione, poi `ping`, `tools/list`, `tools/call`.
- **9 tool**, tutti con `inputSchema`, annotazioni (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint: false`) e `structuredContent`:
  - `archive_info`, `archive_list` (paginato, filtro glob), `archive_test`, `archive_read_entry` (testo, oppure immagine in base64);
  - `archive_extract`, `archive_create`;
  - `bgzf_compress`, `bgzf_check`, `bgzf_convert`.
- **Progresso e cancellazione:** `notifications/progress` quando il client invia un `progressToken`. `notifications/cancelled` interrompe il lavoro in corso, e a una richiesta cancellata non segue nessuna risposta.

## Sicurezza (STUDIO.md §6-ter)
- **Allowlist:** valgono `--allow`, le cartelle passate dopo `--` e `~/Library/Application Support/Xipper/mcp.json`. I percorsi passano per `realpath`, quindi i symlink e i `..` che escono vengono rifiutati. **L'allowlist si controlla prima dell'esistenza del file**, così le risposte non rivelano mai se un file esiste fuori dalle cartelle consentite. Senza cartelle configurate, ogni operazione viene rifiutata con l'istruzione su come configurarle.
- **Sola lettura** (`--read-only`): restano esposti solo i 5 tool di lettura.
- **Password mai nella chat:**
  - `password_ref` punta al Portachiavi (`xipper mcp password set|delete|list`, servizio `app.xipper.mcp`);
  - la password in chiaro è rifiutata, salvo `--allow-password-argument`;
  - l'audit non registra mai campi `password*`.
- **Conferme umane** prima di sovrascrivere archivi, estrarre sostituendo file o convertire sul posto:
  - con 2025-11-25 tramite una vera richiesta `elicitation/create`;
  - con 2026-07-28 tramite MRTR: `resultType: "input_required"` più un `requestState` **firmato con HMAC-SHA256** (chiave per processo), legato al tool e al digest degli argomenti, con scadenza a 10 minuti. Uno stato manomesso o riusato per un'altra chiamata viene ignorato e la conferma richiesta di nuovo;
  - un client senza elicitation non può eseguire operazioni distruttive.
- **Audit** in JSONL (`~/Library/Logs/Xipper/mcp-audit.jsonl`, permessi 0600): ora, client, tool, argomenti senza segreti, esito e durata.
- I limiti di estrazione (zip bomb, spazio libero), la quarantena e le altre protezioni di XipperKit valgono anche qui.

## Installazione
- **Claude Code:**

  ```bash
  claude mcp add --transport stdio --scope user xipper -- /percorso/xipper mcp --allow ~/Documents
  ```

  `xipper mcp install` stampa i comandi esatti.
- **Claude Desktop:** `xipper mcp bundle -o Xipper.mcpb` produce un MCP Bundle con manifest 0.3, `server.type: "binary"`, un `user_config` con le cartelle consentite (multiple, default Documenti) e l'interruttore per la sola lettura. Lo zip è creato con XipperKit e mantiene il bit eseguibile.

## Verifiche
- **Client reale, Claude Code 2.1.236**, con una configurazione isolata (HOME temporanea), stato "✔ Connected" in entrambe le modalità:
  - di default negozia `initialize` 2025-11-25, dichiara `elicitation: {}` e chiede `tools/list`;
  - con `MCP_SDK_GENERATION=v2 MCP_PROTOCOL_NEGOTIATION=auto` sonda con `server/discover` 2026-07-28 e prosegue in modalità moderna.
- **10 test nuovi** (40 in totale, tutti verdi):
  - handshake legacy e negoziazione delle versioni;
  - discover moderno ed errori -32022/-32602;
  - allowlist: percorsi esterni, symlink, `..`, percorsi relativi, nessun indizio sull'esistenza dei file;
  - sola lettura;
  - flusso completo in entrambe le modalità (create, info, list paginato e con glob, read, test con progresso, extract, audit);
  - MRTR con stato manomesso, falsificato, rifiutato e accettato, e client senza elicitation;
  - elicitation legacy;
  - password dal Portachiavi;
  - tool BGZF;
  - binario reale su stdio, moderno e legacy.

## Da fare
- **Validare il `.mcpb`** con il CLI ufficiale (`npx @anthropic-ai/mcpb validate`, non installato qui) e provarlo in Claude Desktop.
- **Firma:** firmare e notarizzare il binario nel bundle (fase di rilascio).
- **Funzioni future:**
  - richiesta della password tramite Xipper.app via XPC (alternativa a `password_ref`, prevista con l'app);
  - estensione Tasks per i lavori molto lunghi;
  - resources (`xipper://archive/...`).
