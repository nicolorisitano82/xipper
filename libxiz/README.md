# libxiz

Implementazione indipendente in C99 del formato **XIZ 1.9** di Xipper (fino alla 1.8 in lettura), scritta a partire dalla
specifica pubblica [`docs/XIZ_SPEC.md`](../docs/XIZ_SPEC.md) e non dal codice Swift. Serve a
leggere, verificare ed estrarre archivi XIZ su macOS, Linux e Windows, e come seconda
implementazione per la riproducibilità forense (`docs/FORENSE_3.1.md`). Licenza MIT, come Xipper.

Dove spec e riferimento Swift non coincidono, o la spec è ambigua, è annotato in
[`SPEC_NOTES.md`](SPEC_NOTES.md).

## Stato

| Area | Stato |
|---|---|
| Superblock, footer, catalogo TLV, campi critici/non critici (§3–§7) | completo |
| Segmenti aggiunti e recupero da append interrotto (§11) | completo |
| Frame store / zstd / dizionari zstd (§4, §12) | completo |
| LZMA2 e ARM64 + LZMA2 (§14) | completo |
| Cifratura con password: Argon2id, AES-256-GCM, HKDF, catalogo STREAM (§6) | completo |
| Limiti e controlli anti-bomba (§5, §7, §8) | completo |
| Verifica (CRC-32C, SHA-256 / HMAC), lettura di una voce, estrazione sicura | completo |
| 1.3: directory, gruppi di accesso, destinatari password e X25519, soglie k-di-n (Shamir) | completo (lettura) |
| 1.3: voci cancellabili e slot azzerati (§13.7) | completo (lettura) |
| 1.3: firme Ed25519 dei segmenti e catena (§13.5) | verifica completa |
| 1.3: alberi Merkle, prove `xiz-proof-1` (§13.6) | verifica completa |
| Marca temporale RFC 3161 | rilevata, **non** verificata |
| Beta 0.1 (§9) | dietro `XIZ_OPEN_ALLOW_BETA`, senza fixture |
| Scrittura: XIZ 1.0 zstd, frame da 4 MiB, deduplica per file, password | completo |
| Scrittura: segmenti aggiunti (aggiunte, rimozioni, cartelle) su archivi 1.0–1.2/1.4 | completo |
| Scrittura di strutture 1.3 (gruppi, firme, slot), dizionari, LZMA2 | non prevista |
| 1.5: recovery record (§15): verifica, riparazione in place, aggiunta e rimozione, senza password | completo (un thread, NEON su AArch64) |
| 1.6: frame JPEG ricompressi con brunsli (§16) | lettura completa (decoder in C++, opzione `XIZ_JPEG`) |
| 1.7: destinatari post-quantum X-Wing (§17) | saltati: si apre con le altre credenziali |
| 1.8: frame LZRAVEN e LZMESH (§18) | lettura su macOS 27 (framework Compression), rifiutati altrove |
| 1.9: documenti con i flussi Deflate ricompressi (§19) | non ancora: rifiutati con un errore chiaro (bit 0x0100) |

## Build

Serve CMake ≥ 3.16, un compilatore C99 e, per i frame JPEG, un compilatore C++17. Le dipendenze
vengono compilate dai sorgenti già in `../Vendor` (zstd, liblzma, Argon2, brunsli e il decoder
Brotli) e da `third_party/` (crittografia).

```bash
cmake -S libxiz -B libxiz/build -DCMAKE_BUILD_TYPE=Release
```

```bash
cmake --build libxiz/build -j
```

```bash
cd libxiz/build && ctest --output-on-failure
```

Opzioni: `-DCMAKE_BUILD_TYPE=Debug` attiva AddressSanitizer e UBSan (`XIZ_SANITIZE`, default ON);
`-DXIZ_WERROR=ON` rende errori i warning (`-Wall -Wextra -Wpedantic -Wshadow -Wformat=2 …`);
`-DXIZ_FUZZ=ON` costruisce i fuzzer (serve un clang con libFuzzer: su macOS quello di Homebrew,
`-DCMAKE_C_COMPILER=$(brew --prefix llvm)/bin/clang`); `XIZ_VENDOR_DIR` indica un'altra copia di
`Vendor/`; `-DXIZ_JPEG=OFF` toglie brunsli e il C++: gli archivi con la feature `jpeg` vengono
rifiutati con un errore chiaro e `xiz_has_jpeg()` restituisce 0.

