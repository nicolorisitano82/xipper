# Xipper: risultati dello spike (fase 0)

*21 ottobre 2026 · Apple M3 Max (10 P-core + 4 E-core, 36 GB) · macOS 27.2 · Xcode 27 · Swift 6.4*

Lo spike doveva rispondere a tre domande:
1. Quali codec usare, tra quelli di sistema e quelli vendorizzati?
2. Quanto rende l'hardware arm64 su CRC e crittografia?
3. Un writer ZIP parallelo batte davvero gli strumenti esistenti, restando compatibile?

**Risposta breve:** sì su tutte e tre. Il prototipo ZIP è **7–8 volte più veloce** di `zip` e di `ditto` (il motore di Archive Utility), con lo stesso rapporto di compressione e la piena compatibilità.

Il codice e i risultati grezzi sono in [`spike/`](spike/): istruzioni in [`spike/README.md`](spike/README.md), dati in [`spike/results/`](spike/results/).

---

## 1. Corpus

468 MB e 11.073 file, presi solo dal sistema locale: header SDK e framework (30%), binari di `/usr/bin` e `/usr/libexec` (55%), man page, sfondi HEIC già compressi (14%) e 45 symlink. Per i codec è stato riunito in un unico `mix.tar` da 474 MB. I test a thread singolo usano un campione a strisce da 67 MB che mantiene la stessa composizione.

## 2. Codec

### A thread singolo (67 MB)

| Codec | Rapporto | Compressione | Decompressione |
|---|---|---|---|
| zlib di sistema -6 | 39,6% | 52 MB/s | 1.200 MB/s |
| **libdeflate -6** | 39,5% | **142 MB/s** (2,7× zlib) | 1.355 MB/s |
| libdeflate -12 | 38,6% | 10 MB/s | 1.412 MB/s |
| Apple ZLIB (Compression.framework) | 39,9% | 70 MB/s | 775 MB/s |
| Apple LZFSE | 38,4% | 158 MB/s | 1.731 MB/s |
| Apple LZ4 | 51,0% | 1.019 MB/s | 4.458 MB/s |
| Apple LZBITMAP | 41,7% | 386 MB/s | 4.984 MB/s |
| Apple LZMA (xz -6) | 30,6% | 4,8 MB/s | 175 MB/s |
| bzip2 di sistema -9 | 36,2% | 19,5 MB/s | 55 MB/s |
| **zstd -3** | 37,4% | **516 MB/s** | 1.883 MB/s |
| zstd -9 | 35,1% | 126 MB/s | 2.030 MB/s |
| zstd -19 | 32,6% | 5,9 MB/s | 1.691 MB/s |
| xz -6 (liblzma) | 30,6% | 5,2 MB/s | 146 MB/s |

### Multi-thread, 14 thread (474 MB)

| Codec | Rapporto | Compressione | Decompressione |
|---|---|---|---|
| **zstd -3 MT** | 36,9% | **3.950 MB/s** | 1.713 MB/s |
| zstd -9 MT | 34,0% | 778 MB/s | 2.110 MB/s |
| zstd -9 MT --long | 31,1% | 547 MB/s | 2.225 MB/s |
| zstd -19 MT | 29,9% | 36 MB/s | 1.788 MB/s |
| **xz -6 MT** (liblzma) | 28,5% | **34,6 MB/s** (6,7× Apple LZMA) | **1.483 MB/s** (8,5×) |

**Decisioni:**
- **Deflate (ZIP, gzip):** *libdeflate* per i file piccoli e medi: a parità di rapporto è 2,7 volte più veloce di zlib. Per i file grandi, divisi in blocchi in stile pigz, oggi si usa la zlib di sistema, perché libdeflate non supporta né il dizionario né i blocchi non finali. → In fase 1 si valuta *zlib-ng* (licenza zlib) oppure una patch a libdeflate: guadagno atteso 2–2,5× sui file grandi.
- **zstd** è il miglior compromesso in assoluto: 3,9 GB/s su 14 core con un rapporto migliore di deflate -9. → Formato predefinito consigliato per `tar.zst` e per ZIP con metodo 93 ("modalità veloce").
- **xz:** la *liblzma vendorizzata* è indispensabile. Apple LZMA ha lo stesso rapporto ma **nessun multi-thread**, e con il multi-thread liblzma è 6,7 volte più veloce in compressione e 8,5 in decompressione.
- **bzip2** di sistema basta per compatibilità: lento, ma è un formato legacy.
- **Apple LZFSE, LZ4, LZBITMAP** si usano solo per `.aar`, perché non sono formati aperti interoperabili.

## 3. Checksum

| Implementazione | Velocità |
|---|---|
| CRC32 a tabella, byte per byte | 0,38 GB/s |
| CRC32 con l'istruzione ARMv8 `__crc32d`, in una sola catena | 9,7 GB/s |
| CRC32 della zlib di sistema (già ottimizzata da Apple) | 36,3 GB/s |
| **CRC32 di libdeflate** (PMULL + CRC su più flussi) | **66,3 GB/s** |
| Adler-32 di zlib / di libdeflate (NEON) | 18,1 / 52,7 GB/s |

→ **Revisione dello studio:** non serve scrivere CRC in NEON a mano. libdeflate è già al limite della banda di memoria, e l'istruzione CRC usata in modo ingenuo è 7 volte più lenta. Il CRC non sarà mai il collo di bottiglia.

