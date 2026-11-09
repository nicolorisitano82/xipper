# Benchmark

Generato con `scripts/benchmark.sh 300 2` (corpus deterministico di 300 MB). Per rifarlo su un altro Mac: `scripts/benchmark.sh [MB] [esecuzioni]`.

## Benchmark Xipper — Apple M3 Max, 27.2, 2026-10-21

Corpus: 316 MB, 4496 file (sorgenti piccoli, testi, dati già compressi, un file grande). Miglior tempo su 2 esecuzioni, cache calda.

### Creazione

| Strumento | Tempo | Velocità | Archivio | Rapporto |
|---|---|---|---|---|
| Xipper ZIP (deflate, livello 6) | 0.33 s | 1020 MB/s | 216 MB | 65.0% |
| ditto -c -k (Utility Archivio) | 6.57 s | 50 MB/s | 222 MB | 66.9% |
| zip -r -6 (Info-ZIP) | 5.48 s | 61 MB/s | 220 MB | 66.5% |
| Xipper tar.zst (livello 3) | 0.37 s | 891 MB/s | 196 MB | 59.1% |
| tar + zstd -3 -T0 | 1.96 s | 169 MB/s | 196 MB | 59.1% |
| Xipper 7z (livello 6) | 15.63 s | 21 MB/s | 189 MB | 56.9% |
| 7zz a -mx5 | 55.49 s | 6 MB/s | 187 MB | 56.4% |

### Verifica ed estrazione

| Operazione | Tempo |
|---|---|
| Xipper test ZIP | 0.09 s |
| unzip -t | 1.78 s |
| Xipper extract ZIP | 0.39 s |
| ditto -x -k | 1.61 s |
| Xipper extract tar.zst | 0.67 s |
| zstd -d + tar -x | 1.27 s |

### Dizionari XIZ (23/10/2026)

20.000 file sotto 64 KiB presi dai repository di lavoro (53,6 MB, soprattutto sorgenti e JSON).
Dimensione dell'archivio e tempo di `xipper create`, con e senza `--no-dictionary`:

| Livello | Con dizionario | Senza | Differenza |
|---|---|---|---|
| 3 | 14,89 MB | 14,88 MB | +0,06% (a questo livello il dizionario non si usa) |
| 12 | 12,93 MB · 1,24 s | 13,06 MB · 0,80 s | −1,0% |
| 19 | 12,00 MB · 2,71 s | 12,13 MB · 2,19 s | −1,1% |

Con l'API di zstd, frame da 4 MiB e livello 12, un dizionario "attaccato" (il default) peggiora
del 3%, uno caricato nella finestra (`ZSTD_dictForceLoad`) migliora dell'1,4%. Il dizionario rende
molto di più sui file compressi uno per uno (−23%), ma il frame da 4 MiB condiviso resta più
piccolo di entrambi.

### Ottimizzazioni ARM64 (23/10/2026)

Apple M3 Max; tempo di `xipper`, cache calda, miglior tempo su tre esecuzioni.

| Operazione | Prima | Dopo | Come |
|---|---|---|---|
| `par2 create`, 512 MB, 10% | 4,40 s (28 s CPU) | 1,90 s (7,8 s CPU) | GF(2^16) in NEON (`TBL` su tabelle di nibble, `EOR3`); MD5 delle slice in parallelo con quello del file |
| `test` tar.bz2 di Xipper, 316 MB | 7,51 s | 1,51 s | blocchi bzip2 decodificati in parallelo |
| `test` tar.bz2 di `bzip2 -9`, 316 MB | (un solo thread) | 1,23 s | idem: i blocchi si trovano a qualunque offset di bit |
| `test` tar.xz di `xz -T1`, 234 MB | 1,94 s | 1,48 s | ciclo ARM64 di 7-Zip (`LzmaDecOpt.S`) al posto di liblzma |
| `test` tar.xz di Xipper (multiblocco) | 0,31 s | 0,31 s | resta liblzma multi-thread |

Dove va il tempo che resta:
- creazione di tar.xz e 7z: 68% in `bt_find_func`, il match finder di LZMA, che insegue puntatori ed è limitato dalla latenza della memoria;
- estrazione: il file system (`close`);
- xz a blocco unico: 12% nel CRC-64 a tabelle di liblzma.

### Ordinamento per tipo in XIZ (23/10/2026)

Gli stessi 20.000 file sotto 64 KiB, con i loro nomi (52 MB). XIZ senza dizionario, ordine di
scansione (cartella per cartella) contro ordine per estensione, nome, dimensione, percorso:

