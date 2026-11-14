# 2. Creating archives

## The quick way

1. Drop files or folders on the Xipper window, or click **Add Files**.
2. Check the **Name** and the folder it will be saved in (**Save in**, or **Other Folder…**).
3. Choose a **Format** and a **Level**.
4. Click **Compress**.

When the job ends, the result panel offers:
- **Verify**, **Show Contents**, **Show in Finder**, **Create Another Archive**;
- **Copy as Command**: the `xipper` command that would create the same archive, for a script.

You can also compress from the Finder ([chapter 8](08-finder-shortcuts.md)) or from Terminal ([chapter 10](10-command-line.md)).

## Choosing a format

| Format | Best for | Notes |
|---|---|---|
| **ZIP** | Sending files to anyone | Opens everywhere (Windows, Archive Utility). The default method, Deflate, works with every tool; see below for the others |
| **tar.zst** | Backups and exchange between Mac and Linux | The fastest and most compact for that use |
| **tar.xz** | Long-term archives | Very compact, slower |
| **7z** | Compact archives with encrypted names | Solid compression; with a password it can also hide the file names |
| **XIZ** | Your own archives | Xipper's format: everything in [chapter 6](06-xiz.md) (signatures, access per folder, versions, recovery data, recompression of photos, documents, tables and AI models). Read by Xipper and by the free `xiz` tool on Linux, Windows and macOS |
| **Apple Archive (aar)** | macOS tools (`aa`, `aea`) | Can be encrypted (AEA) or signed |
| **tar, tar.gz, tar.bz2, tar.lz4, tar.br, cpio** | Compatibility with Unix tools | |
| **gz, bz2, xz, zst, lz4, br** | A single file | Compress one file, not a folder |

The **Preset** menu offers ready-made choices:
- **Quick backup**: tar.zst at a fast level;
- **Long-term archive**: tar.xz at the maximum level.

The default format and level for new archives are set in **Settings › General**.

## Levels

The **Level** control goes from fast to maximum. Higher levels make smaller archives and take longer. Extraction speed hardly changes, except for XIZ with LZMA2 (see [chapter 6](06-xiz.md)).

Files that are already compressed (photos, videos, archives) are stored as they are by default, because compressing them again wastes time. To change this for ZIP, see **Settings › Formats › ZIP**.

## Passwords

Set a **Password** to encrypt the archive:

| Format | Encryption |
|---|---|
| ZIP, 7z, XIZ | AES-256 |
| Apple Archive | AEA; macOS requires a password of at least 20 characters |

- **7z:** with a password, the file names can be encrypted too (**Settings › Formats › 7z › With a password, also encrypt file names**).
- **XIZ:** names are always encrypted along with the content. XIZ can also give different people access to different folders (**Access**, [chapter 6](06-xiz.md#reserved-folders-recipients-and-custodians)).
- **ZIP:** AES-256 is read by 7-Zip, WinZip and most modern tools, but not by Archive Utility. From the command line, `--zipcrypto` writes the old, weak ZipCrypto for receivers that cannot read AES. Use it only when you must.

Saved passwords live in the Keychain. **Settings › Security** can require Touch ID to use them.

## ZIP methods

**Format › More ZIP methods**, or **Settings › Formats › ZIP › Method**:

| Method | Compatibility |
|---|---|
| Deflate | Works everywhere (default) |
| Zstandard | Faster; 7-Zip, WinZip |
| bzip2, LZMA, xz | Smaller; 7-Zip, WinZip |
| Deflate64 | 7-Zip, WinZip, Info-ZIP |
| No compression | Everywhere |

Archive Utility opens only Deflate and uncompressed ZIP files.

Other ZIP options in **Settings › Formats › ZIP**:
- **Don't recompress already compressed files** (on by default);
- **Include hidden Mac files** (`.DS_Store`, `._*`); they are left out by default;
- **Save Mac tags and attributes** in a `__MACOSX` folder, as the Finder does;
- **Windows-compatible names**: entries Windows cannot extract (`a:b`, `why?`, `CON.txt`, trailing dots, names that differ only in case) are renamed. When two names collide, a name that was already valid keeps priority.

## 7z options

**Solid compression** (**Settings › Formats › 7z**) packs files together in large blocks. Archives come out smaller, but extracting a single file means decompressing its whole block. From the command line, `--solid SIZE` sets the block size (`64m`, `2g`, or `off` for one block per file).

## Split archives

From the command line, `-v SIZE` splits an archive into volumes:

- **7z:** `name.7z.001`, `.002`, …
- **ZIP:** the PKWARE split format, `name.z01`, …, `name.zip`. 7-Zip, WinZip, WinRAR and `zip -s 0` read it. With `--numbered`, the pieces are `name.zip.001`, `.002`, …, which joined with `cat` make an ordinary ZIP.

```bash
xipper create -v 4g photos.zip ~/Pictures/2026
```

Xipper opens split archives when you open the last part (`.zip`) or the first (`.001`). If a part is missing, the error offers **Locate…** to find it.

## Recovery data at creation

**Settings › General › Recovery Data › Create PAR2 recovery data after every compression** adds recovery data to every new archive:
- **XIZ:** inside the archive;
- **other formats:** `.par2` files next to it.

See [chapter 5](05-verify-repair-checksums.md).

## Sign and Access (XIZ)

With the XIZ format, the window shows two more controls:

- **Signature:** signs the archive with one of your signing keys ([chapter 7](07-keys.md)). Every later change can be signed too.
- **Access:** reserved folders, recipients, custodians and erasable files ([chapter 6](06-xiz.md#reserved-folders-recipients-and-custodians)).
