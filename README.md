# Xipper

*Italiano · [English](README.en.md)*

Archiviatore nativo per macOS su Apple Silicon: crea, estrae, verifica e cifra archivi ZIP, 7z, tar (gz, bz2, xz, zst) e XIZ, il formato di Xipper ([specifica](docs/XIZ_SPEC.md)), più file singoli compressi e BGZF/bgzip per la genomica (con indici tabix/CSI, verifica di VCF/BCF/BAM/CRAM e manifest dei checksum). Modifica gli archivi senza estrarli (ZIP e XIZ senza ricomprimere quello che non cambia) e li protegge con dati di recupero PAR2. Monta anche un archivio come volume, in lettura e scrittura: lo apri e lo modifichi nel Finder, e alla fine Xipper salva le modifiche nell'archivio. Non dipende da software di terzi a runtime: i codec open source sono compilati dentro l'app (vedi [Vendor/README.md](Vendor/README.md)).

- Studio di fattibilità e decisioni: [STUDIO.md](STUDIO.md)
- Spike delle prestazioni (fase 0): [SPIKE_FASE0.md](SPIKE_FASE0.md)
- Core e CLI (fase 1, con 7z della fase 3): [FASE1.md](FASE1.md)
- App SwiftUI (fase 2, in corso): [FASE2.md](FASE2.md) · specifica UI: [docs/UI_SPEC.md](docs/UI_SPEC.md)
- Beta per i tester: [docs/BETA_TESTERS.md](docs/BETA_TESTERS.md)
- Roadmap (v1.0, v2): [docs/ROADMAP.md](docs/ROADMAP.md)

## Struttura

```
Package.swift            SwiftPM: codec C + XipperKit + CLI + test (macOS 26, arm64)
Vendor/                  zstd, libdeflate, liblzma, PPMd del LZMA SDK (sorgenti vendorizzati)
Sources/CXipShims/       wrapper C su zlib/bzip2 di sistema
Sources/XipperKit/       core Swift
  Xipper.swift           API pubblica: create / extract / test / list, riconoscimento del formato
  Zip/                   writer parallelo (ZIP64, AES-256, zstd), reader, estrazione e verifica parallele
  Tar/                   tar ustar/pax/GNU, compressione e decompressione in streaming
  SevenZip/              7z: header, grafo dei coder, filtri BCJ/BCJ2, LZMA2 parallelo, volumi
  Codecs/                deflate, gzip/bzip2 paralleli, xz/zstd multi-thread, CRC-32
  Crypto/                WinZip AES (CTR little-endian su AES-ECB hardware), 7z AES-256-CBC, ZipCrypto (sola lettura)
  Extraction/            estrazione sicura comune a tutti i formati
  Mount/                 archivio montato come volume: albero copy-on-write, server WebDAV locale, NetFS
  Support/               concorrenza P/E-core, I/O, scansione delle sorgenti
Sources/xipper/          CLI
Tests/XipperKitTests/    interoperabilità, sicurezza, round trip
spike/                   codice e risultati della fase 0 e benchmark della fase 1
```

## Build e test

App (Xcode 27, macOS 26):

```bash
xcodebuild -project App/Xipper.xcodeproj -scheme Xipper -derivedDataPath .build/xcode build
```

Beta firmata (self-signed) con DMG in `dist/`:

```bash
scripts/release.sh beta1
```

Core e CLI:

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
.build/release/xipper create -p --volume 2g privato.7z archivio/
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

Modificare un archivio, riparare con PAR2:

```bash
.build/release/xipper edit foto.zip --delete vecchia.jpg --rename bozza:finale --add nuova.jpg:finale/nuova.jpg
```

```bash
.build/release/xipper par2 create --redundancy 10 foto.zip
```

```bash
.build/release/xipper par2 repair foto.zip.par2
```

Montare un archivio come volume (`/Volumes/<nome>`) finché non lo espelli o premi Ctrl-C. Le modifiche vengono salvate nell'archivio; con `--read-only` il volume è in sola lettura, con `--discard` le modifiche si scartano:

```bash
.build/release/xipper mount foto.zip
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

Indici tabix/CSI, verifica di VCF/BCF/BAM/CRAM e dei loro indici, manifest dei checksum:

```bash
.build/release/xipper tabix --bgzip varianti.vcf
```

```bash
.build/release/xipper index-check campione.cram varianti.vcf.gz
```

```bash
.build/release/xipper manifest create -o consegna.json dati/
```

```bash
.build/release/xipper manifest verify consegna.json
```

Server MCP per agenti AI (Claude Code, Claude Desktop):

```bash
claude mcp add --transport stdio --scope user xipper -- "$PWD/.build/release/xipper" mcp --allow ~/Documents
```

```bash
.build/release/xipper mcp bundle -o Xipper.mcpb
```

Uscita: `0` ok, `1` errore, `2` uso errato, `3` voci saltate o verifica fallita, `4` password mancante o errata, `130` annullato (Ctrl-C).

## Licenza

[MIT](LICENSE). Il codice in `Vendor/` mantiene la propria licenza: zstd BSD-3-Clause, libdeflate MIT, liblzma 0BSD (vedi [Vendor/README.md](Vendor/README.md)).
