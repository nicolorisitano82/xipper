# 6. XIZ, Xipper's format

XIZ is an archive format made for keeping files, not just sending them. Its specification is public ([docs/XIZ_SPEC.md](../docs/XIZ_SPEC.md)) and there is an independent reader written in C, `xiz` / libxiz, for Linux, Windows and macOS ([chapter 13](13-troubleshooting.md#reading-xiz-without-xipper)).

What every XIZ archive has:

- **Independent frames:** a damaged frame costs only the files in it. Single files can be read without decompressing the rest, which is also why mounting is fast.
- **A SHA-256 of every file**, and a checksum of every frame.
- **Deduplication:** identical files, and identical pieces of large files (content-defined chunks), are stored once.
- **A zstd dictionary for many small files**, built automatically.
- **Encryption with Argon2id and AES-256-GCM** when there is a password. Names, sizes and dates are encrypted too.
- **Changes appended at the end:** earlier states stay available as versions.

## Smaller files without losing anything

These options are in **Settings › Formats › XIZ**. Each one rewrites some kinds of files in a more compact way and rebuilds them byte for byte on extraction. Each file is rebuilt and compared before it enters the archive. A file the method can't handle, or that wouldn't come out smaller, is stored the usual way.

| Option | Files | Typical gain | Readable by | Command line |
|---|---|---|---|---|
| **Smaller JPEG photos** | JPEG | about 20% | Xipper 2.7+ | `--jpeg` |
| **Smaller PNGs, PDFs and documents** | PNG, PDF, DOCX/XLSX/PPTX, ODF, EPUB | PNG ~30%, PDF ~17%, documents ~13% vs LZMA2 | Xipper 3.0+ | `--documents` |
| **Smaller CSV Tables** | CSV, TSV, TAB, BED, PSV of at least 64 KB | 10–30% vs the Maximum level on tables of numbers, and faster to open | Xipper 3.1+ | `--tables` |
| **Smaller AI Models** | `.safetensors`, PyTorch `.pt`, `.pth`, `.bin`, `.ckpt` | 10–15% vs zstd, 5–9% vs xz -9, at zstd's speed | Xipper 3.1+ | `--models` |

How each one works:

- **Photos:** JPEG data is recoded with brunsli.
- **Documents:** the Deflate streams inside the files are unpacked, compressed better, and rebuilt bit for bit with preflate.
- **Tables:** OpenZL splits each table into columns and compresses each with its own method (numbers parsed and delta-coded, repeated strings tokenised). Large tables are stored in pieces of whole rows.
- **AI models:** the weights are split into sign and exponent (entropy-coded) and mantissa, tensor by tensor, with OpenZL. float32, bfloat16 and float16 are supported. Headers and metadata go with the usual codec.

Measured on real models:

| Model | zstd | Smaller AI Models | xz -9 |
|---|---|---|---|
| BERT tiny (PyTorch, float32) | 16.4 MB | **14.8 MB** | 16.3 MB |
| BERT mini (PyTorch, float32) | 41.7 MB | **37.5 MB** | 41.2 MB |
| SmolLM2-135M (safetensors, bfloat16) | 210.4 MB | **179.6 MB** | 189.6 MB |

## Maximum level, LZMA2 and the Apple codecs

- **"Maximum" level with LZMA2** (**Settings › Formats › XIZ**) makes archives about 10% smaller for apps and source code, but they are slower to open. Readable by Xipper 2.6+. From the command line: `--lzma2`. Frames that hold mostly arm64 executables get a branch filter that shrinks them further.
- **Apple codecs**<a id="apple-codecs"></a> (LZRAVEN and LZMESH, macOS 27 only):
  - at "Maximum", LZRAVEN is about 7% smaller than LZMA2 and faster to open;
  - at the other levels, LZMESH compresses like zstd 9 at the speed of zstd 3;
  - these archives open only on macOS 27 with Xipper 3.0+. From the command line: `--lzraven`, `--lzmesh`.

## Versions

Every change to an XIZ archive (edit, update, signature) adds a segment at the end and leaves the earlier ones untouched. In the inspector, the **Versions** section lists them, with date, size, number of files and the signer when signed.

**Open** shows a version read-only: you can browse it, extract from it or mount it. From the command line:

```bash
xipper versions archive.xiz
xipper extract --version 3 archive.xiz
```

The space taken by deleted data comes back with `xipper edit --compact`, which also drops the earlier versions.

## Reserved folders, recipients and custodians

The **Access** button (main window, XIZ format) opens the access sheet.

- **Reserved folders:** each one is encrypted with its own key; everything else is in the main group. Name it ("Reports") and choose the folders it covers.
- **Who can open:** each recipient opens the main group and the reserved folders you tick. A recipient is either:
  - a **Password**, or
  - a **Public key**: `xizpq1…` (post-quantum) or `xizpk1…` (classic). The person sends you this, or you pick one of your own identities with **Use one of your identities**.

  Recipients with a key don't need to share a password with anyone.
- **Custodians:** a custodian group opens its folders only when the required number of custodians unlock together, for example 2 of 3. Each custodian has a password or a public key. The secret is split with Shamir's scheme.
- **Erasable files:** each file gets its own key. **Erase Permanently…** later destroys that key in place, making the file unreadable in every version of the archive and in every copy made afterwards. Copies made earlier still hold the key: erase before you hand the archive out. Erasable files need encryption (a password or recipients).

Someone who opens the archive sees only the folders they hold a key for. The others don't even appear in the list: the inspector shows how many folders are closed.

From the command line, the same policy is a JSON file:

```json
{
  "groups": [ { "name": "reports", "folders": ["project/reports"] } ],
  "recipients": [
    { "label": "Lab", "public_key": "xizpq1…", "groups": ["reports"] },
    { "label": "Me", "password_prompt": true }
  ],
  "thresholds": [
    { "label": "Board", "k": 2, "groups": ["reports"],
      "custodians": [ { "label": "Anna", "password_prompt": true },
                      { "label": "Bruno", "password_env": "BRUNO_PW" },
                      { "label": "Carla", "public_key": "xizpq1…" } ] }
  ],
  "erasable": true
}
```

Each credential is a `public_key`, a password typed when asked (`password_prompt`) or read from an environment variable (`password_env`). Passwords written in the file itself are refused.

```bash
xipper create -f xiz --access policy.json --sign keychain:Work out.xiz folder/
xipper list --identity keychain:* out.xiz              # open with your Keychain identities
printf 'first\nsecond\n' | xipper extract --password-stdin out.xiz   # two custodians' passwords
xipper erase archive.xiz private/old-notes.txt
```

## Signatures and history

A signed XIZ archive records who made each change and when. The inspector's **Signatures** section shows, for each version:

- the **signer's name and key**: a hybrid key appears as `xizsigpq1:` followed by its fingerprint, with "Post-quantum: Ed25519 + ML-DSA-65";
- the **date** and the time-stamp, if any;
- whether the **signature is valid**;
- whether the **chain is intact**. Every signature covers the previous one, so altering or removing an earlier version breaks the chain.

What the marks mean:

| Mark | Meaning |
|---|---|
| ✔ green | Signature valid, chain intact |
| ✖ red, "Invalid signature" | The segment was changed after it was signed |
| ✖ red, "Chain broken" | An earlier version was altered |
| ◆ orange, "Signed with an algorithm this version does not know" | A newer Xipper made it: update to check it |
| "Archive not signed" | No version was signed |

How signing works:
- **New archives:** choose a key in **Signature** (main window).
- **Changes:** **Settings › Keys › Also sign changes to signed archives** signs every change automatically.
- **Who can check:** checking needs no password, so anyone can verify the history of an encrypted archive without being able to read it.

**Key types** ([chapter 7](07-keys.md)):

| Key | Signature | Checked by |
|---|---|---|
| **Post-quantum (recommended)**, `xizsigpq1…` | Ed25519 + ML-DSA-65 together. Valid only if both verify, so it stays sound as long as either algorithm is unbroken, also against future quantum computers. About 5 KB per signed version | Xipper 3.2+, libxiz from 3.2. Earlier versions show the segment as unsigned, but open the archive normally |
| **Classic**, `xizsig1…` | Ed25519 | Every version since 2.2 |
| **Secure Enclave**, `xizsigse1…` | P-256 + ML-DSA-65 together, both kept by your Mac's Secure Enclave: the key cannot be copied, and is lost with the Mac. Post-quantum like the hybrid keys | Xipper 3.3+, libxiz from 3.3 |
| **Certificate** | ECDSA P-256 or RSA with an X.509 certificate, from the Keychain or a smart card: the signature carries your certified name. Choose it in **Settings › Keys › Sign new XIZ archives with** or in the XIZ sheet | Xipper 3.1+ |

```bash
xipper keygen --signing --pq --keychain "Work"                 # a hybrid key in the Keychain
xipper create -f xiz --sign keychain:Work --signer "Ada" out.xiz folder/
xipper edit out.xiz --add new.txt --sign keychain:Work
xipper history out.xiz
```

### Time-stamps

If you set a time-stamp authority (RFC 3161 URL) in **Settings › Keys**, each signature also gets a time-stamp. The authority's own signature then proves that your signature existed at that time. This is the only case in which Xipper contacts a server when signing. From the command line: `--timestamp URL`.

### Signed Apple Archives

With a signing key, an Apple Archive (`.aar`) can be signed too (signed, not encrypted: AEA profile 0). macOS's `aea` checks it with the key `xipper history --aea-pem FILE` writes.

## Proofs of inclusion

A proof shows that one file belongs to a signed archive without handing over the archive or its password. It works like a page of a signed register shown on its own.

1. Right-click a file › **Create Proof of Inclusion…** writes a small JSON file.
2. Send the proof and the file.
3. The receiver checks them with **File › Verify Proof of Inclusion…**, or `xipper verify-proof`, or `xiz verify-proof` on any system. The check confirms:
   - the content matches;
   - the file is in the archive's signed tree;
   - who signed it and when.

```bash
xipper prove archive.xiz contracts/2026-03.pdf -o proof.json
xipper verify-proof proof.json 2026-03.pdf
```

## Forensic archives

Archives made by **Xipper Forensic**, a separate app for digital evidence, are XIZ 1.10 archives. Xipper opens, verifies and extracts them like any XIZ. The inspector shows, read-only:
- the case and the evidence item;
- the source's SHA-256;
- unreadable sectors;
- the hand-overs.

Xipper never changes them. Use Xipper Forensic or `xiz forensic` to verify the evidence fully.

## Compatibility

| Archive uses | Readable by |
|---|---|
| Nothing special (zstd), recovery data | Every Xipper, `xiz` |
| Signatures, access, proofs, erasable files (1.3) | Xipper 2.2+ |
| LZMA2 (1.4) | Xipper 2.6+ |
| JPEG recompression (1.6) | Xipper 2.7+ |
| Post-quantum recipients (1.7) | Xipper 3.0+. If the archive also has a password or a classic key, older versions open it with those |
| Apple codecs (1.8) | Xipper 3.0+ on macOS 27 only |
| Document recompression (1.9) | Xipper 3.0+ |
| Forensic profile (1.10) | Xipper 3.1+, Xipper Forensic |
| Tables and AI models (1.11) | Xipper 3.1+ |
| Post-quantum signatures (1.12) | Content: every version that reads signed archives. Verifying the signature: Xipper 3.2+ |
| Secure Enclave signatures (1.13) | Content: every version that reads signed archives. Verifying the signature: Xipper 3.3+ |

An archive that needs a newer reader is refused with a clear message, never misread. `xiz` (libxiz) reads all of them, the Apple codecs only on macOS 27.
