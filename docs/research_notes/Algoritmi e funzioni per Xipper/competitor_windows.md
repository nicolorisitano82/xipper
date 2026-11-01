# Windows archivers as a competitive benchmark for Xipper (as of Nov 2026)

Scope: 7-Zip, NanaZip, WinRAR 7.x, PeaZip, Bandizip, WinZip 29/30, Windows 11 built-in archiving, PowerArchiver (IZArc not researched: no current release activity found, so it is low priority).

How these notes were made: about 16 search and fetch calls. The primary changelogs were read through a summarising fetch tool: 7-zip.org history.txt, rarlab rarnew.htm, PeaZip changelog, Bandisoft history, NanaZip ReleaseNotes.md. Where a version number or CVE comes only from that tool's summary, the report writer should spot-check it against the source before quoting it verbatim. The official WinZip "what's new" and "features" URLs returned 404.

Xipper baseline (from the brief): ZIP, 7z, tar variants, Apple Archive and XIZ creation; RAR/RAR5 reading, including encrypted archives; in-place editing; PAR2; mounting an archive as a read-write volume; multi-volume; AES; signed archives; Windows-safe names; actionable error remedies; Finder and QuickLook extensions; CLI; MCP server.

---

## 1. Algorithms and formats: create vs extract

### Takeaway
On formats, the Windows field has moved little since 2024. The real differentiators are a handful of proprietary or niche codecs:
- WinRAR: RAR5 with dictionaries up to 64 GB, plus recovery records and volumes.
- WinZip: Zipx "Best method", with lossless JPEG/MP3/WavPack recompression.
- PeaZip: create ZPAQ, Brotli, Zstd, PEA, ARC, WIM.
- NanaZip: extra codecs Zstd, Brotli, LZ4, Lizard, LZ5.
- PowerArchiver: the .PA codec chains.
- 7-Zip: ARM64 and RISCV executable filters in 7z and xz.

Windows 11 now creates 7z and tar natively, but without encryption.

### Cited findings