| Livello | Ordine di scansione | Ordinato | Differenza |
|---|---|---|---|
| 3 | 13,93 MB | 13,04 MB | −6,4% |
| 12 | 12,32 MB | 11,55 MB | −6,3% |
| 19 | 11,45 MB | 10,72 MB | −6,3% |

Con il dizionario si aggiunge circa lo 0,5% (11,50 MB a 12, 10,66 MB a 19). In una simulazione con
frame da 4 MiB, un MinHash del contenuto dentro ogni estensione faceva peggio del nome (12,81
contro 12,68 MB a livello 3), e la dimensione dopo il nome aiuta (12,22 MB).


## Codec per XIZ 1.4 — Apple M3 Max, macOS 27.2, 02/11/2026

Generato con `swift run -c release xipper-bench CORPUS... --runs 2` (`Sources/xipper-bench`): blocchi
indipendenti da 4 MiB come i frame di XIZ, **un solo core**, miglior tempo su 2 passate, cache calda.
Rapporto = dimensione compressa / originale (più basso è meglio). Corpus presi dai dati di questo Mac,
solo in locale (nel repo ci sono solo i numeri): sorgenti (SDK, Xipper), testo strutturato (JSON, XML,
CSV, log dei repository), binari delle app installate, documenti (PDF e Office da Documenti e
Scrivania), foto (JPEG/HEIC/PNG). Non misurati: zxc, bsc, kanzi (servirebbe compilare lzbench, codice
esterno). Brotli manca perché Xipper ha solo il suo encoder.

#### sorgenti: 33.0 MB, blocks of 4 MiB, best of 2

| Codec | Ratio | Compress MB/s | Decompress MB/s |
|---|---|---|---|
| LZ4 | 30.15% | 770 | 4376 |
| LZ4 HC 9 | 21.82% | 58 | 4917 |
| zstd -1 | 20.24% | 696 | 1926 |
| zstd -3 | 18.33% | 515 | 1858 |
| zstd -9 | 15.72% | 123 | 2093 |
| zstd -19 | 14.06% | 6 | 1851 |
| Deflate -6 (libdeflate) | 18.69% | 174 | 1844 |
| LZMA2 -6 | 13.69% | 7 | 233 |
| LZMA2 -9 | 13.69% | 7 | 235 |
| LZ4 (Apple) | 31.35% | 957 | 4114 |
| LZFSE (Apple) | 18.26% | 170 | 2413 |
| LZBITMAP (Apple) | 25.83% | 422 | 4551 |
| zlib (Apple) | 19.04% | 100 | 1035 |
| LZMA (Apple) | 13.69% | 7 | 255 |
| LZMESH (Apple) | 17.50% | 398 | 2476 |
| LZRAVEN (Apple) | 13.80% | 8 | 686 |

#### testo: 157.3 MB, blocks of 4 MiB, best of 2

| Codec | Ratio | Compress MB/s | Decompress MB/s |
|---|---|---|---|
| LZ4 | 24.59% | 1514 | 7214 |
| LZ4 HC 9 | 19.22% | 82 | 7852 |
| zstd -1 | 13.72% | 1189 | 2673 |
| zstd -3 | 13.87% | 806 | 2403 |
| zstd -9 | 12.37% | 187 | 2576 |
| zstd -19 | 10.63% | 5 | 2942 |
| Deflate -6 (libdeflate) | 13.81% | 271 | 2364 |
| LZMA2 -6 | 10.45% | 9 | 226 |
| LZMA2 -9 | 10.46% | 9 | 228 |
| LZ4 (Apple) | 24.59% | 1704 | 6283 |
| LZFSE (Apple) | 15.02% | 211 | 3227 |
| LZBITMAP (Apple) | 20.57% | 572 | 4345 |
| zlib (Apple) | 14.96% | 143 | 1270 |
| LZMA (Apple) | 10.45% | 9 | 232 |
| LZMESH (Apple) | 13.96% | 491 | 3401 |
| LZRAVEN (Apple) | 10.40% | 10 | 690 |

#### binari: 209.7 MB, blocks of 4 MiB, best of 2