## 4. Crittografia (CommonCrypto, hardware AES/SHA)

| Operazione | Velocità |
|---|---|
| AES-256-CTR | **13,0 GB/s** |
| AES-256-CBC, cifratura (7z; sequenziale per natura) | 1,45 GB/s |
| SHA-256 / SHA-1 / HMAC-SHA1 | 2,8 GB/s |
| PBKDF2-SHA1 ×1000 (chiave ZIP AES) | 0,75 ms per chiave |
| KDF di 7z, SHA-256 ×2¹⁹ | 5,8 ms per chiave |

→ La cifratura costa poco rispetto alla compressione. Il punto più lento è **HMAC-SHA1** (autenticazione WinZip AES), a 2,8 GB/s per flusso; si parallelizza per voce, quindi va bene.
⚠️ **Nota di implementazione:** WinZip AES usa CTR con contatore **little-endian**, mentre la modalità CTR di CommonCrypto è big-endian. Va implementato un CTR nostro sopra AES-ECB, sempre accelerato in hardware.

## 5. Prototipo ZIP parallelo (`xipzip`, Swift + target C)

Funzionamento:
- compressione per voce in parallelo;
- file sopra i 4 MB divisi in blocchi da 1 MB, compressi in parallelo con un dizionario di 32 KB innescato e un sync-flush, con CRC combinato (tecnica pigz);
- scrittura ordinata a lotti da 512 MB, per tenere limitata la memoria;
- nomi UTF-8, permessi Unix, symlink;
- scrittura *stored* se la compressione non conviene.

### Creazione (deflate -6, cache calda)

| Caso | xipzip, 14 thread | xipzip, 1 thread | Info-ZIP `zip -6` | `ditto -c -k` |
|---|---|---|---|---|
| Albero: 11.688 voci, 465 MB | **1,41 s** (330 MB/s) → 191,6 MB | 9,19 s | 10,53 s → 192,6 MB | 9,98 s → 192,2 MB |
| Albero con solo i 10 P-core | **1,32 s** (352 MB/s) | | | |
| File singolo da 474 MB | **1,22 s** (387 MB/s) → 184,6 MB | 10,08 s | 9,89 s → 184,8 MB | 9,38 s → 184,6 MB |

- **7,5× più veloce di `zip` e di `ditto`**, con un archivio **uguale o più piccolo**. La divisione in blocchi costa meno dello 0,1% di rapporto.
- **Gli E-core non aiutano nei lavori interattivi:** con 10 thread si va più veloci che con 14. → Lavori in primo piano solo sui P-core; gli E-core restano ai lavori in background (cartelle sorvegliate, Azioni rapide).

### Compatibilità degli archivi prodotti
- `unzip -t` ✅ · `python zipfile.testzip` ✅ · `bsdtar -t` ✅ (11.688 voci)
- Estrazione con **`ditto -x -k` (Archive Utility) + `diff -r`: identico** al sorgente. Symlink 45 su 45, bit eseguibili 12 su 12.
- Lo `unzip` di Info-ZIP rifiuta alcuni symlink con "Permission denied". Lo fa anche con un archivio creato da Info-ZIP stesso, quindi è una sua regola di sicurezza: blocca i symlink che puntano fuori dalla cartella di destinazione, e il corpus ne contiene. → **Xipper deve applicare la stessa regola** (§7 dello studio).

### Verifica parallela ("Testa archivio")

| Archivio | xipzip test, 14 thread | `unzip -t` |
|---|---|---|
| creato da Info-ZIP (465 MB) | **0,21 s** (2,26 GB/s) | 2,55 s (0,18 GB/s) |
| creato da ditto | 0,22 s (2,09 GB/s) | |
| creato da xipzip | 0,07 s (6,7 GB/s) | |
| file singolo da 474 MB | 0,63 s (757 MB/s): un flusso deflate unico si decomprime per forza in sequenza | |

→ La verifica è **12 volte più veloce** di `unzip -t`. Per i file grandi la decompressione resta sequenziale. **Idea per la fase 1:** il nostro writer conosce già i confini dei blocchi, quindi può salvarne un indice in un *extra field* proprietario ma ignorabile dagli altri programmi. Così i *nostri* archivi si potranno decomprimere in parallelo anche voce per voce, restando ZIP standard al 100%.

## 6. Integrazione Swift ↔ C

I codec C, compilati come target SwiftPM o come librerie statiche, si richiamano da Swift senza problemi e senza overhead misurabile.
Nella fase 1 restano da sistemare tre cose:
- passare a **Swift 6 con strict concurrency**: lo spike usa la modalità del linguaggio 5;
- compilare i codec come target SwiftPM, non con CMake;
- togliere i path assoluti.

## 7. Prossimi passi (fase 1)
1. Pacchetto `XipperKit`: compilazione dei codec dentro SwiftPM, writer ZIP con ZIP64, streaming oltre la RAM, scheduler P/E.
2. Valutare zlib-ng o una patch a libdeflate per i blocchi dei file grandi (obiettivo: oltre 800 MB/s in deflate -6).
3. ZIP AES-256 (CTR little-endian e HMAC) e protezioni di sicurezza: zip-slip, symlink in uscita dalla destinazione, zip-bomb, quarantena.
4. Lettore ZIP completo ed estrazione parallela, scrittura atomica, metadati macOS.
5. tar con gz/xz/zst e gli stessi motori.
