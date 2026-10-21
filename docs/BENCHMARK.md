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
