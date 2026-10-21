# Archive container design: deduplication, solid vs non-solid layout, random access and indexing

Research date: 2026-10-21. Every item under "Cited Findings" comes from a source fetched in this session. Items marked "(background knowledge, not verified this session)" come from prior knowledge and appear only under Inferences or Gaps.

## 1. Content-defined chunking (CDC) and deduplication

### Takeaway
Gear-based CDC (FastCDC) is the current default. It is about 10x faster than Rabin CDC and about 3x faster than earlier Gear/AE CDC, with nearly the same dedup ratio. The 2020 TPDS version adds "rolling two bytes" and reports a 3–12x speedup over prior CDC. Real tools use very different average chunk sizes: 64 KiB in casync, 1 MiB in restic, 2 MiB in borg, and under 8 MiB in bupstash. Whole-file dedup alone captures most of the benefit: about 75% of block-level savings on live filesystems and 87% on backup images.

### Cited Findings
- FastCDC (Xia et al., USENIX ATC 2016) is "about 10x faster than the best of open-source Rabin-based CDC" and "about 3x faster than the state-of-the-art Gear- and AE-based CDC", with "nearly the same deduplication ratio as the classic Rabin-based approach." — [USENIX ATC'16 FastCDC](https://www.usenix.org/conference/atc16/technical-sessions/presentation/xia)
- FastCDC has three techniques — [USENIX ATC'16 FastCDC](https://www.usenix.org/conference/atc16/technical-sessions/presentation/xia):
  - a simplified and enhanced Gear hash judgment;
  - cut-point skipping below the minimum chunk size, which is faster but lowers the dedup ratio;
  - chunk-size normalization into a narrow region, which recovers the lost dedup ratio.
- The 2020 journal version ("The Design of Fast Content-Defined Chunking for Data Deduplication Based Storage Systems", IEEE TPDS 31(9):2017–2031) adds rolling two bytes per iteration. It reports being "3-12X faster than the state-of-the-art CDC approaches" with nearly the same or higher dedup ratio than Rabin CDC. The Rust `fastcdc` crate implements both the 2016 and 2020 variants. — [TPDS 2020 PDF](https://ranger.uta.edu/~jiang/publication/Journals/2020/2020-IEEE-TPDS(Wen%20Xia).pdf); [HIT Scholar record](https://scholar.hit.edu.cn/en/publications/the-design-of-fast-content-defined-chunking-for-data-deduplicatio/); [docs.rs fastcdc](https://docs.rs/crate/fastcdc/latest)
- **restic** — [restic design reference](https://restic.readthedocs.io/en/stable/100_references.html):
  - Chunking: Rabin fingerprints over a 64-byte sliding window. Files under 512 KiB are not split. Blobs are 512 KiB–8 MiB, with a target average of 1 MiB. The irreducible polynomial is chosen at random per repository at `init`.
  - Pack files: `EncryptedBlob1..N || EncryptedHeader || Header_Length (4-byte LE)`. The header is at the end so packs can be streamed without rewriting.
  - Indexes: separate encrypted JSON index files, each under 8 MiB, with `supersedes` for repacking.
  - Compression: zstd, from repository format v2.
- **borg** — [Borg internals: data structures](https://borgbackup.readthedocs.io/en/stable/internals/data-structures.html):
  - Chunking: Buzhash with defaults CHUNK_MIN_EXP=19 (512 KiB), CHUNK_MAX_EXP=23 (8 MiB), HASH_MASK_BITS=21 (about 2 MiB target average), HASH_WINDOW_SIZE=4095. The buzhash table is XORed with a per-repository secret `chunk_seed` to prevent chunk-size fingerprinting.
  - Chunk IDs: a keyed MAC or strong hash (`id_key`).
  - Item metadata: msgpack items, chunked separately with a finer chunker of about 128 KiB.
  - Limits: the archive object is capped at MAX_OBJECT_SIZE = 20 MiB.
  - Files cache: (inode, size, mtime_ns) skips unchanged files.
- **casync** — [casync announcement (Poettering)](https://0pointer.net/blog/casync-a-tool-for-distributing-file-system-images.html):
  - Chunking: buzhash, default average chunk size 64 KiB, tunable with `--chunk-size`. Smaller chunks give better sharing but more files and HTTP requests.
  - Storage: chunks are named by SHA-256 and compressed with xz.
  - Indexes: `.caidx`/`.caibx` are a linear list of (chunk hash, size).
- **bupstash** — [bupstash technical overview](https://raw.githubusercontent.com/andrewchambers/bupstash/master/doc/technical_overview.md):
  - Chunking: gear rolling hash over a 32-byte window, chunks smaller than 8 MiB.
  - Addressing: keyed BLAKE3 chunk addresses.
  - Structure: a Merkle "HTree" whose non-leaf nodes store child addresses plus chunk counts, which enables random access.
  - Index: an optional separate content index (also an HTree) lets clients list files and fetch partial data without downloading the data stream.
- **Measured dedup gains**: Meyer & Bolosky (FAST'11, Best Paper; FAST'23 Test of Time) studied 857 Microsoft desktops over 4 weeks. Whole-file dedup achieved about 3/4 of the savings of the most aggressive block-level dedup on live filesystems, and 87% on backup images. — [USENIX FAST'11](https://usenix.org/conference/fast11/study-practical-deduplication); [USENIX blog](https://www.usenix.org/blog/study-practical-deduplication)
- **DwarFS** on a Perl install tree (47.65 GiB, 1.93M files): dedup removed "28.2 GiB / 47.65 GiB in 1782826/1927501 duplicate files", so whole-file dedup alone removed about 59% of the bytes before compression. — [DwarFS README](https://github.com/mhx/dwarfs)
- **zpaq** (dedup + context mixing) on the same Perl tree — [DwarFS README](https://github.com/mhx/dwarfs):
  - `-m5`: 490 MB in 47m8s, with extraction taking 46m38s (about 700x slower than DwarFS extraction).
  - Default level: 1,143 MB in 381 s.
  - DwarFS `-l9` produced 315 MB.

### Inferences
- For a general-purpose archive (not a backup repository), whole-file dedup (a hash per file) is cheap and captures most of the gain. CDC adds value mainly for versioned trees, VM images and large files that change slightly. A sensible design: whole-file dedup always, plus optional FastCDC (2020 variant) for files above a threshold (e.g. ≥ 1 MiB). Chunks of 64 KiB–1 MiB average match casync and restic practice.
- Backup tools use large chunks (1–2 MiB) to keep index and metadata overhead low across TB-scale repositories. An archive format can afford smaller chunks (16–64 KiB) because its chunk table only covers one archive.
- Borg's per-repo seed and restic's per-repo polynomial exist because CDC boundaries leak information about file contents. An encrypted archive format should key or seed its chunker.

### Gaps
- I did not fetch per-dataset dedup ratios from the FastCDC paper (e.g. its TAR, LNX, WEB, VMA, RDB datasets), so no dataset-level percentages are given. Read the TPDS PDF for them.
- I found no measured dedup numbers for VM images from a primary source in this session.
- Later CDC variants (e.g. RapidCDC, QuickCDC, SeqCDC, AE/RAM chunking, and SIMD-accelerated "VectorCDC" proposals) were not verified this session.
- zpaq's internal fragment parameters were not verified this session. From background knowledge: rolling-hash fragments averaging about 64 KiB, append-only journaling.

## 2. Solid vs per-file compression

### Takeaway
Solid compression exploits redundancy across files and wins heavily on many small, similar files. The largest documented gains come from combining solid compression with dedup and similarity ordering, as in DwarFS. The cost is random access: one file needs decompression of everything before it in its block. The proven remedy is bounded solid blocks (DwarFS 16 MiB by default, 7z configurable), combined with file grouping or ordering so that similar data lands in the same block.

### Cited Findings
- I found no rigorous, controlled solid vs non-solid benchmark on a source tree. The figures available are from blogs or wikis and vary widely:
  - 551 MB of text-like data compressed to 38 MB with solid 7z vs 149 MB with non-solid ZIP (weak source).
  - LZMA2 solid 30.29% vs non-solid 30.44%: a marginal gain when files are dissimilar or large.
  - Suggested solid block cap: 512 MB.

  — [Grokipedia: Solid compression](https://grokipedia.com/page/Solid_compression) (low reliability)
- A 7-Zip forum thread reports that cross-file redundancy is lost beyond the solid block boundary, so the block size must cover the data that shares redundancy. — [SourceForge 7-Zip discussion](https://sourceforge.net/p/sevenzip/discussion/45797/thread/91a26e7da4/)
- DwarFS vs solid and non-solid formats on Perl (47.49 GiB, 1.9M files) — [DwarFS README](https://github.com/mhx/dwarfs):

  | Format | Size | Ratio | Build time | Notes |
  |---|---|---|---|---|
  | SquashFS (per-block, default) | 3.245 GiB | 14.6 | — | |
  | SquashFS zstd-22 | 4.75 GB | — | 32m54s | |
  | SquashFS lzma | 3.84 GB | — | 13m42s | |
  | 7z -mx=7 (solid) | 1.219 GiB | 39 | 23m27s | |
  | wimlib non-solid | 4.6 GB | — | 8m39s | |
  | wimlib solid LZMS | 1.017 GB | — | 15m23s | |
  | xz of the tarball | 4.3 GiB | — | 34m55s | Single stream, but window too small for distant duplicates |
  | lrzip on the tarball | 500 MB | — | 57m32s | |
  | DwarFS zstd | 0.352 GiB | 135 | 5m3s | |
  | DwarFS lzma | 0.310 GiB | 153 | — | |
  | DwarFS -l9 | 315 MB | — | 3m43s | |

- Random access cost of solid blocks (DwarFS benchmark, checksumming 1139 files) — [DwarFS README](https://github.com/mhx/dwarfs):
  - 7z solid: about 5 hours
  - SquashFS: 1.54 s
  - DwarFS zstd: 1.13 s
  - The solid WIM was "too slow to finish" the access benchmark. Non-solid WIM took 7.54 s vs DwarFS 1.15 s.
- Raspbian image comparison — [DwarFS README](https://github.com/mhx/dwarfs):
  - Sizes: DwarFS default 287 MiB, SquashFS 364 MiB, xz 297 MB, DwarFS -l9 244 MiB, tar.xz of the tree 247 MiB.
  - Full extraction: dwarfsextract 3.8 s vs `tar xf` of the tar.xz 12.8 s.

### Inferences
- Solid compression gives an order-of-magnitude gain on highly redundant trees (Perl versions: SquashFS 3.2 GiB → 7z 1.2 GiB). Dedup plus similarity ordering adds another 3–4x (→ 0.31–0.35 GiB). On heterogeneous or already-compressed data the solid gain is small (<1%).
- Bounded solid blocks (e.g. 4–64 MiB) plus a per-block index keep worst-case single-file access at "decompress one block". At zstd/lz4 speeds this is milliseconds, versus hours for 7z's unbounded solid folders.
- Long-range matching (zstd `--long`, lrzip) partly substitutes for dedup but is slower and less effective than explicit dedup (lrzip 500 MB vs DwarFS 315 MB).

### Gaps
- No primary, reproducible benchmark of 7z `-ms=on` vs `-ms=off` vs zip on a canonical source tree (e.g. Linux kernel) was found. Running one locally is recommended.
- 7-Zip's exact default solid block size limits per level were not verified this session. From background knowledge, they depend on level and dictionary size (e.g. a few GB at -mx9).

## 3. Index and catalog design across formats

### Takeaway
The best-performing formats put a compact index at the end (ZIP central directory, 7z header, zstd seek table, restic pack header). That allows streaming creation, because data comes first and the index last, and fast listing, because the reader seeks to the end. Appending is easiest when each segment carries its own trailing index and a newer index can supersede an older one (restic, WIM multi-image, zpaq journaling). Pure streams such as tar have no index and need a full scan.

### Cited Findings
- **ZIP** (APPNOTE 6.3.9) — [PKWARE APPNOTE 6.3.9](https://pkwaredownloads.blob.core.windows.net/pkware-general/Documentation/APPNOTE-6.3.9.TXT):
  - Layout: local file headers and data, then the central directory, then an optional ZIP64 EOCD record and locator, then the EOCD record (signature 0x06054b50).
  - Locating the index: the EOCD comment can be up to 65,535 bytes, so readers scan back up to about 64 KiB to find it.
  - Field widths: legacy counts are 2 bytes and sizes/offsets 4 bytes. An overflow is marked 0xFFFF/0xFFFFFFFF and resolved by ZIP64 8-byte fields.
  - Streaming: general purpose bit 3 plus a data descriptor (optional signature 0x08074b50) allows streaming and non-seekable writing.
  - Compression method IDs: 8 Deflate, 14 LZMA, 93 Zstandard (20 deprecated), 95 XZ, 99 AES marker.
  - Unix support: "version made by" upper byte 3 = UNIX determines how external attributes are read.
  - Extra field IDs: 0x000d UNIX, 0x000a NTFS (timestamps), 0x5455 extended timestamp, 0x7855 Info-ZIP UNIX, 0x7075 Unicode path.
- **7z** — [7zFormat.txt](https://raw.githubusercontent.com/ip7z/7zip/main/DOC/7zFormat.txt):
  - Signature header: a 6-byte signature, version, StartHeaderCRC, then NextHeaderOffset, NextHeaderSize and NextHeaderCRC pointing at the header at the end.
  - Data model: packed streams, then Folders (coder graphs with bind pairs), then SubStreamsInfo (several files per folder = solid).
  - FilesInfo: properties kEmptyStream, kEmptyFile, kAnti, kCTime, kATime, kMTime, kName, kWinAttributes (UINT32), kStartPos, kDummy.
  - Encoded header: kEncodedHeader (0x17) means the header is itself a packed stream, which is how compressed and encrypted headers (`-mhe`) work.
- **zstd seekable format** — [zstd seekable format spec](https://raw.githubusercontent.com/facebook/zstd/dev/contrib/seekable_format/zstd_seekable_compression_format.md):
  - Structure: independent zstd frames, followed by a seek table inside a final skippable frame (magic 0x184D2A5E), so plain zstd decoders still work.
  - Entries: 8 bytes each (compressed size u32, decompressed size u32), or 12 bytes with an XXH64-low-32 checksum.
  - Footer (9 bytes): frame count u32, descriptor byte (bit 7 = checksum flag), magic 0x8F92EAB1 as the last bytes of the file.
  - Offsets: computed by prefix sum. No maximum frame size is specified.
- **restic pack**: the header is at the end, so a pack can be indexed by reading only its header. Separate index files allow listing without reading the packs. — [restic design reference](https://restic.readthedocs.io/en/stable/100_references.html)
- **bupstash**: a separate content index (Merkle tree) allows listing and partial restore without the data stream. — [bupstash technical overview](https://raw.githubusercontent.com/andrewchambers/bupstash/master/doc/technical_overview.md)
- **casync catar**: a deterministic, reproducible, depth-first serialization in which each file or subtree serializes independently (no cross-references), which improves chunk reuse. The index is a separate `.caidx` chunk list. — [casync announcement](https://0pointer.net/blog/casync-a-tool-for-distributing-file-system-images.html)
- **WIM / wimlib** — [wimlib](https://wimlib.net/):
  - Dedup: single-instance storage by SHA-1, with each unique stream stored once per archive across images, hardlinks and named streams.
  - Compression: XPRESS, LZX (the default) and LZMS. Solid LZMS resources = ESD.
  - Images: multiple images per archive, managed with wimappend, wimdelete and wimexport.
  - Unix metadata: optional uid, gid, mode and xattrs.
- **pixz**: splits xz into many blocks for random access. Tarballs are indexed automatically, so `-l` lists files quickly and `-x` extracts one file quickly, verifying content against the index. Compression and decompression are parallel. — [pixz README](https://github.com/vasi/pixz)
- **EROFS** — [EROFS USENIX ATC'19](https://www.usenix.org/conference/atc19/presentation/gao); [Linux kernel EROFS docs](https://docs.kernel.org/filesystems/erofs.html):
  - Paper headline (ATC'19): fixed-size output compression instead of the fixed-size input used by squashfs-like systems. It reduces I/O amplification and decompression memory, deployed on "tens of millions of smartphones". Results: boot time up to 22.9% lower, storage nearly halved.
  - Algorithms: LZ4, MicroLZMA, DEFLATE and zstd, chosen per inode.
  - Pclusters: big pclusters since Linux 5.13. Since 6.1, one pcluster can serve multiple extents (compressed dedup).
  - Tail handling: fragments (tail packing into a special inode) and inline tails.
  - Dedup: chunk-based files (5.15+) and rolling-hash dedup.
  - Directories: entries sorted for binary search.
  - Addressing: 48-bit block addressing, up to 1 EiB.
- **DwarFS** — [DwarFS README](https://github.com/mhx/dwarfs):
  - Metadata: a separate metadata section. Mounting a 1.9M-file image took 0.009 s (zstd) vs 3.6 s for 7z listing.
  - Lookup: "find all 1.9M files" took 2.8 s vs 5.3 s for SquashFS.
  - Blocks: 16 MiB by default (64 MiB at -l9), and blocks can reference chunks in up to 2 previous blocks.
  - Throughput: random read about 20.2 GiB/s vs squashfuse about 230 MiB/s.

### Inferences — capability matrix (synthesized from the sources above plus format knowledge; verify before publishing)

| Format | List without reading data | Append | Streaming creation | Partial extraction |
|---|---|---|---|---|
| ZIP | Yes (CD at end) | Yes, by rewriting the CD after the last entry | Yes (bit 3) | Yes, per file |
| 7z | Yes (header at end), but needs to decode the header (and decrypt it if encrypted) | Limited (7-Zip rewrites the archive) | No: the start header must be patched with NextHeaderOffset, so seekable output is needed | Per folder; solid folders must decode from the start |
| tar(.gz/.xz) | No (full scan) | Uncompressed tar only | Yes | Sequential scan |
| pixz tar.xz | Yes (index) | No | Yes | Per xz block |
| zstd seekable | Frame table only (no file names) | Possible by rewriting the trailing table | Yes | Per frame |
| SquashFS/EROFS/DwarFS | Yes (mountable) | No (read-only images) | No (built in one pass with seeks) | Per block or pcluster |
| WIM | Yes | Yes (images) | No | Per resource |

- The design pattern that best fits all four goals (ratio, random access, append, streaming):
  1. A stream of bounded-size compressed blocks (zstd frames, 1–64 MiB) containing deduplicated, similarity-ordered file content.
  2. A trailing, compressed (and optionally encrypted) catalog with: file entries → (block id, offset, length) or chunk lists; the block table; a hash per file and chunk.
  3. A fixed-size footer with a magic number and the catalog offset, like ZIP EOCD, the zstd seekable footer or the restic Header_Length.
  4. Appending writes new blocks plus a new catalog that supersedes the old one (restic `supersedes` / journaling), keeping old catalogs for history or rollback.

### Gaps
- The SquashFS on-disk layout (128 KiB default block, fragment blocks, inode and directory tables at the end) was not fetched this session (background knowledge).
- The Apple Archive's own index and seek support was not verified. From background knowledge, AAR is a sequential stream of header+blob entries with no central index.
- The ZIP Info-ZIP "new Unix" extra field 0x7875 (variable-length uid/gid) is in Info-ZIP's extrafld.txt, not APPNOTE. APPNOTE as fetched lists 0x7855. Both IDs exist; this was not verified this session.

## 4. Metadata to preserve on macOS/Unix

### Takeaway
Full Unix and macOS fidelity needs:
- type, mode, uid/gid (plus names), nanosecond mtime/ctime/atime and birth time;
- xattrs (which on macOS carry resource forks as `com.apple.ResourceFork` and Finder info);
- ACLs, BSD file flags, symlink targets as raw bytes, hardlink grouping, device numbers and sparse holes.

Apple Archive, borg, casync and pax/libarchive cover most of this. Native 7z covers only Windows attributes and FILETIME, and ZIP needs extra fields.

### Cited Findings
- **Apple Archive (aa/YAA)** — [aa(1) man page](https://manp.gs/mac/1/aa); [The Apple Wiki: Apple Archive](https://theapplewiki.com/wiki/Apple_Archive):
  - Headers are field-based: magic "AA01" (or legacy "YAA1"), a 2-byte header size, then typed key/value fields. UINTs come in 1, 2, 4 or 8 bytes, with the size encoded in the type.
  - Field keys: TYP (d/f/l, …), PAT, LNK, DEV, UID, GID, MOD, FLG (flags), MTM, CTM, BTM (backup time), XAT (xattrs), ACL.
- **borg** stores per item: path, user/group, uid/gid, mode, symlink and hardlink source, rdev, mtime/atime/ctime in nanoseconds, xattrs, ACLs (OS-dependent) and flags. — [Borg internals](https://borgbackup.readthedocs.io/en/stable/internals/data-structures.html)
- **restic** tree nodes store: name, type, mode, mtime/atime/ctime, uid/gid, user/group, inode, device_id, size, links, content, subtree, linktarget and linktarget_raw (base64 for non-UTF-8 symlinks, since 0.16.0). The xattr field was not in the fetched section. — [restic design reference](https://restic.readthedocs.io/en/stable/100_references.html)
- **casync catar** stores: ownership, permissions, timestamps, symlinks, xattrs, ACLs, file capabilities, chattr flags and FAT attributes, each toggleable. SELinux and SMACK labels were not yet stored. — [casync announcement](https://0pointer.net/blog/casync-a-tool-for-distributing-file-system-images.html)
- **7z**: the spec defines only kWinAttributes (UINT32) and Windows-style timestamps. It has no uid/gid, xattr or ACL fields. — [7zFormat.txt](https://raw.githubusercontent.com/ip7z/7zip/main/DOC/7zFormat.txt)
- **EROFS**: the 64-byte inode carries nanosecond timestamps and 32-bit uid/gid, while the compact 32-byte inode has no nanosecond times and 16-bit ids. It supports inline and shared xattrs (with an optional bloom filter), POSIX ACLs stored as xattrs, and long xattr name prefixes. — [Linux kernel EROFS docs](https://docs.kernel.org/filesystems/erofs.html)
- **WIM (wimlib)**: optional Unix uid/gid/mode/xattrs. — [wimlib](https://wimlib.net/)
- **ZIP**: Unix mode lives in external attributes when "version made by" = 3. Times and uid/gid need extra fields (0x5455, 0x000d, 0x7855). — [PKWARE APPNOTE 6.3.9](https://pkwaredownloads.blob.core.windows.net/pkware-general/Documentation/APPNOTE-6.3.9.TXT)

### Inferences
- An extensible TLV/field-keyed header, as in AAR, is the most future-proof choice: unknown keys can be skipped, and per-archive "field masks" can drop unneeded metadata. Pair it with a columnar catalog (all modes, then all mtimes, and so on) to compress the metadata well. DwarFS's metadata approach suggests this, but it was not verified in detail.
- Store xattr values as content-addressed blobs so they dedup like data (resource forks, quarantine flags and Finder info repeat often).
- Sparse files: record hole maps (SEEK_HOLE/SEEK_DATA) per file rather than storing zero runs.

### Gaps
- pax extended header keywords (e.g. `mtime` with fractional seconds, `SCHILY.xattr.*`, `LIBARCHIVE.xattr.*`, `SCHILY.acl.*`, `SCHILY.fflags`, GNU sparse 1.0) were not fetched this session (background knowledge only).
- The official Apple Archive developer documentation (AAFieldKey list, AAEntryXATBlob/ACLBlob encoding) was not fetched. The field list above comes from the man page and the Apple Wiki.
- macOS-specific items to verify: Apple's `aa` handling of APFS clones, compressed files (decmpfs `com.apple.decmpfs`) and birth time.

## 5. Similarity-based ordering of files

### Takeaway
Ordering files by content similarity before solid compression is the single biggest ratio lever after dedup. DwarFS's nilsimsa ordering, combined with segment dedup, makes it about 3.5x smaller than solid 7z on version-heavy trees while also building faster.

### Cited Findings
- **DwarFS similarity and categorization** — [DwarFS README](https://github.com/mhx/dwarfs):
  - Ordering: files are ordered by a similarity hash (nilsimsa) so redundancy is exploited across file boundaries.
  - Segmenting: a segmenter finds matching segments across blocks, within a lookback of up to 2 previous blocks (`-B3`).
  - Categorizers: route content to different compressors, e.g. skip incompressible files and use FLAC for PCM audio.
  - Example: astrophotography data went from 3.94 GiB to 1.20 GiB in about 3.4 s, vs 2.2 GiB with fpack.
- **Speed vs ratio, DwarFS lzma vs zstd**: lzma gives smaller images but decompresses "about an order of magnitude slower". Sizes on Perl: 0.310 GiB vs 0.352 GiB. — [DwarFS README](https://github.com/mhx/dwarfs)

### Inferences
- A practical ordering pipeline for a new format:
  1. Whole-file dedup by hash.
  2. Group by detected type or category (extension plus magic sniffing), and send already-compressed media to a "store" or fast path.
  3. Within each group, order by a locality-sensitive hash (nilsimsa, or MinHash over CDC chunk fingerprints), falling back to path or extension sort.
  4. Pack into bounded solid blocks (e.g. 4–16 MiB zstd, optionally with a trained dictionary per category).
- Sorting by extension, then name (7-Zip's `-mqs` "sort by type") is a cheap baseline. Similarity hashing adds gains mainly on version-heavy or near-duplicate trees.

### Gaps
- I did not fetch documentation of 7-Zip's `-mqs` default or its measured effect. This is background knowledge: 7-Zip groups by extension in solid mode.
- No independent (non-author) benchmark of DwarFS ordering vs plain extension sort was found. All DwarFS numbers come from the author's README.
