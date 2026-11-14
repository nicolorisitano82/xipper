# Xipper 3.2 User Manual

Xipper is an archiver for Macs with Apple silicon (M1 or later) running macOS 26 or later. It creates, opens, verifies, repairs and extracts archives, edits them in place, mounts them as volumes and converts between formats. XIZ, its own format, adds features ordinary archives lack: signed history, per-folder access, post-quantum keys, recovery data inside the archive and lossless recompression of photos, documents, tables and AI models.

This manual covers the app, the Finder integration and the `xipper` command. It describes version 3.2.0 (14 November 2026).

## Contents

| Chapter | What it covers |
|---|---|
| [1. Getting started](01-getting-started.md) | Requirements, installing, first launch, the Welcome steps, updates, privacy, uninstalling |
| [2. Creating archives](02-creating-archives.md) | The main window, formats and when to use each, levels, presets, passwords, ZIP methods, 7z options, split archives |
| [3. Opening and extracting](03-opening-and-extracting.md) | The browser and the inspector, Quick Look, extracting, what Xipper does to keep you safe, RAR, name encodings, nested archives |
| [4. Editing, mounting and converting](04-editing-mounting-converting.md) | Changing an archive without extracting it, mounting it as a volume, changing its format, converting with little free space |
| [5. Verifying, repairing and checksums](05-verify-repair-checksums.md) | Verify, recovery data (inside XIZ, PAR2 for the rest), repairing damaged ZIP files, checksum lists |
| [6. XIZ, Xipper's format](06-xiz.md) | Smaller photos, documents, tables and AI models, Apple codecs, versions, reserved folders, recipients, custodians, erasable files, signatures (also post-quantum), proofs of inclusion, time-stamps, forensic archives, compatibility |
| [7. Keys](07-keys.md) | Identities and signing keys in the Keychain, classic and post-quantum, import and export |
| [8. Finder, Quick Look, Shortcuts and the menu bar](08-finder-shortcuts.md) | The Finder extension, Quick Actions, Services, Quick Look, Shortcuts actions, the menu bar icon |
| [9. Genomics](09-genomics.md) | BGZF, BAM ↔ CRAM 3.1, indexes, checks and checksum manifests |
| [10. The command line](10-command-line.md) | Installing `xipper`, every command and option, examples, scripting |
| [11. AI assistants (MCP)](11-ai-assistants.md) | Letting Claude and other assistants use Xipper safely |
| [12. Settings reference](12-settings.md) | Every setting, tab by tab |
| [13. Limits, troubleshooting and help](13-troubleshooting.md) | Known limits, common problems, reading XIZ without Xipper, reporting a problem |
| [14. Signed documents](14-signed-documents.md) | Verifying `.p7m`, signed PDFs and ASiC, qualified or not, revocation; signing `.p7m` with a certificate or a smart card |

## What's new in 3.3

- **Signed documents.** Xipper verifies `.p7m` files, signed PDFs and ASiC containers: who signed, when, whether the signature is qualified (EU trusted list) and whether the certificate was revoked (online only with your permission). It also signs documents as `.p7m` with a certificate or a smart card, with a time-stamp if you like, also next to or over existing signatures. See [chapter 14](14-signed-documents.md).
- **Signing keys in the Secure Enclave (XIZ 1.13).** A key made by your Mac's Secure Enclave never leaves it: P-256 and ML-DSA-65 together. See [Keys](07-keys.md#keys-in-the-secure-enclave).
- **Signing XIZ archives with a certificate** (Keychain or smart card) in the app, not only in Xipper Forensic.

## What's new in 3.2

- **Post-quantum signatures (XIZ 1.12).** New signing keys are hybrid: Ed25519 together with ML-DSA-65 (FIPS 204). A signature is valid only when both halves verify, so it holds as long as either algorithm is unbroken. See [Signatures](06-xiz.md#signatures-and-history) and [Keys](07-keys.md).
- **Smaller AI models.** The weights of `.safetensors` files and PyTorch checkpoints (`.pt`, `.pth`, `.bin`, `.ckpt`) are compressed tensor by tensor with OpenZL. They come out 10–15% smaller than with zstd and 5–9% smaller than xz at its strongest, at zstd's speed. Xipper 3.1 can read these archives too. See [Smaller files without losing anything](06-xiz.md#smaller-files-without-losing-anything).
- **Signatures Xipper cannot check** are now shown as "signed, not verified", never as unsigned.
- **Proofs of inclusion** signed with a certificate are now verified correctly.

From 3.1 and 3.1.1:
- tables (CSV, TSV, BED) compressed column by column;
- forensic archives shown read-only in the inspector;
- updates offered only for Xipper itself;
- "Change Format" with little free space resumes after a power cut or a restart.

## Conventions

- **Menus and settings** are written as **Menu › Item**. Settings are in **Xipper › Settings…** (⌘,).
- **Commands** for Terminal look like `xipper test archive.zip`. Words in capitals, such as `FILE` or `DIR`, are placeholders for your own names.
- **XIZ version numbers** (1.6, 1.11…) are versions of the format, not of the app. [Compatibility](06-xiz.md#compatibility) says which Xipper reads what.
