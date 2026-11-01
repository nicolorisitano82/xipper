# "Cambia formato": converting archives between containers without recompression, with little free space, safely and recoverably

Scope: design study for a Xipper feature that converts an archive from one container format to another, copying compressed streams as they are wherever possible, working with little free disk space on APFS, and surviving a crash or power loss at any point. Grounded in Xipper's code (paths relative to `/Users/nicolo/Work/zipper`) and in primary specs and man pages. No repo file was modified.

Code references use `path:line` (lines as of commit 10fd976). macOS man pages were read locally on Darwin 27.2 (`man 2 fcntl`, `man 2 fsync`, `man 2 rename`/`renamex_np`, `man 2 clonefile`, `man 2 lseek`, `man 1 bsdtar`, `man 1 aa`) and are cited as "macOS man page".

---

## 1. Compatibility matrix: which streams can be moved raw, which only need new framing, which must be transcoded

### Takeaway
Raw transplant works when the source codec exists in the target format **and** the source stream covers exactly one target unit (one ZIP entry, one 7z folder, or one XIZ frame of 64 MiB or less). Re-framing alone (new headers, sizes and CRCs computed from data already there) covers more pairs than expected: ZIP LZMA→7z LZMA, 7z LZMA2→ZIP xz, ZIP Deflate→tar.gz as a multi-member gzip, ZIP zstd→XIZ frames. Transcoding is needed for solid blocks split into per-file entries, tar.X single streams going into per-file formats, RAR, Apple Archive, and any codec the target lacks (XIZ accepts only store and zstd). Encryption never lets ciphertext be reused, but it does **not** force recompression: decrypt the compressed bytes, then re-encrypt them.

### Cited Findings

**What Xipper's formats can carry (from code and spec)**
- ZIP methods Xipper knows: store 0, deflate 8, deflate64 9, bzip2 12, lzma 14, zstd 93, xz 95, aes 99 — `Sources/XipperKit/Zip/ZipFormat.swift:13`.
- 7z coder IDs Xipper knows: Copy, Delta 0x03, LZMA2 0x21, LZMA 0x030101, PPMd, BCJ/BCJ2/ARM/ARM64…, Deflate 0x040108, Deflate64 0x040109, BZip2 0x040202, ZSTD 0x04F71101, 7zAES — `Sources/XipperKit/SevenZip/SevenZipFormat.swift:43-60`, `:65-83`.
- Xipper's 7z writer emits only LZMA2 or Copy (plus the ARM64 filter and AES) — `Sources/XipperKit/SevenZip/SevenZipWriter.swift:335-351`.
- XIZ frames: codec 0 = store, 1 = zstd only — `docs/XIZ_SPEC.md:78`. Writers use 4 MiB frames; small files share a frame and big files span several — `docs/XIZ_SPEC.md:100-102`. Readers enforce `usize ≤ 64 MiB` per frame — `docs/XIZ_SPEC.md:273`. Frame CRC32C covers the payload *as written*, i.e. compressed or ciphertext bytes — `docs/XIZ_SPEC.md:84`, `:97`. The per-file digest is SHA-256 (HMAC when encrypted) and is **optional**; there is no CRC-32 of content — `docs/XIZ_SPEC.md:144`. File content is a list of extents (frame, offset, length), and extents of different entries may overlap (dedup) — `docs/XIZ_SPEC.md:138`, `:148-151`.
- Xipper's ZIP writer splits big entries into chunks: one Deflate stream pigz-style (1 MiB chunks), **independent zstd frames** (4 MiB), and bzip2/xz blocks joined into one stream (xz: 8 MiB) — `Sources/XipperKit/Zip/ZipWriter.swift:191-199`, `Sources/XipperKit/Codecs/Deflate.swift:9`.
- Xipper's Apple Archive writer compresses the **whole byte stream** (LZ4/LZFSE/LZMA via `ArchiveByteStream.compressionStream`), not each entry — `Sources/XipperKit/Tar/AppleArchiveWriter.swift:14-15`, `:53`. Apple's `aa` tool says archive compression is block-based, with a default block size of 4m — macOS man page `aa(1)`.
- RAR is read through libarchive (`ARCHIVE_FORMAT_RAR_V5`), so it is read-only — `Sources/XipperKit/Tar/RarReader.swift:203`.

**Existing raw-copy machinery that convert can reuse**
- `SevenZipCarriedFolder` lets the 7z writer write "a folder of an existing archive … as it is": its packed streams are copied byte for byte, with coders, keys and CRCs — `Sources/XipperKit/SevenZip/SevenZipWriter.swift:22-31`. The copy loop runs in 4 MiB pieces — `:117-130`. A convert-to-7z path can build such folders **synthetically** from ZIP entries: one Deflate/BZip2/LZMA coder, one packed stream, one substream, with the CRC taken from ZIP.
- The 7z editor carries a folder only when every member has a CRC and none is an anti-item (`recs.allSatisfy { $0.crc != nil && !$0.isAnti }`) — `Sources/XipperKit/Edit/ArchiveEditor.swift:228`. This is the same rule convert must apply on 7z→ZIP, because ZIP requires a CRC.
- The ZIP editor copies local header, data and data descriptor byte for byte and rebuilds the central record. It adds ZIP64 fields only where values overflow — `Sources/XipperKit/Edit/ArchiveEditor.swift:364-424`; EOCD/ZIP64 EOCD at `:446-467`. This is the ZIP emitter convert needs; it only has to accept a "foreign" entry (method, CRC, sizes, raw bytes) instead of a `ZipEntryRecord`.
- The XIZ editor appends frames and a new catalog (XIZ 1.1 segments) — `Sources/XipperKit/Edit/ArchiveEditor.swift:469-523`. `XizWriter.writeData` compresses from `ArchiveItem`s. Convert-to-XIZ needs a new lower-level "write a pre-compressed frame (codec, usize, payload)" entry point.

