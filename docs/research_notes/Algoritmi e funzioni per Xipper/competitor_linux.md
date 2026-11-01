# Linux archivers and compression/backup tooling: competitive benchmark and idea source for Xipper

Scope: GUI archivers (Ark, File Roller, Xarchiver, Engrampa, PeaZip), CLI and format tools (7zz, atool, dtrx, unar, ouch, libarchive/bsdtar, parallel compressors, zpaq, lrzip), read-only filesystem images (squashfs, EROFS, DwarFS), dedup backup tools (borg, restic, kopia), and casync/desync. Research date: 2026-11-01. Xipper context: MIT, self-contained, native macOS. It already has ZIP/7z/tar/lz4/brotli/cpio/AA/XIZ create, RAR read, in-place editing, PAR2, mount read-write, AES, signed archives with Merkle proofs, Finder/QuickLook, CLI and MCP.

Method note: about 20 tool calls. Primary sources were preferred: project READMEs, official docs, man pages and release notes. Where a tool could not be checked in this session, it is listed under Gaps rather than described from memory.

---

## 1. Feature list per tool (GUI and CLI) and the license picture

### Takeaway
Linux GUI archivers (Ark, File Roller, PeaZip) are broad but conventional. Xipper already exceeds them on in-place editing, recovery data, signing and mounting. The differentiating ideas on Linux come from CLI and format tools: smart extraction (dtrx), signature-based format detection with confirmation (ouch), encoding autodetection (unar), and versioned dedup archives (zpaq, borg, restic, kopia). One correction to the brief: GNOME "Decoder" is a QR-code app, not an archiver.

### Cited Findings

