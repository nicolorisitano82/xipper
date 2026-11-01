# Algoritmi di compressione lossless 2022–2026: candidati per Xipper

Scope: what is NEW relative to `docs/reports/Nuovo formato di compressione Xipper.md` (which already covers zstd/LZ4/Brotli/LZMA/ANS basics, Giesen interleaving, Recoil, DietGPU, nvCOMP, CDC/FastCDC, DwarFS, PAQ/cmix at a high level, Metal memory caveats from Beischl et al. DaMoN 2026). Research date: 2026-11-01. Unless noted, benchmark numbers are single-thread on Silesia (`silesia.tar`, 202 MB); "ratio %" = compressed/original (lower is better).

## 1. New codecs and format-aware frameworks (2022–2026), benchmarked against zstd/xz

### Takeaway
The most important new thing for Xipper on Apple Silicon is **zxc** (BSD-3): on an Apple M2 it decodes at 2x the speed of LZ4 at the same ratio, and at 2.8x the speed of zstd -1 at a slightly better ratio. Its catch is slow compression at the high levels, and the format still breaks between versions. **Meta OpenZL** (BSD, Oct 2025) is a real advance, but only for *structured* data (numeric columns, Parquet, CSV). On generic files it falls back to zstd, and its wire format is not yet stable. **Apple LZMESH** (OS 27) and **LZBITMAP** are free, system-provided, Apple-only codecs that could serve a fast "Apple-native" mode. Among the classic mid-range codecs, nothing new beats zstd's decode-speed/ratio curve, except kanzi and bsc at the high-ratio end.

### Cited Findings

