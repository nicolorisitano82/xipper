# Xipper 2.0

*[Italiano](LEGGIMI.md) · English*

Xipper is an archiver for Macs with Apple Silicon (M1 or later) running **macOS 26 or later**. It creates, opens, verifies, repairs and extracts archives quickly and safely: ZIP, 7z, tar (gz, bz2, xz, zst), cpio, Apple Archive and XIZ, Xipper's own format. For genomics it converts BAM ↔ CRAM 3.1 and builds the indexes samtools, bcftools and tabix use.

## Installing
1. Open the Xipper `.dmg` file and drag **Xipper** into **Applications**.
2. **First launch.** Xipper is signed with its own certificate, not an Apple Developer ID, so macOS blocks it the first time.
   - Open Xipper. When macOS says the developer cannot be verified, choose **Done**.
   - Go to **System Settings › Privacy & Security**, scroll to "Xipper was blocked" and click **Open Anyway**. Confirm with your password or Touch ID.
   - Or, in Terminal:

     ```bash
     xattr -dr com.apple.quarantine /Applications/Xipper.app
     ```

3. Optionally check the DMG against the SHA-256 in the `.sha256` file next to it.

## What it does
- **Compress:** drop files and folders on the window, pick format, level and an optional password (ZIP, 7z and XIZ with AES-256; Apple Archive with AEA). ZIP can also use bzip2, LZMA and xz (Format menu › More ZIP methods), readable by 7-Zip and WinZip but not by Archive Utility.
- **Open and browse:** double-click an archive; preview with the space bar, drag files out to the Desktop.
- **Extract:** next to the archive, or chosen entries anywhere. Xipper never writes outside the destination, blocks zip bombs and keeps the quarantine of downloaded files.
- **Edit without extracting:** in the browser, right-click › **Rename…**, **Delete**, **Add Files…**, or drop files on the table. ZIP, 7z and XIZ keep what does not change as it is, without recompressing it (in a solid 7z, only the blocks you touch are compressed again).
- **Mount as a volume:** the **Mount** button (or Finder › Xipper › Mount as a Volume). The archive appears in `/Volumes`; open and edit it in the Finder, and when you eject it Xipper asks whether to save the changes.
- **Verify and repair:** **Verify** checks integrity without writing anything. **Create Recovery Data** (inspector) writes PAR2 files next to the archive; if the archive ever gets damaged, **Repair** rebuilds it.
- **Genomics:**
  - BGZF compatible with `bgzip`;
  - **CRAM 3.1**: open a `.cram` or `.bam` and use **Convert to BAM…** / **Convert to CRAM…** with the reference FASTA (CRAM is usually 30–50% smaller than BAM, and samtools reads it);
  - `.bai`/`.csi`, `.crai`, BCF `.csi`, `.fai` and tabix indexes (SAM too);
  - VCF/BCF/BAM/CRAM checks and checksum manifests.

## Finder integration
On first launch Xipper offers three optional steps: the Finder extension, Xipper as the default app for archives, and the `xipper` command in Terminal. Reopen them from **Help › Welcome to Xipper**.

- **Xipper menu and toolbar button:** enable **Xipper in the Finder** in **System Settings › General › Login Items & Extensions › Finder Extensions**.
- **Quick Actions / Services:** **Compress with Xipper**, **Extract with Xipper**, **Verify with Xipper**.
- **Quick Look** for archives and **Shortcuts** actions (Compress, Extract, Verify, List Contents).

Xipper's Finder menu offers the fitting action first: **Decompress** on archives, **Compress** on everything else; the others are under **More with Xipper**.

Finder actions always create new files next to the originals and never overwrite anything.

## Known limits
- **RAR** opens read-only (multi-volume too); encrypted RAR5 archives open with their password, but not encrypted RAR 4 or encrypted multi-volume ones; ISO and MPEG-G are planned for 3.0.
- CRAM files are not browsed like archives: convert them to BAM, with the reference FASTA they were written with.
- Encrypted Apple Archives need a password of at least 20 characters (a macOS limit).
- A mounted archive is a local WebDAV volume: the first time a very large file is opened, the Mac reads all of it.

## Acknowledgements
Xipper includes open-source code (zstd, libdeflate, liblzma, htscodecs, libarchive, Argon2, LZMA SDK): the licenses are in **Xipper › Acknowledgements**.

## Updates
Once a day Xipper asks GitHub whether there is a new version (also from **Xipper › Check for Updates…**). It downloads it only if you say so, checks its SHA-256 and opens the disk image: drag Xipper into **Applications** as the first time.

## Privacy
Xipper collects no data. Its only connection to the Internet is the update check on GitHub, which can be turned off in **Settings › General**.

## Problems
Open an issue at <https://github.com/nicolorisitano82/xipper/issues> with your macOS version, what you did and what happened.