**7-Zip (Igor Pavlov; free, LGPL with unRAR restriction)**
- 23.00 (2023-05-07): new ARM64 filter for 7z and xz. Before compressing an .exe or .dll, 7-Zip parses it and picks BCJ, BCJ2 or ARM64 per file. The BCJ2 section limit rose from 64 MiB to 240 MiB. — [7-Zip history.txt](https://www.7-zip.org/history.txt)
- 24.01 (2024-01-31): Zstandard decoding for .zst, and for ZST inside ZIP, SquashFS and RPM. Adds XXH64. Opens RAR archives whose dictionary exceeds 4 GB (WinRAR 7.00), and DMG with XZ (ULMO) and LZMA. — [7-Zip history.txt](https://www.7-zip.org/history.txt)
- 24.03 (2024-03-23): RISCV filter for 7z and xz. ARM64 LZMA/LZMA2 decompression is 20–60% faster. Adds the `-smemx` RAR memory limit, which prompts when a RAR needs more than 4 GB. — [7-Zip history.txt](https://www.7-zip.org/history.txt)
- 24.05 (2024-05-14): `-myv=MMNN` targets a minimum decoder version when creating 7z. `-myfa` and `-myfd` allow or disallow filters. — [7-Zip history.txt](https://www.7-zip.org/history.txt)
- 24.09 (2024-11-29): larger default LZMA/LZMA2 dictionaries. Adds SHA-512, SHA-384, SHA3-256 and MD5 hashing. Fixes Zone.Identifier propagation from nested archives. — [7-Zip history.txt](https://www.7-zip.org/history.txt)
- 25.00 (2025-07-05): compression and benchmark can use more than 64 threads on Windows. bzip2 compression is 15–40% faster. Security fixes CVE-2025-11001/11002 (symlinks) and CVE-2025-53816 (RAR). — [7-Zip history.txt](https://www.7-zip.org/history.txt)
- 25.01 (2025-08-03): safer symlink extraction (CVE-2025-55188). The `-snld20` switch bypasses the check. — [7-Zip history.txt](https://www.7-zip.org/history.txt)
- 26.00 (2026-02-12) to 26.05 (2026-10-21): mainly hardening, with many CVEs across the SquashFS, NTFS, UDF, WIM, XZ and other handlers. 26.01 uses Linux huge pages for about 10% faster LZMA compression and adds `-spo` output-path modes. 26.02 fixes an XZ heap overflow (RCE). 26.03 fixes a Mark-of-the-Web bypass with crafted archives (CVE-2026-58052). — [7-Zip history.txt](https://www.7-zip.org/history.txt) *(the CVE numbers come from the fetch summary; verify before quoting)*
- Zstd is extract-only in mainline 7-Zip: 24.01 added decoding but not encoding. Forks (NanaZip, 7-Zip-zstd) add encoding. — [7-Zip history.txt](https://www.7-zip.org/history.txt); [NanaZip ReleaseNotes](https://raw.githubusercontent.com/M2Team/NanaZip/main/Documents/ReleaseNotes.md)

**NanaZip (M2Team; MIT/7-Zip-derived, distributed through the Microsoft Store)**
- Extra codecs on top of 7-Zip:
  - 1.0: Zstandard (from the 7-Zip-zstd branch).
  - 2.0: LZ4 and BLAKE3.
  - 3.0: Brotli.
  - 5.0: Lizard and LZ5.
  - 7.0: drops the unmaintained Fast-LZMA2 encoder and rewrites the Zstd encoder.
  - Latest: 7.0 (2610.2, build 7.0.1882.0).
  — [NanaZip ReleaseNotes](https://raw.githubusercontent.com/M2Team/NanaZip/main/Documents/ReleaseNotes.md)
- Hashes:
  - 2.0: the RHash family (AICH, BLAKE2b, BTIH, ED2K, GOST, SHA-3, Tiger, TTH, Whirlpool) and XXH3.
  - 3.0: SM3.
  - 7.0: SHA512/224, SHA512/256, SHAKE128/256.
  — [NanaZip ReleaseNotes](https://raw.githubusercontent.com/M2Team/NanaZip/main/Documents/ReleaseNotes.md)
- Read-only formats added in 5.0: UFS/UFS2, ROMFS, ZealFS, WebAssembly, Electron ASAR, littlefs, and .NET single-file bundles. — [NanaZip ReleaseNotes](https://raw.githubusercontent.com/M2Team/NanaZip/main/Documents/ReleaseNotes.md)
- 6.0 (6.0.1632.0): requires Windows 10 2004 or later, drops x86, adds extract-on-open. Synced with 7-Zip 26.01 in 6.0 Update 6. — [NanaZip ReleaseNotes via search](https://raw.githubusercontent.com/M2Team/NanaZip/main/Documents/ReleaseNotes.md)

**WinRAR 7.x (RARLAB; trialware)**
- 7.00 (final around Feb/Mar 2024):
  - Dictionaries above 1 GB, up to 64 GB depending on RAM. Archives with a dictionary over 4 GB need WinRAR 7 or newer to unpack.
  - Long-range search and exhaustive search (`-mcx`).
  - Paths up to 65,535 characters.
  - RAR4 creation removed; RAR4 extraction remains.
  - "Propagate Mark of the Web" settings.
  - `-ol-` to block symlinks; `-mdx` to limit the extraction dictionary.
  — [RARLAB What's new](https://www.rarlab.com/rarnew.htm); date: [BetaNews 2024-03-03](https://betanews.com/2024/03/03/winrar-7-0-boosts-compression-ratios-with-support-for-larger-dictionary-sizes)
- 7.10: dark mode; large memory pages (`-mlp`); MotW "zone value only" and the `-om` switch; MotW applied to nested archives; drops 32-bit Windows; supports up to 64 logical CPUs across processor groups. — [RARLAB What's new](https://www.rarlab.com/rarnew.htm)
- 7.12 and 7.13: two separate directory-traversal fixes. The 7.12 issue was reported via ZDI, the 7.13 issue by ESET. 7.13 was released 2025-07-30. — [RARLAB What's new](https://www.rarlab.com/rarnew.htm); [search result summary citing release date](https://www.neowin.net/software/winrar-720-final/)
- 7.20 (around Feb 2026): faster deletion from solid archives; extended `-ag` name masks; faster opening of large archives and faster TAR extraction. — [RARLAB What's new](https://www.rarlab.com/rarnew.htm); [Forest Watch](https://forest.watch.impress.co.jp/docs/news/2121981.html)
- 7.21: detects archives whose extension does not match their real format, for example a RAR renamed to .zip. — [RARLAB What's new](https://www.rarlab.com/rarnew.htm)
- 7.23 (2026-06-30): fixes a heap overflow in RAR5 recovery-volume reconstruction and a symlink-escape issue; updates the 7z library. — [AlternativeTo news](https://alternativeto.net/news/2026/6/winrar-7-23-fixes-security-vulnerabilities-updates-7z-library-and-enhances-version-display/); [RARLAB What's new](https://www.rarlab.com/rarnew.htm)
- 7.30 beta 1 and 2 (Oct 2026):
  - TAR sparse files (GNU and PAX).
  - NTFS alternate data stream output.
  - `-lim` to cap disk writes, memory and runtime.
  - `-da` to delete the archive after a successful extraction.
  - Limits on REV recovery (4,096 total or 1,024 missing volumes).
  - Hard links blocked; MotW applied to links.
  — [RARLAB What's new](https://www.rarlab.com/rarnew.htm); [Deskmodder 2026-10-21](https://www.deskmodder.de/blog/2026/10/21/winrar-7-30-kann-ausprobiert-werden/)
- Older but relevant: Zstandard extraction for .zst and .zipx (6.10); ARM64 filter in XZ extraction (6.23); `-ams`/`-amr` to save and restore the archive name and time (6.20). — [RARLAB What's new](https://www.rarlab.com/rarnew.htm)
- WinRAR creates RAR and ZIP. It extracts CAB, ARJ, LZH, TAR, GZ, UUE, ISO, BZ2, Z and 7z. It applies automatic multimedia, executable and object-library filters, and offers AES-256 and "authenticity signatures". — [win-rar.com features](https://www.win-rar.com/features.html)

**PeaZip (Giorgio Tani; LGPLv3; Windows, Linux, macOS)**
- Creates 7Z, ARC, Brotli, BZ2, GZ, PEA, TAR, WIM, Zstd and ZIP. Creates RAR only if WinRAR is installed. Opens more than 200 formats, including ACE (via a plugin), DMG, ISO, PAQ, UDF and ZIPX. — [peazip.github.io](https://peazip.github.io/)
- The changelog also lists ZPAQ and XZ creation, and tar.* combinations. — [PeaZip changelog](https://peazip.github.io/changelog.html)
- Version history:
  - 10.0 (2024-10-26): UI revamp; checksums saved in GNU coreutils format; 234 openable extensions. — [Linuxiac](https://linuxiac.com/peazip-10-0-file-archiver-debuts-revamped-interface/)
  - 10.8.0 (2025-12-06): Brotli 1.2.0. — [PeaZip changelog (raw)](https://raw.githubusercontent.com/peazip/peazip.github.io/master/changelog.html)
  - 11.0.0 (2026-04-06): batch archive testing; archive pre-parsing up to 94% faster on very large archives. — [PeaZip changelog](https://peazip.github.io/changelog.html)
  - 11.2.0 (2026-07-12): .ZIM (Zeno Improved) read support. — [PeaZip changelog](https://peazip.github.io/changelog.html)
  - 11.4.0 (2026-10-17, latest): bundles 7z 26.04 and Pea 1.34; 243 openable extensions. — [PeaZip changelog](https://peazip.github.io/changelog.html)
- PeaZip notes that WinZip's custom WavPack, MP3 and JPEG Zipx filters are not supported, for either reading or writing. — [PeaZip zipx page (via search)](https://peazip.github.io/zipx-file-format.html)

**Bandizip (Bandisoft; free with ads, plus Professional and Enterprise)**
- Creates ZIP, 7Z (LZMA2), ZIPX (XZ), EXE (SFX), TAR, TGZ, LZH (LH7), ISO (Joliet), GZ and XZ. Extracts more than 40 formats; ZPAQ is extract-only. Runs on x86, x64 and ARM64. A separate macOS product exists. — [Bandizip product page](https://en.bandisoft.com/bandizip/)
- Changelog highlights:
  - 7.31 (2023-08-30): 7z ARM64 filter; BandiView becomes the internal image viewer; SFX "run as admin".
  - 7.33 (2024-05-09): RAR7 decompression.
  - 7.36 (2024-06-24): LZ4 decompression.
  - 7.37 (2025-02-11): ADS in RAR5.
  - 7.40 (2025-09-10): symlinks in 7z; fix for CVE-2025-8088 (RAR ADS).
  - 7.42 to 7.47 (Apr–Oct 2026): many vulnerability, MotW and AMSI fixes. Latest is 7.47 (2026-10-13).
  — [Bandizip history](https://www.bandisoft.com/bandizip/history/)
- I found no "high-speed archive" (.bz / parallel format) entry in the 7.30–7.47 changelog. Only ZIP parallel *extraction* appears, added in 7.20, disabled in 7.35 and fixed in 7.36. — [Bandizip history](https://www.bandisoft.com/bandizip/history/)

**WinZip (Corel/Alludo; paid)**
- Zipx "Best method" is the default for .zipx. It picks a method per file type: JPEG recompression for JPG, MP3 and WavPack for audio, and XZ, LZMA or PPMd for others. JPEG, MP3 and WavPack cannot be chosen manually. The manual choices are Best, BZip2, LZMA, PPMd, XZ and Zstd. Recipients need WinZip 12.1 or later. — [Corel KB 125880](https://kb.corel.com/125880); [Corel KB 125951](https://kb.corel.com/125951); [Corel KB 125889](https://kb.corel.com/125889)
- WinZip 30 was released 2026-01-28. Changes: European Accessibility Act compliance, faster startup and performance, improved file associations for archive and image formats. — [Forest Watch (Impress)](https://forest.watch.impress.co.jp/docs/news/2081797.html)

**Windows 11 built-in (libarchive)**
- Read support for RAR, 7z, tar, tar.gz/bz2/zst/xz, tgz and txz was announced at Build 2023. It shipped in the Sept–Oct 2023 cumulative updates; one report names the KB5031455 preview (22621.2506). Password-protected archives are not supported. — [TweakTown](https://www.tweaktown.com/news/94114/windows-11-can-now-open-rar-7-zip-and-other-compressed-files-natively-but-theres-catch/index.html); [Engadget](https://www.engadget.com/windows-11-finally-gets-native-rar-support-192034673.html); [Pureinfotech](https://pureinfotech.com/window-11-extract-rar-7zip-archival-formats/)
- Creation: Canary build 25992 added "Compress to → 7z / TAR" next to ZIP, plus an "Additional options" wizard for format, method and level. It reached stable in 24H2. No password or encryption. — [Pureinfotech](https://pureinfotech.com/windows-11-create-7-zip-tar-archive-files/); [Winaero](https://winaero.com/windows-11-now-supports-7z-and-tar-archive-creation)

**PowerArchiver (ConeXware; paid)**
- The ".PA" Advanced Codec Pack picks codec and filter chains automatically per extension set, with manual tuning available. It is included in licences bought for PowerArchiver 2017 and later. — [PowerArchiver site](https://www.powerarchiver.com/?p=7959); [PA forum](https://forums.powerarchiver.com/post/36962)
- Creates and opens ZIPX. — [PowerArchiver ZIPX page](https://www.powerarchiver.com/de/?p=609)
- The latest version found is 22.10.02 (2025-04-12), but that comes from a third-party listing only. — [PCWelt](https://www.pcwelt.de/?p=1135031)

### Inferences
- Xipper already covers what Windows 11 offers (7z, tar, ZIP creation) and adds encryption, which the Windows built-in lacks.
- The main create-side codec gaps compared with Windows tools:
  1. An executable branch filter (ARM64/BCJ) that is applied automatically per file. The Mach-O/ARM64 analogue matters for macOS app bundles.
  2. Zstd, Brotli and LZ4 inside 7z (as NanaZip and PeaZip do).
  3. Content-specific lossless recompression for JPEG and audio (WinZip). On macOS the obvious modern equivalents would be packJPG/Lepton-style JPEG or JPEG XL lossless transcoding (a design idea, not a sourced feature).
  4. Very large dictionaries with long-range matching (WinRAR 7, up to 64 GB).
  5. ZPAQ, WIM, ARC and PEA creation (PeaZip), which are niche.
- Mainline 7-Zip *extracts* Zstd but does not create it, so Xipper's XIZ and Zstd story is not behind the market leader.

### Gaps
- No official WinZip 29/30 feature list was retrievable (404s). Whether WinZip 30 creates 7z, and what it does with RAR, is unconfirmed here.
- Bandizip's proprietary high-speed format: earlier Bandizip versions have a "high speed archiving" option, but I found no citation for its current status.
- I did not fetch WinRAR's help pages on the RAR5 "locator" record (which speeds up locating the recovery record and quick-open data) or on the quick-open settings, so details are unsourced here. WinRAR's recovery record and recovery volumes (.rev) are well known, and are indirectly confirmed by the 7.12, 7.23 and 7.30 changelog items on recovery-volume testing and limits.

---

## 2. Distinctive features (repair, recovery, smart extract, preview, cloud, SFX, hashes, secure delete, backup, CLI, malware scan, MotW)

### Takeaway
The features that Windows users actually cite, and Xipper partly lacks:
- Archive repair and recovery records (WinRAR's native recovery records; Bandizip Pro's ZIP repair).
- Smart Extraction, i.e. "extract here, and create a folder only if needed" (NanaZip, Bandizip, 7-Zip).
- Password managers (PeaZip, Bandizip Pro).
- Password recovery (Bandizip Pro).
- Thumbnail and image preview inside archives (Bandizip Pro, PeaZip).
- Antimalware or AMSI scanning before extraction (Bandizip, WinZip).
- Hash tools with many algorithms (7-Zip, NanaZip, PeaZip).
- Secure delete and duplicate finder (PeaZip).
- Export of a GUI task as a CLI script (PeaZip).
- Benchmark (7-Zip, WinRAR).
- Rigorous Mark-of-the-Web propagation (all of them, and a constant CVE source).

### Cited findings
- **Mark-of-the-Web propagation:**
  - 7-Zip: `-snz` (since 22.00); 24.09 fixes MotW for nested archives; 26.03 fixes a MotW bypass. — [7-Zip history.txt](https://www.7-zip.org/history.txt)
  - WinRAR: 7.00 adds configurable MotW propagation; 7.10 adds "zone value only", `-om` and nested-archive MotW; 7.30 adds MotW on links. — [RARLAB What's new](https://www.rarlab.com/rarnew.htm)
  - NanaZip: 6.0 adds registry policy for MotW enforcement. — [NanaZip ReleaseNotes](https://raw.githubusercontent.com/M2Team/NanaZip/main/Documents/ReleaseNotes.md)
  - Bandizip: repeated MotW fixes in 7.37–7.47, including CVE-2025-33027. — [Bandizip history](https://www.bandisoft.com/bandizip/history/)
- **Smart and auto extract:**
  - NanaZip: Smart Extraction since 5.0; extract-on-open in 6.0; an "extract all automatically" policy for executables (6.0 preview). — [NanaZip ReleaseNotes](https://raw.githubusercontent.com/M2Team/NanaZip/main/Documents/ReleaseNotes.md); [warp2search](https://www.warp2search.net/story/nanazip-60-preview-1-6014610-released/)
  - WinRAR: 7.30 beta adds `-da` to delete the archive after a successful extraction. — [RARLAB What's new](https://www.rarlab.com/rarnew.htm)
- **Repair, password, preview and scan features (Bandizip):**
  - Free for all users: multi-core compression ("up to 6x"), editing inside archives, integrity test.
  - Professional only: Password Manager; ZIP Repair Archive; Password Recovery (brute force); Image Preview in Archive (thumbnails); Antimalware Scan on Archive (whether this one is Pro-only is ambiguous on the page).
  — [Bandizip product page](https://en.bandisoft.com/bandizip/)
  - 7.42 fixes AMSI scanning, which confirms the AMSI integration exists. — [Bandizip history](https://www.bandisoft.com/bandizip/history/)
- **PeaZip:**
  - Secure delete.
  - Two-factor encryption: password plus keyfile.
  - Encrypted password manager. 11.3.0 makes a master password mandatory; 11.0.0 adds a password entropy rating.
  - Many checksum and hash algorithms.
  - Archive conversion and a duplicate finder.
  - Export of GUI tasks as command-line scripts.
  - Batch testing (11.0) and a PEA test mode (11.3).
  — [peazip.github.io](https://peazip.github.io/); [PeaZip changelog](https://peazip.github.io/changelog.html)
  - 10.8 expanded archive preview and added thumbnail and text viewers; 10.9 improved the image viewer. — [Softantenna](https://softantenna.com/softwares/4309-peazip); [PeaZip changelog (raw)](https://raw.githubusercontent.com/peazip/peazip.github.io/master/changelog.html)
- **Hash tools:**
  - 7-Zip context-menu hashes include XXH64, BLAKE2sp, SHA-512/384, SHA3-256 and MD5 (24.03, 24.09). — [7-Zip history.txt](https://www.7-zip.org/history.txt)
  - NanaZip adds BLAKE3 with assembly acceleration, the RHash set, SM3 and SHAKE. — [NanaZip ReleaseNotes](https://raw.githubusercontent.com/M2Team/NanaZip/main/Documents/ReleaseNotes.md)
- **Benchmark:** 7-Zip's benchmark handles more than 64 threads (25.00, 26.00). WinRAR's benchmark thread control arrived in 7.00. — [7-Zip history.txt](https://www.7-zip.org/history.txt); [RARLAB What's new](https://www.rarlab.com/rarnew.htm)
- **WinRAR extraction resource caps and format sniffing:** 7.30 beta adds `-lim`, which caps disk writes, memory and time, as zip-bomb protection. 7.21 detects mismatched extensions. — [RARLAB What's new](https://www.rarlab.com/rarnew.htm)
- **SFX:** WinRAR's SFX sets an environment variable with the archive name (7.20). Bandizip offers SFX creation, with a "run as administrator" option (7.31). — [RARLAB What's new](https://www.rarlab.com/rarnew.htm); [Bandizip history](https://www.bandisoft.com/bandizip/history/)
- **Security hardening as a feature:** NanaZip 2.0 enabled CFG, CET Shadow Stack, EH Continuation and blocking of remote DLL loads. — [NanaZip ReleaseNotes](https://raw.githubusercontent.com/M2Team/NanaZip/main/Documents/ReleaseNotes.md)
- **Symlink, hard-link and path-traversal hardening** dominates 2025–2026 changelogs across 7-Zip (25.00, 25.01), WinRAR (7.12, 7.13, 7.23, 7.30) and Bandizip (7.42–7.47). — sources above
- **WinZip:** a retailer listing claims scanning of encrypted and unencrypted zips before extraction, against malware and ransomware. This was not confirmed for v30. — [search summary of retailer listing](https://www.connection.com/product/corel-corp.-winzip-30-standard-license-100-999/lcwz30stdml3/42065258)

### Inferences
These are features Xipper apparently lacks compared with the Windows tools, ranked by how often competitors offer them:
1. **Smart Extraction**, i.e. create a folder only when the archive has several roots, plus "extract on open" and "delete archive after extract" (NanaZip, Bandizip, WinRAR `-da`).
2. **Archive repair** for damaged ZIP/7z without PAR2: rebuilding the central directory, as in WinRAR "Repair" and Bandizip Pro. PAR2 covers prevention but not repair of already-broken plain ZIPs.
3. **Native in-format recovery record.** WinRAR embeds one in RAR5; Xipper uses external PAR2. One option is embedding PAR2-like data inside XIZ.
4. **Password manager** for frequently used passwords, ideally Keychain-backed on macOS (PeaZip, Bandizip Pro).
5. **Thumbnail and image preview inside archives**, plus an image viewer (Bandizip Pro and BandiView, PeaZip). QuickLook partially covers this.
6. **Pre-extraction malware scan.** The macOS analogues would be XProtect/Gatekeeper triggers, or a ClamAV hook. Windows tools use AMSI.
7. **Hash tool UI** with BLAKE3, XXH3, SHA-3 and so on, and GNU-format checksum export (NanaZip, PeaZip).
8. **Benchmark tool** (7-Zip, WinRAR).
9. **Secure delete after archiving**, and a duplicate finder (PeaZip). On APFS SSDs secure delete is of limited value, so it may not be worth copying.
10. **Export a GUI job as a CLI script** (PeaZip). Xipper's CLI and MCP server could expose "copy as command".
11. **Extraction resource limits** (WinRAR `-lim`) and **extension/format mismatch detection** (WinRAR 7.21).
12. **Password recovery / brute force** (Bandizip Pro). This is legally neutral but niche.
13. **The quarantine attribute** (`com.apple.quarantine`) is the macOS counterpart of MotW. Competitors treat propagation into nested archives and links as a security feature, and it is a recurring CVE category. Xipper should state its propagation policy explicitly.

### Gaps
- Cloud upload: WinZip has historically integrated cloud services such as Dropbox, Google Drive and OneDrive, but I could not retrieve an official page for v29/30.
- Scheduled backups: WinZip and PowerArchiver have historically offered backup scheduling. Not verified in this session.
- I did not verify these WinZip features from primary sources this session: PDF and image tools, shredding, Zip repair.
- IZArc: not researched. It shows no evidence of an active 2025–2026 release.

---

## 3. Pricing, licensing, and user-perceived strengths and weaknesses

### Takeaway
The free open-source tools (7-Zip, NanaZip, PeaZip) set user expectations. The paid tools justify their price with proprietary formats (RAR5, Zipx), recovery and repair, and convenience features: password manager, preview, scanning. Reviewers in 2026 say 7-Zip is the default, NanaZip is the modern Windows 11 face of 7-Zip, PeaZip is the power-user and cross-platform tool, and WinRAR is for RAR workflows.

### Cited findings
- 7-Zip is called "the safest default recommendation" for replacing WinZip and WinRAR. NanaZip keeps full 7-Zip compatibility with better Windows 11 context-menu integration; one user called it "a lot faster UI-wise than Peazip". PeaZip is the best fit for users who want more tools and cross-platform support, but its many options can overwhelm casual users. WinRAR is the "specialist choice for RAR/RAR5" and is trialware. — [compresto.app comparison](https://compresto.app/blog/nanazip-vs-peazip); [compresto.app best ZIP programs](https://compresto.app/blog/best-zip-program); [MakeTechEasier](https://maketecheasier.com/best-free-file-archivers-windows)
- WinRAR: a single licence covers all languages and platforms, with a 40-day trial. — [win-rar.com features](https://www.win-rar.com/features.html)
- After 7.23, WinRAR thanked users for paying, a nod to the "nobody pays for WinRAR" meme. — [Dexerto](https://www.dexerto.com/entertainment/winrar-releases-new-update-and-says-its-thanks-to-people-finally-paying-3381350/); [tbreak](https://tbreak.com/winrar-7-23-released-meme-software-update/)
- Bandizip: the free edition is ad-supported but may be used commercially. Professional is a paid upgrade that unlocks the password manager, repair, password recovery, image preview and (possibly) the antimalware scan. Enterprise is a separate edition. Prices were not shown on the page. — [Bandizip product page](https://en.bandisoft.com/bandizip/)
- PeaZip: LGPLv3, free. — [peazip.github.io](https://peazip.github.io/)
- NanaZip: free through the Microsoft Store. In 6.0 it moved to a community-driven development model. — [NanaZip ReleaseNotes](https://raw.githubusercontent.com/M2Team/NanaZip/main/Documents/ReleaseNotes.md)
- WinZip: paid Standard, Pro and Enterprise editions, sold by resellers per user. — [Connection reseller listing](https://www.connection.com/product/corel-corp.-winzip-30-standard-license-100-999/lcwz30stdml3/42065258); [Bechtle](https://www.bechtle.com/de-en/shop/product-family/winzip--0501JV001--f)
- PowerArchiver: paid, with .PA tied to licences from 2017 onward. A third-party listing describes it as a trial version. — [PA forum](https://forums.powerarchiver.com/post/36962); [PCWelt](https://www.pcwelt.de/?p=1135031)
- Windows 11 built-in: free, but its main limitation for users is the lack of encrypted archives (neither create nor extract). — [Pureinfotech](https://pureinfotech.com/windows-11-create-7-zip-tar-archive-files/); [TweakTown](https://www.tweaktown.com/news/94114/windows-11-can-now-open-rar-7-zip-and-other-compressed-files-natively-but-theres-catch/index.html)

### Inferences

**Per-product feature matrix** (Y = yes, R = read/extract only, P = paid tier only, – = no or not found). It is built from the findings above, and cells marked "?" are unverified.

| Feature | 7-Zip | NanaZip | WinRAR 7 | PeaZip | Bandizip | WinZip 30 | Win11 | PowerArchiver | Xipper |
|---|---|---|---|---|---|---|---|---|---|
| Create ZIP / 7z | Y/Y | Y/Y | Y/R | Y/Y | Y/Y | Y/? | Y/Y | Y/Y? | Y/Y |
| Create RAR5 | – | – | Y | via WinRAR | – | – | – | ? | – (read) |
| Zstd in archives (create) | R | Y | R | Y | – | Y (zipx) | tar.zst R | ? | ? (XIZ) |
| Brotli / LZ4 / Lizard | – | Y | – | Brotli Y | LZ4 R | – | – | ? | ? |
| ZPAQ create | – | – | – | Y | R | – | – | – | – |
| JPEG/WavPack recompression | – | – | – | – (R no) | – | Y (zipx) | – | .PA? | – |
| ARM64 / RISCV exe filter | Y (23.00, 24.03) | Y | R (XZ) | via 7z | R | – | – | ? | ? |
| Huge dictionary / long-range | 7z LZMA2 | same | Y (64 GB) | via 7z | – | – | – | – | ? |
| Embedded recovery record | – | – | Y | – | – | – | – | – | PAR2 (external) |
| Archive repair | – | – | Y | – | P (ZIP) | ?(hist.) | – | Y? | – |
| AES encryption | Y | Y | Y | Y + keyfile | Y | Y | – | Y | Y |
| Signed / authenticated archives | – | – | Y (authenticity) | – | – | ? | – | – | Y |
| Edit in place | partial | partial | Y | Y | Y | Y | – | Y | Y |
| Mount as volume | – | – | – | – | – | – | Explorer folder view | Y? (PA mount, unverified) | Y (R/W) |
| Smart extract / extract-on-open | partial | Y (5.0/6.0) | – (`-da`) | Y? | Y | ? | – | ? | ? |
| Password manager | – | – | Y (organize passwords) ? | Y | P | ? | – | ? | – |
| Password recovery | – | – | – | – | P | – | – | – | – |
| Preview/thumbnails in archive | – | – | viewer | Y (10.8) | P + BandiView | Y (image tools) | – | ? | QuickLook |
| Malware scan (AMSI/AV) | – | – | AV hook (hist.) | – | Y (AMSI) | Y? | Defender | ? | – |
| Multi-algorithm hash tool | Y | Y++ (BLAKE3, SM3) | BLAKE2 | Y | ? | – | – | ? | ? |
| Benchmark | Y | Y | Y | – | – | – | – | – | – |
| Secure delete | – | – | Y? (wipe) | Y | – | Y? (shred) | – | Y? | – |
| SFX | Y | Y | Y | Y | Y | Y (paid add-on hist.) | – | Y | ? |
| MotW / quarantine propagation | Y (`-snz`) | Y (policy) | Y (configurable) | ? | Y | ? | Y | ? | ? |
| CLI | Y | Y | Y (rar.exe) | Y + export | Y (bz.exe) | Y (add-on) | – | Y | Y + MCP |
| Cross-platform | Linux/mac CLI | – | Linux/mac CLI | Win/Linux/mac | Win + Mac | Win + Mac | – | Win | macOS |

Notes on the matrix:
- Cells with "?" or "hist." come from my general knowledge and are not cited in this session, so verify them before publishing: the WinRAR password organizer, WinRAR wipe, WinZip shred and cloud, PowerArchiver mount, Bandizip bz.exe, the WinZip CLI add-on.
- Xipper's "mount read-write", "signed archives" and "MCP server" have no direct Windows equivalent found. PowerArchiver historically advertised mounting, but this is unverified.

**Positioning notes**
- Xipper's clearest differentiators against Windows archivers are the read-write archive mount, the MCP server, actionable error remedies, and native Finder/QuickLook integration.
- The most-requested table-stakes features Xipper may still lack are smart extract, ZIP repair, a password manager, in-archive thumbnails, a malware-scan hook, a benchmark, and a hash UI.

### Gaps
- Exact current prices were not retrieved from primary pages: WinRAR (historically about USD 29 single user), WinZip Standard/Pro, Bandizip Professional, PowerArchiver.
- No Reddit threads were returned by search, so user sentiment comes from editorial comparison articles, which are lower-quality and partly SEO content (compresto.app sells a competing product).
- PowerArchiver's 2025–2026 release activity is unclear: no official changelog was found.
