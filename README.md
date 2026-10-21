# Xipper

Archiviatore nativo per macOS su Apple Silicon: crea, estrae, verifica e cifra archivi ZIP e tar (gz, bz2, xz, zst), più file singoli compressi e BGZF/bgzip per la genomica. Non dipende da software di terzi a runtime: i codec open source sono compilati dentro l'app (vedi [Vendor/README.md](Vendor/README.md)).

- Studio di fattibilità e decisioni: [STUDIO.md](STUDIO.md)
- Spike delle prestazioni (fase 0): [SPIKE_FASE0.md](SPIKE_FASE0.md)
- Core e CLI (fase 1): [FASE1.md](FASE1.md)

## Struttura

```
Package.swift            SwiftPM: codec C + XipperKit + CLI + test (macOS 26, arm64)
Vendor/                  zstd, libdeflate, liblzma (sorgenti vendorizzati)
Sources/CXipShims/       wrapper C su zlib/bzip2 di sistema
Sources/XipperKit/       core Swift
  Xipper.swift           API pubblica: create / extract / test / list, riconoscimento del formato
  Zip/                   writer parallelo (ZIP64, AES-256, zstd), reader, estrazione e verifica parallele
  Tar/                   tar ustar/pax/GNU, compressione e decompressione in streaming
  Codecs/                deflate, gzip/bzip2 paralleli, xz/zstd multi-thread, CRC-32
  Crypto/                WinZip AES (CTR little-endian su AES-ECB hardware), ZipCrypto (sola lettura)
  Extraction/            estrazione sicura comune a tutti i formati
  Support/               concorrenza P/E-core, I/O, scansione delle sorgenti
Sources/xipper/          CLI
Tests/XipperKitTests/    interoperabilità, sicurezza, round trip
spike/                   codice e risultati della fase 0 e benchmark della fase 1
```

## Build e test

```bash
swift build -c release
```

```bash
swift test
```

I test di interoperabilità usano `unzip`, `ditto`, `tar` e `python3` di sistema. Se è installato, usano anche `7zz` (Homebrew): servono solo ai test, non all'app.

## CLI

```bash
.build/release/xipper create foto.zip ~/Pictures/Vacanze
```

```bash
.build/release/xipper create -p segreto.zip documenti/
```

```bash
.build/release/xipper create -f tar.zst backup.tar.zst progetto/
```

```bash
.build/release/xipper extract backup.tar.zst
```

```bash
.build/release/xipper test -p segreto.zip
```

```bash
.build/release/xipper list --long foto.zip
```

Genomica (BGZF, compatibile con `bgzip`):

```bash
.build/release/xipper bgzip -i varianti.vcf
```

```bash
.build/release/xipper bgzip --convert vecchio.vcf.gz
```

```bash
.build/release/xipper bgzip -t campione.bam
```

Uscita: `0` ok, `1` errore, `2` uso errato, `3` voci saltate o verifica fallita, `4` password mancante o errata, `130` annullato (Ctrl-C).

## Licenza

[MIT](LICENSE). Il codice in `Vendor/` mantiene la propria licenza: zstd BSD-3-Clause, libdeflate MIT, liblzma 0BSD (vedi [Vendor/README.md](Vendor/README.md)).