Piattaforme provate:

- **macOS 27, Apple clang, arm64**: build senza warning, `ctest` verde (Debug con sanitizer e Release).
- **Linux arm64** (container Debian stable): gcc 14 Debug con ASan/UBSan e clang 19 Release,
  build con `-Werror`, `ctest` verde.
- **Linux x86_64** (stesso container, emulato): gcc 14 Release e Debug con ASan/UBSan, `ctest`
  verde (copre anche il CRC-32C a tabelle, senza istruzioni ARM).
- **Windows**: cross-compilazione con MinGW-w64 senza warning (`-Werror`). **Non eseguita**: il
  codice Windows (API wide, `CreateFileW`, link simbolici, nomi riservati) è compilato ma non
  provato su una macchina Windows.

## CLI `xiz`

```
xiz list    [-l] <archive>
xiz info    <archive>
xiz test    [--frames] <archive>
xiz extract [-d DIR] [--overwrite] [--allow-external-symlinks] [--no-symlinks]
            [--no-permissions] [--no-times] [--continue] <archive> [entry...]
xiz cat     <archive> <entry>
xiz history <archive>                    firme dei segmenti (non servono chiavi)
xiz verify-proof <proof.json> <file>
xiz create  [-l LEVEL] [--frame-size MiB] [--overwrite] <archive> <file|folder>...
xiz append  <archive> [--add FILE[:PATH]]... [--delete PATH]... [--mkdir PATH]...
xiz scrub   [--repair] <archive>         ogni byte contro il recovery record; --repair ripara in place
xiz recovery add [--redundancy N] | remove | info <archive>
```

I record scritti da libxiz e da Xipper sono identici byte per byte e ciascuno ripara quelli
dell'altro. `append` toglie il record (§15.4): va riaggiunto dopo.

Credenziali: `--password-env VAR`, `--password-stdin` (una password per riga: più custodi di una
soglia), `--identity FILE` (chiave segreta X25519 `XIZ-SECRET-KEY-1-…`, ripetibile). Codici di
uscita: 0 ok, 1 errore o archivio danneggiato, 2 uso, 3 password mancante o sbagliata, 4 voci
saltate durante l'estrazione.

## API

Header unico: [`include/xiz.h`](include/xiz.h). Prefisso `xiz_`, handle opachi, ogni funzione
restituisce `XIZ_OK` (0) o un codice negativo `xiz_status` e riempie un `xiz_error` opzionale
(codice e messaggio). L'I/O passa da una callback di lettura a offset (`xiz_source`); ci sono
helper per file (`xiz_source_file`, API wide su Windows) e memoria (`xiz_source_memory`).

```c
#include "xiz.h"

xiz_open_options o = {0};
o.password = "…";                       /* facoltativa */
xiz_archive *a;
xiz_error err;
if (xiz_open_file(&a, "dati.xiz", &o, &err) != XIZ_OK) { fprintf(stderr, "%s\n", err.message); return 1; }

for (size_t i = 0; i < xiz_entry_count(a); i++) {
    xiz_entry e;
    xiz_get_entry(a, i, &e);
    printf("%s %llu\n", e.path, (unsigned long long)e.size);
}
xiz_test(a, 0, NULL, NULL, NULL, &err);                 /* frame e digest */
xiz_extract(a, "destinazione", NULL, NULL, &err);       /* estrazione sicura */
xiz_close(a);
```

Funzioni principali:

- apertura: `xiz_open`, `xiz_open_file`, `xiz_close`, `xiz_get_info`;
- voci: `xiz_entry_count`, `xiz_get_entry`, `xiz_get_xattr`, `xiz_find`, `xiz_read_entry`
  (streaming, digest verificato alla fine), `xiz_read_entry_alloc`;
- verifica: `xiz_test` (callback per ogni problema, rapporto finale);
- estrazione: `xiz_extract` con `xiz_extract_options` (flag, selezione, limite di byte, callback);
- 1.3: `xiz_group_count`/`xiz_get_group`/`xiz_group_prefix`, `xiz_stanza_count`/`xiz_get_stanza`,
  `xiz_signature_count`/`xiz_get_signature`, `xiz_check_tree`, `xiz_check_inclusion`,
  `xiz_verify_proof`; `XIZ_OPEN_NO_KEYS` apre un archivio 1.3 cifrato senza credenziali, per
  leggerne struttura e firme;