| Codec | Ratio | Compress MB/s | Decompress MB/s |
|---|---|---|---|
| LZ4 | 47.01% | 873 | 4749 |
| LZ4 HC 9 | 38.59% | 58 | 4646 |
| zstd -1 | 34.67% | 692 | 1462 |
| zstd -3 | 31.21% | 497 | 1436 |
| zstd -9 | 28.86% | 118 | 1526 |
| zstd -19 | 26.31% | 7 | 1134 |
| Deflate -6 (libdeflate) | 32.63% | 142 | 1147 |
| LZMA2 -6 | 23.70% | 7 | 123 |
| LZMA2 -9 | 23.70% | 6 | 121 |
| LZ4 (Apple) | 47.03% | 898 | 4055 |
| LZFSE (Apple) | 32.18% | 141 | 1695 |
| LZBITMAP (Apple) | 34.32% | 388 | 3988 |
| zlib (Apple) | 33.17% | 66 | 667 |
| LZMA (Apple) | 23.70% | 7 | 134 |
| LZMESH (Apple) | 28.35% | 324 | 2137 |
| LZRAVEN (Apple) | 20.75% | 8 | 373 |

#### documenti: 209.7 MB, blocks of 4 MiB, best of 2

| Codec | Ratio | Compress MB/s | Decompress MB/s |
|---|---|---|---|
| LZ4 | 92.43% | 3926 | 16172 |
| LZ4 HC 9 | 90.55% | 67 | 12429 |
| zstd -1 | 88.99% | 1674 | 7943 |
| zstd -3 | 84.96% | 727 | 5896 |
| zstd -9 | 83.15% | 360 | 6077 |
| zstd -19 | 81.76% | 21 | 2941 |
| Deflate -6 (libdeflate) | 89.74% | 130 | 672 |
| LZMA2 -6 | 81.38% | 11 | 70 |
| LZMA2 -9 | 81.38% | 9 | 70 |
| LZ4 (Apple) | 92.16% | 1984 | 13489 |
| LZFSE (Apple) | 88.28% | 246 | 1045 |
| LZBITMAP (Apple) | 90.51% | 364 | 8720 |
| zlib (Apple) | 90.00% | 61 | 520 |
| LZMA (Apple) | 81.38% | 11 | 70 |
| LZMESH (Apple) | 83.74% | 451 | 3535 |
| LZRAVEN (Apple) | 81.41% | 16 | 254 |

#### foto: 125.8 MB, blocks of 4 MiB, best of 2

| Codec | Ratio | Compress MB/s | Decompress MB/s |
|---|---|---|---|
| LZ4 | 99.85% | 17130 | 27110 |
| LZ4 HC 9 | 99.74% | 65 | 21311 |
| zstd -1 | 99.37% | 3039 | 26271 |
| zstd -3 | 99.31% | 1967 | 25174 |
| zstd -9 | 99.26% | 1906 | 25560 |
| zstd -19 | 99.11% | 27 | 12027 |
| Deflate -6 (libdeflate) | 99.29% | 131 | 825 |
| LZMA2 -6 | 99.15% | 10 | 410 |
| LZMA2 -9 | 99.15% | 6 | 418 |
| LZ4 (Apple) | 99.80% | 2292 | 22231 |
| LZFSE (Apple) | 100.22% | 268 | 931 |
| LZBITMAP (Apple) | 99.44% | 347 | 24554 |
| zlib (Apple) | 99.36% | 63 | 1837 |
| LZMA (Apple) | 99.15% | 7 | 421 |
| LZMESH (Apple) | 99.16% | 1005 | 7158 |
| LZRAVEN (Apple) | 99.26% | 13 | 1521 |

### Cosa dicono

- **Un codec «veloce» non serve a XIZ.** zstd decodifica a 1,4–2,9 GB/s per core e XIZ decodifica i frame
  in parallelo: su 12+ core si supera già la velocità dell'SSD. LZ4 è 2–3 volte più veloce per core,
  ma comprime molto peggio (binari 47% contro 31% di zstd -3, sorgenti 30% contro 18%).
- **Per il modo «massimo» LZMA2 batte zstd -19** in rapporto (binari 23,7% contro 26,3%, sorgenti 13,7%
  contro 14,1%) alla stessa velocità di compressione, ma decodifica circa 10 volte più lento
  (120–235 MB/s per core). Con frame da 4 MiB, -6 e -9 danno lo stesso risultato: il dizionario non
  conta oltre la dimensione del frame. Frame più grandi aiuterebbero entrambi.
- **I codec Apple di macOS 27 sono i migliori nei due estremi**, ma esistono solo su macOS 27:
  - LZRAVEN: rapporto pari o migliore di LZMA2 (binari 20,8% contro 23,7%) e decodifica 3 volte più
    veloce (370–690 MB/s); compressione lenta come LZMA2;
  - LZMESH: rapporto vicino a zstd -9 (binari 28,4% contro 28,9%) a velocità di compressione vicina a
    zstd -3 (320–490 MB/s), decodifica più veloce di zstd (2,1–3,5 GB/s);
  - LZBITMAP: decodifica come LZ4 con un rapporto molto migliore (binari 34% contro 47%).
