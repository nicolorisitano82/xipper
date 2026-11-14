# 10. The command line

Everything Xipper does is also available as the `xipper` command, for Terminal, scripts and automation. It uses the same engine as the app, and the same keys, passwords and settings stored in the Keychain.

## Installing the command

The Welcome steps (**Help › Welcome to Xipper**) link the command into `/opt/homebrew/bin` or `/usr/local/bin`. If neither can be written without a password, they copy this command to the clipboard:

```bash
sudo mkdir -p /usr/local/bin && sudo ln -sf /Applications/Xipper.app/Contents/Helpers/xipper /usr/local/bin/xipper
```

Check with `xipper help`.

## Common options

| Option | Meaning |
|---|---|
| `-p`, `--password` | Ask for the password (encrypting, or opening an encrypted archive) |
| `--password-stdin` | Read the password from the first line of standard input. Further lines are more passwords: the custodians of a k-of-n group each give theirs |
| `-j N`, `--threads N` | Worker threads (default: the performance cores) |
| `--background` | Run on the efficiency cores at low priority |
| `-q`, `--quiet` | No progress output |
| `--identity FILE` | An XIZ identity to open archives with. `keychain:NAME` takes one from the Keychain, `keychain:*` takes all; repeatable |

Exit status:
- `0` means success;
- a non-zero code means failure. `test` and `history`, for example, return non-zero when something does not verify.

## Archives

### create

```
xipper create [options] <archive> <file|folder>...
```

| Option | Meaning |
|---|---|
| `-f`, `--format FMT` | zip (default from the name), 7z, tar, tar.gz, tar.bz2, tar.xz, tar.zst, aar, cpio, xiz, gz, bz2, xz, zst |
| `-l`, `--level N` | zip 1–12, zstd 1–22, xz/7z 0–9, bzip2 1–9 |
| `-m`, `--method M` | ZIP method: deflate (default), zstd, bzip2, lzma, xz, deflate64, store |
| `-p`, `--password` | Encrypt: zip, 7z and xiz with AES-256, aar with AEA |
| `--solid SIZE` | 7z solid block size (`64m`, `2g`, `off`) |
| `-v`, `--volume SIZE` | Split into volumes. For ZIP, `--numbered` names them `.zip.001`… |
| `--plain-names` | 7z with a password: leave the names readable |
| `--zip64` | Always write ZIP64 structures |
| `--zipcrypto` | ZIP: the weak ZipCrypto instead of AES-256, only for receivers without AES |
| `--keep-mac-files` | Keep `.DS_Store`, `._*` and similar files |
| `--apple-double` | ZIP: also store tags and attributes in `__MACOSX/`, like the Finder |
| `--windows-names` | ZIP, 7z: rename entries Windows cannot extract |
| `--recompress-all` | Also compress photos, videos and archives |
| `--no-bgzf`, `--bgzf-index` | Genomic text: plain gzip instead of BGZF / also the `.gzi` index |
| `--overwrite` | Replace an existing archive |

XIZ options:

