# Vendored codecs

Xipper is self-contained: these sources are compiled into the app by SwiftPM. There are no
runtime dependencies besides macOS itself (Foundation, CommonCrypto, libz, libbz2).
Only permissive licenses are allowed here; GPL/LGPL code is never vendored.

| Library | Version | License | Path | Used for |
|---|---|---|---|---|
| [zstd](https://github.com/facebook/zstd) | 1.5.7 | BSD-3-Clause (`zstd/LICENSE`) | `zstd/` (lib: common, compress, decompress) | tar.zst, ZIP method 93 |
| [libdeflate](https://github.com/ebiggers/libdeflate) | 1.24 | MIT (`libdeflate/COPYING`) | `libdeflate/` (lib, x86/riscv code removed) | ZIP deflate, CRC-32 (PMULL), Adler-32 |
| [XZ Utils / liblzma](https://github.com/tukaani-project/xz) | 5.8.1 | 0BSD (`xz/COPYING.0BSD`) | `xz/src/liblzma`, `xz/src/common/tuklib_*` | tar.xz, ZIP methods 14 (LZMA) and 95 (xz), 7z LZMA/LZMA2 and the ARM64/RISC-V filters |
| [LZMA SDK](https://github.com/ip7z/7zip) (7-Zip `C/`) | 26.05 | public domain (stated in each file header) | `lzma-sdk/C` (PPMd variant H and LZMA/LZMA2 decoders), `lzma-sdk/Asm/arm64` (`LzmaDecOpt.S`), `lzma-sdk/shim` | 7z PPMd (030401); LZMA/LZMA2 decoding with 7-Zip's ARM64 assembly loop (liblzma stays the portable path) |

From the system (part of macOS, not vendored): zlib (streaming inflate, chunked deflate,
`crc32_combine`), bzip2, CommonCrypto (AES, HMAC-SHA1, PBKDF2).

## Local modifications
- Only library sources are kept (no CLI tools, tests, build scripts, x86/RISC-V assembly).
- `zstd/include/CZstd.h`, `libdeflate/include/CDeflate.h`: umbrella headers for SwiftPM (`CZstd.h` defines `ZSTD_STATIC_LINKING_ONLY` for `ZSTD_getFrameProgression`).
- `xz/src/liblzma/api/module.modulemap`: exposes only `lzma.h` (the `lzma/*.h` headers must not be included directly).
- liblzma is configured with the same `-D` defines its CMake build uses on macOS arm64 (see `Package.swift`).
- zstd is built with `ZSTD_MULTITHREAD`, `ZSTD_DISABLE_ASM`, `XXH_NAMESPACE=ZSTD_`.
- LZMA SDK: only `Ppmd7.c`, `Ppmd7Dec.c`, `LzmaDec.c`, `Lzma2Dec.c`, `Asm/arm64/LzmaDecOpt.S`, `Asm/arm64/7zAsm.S`
  and the headers they need, unmodified, built with `Z7_LZMA_DEC_OPT`. `lzma-sdk/shim/*` and
  `lzma-sdk/include/CLzmaSDK.h` are ours (small wrappers, the only API visible to Swift).

## Updating
1. Fetch the new tag into `spike/Vendor/` (ignored by git).
2. Copy the same subset of files as above; re-apply the umbrella headers / modulemap.
3. For liblzma, compare the defines in `build/xz/CMakeFiles/liblzma.dir/flags.make` with `Package.swift`.
4. `swift test` and the benchmarks in `spike/`.

The app's "Acknowledgements" screen must reproduce the three license texts (the LZMA SDK is public
domain and needs none, but crediting Igor Pavlov and Dmitry Shkarin is customary).
