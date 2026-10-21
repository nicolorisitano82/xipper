# Xipper

*[Italiano](README.md) · English*

A native archiver for macOS on Apple Silicon. It creates, extracts, verifies and encrypts ZIP, 7z, tar (gz, bz2, xz, zst), cpio, Apple Archive and XIZ, Xipper's own format ([specification](docs/XIZ_SPEC.md)). It also reads lz4, brotli and split ZIP archives, and handles single compressed files and BGZF/bgzip for genomics (tabix/CSI indexes, VCF/BCF/BAM/CRAM checks, checksum manifests).

It needs no third-party software at run time: the open-source codecs are compiled into the app (see [Vendor/README.md](Vendor/README.md)). The project documents are written in Italian.

- Feasibility study and decisions: [STUDIO.md](STUDIO.md)
- Performance spike (phase 0): [SPIKE_FASE0.md](SPIKE_FASE0.md)
- Core and CLI (phase 1, with 7z from phase 3): [FASE1.md](FASE1.md)
- SwiftUI app (phase 2): [FASE2.md](FASE2.md) · UI specification: [docs/UI_SPEC.md](docs/UI_SPEC.md)
- Benchmarks: [docs/BENCHMARK.md](docs/BENCHMARK.md)
- Beta testers: [docs/BETA_TESTERS.en.md](docs/BETA_TESTERS.en.md)
- Roadmap (v1.0, v2; in Italian): [docs/ROADMAP.md](docs/ROADMAP.md)

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
Vendor/                  zstd, libdeflate, liblzma, LZMA SDK (PPMd, ARM64 LZMA decoder)
Sources/CXipShims/       C wrappers over the system zlib/bzip2, CRC-32C
Sources/XipperKit/       Swift core
  Xipper.swift           public API: create / extract / test / list, format detection
  Zip/                   parallel writer (ZIP64, AES-256, ZipCrypto, zstd), reader (also split), extraction, verification
  Tar/                   tar, cpio, Apple Archive; streaming (de)compression
  SevenZip/              7z: headers, coder graph, BCJ/BCJ2 filters, parallel LZMA2, volumes
  Codecs/                deflate, parallel gzip/bzip2/BGZF, xz/zstd, LZ4 frames, brotli, CRC-32
  Crypto/                WinZip AES, 7z AES-256-CBC, ZipCrypto
  Extraction/            safe extraction shared by every format
  Genomics/              tabix/CSI, index and CRAM/VCF/BCF checks, checksum manifests
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

MCP server for AI agents (Claude Code, Claude Desktop):

```bash
claude mcp add --transport stdio --scope user xipper -- "$PWD/.build/release/xipper" mcp --allow ~/Documents
```

Exit codes: `0` ok, `1` error, `2` usage error, `3` skipped entries or failed verification, `4` missing or wrong password, `130` cancelled (Ctrl-C).

## License

[MIT](LICENSE). The code in `Vendor/` keeps its own license: zstd BSD-3-Clause, libdeflate MIT, liblzma 0BSD, LZMA SDK public domain (see [Vendor/README.md](Vendor/README.md)).
