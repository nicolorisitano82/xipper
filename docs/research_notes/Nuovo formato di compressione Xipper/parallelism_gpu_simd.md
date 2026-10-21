# Parallel and Hardware-Accelerated Compression/Decompression (for an Apple Silicon-optimized archive format)

Research date: 2026-10-21. Hardware is noted for each measurement. Results specific to Apple Silicon are marked **[APPLE]**.

## Q1. How do pigz, pbzip2/lbzip2, zstd MT (nbWorkers), pzstd, xz multi-block, BGZF and the zstd seekable format achieve parallelism, and what does it cost?

### Takeaway
Every production tool parallelizes **compression** the same way: cut the input into chunks and compress them on worker threads. They differ in whether chunks share history (a window or dictionary) with the previous chunk. Sharing (pigz default, zstd `nbWorkers`) keeps the ratio close to single-threaded but leaves **one dependent stream that can only be decoded serially**. Fully independent blocks with sizes recorded in headers or an index (pzstd, xz `-T`, BGZF, zstd seekable, Apple Archive) allow parallel **decompression** and random access, and cost some ratio, mostly at small block sizes. Measured decompression scaling for independent-block formats is far from linear at high core counts: pzstd gets 8.4x on 16 cores and only 10.9x on 128 cores.

### Cited Findings
**pigz (parallel gzip)**
- Splits input into **128 KiB** chunks (`-b` to change) and compresses them in parallel. Each chunk's check value is also computed in parallel and then combined. Each chunk ends with a Z_SYNC_FLUSH so byte-aligned partial streams can be concatenated, costing about 4-5 bytes per chunk. — [pigz man page](https://zlib.net/pigz/pigz.pdf)
- Blocks are compressed independently but are **primed with the last 32 KiB of the previous block as a preset dictionary** "to preserve the compression effectiveness". `-i/--independent` turns this off so blocks can be decompressed on their own, and marks block boundaries with a 9-byte empty-block sequence. — [pigz man page](https://zlib.net/pigz/pigz.pdf)
- "Decompression can't be parallelized" without specially prepared deflate streams. pigz decompresses on one thread and uses 3 extra threads for reading, writing and checksums. — [pigz man page](https://zlib.net/pigz/pigz.pdf)
- Measured on 2x AMD EPYC 7702: pigz decompression runs at about 270 MB/s and "never outperforms igzip" (416-656 MB/s single-threaded). — [Knespel & Brunst, rapidgzip, HPDC'23](https://arxiv.org/pdf/2308.08955)

**pbzip2 / lbzip2**
- bzip2 already uses independent blocks of about 900 kB. lbzip2 splits on about 900k blocks in both modes and can decompress **any** .bz2 file in parallel by scanning for block boundaries. Its own notes say splitting is "not guaranteed, just very likely (failure is detected)". The pbzip2 man page says its decompression speedup "depends on how file was created". — [lbzip2 man page](https://www.mankier.com/1/lbzip2); [pbzip2 man page](https://linuxcommandlibrary.com/man/pbzip2); [CNX Software](https://www.cnx-software.com/2016/12/16/compress-decompress-files-faster-with-lbzip2-multi-threaded-version-of-bzip2/)
- lbzip2 decompression on Silesia (EPYC 7702): 0.045 GB/s on 1 core, 0.667 GB/s on 16 cores, 4.1 GB/s on 128 cores, a speedup of about 91x. Ratio is 3.88, the best of the tools tested. — [rapidgzip Table 4](https://arxiv.org/pdf/2308.08955)

**zstd multithreading (`ZSTD_c_nbWorkers`, `jobSize`, `overlapLog`)**
- Multithreaded zstd splits input into jobs, or sections, each compressed by one worker. By default sections are **4x the window size**. "The larger they are, the (slightly) better the compression ratio, but also the higher the memory allocation cost". Job size has a minimum, and smaller requested jobs are resized up. — [zstd commit log (mirror)](https://git.sharpetronics.com/sharpetronics/zstd/commit/992c2370f65180aeb39d9fc52b4ad4c1061695ee); [zstdmt_compress.h](https://gitea.hak8or.com/mirrors/tracy/src/commit/27bf6c17efaa3e68ec33f2bc6fb48de8f4ab70c0/zstd/zstdmt_compress.h)
- `overlapLog` sets how much of the previous job's window each job reloads: 1/(2^(9-n)) of the window, where 9 is the full window and 1 is none. The default 6 means 1/8 of the window. Larger values give a better ratio and lower speed. — [zstd-safe CParameter docs](https://docs.rs/zstd-safe/7.2.4/zstd_safe/enum.CParameter.html); [zstd commit](https://git.sharpetronics.com/sharpetronics/zstd/commit/1993f5d412187fd58728043808ef075656b64012)
- The output is **still one frame**: the decoder "doesn't need to know" it was produced in parallel, and output is "typically a little larger". — [Mercurial dev list, 2017](https://www.mercurial-scm.org/pipermail/mercurial-devel/2017-April/096047.html)
- Because `zstd` (including `-T`) writes a single frame, pzstd cannot parallelize its decompression. On 16 cores, pzstd decompressing a zstd-made file reaches 0.88 GB/s, versus 0.82 GB/s for single-core zstd. — [rapidgzip §4.9 / Table 4](https://arxiv.org/pdf/2308.08955)

**pzstd**
- Splits input into equal-sized chunks, compresses each into an independent zstd frame, and puts a small **skippable-frame header** before each frame recording where the next one starts. It can only parallelize decompression of files it created itself. — [pzstd README](https://cdn.jsdelivr.net/npm/cppzst@2.0.12/deps/zstd/contrib/pzstd/README.md)
- Silesia decompression on EPYC 7702: 1 core 0.81 GB/s, 16 cores 6.78 GB/s (8.4x), 128 cores 8.8 GB/s (10.9x). Disabling checksums (`--no-check`) did not help. Ratio is 3.17 versus 3.18 for single-frame zstd, so the independent-chunk ratio cost at default chunk size is about 0.3%. — [rapidgzip Table 4](https://arxiv.org/pdf/2308.08955)

**xz / liblzma multi-block**
- `-T` splits input into blocks that are compressed **independently**. The default block size is **3x the LZMA2 dictionary size, minimum 1 MiB**, and 2-4x the dictionary is recommended. Each thread buffers about 3x the block size, so memory is about 3x3xDictSize per thread plus the coder memory. For example, 4 threads at `-6` need 660-670 MiB. — [xz(1) man page](https://tukaani.org/xz/man/xz.1.html)
- Single-threaded mode produces the smallest files but stores no block sizes, so only multithreaded output, which **records compressed and uncompressed sizes in block headers**, can be decompressed by multiple threads. Threaded decompression scales down under `--memlimit-mt-decompress` rather than failing. — [xz(1) man page](https://tukaani.org/xz/man/xz.1.html)

**BGZF (bgzip, htslib)**
- BGZF is a series of concatenated, standards-compliant gzip members, each holding **at most 64 KiB uncompressed**. A gzip extra subfield `BC` stores BSIZE, the compressed block length. Random access uses 64-bit **virtual offsets** (`coffset<<16 | uoffset`): 48 bits address the compressed block start and 16 bits the position inside the decompressed block. A separate `.gzi` index maps compressed to uncompressed offsets. — [bgzip man page (htslib)](https://www.htslib.org/doc/1.9/bgzip.html); [Biopython bgzf](https://mitra.stanford.edu/kundaje/marinovg/oak/various/programs/biopython-1.77/Bio/bgzf.py)
- Silesia measurements (EPYC 7702): bgzip ratio 2.99 versus 3.11 for gzip -6, a **~4% ratio cost from 64 KiB independent blocks**. Decompression runs at 0.30 GB/s on 1 core, 2.82 GB/s on 16 cores (9.5x) and 5.5 GB/s on 128 cores. — [rapidgzip Table 4](https://arxiv.org/pdf/2308.08955)

**zstd seekable format**
- Data is cut into independently compressed zstd frames, followed by a **seek table stored in a skippable frame** (magic `0x184D2A5E`). The table has one entry per frame: Compressed_Size (u32), Decompressed_Size (u32), and an optional XXH64 low-32 checksum. A 9-byte footer holds Number_Of_Frames, a descriptor byte and the magic `0x8F92EAB1`, which must be the last bytes of the file. Standard zstd decoders skip the table. — [Seekable format spec](https://raw.githubusercontent.com/facebook/zstd/dev/contrib/seekable_format/zstd_seekable_compression_format.md)
- Guidance: small frames make small random reads cheaper but lower the ratio and enlarge the jump table. Frames "below a few KiB" can hurt the ratio notably, and the frame size should roughly match the access pattern. The Rust implementation zeekstd starts a new frame every **2 MiB** of uncompressed data by default. — [zstd seekable README](https://github.com/facebook/zstd/blob/dev/contrib/seekable_format/README.md); [zeekstd docs](https://docs.rs/crate/zeekstd/latest)

**zstd frame/block semantics (RFC 8878)**
- "Each frame is independent and can be decompressed independently of other frames". Blocks inside a frame are **dependent**: they can reference prior output within Window_Size, the repeat offsets, the previous Huffman tree (treeless literals) and the previous FSE tables (Repeat_Mode). Block_Maximum_Size is 128 KB. Skippable frames use magics `0x184D2A50`-`0x184D2A5F`. Decoders should support windows of at least 8 MB. The content checksum is the low 32 bits of XXH64. — [RFC 8878](https://www.rfc-editor.org/rfc/rfc8878.html)

**Apple Archive / AppleArchive framework** **[APPLE]**
- `ArchiveByteStream.compressionStream(using:writingTo:blockSize:flags:threadCount:)` defaults to **blockSize = 1 MiB** (`1<<20`) and `threadCount = 0` (the default worker count). This is Apple's own block-parallel container design. — [Apple developer docs](https://developer.apple.com/documentation/applearchive/archivebytestream/compressionstream(using:writingto:blocksize:flags:threadcount:).md)
- Apple Archive / `yaa` is multithreaded, defaults to LZFSE, has no level setting, and gets a better ratio with a larger block size. — [Eclectic Light, "Inside Apple Archive"](https://eclecticlight.co/2022/05/10/inside-apple-archive-more-than-a-compression-format/)
- LZFSE switches to LZVN for inputs under 4096 bytes. — [Wikipedia: LZFSE](https://en.wikipedia.org/wiki/LZFSE)

### Inferences
- The ratio cost of independent blocks is small at MiB scale (pzstd about 0.3% versus single-frame zstd) and grows at small blocks (BGZF 64 KiB about 4% versus gzip -6, within a 32 KiB-window codec). For zstd or LZMA with large windows, the penalty depends on block size relative to window size. xz's guidance of block = 2-4x the dictionary reflects this.
- To get both parallel decompression and good ratio, use **two levels**. Independent "frames" of about 1-8 MiB are the unit of parallelism, recorded in a seek index. Inside each frame, a normal dependent block stream. A shared, trained dictionary can be referenced by all frames to recover ratio on small frames; RFC 8878 Dictionary_ID provides the hook.
- pzstd stops scaling past about 16 cores even with independent frames. A scalable decoder needs work-stealing, output ordering that does not serialize, and an index read up front, not a skippable header scanned in sequence.
- For Apple Silicon heterogeneity (P-cores plus E-cores), many small frames (much more than the core count) give better load balance than equal static splits. This needs measurement; see Gaps.

### Gaps
- No current (2024-2026) published curve of zstd `-T` compression throughput versus thread count, or of ratio versus jobSize, was found. Primary sources give only qualitative statements ("slightly better", "typically a little larger"). A benchmark should be run locally (`zstd -b -T#`, `--zstd=jobsize=,overlapLog=`) on M-series hardware.
- No Apple Silicon measurements were found for pigz, pzstd, xz -T or rapidgzip scaling.
- No primary block-size versus ratio curve was found for xz or zstd seekable. The Apple Archive on-disk block layout is not publicly documented.

## Q2. Why is single-stream LZ decompression sequential, and what enables parallel decompression?

### Takeaway
LZ77 back-references copy from earlier decoded output (up to 32 KiB back for Deflate, up to the window size for zstd), and Huffman/FSE bitstreams have no symbol boundaries a decoder can find without decoding. A thread therefore cannot start mid-stream without both the bit position and the preceding window. Parallel decompression needs either independent blocks plus an index (pzstd, BGZF, xz MT, zstd seekable), or speculative decoding with a block finder and two-pass marker resolution (pugz, rapidgzip). The second approach is bounded by a serial window-propagation step, and an index removes it.

### Cited Findings
- A zstd frame's compressed blocks depend on prior output within the window, repeat offsets, and previous Huffman/FSE tables. Only frames are independent. — [RFC 8878](https://www.rfc-editor.org/rfc/rfc8878.html)
- pugz showed that a thread can decompress from the middle of a Deflate stream by writing **marker symbols** for references into the unknown 32 KiB window. It requires output bytes in 9-126 (ASCII text), and does not handle arbitrary gzip. — [Knespel & Brunst, rapidgzip, HPDC'23](https://arxiv.org/pdf/2308.08955)
- rapidgzip (Knespel & Brunst, TU Dresden, HPDC 2023) generalizes this to arbitrary data. A fast **block finder** locates candidate Deflate block starts, speculative decoding with trial-and-error rejects false positives, and window propagation is followed by parallel marker replacement. Marker replacement is about 10x faster than Deflate decoding, but "the propagation of the windows cannot be parallelized", so speedup is Amdahl-bounded by chunk size. With 4 MiB chunks the serial part is half the time at 128 cores. — [rapidgzip paper](https://arxiv.org/pdf/2308.08955)
- rapidgzip numbers (2x AMD EPYC 7702, 2x64 cores, SMT). Base64 random data: **8.7 GB/s on 128 cores, 55x GNU gzip (157 MB/s), 21x igzip (416 MB/s)**; **17.8 GB/s with an index**. Silesia: 5.6 GB/s without an index (33x), **16.3 GB/s with an index (95x)**. The Silesia case stops scaling at about 64 cores because of more back-references. The default compressed chunk is **4 MiB** (pugz needs 32 MiB). Memory is about 8 MiB per thread with an index, and up to 80 MiB per thread otherwise. File reading becomes a bottleneck above about 18 GB/s. — [rapidgzip paper](https://arxiv.org/pdf/2308.08955)
- At 128 cores, rapidgzip with an index (16.4 GB/s) is **about 2x pzstd** (8.8 GB/s) on Silesia. — [rapidgzip Table 4](https://arxiv.org/pdf/2308.08955)
- The compressor's choices matter. igzip -0 puts everything in a single Dynamic Block, so rapidgzip falls to 0.16 GB/s (effectively serial). pigz output decodes slower (about 3.8 GB/s) than gzip output (about 5.0-6.0 GB/s) because block-size choices change the Huffman-header amortization and block-finder overhead. — [rapidgzip Table 3](https://arxiv.org/pdf/2308.08955)
- A later project README reports up to **24 GB/s with an index and 12 GB/s without** on Silesia, on the same 2x64-core EPYC 7702, using a newer version. These are project-reported and not peer-reviewed. — [rapidgzip GitHub](https://github.com/mxmlnkn/rapidgzip)

### Inferences
- A new format should never require speculative decoding. It should store an **explicit block index** (offsets and sizes, compressed and uncompressed) in a footer, as the zstd seekable footer and the BGZF/GZI index do. rapidgzip's 2-3x gain from an index is a direct measure of what the index is worth.
- Avoid putting format-level information that every block needs in sequential headers that must be scanned. pzstd's skippable-frame-per-chunk scan is one likely reason for its poor scaling (inference).
- Put a checksum per block in the index so verification can run in parallel and independently, as the zstd seekable entry checksum does.

### Gaps
- No primary scaling data for parallel decompression on Apple Silicon (P-plus-E-core heterogeneity, at most 24P+8E on M3 Ultra) was found.

## Q3. GPU compression: nvCOMP, Gompresso, DietGPU, GPU ANS, Apple Metal. When do GPUs beat CPUs, and what do transfers cost compared with unified memory?

### Takeaway
GPUs reach hundreds of GB/s **only for entropy-only or GPU-designed formats with many small independent segments** (DietGPU ANS 250-600 GB/s, Bitcomp about 460 GB/s), or with fixed-function hardware (Blackwell Decompression Engine, up to 600 GB/s for LZ4/Snappy/Deflate). General LZ77 decode on GPUs is limited by serial parse and dependency chains, and formats have to be changed to remove dependencies, at a ratio cost of 0.5-19%. Discrete-GPU results were historically **PCIe-bound** (13 GB/s measured on PCIe 3). On Apple Silicon unified memory removes the copy but not coherence costs. No published Metal LZ or ANS codec benchmark was found.

### Cited Findings
**Gompresso (Sitaridi, Mueller, Kaldewey, Lohman, Ross; ICPP 2016)**
- Hardware: NVIDIA Tesla K40, PCIe 3.0 x16 (13 GB/s measured, 16 nominal), compared with 2x Intel E5-2620 v2 (12 cores, 24 threads). Default block 256 KB, 8 KB window, 10-bit maximum Huffman codeword. CPU libraries were tested with 2 MB blocks. — [Gompresso paper](https://ar5iv.labs.arxiv.org/html/1606.00519)
- Two techniques: Multi-Round Resolution (MRR) of back-references at decode time, and **Dependency Elimination (DE)** at compression time, which forbids nested back-references. DE costs **up to 19% ratio** and up to 13% compression speed. The conclusion states "no more than 10%", an internal inconsistency. Gompresso/Bit loses about 9% ratio from length-limited Huffman. — [Gompresso paper](https://ar5iv.labs.arxiv.org/html/1606.00519)
- Results: Gompresso/Bit is about 2x faster than block-parallel zlib on the 24-thread CPU, with 17% less energy. Gompresso/Byte is about 1.35x faster than LZ4 and **was PCIe-bound**. — [Gompresso paper](https://ar5iv.labs.arxiv.org/html/1606.00519); [IBM Research](https://research.ibm.com/publications/massively-parallel-lossless-data-decompression)

**DietGPU (Meta / Facebook Research)**
- A GPU-native rANS entropy coder plus a float codec. The basic unit is a **4 KiB segment assigned to one warp**, and each array in a batch has its own statistics and is independently decodable. Everything runs on the device with no CPU involvement. — [DietGPU GitHub](https://github.com/facebookresearch/dietgpu)
- Throughput on A100: ANS about **250-410 GB/s**, float codec about 250-600 GB/s. It is not worth using below about 512 KiB of data. Higher entropy input lowers throughput. — [DietGPU GitHub](https://github.com/facebookresearch/dietgpu)
- Third-party measurement on H100: DietGPU ANS encode 364.9 GB/s, **decode 592.5 GB/s**. This is from an arXiv preprint and should be treated as secondary. — [arXiv 2606.18900](https://arxiv.org/pdf/2606.18900)

**GPU ANS research**
- "Massively Parallel ANS Decoding on GPUs" (ICPP 2019, the "multians" decoder by Weißenberger & Schmidt) targets the bottleneck where GPU APIs rely on CPU preprocessing for decoding. **Its GB/s figures could not be retrieved.** — [catalog listing](https://fitforthem.unipa.it/subject:Entropy%20encoding)
- Recoil (Lin et al., ICPP 2023). Hardware: Xeon W-3245 (16 cores) and RTX 2080 Ti. Max decode is about **11+ GB/s on CPU** and **90+ GB/s on GPU** for both Recoil and conventional partitioned rANS, and both "significantly outperformed" multians. Partitioning into 2,176 independent streams for the GPU costs **+0.03% (enwik9) up to +23.5% (random small-alphabet data)** in size, against at most +0.14% with 16 partitions for the CPU. Recoil instead stores split metadata so a single encode can be decoded at any parallelism. — [Recoil, arXiv 2306.12141](https://arxiv.org/html/2306.12141v3)

**nvCOMP (NVIDIA)**
- Blackwell (B200/B300/GB200/GB300) adds a fixed-function **Decompression Engine (DE)** for Snappy, LZ4, Deflate and GZip, at up to **600 GB/s**. **Zstd is not DE-accelerated.** — [nvCOMP Decompression Engine FAQ](https://docs.nvidia.com/cuda/nvcomp/decompression_engine_faq.html); [nvCOMP product page](https://developer.nvidia.com/nvcomp)
- Independent B200 microbenchmark: LZ4 output about 172 GB/s (random data) to 220 GB/s (repetitive), Bitcomp 462.4 GB/s. — [arXiv 2512.02189](https://arxiv.org/pdf/2512.02189)
- nvCOMP 5.0 release notes claim up to 12x decompression speedup from the batched high-throughput interface. — [nvCOMP release notes](https://docs.nvidia.com/cuda/nvcomp/release_notes.html)
- Earlier figures: LZ4 decompression about 60-69 GB/s (GPU not stated in the source) and nvCOMP DEFLATE about 50 GB/s on A100 (cited second-hand). — [nvCOMP GTC slides](https://reprises.in2p3.fr/ressource/Presentation/CWE41740_Slide_Deck_1648076975326001TKn2.pdf); [arXiv 2606.18900](https://arxiv.org/pdf/2606.18900)

**What limits GPU LZ77 decoding (2026 preprint, single author, not peer-reviewed)**
- On H100, across three GPU LZ77 decoders, **parsing (not copying) takes 64-72% of decode time**. Median match length is 7 bytes against a 128-byte cache line, giving 4.4% bus efficiency. An encoder-side change (dropping the 4-entry repeat-offset history) costs 0.54% ratio and grows the dependency-free parse run from 4 to 706 commands. — [Shavidze, arXiv 2608.10188](https://arxiv.org/abs/2608.10188)

**Apple Silicon unified memory and Metal** **[APPLE]**
- TUM study (DaMoN '26) on an M4 Pro (10P+4E, 20 GPU cores, LPDDR5X-8533, 273 GB/s theoretical) and an M3 Ultra (24P+8E, 80 GPU cores, 819.2 GB/s theoretical). M4 Pro measured GPU 248 GB/s, CPU (all cores) 251 GB/s, single core 52 GB/s. M3 Ultra measured **GPU 738 GB/s (90%)** but **CPU only 253 GB/s (30%)**, single core 43 GB/s. The authors attribute this to a CPU-side interconnect limit, and conclude that for memory-bound work on the M3 Ultra the GPU is the better unit. — [Beischl et al., "Evaluating Apple Silicon for Data Processing", DaMoN 2026](https://db.in.tum.de/~beischl/papers/Evaluating_Apple_Silicon_for_Data_Processing.pdf)
- Unified memory "eliminates explicit data copies" but **Metal shared-buffer allocation triggers wiring (10-60 GB/s) and a full coherence pass (70-120 GB/s on M4 Pro) at kernel launch for every new buffer**. Example: a 16 GB buffer took 1160 ms to wire and 140 ms for coherence. Allocating one large region once and managing it explicitly cut per-run coherence to under 0.06 ms. Metal also frees memory lazily. — [Beischl et al., DaMoN 2026](https://db.in.tum.de/~beischl/papers/Evaluating_Apple_Silicon_for_Data_Processing.pdf)
- A community project reports shared-mode Metal buffers are slower for GPU compute than GPU-private buffers because of coherence overhead. This is anecdotal. — [ethresear.ch WHIR on Metal](https://ethresear.ch/t/gpu-accelerated-whir-proving-on-apple-silicon/24762)
- Apple's GPU lossless/lossy **texture** compression (A15/M2 onward) is transparent and undocumented, and not usable as a general data codec. — [Ludicon blog](https://www.ludicon.com/castano/blog/?p=1790)

### Inferences
- On Apple Silicon, there is no PCIe tax, so the Gompresso-era transfer bottleneck disappears. But a single M-series CPU core manages about 43-52 GB/s of memory traffic, and real LZ decoders run at about 1-5 GB/s per core. **A multi-core CPU decoder is compute-bound well below memory bandwidth**, so a GPU entropy stage could help mainly on Max/Ultra parts, where the GPU has about 3x the CPU's usable bandwidth (M3 Ultra).
- If GPU decode is a goal, the format should keep **entropy-coded streams in many independent sub-streams** (DietGPU uses 4 KiB per warp) or store Recoil-style split metadata, and keep LZ dependency chains short or optional. This costs ratio, from about 0.03% on text to over 20% on adversarial data, so make it a per-archive or per-block profile, not mandatory.
- Any Metal path must use long-lived, pre-wired shared buffers (or `MTLHeap`) reused across blocks, to avoid the per-allocation wiring and coherence costs measured by TUM.
- For an archive tool (read file, compress, write), CPU NEON codecs on 10-24 P-cores likely saturate NVMe before the GPU is needed. GPU offload looks most worthwhile for very fast decode-to-memory of large archives on Max/Ultra machines. This is an inference and has not been measured.

### Gaps
- No published Metal implementation or benchmark of LZ4, zstd, Deflate or ANS on Apple GPUs was found. Apple's Compression framework exposes CPU codecs only, per the sources found.
- Throughput numbers for Weißenberger & Schmidt's multians (ICPP 2019) could not be retrieved; the full paper is behind ACM.
- No authoritative per-algorithm nvCOMP GB/s table for A100/H100 is in the public docs. The figures above are from mixed sources and mixed GPUs.

## Q4. SIMD/NEON acceleration: hashing, matching, entropy decoding, and checksums at memory bandwidth

### Takeaway
Integrity checks are not a bottleneck on Apple Silicon if chosen well. CRC32 with PMULL+EOR3 reaches **about 85 GB/s on one M1 core**, and XXH3 runs above RAM bandwidth with SIMD. A cryptographic hash is the expensive part: BLAKE3 is about 1.1 GB/s single-threaded on an M1 via Python bindings, and its Merkle-tree design lets it scale across threads and SIMD lanes. A per-block checksum design parallelizes naturally.

### Cited Findings
- **CRC32 on Apple M1 (single core)** **[APPLE]**: scalar `crc32x` instruction 25.5 GB/s; PMULL-only folding 77.7 GB/s; **best mix (9 PMULL+EOR3 lanes interleaved with 6 scalar crc32x lanes) 85.05 GB/s**. On Ampere Altra (no EOR3) the best is 35.9 GB/s. — [corsix/fast-crc32](https://github.com/corsix/fast-crc32)
- zlib-ng ships an ARMv8 PMULL+EOR3 CRC32 path (9 PMULL lanes, 192 bytes per iteration) based on Cawley's work. — [zlib-ng source](https://fuchsia.googlesource.com/third_party/github.com/zlib-ng/zlib-ng/+/9babb290290b6cf5810f6e7e54d8e120aa9b6727/arch/arm/crc32_armv8_pmull_eor3.c)
- Linux arm64: a 4-way PMULL CRC32 gives 2-2.8x on **Apple M2** for 1-8 KiB inputs. A 12-wide PMULL version with EOR3 beats 4-way on Apple M1, but did not on non-Apple cores tested. — [LKML patch v4](https://lkml.rescloud.iu.edu/2410.2/03982.html); [LKML discussion (Biggers)](https://lkml.iu.edu/hypermail/linux/kernel/2410.2/01208.html)
- **XXH3** (i7-9700K, clang 10): AVX2 59.4 GB/s, SSE2 31.5 GB/s, versus memcpy from RAM at 28.0 GB/s. XXH64 runs at 19.4 GB/s, XXH32 at 9.7 GB/s, BLAKE2 at 1.1 GB/s. Speeds above RAM are possible only for in-cache data. The README has no NEON or Apple numbers. — [xxHash README](https://github.com/Cyan4973/xxHash)
- **BLAKE3** is "highly parallelizable across any number of threads and SIMD lanes, because it's a Merkle tree on the inside", which also enables verified streaming. It has NEON implementations in the Rust and C versions, multithreading via Rayon, and `b3sum` multithreads by default. — [BLAKE3 README](https://raw.githubusercontent.com/BLAKE3-team/BLAKE3/master/README.md)
- BLAKE3 on Apple M1 (16 MiB buffer, Python bindings) **[APPLE]**: about 1,119 MiB/s single-threaded and about 2,779 MiB/s with automatic threads (about 2.5x). blake2b runs at about 605 MiB/s. This is an indicative third-party figure. — [blake3 Python benchmark via search result](https://pkg.go.dev/goforge.dev/blake3sum)
- The zstd frame checksum is XXH64 (low 32 bits), and seekable entries can carry a per-frame XXH64 checksum. — [RFC 8878](https://www.rfc-editor.org/rfc/rfc8878.html); [Seekable spec](https://raw.githubusercontent.com/facebook/zstd/dev/contrib/seekable_format/zstd_seekable_compression_format.md)
- zstd's man page puts fast modes at over 200 MB/s per core for compression and over 500 MB/s per core for decompression (general rule, no specific hardware). pzstd and zstd decompress Silesia at about 0.82 GB/s on one EPYC 7702 core, and lz4 at 1.34 GB/s. — [zstd man page](https://man.archlinux.org/man/zstd.1.en.raw); [rapidgzip Table 4](https://arxiv.org/pdf/2308.08955)

### Inferences
- For per-block integrity, CRC32C (PMULL) or XXH3 cost a small fraction of decompression time. A whole-archive cryptographic digest (BLAKE3) should be computed as a tree over block hashes so it parallelizes with the blocks. BLAKE3's 1 KiB-chunk Merkle structure makes it a natural fit, and its tree layout can line up with archive block boundaries (inference).
- Combined CRCs (pigz computes per-chunk check values in parallel and combines them) are an alternative when a single whole-stream CRC is needed for compatibility.

### Gaps
- No primary measurements were found of NEON-specific LZ match-finding or Huffman/FSE decoding speedups (zstd, libdeflate, LZ4) on M-series, and no official XXH3 NEON or BLAKE3 NEON GB/s figures on M-series (xxhash.com benchmarks were not retrieved).
- No measured data was found on how the M-series P-core versus E-core split affects compression throughput.

## Q5. I/O: keeping NVMe SSDs saturated, and pipeline design with back-pressure

### Takeaway
Apple internal SSDs deliver about 2-7 GB/s sequential depending on the model, below the CPU and GPU memory bandwidth and below the aggregate throughput of a parallel decoder (rapidgzip already hits file-read limits at about 18 GB/s on EPYC). Parallel decompression with a block index will often be **I/O-bound on Mac**. Parallel compression at high levels (xz, zstd-19) will be CPU-bound. The pipeline should use bounded queues of independent blocks with per-block ordering by index.

### Cited Findings
- Blackmagic test: **M5 MacBook Pro SSD up to 6,323 MB/s read versus 2,031 MB/s on an M4 MacBook Pro** (M4 configuration unspecified). Apple routes x4 PCIe lanes to the SSD on base chips and x8 on Pro/Max/Ultra. **[APPLE]** — [TechSpot](https://www.techspot.com/community/topics/early-tests-show-the-m5-macbook-pros-ssd-is-about-2-5x-faster-than-the-m4.295221/); [Low End Mac M4 Max specs](https://lowendmac.com/1234/apple-silicon-m4-max-chip-specs/)
- M1 Mac mini file reads: median 2.9 GB/s over files of 10 KB to 2 GB, with cache effects excluded. **[APPLE]** — [Eclectic Light](https://eclecticlight.co/2020/12/28/internal-ssds-can-read-files-at-extreme-speed/)
- rapidgzip's file-read path reaches about **18 GB/s with 4 or more threads** and becomes the bottleneck above 128 cores. Parallel, multi-threaded reads are needed to reach peak storage bandwidth. — [rapidgzip paper](https://arxiv.org/pdf/2308.08955)
- pigz uses separate threads for reading, writing and checksumming even when decompression is serial. — [pigz man page](https://zlib.net/pigz/pigz.pdf)
- xz threaded mode bounds memory per thread (about 3x block size buffering) and reduces the thread count to stay within memory limits, a built-in form of back-pressure. — [xz(1) man page](https://tukaani.org/xz/man/xz.1.html)
- rapidgzip's memory scales with parallelism times chunk size times ratio, and it caps the decompressed chunk size to bound memory (8 MiB per thread with an index). — [rapidgzip paper](https://arxiv.org/pdf/2308.08955)

### Inferences
- Pipeline sketch: reader threads issue large (≥1-8 MiB), aligned, concurrent reads, then a **bounded MPMC queue** of blocks feeds the compressor workers (P-cores first, E-cores for background or checksum work). An encrypt stage per block, using an AEAD with a per-block nonce derived from the block index, preserves independence. A reorder buffer bounded to N in-flight blocks then feeds the writer. Back-pressure comes from bounded queue capacity and an in-flight memory budget, as in xz's memlimit approach.
- Because SSD throughput (about 2-7 GB/s) is below the CPU decode capacity of 10+ P-cores on fast codecs, the decompression path should favour **fewer, larger reads and zero-copy into decode buffers** (mmap or pre-wired buffers) over more threads.

### Gaps
- No controlled measurements were found of queue depth, `F_NOCACHE`/`F_RDAHEAD`, or concurrent-read scaling on Apple internal SSDs, nor M4 Max or M3 Ultra-specific SSD numbers from a primary source. These need local benchmarks (fio-style).
- No published pipeline designs specific to an archive tool with encryption on macOS were found.
