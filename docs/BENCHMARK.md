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