- scrittura: `xiz_writer_create`, `xiz_writer_append`, `xiz_writer_add_data` / `_add_file` /
  `_add_directory` / `_add_symlink` / `_add_tree`, `xiz_writer_remove`, `xiz_writer_finish`,
  `xiz_writer_abort`.

Un `xiz_archive` non è thread-safe (ha una cache di frame); per leggere in parallelo si apre una
volta per thread.

## Sicurezza dell'estrazione

- Percorsi: `..`, NUL e componenti oltre 255 byte scartano la voce (riportata); `/` iniziale,
  componenti vuote e `.` sono ignorate (§5.3).
- POSIX: ogni percorso è percorso con `openat(O_NOFOLLOW | O_DIRECTORY)` dal descrittore della
  destinazione e i file sono creati con `O_CREAT | O_EXCL | O_NOFOLLOW`: niente scrive attraverso
  un link simbolico, nemmeno uno già presente nella destinazione. Con `--overwrite` un link
  esistente viene sostituito, non seguito.
- I link simbolici sono creati per ultimi e solo se restano dentro la destinazione: relativi, con
  i `..` iniziali entro la profondità del link e nessun `..` dopo un nome (che potrebbe
  attraversare un altro link dell'archivio). `--allow-external-symlinks` toglie il controllo.
- setuid, setgid e sticky sono azzerati; permessi e mtime ripristinati (cartelle alla fine, dalle
  più profonde); proprietario solo con `XIZ_EXTRACT_OWNER`.
- La dimensione dichiarata della selezione è confrontata con il limite del chiamante e con lo
  spazio libero **prima** di scrivere.
- Windows: API Unicode e prefisso `\\?\`; ogni componente esistente deve essere una cartella vera
  (niente reparse point); nomi con `<>:"|?*\`, controlli, punti o spazi finali e nomi di
  dispositivo (`CON`, `COM1`…) sono resi validi (`xiz_windows_name`). I controlli Windows non sono
  atomici come `openat` (TOCTOU possibile se un altro processo modifica la destinazione durante
  l'estrazione).

Limiti del decodificatore: frame ≤ 64 MiB, catalogo ≤ 1 GiB (configurabile più basso con
`max_catalog`, e comunque allocato man mano che si decomprime), keys block ≤ 64 KiB, parametri
Argon2id entro i limiti di §6.2, dizionari ≤ 1 MiB, esattamente un frame zstd per payload,
lunghezze di output esatte per zstd e LZMA2, finestra LZMA2 ≤ 64 MiB e mai più grande del frame.

## Crittografia: scelta e licenze

Né CryptoKit né CommonCrypto: tutto è portabile e compilato dai sorgenti.

| Primitiva | Implementazione | Licenza |
|---|---|---|
| SHA-256, HMAC-SHA-256, HKDF | [BearSSL](https://bearssl.org) 0.6, `sha2small.c`, `hmac.c`, `hkdf.c` | MIT |
| AES-256-GCM | BearSSL 0.6, `aes_ct64*` (AES bitsliced a tempo costante) + `ghash_ctmul64` + `gcm.c` | MIT |
| X25519, Ed25519 (SHA-512) | [Monocypher](https://monocypher.org) 4.0.2, `monocypher.c` e `optional/monocypher-ed25519.c` | BSD-2-Clause o CC0 |
| Argon2id | PHC reference (`../Vendor/argon2`, già usata da Xipper) | CC0 o Apache-2.0 |
| CRC-32C | proprio (tabelle slice-by-8; istruzioni CRC su ARMv8) | MIT |
| Shamir GF(2⁸) | proprio, senza tabelle indicizzate dal segreto | MIT |

BearSSL è stata scelta perché le sue versioni "ct" sono a tempo costante senza istruzioni
specifiche della CPU e il sottoinsieme necessario è piccolo (16 file); Monocypher perché è un solo
file per X25519/Ed25519, verificato e senza dipendenze. Archivi scaricati da bearssl.org e
monocypher.org il 02/11/2026; SHA-256 degli archivi:

- `bearssl-0.6.tar.gz` `6705bba1714961b41a728dfc5debbe348d2966c117649392f8c8139efc83ff14`
- `monocypher-4.0.2.tar.gz` `38d07179738c0c90677dba3ceb7a7b8496bcfea758ba1a53e803fed30ae0879c`

Modifiche locali: nessuna ai sorgenti. Di BearSSL sono tenuti solo i file elencati in
`third_party/bearssl/src` (con `inner.h` e `config.h`) e tutti gli header pubblici; le licenze
sono in `third_party/*/LICEN*`. Le librerie vanno aggiunte ai riconoscimenti dell'app se libxiz
ci entra.

Codec: zstd 1.5.7 (BSD), liblzma 5.8.4 (0BSD, solo decoder LZMA2 e filtro ARM64, a thread
singolo), brunsli `c18b962` (MIT, solo decoder) con il decoder di Brotli 1.2.1 (MIT), da
`../Vendor` senza modifiche. Con brunsli la libreria statica contiene codice C++: chi la collega
usa il linker C++ (CMake lo fa da solo).

## Test

- `tests/unit.c`: vettori pubblicati (CRC-32C, SHA-256, HMAC, HKDF RFC 5869, AES-GCM NIST),
  Merkle, nomi Windows.
- `tests/run_fixtures.sh`: 60+ controlli end-to-end sulle fixture scritte da Xipper — estrazione
  confrontata con l'albero originale (contenuto, permessi, mtime, link), zstd, livello 19,
  dizionari, LZMA2, ARM64 + LZMA2, password, segmenti aggiunti, append interrotto, gruppi di
  accesso (tutto / solo gruppo 0 / identità X25519 / 2 custodi su 3 / un custode solo), firme e
  catena, prova valida e manomessa, archivi cancellabili, danni; poi il writer: creazione,
  deduplica, cifratura, append, rifiuto degli archivi 1.3. Con `XIPPER=…/xipper` controlla anche
  che Xipper legga gli archivi di libxiz e viceversa.
- `tests/security.c`: archivi forgiati byte per byte per violare ogni regola (bit richiesti
  sconosciuti, campi critici, totali, extent, gap, cataloghi con dati in coda, bombe zstd, frame
  oltre 64 MiB, `catalog_usize` falso, LZMA2 senza feature, con dati dopo l'end marker o senza);
  **ogni singolo byte alterato** di un archivio viene rilevato e ogni troncamento rifiutato;
  path traversal, link simbolici verso l'esterno, catene di link, link preesistenti nella
  destinazione, bit setuid; slot di chiave alterato o azzerato.
- `fuzz/fuzz_open.c` (tutto il percorso di lettura su un archivio in memoria) e
  `fuzz/fuzz_catalog.c` (parser e decodificatori singoli, prove JSON), con `fuzz/xiz.dict`.
  Prima campagna (02/11/2026, macOS, 4 worker, ASan+UBSan): 4 minuti di `fuzz_open` a partire
  dalle fixture e 3 di `fuzz_catalog` (circa 8 milioni di esecuzioni): nessun crash. È poco:
  va ripetuta più a lungo, idealmente in CI.

```bash
cmake -S libxiz -B libxiz/build-fuzz -DCMAKE_C_COMPILER=$(brew --prefix llvm)/bin/clang -DXIZ_FUZZ=ON -DXIZ_TESTS=OFF
```

```bash
libxiz/build-fuzz/fuzz_open -dict=libxiz/fuzz/xiz.dict -max_len=150000 CORPUS_DIR
```

Le fixture (`tests/fixtures`, ~550 KB, contenuto sintetico) si rigenerano con
`tests/make_fixtures.sh` (serve la CLI Swift: `swift build -c release --product xipper`). Le chiavi
`identity.key` e `signing.key` lì dentro sono chiavi di prova, generate per le fixture.

## Limiti noti

- Niente verifica CMS delle marche temporali RFC 3161 (presenza riportata).
- Il writer non produce strutture 1.3 né dizionari o LZMA2; l'append su archivi 1.3 è rifiutato.
- Il writer deduplica per file intero (SHA-256), non per chunk a contenuto variabile.
- La decompressione è a thread singolo (un archivio per thread); niente prefetch parallelo dei frame.
- Su Windows: non provato su una macchina reale; link simbolici solo con privilegio o Developer
  Mode; i permessi POSIX diventano al più l'attributo sola lettura.
- Gli xattr sono letti ed esposti (`xiz_get_xattr`) ma non applicati in estrazione.
