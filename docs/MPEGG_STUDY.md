# MPEG-G in sola lettura: studio tecnico

*Studio del 23/10/2026. Base di partenza: [STUDIO.md §4.5](../STUDIO.md) (stato dell'arte, Genie, brevetti), che qui non si ripete.*

> **Brevetti.** Il proprietario ha deciso di accettare il rischio brevettuale descritto in STUDIO §4.5 per la sola lettura. Questo documento tratta solo l'aspetto tecnico; il passo G0 resta documentato in STUDIO per la fase di scrittura.

Ambiente delle prove: MacBook Pro M3 Max (14 core), macOS 27.2, Apple clang 21, CMake e Homebrew. Genie `main` = tag `v2.0-p2` (`74927ae`, 14/5/2025, l'unica release, segnata come pre-release). Ramo `develop-part6` a `dd69575` (25/9/2026). Clone, build e dati di prova stanno nello scratchpad della sessione, mai nel repository.

---

## 0. Sintesi

- **Genie compila su Apple Silicon** con 4 correzioni banali al codice (include e tipi) e 2 opzioni di CMake. Il problema di OpenMP descritto in STUDIO è **superato**: la v2 non usa più OpenMP, ma `std::thread`.
- **Il round trip funziona solo su dati semplici**: FASTQ e allineamenti a lunghezza fissa senza tag. Le prove hanno trovato:
  - **un bug dell'encoder** (lunghezze variabili con coppie) che produce file corrotti;
  - **un buffer overflow nel decoder** (scrittura fuori dai limiti, confermata da ASan);
  - eccezioni nei thread che terminano il processo con `abort`;
  - una decina di perdite silenziose: tag, codici IUPAC, flag, TLEN, CIGAR `=`/`X`/`P`, nomi di mate 2.
- **Il formato prodotto di default da Genie 2 non è standard.** L'entropia predefinita è `zstd` (`encoding_mode_ID = 2`); il CABAC standard si ottiene solo con `--entropy gabac`.
- **Un `.mgb` da solo non è decodificabile.** I metadati del riferimento stanno in un file accessorio `.mgb.json`, propria di Genie. Il contenitore autosufficiente è il `.mgg` della Part 1.
- **Prestazioni in lettura (CABAC standard):**
  - 400.000 allineamenti si decodificano in 4,4 s, contro 0,23 s di CRAM 3.1 (circa 20 volte più lento), con 1,4 GB di RSS;
  - 400.000 letture FASTQ in global assembly richiedono 6,0 s, senza parallelismo, perché formano un'unica access unit (AU).
- **Dati di conformità pubblici: praticamente assenti.**
  - I bitstream della Part 5 e il software di riferimento della Part 4 non sono scaricabili liberamente.
  - Nel repository di Genie c'è un solo `.mgb` di "conformità" (2021), che la v2 non riesce a decodificare.
- **Raccomandazione: un modello ibrido.**
  - Il parser dei contenitori (riconoscimento, info, Quick Look) va scritto **in Swift**.
  - Il decoder di Genie si vendorizza, **solo il lato decodifica**, come target C++ di SwiftPM con uno shim C.
  - Il decoder però **non gira dentro l'app**: va eseguito in un **processo helper** isolato, a causa di abort, overflow e memoria.
  - Il porting completo in Swift è da scartare.

---

## 1. Build su macOS arm64

| Passo | Esito | Cosa serve |
|---|---|---|
| libbsc v3.3.4 (non è su Homebrew) | ❌ con il makefile originale (`-mavx2`, `-fopenmp` non supportati da Apple clang) | ✅ con `make CFLAGS="… -O3 -DLIBBSC_SORT_TRANSFORM_SUPPORT -DLIBBSC_ALLOW_UNALIGNED_ACCESS"`, senza AVX2 né OpenMP, e `make install PREFIX=…`; compila in 1 s |
| configurazione di CMake | ❌ `HTSlib NOT FOUND`: `FindHTSlib.cmake` usa `NO_DEFAULT_PATH` con percorsi Linux fissi | `-DHTSLIB_SEARCH_DIRS=/opt/homebrew -DCMAKE_PREFIX_PATH="<libbsc>;/opt/homebrew"` |
| include di zstd, lzma, libbsc e htslib | ❌ `zstd.h`/`lzma.h`/`libbsc.h`/`htslib/sam.h` not found: i `Find*.cmake` trovano le librerie ma non propagano gli include | `-DCMAKE_CXX_FLAGS="-I/opt/homebrew/include -I<libbsc>/include"` |
| `util/log.cc`, `core/stats/perf_stats.cc`, `read/localassembly/encoder.cc`, `apps/genie/capsulator/main.cc` | ❌ `implicit instantiation of undefined template std::basic_*stringstream` | aggiungere `#include <sstream>` (libc++ è più rigida di libstdc++) |
| `core/classifier_regroup.cc:324` | ❌ `no matching function for call to 'max'` (`size_t` è `unsigned long`, `uint64_t` è `unsigned long long` su Darwin) | `std::max<uint64_t>(…)` |
| build completa (Release, `make -j10`) | ✅ 41 s di wall-clock, 283 warning | binario `genie` da 6,0 MB (4,9 MB dopo lo strip); a runtime dipende da `libhts`, `libzstd` e `liblzma` di Homebrew |

Altro:
- La release usa htslib 1.20/1.21 su Linux; con htslib 1.24 di Homebrew funziona.
- L'operazione `capsulate` esiste ma non compare nell'help, che la chiama per errore `capsulator`.
- Ogni esecuzione crea cartelle `tmp.XXXXXXXXXX` nella working dir, che restano lì se il processo va in crash.

---

## 2. Prove di round trip

Strumenti usati:
- `genie transcode-*` per convertire SAM/FASTQ ↔ `.mgrec`;
- `genie run` per convertire `.mgrec` ↔ `.mgb`, oppure `.mgb` → SAM/FASTQ direttamente;
- `genie capsulate` per convertire `.mgb` ↔ `.mgg`.

Tempi in secondi di wall-clock, RSS massima da `/usr/bin/time -l`, 14 thread salvo indicazione.

### 2.1 FASTQ: 2 × 200.000 letture da 150 bp, generate (136 MB)

| Modalità | Codifica | Dimensione `.mgb` | Decodifica | RSS in decodifica |
|---|---|---|---|---|
| global assembly, zstd (default di Genie, **non standard**) | 2,54 | 37,3 MB | 0,85 | 0,5 GB |
| global assembly, **CABAC** (`--entropy gabac`) | 12,35 | 36,6 MB | 5,97 (5,99 con `-t 1`) | 1,1 GB |
| low latency, zstd | 0,93 | 53,0 MB | 0,80 | 0,5 GB |
| low latency, **CABAC** | 9,46 | 50,4 MB | 5,27 | 1,3 GB |
| riferimento: `gzip -6` | 5,2 per un file | ~65 MB in totale | — | — |
| riferimento: `zstd -19 -T0` | 25 per un file | 45,8 MB | — | — |

Contenuto:
- le sequenze e le qualità sono identiche come insieme;
- **l'ordine delle letture cambia**, perché global assembly le riordina;
- **il nome di mate 2 viene sostituito da quello di mate 1** (`… 2:N:0` diventa `… 1:N:0`): MPEG-G conserva un solo nome per template.

### 2.2 SAM: 400.000 allineamenti, coppie da 150 bp, con substitution, indel e soft clip, senza tag (140 MB, riferimento da 2 Mb)

| Modalità | Codifica | `.mgb` | Decodifica | Note |
|---|---|---|---|---|
| con riferimento, zstd | 0,87 | 34,8 MB | 1,53 (1,94 con `-t 1`) | + 0,66 s per il passaggio `.mgrec` → SAM |
| con riferimento, **CABAC** | 7,56 | 34,3 MB | 4,56 (6,62 con `-t 1`); da `.mgb` direttamente a SAM: **4,39 s, 1,4 GB** | 2 AU (da 256.000 e 144.000 record): il parallelismo si limita a 2 |
| local assembly, zstd | 2,49 | 35,7 MB | 3,24 | non richiede il FASTA |
| con riferimento, lzma / bsc | 25,1 / 4,6 | 34,8 / 33,6 MB | 2,1 / 3,2 | entrambi fuori standard |
| `capsulate` `.mgb` → `.mgg` → `.mgb` | 0,02 / 0,02 | `.mgg` di 34,8 MB | — | il `.mgb` estratto è identico |
| riferimento: **CRAM 3.1** (`samtools`, un thread) | 0,64 | 33,2 MB | **0,23** | — |

Contenuto:
- i record sono identici come insieme;
- **l'ordine non viene conservato**: su 400.000 record ci sono 199.999 inversioni di coordinate, perché l'output è raggruppato per coppia;
- l'header perde `SO:coordinate`.

### 2.3 Casi limite

Sono stati usati i 43 casi SAM di `data/test_data/` di Genie e il file di prova del lettore CRAM (`scratchpad/cram/in.sam`: 2.552 record, IUPAC, `QUAL=*`, unmapped, lunghezze 75/100/150).

| Caso | Risultato |
|---|---|
| unmapped, mapped single-end, coppie sovrapposte o distanti, secondari (`0x100`), `S`/`H`/`I`/`D`, read group in mgrec | ✅ round trip esatto sui campi 1–11 |
| **tag opzionali** (`NM`, `MD`, `RG`, `SA`, `BC`, `XS`, …) | ❌ **tutti persi**, senza avvisi |
| supplementary (`0x800`) | ❌ escono come secondary (`0x100`) |
| flag: QC-fail (`0x200`), mate reverse (`0x20`), duplicate sul mate | ❌ persi o alterati (`659`→`147`, `97`→`65`, `147`→`1171`) |
| TLEN di coppie in record separati (distanza > 32.767) | ❌ diventa `0` |
| CIGAR `=`/`X` | ⚠️ diventano `M`; la sequenza resta corretta |
| CIGAR `P` | ❌ diventa `H` (bug) |
| CIGAR `N` (splicing), tutto `D`, tutto `H`, half-mapped (classe HM) | ❌ record scartati dall'encoder (finiscono in `*.unsupported.mgrec`) |
| `QUAL = *` | ❌ l'encoder va in abort con `Invalid quality score` |
| basi IUPAC (`R`, `Y`) | ❌ **corruzione silenziosa** (`R`→`A`) |
| SAM non ordinato per coordinate | ❌ abort con `SAM file is not sorted`; i 59 unmapped "non ordinati" vengono scartati con un warning |
| **coppie a lunghezza variabile** in classe I/M | ❌ **file corrotto, crash in decodifica non deterministico** (§4.11) |

---

## 3. Architettura (lato decodifica)

### 3.1 Moduli e righe di codice

Il sorgente è in `src/genie/<area>/<modulo>`; il percorso `src/libs` citato da issue vecchie non esiste più. In tutto sono 88.664 righe (`.cc`/`.h`) più 38.219 di header di terze parti (`nlohmann/json`, CLI11, BBHash, kwaymergesort, picosha2).

| Modulo | Righe | Lato decodifica (stima per nome di file) | Ruolo |
|---|---|---|---|
| `util` | 9.405 | 6.765 | bit reader, ThreadManager, logging, wrapper di zlib |
| `core` | 17.482 | ~12.000 | record MPEG-G, parameter set, AU, flow graph, gestione del riferimento, API Part 3 (stub) |
| `format/mgb` | 3.686 | 3.444 | data unit della Part 2 (raw stream) |
| `format/mgg` | 15.236 | ~9.000 | box della Part 1, encapsulator e decapsulator |
| `format/sam`, `fastq`, `fasta` | 4.887 | ~3.200 | exporter, lettura del FASTA di riferimento |
| `entropy/paramcabac` | 3.286 | 3.286 | parametri CABAC della Part 2 |
| `entropy/gabac` | 10.817 | ~6.800 | CABAC (binarizzazioni, trasformazioni, contesti) |
| `entropy/zstd`, `lzma`, `bsc` | 2.210 | ~1.600 | entropie **fuori standard** |
| `read/basecoder` | 2.150 | 1.028 | decodifica degli allineati (classi P/N/M/I/HM) |
| `read/refcoder`, `localassembly`, `lowlatency` | 1.791 | ~1.000 | riferimento esterno, riferimento calcolato locale, classe U senza assembly |
| `read/spring` | 7.472 | ~1.600 | global assembly (SPRING): il decoder è piccolo, l'encoder è grande |
| `quality/paramqv1`, `calq` | 4.070 | ~2.000 | codebook QV e CALQ (con perdita) |
| `name/tokenizer`, `write_out` | 1.364 | ~1.100 | nomi delle letture |

**Un decoder di sola lettura richiede circa 35.000–45.000 righe** di C++17. Il filtro grezzo per nome di file ne conta circa 60.000; il resto sono writer e encapsulator che restano nei file di `core` e `mgg`. Le dipendenze esterne necessarie sono:
- **obbligatorie:** zlib, solo nell'exporter;
- **per i file prodotti da Genie:** zstd e liblzma, già vendorizzati in Xipper, e libbsc (Apache-2.0, circa 10 file C/C++);
- **non necessarie:** htslib (serve solo a `transcode-sam` in lettura), OpenMP, BBHash e kwaymergesort (lato encoder).

### 3.2 Flusso di decodifica

1. `format/mgb/Importer` legge i data unit in sequenza: **raw reference** (tipo 0), **parameter set** (tipo 1) e **access unit** (tipo 2, con block header per ciascun descriptor).
2. `FlowGraphDecode`:
   - per ogni AU sceglie un read decoder secondo la classe e il "computed reference";
   - per ogni descriptor sceglie l'entropy decoder secondo `encoding_mode_ID`.
3. Ogni AU, decodificata in `core::record::Record`, passa a un exporter (`mgrec`, SAM o FASTQ). Il parallelismo è **per AU**, con `ThreadManager` su `std::thread`.

| Read decoder | Quando | Note |
|---|---|---|
| `refcoder` / `basecoder` | AU di classe P/N/M/I/HM con riferimento esterno | richiede il FASTA e i metadati del riferimento |
| `localassembly` | `computed_ref = local assembly` | il riferimento si ricostruisce dai record precedenti nella stessa AU; è sequenziale |
| `lowlatency` | classe U senza computed ref | — |
| `spring` | classe U con global assembly | **l'intero dataset sta in una AU**: un thread solo, file temporanei nella working dir |
| — | `computed_ref = RefTransform / PushIn` | `UTILS_DIE("… not supported")` |

| Entropy decoder | `encoding_mode_ID` | Standard? |
|---|---|---|
| `gabac` (CABAC con i parametri di `paramcabac`) | 0 | ✅ Part 2 |
| `lzma` | 1 | ❌ Genie |
| `zstd` | 2 | ❌ Genie, ed è **il default di `genie run`** |
| `bsc` | 3 | ❌ Genie |

Altri vincoli:
- I descrittori "class-specific" producono un abort (`Class-specific entropy decoding not supported`).
- Per le qualità è supportata solo la modalità 1 (codebook di paramqv1).
- Il name decoder si sceglie con un'euristica sul numero di subsequence; nel codice c'è un `TODO`.

### 3.3 Contenitori

- **`.mgb` (raw stream della Part 2):**
  - è una sequenza di data unit senza magic number; il primo byte è il tipo (`0x01` per un parameter set);
  - il riconoscimento è solo euristico: tipo valido, dimensioni coerenti, parameter set analizzabile;
  - **i metadati del riferimento (nome, URI, checksum SHA-256 per sequenza, nomi e lunghezze dei contig) non stanno nel `.mgb`**, ma nel file accessorio `<file>.mgb.json` scritto da Genie;
  - senza quel file la decodifica fallisce, anche passando il FASTA: `Tried to read descriptor that has already ended`, oppure `Unknown reference ID`.
- **`.mgg` (Part 1):**
  - è un file a box: `flhd`, con `major_brand = "MPEG-G"` e `minor_version` `"1900"` oppure `"2000"`, poi `dgcn` (dataset group), `dghd`, `rfgn` (riferimento con URI e checksum), `dtcn` (dataset), parameter set e AU;
  - Genie lo legge e lo scrive con `capsulate` e supporta MIT, label e i box di protezione a livello di struttura;
  - **`genie run` non accetta un `.mgg` in ingresso** (`Unknown constellation of file name extensions`): prima va riconvertito in `.mgb` + `.json`;
  - il riferimento è memorizzato come URI `file:///percorso/assoluto.fa` con la checksum: il reader deve chiedere il FASTA all'utente e verificarlo.

---

## 4. Lacune per un reader fedele

Legenda dell'impegno: g = giorni-persona per una persona che conosce già il codice.

Sul testo dello standard: ISO/IEC 23092-1/-2/-3 sono a pagamento. Quello che segue viene dal codice di Genie, dai metadati pubblici ISO e dagli articoli. Dove non si può verificare è scritto **(non verificabile)**.

| # | Lacuna | Dove | Cosa richiede lo standard | Correzione proposta | Impegno |
|---|---|---|---|---|---|
| 4.1 | **API della Part 3**: 13 funzioni C (`GenieGetHierarchy`, `…BySimpleFilter`, `…Metadata…`, `…Protection`, `…Statistics`) che restituiscono `kGenieReturnCodeGUnlistedError`; l'API C++ in `api.cc` ha gli `UTILS_DIE` commentati | `src/genie/core/c_api.cc`, `api.cc` | la Part 3 ([23092-3:2022](https://www.iso.org/standard/82725.html), rivista nel 2025) definisce l'API di accesso e i metadati | **non serve per Xipper**: definiamo un nostro shim C minimo (§5). L'API completa resta fuori dalla fase 1 | 0 g (oppure 15–25 g per l'API completa) |
| 4.2 | **Campi ausiliari e tag SAM** persi | `format/sam/importer` non li legge; nel record MPEG-G non c'è un campo per loro | i campi ausiliari e l'interoperabilità con SAM stanno nella **Part 3** (§8 e Annex C nell'edizione 2022; §10 e Annex E nell'edizione 2025, secondo i riassunti dei rivenditori); la sintassi esatta **(non verificabile)** | in lettura: decodificare i campi ausiliari se presenti, il che richiede il testo della Part 3; fino ad allora, **segnalare nel report "tag non presenti nel formato"** | 2 g per il report; 8–12 g per il supporto, con il testo ISO |
| 4.3 | **Part 6** (annotazioni) | ramo `develop-part6` | — | **fuori dalla fase 1** (vedi sotto) | — |
| 4.4 | **Half-aligned (classe HM)** e half-mapped | l'encoder li scarta (`mgrec/importer.cc` `IsRecordSupported`); il decoder ha i rami `kClassHm` in `basecoder/decoder.cc`, ma non sono mai coperti da file prodotti da Genie; i casi 15 e 49 di `test_data` falliscono | la Part 2 definisce la classe HM (una lettura allineata e il mate no) | test con file HM di un altro encoder (che non abbiamo); revisione dei rami HM; controlli dei limiti | 3–5 g, più i dati |
| 4.5 | **Allineamenti secondari e supplementari** | i secondari sono codificati come record separati con `flag_not_primary`: ✅; i supplementari diventano secondari; il descrittore `mmap` (allineamenti multipli nello stesso record) è definito in `constants.h` ma **non viene mai letto** dal decoder | `mmap` e `msar`/split alignments nella Part 2; la semantica di `0x800` **(non verificabile)** | decodifica di `mmap` e degli split oltre il secondo; mappatura corretta di `0x800`; nell'export, ricostruzione del tag `SA` se lo standard lo prevede | 5–8 g |
| 4.6 | **Splicing (`N`)** | `IsECigarSupported` scarta i caratteri `*`, `/` e `%`; `encoder.cc:504` `"Splicing is currently not supported"`; [#33](https://github.com/tnt-LUH/genie/issues/33) | splice nell'extended CIGAR della Part 2 | lato decoder: gestire gli splice in `ContractECigar` e `DecodeMismatches` | 3–4 g |
| 4.7 | **Limite di 511 basi** | `read/spring/params.h` `kMaxReadLen = 511`, usato solo dall'encoder (`preprocess.cc`, buffer su stack in `reorder.impl.h`). Il **decoder SPRING non lo usa** | la Part 2 non ha questo limite **(non verificabile nel dettaglio)** | per un reader **non è un blocco**. Da verificare con letture lunghe (ONT/PacBio) prodotte da un altro encoder | 1 g di test |
| 4.8 | **Ordine dell'output SAM** ([#11](https://github.com/tnt-LUH/genie/issues/11), aperta dal 2020) | `FlowGraphDecode` emette le AU nell'ordine del file; AU di classi diverse coprono la stessa regione; le coppie escono raggruppate | lo standard non garantisce l'ordine originale (la classificazione P/N/M/I/U riordina) | export: **k-way merge** sulle AU con intervalli sovrapposti (le AU dichiarano `[seq, start, end]`), oppure ordinamento esterno a blocchi in Xipper, poi `@HD SO:coordinate`. Per FASTQ: opzione "ordine per nome" | 4–6 g |
| 4.9 | **Thread** | **OpenMP non c'è più nella v2**: nessun `#pragma omp`, `GENIE_USE_OPENMP` definisce solo una macro inutilizzata. Il parallelismo è per AU (`ThreadManager`); con le AU di default da 256.000 record il guadagno è minimo, nullo in global assembly (1 AU). Il tempo va per oltre l'80% in CABAC, come riportato nell'articolo | — | decodifica **in parallelo dei descriptor stream** dentro la stessa AU: i blocchi CABAC sono indipendenti, quindi si ottiene da 4 a 8 volte su M-series; pool di thread con GCD | 4–6 g |
| 4.10 | **libbsc** | non c'è su Homebrew; il makefile non compila su arm64; sul ramo part6 è vendorizzata in `thirdparty/libbsc` | fuori standard (`mode 3`) | vendorizzare il sottoinsieme di decodifica (Apache-2.0) senza AVX2 né OpenMP, come target `CBsc`. Opzionale: serve solo ai file `--entropy bsc` | 1 g |
| 4.11 | **Bug dell'encoder sulla lunghezza delle letture** (non era mai stato segnalato) | `read/basecoder/encoder.cc`, ramo "same record": `kReadLength` viene scritto **due volte** per il segmento 2 (`length_var_2` e poi `length2`). Con letture tutte della stessa lunghezza `rlen` viene ignorato e il bug resta nascosto; con lunghezze variabili il flusso `rlen` va fuori sincronia | — | patch di una riga (togliere il secondo `Push`), verificata: dopo la patch le decodifiche sono stabili. I **file `.mgb` già prodotti da Genie v2 con coppie a lunghezza variabile sono corrotti**: il reader deve rilevarli (sequenza più corta delle mismatch, o descrittori avanzati) e segnalarli | 0,5 g più la diagnosi |
| 4.12 | **Overflow nel decoder** (sicurezza) | `basecoder/decoder.cc:371`, `sequence[position] = …` senza controllo; su un input non valido ASan segnala `heap-buffer-overflow WRITE`; in Release il crash è casuale (`EXC_BREAKPOINT` nell'allocatore xzone). Lo stesso schema (indici presi dal bitstream senza verifica) ricorre in `DecodeMismatches`, `DecodeClips`, nei LUT degli alfabeti e in `Pull()` | un decoder conforme deve almeno rifiutare i bitstream non validi | controlli dei limiti in tutti i decoder di descrittori e di record; fuzzing con libFuzzer, ASan e UBSan sullo shim; corpus dai nostri file | 6–10 g |
| 4.13 | **Eccezioni nei thread → `std::terminate`** | `util/thread_manager.cc`: un `UTILS_DIE` dentro un worker produce `libc++abi: terminating due to uncaught exception` e il processo termina con `abort` | — | catturare l'eccezione nel worker e propagarla con `exception_ptr` al chiamante. Anche dopo la correzione, **l'isolamento in un processo resta necessario** (§5) | 1–2 g |
| 4.14 | **`.mgb` senza metadati del riferimento** | il file accessorio `.mgb.json` è un'invenzione di Genie (`capsulator/main.cc`) | nello standard i metadati del riferimento stanno nella Part 1 (box `rfgn`) o nella Part 3 | reader: preferire `.mgg`; per un `.mgb` cercare `.mgb.json` accanto al file, altrimenti chiedere il FASTA e ricostruire gli ID dalle sequenze. Decodifica di `.mgg` **diretta**, senza riconvertirlo in `.mgb` | 2–3 g |
| 4.15 | **Alfabeto IUPAC** | tutti i read decoder usano `AlphabetId::kAcgtn` in modo fisso; l'encoder trasforma `R`→`A` | nella Part 2 l'`alphabet_ID` 1 = IUPAC (16 simboli), noto da fonti secondarie **(non verificabile nel dettaglio)** | leggere `alphabet_ID` dal parameter set e scegliere il LUT corretto in `basecoder`, `lowlatency` e `spring`; rifiutare gli ID sconosciuti | 2 g |
| 4.16 | **Flag, TLEN e mate nell'export SAM** | `format/sam/exporter.cc` e la ricostruzione delle coppie in record separati (`kPairR1Split`, …); per le coppie lontane c'è anche [#34](https://github.com/tnt-LUH/genie/issues/34) | i flag `pcr_duplicate`, `quality_fail`, `proper_pair` e i dati del mate sono nel record **(dettagli non verificabili)** | riscrivere in Swift la parte "record MPEG-G → SAM/BAM" (§7, M5), con test sui 43 casi | incluso in M5 |
| 4.17 | **CIGAR `P`→`H`, `=`/`X`→`M`** | `basecoder/decoder.cc` `ContractECigar` ed exporter | l'extended CIGAR della Part 2 distingue le substitution, non il padding **(non verificabile)** | `=`/`X` si possono ricostruire dal riferimento (opzione d'export); `P` va corretto | 1 g |
| 4.18 | **`QUAL = *` e letture senza qualità** | l'encoder va in abort; nel decoder il caso "qualità assenti" non è coperto | la Part 2 ammette le qualità assenti **(non verificabile)** | nel decoder: se il descrittore QV è vuoto, `QUAL = *` / FASTQ `!` | 1 g |
| 4.19 | **Modalità non decodificabili** | `RefTransform`, `PushIn`, entropia class-specific, QV con modalità ≠ 1, CALQ (con perdita, decodificabile ma da segnalare) | previsti dalla Part 2 | messaggi chiari ("modalità X non supportata") e nessun abort; supporto solo se emergono file reali | 1 g più eventuali aggiunte |
| 4.20 | **Compatibilità tra versioni del bitstream** | il `gen-011.mgb` del 2021, incluso nel repository, non si decodifica con la v2 (eccezione `vector`); `MpegMinorVersion` conosce solo `1900` e `2000`; la Part 2 è alla 3ª edizione ([23092-2:2024](https://www.iso.org/standard/83527.html)) | le novità della 3ª edizione **(non verificabili)** | dichiarare supportate solo le versioni 1900 e 2000; diagnosi del caso `gen-011`; per l'edizione 2024 serve il testo | 2–4 g |
| 4.21 | **Problemi di contorno su macOS** | 4 correzioni di compilazione (§1); file temporanei nella working dir; il log va su stderr con il banner ASCII | — | patch al vendoring; working dir = `FileManager.temporaryDirectory`/UUID; logger reindirizzato allo shim | 1 g |

**Part 6 (`develop-part6`), stato al 25/9/2026:**
- 3.891 commit, circa 122.000 righe in `src/`, 877 file cambiati rispetto a `main`;
- nuovi tipi di record (genotype, contact, feature, track, …) e nuove entropie (rANS, JBIG, "ser");
- la CI fallisce negli ultimi 3 run (25/9, 20/8 e 15/8/2026);
- **`thirdparty/jbigkit` è GPL-2.0**, incompatibile con la regola "niente GPL" di `Vendor/README.md`;
- `thirdparty/codecs/procrustes` non ha nessun file di licenza;
- il ramo riscrive anche `basecoder/encoder.cc`: `kReadLength` compare 2 volte in punti diversi, quindi il bug 4.11 potrebbe essere corretto lì (non verificato).

**Conclusione:** le annotazioni restano fuori dalla fase 1; da valutare quando il ramo arriva in `main`, escludendo JBIG.

---

## 5. Opzioni d'integrazione

| Criterio | (a) Target C++ vendorizzato + shim C, in processo | (b) Porting in Swift | (c) Binario helper |
|---|---|---|---|
| Licenza | BSD-3 di Genie, Apache-2.0 di libbsc: compatibili con MIT; servono le note di attribuzione | nessun vincolo (opera derivata BSD-3, con attribuzione) | come (a) |
| Codice da mantenere | ~40.000 righe C++ "estranee", con patch locali da riapplicare a ogni aggiornamento (upstream è quasi fermo) | ~12.000–18.000 righe Swift nostre | come (a), più il protocollo di IPC |
| Dimensione | stima +2,5–3,5 MB in `XipperKit` (il `genie` completo strippato pesa 4,9 MB, incluso l'encoder); zstd e lzma riusano `CZstd`/`CLZMA` | +0,5–1 MB | +2,5–3,5 MB in un eseguibile separato |
| Robustezza | ❌ un abort o un overflow **fanno cadere l'app, il Finder Sync o Quick Look** | ✅ niente abort; i limiti li controlla Swift | ✅ un crash del helper diventa un errore gestito |
| Memoria e thread | 1,1–1,4 GB di RSS sui file di prova, dentro il processo dell'app o, peggio, di Quick Look | controllabile (streaming per AU) | isolata; si può limitare (`setrlimit`) e annullare con `SIGTERM` |
| Sandbox | l'app (DMG) non è sandboxed; **le estensioni Quick Look lo sono**: i file temporanei vanno in `NSTemporaryDirectory` | nessun problema | il helper va in `Contents/Helpers`, firmato con l'app; lanciato da un'estensione eredita la sua sandbox (è ammesso); nessun entitlement in più |
| Conformità | eredita i bug di Genie (§4), che vanno corretti nel vendoring | **alto rischio**: CABAC e SPRING vanno reimplementati senza bitstream di conformità (§6) | come (a) |
| Prestazioni | come Genie, con parallelismo per stream da aggiungere | il CABAC in Swift è circa 1,5–2 volte più lento del C++ senza un lavoro attento | come (a), più la serializzazione dei record (trascurabile rispetto al CABAC) |
| Impegno fino al primo export | ~15 g | ~60–90 g | ~18 g |

**Raccomandazione: un'architettura ibrida, (a) dentro (c), più un parser in Swift.**
1. **`CGenieDecode`:** target C++17 di SwiftPM in `Vendor/genie/`, con il sottoinsieme di decodifica di `v2.0-p2` e le patch del §4 (macOS, 4.11–4.15, 4.21).
   - Lo affiancano lo shim C `xg_open / xg_next_batch / xg_close / xg_error`, che non lascia mai uscire eccezioni, e `CBsc` (opzionale).
   - **Nessun legame con htslib**: SAM, BAM e CRAM li scrive Xipper.
2. **`xipper-mpegg`:** eseguibile helper di SwiftPM, linkato a `CGenieDecode`.
   - Legge `.mgb` o `.mgg` e restituisce su stdout **record binari in stile BAM**, cioè l'`AlignmentRecord` di `Genomics/CRAM/Alignment.swift`, più gli eventi di progresso e di perdita.
   - L'app, la CLI, MCP e Quick Look lo avviano con `Process`; per l'app è meglio un **servizio XPC** in seguito.
3. **`MPEGGContainer.swift`:** parser in Swift puro, senza C++, per i box della Part 1 e per i data unit e header di AU/parameter set della Part 2.
   - Basta per riconoscimento, info, elenco, inspector e Quick Look senza decodificare: è veloce, sicuro e funziona in sandbox.
4. **Non fare il porting completo (b)**, finché non arrivano i bitstream di conformità e una domanda reale. Il CABAC è il punto più costoso e più rischioso.

---

## 6. Dati di test

| Fonte | Cosa contiene | Disponibilità e licenza |
|---|---|---|
| **ISO/IEC 23092-5:2020** (conformità, [iso.org/standard/73668](https://www.iso.org/standard/73668.html)) | procedure e bitstream di test per le Part 1 e 2, "forniti in forma elettronica" | a pagamento (circa CHF 135); non è chiaro se i bitstream si scarichino liberamente da `standards.iso.org`: la ricerca non li ha trovati. Copyright ISO **(non verificabile)** |
| **ISO/IEC 23092-4:2020** (software di riferimento, [iso.org/standard/75859](https://www.iso.org/standard/75859.html)) | decoder e encoder di riferimento ("genomic model") | [mpeg-g.org](https://mpeg-g.org/?p=2451): licenza "ISO/BSD", ma **"accessible to MPEG delegates only"**. È lo strumento che Genie usava per i controlli incrociati ([#29](https://github.com/tnt-LUH/genie/issues/29)) |
| **Repository di Genie, `data/mpeg-g/conformance/`** | `gen-011` (coppie, lunghezza fissa: SAM, BAM, `.mgrec` per classe, **un `.mgb`** del 5/6/2021) e `gen-012` (single-end, lunghezze variabili, **senza `.mgb`**); FASTA di 10 kb di E. coli DH10B | BSD-3 (licenza del repository). Derivati dalla "sequencing data collection" di MPEG (`MiSeq_Ecoli_DH10B_110721_PF.bam`). **Il `.mgb` non si decodifica con la v2** (§4.20) |
| **Repository di Genie, `data/test_data/01–55`** | 55 casi limite (12 FASTQ, 43 SAM con FASTA minimi), con README | BSD-3; utili per il test dell'export (§2.3) |
| **CI di Genie** (`ci/conformance_test.sh`) | input, non bitstream: `ERR174310_short_{1,2}.fastq.gz`, `NA12878_S1_chr22_trunc.sam`, `hg19_custom.fa` | Seafile dell'università di Hannover: i link rispondono (HTTP 200, pagina di download), ma i file non sono stati scaricati. Dati di origine pubblici (ENA, Illumina Platinum) |
| **GenomSys** | MPEG-G Suite (CLI e SDK), commerciale; il sito mostra un `sample.mgg` da 1,6 GB in una demo | nessun download pubblico; prova gratuita su richiesta ([genomsys.com/mpeg-g-suite](https://www.genomsys.com/mpeg-g-suite/)) |
| **File `.mgg`/`.mgb` "in circolazione"** | nessuno trovato in archivi pubblici (ENA, SRA, Zenodo) nelle ricerche fatte | — |

**Piano per il corpus:**
1. Generare con Genie (patchato) una matrice "modalità × entropia × tipi di dato", in CABAC (conforme) e zstd (default di Genie), e salvarla in `Tests/Fixtures/mpegg/` sotto 1 MB.
2. Aggiungere i file corrotti noti (bug 4.11) come casi negativi.
3. Chiedere a GenomSys un campione `.mgg` prodotto dalla sua Suite, la seconda implementazione indipendente.
4. Valutare l'acquisto delle Part 1, 2 e 5: circa CHF 135–221 per parte.

---

## 7. Piano della fase 1 (sola lettura)

Ordine di lavoro: i passi M1–M2 non dipendono da Genie e si possono rilasciare da soli.

| Passo | Contenuto | Dipende da | Impegno |
|---|---|---|---|
| **M0 Vendoring** | `Vendor/genie/` (sottoinsieme di decodifica di `v2.0-p2`), patch per macOS e 4.11/4.13/4.21; target `CGenieDecode` (C++17 con le eccezioni attive, perché Genie le usa per gli errori: lo shim le cattura tutte) e `CBsc`; zstd e lzma da `CZstd`/`CLZMA`; aggiornare `Vendor/README.md` e i ringraziamenti | — | 3–4 g |
| **M1 Riconoscimento** | UTType `app.xipper.mpegg-gen` (`.mgg`), `…mpegg-stream` (`.mgb`), con icona. Magic number: `.mgg` = box `flhd` + `MPEG-G` + versione `1900`/`2000`; `.mgb` = data unit di tipo 0/1/2 con dimensioni coerenti e parameter set analizzabile. Comportamento nell'archiviatore: "già compresso", niente ricompressione (`Genomics.compressedExtensions`) | — | 1–2 g |
| **M2 List/info** (Swift) | `MPEGGContainer.swift`: dataset group, dataset, riferimento (nome, URI, checksum, contig), parameter set (classi, `alphabet_ID`, lunghezza delle letture, coppie, **entropia: "CABAC standard" o "Genie zstd/lzma/bsc, non standard"**, modalità QV/CALQ), elenco delle AU (classe, intervallo, numero di record) ricavato dagli header, quindi totale dei record senza decodificare. Output in CLI (`xipper info`), MCP e app | M1 | 3–5 g |
| **M3 Shim + helper** | `xg_*` in C; `xipper-mpegg` in streaming per AU; annullamento, progresso, limite di memoria; decodifica diretta di `.mgg`; `.mgb.json` facoltativo; FASTA chiesto all'utente e verificato con SHA-256 | M0 | 6–8 g |
| **M4 Verifica** | decodifica completa con exporter nullo: record contati e confrontati con gli header delle AU, checksum del riferimento, descrittori consumati per intero (che rileva il bug 4.11), alfabeto e modalità supportati. Report "OK / avvisi / errori" come `GenomicsCheck` | M3 | 2–3 g |
| **M5 Export SAM/BAM/FASTQ** | record MPEG-G → `AlignmentRecord` in Swift (flag, mate, TLEN, CIGAR, §4.16–4.18); header `@SQ` dal riferimento e `@HD SO`; **ordinamento per coordinate** (merge delle AU, §4.8); BAM con BGZF esistente; FASTQ appaiati (`_1`/`_2`) con ripristino di `/1` e `/2`; **report delle perdite** (tag assenti, CALQ, IUPAC, letture non rappresentabili) | M3 | 6–8 g |
| **M6 Export CRAM** | `AlignmentRecord` → nuovo `CRAMEncoder` (in sviluppo in `Genomics/CRAM/`, da non toccare: solo integrazione) | M5 e il writer CRAM stabile | 2–3 g |
| **M7 Quick Look e inspector** | anteprima con i dati di M2, in Swift e senza helper; "prime N letture" tramite il helper, con timeout di 2 s e limite di memoria; miniatura con il badge "MPEG-G" | M2 (M3 per le letture) | 3–4 g |
| **M8 Robustezza e prestazioni** | controlli dei limiti (§4.12), libFuzzer + ASan/UBSan sullo shim, corpus (§6), CABAC in parallelo per descriptor (§4.9), confronto con CRAM in `docs/BENCHMARK.md` | M3 | 8–12 g |
| **M9 Documentazione** | `docs/LEGGIMI.md`, guida utente, limiti dichiarati, licenze | tutto | 1 g |
| **Totale** | | | **circa 35–50 g-persona** (circa 7–10 settimane per una persona) |

### Rischi

| Rischio | Impatto | Mitigazione |
|---|---|---|
| Nessun bitstream di conformità indipendente: si testa Genie contro Genie | alto: bug simmetrici (encoder e decoder sbagliati allo stesso modo) non si vedono | campioni GenomSys; acquisto della Part 5; il software di riferimento della Part 4 tramite un delegato MPEG |
| File reali prodotti da Genie v2 col default zstd, non standard | medio | supportarli ed etichettarli come "non standard" |
| File corrotti da Genie (4.11) già in circolazione | medio | rilevamento in M4 e messaggio esplicito |
| Upstream poco attivo (main fermo dal 5/2025, issue del 2020 aperte) | medio: il fork diventa nostro | patch minime e documentate; valutare di proporle upstream |
| Memoria (1,1–1,4 GB per 140 MB) e SPRING in un'unica AU | medio su file da decine di GB | helper isolato; avviso sulla dimensione; streaming per AU |
| Perdite intrinseche (tag, ordine, nomi di mate) percepite come "file rovinato" | medio | export presentato come conversione, con il report delle perdite (STUDIO §4.5, punto 2) |
| Brevetti | accettato dal proprietario | — |

### Domande aperte per il proprietario

1. **Acquisto delle norme:** comprare ISO/IEC 23092-1, -2 (ed. 2024), -3 (ed. 2025) e -5, per circa CHF 600–700? Senza, 4.2, 4.5, 4.15 e 4.20 restano a metà.
2. **Contatto con GenomSys** per avere campioni `.mgg` della loro Suite? È l'unica seconda implementazione.
3. **Patch upstream:** proporre a tnt-LUH le correzioni di 4.11–4.13 e quelle per macOS (scelta di visibilità)?
4. **Ambito:** bastano FASTQ e allineati "comuni", o servono subito i supplementari, gli splice e i tag della Part 3?
5. **Lettura senza FASTA:** se il riferimento non è disponibile, ci si limita a info e verifica strutturale (M2) o si permette l'export dei soli non allineati?
6. **Helper o XPC:** per la v2 basta un eseguibile helper avviato con `Process`, o si va subito su un servizio XPC (più lavoro, migliore integrazione con la sandbox di Quick Look)?

---

## Fonti

- Genie: [github.com/tnt-LUH/genie](https://github.com/tnt-LUH/genie), con il tag `v2.0-p2` e i rami `main` e `develop-part6`; issue [#9](https://github.com/tnt-LUH/genie/issues/9), [#11](https://github.com/tnt-LUH/genie/issues/11), [#29](https://github.com/tnt-LUH/genie/issues/29), [#33](https://github.com/tnt-LUH/genie/issues/33), [#34](https://github.com/tnt-LUH/genie/issues/34), [#64](https://github.com/tnt-LUH/genie/issues/64).
- libbsc: [github.com/IlyaGrebnov/libbsc](https://github.com/IlyaGrebnov/libbsc) (v3.3.4, Apache-2.0).
- ISO: [23092-2:2024](https://www.iso.org/standard/83527.html), [23092-3:2022](https://www.iso.org/standard/82725.html), [23092-4:2020](https://www.iso.org/standard/75859.html), [23092-5:2020](https://www.iso.org/standard/73668.html).
- Software MPEG-G e accesso al software di riferimento: [mpeg-g.org](https://mpeg-g.org/?p=2451).
- GenomSys MPEG-G Suite: [genomsys.com/mpeg-g-suite](https://www.genomsys.com/mpeg-g-suite/).
- Articolo su Genie e analisi dei brevetti: vedi STUDIO.md §4.5.

*Le misure del §2 sono di una sola macchina con dati sintetici; vanno ripetute su dati reali (per esempio NA12878 chr22) prima di citarle in `docs/BENCHMARK.md`.*
