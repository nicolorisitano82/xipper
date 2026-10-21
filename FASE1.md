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
- 7z (fase 3), Deflate64 in lettura, ZIP multi-volume, RAR (valutazione legale).
- CLI + server MCP (fase 1.5, vedi STUDIO.md §6-ter).

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
