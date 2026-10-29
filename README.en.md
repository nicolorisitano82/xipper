# Xipper

*[Italiano](README.md) · English*

A native archiver for macOS on Apple Silicon. It creates, extracts, verifies and encrypts ZIP (also bzip2, LZMA, xz, zstd, Deflate64, split volumes), 7z, tar (gz, bz2, xz, zst, lz4, br), lz4, brotli, cpio, Apple Archive and XIZ, Xipper's own format ([specification](docs/XIZ_SPEC.md)). It also opens RAR and RAR5 archives, encrypted RAR5 included. For genomics it converts BAM ↔ CRAM 3.1, writes BGZF/bgzip and the indexes samtools, bcftools and tabix use, and checks VCF/BCF/BAM/CRAM files.

| Compress | Browse, verify, repair |
|---|---|
| ![Xipper's main window: drop files to compress, with format, level and password](docs/screenshots/comprimi.png) | ![An XIZ archive open in Xipper: entries, inspector, verification and PAR2 recovery data](docs/screenshots/archivio.png) |
| **Per-folder access (XIZ 1.3)** | **Signed history** |
| ![The Access sheet: reserved folders and who can open them](docs/screenshots/accesso.png) | ![The inspector with the signature of every change](docs/screenshots/firme.png) |

It needs no third-party software at run time: the open-source codecs are compiled into the app (see [Vendor/README.md](Vendor/README.md)). The project documents are written in Italian.

- Feasibility study and decisions: [STUDIO.md](STUDIO.md)
- Performance spike (phase 0): [SPIKE_FASE0.md](SPIKE_FASE0.md)
- Core and CLI (phase 1, with 7z from phase 3): [FASE1.md](FASE1.md)
- SwiftUI app (phase 2): [FASE2.md](FASE2.md) · UI specification: [docs/UI_SPEC.md](docs/UI_SPEC.md)
- Benchmarks: [docs/BENCHMARK.md](docs/BENCHMARK.md)
- Beta testers: [docs/BETA_TESTERS.en.md](docs/BETA_TESTERS.en.md)
- Roadmap (in Italian): [docs/ROADMAP.md](docs/ROADMAP.md)
- XIZ format specification: [docs/XIZ_SPEC.md](docs/XIZ_SPEC.md)
- Genomics: [XIZ for genomics, study](docs/XIZ_GENOMICS_STUDY.md) · [XIG design](docs/XIG_DESIGN.md) · [MPEG-G study](docs/MPEGG_STUDY.md) (in Italian)

## Highlights

- **Fast on Apple Silicon.** Parallel ZIP writing, parallel gzip/bzip2/BGZF, multi-threaded xz/zstd/LZMA2, and 7-Zip's ARM64 assembly LZMA decoder. On an M3 Max, creating a 316 MB ZIP takes 0.33 s, against 6.57 s for Archive Utility.
- **Safe extraction.** It never writes outside the destination and refuses zip slip, external symlinks and zip bombs (with a capped "extract anyway"). It propagates quarantine to extracted files and fuzz-tests every reader.
- **Encryption.**
  - ZIP: AES-256 by default; ZipCrypto only on request, after a warning.
  - 7z: AES-256 with encrypted file names.
  - Apple Archive: AEA encryption.
  - XIZ: Argon2id and AES-256-GCM over data, names and metadata.
  - Passwords can be saved in the Keychain and unlocked with Touch ID.
- **Mac metadata.** Finder tags, resource forks and extended attributes are stored in tar and Apple Archive, and in ZIP on request (`__MACOSX`, like the Finder).
- **Edit archives without unpacking them.** Delete, rename and add entries; ZIP, 7z and XIZ keep untouched entries as they are (no recompression; in a solid 7z only the touched blocks).
- **PAR2 recovery data.** Written from the specification, compatible with par2cmdline and MultiPar; damaged archives are repaired from the window or the CLI, also when data was shifted by an insertion or a deletion.
- **XIZ for sensitive data** (XIZ 1.3, in the app and on the command line), features no common archive format has:
  - **per-folder access:** several recipients (password or X25519 public key), each sees and extracts only its folders; the others do not even appear;
  - **k-of-n unlock:** a folder opens only when, say, 2 of 3 custodians unlock together (Shamir secret sharing);
  - **signed history:** every change is signed (Ed25519), chained to the previous one and optionally time-stamped (RFC 3161); `xipper history` checks it without the password;
  - **proof of one file:** prove that a file belongs to the signed archive without handing over the rest (Merkle tree, RFC 6962); anyone can verify it with the file alone;
  - **erasure:** in archives created as erasable each file has its own key; erasing it makes the content unreadable in every version of the archive (copies made earlier keep it);
  - **keys in the Keychain:** identities and signing keys stay in the macOS Keychain and are used with Touch ID (Settings › Keys); the `xipper` command uses them as `keychain:NAME`.
- **Genomics.** CRAM 3.1 read and write (htscodecs), `.bai`/`.csi`/`.crai`/`.fai`/tabix indexes, BGZF compatible with `bgzip`, checks of VCF/BCF/BAM/CRAM. XIG, a native genomic profile of XIZ, is being designed ([docs/XIG_DESIGN.md](docs/XIG_DESIGN.md)).
- **Mount archives as volumes, read-write.** Open and edit an archive in the Finder without extracting it; when you eject it, Xipper writes the changes back into the archive. It uses a local WebDAV server and macOS's own client, with no kernel extension and no special entitlement.
- **macOS integration.**
  - Finder extension, Quick Actions, Quick Look previews and thumbnails.
  - Shortcuts actions (compress, extract, verify, list).
  - Notifications, Dock progress and an optional menu bar extra.
  - English and Italian.
- **For scripts and AI agents.** A CLI (`xipper`) and an MCP server (`xipper mcp`) with a folder allowlist and audit log.

## Layout

```
Package.swift            SwiftPM: C codecs + XipperKit + CLI + tests (macOS 26, arm64)
Vendor/                  zstd, libdeflate, liblzma, LZMA SDK (PPMd, ARM64 LZMA decoder), htscodecs, libarchive (RAR),
                         lz4, brotli (encoder), Argon2
Sources/CXipShims/       C helpers: zlib/bzip2 wrappers, CRC-32C, GF(2^16) NEON for PAR2, Deflate64
Sources/XipperKit/       Swift core
  Xipper.swift           public API: create / extract / test / list, format detection
  Zip/                   parallel writer (ZIP64, AES-256, ZipCrypto, zstd), reader (also split), extraction, verification
  Tar/                   tar, cpio, Apple Archive, RAR (libarchive) with RAR5 decryption; streaming (de)compression
  Xiz/                   XIZ: writer, reader, access groups and recipients, signatures, proofs, erasure
  SevenZip/              7z: headers, coder graph, BCJ/BCJ2 filters, parallel LZMA2, volumes
  Codecs/                deflate, parallel gzip/bzip2/BGZF, xz/zstd, LZ4 frames, brotli, CRC-32
  Crypto/                WinZip AES, 7z AES-256-CBC, ZipCrypto
  Extraction/            safe extraction shared by every format
  Genomics/              CRAM 3.1, BAM, indexes (tabix/CSI/BAI/CRAI/FAI), CRAM/VCF/BCF checks, checksum manifests
  Mount/                 archives mounted as volumes: copy-on-write tree, local WebDAV server, NetFS
  Support/               P/E-core concurrency, I/O, source scanning, extended attributes, AppleDouble
Sources/XipperMCP/       MCP server
Sources/xipper/          CLI
App/                     SwiftUI app and its Finder, Quick Look and thumbnail extensions
Tests/XipperKitTests/    interoperability, security, fuzzing, round trips
scripts/                 release, benchmark, string catalogs, icon
```

## Build and test

App (Xcode 27, macOS 26):

```bash
xcodebuild -project App/Xipper.xcodeproj -scheme Xipper -derivedDataPath .build/xcode build
```

Signed beta (self-signed) with a DMG in `dist/`:

```bash
scripts/release.sh beta3
```

Core and CLI:

```bash
swift build -c release
```

```bash
swift test
```

The interoperability tests use the system's `unzip`, `ditto`, `tar`, `cpio`, `aa` and `python3`. They also use `7zz`, `lz4` and `brotli` when Homebrew has them; these are needed only by the tests, never by the app.

Benchmark against the tools on your Mac:

```bash
scripts/benchmark.sh 600 3
```

## CLI

```bash
.build/release/xipper create photos.zip ~/Pictures/Holidays
```

```bash
.build/release/xipper create -p secret.zip documents/
```

```bash
.build/release/xipper create -f tar.zst backup.tar.zst project/
```

```bash
.build/release/xipper create -p --volume 2g private.7z archive/
```

```bash
.build/release/xipper extract backup.tar.zst
```

```bash
.build/release/xipper test --sha256 photos.zip > SHA256SUMS
```

```bash
.build/release/xipper list --long photos.zip
```

Edit an archive, repair it with PAR2:

```bash
.build/release/xipper edit photos.zip --delete old.jpg --rename draft:final --add new.jpg:final/new.jpg
```

```bash
.build/release/xipper par2 create --redundancy 10 photos.zip
```

```bash
.build/release/xipper par2 repair photos.zip.par2
```

Mount an archive as a volume (`/Volumes/<name>`) until you eject it or press Ctrl-C. Changes are saved into the archive; `--read-only` mounts it read-only, `--discard` drops the changes:

```bash
.build/release/xipper mount photos.zip
```

Genomics (BGZF, compatible with `bgzip`), tabix/CSI indexes and checksum manifests:

```bash
.build/release/xipper bgzip -i variants.vcf
```

```bash
.build/release/xipper tabix --bgzip variants.vcf
```

```bash
.build/release/xipper manifest create -o delivery.json data/
```

XIZ for sensitive data: keys, access policy, signed changes, proofs, erasure:

```bash
.build/release/xipper keygen -o research.key
```

```bash
.build/release/xipper keygen --signing -o signing.key
```

```bash
.build/release/xipper create -f xiz --access policy.json --sign signing.key --signer "Lab" case.xiz case/
```

```bash
.build/release/xipper list --identity research.key case.xiz
```

```bash
.build/release/xipper history case.xiz
```

```bash
.build/release/xipper prove -p case.xiz case/reports/r1.pdf -o r1.proof.json
```

```bash
.build/release/xipper verify-proof r1.proof.json r1.pdf
```

```bash
.build/release/xipper erase -p --sign signing.key case.xiz case/reports/r1.pdf
```

The policy file (passwords never sit in it: `password_env` or `password_prompt`) is described in `xipper help` and in [docs/XIZ_SPEC.md §13](docs/XIZ_SPEC.md).

MCP server for AI agents (Claude Code, Claude Desktop):

```bash
claude mcp add --transport stdio --scope user xipper -- "$PWD/.build/release/xipper" mcp --allow ~/Documents
```

Exit codes: `0` ok, `1` error, `2` usage error, `3` skipped entries or failed verification, `4` missing or wrong password, `130` cancelled (Ctrl-C).

## License

[MIT](LICENSE). The code in `Vendor/` keeps its own license: zstd BSD-3-Clause, libdeflate MIT, liblzma 0BSD, LZMA SDK public domain, htscodecs BSD-3-Clause, libarchive BSD-2-Clause, lz4 BSD-2-Clause, brotli MIT, Argon2 CC0/Apache-2.0 (see [Vendor/README.md](Vendor/README.md)).
