# 3. Opening and extracting

## Formats Xipper opens

ZIP (also split, Deflate64, bzip2, LZMA, xz, Zstandard, PPMd, AES and ZipCrypto), 7z (also split, self-extracting and encrypted), tar and its compressed forms (gz, bz2, xz, zst, lz4, br), cpio, Apple Archive (also encrypted or signed), XIZ, RAR and RAR5 (read-only, encrypted RAR5 included), and single compressed files (gz, bz2, xz, zst, lz4, br).

## The browser

Open an archive by double-clicking it, by dropping it on the window or with **File › Open Archive…**.

- The table lists the contents: **Name**, **Size**, **Compressed**, **Method**, **Modified**, **CRC-32**, **Permissions**, **Encryption**. Click a folder's arrow to open it. **Back** and **Enclosing folder** move around.
- **Quick Look:** select a file and press the space bar.
- **Drag** files out to the Desktop or a Finder window to extract just those.
- **Actions** (toolbar) and the right-click menu hold everything you can do with the selection:
  - **Extract…**, **Open Folder**, **Rename…**, **Add Files…**, **Delete**;
  - for XIZ: **Create Proof of Inclusion…** and **Erase Permanently…**;
  - **Select All**, and **Multiple Selection**, which shows check boxes (useful on a touch screen).
- **Info** shows or hides the inspector.

### The inspector

The inspector describes the archive or the selection:

- **format, content, compression ratio**;
- **SHA-256 of the archive**, to write down or send to whoever receives it;
- **quarantine**: whether the archive came from the Internet;
- **Verify Archive**;
- for XIZ:
  - **Signatures**, the signed history ([chapter 6](06-xiz.md#signatures-and-history));
  - **Access**, with open folders, closed folders and erasable files;
  - **Versions**;
  - **Recovery Data**;
  - **Forensic evidence**, for archives made by Xipper Forensic;
- for genomic files: alignments, reference sequences, read groups, BGZF blocks.

### Encrypted archives

When an archive needs a password, Xipper asks for it.
- **Saved passwords:** with **Settings › Security**, it can keep them in the Keychain and require Touch ID to use them.
- **7z and XIZ with encrypted names** show nothing until the password is given.
- **XIZ archives for public keys** open with your identities from the Keychain ([chapter 7](07-keys.md)).

## Extracting

- **Extract** in the toolbar extracts next to the archive. Hold ⌥ (Option), or use **Extract To…**, to choose the folder.
- **Extract…** on a selection opens the extract sheet:
  - **Destination**: next to the archive, or **Other Folder…**;
  - **Structure**: **Keep folders**, or **Files only, all in the destination**;
  - **If a file already exists**: **Ask every time**, **Replace**, **Keep Both** or **Skip**;
  - **Open the folder when done**.

Extraction is verified as it goes: a file whose checksum does not match is reported and kept apart, and it never silently replaces a good one.

### Archives inside archives

**Settings › General › Also extract archives inside** extracts up to 3 levels of nested archives. Each one found inside is extracted next to itself and then removed.

Some files are left alone:
- genomic files (`.vcf.gz`, `.bam`, …);
- parts of split archives;
- documents that are archives internally, such as `.docx`.

From the command line: `xipper extract -r archive.zip`.

## What Xipper does to keep you safe

| Protection | What it does |
|---|---|
| **Never writes outside the destination** | Names such as `../../etc/passwd` or absolute paths are refused, and Xipper never writes through a link |
| **Symbolic links** | **Settings › Security › Symbolic links**. **Only inside the destination folder** is the default; **All (trusted archives)** and **None** are the alternatives |
| **Zip bomb protection** | Stops an extraction that would expand beyond a ratio. **Standard (1000:1)** is the default; **Strict (100:1)** and **Permissive (100,000:1)** are the alternatives |
| **Quarantine** | Files extracted from an archive downloaded from the Internet keep macOS's quarantine, so Gatekeeper still checks apps and scripts among them. **Settings › Security** can turn this off |
| **Permissions** | setuid and setgid bits are removed |
| **Deceptive names** | Names that hide their real extension (right-to-left override characters, double extensions such as `invoice.pdf.app`) are flagged, with the real name shown in the inspector |
| **Isolated decoders** | RAR and 7z archives are decoded in a separate, sandboxed process: a malformed archive cannot make Xipper quit or reach your files |

Entries that were blocked are listed at the end of the job with the reason.

## ZIP files from Windows and other systems: name encodings

Old ZIP files write names in a code page, not in UTF-8. Xipper guesses the code page. If the names look wrong, choose another one in **Actions › Name Encoding**: cp437, cp850, cp866, windows1252, windows1251, Shift-JIS, GBK, Big5 or EUC-KR. From the command line, use `--names-encoding ENC`.

## RAR

RAR and RAR5 archives open read-only, split ones too, and encrypted RAR5 archives open with their password. Encrypted RAR 4 archives and encrypted split RAR5 archives are not supported. To change a RAR, convert it to another format ([chapter 4](04-editing-mounting-converting.md#changing-format)).

## When something goes wrong

Errors come with an action when there is one:

| Action | When |
|---|---|
| **Locate…** | A part of a split archive is missing |
| **Repair** | Recovery data exists for the archive ([chapter 5](05-verify-repair-checksums.md)) |
| **Extract Elsewhere…** | The destination is full, read-only or not writable |
| **Try Again** | A disk was disconnected |