| Option | Meaning |
|---|---|
| `--lzma2` | LZMA2 frames, about 10% smaller |
| `--lzraven`, `--lzmesh` | Apple codecs, macOS 27 only |
| `--jpeg` | Recompress JPEG losslessly |
| `--documents` | Recompress PNG, PDF and Office/EPUB losslessly |
| `--tables` | CSV, TSV and BED column by column |
| `--models` | AI model weights tensor by tensor |
| `--recovery N` | N percent of recovery data inside the archive |
| `--no-dictionary` | No zstd dictionary for small files |
| `--access POLICY.json` | Reserved folders, recipients, custodians, erasable files ([chapter 6](06-xiz.md#reserved-folders-recipients-and-custodians)) |
| `--sign FILE` or `keychain:NAME` | Sign the archive. With aar, writes a signed Apple Archive |
| `--signer NAME` | The name shown in the history |
| `--timestamp URL` | RFC 3161 time-stamp authority |

```bash
xipper create photos.zip ~/Pictures/Trip
xipper create -f tar.zst -l 19 backup.tar.zst ~/Projects
xipper create -f xiz --lzma2 --jpeg --documents --recovery 10 --sign keychain:Work archive.xiz ~/Documents/2026
```

### extract

```
xipper extract [options] <archive> [entry...]
```

| Option | Meaning |
|---|---|
| `-d`, `--dest DIR` | Destination (default: next to the archive, in a new folder) |
| `--into` | Extract directly into DIR, without a new folder |
| `--flatten` | Every file directly in DIR, without folders |
| `--overwrite P` | `keep-both` (default), `replace`, `skip`, `fail` |
| `-r`, `--recursive [N]` | Also extract archives found inside, N levels (default 3). `--keep-nested` keeps them |
| `--allow-external-symlinks` | Allow links pointing outside the destination |
| `--no-quarantine` | Don't copy the archive's quarantine to the files |
| `--version N` | XIZ: extract version N |
| `--names-encoding ENC` | Code page of old ZIP names: cp437, cp850, cp866, windows1252, windows1251, shiftjis, gbk, big5, euckr |

### list, test, versions

```bash
xipper list --long archive.7z
xipper test archive.xiz
xipper test --sha256 archive.zip          # also a SHA256SUMS list of the content
xipper versions archive.xiz               # every version: size, files, signer, date
```

### edit and update

```bash
xipper edit archive.zip --delete PATH --rename OLD:NEW --add FILE[:PATH] --mkdir PATH   # repeatable, in order
xipper edit --compact archive.xiz                                                       # drop deleted data and old versions
xipper update [--dry-run] archive.xiz ~/Folder                                          # add new and changed files, remove missing ones
```

### convert

```
xipper convert --to FMT [options] <archive>
```

| Option | Meaning |
|---|---|
| `--to FMT` | zip, 7z, tar, tar.gz, tar.bz2, tar.xz, tar.zst, aar, cpio, xiz (required) |
| `-o FILE` | The new archive |
| `-m`, `-l` | Method and level for recompressed entries |
| `-p` | The original's password |
| `--encrypt` | Protect the new archive with a password |
| `--dry-run`, `--json` | Show the plan: what is copied, what is recompressed, the space needed |
| `--trash-original` | Move the original to the Trash once the new archive is verified |
| `--accept-losses` | Go on when signatures, access groups or the password would be lost |
| `--little-space` | ZIP or 7z to XIZ when the disk can't hold both. The same command resumes an interrupted conversion |
| `--abandon` | Give up an interrupted little-space conversion, before any of the original was freed |
| `--lzma2` … `--models` | XIZ options, as in create |

### mount

```bash
xipper mount archive.zip                   # until you eject it or press Ctrl-C
xipper mount --read-only --at ~/mnt archive.xiz
xipper mount --discard archive.zip         # changes are dropped on eject
```

## Integrity and repair

```bash
xipper scrub [--repair] archive.xiz        # check every byte against the recovery record
xipper recovery add --redundancy 10 archive.xiz
xipper recovery remove archive.xiz
xipper recovery info archive.xiz
xipper repair archive.xiz                  # = scrub --repair
xipper repair -o fixed.zip damaged.zip     # rebuild a ZIP without recovery data
xipper par2 create --redundancy 10 file
xipper par2 verify file.par2
xipper par2 repair file.par2
```

## Checksums

```bash
xipper hash [-a ALG[,ALG…]] [--contents] [--bsd] [-o LIST] <file|folder|archive>...
xipper hash -c LIST
```

Algorithms: sha256 (default), sha512, sha3-256, blake3, xxh128, xxh3, sha1, md5, crc32, crc32c.
- **Output:** one algorithm prints `sha256sum`/`b3sum`-style lines; several print BSD-tagged lines.
- **`-o`:** writes a list, such as `SHA256SUMS`, `B3SUMS` or `list.json`.
- **`--contents`:** hashes the files inside archives.

## XIZ keys, signatures, proofs

```bash
xipper keygen [--signing] [--pq | --secure-enclave] -o FILE | --keychain NAME
xipper history archive.xiz                       # who changed what and when; exit 3 if something does not verify
xipper history --aea-pem key.pem signed.aar      # key of a signed Apple Archive, for aea -sign-pub
xipper prove archive.xiz path/in/archive -o proof.json
xipper verify-proof proof.json file
xipper erase archive.xiz path/in/archive...      # archives created with "erasable"
```

`keygen` options:
- no flags: a classic identity (X25519);
- `--pq`: a post-quantum identity (X-Wing);
- `--signing`: a classic signing key (Ed25519);
- `--signing --pq`: a hybrid signing key (Ed25519 + ML-DSA-65);
- `--signing --secure-enclave`: a key in this Mac's Secure Enclave (P-256 + ML-DSA-65), which works only on this Mac.

## Signed documents

```bash
xipper sig verify [--online] [--country CC | --no-trusted-list] [--json] FILE
xipper sig extract [-o FILE] FILE.p7m
xipper sig certificates
xipper sig sign --certificate NAME [--parallel | --nested] [--timestamp URL [--tsa-user USER]] [-o FILE] [--overwrite] FILE
```

- `verify` checks a `.p7m`, a signed PDF or an ASiC container; exit 3 if not every signature is valid. `--online` downloads the trusted list and asks OCSP/CRL services; otherwise the cached list and the revocation data in the file are used.
- `extract` writes the document inside a `.p7m` (also nested), without checking.
- `certificates` lists the signing certificates (Keychain, smart cards), marking qualified, non-repudiation and expired ones.
- `sign` makes `FILE.p7m` (CAdES-BES; CAdES-T with `--timestamp`). For a `.p7m`, `--parallel` adds a signer in place, `--nested` wraps it. The time-stamp password comes from `XIPPER_TSA_PASSWORD` or is asked.

See [chapter 14](14-signed-documents.md).

## Genomics

```bash
xipper bgzip [-d] [-c] [-i] [-r] [-t] [-l N] [-@ N] [--convert] [--info] file...
xipper tabix [-p vcf|bed|gff|sam] [-C] [-s N -b N -e N] [-0] [-S N] file.gz
xipper index [-C] [-m N] [-o FILE] file...       # .bai .csi .crai .fai .tbi
xipper index-check [--data FILE] [--no-index] file...
xipper cram -r REF.fa [--version 3.0] [--no-md] [-o FILE] [-f] file.bam|file.cram
xipper manifest create [-a ALGS] -o MANIFEST file|folder...
xipper manifest verify manifest...
```

See [chapter 9](09-genomics.md).

## AI assistants

```bash
xipper mcp --allow ~/Documents        # MCP server on stdio
xipper mcp install                    # how to register it in Claude Code / Claude Desktop
```

See [chapter 11](11-ai-assistants.md).

## Copy as Command

After creating an archive in the app, **Copy as Command** in the result panel copies the exact `xipper` command that makes the same archive. It is a quick way to turn something you did once into a script.
