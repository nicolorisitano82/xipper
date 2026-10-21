# Lossless general-purpose codecs (LZ77 family) and entropy coders: state of the art for a new fast archive format

Research date: 2026-10-21. All numbers are copied from the cited source. The hardware and versions are given next to each number. Single-thread figures are used unless stated otherwise.

## 1. Benchmark numbers: ratio and speed per codec (Silesia, lzbench, LTCB)

### Takeaway
On a current x86 server core (lzbench 2.4, AMD EPYC 9555P, 2026), the Pareto frontier is:
- lz4 for speed: about 3.8 GB/s decode at ratio ~2.1.
- zstd for the broad middle: ~1.1–1.35 GB/s decode at every level, ratio 2.9 to 4.05.
- xz/LZMA at the top of the LZ class: ratio ~4.35, but only ~80–125 MB/s decode.
- Context mixing (cmix, nncp, paq8) beyond LZ, with roughly 2x better text ratio than LZMA but about 1000x slower.

zstd's flat decode speed across levels is its key property. Brotli and zlib decode at 300–450 MB/s.

### Cited Findings
**lzbench 2.4 (most recent authoritative table).** Setup: single thread of an AMD EPYC 9555P at 3.20 GHz, turbo off, Ubuntu 26.04, gcc 15.2.0, `silesia.tar` (211,947,520 B). Values are compression MB/s / decompression MB/s / compressed size as % of original. Source: [lzbench README](https://github.com/inikep/lzbench).

- memcpy: 24075 / 24002 MB/s.
- lz4 1.10.0 (default): 550 / 3832 MB/s, 47.60% (ratio ~2.10). lz4 --fast -17: 924 / 3977 MB/s, 62.15%.
- lz4hc 1.10.0:
  - -1: 259 / 3382 MB/s, 42.06%.
  - -9: 31.9 / 3703 MB/s, 36.75%.
  - -12: 10.4 / 3813 MB/s, 36.45% (ratio ~2.74).
- zstd 1.5.7:
  - --fast=3: 509 / 1803 MB/s, 44.63%.
  - -1: 411 / 1351 MB/s, 34.53% (ratio ~2.90).
  - -2: 352 / 1257 MB/s, 32.70%.
  - -5: 126 / 1172 MB/s, 29.60%.
  - -8: 61.8 / 1301 MB/s, 28.17%.
  - -11: 36.1 / 1320 MB/s, 27.35%.
  - -15: 9.39 / 1345 MB/s, 26.83%.
  - -18: 4.13 / 1175 MB/s, 25.14%.
  - -22: 1.99 / 1087 MB/s, 24.67% (ratio ~4.05).
  - Level 3 appears only in the multi-threaded table, at 31.37%.
- brotli 1.2.0:
  - -0: 341 / 322 MB/s, 37.01%.
  - -2: 139 / 378 MB/s, 32.12%.
  - -5: 53.3 / 419 MB/s, 28.10%.
  - -8: 12.6 / 443 MB/s, 26.96%.
  - -11: 0.56 / 383 MB/s, 23.78% (ratio ~4.20).
- zlib 1.3.2: -1 at 89.0 / 297 MB/s, 36.45%. -6 at 26.8 / 314 MB/s, 32.19%. -9 at 11.3 / 318 MB/s, 31.92%.
- libdeflate 1.26 (Deflate-compatible):
  - -1: 202 / 783 MB/s, 34.68%.
  - -6: 82.1 / 820 MB/s, 31.85%.
  - -12: 4.73 / 832 MB/s, 30.52%.
  - libdeflate decodes about 2.6x faster than zlib on the same format.
- xz 5.8.4:
  - -1: 19.2 / 105 MB/s, 27.75%.
  - -5: 3.84 / 121 MB/s, 23.70%.
  - -9: 2.75 / 122 MB/s, 23.01% (ratio ~4.35).
- lzma SDK 26.03: -6 at 3.13 / 78.4 MB/s, 23.38%. -9 at 2.55 / 78.2 MB/s, 22.97%.
- lzham 1.0 -d26 -1: 3.16 / 273 MB/s, 25.83%. This is near-LZMA ratio with about 2x LZMA's decode speed.
- lizard 2.1 -10: 464 / 1911 MB/s, 48.79%. -19: 4.07 / 1821 MB/s, 36.53%.
- kanzi 2.5.3:
  - -1: 196 / 1112 MB/s, 37.44%.
  - -6: 15.0 / 31.2 MB/s, 23.36%.
  - -9: 2.48 / 2.44 MB/s, 19.73% (ratio ~5.07). This is a CM/BWT-class symmetric codec.
- bsc 3.3.12 -m0 -e1 (BWT): 19.4 / 25.0 MB/s, 23.26%.
- bzip2 1.0.8 -9: 12.7 / 35.5 MB/s, 25.75%.
- No run date is stated on the page beyond "© 2026".

**zstd README table.** Setup: Core i7-9700K at 4.9 GHz, Ubuntu 24.04, gcc 14.2, Silesia, lzbench. Values are ratio, compression MB/s, decompression MB/s. Source: [facebook/zstd README](https://github.com/facebook/zstd).
- zstd 1.5.7 -1: 2.896, 510, 1550.
- zstd --fast=1: 2.439, 545, 1850.
- zstd --fast=4: 2.146, 665, 2050.
- brotli 1.1.0 -1: 2.883, 290, 425.
- zlib 1.3.1 -1: 2.743, 105, 390.
- lz4 1.10.0: 2.101, 675, 3850.
- snappy 1.2.1: 2.089, 520, 1500.
- lzo1x -1: 2.106, 650, 780.

**Facebook launch post (2016).** Source: [Facebook Engineering, 2016](https://engineering.fb.com/2016/08/31/core-infra/smaller-and-faster-data-compression-with-zstandard/).
- At the same ratio, zstd compresses "~3-5x" faster than zlib.
- At the same speed, its output is "10-15 percent smaller".
- Decompression is "almost 2x faster": ~550 vs 270 MB/s on Silesia.
- Hardware: Intel E5-2678 v3 at 2.5 GHz.

**Matt Mahoney's Large Text Compression Benchmark (LTCB, enwik9 = 10^9 bytes of Wikipedia XML).** Times are in ns/byte, memory in MB. Source: [LTCB](https://www.mattmahoney.net/dc/text.html).
- Top context-mixing / neural-network entries:
  - "ex-girlfriend 1.0": 91,778,237 B, 220,071 / 241,636 ns/B, 10,204 MB, Threadripper 3970X.
  - cmix-neif 1.0: 91,913,343 B, ~175,000 ns/B both ways, 9,750 MB, EPYC 7B13.
  - nncp v3.2: 106,632,363 B, ~240,000 ns/B, uses an RTX 3090 GPU.
  - cmix v21: 107,963,380 B (enwik8 14,623,723), ~623,000–638,000 ns/B, 30,950 MB, i7-7700K.
  - paq8px_v206fix1 -12L: 124,696,410 B, ~292,000 ns/B, 28,151 MB, i9-12900KS.
  - paq8hp12any: 132,045,026 B, ~37,600 ns/B, 1,850 MB.
  - zpaq 6.42: 142,252,605 B, 6,699 / 14,739 ns/B, 14,000 MB.
- Reference compressors (all older versions on older hardware):
  - 7zip 4.46a PPMd: 178,965,454 B, 503 / 546 ns/B.
  - xz 5.2.1: 197,331,816 B, 5,876 / 20 ns/B.
  - zstd 0.6.0 -22 --ultra: 215,674,670 B, 701 / 2.2 ns/B, 792 MB.
  - brotli -q 11 -w 24: 223,597,884 B, 3,400 / 5.9 ns/B.
  - bzip2 -9: 253,977,839 B.
  - gzip -9: 322,591,995 B, 101 / 17 ns/B, 1.6 MB.
- My fetch of the page was truncated, so ranks 1–3 were not captured.

**Huff0/FSE stand-alone.** Source: [Cyan4973/FiniteStateEntropy](https://github.com/Cyan4973/FiniteStateEntropy).
- Hardware: i7-5600U, gcc 4.8.4, 32 KB blocks.
- On a skewed file (Proba80), Huff0 decodes at ~1350 MB/s, FSE at ~440 MB/s, and zlib's Huffman at ~300 MB/s.
- FSE compresses better on skewed distributions because Huffman cannot go below 1 bit/symbol.
- Newer zstd Huff0 "4X1" decoder benchmarks report ~1030–1310 MB/s on x86-64 depending on compiler and asm variant. Source: [zstd commit mirror](https://git.sharpetronics.com/sharpetronics/zstd/src/commit/8957fef554e844ef724022075ffdf740464aa515).

**Apple Silicon / ARM64.** Source: [Aras Pranckevičius, 2023](https://aras-p.info/blog/2023/01/29/Float-Compression-1-Generic/).
- Tested on a Ryzen 5950X and an Apple M1 Max (Clang 14), on float data.
- zstd decodes at about 1 GB/s with MSVC and about 2 GB/s with Clang (asm paths).
- lz4 decodes at about 5 GB/s.
- brotli decodes more slowly than zlib.
- The M1-specific numbers exist only as chart images.
- An OpenBenchmarking M1 lzbench run failed (binary missing). Source: [OpenBenchmarking](https://openbenchmarking.org/result/2210166-PROG-COMPRES40).

**Format specifications.**
- LZ77: Ziv & Lempel, "A Universal Algorithm for Sequential Data Compression", IEEE Trans. Inf. Theory 23(3), 1977.
- zstd format: [RFC 8878](https://www.rfc-editor.org/rfc/rfc8878). It uses FSE (tANS) for sequences and Huff0 for literals.
- Brotli: [RFC 7932](https://www.rfc-editor.org/rfc/rfc7932). It uses context-modeled Huffman plus a built-in static dictionary.

### Inferences
- **Decode speed tiers.** On x86 2025–2026:
  - lz4 family: ~3.8–4 GB/s.
  - zstd: ~1.1–1.8 GB/s, almost independent of level.
  - libdeflate: ~0.8 GB/s.
  - brotli and zlib: ~0.3–0.45 GB/s.
  - LZMA/xz: ~0.08–0.12 GB/s.
  - Context mixing: ~0.002–0.005 MB/s, i.e. kilobytes/s.
- **Pareto frontier (Silesia, ratio vs decode speed).** The frontier codecs are:
  - lz4, at ratio ~2.1.
  - lz4hc, at ratio ~2.7 with ~3.8 GB/s decode.
  - zstd, from ratio 2.9 to 4.05.
  - xz/lzma, at ratio ~4.35, or lzham at a ratio similar to zstd -18 with about 2x LZMA's decode speed.
  - kanzi or bsc, and then CM, above ratio 4.5.
  - Brotli -11 (23.78%) beats zstd -22 (24.67%) on ratio, but decodes ~3x slower. Zlib is dominated at every point.
- **Ratio gaps.** zstd -22 vs xz -9 is about 7% larger output (24.67% vs 23.01%) for ~10x faster decode. Most archivers (for example zstd-based .tar.zst) accept that trade.
- **Recommendation for a fast archive format.** Use zstd as the default codec. Add an lz4-class "store-fast" mode. Optionally add an LZMA-class (or zstd --ultra --long) "max" mode. Do not use Deflate or Brotli as the primary codec.

### Gaps
- No up-to-date Squash benchmark numbers were retrieved. The Squash site is old (2015–2017 era) and was not fetched.
- I found no published lzbench table on Apple M1/M2/M3/M4. Running lzbench locally on Apple Silicon is recommended.
- zstd levels 3/9/19 single-threaded are missing from the current lzbench table.
- Memory use per level was not captured from lzbench, which does not report it. Known rule of thumb, not verified here: the decoder needs about window size plus small tables.
- Ranks 1–3 of the LTCB were not captured.

## 2. ANS (Duda) and how tANS/rANS compare with Huffman and arithmetic coding

### Takeaway
ANS keeps the coder state in a single integer, not a [low, range] pair. That gives arithmetic-coding-level efficiency (fractional bits) at Huffman-like speed.
- tANS/FSE is table-driven and is used in zstd.
- rANS uses multiply/shift and suits adaptive models and SIMD/GPU interleaving.
- Huffman (Huff0) remains the fastest for literals with flat distributions. ANS wins on skewed distributions.

### Cited Findings
- Duda, "Asymmetric numeral systems: entropy coding combining speed of Huffman coding with compression rate of arithmetic coding", arXiv:1311.2540. Source: [arXiv](https://arxiv.org/abs/1311.2540).
  - Dates: v1 11 Nov 2013, v2 6 Jan 2014. The original ANS idea dates to Duda 2009 (arXiv:0902.0271).
  - Huffman approximates probabilities with powers of 2, which limits compression.
  - Arithmetic coding approaches entropy, but at a higher cost.
  - ANS uses a single natural-number state. A cited implementation decodes about 50% faster than Huffman for a 256-symbol alphabet at compression similar to arithmetic coding.
  - For tANS, the whole behavior fits in a table of a few KB for a 256-symbol alphabet.
- Huff0 vs FSE (tANS), Collet. Source: [FiniteStateEntropy](https://github.com/Cyan4973/FiniteStateEntropy).
  - Huff0 has a "massive speed advantage": ~1350 vs ~440 MB/s decode on i7-5600U.
  - FSE compresses better on skewed data because it breaks the 1-bit/symbol floor.
  - zstd therefore uses Huff0 for literals and FSE for the literal-length, match-length and offset codes ([RFC 8878](https://www.rfc-editor.org/rfc/rfc8878)).
- Giesen, "rANS in practice" (2015). Source: [ryg blog](https://fgiesen.wordpress.com/2015/12/21/rans-in-practice/).
  - Interleaving 2 rANS streams is ~1.4x faster for both encode and decode.
  - rANS gives "easily the fastest practical multi-symbol alphabet arithmetic decoders".
  - Huffman table construction is somewhat faster than tANS. Per-symbol decode cost is similar.
  - Deployments: Oodle LZNA (63-bit state, 32-bit renormalization) and BitKnit (32-bit state, 16-bit renormalization, 14-bit probabilities), both shipped in 2015.
- Giesen, "Interleaved entropy coders", arXiv:1402.3392 (2014). Sources: [ar5iv](https://ar5iv.labs.arxiv.org/html/1402.3392), [arXiv](https://arxiv.org/abs/1402.3392).
  - Setup: i7-2600K at 3.4 GHz, decode only.
  - Serial scalar rANS: ~202–266 MiB/s.
  - 2-way interleaved: ~338–501 MiB/s (1.62–1.88x).
  - 8-way SSE4.1 SIMD: ~564–573 MiB/s (2.15–2.79x). For example, book1 goes 219 → 365 → 566 MiB/s.
  - Multiple ANS streams can be merged into one bitstream without metadata.
  - The SIMD variant (`rans_word_sse41`) needs at least 4 independent streams.

### Inferences
- **Entropy stage of the new format:**
  - Huffman (4-stream, Huff0-style, branchless) for literals.
  - tANS/FSE for LZ sequence codes.
  - rANS, with N-way interleaving such as 4/8/32 lanes, if adaptive or order-1 modeling is wanted in a "max" mode. It also maps well to NEON and AVX2.
- Interleaving (multiple independent streams per block) is the main reason modern decoders reach multiple GB/s. A new format should require it in the bitstream layout, for example four Huffman streams with jump tables as in zstd.

### Gaps
- I found no recent NEON-specific rANS or Huff0 throughput numbers on Apple Silicon.
- No benchmark directly compares tANS and rANS decode MB/s on the same hardware.

## 3. Long-range matching and trained dictionaries (many small files)

### Takeaway
Trained dictionaries give a 2–5x ratio improvement on small (~1 KB) records. Facebook's example went from 2.8x to 6.9x.

`--long` (128 MB to 2 GB windows) helps on big archives with distant repetition, such as source trees and VM images. The cost is decoder memory equal to the window size.

### Cited Findings
- zstd dictionaries. Source: [Facebook Engineering 2016](https://engineering.fb.com/2016/08/31/core-infra/smaller-and-faster-data-compression-with-zstandard/).
  - Small-data compression is "2x to 5x better" with a dictionary.
  - On 1,000 GitHub user JSON records (~850 KB total, under 1 KB each), the ratio goes from 2.8x without a dictionary to 6.9x with a 65,599-byte dictionary built by `zstd --train`.
- The zstd README dictionary benchmark (github-users sample, ~10K records of ~1 KB) reports gains in ratio and in compression and decompression speed. Those numbers are shown only in charts. Source: [zstd README](https://github.com/facebook/zstd).
- COVER dictionary builder. Sources: [Moffat abstract](https://people.eng.unimelb.edu.au/ammoffat/abstracts/lpmw16www.html), [python-zstandard docs](https://python-zstandard.readthedocs.io/en/stable/dictionaries.html).
  - zstd's COVER trainer is based on Liao, Petri, Moffat, Wirth, "Effective Construction of Relative Lempel-Ziv Dictionaries", WWW 2016, pp. 807–816.
  - It treats dictionary building as a set-cover problem over k-mers (dmers). It picks the highest-coverage segment per epoch and concatenates the segments.
  - Its parameters are k (segment size) and d (dmer size).
- zstd `--long`, introduced in v1.3.2. Source: [zstd v1.3.2 release](https://github.com/facebook/zstd/releases/tag/v1.3.2).
  - It adds a dedicated long-distance match finder, and the output is still standard zstd.
  - The default window is 128 MB. `--long=31` gives a 2 GB window, and the decoder needs `--long=31` or `--memory=2GB`.
  - Overhead is minimal at any level.
  - On Linux 4.7–4.12 tarballs, zstd with a 2 GB window beat lrzip-zstd. The plain and 128 MB windows were too small.
  - Memory scales with window × threads.
  - Numbers are shown only in charts.
- RFC 8878 recommends that decoders support windows of at least 8 MB, which is relevant for interoperable defaults. Source: [RFC 8878](https://www.rfc-editor.org/rfc/rfc8878).

### Inferences
- **Small files.** An archive of many small files should do one of two things:
  - Solid-compress them sorted by type, which gives a large shared window.
  - Train a per-archive or per-type dictionary (COVER/fastCOVER) and store it once in the archive header. This keeps per-file random access, which solid blocks lose.
- **Large inputs.** Expose a long-range mode (window ≥128 MB, up to 2 GB) for large inputs. Record the window in the header so the decoder can refuse or limit memory.

### Gaps
- I did not retrieve exact `--long` ratio and speed numbers; they are chart-only in the release notes.
- I did not retrieve fastCOVER vs COVER speed numbers.

## 4. Context mixing (PAQ8, cmix, zpaq): ratio vs speed, and use for a "maximum" mode

### Takeaway
Context mixing (and neural-network coders such as nncp) reach about 92–125 MB on enwik9, versus about 197 MB for xz and 216 MB for zstd -22. That is roughly 40–55% smaller output.

The cost is about 0.1–0.6 ms per byte, i.e. ~2–10 KB/s, symmetric (decoding is as slow as encoding), and 10–30 GB of RAM. That is unusable for a fast archiver.

Lighter middle grounds exist: zpaq, PPMd, BWT (bsc), and kanzi -8/-9 (ratio ~5.0 on Silesia at ~2.5 MB/s). These are the realistic "max" options.

### Cited Findings
- Source for all LTCB enwik9 figures: [LTCB](https://www.mattmahoney.net/dc/text.html).
  - cmix v21: 107,963,380 B, ~623,000 ns/B compress, 30.9 GB RAM.
  - paq8px_v206: 124,696,410 B, ~292,000 ns/B, 28 GB.
  - zpaq 6.42: 142,252,605 B, 6,699 ns/B compress (~150 KB/s), 14 GB.
  - 7zip PPMd: 178,965,454 B at ~500 ns/B (~2 MB/s) symmetric.
  - xz: 197,331,816 B, with 20 ns/B decode (~50 MB/s on 2015-era hardware).
- Silesia, lzbench 2.4 on EPYC 9555P. Source: [lzbench](https://github.com/inikep/lzbench).
  - kanzi -9: 19.73%, 2.48 / 2.44 MB/s.
  - kanzi -6: 23.36%, 15 / 31 MB/s.
  - bsc: ~23.3%, ~19–29 / 15–25 MB/s.
  - xz -9: 23.01%, 122 MB/s decode.

### Inferences
- **For a "max" mode, ranked by practicality:**
  1. LZMA2-class, or zstd -19..22 --long. These keep fast decoding.
  2. An optional symmetric BWT/CM codec (bsc-like or kanzi-like) for text-heavy solid blocks. This gives ~10–15% smaller output than xz at ~5–40x slower decode.
  3. Full PAQ/cmix is only worthwhile as a research curiosity.
- **Hybrid idea.** An LZ parse with a small-context-mixing or adaptive rANS backend for literals, as in LZNA or LZMA's adaptive binary range coder. It recovers part of the CM gain while keeping LZ decode speed.

### Gaps
- I found no recent public benchmark of LZ+CM hybrids (for example Oodle LZNA or Leviathan) on Silesia with hardware details.
- No ARM64 timings for CM codecs were found.

## 5. Preprocessing filters (BCJ/BCJ2, ARM64, E8E9, delta) and measured gains

### Takeaway
Executable branch-address filters give a modest but nearly free gain. The ARM64 filter, new in xz 5.4 and 7-Zip 23, makes the Linux arm64 kernel about 5% smaller.

Archivers now auto-select the filter per executable type. Measured percentages for BCJ2 and E8E9 were not found in primary sources.

### Cited Findings
- **Linux kernel ARM64 filter.** Sources: [kernel commit 7472ff8](https://android-kvm.googlesource.com/linux/+/7472ff8adad8655f38b060a602f66e59c93c4793), [LKML patch](https://lkml.iu.edu/hypermail/linux/kernel/2403.2/04262.html).
  - The kernel's `xz_wrap.sh` commit "xz: adjust arch-specific options for better kernel compression" (2024) reports that the ARM64 BCJ filter shrinks the compressed kernel by about 5% compared with unfiltered xz/LZMA.
  - It requires xz ≥ 5.4.0.
  - Other alignment-option tweaks give 0–2%.
- **7-Zip 23.00/23.01.** Source: [7-Zip releases](https://github.com/ip7z/7zip/releases/latest).
  - Added the ARM64 filter for 7z and xz.
  - Automatically chooses BCJ or BCJ2 for x86 and ARM64 for ARM64 by inspecting .exe/.dll files. Previously the x86 filter was applied to all.
  - Raised the default BCJ2 section size from 64 MiB to 240 MiB.
  - No percentages are given.

### Inferences
- **Filters to include.** Reversible filters selected by content detection (ELF/Mach-O/PE header parsing):
  - x86 BCJ/E8E9.
  - ARM64. This is important for Apple Silicon and Mach-O, especially universal binaries.
  - Delta for structured, table-like and audio data.
- Filters should be per-file or per-block metadata so random access is preserved.

### Gaps
- I found no measured BCJ2-vs-BCJ, E8E9, or delta-filter percentage gains in primary sources within the budget.
- No data on filters for structured formats (columnar or float data, as in Aras P.'s later "float compression" posts) was retrieved.