**Reference baseline (lzbench 2.4, AMD EPYC 9555P 3.2 GHz turbo off, gcc 15, silesia.tar)** — [lzbench README](https://github.com/inikep/lzbench)
| Codec | Compr MB/s | Decompr MB/s | Ratio % |
|---|---|---|---|
| lz4 1.10.0 | 550 | 3832 | 47.60 |
| zstd 1.5.7 --fast=1 / -1 / -5 / -11 / -18 / -22 | 453 / 411 / 126 / 36.1 / 4.13 / 1.99 | 1707 / 1351 / 1172 / 1320 / 1175 / 1087 | 41.01 / 34.53 / 29.60 / 27.35 / 25.14 / 24.67 |
| xz 5.8.4 -1 / -9 | 19.2 / 2.75 | 105 / 122 | 27.75 / 23.01 |
| lzma 26.03 -9 | 2.55 | 78.2 | 22.97 |
| brotli 1.2.0 -5 / -11 | 53.3 / 0.56 | 419 / 383 | 28.10 / 23.78 |
| libdeflate 1.26 -6 / -12 | 82.1 / 4.73 | 820 / 832 | 31.85 / 30.52 |
| **zxc 0.14.1 -1 / -3 / -6** | 614 / 168 / 9.04 | **8151 / 4716 / 3938** | 61.76 / 46.09 / 36.28 |
| **lzav 5.17 -1 / -2** | 451 / 42.8 | 2527 / 2454 | 39.91 / 34.85 |
| lizard 2.1 -10 / -30 / -49 | 464 / 356 / 1.99 | 1911 / 1154 / 1058 | 48.79 / 40.45 / 28.63 |
| density 0.16.6 -1 / -3 | 1630 / 442 | 1617 / 578 | 62.77 / 43.56 |
| kanzi 2.5.3 -1 / -3 / -5 / -7 / -9 | 196 / 99 / 19.6 / 10.8 / 2.48 | 1112 / 338 / 53.2 / 15.8 / 2.44 | 37.44 / 30.40 / 25.49 / 22.32 / 19.73 |
| bsc 3.3.12 -m0 -e1 | 19.4 | 25.0 | 23.26 |
| lzham 1.0 -d26 -1 | 3.16 | 273 | 25.83 |
| misa77 0.6.0 -1 (new) | 73.8 | 7813 | 42.65 |
| skim 0.1.0 / memlz 0.5b (new) | 2313 / 4452 | 3500 / 2039 | 64.53 / 59.90 |

- lzbench now ships **openzl**, bzip3, fast-lzma2, zlib-ng, lzfse/lzvn and several new LZ codecs (zxc, misa77, skim, memlz, pulsar, wlz4), plus nvcomp/gpucompact for GPUs. — [lzbench README](https://github.com/inikep/lzbench)

**zxc (asymmetric LZ, built for decode speed)**
- On an **Apple M2** (lzbench 2.4.1, Clang 21, macOS 26, single thread, Silesia), the project reports: zxc 0.15.0 -1 decodes at 13,513 MB/s (61.76%), -3 at 9,707 MB/s (46.65%), -5 at 8,118 MB/s (40.83%), -6 at 6,884 MB/s (36.28%) and -7 at 5,054 MB/s (33.09%). Compression runs at 886 / 267 / 114 / 14.5 / 9.71 MB/s at those levels. On the same M2: lz4 1.10.0 4,774 MB/s (47.60%), lz4hc -9 4,522 MB/s (36.75%), lzav -1 3,876 MB/s (39.91%), zstd -1 1,803 MB/s (34.53%), zstd -3 1,680 MB/s (31.20%), zlib -1 378 MB/s. — [zxc README](https://github.com/hellobertrand/zxc)
- Format details: blocks are powers of two from 4 KB to 2 MB (default 512 KB), and levels 6-7 use Huffman-coded sections. There are hand-tuned NEON, AVX2 and AVX-512 paths. Contexts take ~1.79 MB to compress and ~1.0 MB to decompress at 512 KB blocks. A multi-threaded stream API is included. The format is specified in FORMAT.md and backed by conformance vectors, but **each format change is a clean break (v9 tools reject v8)**. License: **BSD-3-Clause**. — [zxc README](https://github.com/hellobertrand/zxc)
- The project claims >40% faster decompression than LZ4 on Apple Silicon, >25% on Graviton/Axion and >5% on x86. Benchmarks run in CI on every commit. These are the author's own figures. — [zxc GitHub](https://github.com/hellobertrand/zxc); [PyPI zxc-compress](https://pypi.org/project/zxc-compress)
- zxc is packaged in Debian sid (libzxc2) and the AUR. — [Debian](https://packages.debian.org/ru/sid/libzxc2)

**Meta OpenZL (Oct 2025)**
- Paper: "OpenZL: A Graph-Based Model for Compression", Collet, Terrell, Handte et al., arXiv 2510.03203 (v2, 30 Oct 2025). Compression is modeled as a DAG of modular codecs. Each compressed chunk embeds its resolved graph, so a single **universal decoder** decodes any configuration. SDDL (Simple Data Description Language) compiles a format description to bytecode that runs sandboxed and splits input into typed streams. An offline trainer (clustering, the ACE genetic graph composer, an ML selector) produces serialized compressors along the speed/ratio curve. — [arXiv 2510.03203v2](https://arxiv.org/html/2510.03203v2)
- Meta's numbers on the SAO dataset (Apple M1, clang-17): **OpenZL ratio 2.06, 340 MB/s compression, 1200 MB/s decompression**, against zstd -3 at 1.31 / 220 / 850 and xz -9 at 1.64 / 3.5 / 45. CSV parsing caps compression at ~64 MB/s. — [Meta Engineering blog](https://engineering.fb.com/2025/10/06/developer-tools/openzl-open-source-format-aware-compression-framework/)
- On unstructured data "it simply falls back to zstd". Text such as enwik or dickens gets essentially zstd's performance, and "when there is no structure, there is no advantage". — [Meta Engineering blog](https://engineering.fb.com/2025/10/06/developer-tools/openzl-open-source-format-aware-compression-framework/)
- License: **BSD**. Building needs C11 + C++17 and CMake ≥3.20. The API, format and codecs are "subject to (and will!) change". Frames from release-tagged versions are promised to stay decodable "for at least several years". — [facebook/openzl](https://github.com/facebook/openzl)
- Other coverage confirms that the Parquet datasets (Binance, TLC Green Trip) and ERA5 Flux are presented only as charts. — [InfoQ](https://www.infoq.com/news/2025/10/openzl-structured-compression)

**zstd 1.5.7 (2025)**
- The release has >500 commits. It speeds up small-block compression at level 1 (dictionary compression: 0 to +15%), improves `--patch-from`, makes **multithreading the CLI default**, gives slightly better ratios on large files, and adds a `--max` CLI option that trades time and memory for ratio. It also fixes a 32-bit bug in long-lived reused CCtx. — [zstd releases](https://github.com/meta/zstd/releases); [SUSE changelog](https://packagehub.suse.com/packages/zstd/1_5_7-160000_2_2/)

**High-ratio non-LZ codecs (LTCB enwik9, sizes in bytes)** — [LTCB](https://www.mattmahoney.net/dc/text.html)
- bsc 3.25 (-b1000 -e2): 163,884,462, compression 23 ns/B (~43 MB/s), decompression 8 ns/B (~125 MB/s), 5 GB memory. bsc-m03 0.4.0: 160,258,936.
- kanzi (TPAQX level): 161,690,495, ~490/480 ns/B, 3.1 GB.
- bzip3 (-b 511): 169,990,721, 175/146 ns/B, 3.7 GB.
- Reference points: xz 5.2.1 -9e: 197,331,816 (decompression 20 ns/B). zstd -22 --ultra (old 0.6.0 entry): 215,674,670.

**Apple system codecs (Compression.framework)**
- **LZMESH**: new in Apple OS **version 27**. Apple positions it as a replacement for LZFSE and zlib: LZ77 + length-limited Huffman + a lazy parser. Per Apple it compresses better than both, encodes faster and **decodes 3.5x faster than COMPRESSION_ZLIB on Apple silicon**. The decoder needs only 64 KB of scratch memory. Buffer API only. — [Apple docs: COMPRESSION_LZMESH](https://developer.apple.com/documentation/compression/compression_lzmesh.md)
- **LZBITMAP**: designed for SIMD, so encoder and decoder loops advance several symbols per vector op. It sits between LZ4 and LZMESH on the speed/ratio curve, with a ratio close to zlib at lower compression cost. Apple-only, buffer API only (no stream API). — [Apple docs: COMPRESSION_LZBITMAP](https://developer.apple.com/documentation/compression/compression_lzbitmap.md)
- LZRAVEN, a further algorithm, reportedly appeared in 26.4b1 as "Mammoth", was pulled, then reappeared in 27.0 (third-party wiki, low confidence). — [The Apple Wiki](https://theapplewiki.com/wiki/LZRAVEN)
- I found no independent LZBITMAP or LZMESH benchmarks. Apple's claims are qualitative except for the 3.5x figure. — [Apple docs](https://developer.apple.com/documentation/compression/compression_lzbitmap.md); [artandlogic 2017 (pre-LZBITMAP)](https://artandlogic.com/save-time-energy-libcompression/)

**Licenses of candidates** (from the repos)
- zxc BSD-3 ([repo](https://github.com/hellobertrand/zxc)). OpenZL BSD ([repo](https://github.com/facebook/openzl)). zstd BSD/GPLv2 dual ([repo](https://github.com/facebook/zstd)). lzbench lists lzav, kanzi, bsc, lzham, density, lizard and bzip3 as integrated, but it does not state their licenses ([lzbench](https://github.com/inikep/lzbench)). See Gaps.

### Inferences
- **zxc fills the "fast" slot better than LZ4 on Apple Silicon.** zxc -3 beats LZ4 at the same ratio (46.65% vs 47.60%) with ~2x the decode speed (9.7 vs 4.8 GB/s on M2). zxc -5/-6 beats lz4hc (36-41%) at 6.9-8.1 GB/s. zxc -7 (33.09%) out-compresses zstd -1 (34.53%) and decodes 2.8x faster (5.05 vs 1.8 GB/s), but compresses at only ~10 MB/s. That makes it a natural "compress once, extract many" profile (distribution DMGs, app bundles, asset packs). Even at 5-13 GB/s per core, decode exceeds any Mac internal SSD (2-6.3 GB/s per the prior report). The value is therefore lower CPU and energy per extraction, and near-instant in-memory or cached reads, more than wall-clock gains on cold disk reads.
- **Risk:** zxc's version-to-version format breaks are incompatible with a long-lived archive format. Xipper would have to vendor and freeze one wire version (e.g. v9) under its own codec id in XIZ, and own that decoder forever.
- **OpenZL:** worth tracking, not adopting for 2.x. Typical Mac archive contents (source trees, documents, app bundles, media) are mostly unstructured, so OpenZL ≈ zstd. Its format is unstable. It does make sense later as an optional per-frame codec for detected numeric/columnar files (CSV, Parquet, raw float arrays, scientific and genomic tables). Xipper's XIZ per-frame codec id already allows that.
- **Apple LZMESH/LZBITMAP:** zero vendoring cost and probably tuned for M-series. They are Apple-only, which is fine for XIZ and Apple Archive (Xipper is macOS-only), but they need OS 27+, so a fallback is required. They are buffer-only, which suits XIZ's independent 1-64 MiB frames. Benchmark locally before relying on Apple's claims.
- **High-ratio mode:** kanzi -7 (22.32% at ~11/16 MB/s) and bsc (23.3% at ~20-25 MB/s symmetric) beat xz -9 (23.01%, decode 122 MB/s) on ratio at similar compression speed. They decode 5-8x slower than xz, though. For text-heavy archives, a BWT codec (bsc or bzip3-style) is the only realistic "better than xz" option. Full kanzi -9 / CM is too slow at ~2.4 MB/s symmetric.
- Lizard, density, lzham and brotli-large-window bring nothing new: each is dominated by zstd/zxc/lz4 on Silesia at some point on the curve.

### Gaps
- The OpenZL paper's per-dataset tables (ERA5, Parquet, CSV) only survive as figures. I could not extract numbers beyond the SAO example.
- I could not verify licenses for lzav, kanzi, libbsc, lzham, density, lizard and bzip3 in this session. My understanding is lzav MIT, kanzi Apache-2.0, libbsc Apache-2.0, lzham MIT, bzip3 LGPL-3.0 (problematic for static MIT bundling), but this is unverified and must be checked in each repo's LICENSE.
- I found no Apple-Silicon lzbench data for kanzi, bsc, xz or brotli. M2 numbers exist only in zxc's README (an interested party).
- I did not research Brotli large-window or shared-dictionary updates, LZ4 long-range, or open Oodle-style codecs in depth. lzbench lists no Oodle (Kraken/Leviathan), so no open-licensed Oodle implementation appears to be integrated there.

## 2. Neural / LLM-based lossless compression: realistic speeds and archiver usability

### Takeaway
Neural compression now holds every top spot on enwik9 (~92 MB vs ~197 MB for xz), but it runs at **~4-9 KB/s on CPU** and ~1 MB/s with a high-end NVIDIA GPU. It needs 4-10+ GB of RAM and bit-exact deterministic inference on both ends. None of it is usable as a general archiver codec today, and I found no published Apple Neural Engine or Metal throughput numbers.

### Cited Findings
- **ts_zip (Bellard)** uses RWKV 169M v4, 8-bit weights, BF16 evaluation, a deterministic and reproducible design (independent of GPU/CPU/thread count) and 4 GB RAM. Speed is "up to 1 MB/s" compression and decompression on an RTX 4090. Results in bpb (xz vs ts_zip): enwik8 1.989 vs 1.106, enwik9 1.707 vs 1.084, book1 2.717 vs 1.431, linux-1.2.13.tar 1.441 vs 1.021. The download is binary-only with no license stated. — [ts_zip](https://bellard.org/ts_zip/)
- **LTCB (Oct 2026)**, enwik9: cmix-neif 1.0 (Oct 2026) 91,913,343 B at 175,392 ns/B (≈5.7 KB/s), 9.75 GB. ex-girlfriend 1.0 91,778,237 B at 220,071 ns/B. zmix 1.0 96,096,261 B at 131,364 ns/B (≈7.6 KB/s) on one Ryzen 9 5900X core. fx2-cmix-transformer 96,996,198 B. altxs 93,434,410 B on a GH100 GPU, 88 GB. tufazip v2 100,958,324 B on 2x B200 GPUs at 647,595 ns/B. nncp v3.2 (2023) 106,632,363 B at ~240,000 ns/B on an RTX 3090. cmix v21 (Sep 2024) 107,963,380 B at ~623,000 ns/B and 30.95 GB. jax-compress (Mar 2026) 113,393,442 B on a TPU v6e. — [LTCB](https://www.mattmahoney.net/dc/text.html)
- **DeepMind, "Language Modeling Is Compression" (ICLR 2024)**: Chinchilla 70B with arithmetic coding compresses ImageNet patches to 43.4% (PNG 58.5%) and LibriSpeech to 16.4% (FLAC 30.3%). Counting model size in the output makes large models far worse. Code is released, but Chinchilla's weights are not. — [arXiv 2309.10668](https://arxiv.org/pdf/2309.10668); [GitHub](https://github.com/google-deepmind/language_modeling_is_compression)
- The OpenZL paper notes that neural approaches run at roughly 1 KB/s, while zstd runs at ~100 MB/s compression and ~1 GB/s decompression. — [arXiv 2510.03203v2](https://arxiv.org/html/2510.03203v2)
- **llama-zip** uses any GGUF LLM as the arithmetic coder's model. It requires identical model and parameters (context, GPU layers, window overlap) at both ends and is "significantly slower" than traditional tools. No throughput numbers are published. — [llama-zip (sourcepulse)](https://www.sourcepulse.org/projects/1840241)
- My search turned up no published KB/s measurements of LLM-based compression on Apple Silicon (ANE, Metal or MLX). — search result summary; [starmorph Apple Silicon inference guide](https://blog.starmorph.com/blog/apple-silicon-llm-inference-optimization-guide) covers chat tok/s only.

### Inferences
- At 1 MB/s (ts_zip on a 4090, likely slower on an M-series GPU), a 1 GB folder takes ~17 min each way. CM-class codecs at 5 KB/s would take ~2 days. Determinism across ANE/GPU generations is also unproven. Apple does not guarantee bit-identical float results across chips, and a single mismatched probability corrupts the rest of the stream.
- The most a neural codec could be is an opt-in "experimental max text" mode for small text-only archives (<10-50 MB), with a pinned model shipped in the app (a 169M-parameter model at 8 bits ≈ 170 MB+ added to the DMG), and only if it is implemented with integer or fixed-point deterministic inference. Not recommended for 2.x/3.x.
- The fact that LLMs beat PNG and FLAC raw is not a practical route either: dedicated codecs (JPEG XL lossless, FLAC) remain orders of magnitude faster.

### Gaps
- No Apple Silicon (ANE/Metal/MLX) benchmarks for ts_zip, nncp or llama-zip.
- ts_zip's license is unclear (binary-only). nncp's license was not verified in this session.
- The top three LTCB ranks (above 91.78 MB) were not in the fetched portion of the page.

## 3. Advances in entropy coding, SIMD/parallel decoding and GPU/Apple-specific decoding

### Takeaway
Since the prior report, the new developments are SIMD-designed formats. **zxc** (NEON), Apple's **LZBITMAP** (vector-layout LZ) and **LZMESH** (LZ + length-limited Huffman, 64 KB decoder scratch) show that format layout designed for SIMD, not better entropy theory, drives decode gains on ARM. In 2026, **PivCo-Huffman** proposed a SIMD-friendly Huffman layout with selective ANS that claims higher decode throughput than state-of-the-art Huffman codecs. There are still no published Metal benchmarks for LZ or ANS decoding.

### Cited Findings
- **PivCo-Huffman** (Marcin Zukowski, arXiv 2606.05765, June 2026) uses a pivot-coded Huffman structure derived from wavelet trees, designed for SIMD encode and decode, with ANS applied selectively to skewed nodes. The author says it "consistently outperforms state-of-the-art Huffman codecs in decoding throughput", with ratios approaching ANS codecs. The full paper has NEON (Graviton) and x86 tables that I could not extract. No code link was found. — [arXiv 2606.05765](https://arxiv.org/abs/2606.05765)
- Interleaved rANS (Giesen) is branch-free in SIMD form, but the lack of fast SIMD gather limits it. Recoil notes that interleaving does not scale across cores without format support. — [arXiv 1402.3392](https://arxiv.org/pdf/1402.3392); [Recoil arXiv 2306.12141](https://arxiv.org/pdf/2306.12141)
- LZBITMAP arranges literal and match data so that encoder and decoder hot loops advance multiple symbols per vector op. — [Apple docs](https://developer.apple.com/documentation/compression/compression_lzbitmap.md)
- LZMESH uses length-limited Huffman, a lazy parser and a 64 KB decoder scratch, and decodes 3.5x faster than zlib on Apple silicon. — [Apple docs](https://developer.apple.com/documentation/compression/compression_lzmesh.md)
- zxc uses NEON paths and Huffman sections only at levels 6-7, and decodes at 5-13.5 GB/s on M2. — [zxc README](https://github.com/hellobertrand/zxc)
- OpenZL's universal decoder lets the compressor evolve (new graphs) without decoder changes. Its entropy backends choose between engines per stream. — [arXiv 2510.03203v2](https://arxiv.org/html/2510.03203v2)
- lzbench now includes GPU backends (nvcomp, gpucompact), CUDA only. Nothing is Metal-based. — [lzbench README](https://github.com/inikep/lzbench)

### Inferences
- On M-series, a per-core NEON decoder at 5-13 GB/s already exceeds SSD bandwidth, and Metal remains unjustified for the main extraction path. The prior report's conclusion stands, now with even faster CPU decoders.
- For a future XIZ "v2 entropy stage", Huffman with SIMD-friendly layout (PivCo-style, Huff0 4-stream) plus selective ANS is the direction 2026 research points to. That is research-grade work. Adopting zstd/zxc as-is is the practical path.

### Gaps
- PivCo-Huffman's actual GB/s numbers, its baselines and code availability.
- No published Metal (Apple GPU) LZ/ANS decoder benchmarks (still true, as in the prior report).
- No third-party LZBITMAP or LZMESH throughput numbers.

## 4. Ranking for Xipper: user-visible value on Apple Silicon

### Takeaway
In priority order: (1) **zxc** as a "fast-extract" XIZ codec (largest measurable Apple Silicon gain, BSD-3, but freeze the format version). (2) **Apple LZMESH/LZBITMAP** as an optional Apple-native fast mode on OS 27+ (zero vendoring, but not yet benchmarked). (3) **zstd 1.5.7 upgrade** with MT defaults and `--max`-style settings for "max" (cheap, safe). (4) A **BWT codec (libbsc, or kanzi BWT levels)** as a text-only "ultra" mode beating xz on ratio. (5) **OpenZL** only later, for structured/numeric files. (6) **Neural/CM**: no.

### Cited Findings
- zxc on M2: -3 at 9,707 MB/s vs LZ4 at 4,774 MB/s at ~47% ratio. zxc -7 at 33.09% / 5,054 MB/s vs zstd -1 at 34.53% / 1,803 MB/s. — [zxc README](https://github.com/hellobertrand/zxc)
- zstd keeps decode at ~1.1-1.35 GB/s at every level from -1 to -22 (EPYC). — [lzbench](https://github.com/inikep/lzbench)
- kanzi -7 22.32% and bsc 23.26%, vs xz -9 23.01% with decode at 122 MB/s. — [lzbench](https://github.com/inikep/lzbench)
- OpenZL gives 2.06 vs 1.31 (zstd -3) on structured SAO data, but zstd parity on text. — [Meta blog](https://engineering.fb.com/2025/10/06/developer-tools/openzl-open-source-format-aware-compression-framework/)
- Neural compressors run at ~5 KB/s on CPU, ~1 MB/s on an RTX 4090. — [LTCB](https://www.mattmahoney.net/dc/text.html); [ts_zip](https://bellard.org/ts_zip/)

### Inferences
- **Speed beats ratio for typical Mac users.** Most archive payloads are media and already-compressed files, where ratio gains are ~0 and dedup/store detection matter more (prior report). Decode speed and low CPU use show up on every extraction, while a ratio gain of 1-3% over zstd -19 rarely matters.
- **Suggested XIZ mode map:** fast = zxc -3..-5 (or LZ4 fallback); default = zstd 3-6; "fast-extract max" = zxc -7 / zstd -19; max = zstd -22 long / LZMA2; ultra-text = bsc (opt-in, slow decode).
- **Validation needed before adoption:** run a local lzbench on M-series covering zxc, lz4, lzav, zstd, kanzi, bsc and Apple LZMESH/LZBITMAP (via a small Compression.framework harness) over a representative Mac corpus (app bundles, source trees, Office docs, the genomic BAM).

### Gaps
- No independent verification of zxc's M2 numbers or of LZMESH's 3.5x claim. No M3/M4/M5 data.
- License verification for lzav, kanzi, libbsc, bzip3 (bzip3 possibly LGPL, to be avoided for static linking).