- **Documenti e foto quasi non si comprimono** (81–92% e 99%): i guadagni lì vengono solo dalla
  ricompressione dei flussi interni (Deflate nei documenti, JPEG), non da un codec migliore.

**Decisione (02/11/2026):** XIZ 1.4 aggiunge solo LZMA2 (con il filtro ARM64 per i frame di eseguibili
arm64), così il formato resta leggibile ovunque. LZRAVEN e LZMESH sono rimandati alla 3.0, come
codec facoltativi solo per macOS 27.

### XIZ 1.4 con LZMA2 (02/11/2026)

`xipper create -f xiz` sugli stessi corpora, con tutti i core (M3 Max, 16 core); tempi in secondi:

| Corpus | zstd 3 | zstd 12 («Massimo») | zstd 19 | LZMA2 |
|---|---|---|---|---|
| binari (209,7 MB) | 63,4 MB · 0,25 · 0,25 | 58,3 MB · 0,71 · 0,30 | 53,3 MB · 4,48 · 0,19 | **48,0 MB** · 4,81 · 0,39 |
| sorgenti (33,0 MB) | 6,06 MB · 0,10 · 0,08 | 5,10 MB · 0,17 · 0,08 | 4,65 MB · 0,95 · 0,08 | **4,52 MB** · 0,88 · 0,10 |
| testo (157,3 MB) | 21,6 MB · 0,16 · 0,14 | 19,1 MB · 0,42 · 0,15 | 16,6 MB · 4,96 · 0,14 | **16,3 MB** · 2,62 · 0,21 |

Ogni cella: dimensione · creazione · estrazione. Rispetto a «Massimo» con zstd 12, LZMA2 fa archivi
più piccoli del 18% (binari), 11% (sorgenti) e 15% (testo); la creazione è lenta come zstd 19 e
l'estrazione, con i frame in parallelo, resta sotto il mezzo secondo. Per questo nell'app LZMA2 è
un'opzione di «Massimo» (Impostazioni › Formati › XIZ) e non il predefinito: gli archivi si aprono solo
con Xipper 2.6 o successivo.

### 3.0, fase A: misure su file veri (09/11/2026)

File dell'utente in Documenti, Download e Scrivania (cartella dei BAM esclusa), letti sul posto; qui
solo i totali. La libreria Foto non ha originali in locale (sono su iCloud), quindi le foto sono i
JPEG di quelle cartelle.

**JPEG con brunsli** (`xipper-bench --jpeg`, un core): 650 file, 3.808 MB. 622 ricompressi, tutti
identici; 28 rifiutati da brunsli (restano in un frame normale). Risultato **83,98%** dell'originale
contro **98,31%** di zstd -19; 15,9 MB/s in codifica e 15,5 MB/s in decodifica per core. Le cifre dei
JPEG di sistema della 2.7 (78–84%) reggono su foto vere.

**Deflate e audio** (`scripts/estimate-recompression.py`, file da 4 KiB a 64 MiB). Per ogni file:
cosa fa XIZ oggi (zstd -19 e LZMA2 sul file com'è) e cosa farebbe con i flussi Deflate decompressi
(o con FLAC per l'audio). I dati che preflate aggiunge per ricostruire il Deflate originale non sono
contati: sui flussi di zlib sono circa lo 0,01%, con altri compressori di più, quindi i guadagni veri
sono un po' più bassi.

| Tipo | File | MB | LZMA2 oggi | LZMA2 dopo | Guadagno |
|---|---|---|---|---|---|
| PNG | 206 | 915,3 | 99,6% | 66,7% | **33,0%** |
| PDF | 311 | 275,2 | 85,4% | 67,1% | **21,5%** |
| DOCX, XLSX, PPTX, EPUB, ODF | 95 | 59,5 | 60,9% | 51,5% | **15,5%** |
| AIFF (suoni di sistema) → FLAC | 14 | 4,8 | 49,9% | 24,9% | 50,1% |

- **PNG** è il bersaglio più grande: oggi non si comprimono affatto (99,6%), dopo un terzo in meno;
- **PDF**: 264 file su 311 hanno flussi Flate; i PDF sopra i 64 MiB (circa 670 MB) non sono contati;
- **documenti Office**: guadagno minore, perché sono già piccoli e in parte testo che LZMA2 comprime;
- **audio**: nessun WAV o AIFF tra i file dell'utente; la stima viene solo dai suoni di sistema e non
  dice quanto conti nella pratica.

**Decisione per la fase E:** si fa, partendo da PNG e PDF; FLAC resta in fondo, solo se avanza tempo.