**Spec facts that decide transplant versus re-framing**
- ZIP: "Data integrity MUST be provided for each file using CRC32" (APPNOTE 4.1.5). Bit 3 data descriptors carry CRC and sizes after the data (4.3.9) — [APPNOTE 6.3.10](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT).
- ZIP LZMA (method 14): the data starts with a 2-byte LZMA SDK version, a 2-byte properties size and the properties (5 bytes in SDK 4.3: lc/lp/pb byte plus 4-byte dictionary size). The EOS marker is optional and signalled by general-purpose bit 1 (APPNOTE 5.8.5–5.8.9, 4.4.4) — [APPNOTE 6.3.10](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT).
- 7z: coder properties live in the header's Folder record (`Properties[PropertiesSize]`). Digests are optional (`AllAreDefined`, else a per-stream `Defined` bit). SubStreamsInfo carries per-folder `NumUnPackStreams`, `UnPackSizes` and CRCs — [7zFormat.txt](https://raw.githubusercontent.com/ip7z/7zip/main/DOC/7zFormat.txt).
- zstd: "Zstandard compressed data is made up of one or more frames", and frames can be appended into a single stream (§2, §3.1). `Frame_Content_Size` is optional unless `Single_Segment_Flag` is set (§3.1.1.1.4). Decoders are recommended to support windows up to 8 MB (§3.1.1.1.2) — [RFC 8878](https://www.rfc-editor.org/rfc/rfc8878.html).
- xz: a file may hold several concatenated Streams with null Stream Padding (§2, §2.2). Check types are CRC32 0x01, CRC64 0x04 and SHA-256 0x0A, "calculated from the original uncompressed data" (§2.1.1.2, §3.4). LZMA2 filter 0x21 has a 1-byte dictionary property (§5.3.1). BCJ filters include ARM64 0x0A (§5.3.2). The Index records Unpadded Size and Uncompressed Size per block (§4.3) — [xz file format](https://tukaani.org/xz/xz-file-format.txt). The sample code uses polynomial 0xEDB88320, the same reflected CRC-32 as ZIP and gzip ([§6](https://tukaani.org/xz/xz-file-format.txt)).
- 7z ZSTD id 4F71101 belongs to the **7-Zip-zstd fork** (mcmilk), not mainline 7-Zip. The fork ships a codec plugin for mainline, but that plugin only gives zstd inside 7z — [7-Zip-zstd README](https://github.com/mcmilk/7-Zip-zstd); [ghisler.ch forum](https://www.ghisler.ch/board/viewtopic.php?p=342767). I found no source showing mainline 7-Zip with native zstd (see Gaps).
- gzip→zip without recompression is known practice: `gz2zip` reuses the Deflate payload and takes CRC-32 and size from the gzip trailer. ISIZE is mod 2^32, so a file over 4 GiB needs its size supplied — [gz2zip on PyPI](https://pypi.org/project/gz2zip/).

**Pair-by-pair matrix** (R = raw transplant, the compressed bytes are identical; F = re-framing only, headers rebuilt from data already there, no decode; D = decode-only pass to compute a missing checksum, no re-encode; T = transcode, decode plus encode)

| Source → Target | Entry types | Verdict | Basis |
|---|---|---|---|
| ZIP → 7z | store / Deflate / Deflate64 / BZip2 | **R**: one non-solid folder per entry, coder Copy/Deflate/Deflate64/BZip2, CRC from ZIP | 7z coder IDs above; `SevenZipCarriedFolder` |
| ZIP → 7z | LZMA (14) | **F**: strip the 4-byte version/size header, move the 5 property bytes into the 7z coder properties | APPNOTE 5.8.8; 7zFormat.txt |
| ZIP → 7z | zstd (93) | R only with the fork id 0x04F71101: **not readable by mainline 7-Zip**, so T to LZMA2 by default | fork-only id |
| ZIP → 7z | xz (95), single block, LZMA2 only | **F** (inference): extract the raw LZMA2 data of the block into an LZMA2 coder (dictionary prop from block header); BCJ/ARM64 filters map to 7z filter coders | xz §3, §5.3 |
| ZIP → 7z | AES / ZipCrypto | decrypt, then R/F, then re-encrypt with 7zAES (whole folder) | ciphertext not reusable |
| 7z → ZIP | non-solid folder, 1 coder in {Copy, Deflate, Deflate64, BZip2} with CRC | **R** | ArchiveEditor.swift:228 rule |
| 7z → ZIP | non-solid LZMA | **F**: prepend the ZIP LZMA header (version + props). Bit 1 must reflect whether an EOS marker is present (7z LZMA usually ends without one; known size) | APPNOTE 5.8 |
| 7z → ZIP | non-solid LZMA2 (Xipper's default) | **F** (inference): wrap as ZIP method 95 **xz**: Stream Header + Block Header (filter 0x21, dict prop; ARM64 0x0A if present) + LZMA2 data + CRC32 check (= the 7z CRC) + Index + Footer | xz spec |
| 7z → ZIP | solid folder (n files) | **T** per file (decode the folder once, stream each file into its own encoder). Exception: target "xz" with whole-folder entries is impossible because ZIP entries are per file | — |
| 7z → ZIP | file without CRC | D (decode to compute CRC-32) then R/F | APPNOTE 4.1.5 |
| ZIP → XIZ | zstd entry made of frames each ≤ 64 MiB uncompressed | **F**: each zstd frame becomes an XIZ frame (32-byte header, CRC32C of payload); the entry gets extents over those frames. Xipper's own ZIP zstd = 4 MiB independent frames, ideal | ZipWriter.swift:191-199; XIZ_SPEC §4 |
| ZIP → XIZ | zstd single frame > 64 MiB, or no Frame_Content_Size | T (or decode to learn usize when it fits) | XIZ_SPEC:273; RFC 8878 §3.1.1.1.4 |
| ZIP → XIZ | store | F (store frames of ≤ 4 MiB, cut freely) | XIZ_SPEC:78 |
| ZIP → XIZ | Deflate/bzip2/LZMA/xz | **T** (cheap streaming decode + zstd encode) | XIZ codec set |
| XIZ → ZIP | file covering whole frames exclusively (big file) | **F + D**: concatenated zstd frames = valid ZIP zstd data, but ZIP needs CRC-32 of content and XIZ has only SHA-256, so decode once (zstd decodes at GB/s) | RFC 8878 §3.1; XIZ_SPEC:144 |
| XIZ → ZIP | small files sharing a frame, dedup extents | **T** (decode the frame, encode per file) | XIZ_SPEC:148-151 |
| XIZ → 7z | frames → solid folders | **F** (inference) when a frame's extents partition it in order without overlap: one 7z folder per run of frames (concatenated payloads = one zstd stream) with substreams = files. Needs the fork zstd id, so by default T to LZMA2 | 7zFormat SubStreams |
| 7z → XIZ | Copy folder | F | — |
| 7z → XIZ | LZMA/LZMA2/Deflate/BZip2 | T | XIZ codec set |
| tar.X → tar.Y | any | **T on the outer stream only** (tar bytes unchanged): streaming decode + encode, no temp files | — |
| tar.X → ZIP/7z/XIZ | single compressed stream | **T** (the stream cannot be split at file boundaries without decoding) | — |
| tar → ZIP/7z/XIZ (uncompressed tar) | — | stored entries: R (tar data are raw bytes); otherwise compress | — |
| ZIP(Deflate) → tar.gz | Deflate entries | **F** (inference): gzip allows multiple members; emit a member for each tar header block, a member holding the raw ZIP Deflate stream with CRC-32/ISIZE from ZIP (same CRC as gzip), and a member for the 512-byte padding | gz2zip principle (reverse); RFC 1952 |
| ZIP(zstd) → tar.zst, ZIP(xz) → tar.xz, ZIP(bzip2) → tar.bz2 | same idea: concatenated frames/streams | **F** (inference) | RFC 8878 §2; xz §2 |
| RAR → any | compressed entries | **T** (proprietary codec; Xipper only decodes via libarchive) | RarReader.swift:203 |
| RAR → any | stored entries | R | — |
| Apple Archive (.aar/.aea) → any; any → AA | — | **T** (block compression over the whole stream; AEA re-signs/re-encrypts) | AppleArchiveWriter.swift:14-53; `aa(1)` |
| cpio(.X) | like tar | — | — |
| ZIP → ZIP (e.g. force ZIP64, Deflate64→zstd) | — | R via ZipEditor; only codec changes T | ArchiveEditor.swift:364 |

**Encryption**
- WinZip AES (AE-1/AE-2) is implemented in `Sources/XipperKit/Crypto/WinZipAES.swift:4`, 7z AES in `Sources/XipperKit/Crypto/SevenZipAES.swift`, and XIZ uses per-frame AEAD with associated data that binds archive_id, frame index, codec, flags, dictionary and usize — `docs/XIZ_SPEC.md:215-221`. Each scheme derives keys differently and frames ciphertext differently (per entry, per folder, per frame), so ciphertext cannot be reused across formats.
- XIZ's AEAD associated data includes the frame index and archive_id — `docs/XIZ_SPEC.md:220` — so even XIZ→XIZ re-layout requires re-encryption.

**Competitors / prior art**
- WinRAR "Convert archives" (`WinRAR cv`, since 3.10) **unpacks to a temporary folder and repacks**, needs free space for that, has a "lowest allowed ratio" guard, can skip encrypted archives and delete originals, and warns it may fail on archives with links or file versions — [WinRAR help mirror](https://documentation.help/WinRAR/HELPCommandsConvert.htm) (summary via search; direct fetch returned 403), [Neowin WinRAR 3.10](https://www.neowin.net/amp/winrar-310-is-out/).
- PeaZip's converter extracts and recompresses into 7Z/TAR/WIM/ZIP, and is also pitched as a way to recompress at higher settings or add encryption — [PeaZip convert FAQ](https://peazip.sourceforge.net/convert-files.html).
- Bandizip: I found no dedicated convert command. Its in-place editing (add/delete/rename) "supports only the ZIP format" — [Bandizip help](https://be.bandisoft.com/bandizip/help/how-to-modify-an-archive-without-decompression/).
- WinZip: no one-click conversion; extract and re-zip (secondary source) — [cyberly.org](https://www.cyberly.org/en/can-winzip-convert-archives-between-formats/index.html).
- bsdtar: `tar -czf - --format pax @-` "converts" any readable archive by re-reading entries and writing them again, so it recompresses — macOS man page `bsdtar(1)`; [mankier bsdtar](https://mankier.com/1/bsdtar).
- Apple `aa convert` converts an archive into another archive (subset, other compression via `-a`/`-b`), within Apple Archive only — macOS man page `aa(1)`.
- advzip re-encodes Deflate streams inside ZIPs (zlib/7-Zip/libdeflate/zopfli), the opposite of transplanting — [advzip man page](https://manpages.debian.org/testing/advancecomp/advzip.1).
- gz2zip: the only general tool found that converts without recompression (gzip→ZIP/ZIP64) — [PyPI](https://pypi.org/project/gz2zip/).

### Inferences
- Xipper would be the first mainstream archiver whose convert keeps compressed payloads byte-identical across *different* containers. Every competitor found extracts and repacks.
- The cheapest high-value pairs are ZIP↔7z for Deflate/BZip2/LZMA/LZMA2(via xz) and ZIP(zstd)↔XIZ. Pairs that touch Xipper-written archives transplant best, because Xipper already writes independent zstd frames, LZMA2 chunks with dictionary resets and pigz-style Deflate.
- The "decode-only to compute CRC" case (XIZ→ZIP, AE-2→7z, 7z files without CRC) costs CPU but no extra disk space and no quality loss. It should be counted separately from transcoding in the UI.
- Default policy: never write a codec the target ecosystem cannot read (zstd-in-7z, xz-in-ZIP for some readers). Make "keep zstd (needs 7-Zip-zstd)" an explicit opt-in.
- Because Xipper's own 7z writer splits LZMA2 into chunks joined with dictionary resets (`SevenZipWriter.swift:34-35`), a solid Xipper 7z folder has restart points. In principle a solid folder could be split at those points into sub-folders without decoding, but a file boundary rarely falls on a chunk boundary, so per-file ZIP still needs T. Restart points matter more for low-space checkpoints (§2).
- AE-2 WinZip AES entries store CRC = 0 by design. Going AE-2 → 7z (CRC wanted) needs D, after decryption.

### Gaps
- Not verified: whether mainline 7-Zip's LZMA decoder in 7z accepts a stream that ends with an EOS marker (needed for ZIP LZMA with bit 1 → 7z), or whether ZIP readers (macOS Archive Utility, Windows Explorer, Info-ZIP) accept method 95 xz produced by re-framing 7z LZMA2. Both need an interop test with `7zz`, `unzip`, `bsdtar` and Windows.
- No source confirms whether mainline 7-Zip (ip7z) ever added native zstd. Only fork and forum sources were found.
- I did not check how 7-Zip-zstd's ZSTD decoder handles a packed stream made of several concatenated frames (needed for XIZ→7z F). RFC 8878 allows it, but the implementation must be tested.
- Multi-block xz in ZIP (Xipper joins 8 MiB xz blocks) → 7z LZMA2: concatenating block payloads after dropping LZMA2 end markers should give a valid LZMA2 stream because each block starts with a dictionary reset. This is an inference, not verified.

---

## 2. Low-disk-space strategies on APFS

### Takeaway
macOS has **no range clone**: `clonefile` works on whole files only, and an Apple engineer says partial clones could at most go "to the same file offset". Low-space conversion must therefore copy bytes and free the source behind it with `F_PUNCHHOLE`, front to back, in the source's physical order. The extra space needed peaks at about one verification unit (the largest of: one entry, one solid folder, one XIZ frame, or one checkpoint span of a tar stream) plus the target's growth for transcoded data. Punching frees nothing when the source blocks are shared (clones, APFS/Time Machine snapshots), so the feature must detect that before relying on it.

### Cited Findings
- `F_PUNCHHOLE`: "Deallocate a region and replace it with a hole. Subsequent reads … return bytes of zeros … This will not change the actual file size. Holes must be aligned to file system block boundaries. This will fail on file systems that do not support this interface." It takes `fpunchhole_t {fp_flags, reserved, fp_offset, fp_length}`. Errors: EINVAL if offset/length are not block multiples or flags are non-zero; **ENOSPC** "a filesystem that supports cloned files may return this error if punching a hole requires the creation of a clone and there is not enough space"; EPERM without write permission — macOS man page `fcntl(2)`. The struct is in the SDK at `sys/fcntl.h` (`fpunchhole_t`). Third-party code uses value 99 for `F_PUNCHHOLE` and says it arrived in the macOS 10.12.4 SDK — [rust-lang/libc PR 3337](https://github.com/rust-lang/libc/pull/3337/files); [QEMU patch](https://patchwork.ozlabs.org/project/qemu-devel/patch/B80D2309-1C4D-4410-B182-C704EA9D9386@gmail.com/).
- `clonefile`/`clonefileat`/`fclonefileat` clone a **whole file**: dst "must not exist"; blocks are shared copy-on-write; "a subsequent overwrite of an existing data block [may] return ENOSPC" — macOS man page `clonefile(2)`.
- Partial clone into an existing file does not exist on macOS. An Apple DTS engineer: it "would only be possible from a particular file offset in the source file *to the same file offset* in the destination file" because of encryption invariants, with no commitment to ship it. The workaround is to clone to a temp file and rename it over (FB12737014, FB23426784) — [Apple Developer Forums 831575](https://developer.apple.com/forums/thread/831575). Linux has FICLONERANGE and Windows has FSCTL_DUPLICATE_EXTENTS_TO_FILE (same thread).
- `F_TRANSFEREXTENTS` only moves preallocated space **past EOF** to another file. It does not move data — macOS man page `fcntl(2)`.
- `EF_MAY_SHARE_BLOCKS` ("file may share blocks with another file") exists in `sys/stat.h`. It only says a file *may* share blocks — SDK header; [Eclectic Light on clone detection](https://eclecticlight.co/2021/04/02/how-can-you-tell-whether-a-file-has-been-cloned-in-apfs/).
- `SEEK_HOLE`/`SEEK_DATA` let a program find holes. Filesystems "are allowed to expose ranges of zeros with SEEK_HOLE, but not required to" — macOS man page `lseek(2)`.
- zran-style checkpoints: a Deflate stream can be resumed at any block boundary given the bit offset plus "the 32K bytes of uncompressed data that precede that block" — [zlib examples/zran.c](https://raw.githubusercontent.com/madler/zlib/develop/examples/zran.c).
- Xipper's current writers assume full extra space: `OutputFile` writes a hidden temp `.<name>.xiptmp-<rand>` next to the target and `renamex_np`s it into place at commit — `Sources/XipperKit/Support/FileIO.swift:107-115`, `:156-166`. The generic edit path extracts to a temp dir and recreates the archive (≈ 2–3× space) — `Sources/XipperKit/Edit/ArchiveEditor.swift:72-110`.

**Strategy (a): forward copy + hole punching (recommended for v2)**
- Order: walk the source in increasing physical offset. ZIP: local headers order by `localHeaderOffset`, read from the central directory first. 7z: packed streams are contiguous after the 32-byte start header; the header sits at the end. XIZ: frames are contiguous from `data_start` — `docs/XIZ_SPEC.md:36-38`. tar.X: the stream itself.
- The target is a new file on the same volume, written append-only. Target directory structures (ZIP central directory, 7z header, XIZ catalog+footer) go last, built from in-memory state that is also journaled (§3).
- After target unit *k* is durable and verified, punch the source range `[align_up(prev_end), align_down(unit_end))` at the APFS block size (4096 is typical; query `f_bsize` with `fstatfs`). Leftover partial blocks are punched together with the next unit.
- Peak extra space ≈ max over units of (target bytes written − source bytes freed so far) + the target directory + the journal. For pure R/F conversions target ≈ source, so peak ≈ largest unit + alignment slack (≤ 2 blocks) + metadata.
- Units: ZIP/7z non-solid: one entry/folder, which can be split further into sub-ranges for very large raw entries, because raw bytes can be verified per sub-range. 7z solid folder: the whole packed stream, unless Xipper-written LZMA2 with dictionary-reset chunks provides restart points. XIZ: a frame (≤ 64 MiB uncompressed, 4 MiB typical). tar.gz/tar.bz2: checkpoints (Deflate: bit offset + 32 KiB window, zran; bzip2: block boundaries; zstd/xz: frame/block boundaries only. A single-frame zstd or single-block xz with a large window allows no small checkpoint, so its unit is the whole stream).

**Strategy (b): clonefile**
- Useless for sharing extents between a source of format A and a target of format B (no range clone). Useful as a **free safety snapshot** before an in-place operation: clone source → hidden backup, modify the original in place, delete the backup at the end. Space is consumed only for blocks that diverge (copy-on-write). It does **not** reduce peak space for a full conversion, because the backup pins every source block.

**Strategy (c): in-place rewrite inside the source file**
- Possible only when the target's write pointer never overtakes the source's read pointer. ZIP→7z satisfies this naturally: 7z has no per-entry local headers, so its prefix is always ≤ the ZIP prefix. Most other directions do not (7z→ZIP adds 30+name bytes per entry ahead of the data).
- Every overwrite destroys source bytes before the target is complete, so it needs a doublewrite buffer (stage each unit in the journal before overwriting). That doubles I/O and leaves no rollback without reverse conversion. Two-file punching gives the same peak space with simpler invariants (source bytes are only freed, never overwritten), so in-place is not recommended except for same-format fix-ups (ZIP64 promotion, XIZ compaction) where `clonefile` gives a cheap backup.

**Strategy (d): temporary volumes / chunk files (fallback when punching is unsupported, e.g. exFAT/FAT/SMB)**
- Process the source **back to front**, shrinking it with `ftruncate` (works on every filesystem) and writing each converted unit into its own numbered chunk file. Then assemble the target front to back, unlinking each chunk file once appended (with a journal). Peak ≈ one unit; I/O ≈ 2× target. ZIP/7z/XIZ offsets are only needed in the final directory, so they can be computed during assembly.

### Inferences
- The space estimate shown before conversion = Σ(raw/framed bytes, exact) + Σ(transcoded bytes, estimated by compressing a sample of each transcoded entry or of the first N MiB) + directory size + journal. Low-space mode needs only max(unit) + growth, where growth = max(0, target − source) accumulated in order.
- Punching must be **proven effective before the first destructive step**: punch one already-converted unit, then compare `statfs` free space before and after (allow noise) and check `EF_MAY_SHARE_BLOCKS`. If no space came back (snapshot/clone), stop and tell the user: "this file is held by a snapshot (Time Machine local snapshot or a clone): low-space mode cannot free space." That case is not dangerous: the snapshot still holds the data.
- A source in a Time Machine local snapshot is actually *safer* to punch (the snapshot keeps a copy) but gains nothing. A source that is a clone of another file is likewise safe but gains nothing.
- Cross-volume target (e.g. converting onto an external disk) needs no punching at all. Detect the different `st_dev` and use v1 mode with space checked on the target volume.

### Gaps
- Apple documents no APFS-specific semantics for F_PUNCHHOLE: punch granularity, whether metadata updates are journaled atomically with the punch, or how holes behave across `F_FULLFSYNC`. Only the generic fcntl man page exists. Needs empirical testing (punch, then power cut in a VM).
- I could not confirm APFS block size behaviour on non-4K volumes or whether punching on encrypted APFS volumes has extra constraints beyond the same-offset clone remark.
- No authoritative source on whether `F_PUNCHHOLE` works on files inside iCloud Drive / File Provider domains.

---

## 3. Safety and recoverability

### Takeaway
Use a write-ahead intent journal (append-only, CRC per record, `F_FULLFSYNC` before every destructive step) together with the invariant **"no source byte is freed until the target bytes that replace it are durable and re-verified from disk"**. Recovery then always means **resume forward**: the journal records what is done, punches are idempotent, and the target is truncated to the last committed offset. Byte-exact rollback is possible only before the first punch. After that, "rollback" is a reverse conversion: lossless for R/F units, semantically equivalent but not byte-identical for transcoded units. Signatures (XIZ signed segments, AEA) and PAR2 sets never survive a conversion. They must be re-created, or the conversion refused unless the user accepts that.

### Cited Findings
- fsync alone does not guarantee persistence on macOS: the drive "may not physically write the data … and it may be written in an out-of-order sequence … This is not a theoretical edge case". Applications needing ordering should use `F_FULLFSYNC` — macOS man page `fsync(2)`. `F_FULLFSYNC` "asks the drive to flush all buffered data … data that had been fsync'd on the same device before is guaranteed to be persisted when this call returns", and it is implemented on APFS. `F_BARRIERFSYNC` orders I/O without guaranteeing durability — macOS man page `fcntl(2)`.
- `renamex_np(RENAME_SWAP)` swaps source and target atomically where `VOL_CAP_INT_RENAME_SWAP` is supported. `RENAME_EXCL` returns EEXIST if the destination exists. The two flags cannot be combined — macOS man page `renamex_np(2)`.
- OSDI'14 "All File Systems Are Not Created Equal": ALICE found 60 crash vulnerabilities in 11 applications, and the common heuristic of persisting a file's data before renaming it fixes only a small minority (3) — [USENIX](https://usenix.org/node/186195); [paper PDF](https://cs.uwaterloo.ca/~alkiswan/papers/alice-osdi14.pdf); [Morning Paper summary](https://blog.acolyer.org/2016/02/11/fs-not-equal/).
- Xipper today: `OutputFile.commit` flushes, closes and `renamex_np`s **without fsync/F_FULLFSYNC** — `Sources/XipperKit/Support/FileIO.swift:156-166`. `AppendFile.sync()` (XIZ appends) does use `F_FULLFSYNC` with an `fsync` fallback — `Sources/XipperKit/Edit/ArchiveEditor.swift:633`. XIZ appends are crash-safe by format design: an interrupted append leaves bytes after the last valid footer, and readers search backwards for the last valid footer — `docs/XIZ_SPEC.md:311-313`.
- Signature and key policies already in Xipper: editing a signed AEA without a key is refused — `Sources/XipperKit/Edit/ArchiveEditor.swift:63-65`. Compacting an XIZ with access groups or signatures is refused because it "would drop them" — `:58-60`. Changing an XIZ with access groups needs every group's key — `:530-533`. XIZ 1.3 signed segments chain each signature to the previous one — `docs/XIZ_SPEC.md:340+`.
- `SF_DATALESS` (0x40000000, "file is dataless object") in `st_flags` marks iCloud/File Provider files whose data is not local — SDK `sys/stat.h:359`.
- PAR2 support: `PAR2.verify`/`PAR2.repair` — `Sources/XipperKit/Recovery/PAR2.swift:145`, `:152`. CLI `xipper par2 create|verify` — `Sources/xipper/main.swift:377-398`.

### Proposed protocol (synthesis)

Files in the source's directory (same volume, so renames are atomic):
- `<src>`: the source, renamed at start to `.<src>.xipper-converting` in low-space mode so Finder and other tools do not show a half-punched archive under its real name. Alternatively keep the name and set an xattr `com.xipper.convert`.
- `.<dst>.xiptmp-<uuid>`: the target under construction (the existing OutputFile naming).
- `.<dst>.xipper-journal`: the journal.

Journal records (append-only, each = type + payload + CRC32C, like XIZ's own CRC32C usage):
1. `BEGIN`: source identity (dev, ino, size, mtime, SHA-256 of the source's directory region, i.e. the ZIP CD, 7z header or XIZ footer+catalog), target path/format/options, Xipper version, the low-space flag and the full **plan** (ordered units: source range, target op R/F/D/T, expected target length if known, source CRC or hash of raw bytes).
2. `UNIT_DONE(k, target_end, target_hash)`, written after the target data is durable and verified.
3. `PUNCHED(k, range)`: optional, since punching is idempotent.
4. `DIRECTORY(offset, length, hash)`: the target's central structures are written.
5. `COMMITTED`: the final rename is done. The journal is then unlinked.

Per-unit ordering (low-space mode):
1. Write the unit to the target (append).
2. `F_FULLFSYNC(target)`. Optionally `F_BARRIERFSYNC` per unit and a full fsync every N MiB, but **always** a full one before a punch.
3. Re-read the unit from disk (with `F_NOCACHE` on a second fd, so the bytes come from storage rather than the unified buffer cache, as far as macOS allows) and compare it with the hash computed while writing. For R/F units also compare it with the hash of the source raw bytes read in step 1. For T units, decode the written unit and compare the CRC-32 of the plaintext with the source CRC.
4. Append `UNIT_DONE` and `F_FULLFSYNC(journal)`.
5. `F_PUNCHHOLE` on the source range (block-aligned).
6. Optionally append `PUNCHED`. No fsync is needed: if the punch is lost, resume repeats it.

Commit:
- Write the target directory, then `F_FULLFSYNC`, then a final verification pass (structure parse plus, optionally, a full CRC test).
- Then `renamex_np(tmp, final, RENAME_EXCL)` when the name changes (usual case: .zip→.7z), or `RENAME_SWAP` + unlink when the name is the same. fsync the directory. Write `COMMITTED`, unlink the source (in low-space mode it is mostly holes already), then unlink the journal.

Resume after a crash (Xipper on launch or on opening either file finds a journal):
- Validate the source identity and that holes exist only where `PUNCHED`/`UNIT_DONE` say (`SEEK_DATA`/`SEEK_HOLE`, with the man page caveat that zeros may also be reported as holes).
- Truncate the target to the last `UNIT_DONE.target_end`, re-punch every done unit (idempotent), and continue from unit k+1.
- If no unit was punched yet: offer **rollback** (delete target and journal, rename the source back). This is byte-exact.
- After punches: offer **resume** (default) or **reverse conversion** of the done units back into the source format. That reverse step is lossless for R/F units and only content-equivalent for T units, so a byte-exact rollback of a partially punched archive is in general impossible. The UI must state this "point of no return" before starting low-space mode.

### Inferences
- Before the conversion feature ships, `OutputFile.commit` should get `F_FULLFSYNC` before `renamex_np` (FileIO.swift:156). The ALICE results show that rename without a preceding persistence step is the classic hole. This also improves every existing create/edit path.
- Verification by re-reading from disk is what makes punching safe against silent write errors. Hashing the source raw bytes once (BLAKE3/SHA-256 or the CRC32C XIZ already uses) gives a cheap equality check for R/F units without decompressing.
- PAR2: if a `.par2` set exists for the source, run `PAR2.verify` (optionally `repair`) **before** converting, so a damaged source is caught while it can still be repaired. After conversion the old PAR2 set is useless; offer to create one for the target with the same redundancy. In low-space mode, PAR2 for the target needs extra space at the end (redundancy % of target).
- Signed XIZ → anything, and AEA → anything: the signature cannot be carried. Converting *into* XIZ or AEA with a signer produces a fresh signature that attests the conversion, not the original author. Default: refuse if the source is signed unless the user confirms "the signature will be lost", mirroring ArchiveEditor.swift:58-65.
- XIZ with access groups or threshold keys → other formats: those formats cannot express per-group keys. Converting would require every key and would collapse everything to one password, so refuse or warn strongly.
- iCloud/dataless sources (`SF_DATALESS`): reading materialises the file (downloads it), which needs the very disk space the user lacks, and punching a File Provider file has unknown semantics. Refuse low-space mode for dataless or File-Provider-managed files, and suggest downloading the file first or using v1 to another volume.
- Sparse leftovers: if a crash happens and the user copies the half-punched source elsewhere with a tool that does not preserve holes, it inflates with zeros. Renaming the source to `.xipper-converting` during the operation reduces that risk.

### Gaps
- No Apple documentation was found on whether `rename` and directory metadata are durable on APFS without an explicit fsync of the directory, or on the ordering between `F_PUNCHHOLE` metadata and data written to another file. This needs crash testing (VM with forced power-off, or `dm-log-writes`-style replay, which is Linux-only; on macOS, a UTM/Virtualization.framework VM killed mid-run).
- I did not verify that `F_NOCACHE` re-reads truly bypass the drive cache. It only bypasses the OS cache, so drive-level verification is impossible from user space.

---

## 4. What competitors do (consolidated)

### Takeaway
Every archiver found (WinRAR, PeaZip, WinZip, Bandizip, bsdtar, Apple `aa convert`) converts by extracting and recompressing, and the ones that document it require full temporary space. The only no-recompression converter found is the single-purpose gz2zip. No tool found offers low-space or crash-resumable conversion.

### Cited Findings
- WinRAR `cv`: unpacks originals to a temp folder ("You need to have enough free space in this folder"), recompresses to RAR/ZIP, has a "lowest allowed ratio" option (100 keeps the original if the new archive is bigger), can delete originals, can skip encrypted archives for unattended runs, may fail on links/file versions, and was added in 3.10 — [WinRAR help mirror](https://documentation.help/WinRAR/HELPCommandsConvert.htm); [Neowin 3.10](https://www.neowin.net/amp/winrar-310-is-out/).
- PeaZip: converts from 200+ readable formats into 7Z/TAR/WIM/ZIP (RAR only if WinRAR is installed), also for recompression or encryption — [PeaZip](https://peazip.sourceforge.net/convert-files.html).
- Bandizip: no convert command found. Editing works for ZIP only — [Bandizip help](https://be.bandisoft.com/bandizip/help/how-to-modify-an-archive-without-decompression/).
- WinZip: extract then re-zip (secondary source) — [cyberly.org](https://www.cyberly.org/en/can-winzip-convert-archives-between-formats/index.html).
- bsdtar `@archive`: re-reads entries and writes a new archive in another format, recompressing — macOS man page `bsdtar(1)`.
- Apple `aa convert`: Apple Archive → Apple Archive (subset, recompression, manifest) — macOS man page `aa(1)`.
- advzip: recompresses Deflate inside ZIP for a 5–10% gain — [advzip(1)](https://manpages.debian.org/testing/advancecomp/advzip.1).
- gz2zip: raw Deflate transplant gzip→ZIP/ZIP64 — [PyPI gz2zip](https://pypi.org/project/gz2zip/).

### Inferences
- Positioning: "Cambia formato senza ricomprimere" (change format without recompressing), with an explicit per-entry report (copied / re-framed / checksum-only / recompressed). Together with low-space and crash-resume, no tool found offers this. Borrow WinRAR's "lowest allowed ratio" guard for the transcoded portion and its "skip encrypted" switch for batch mode.

### Gaps
- I could not fetch the official current WinRAR help (the mirror returned 403 on direct fetch), so details come from search snippets of the mirror. No official WinZip documentation on conversion was found. 7-Zip has no convert command (stated in the brief), but I did not find a primary source saying so.

---

## 5. Concrete recommendation: phases, UX, CLI, tests

### Takeaway
Ship in three steps. v1: a raw-transplant converter with full extra space, verification and an atomic swap, reusing ZipEditor/SevenZipCarriedFolder/XIZ frame writing. v1.5: re-framing pairs (LZMA, LZMA2↔xz, zstd↔XIZ frames, ZIP→tar.gz multi-member). v2: low-space mode with hole punching, the journal and resume. Test with crash injection at every journal step plus VM power-cut tests.

### Cited Findings (code hooks to reuse)
- ZIP emitter with raw copy + central directory: `Sources/XipperKit/Edit/ArchiveEditor.swift:298-467`.
- 7z raw folder injection: `Sources/XipperKit/SevenZip/SevenZipWriter.swift:22-31`, `:117-130`, `:257-275`. Folder intactness rule: `Sources/XipperKit/Edit/ArchiveEditor.swift:228-240`.
- XIZ append writer, durable sync: `Sources/XipperKit/Edit/ArchiveEditor.swift:610-640`. Catalog/footer writing: `XizWriter.writeCatalog` (called at `ArchiveEditor.swift:518`).
- Atomic output: `Sources/XipperKit/Support/FileIO.swift:96-166`.
- CLI dispatch style: `Sources/xipper/main.swift:220` (create), `:345` (edit), `:377` (par2).
- Generic fallback (extract + create): `Sources/XipperKit/Edit/ArchiveEditor.swift:72-110`.

### Proposed design (synthesis)

**Core API**: `Xipper.convert(_ src: URL, to format: ArchiveFormat, options: ConvertOptions) -> ConvertReport`, with ConvertOptions = { level/codec for transcoded entries, password in/out, `allowForeignCodecs` (zstd-in-7z, xz-in-ZIP), `lowSpace: .off/.auto/.force`, `keepSource`, `verify: .structure/.full`, signer }. `ConvertReport` = counts and bytes per class {raw, reframed, checksumOnly, transcoded}, plus output size and peak extra space.
- **Planner** (pure, testable): produces the per-unit plan from the source reader's records (ZipEntryRecord / SevenZip folders / XIZ frames+extents / tar stream) and the target capability table (the matrix in §1). A dry run uses the same plan.
- **Emitters**: ZipEmitter (from ZipEditor.copy/finish, generalised to foreign entries), SevenZipEmitter (SevenZipWriter with synthetic `SevenZipCarriedFolder`s for R/F, its LZMA2 path for T), XizEmitter (new `writeRawFrame(codec:usize:payload:)` + `writeCatalog`), TarEmitter (multi-member gzip/zstd/xz/bzip2 for F, otherwise a streaming encoder).
- **Executor**: v1 = OutputFile + verify + commit with F_FULLFSYNC. v2 = journaled executor with punching.

**Phases**
- v1 (full space): pairs ZIP↔7z (store/Deflate/Deflate64/BZip2 R), 7z non-solid Copy/LZMA→ZIP, ZIP(zstd frames ≤ 64 MiB)→XIZ, tar.X→tar.Y, everything else through T with streaming (no extracted temp tree, unlike `rebuild`). Pre-flight checks free space ≥ estimated target + 5% margin. Source kept until the target verifies, then optionally moved to the Trash (not unlinked) by default.
- v1.5 (re-framing): ZIP LZMA↔7z LZMA; 7z LZMA2(+ARM64)→ZIP xz (opt-in, reader compatibility warning); ZIP xz→7z LZMA2; XIZ→ZIP zstd (decode-only for CRC); ZIP(Deflate/zstd/xz/bzip2)→tar.* multi-member; XIZ↔7z zstd (opt-in, fork-only).
- v2 (low space): journal + F_PUNCHHOLE + resume/rollback UI; chunk-file fallback for filesystems without punch; snapshot/clone detection; refusal for dataless or File Provider files.

**UI/UX** (Finder-style sheet "Cambia formato…")
- Target format picker → instant plan preview: "1 245 entries: 1 180 copied as they are, 40 re-framed, 25 recompressed (Deflate → LZMA2)", with an expandable list of the entries that will be recompressed and why (solid block, unsupported codec, encryption).
- Space panel: "Spazio necessario: 3.2 GB (disponibile 1.1 GB)" → offer low-space mode with an explicit warning: "Durante la conversione l'archivio originale viene liberato man mano: in caso di interruzione la conversione riprende, ma non è possibile tornare all'archivio originale identico byte per byte" (during conversion the original archive is freed progressively: after an interruption the conversion resumes, but the original cannot be restored byte for byte).
- Warnings: signature loss (XIZ/AEA), access groups collapse, PAR2 to regenerate, target codec not readable by common tools (zstd in 7z, xz in ZIP), ZIP AES→7z re-encryption (header encryption choice), RAR → always recompressed.
- Progress shows phases (copy / verify / free); resume banner on next launch if a journal exists.

**CLI shape**
```
xipper convert <archive> --to zip|7z|xiz|tar.zst|… [-o out]
    [--dry-run]                # print the plan: raw/reframed/checksum/transcode per entry, space estimate
    [--low-space auto|on|off] [--keep-source] [--trash-source]
    [--allow-foreign-codecs]   # zstd in 7z, xz in ZIP
    [--level N] [--method …]   # for transcoded entries only
    [--password … | --password-out …] [--sign KEY]
    [--verify structure|full] [--json]
xipper convert --resume <journal|archive>   |   xipper convert --rollback <journal>
```
Exit codes like the other commands. `--dry-run --json` serves the MCP server (`Sources/XipperMCP`) too.

**Test plan**
- Golden interop: for each matrix cell, convert fixtures (Xipper-made + 7-Zip/Info-ZIP/WinRAR/bsdtar/zstd-made, ZIP64, data descriptors with and without signature, Unicode names, AES/ZipCrypto, solid/non-solid 7z, xz multi-block) and check with `7zz t`, `unzip -t`, `bsdtar -tf`, `xz -t`, `zstd -t`, Xipper `test`, plus a byte-equality check of raw payloads (hash of the source compressed range = hash of the target range).
- Crash injection: a fault hook in the executor that aborts (SIGKILL in a child process) at every step boundary (after write, after F_FULLFSYNC, after verify, after journal append, after punch, during directory write, before/after rename) and at random byte offsets inside writes. Each case must then pass resume and give a target byte-identical to an uninterrupted run, and must never contain a punched source range whose target unit is not durable.
- Power-loss simulation: macOS VM (Virtualization.framework/UTM) with forced stop during long conversions on APFS images, replayed many times. Optionally an ALICE-like trace recorder of syscalls (write/fsync/punch/rename) to enumerate legal reorderings, following [ALICE](https://research.cs.wisc.edu/adsl/Publications/alice-osdi14.html).
- Low-space: an APFS disk image of fixed small size (`hdiutil create -size … -fs APFS`) filled to leave only max(unit)+ε free. Conversion must succeed. With a local snapshot present (`tmutil localsnapshot` on the image volume) it must detect no reclaim and stop safely.
- Fuzzing: the planner and readers with malformed sources (lying sizes/CRCs, overlapping XIZ extents, 7z folders with odd bind pairs). A raw transplant must never emit a target whose declared CRC/size disagrees with the decoded content: verify by decoding in tests.
- Property tests: convert A→B→A for R/F-only fixtures gives byte-identical payloads, and A→B extraction equals A extraction (content + metadata modulo format limits).

### Inferences
- Most of v1 is plumbing over code that already exists (ZipEditor.copy, SevenZipCarriedFolder, XIZ append). The new pieces are the planner, a foreign-entry ZIP emitter, the XIZ raw-frame writer and the format adapters for re-framing.
- v2's risk is concentrated in a small executor: about 6 syscalls in a strict order plus journal parsing. Keep it format-agnostic (it sees only "units" with source ranges and target bytes) so crash tests cover every format at once.

### Gaps
- Interop of re-framed outputs (xz-in-ZIP readers, LZMA EOS in 7z, multi-frame zstd in 7-Zip-zstd) must be measured. No documentation settles it.
- Real-world APFS behaviour of F_PUNCHHOLE under power loss is undocumented and must be established by the VM tests above before v2 ships.