**GUI**
- **KDE Ark**: browse, extract, create and modify archives; preview file contents without extracting. Formats: tar, gzip, bzip2, zip, rar, 7z, CD-ROM images "and more". License GPL-2.0+. Latest version 26.08.2 (2026-10-08). Available on Linux (Flathub, Snap) and Windows. — [KDE Apps: Ark](https://apps.kde.org/ark/)
- **GNOME File Roller (Archive Manager)**: still maintained. Version 44.6 requires GTK 4.20.3 and supports tar, bzip2, bzip3, gzip, zip, jar, compress, lzop, zstd, dmg and many others. — [BLFS file-roller](https://linuxfromscratch.org/blfs/view/svn/gnome/file-roller.html)
- File Roller moved to GTK4 in 44.alpha. A 2026 SUSE patch addresses CVE-2026-78322: line-length check when parsing command output. File Roller wraps CLI tools and parses their output, which is an attack surface. — [SUSE PackageHub file-roller](https://packagehub.suse.com/packages/file-roller/)
- File Roller uses GTK4 and libadwaita; its last known commit is dated 2026-05-26. — [LinuxPhoneApps](https://linuxphoneapps.org/apps/org.gnome.fileroller/)
- GNOME 41 removed Archive Manager from GNOME Core because Nautilus has built-in support for common formats. Ubuntu proposed dropping it from the default install. — [Ubuntu Discourse proposal](https://discourse.ubuntu.com/t/proposal-remove-archive-manager-from-default-install/32765)
- Nautilus's built-in extraction relies on **gnome-autoar**, "GObject-based abstractions for archive handling, based on libarchive", licensed LGPLv2.1. — [gnome-autoar GitLab](https://gitlab.gnome.org/GNOME/gnome-autoar)
- **GNOME "Decoder"** generates and scans QR codes. It is not an archive manager. — [apps.gnome.org/Decoder](https://apps.gnome.org/Decoder/)
- **PeaZip (Linux)**: version 11.4.0, LGPLv3. Extracts over 200 types, including 7Z, XZ, BZ2, Brotli, GZ, ISO, RAR/RAR5, TAR, WIM, ZIP, ZIPX, ZPAQ and ZST. Creates 7Z, ARC and PAQ. Encryption with AES, Serpent, Twofish and Blowfish. Also offers secure delete, hash/checksum and duplicate finding, split/join, and export of GUI tasks as command-line scripts. Packages: Flatpak (Qt6, x86_64/aarch64), DEB, RPM and portable tar.gz. — [PeaZip Linux](https://peazip.github.io/peazip-linux.html)

**CLI and format tools**
- **7-Zip 26.01** (2026-04-27): the Linux build can use 2 MB huge pages, about 10% faster 7z/XZ/LZMA/LZMA2 compression. — [Phoronix](https://phoronix.com/news/7-Zip-26.01)
- 7-Zip 26.01 adds a new `-spo[d|c|r]` switch for output path mode. `-spoc` joins the `-o` path with the archive name, which amounts to a "extract into folder named after archive" mode. It also fixes extraction of TAR archives with sparse files. — [Phoronix](https://phoronix.com/news/7-Zip-26.01); [Releasebot mirror](https://releasebot.io/updates/7-zip)
- **ouch** (Rust): no runtime dependencies, clear error messages, accessibility mode, shell completions and man pages, decompression from stdin. Full support for tar, gz, sz, zst, xz, lzma, lz, bz/bz2, bz3, lz4 and br. zip and 7z work but cannot stream. gz, sz and zst compress in parallel. RAR is decompress/list only, as an optional `unrar` feature, for licensing reasons. Supports aliases (cbz/epub = zip, cbr = rar) and chained formats (.tar.gz). Release binaries are signed with Sigstore cosign, and builds are reproducible. — [ouch GitHub](https://github.com/ouch-org/ouch)
- **dtrx** (GPL-3.0; README v7.1, 2011): always extracts into a dedicated directory named after the archive. `--one inside|rename|here` controls the single top-level entry case. `-r` extracts nested archives recursively. It fixes permissions so the owner can read and write all extracted files, and never overwrites an existing directory; it picks an alternative name instead (`-o` to override). Other options: `-n` non-interactive with conservative defaults, `-l` list, `-m` deb/gem metadata, URL download. Formats: tar, zip (including SFX .exe), cpio, rpm, deb, gem, 7z, cab, rar, lzh, InstallShield, plus gz/bz2/lzma/xz/compress. — [dtrx README (moonpyk mirror)](https://github.com/moonpyk/dtrx)
- **unar/lsar** (The Unarchiver CLI, LGPL-2.1+): guesses filename encodings with Mozilla charset autodetection, with an `-e` override. `lsar -j` outputs JSON. — [openSUSE unar.spec](https://build.opensuse.org/projects/openSUSE/packages/unar/files/unar.spec?expand=0); [lsar man](https://linuxcommandlibrary.com/man/lsar). Its RAR code has a non-free license caveat. — [nixpkgs issue 16868](https://github.com/NixOS/nixpkgs/issues/16868)
- **libarchive/bsdtar**: version 3.8.11 (2026-10-30), New BSD license. Reads tar, pax, cpio, zip, xar, lha, ar, cab, mtree, rar and ISO. Writes tar, pax, cpio, zip, xar, ar, ISO, mtree and shar. Detects compression automatically (gzip, bzip2, lzip, xz, lzma, compress). — [libarchive.org](https://libarchive.org/)
- bsdtar `--zstd` compresses on create; zstd input is detected automatically on read. `--newer-mtime` and `--newer` select files by mtime or ctime in create/append/update, a primitive form of incremental archiving. `--acls`, `--xattrs` and `--mac-metadata` (AppleDouble) are stored on create and restored only when extracting as root. — [bsdtar(1)](https://man.freebsd.org/cgi/man.cgi?query=bsdtar&sektion=1)
- **xz-utils**: 5.8.3 (2026-03-31) fixes CVE-2026-34743, which affects all versions since 5.0.0. The default memory limit for multithreaded mode now respects RLIMIT_DATA, RLIMIT_AS and RLIMIT_VMEM. 5.8.1 fixed CVE-2025-31115 in the multithreaded decoder (5.3.3alpha to 5.8.0) and added an SSE2 decoder speedup of 0-5%. — [xz NEWS (NetBSD mirror)](https://ftp.riken.jp/NetBSD/NetBSD-current/src/external/public-domain/xz/dist/NEWS)
- **zpaq** v7.15 (2016-08-17, last release). Public domain since v7.01; earlier versions were GPLv3. It is a journaling archive: updates append, and old versions can be restored by date or version number. `-until` truncates or rolls back the archive (`-until -1` removes the last update). Dedup uses content-defined fragments averaging 64 KB, hashed with SHA-1. Memory use is about 1 MB per GB to update and 0.5 MB per GB to extract. Five methods: method 1 is fastest and the default; method 2 decompresses as fast as 1. Blocks are 16 MB (method 1) or 64 MB. Encryption is AES-256-CTR with scrypt, and the docs state it provides privacy, not tamper protection. — [zpaq page](https://www.mattmahoney.net/dc/zpaq.html)
- **casync** (LGPL-2.1): combines rsync-style chunking with content-addressable storage. Uses a buzhash rolling hash, SHA512/256 (or SHA256) digests, and zstd (or xz/gzip) per chunk. `.catar` is a reproducible, random-access tar replacement. `.caidx`/`.caibx` are indexes, and `.castr` is a chunk store shared across versions. File boundaries are removed before chunking. `--seed=` reuses local data. Delivery works over HTTP/CDN. Also provides `casync mount`, `mkdev` and `gc`. `verify` and `diff` are still "NOT IMPLEMENTED YET". — [casync GitHub](https://github.com/systemd/casync)

### Inferences
- The license picture for an MIT, self-contained Xipper: libarchive (BSD), zstd/xz (BSD/0BSD-style), zpaq (public domain) and borg (BSD-3) are safe to borrow from or link. DwarFS licensing must be checked (README points to LICENSE/REUSE.toml). dtrx (GPL-3), Ark (GPL-2+), PeaZip (LGPLv3), unar and casync (LGPL) should be used only as idea sources, not code. RAR decompression remains license-encumbered everywhere (ouch, unar).
- The "single folder named after the archive" convention now exists in 7-Zip itself (`-spoc`), dtrx and Nautilus. It has become the expected default.

### Gaps
- **Not researched in this session (time budget)**: Xarchiver, Engrampa, atool, lrzip, pigz/pixz/pzstd, mksquashfs options, and desync. These need a follow-up pass. From background knowledge, unverified here: Engrampa is MATE's File Roller fork; atool wraps per-format tools (`aunpack`, `apack`, `als`); lrzip uses long-range rzip preprocessing; pixz produces indexed, seekable xz; pzstd splits input into independent frames for parallel decompression.
- I found no GTK4 archive manager other than File Roller in GNOME Circle or the core apps.
- ouch smart-unpack behavior (single top-level folder) is not documented in the README fetched.
- gnome-autoar's extraction heuristics are not described on its project page.

---

## 2. Ideas that transfer to a Mac archiver

### Takeaway
High value and cheap: dtrx-style smart extract, signature-based detection with confirmation, recursive nested extraction, encoding autodetection, JSON listing, and atomic "safe writes". High value and large effort: a deduplicating, versioned "snapshot archive" (zpaq/borg/restic model), and a seekable read-only mountable image with similarity ordering (DwarFS model). Xipper already has mount, Merkle signing and PAR2, which fit those models.

### Cited Findings
- **Smart extract**: dtrx extracts into a directory named after the archive. If the archive holds a single entry whose name differs from the archive's, it asks, with modes inside, rename or here. It never overwrites existing directories and picks an alternative name instead. — [dtrx](https://github.com/moonpyk/dtrx)
- **Recursive extraction** of nested archives (`dtrx -r`). — [dtrx](https://github.com/moonpyk/dtrx)
- **Format detection**: ouch chooses the format from extensions. For files with no extension it infers from the file signature and asks the user to confirm. Stdin needs `-f`. — [ouch](https://github.com/ouch-org/ouch)
- **Filename encoding autodetection** with Mozilla universalchardet, plus a manual override. — [unar spec](https://build.opensuse.org/projects/openSUSE/packages/unar/files/unar.spec?expand=0)
- **Versioned archive with rollback**: zpaq appends each update, restores by date or version, and `-until` rolls back. — [zpaq](https://www.mattmahoney.net/dc/zpaq.html)
- **Snapshot model**: a restic snapshot is encrypted JSON with time, root tree, paths, hostname, tags and parent. Metadata edits create a new snapshot that records the `original` ID. — [restic references](https://restic.readthedocs.io/en/latest/100_references.html)
- **Pack files with the index at the end** let blobs stream during write and let contents be indexed by reading only the authenticated header. — [restic references](https://restic.readthedocs.io/en/latest/100_references.html)
- **Mount snapshots** as a filesystem and browse them in a regular file manager (`borg mount`). — [Borg docs](https://borgbackup.readthedocs.io/en/stable/)
- **DwarFS** groups files by similarity, dedups across the image, applies per-category handling (FLAC for PCM audio, skips incompressible data), is multi-threaded, and supports macOS. — [DwarFS README](https://github.com/mhx/dwarfs)
- **Chunk store shared across versions, plus seeding from local data**, for efficient delivery of related images. — [casync](https://github.com/systemd/casync)
- **Atomic extraction**: bsdtar `--safe-writes` writes to a temporary file and renames it into place. — [bsdtar(1)](https://man.freebsd.org/cgi/man.cgi?query=bsdtar&sektion=1)
- **Script export**: PeaZip exports GUI tasks as command-line scripts. — [PeaZip](https://peazip.github.io/peazip-linux.html)
- **Reproducible archives**: casync `.catar` is a reproducible serialization. ouch release builds are reproducible and cosign-signed. — [casync](https://github.com/systemd/casync); [ouch](https://github.com/ouch-org/ouch)
- **Incremental tar**: bsdtar `--newer`/`--newer-mtime` add only changed files. — [bsdtar(1)](https://man.freebsd.org/cgi/man.cgi?query=bsdtar&sektion=1)

### Inferences (Xipper candidate features)
1. **Smart Extract default**: if the archive has one top-level entry, extract it as-is; otherwise create a folder named after the archive. Never overwrite; auto-suffix " 2". Offer the dtrx modes in preferences and CLI (`--one inside|rename|here`).
2. **Recursive extract** for nested archives (tar.gz inside zip, and so on), with a depth limit tied to the bomb guard.
3. **Magic-byte sniffing** when the extension is missing or wrong, with a confirmation prompt like ouch's. Also an "Open With Xipper" path for misnamed files.
4. **Charset detection for legacy ZIP names** (CP437/Shift-JIS/GBK), with a manual picker in the UI. Apple's Archive Utility handles this poorly.
5. **Snapshot archive (versioned XIZ)**: content-defined chunking plus append-only journal plus Merkle root per version. The existing Merkle signing infrastructure gives each snapshot a verifiable root, something zpaq cannot provide since its encryption is "privacy, not tamper protection". Mount any version read-only through the existing mount feature, and roll back like `-until`.
6. **Similarity ordering and per-type categorizers** (DwarFS-style) for a read-only seekable XIZ profile: e.g. FLAC-like coding for audio, store incompressible media.
7. **`--safe-writes` atomic extraction** and JSON listing (`lsar -j`) in the CLI and MCP.
8. **Reproducible archive mode**: fixed mtimes, sorted order, normalized uid/gid. Useful together with signatures.

### Gaps
- No primary-source documentation found on ouch's or Nautilus's single-folder heuristics; only dtrx's is documented.

---

## 3. Numbers: ratio, speed and dedup

### Takeaway
On a highly redundant source tree (47.49 GiB of Perl installs), DwarFS reached a 134.9x ratio (lzma: 153.2x) versus 14.63x for SquashFS and 122.7x for tar.zst, and it built faster. Random reads are much faster than squashfuse. EROFS is optimized for read latency and is often larger than SquashFS at default settings. Backup-tool dedup and speed benchmarks are anecdotal and contradictory.

### Cited Findings
- **DwarFS vs SquashFS vs tar.zst** (author's benchmark, DwarFS 0.14.1):
  - Perl dataset, 47.49 GiB:
    - SquashFS zstd: 3.245 GiB, ratio 14.63, 5m37s
    - DwarFS zstd: 0.352 GiB, ratio 134.9, 5m03s
    - DwarFS lzma: 0.310 GiB, ratio 153.2, 2m13s
    - tar.zst: 0.387 GiB, ratio 122.7, compress 8m06s, decompress 57.2s (DwarFS: 46.5s)
  - Separate run: mkdwarfs 5m23s vs mksquashfs 32m54s, about 447 MB vs 4.7 GB. Block sizes differed (16 MiB vs 128 KiB).
  - Audio (Sonniss, 3.072 GiB): SquashFS 2.711 GiB (1.133x, 19.5s) vs DwarFS with categorize 1.664 GiB (1.846x, 3.98s).
  - Random reads: DwarFS about 20 GiB/s vs squashfuse about 230 MiB/s. Finding 1.9M files: 2.82s vs 5.31s.
  - Parallel `perl -v` on a mounted image is about 6x faster than SquashFS.
  - — [DwarFS README](https://github.com/mhx/dwarfs)
- **EROFS vs SquashFS** (sigma-star 2022, Debian image of about 6.5 GiB):
  - LZ4HC: tar 2.8 GiB, SquashFS 2.7 GiB, SquashFS with 4 KiB blocks 3.4 GiB, EROFS 3.6 GiB.
  - XZ: SquashFS 2.0 GiB vs EROFS 2.7 GiB.
  - Read speed with LZ4: EROFS 30.9 MiB/s vs SquashFS (4 KiB) 18.9 MiB/s.
  - — [sigma-star blog](https://sigma-star.at/blog/2022/07/squashfs-erofs/)
- **EROFS project numbers** with dedup: Wikipedia snapshots EROFS (64k) 988 MiB vs SquashFS (128k) 1110 MiB; versions test 310 vs 312 MiB. The FAQ says fair comparisons need matched settings and `-Efragments`, and that EROFS defaults to LZ4 for lowest decompression latency. — [EROFS dedupe docs](https://erofs.docs.kernel.org/en/latest/comparsion/dedupe.html); [EROFS FAQ](https://erofs.docs.kernel.org/en/latest/faq.html)
- **Kopia compression benchmark** (466.7 MiB compressible file, Ryzen 7):

  | Algorithm | Size | Throughput |
  |---|---|---|
  | s2-default | 127.1 MiB | 4 GiB/s |
  | pgzip | 86.3 MiB | 1.2 GiB/s |
  | zstd | 76.8 MiB | 324 MiB/s |
  | zstd-best | 68.9 MiB | 19.2 MiB/s |
  | gzip-best | 83 MiB | 5.1 MiB/s |

  s2 used about 2.1 MiB of memory vs 220-282 MiB for pgzip. Chunk splitting costs some ratio: s2 28.56% vs 25.59% standalone; gzip 18.81% vs 17.27%. Kopia has dropped LZ4. — [Kopia compression docs](https://www.kopia.io/docs/advanced/compression/)
- **Chunking parameters**:
  - restic: Rabin fingerprints, 64-byte window, 512 KiB min, 8 MiB max, about 1 MiB average, files under 512 KiB not split, random polynomial per repository. — [restic references](https://restic.readthedocs.io/en/latest/100_references.html)
  - kopia: default splitter DYNAMIC-4M-BUZHASH. — [Kopia docs](https://www.kopia.io/docs/advanced/compression/)
  - zpaq: about 64 KB average fragments. — [zpaq](https://www.mattmahoney.net/dc/zpaq.html)
  - casync: buzhash. — [casync](https://github.com/systemd/casync)
- **Backup speed and dedup comparisons are inconclusive**: borg and restic were nearly tied on a first backup of random data, and Kopia's speed claims conflict within the same site. A forum user found borg dedups better than Kopia defaults, and that DYNAMIC-1M-BUZHASH dedups better than 4M at some speed cost. — [computingforgeeks](https://computingforgeeks.com/borg-restic-kopia-comparison/); [Kopia forum](https://kopia.discourse.group/t/deduplication-efficiency/1298). The most rigorous harness found is deajan/backup-bench. — [backup-bench](https://awesome.ecosyste.ms/projects/github.com%2Fdeajan%2Fbackup-bench)
- 7-Zip huge pages give about 10% faster LZMA/XZ compression on Linux. — [Phoronix](https://phoronix.com/news/7-Zip-26.01)

### Inferences
- For Xipper's XIZ, DwarFS shows that whole-image similarity ordering plus large blocks plus dedup beats per-file or small-block approaches by an order of magnitude on redundant trees. It also shows that a fast random-access index can coexist with that ratio.
- An average chunk size of 64 KB to 1 MB is the dedup sweet spot across these tools. Smaller chunks dedup better but need more index memory: zpaq is about 1 MB of RAM per GB at 64 KB chunks.
- An s2/LZ4-class fast codec plus a zstd "high" setting covers most of the speed-versus-ratio space. On macOS, Apple's LZFSE/LZ4 in Compression.framework fills the fast slot.
- Huge pages are an analogue for Xipper on macOS (superpages via `VM_FLAGS_SUPERPAGE_SIZE_2MB` on Intel; Apple Silicon uses 16K pages), but this is unverified for ARM64.

### Gaps
- No independent, recent restic/borg dedup-ratio numbers on a standard dataset. Forum anecdotes only.
- pigz/pzstd/pixz/xz -T scaling numbers were not collected.
- DwarFS numbers come from its author; no independent replication was found.
- No DwarFS-vs-EROFS head-to-head.

---

## 4. Security: path traversal, symlinks, zip bombs

### Takeaway
bsdtar is the reference model. By default it strips leading `/`, refuses `..`, and refuses to write through intermediate symlinks unless `-U`/`-P` is given. It skips owner, xattr and ACL restore for non-root users and offers atomic `--safe-writes`. For overlapping-entry zip bombs, the reference fix is Mark Adler's "covered spans" check in Info-ZIP (CVE-2019-13232). Front-ends that parse CLI output (File Roller) keep producing CVEs.

### Cited Findings
- bsdtar defaults: the leading `/` is removed; entries with `..` are not extracted. If the final path element is a symlink it is replaced, intermediate symlinks are refused unless `-U`, and `-P` disables all checks. The man page advises listing before extracting, using `-k` to avoid overwriting, and not extracting as root. — [bsdtar(1)](https://man.freebsd.org/cgi/man.cgi?query=bsdtar&sektion=1)
- bsdtar skips ownership, xattrs and ACLs by default when not root. `--safe-writes` gives atomic temp-file plus rename. — [bsdtar(1)](https://man.freebsd.org/cgi/man.cgi?query=bsdtar&sektion=1)
- dtrx extracts into a fresh directory by default, which contains tarbombs. It never overwrites existing directories, and it normalizes permissions so the owner can read and write. — [dtrx](https://github.com/moonpyk/dtrx)
- **CVE-2019-13232** ("better zip bomb", overlapping entries, CWE-400): the fix tracks covered byte spans. The central directory and any leading bytes start as covered. An entry whose start offset falls in a covered span causes rejection. A special case avoids false positives for a misplaced central directory. It references David Fifield's analysis. — [Debian tracker](https://security-tracker.debian.org/tracker/CVE-2019-13232); [Alpine patch](https://git-old.alpinelinux.org/aports/plain/main/unzip/CVE-2019-13232.patch?h=v3.10.5)
- File Roller CVE-2026-78322 was fixed by checking line length when parsing command output. — [SUSE PackageHub](https://packagehub.suse.com/packages/file-roller/)
- xz CVE-2026-34743 affects all versions since 5.0.0, fixed in 5.8.3. CVE-2025-31115 was in the multithreaded decoder. — [xz NEWS](https://ftp.riken.jp/NetBSD/NetBSD-current/src/external/public-domain/xz/dist/NEWS)
- zpaq encryption provides privacy but not tamper protection. restic authenticates every file (AES-256-CTR plus Poly1305-AES, scrypt KDF). borg uses AES-256 plus HMAC-SHA256. — [zpaq](https://www.mattmahoney.net/dc/zpaq.html); [restic](https://restic.readthedocs.io/en/latest/100_references.html); [Borg](https://borgbackup.readthedocs.io/en/stable/)
- ouch ships cosign-signed, reproducible binaries. — [ouch](https://github.com/ouch-org/ouch)

### Inferences (checklist for Xipper)
- Adopt bsdtar semantics as the default for every format, not only tar:
  - strip absolute paths and refuse `..`;
  - never follow an intermediate symlink created by the archive itself. On macOS, use `openat` with `O_NOFOLLOW` and a dirfd chain, or `O_NOFOLLOW_ANY` on macOS 11+;
  - clamp setuid/setgid bits;
  - restore xattrs selectively, and decide policy on `com.apple.quarantine` propagation.
- Zip bomb guard, three layers:
  - overlapping-span detection (the Adler algorithm);
  - a ratio/size budget enforced during streaming, not trusted from headers;
  - a nesting-depth limit for recursive extract.
- Use atomic temp-file plus rename writes during in-place archive editing and extraction, matching `--safe-writes`.
- Xipper links libraries in-process rather than parsing CLI output, which avoids the File Roller class of bugs. Track xz/zstd/libarchive CVEs in vendored copies (libarchive 3.8.11, xz 5.8.3 or newer).
- Xipper's authenticated encryption and Merkle signing already exceed zpaq and match restic/borg. Worth stating in marketing.

### Gaps
- 7-Zip's and libarchive's handling of overlapping-entry zip bombs was not confirmed in this session.
- ouch's path-traversal and symlink policy is not documented in its README.
- No source checked on Ark's or PeaZip's traversal protections.
