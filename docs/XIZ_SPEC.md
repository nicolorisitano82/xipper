# XIZ archive format, version 1.0

Status: **stable** (frozen on 2026-10-22). Reference implementation: `Sources/XipperKit/Xiz/` in Xipper (MIT).
Design rationale (Italian): [reports/Nuovo formato di compressione Xipper.md](reports/Nuovo%20formato%20di%20compressione%20Xipper.md).
File extension `.xiz`, Uniform Type Identifier `app.xipper.xiz`, media type `application/x-xiz`.

XIZ stores files and folders as independent compressed **frames** followed by one **catalog** that
describes every entry and a fixed-size **footer** that locates the catalog. Identical files and
identical content-defined chunks are stored once. Optional authenticated encryption hides names,
metadata and content behind a password.

## 1. Conventions

- All integers are little-endian, unsigned unless stated. `u8`, `u16`, `u32`, `u64`; `i64` is two's complement.
- Offsets are absolute byte positions in the file.
- `CRC32C` is CRC-32 with the Castagnoli polynomial (0x1EDC6F41, reflected, init and xorout 0xFFFFFFFF), as in iSCSI.
- `SHA256` is FIPS 180-4; `HMAC` is RFC 2104 with SHA-256; `HKDF` is RFC 5869 with SHA-256;
  `AES-GCM` is NIST SP 800-38D with a 256-bit key, 96-bit nonce and 128-bit tag; `Argon2id` is RFC 9106 version 0x13.
- "zstd frame" means one complete Zstandard frame (RFC 8878), without dictionary.
- A reader **must** reject an archive that violates any "must" in this document.

## 2. Layout

```
offset 0         superblock                 64 bytes
                 keys block                 superblock.keys_length bytes (only when encrypted)
data_start       frame 0, frame 1, …        each: frame header (32) + payload (csize)
catalog_offset   catalog                    footer.catalog_csize bytes
file_size - 96   footer                     96 bytes
```

`data_start = 64 + keys_length`. Frames are contiguous: frame 0 starts at `data_start`, each next
frame starts right after the previous payload, and the catalog starts right after the last frame.
There are no gaps and no overlaps. The footer ends the file.

## 3. Superblock (64 bytes)

| Offset | Size | Field | Value |
|---:|---:|---|---|
| 0 | 8 | magic | `58 49 5A 00 0D 0A 1A 0A` ("XIZ\0\r\n\x1A\n") |
| 8 | 2 | version_major | 1 |
| 10 | 2 | version_minor | 0 |
| 12 | 2 | required_features | bit set, see below |
| 14 | 2 | optional_features | bit set, see below |
| 16 | 16 | archive_id | random, unique per archive |
| 32 | 4 | keys_length | length of the keys block; 0 when not encrypted |
| 36 | 24 | reserved | zero |
| 60 | 4 | crc | CRC32C of bytes 0–59 |

**Required features**: a reader **must** refuse an archive with a bit it does not implement.

| Bit | Name | 1.0 |
|---:|---|---|
| 0 | encrypted | defined (§6) |
| 1 | dictionaries | reserved: frames referencing zstd dictionary frames |
| 2 | append_chain | reserved: appended segments linked by `previous_footer` |
| 3–15 | — | reserved, zero |

**Optional features**: a reader **may** ignore them. Bit 0 (`recovery`) is reserved for Reed-Solomon
recovery data; bits 1–15 are reserved and zero.

`encrypted` is set if and only if `keys_length > 0`. `keys_length` must not exceed 65,536.

## 4. Frames

### 4.1 Frame header (32 bytes)

| Offset | Size | Field |
|---:|---:|---|
| 0 | 4 | magic `XFR1` |
| 4 | 1 | codec: 0 = store, 1 = zstd |
| 5 | 1 | flags: 0 in 1.0 (bit 0 reserved for dictionary frames) |
| 6 | 2 | dictionary id: 0 in 1.0 |
| 8 | 4 | frame index (0, 1, 2, …) |
| 12 | 4 | csize: payload length as written |
| 16 | 4 | usize: uncompressed length, at most 67,108,864 (64 MiB) |
| 20 | 4 | CRC32C of the payload as written |
| 24 | 8 | reserved, zero |

The header repeats the frame's catalog record; it exists to locate and verify data during repair.
A reader **must** check that it is byte-identical to the header rebuilt from the catalog and **must
not** use it to decide what to extract.

### 4.2 Payload

- `store`: the data itself (`csize == usize`, or `usize + 16` when encrypted).
- `zstd`: one zstd frame that decompresses to exactly `usize` bytes. A reader **must** stop at `usize`
  bytes of output and reject any other length.
- When the archive is encrypted the payload is the AES-GCM ciphertext of the above followed by the
  16-byte tag (§6.4). The CRC covers the bytes as written (ciphertext and tag), so damage can be
  located without the password.

Writers use 4 MiB frames: small files share a frame, big files span several.

## 5. Catalog

The catalog is a byte string, compressed as one zstd frame of exactly `footer.catalog_usize`
bytes, then encrypted (§6.5) when the archive is encrypted. `footer.catalog_sha256` is the SHA-256
of the catalog **as written**. Decompressed size is limited to 1 GiB.

```
magic        "XCAT"
version      u16 = 1
frame_count  u32
frames       frame_count × frame record (24 bytes)
entry_count  u32
entries      entry_count × entry
```

Nothing may follow the last entry.

### 5.1 Frame record (24 bytes)

`offset u64` (of the frame header) · `csize u32` · `usize u32` · `crc u32` · `codec u8` · `flags u8` · `dictionary u16`.

### 5.2 Entry

```
type         u8      0 = file, 1 = directory, 2 = symbolic link (other values: refuse)
path_length  u16
path         UTF-8, "/"-separated, relative
field_count  u16
fields       field_count × (tag u16, length u32, value[length])
```

| Tag | Name | Value | Critical |
|---|---|---|---|
| 0x8001 | size | `u64` content length | yes |
| 0x8002 | extents | n × (`frame u32`, `offset u32`, `length u32`) | yes |
| 0x8003 | link | symlink target, raw bytes | yes |
| 0x0004 | mode | `u16` permission bits (0o7777) | no |
| 0x0005 | owner | `u32` uid, `u32` gid | no |
| 0x0006 | mtime | `i64` seconds since 1970, `u32` nanoseconds | no |
| 0x0007 | xattr | `u16` name length, name (UTF-8), value (rest); one field per attribute | no |
| 0x0008 | digest | 32 bytes: SHA-256 of the content, HMAC-SHA-256 when encrypted (§6.3) | no |

- Bit 15 of a tag marks it **critical**: a reader **must** refuse an entry with an unknown critical
  tag and **must** skip unknown non-critical tags.
- Files **must** carry `size` and `extents`. The content of a file is the concatenation of its
  extents, each being `length` bytes at `offset` of frame `frame`'s uncompressed data. Extents of
  different entries may overlap (deduplication); every extent **must** lie inside its frame and the
  extent lengths **must** add up to `size`.
- Directories and symlinks have no extents and size 0. Writers list a directory before its content.
- Defaults when a field is absent: mode 0o644 (0o755 for directories), owner 0/0, mtime 0.

### 5.3 Path rules

A path is a list of components separated by `/`. Writers **must** produce relative paths with no
empty, `.` or `..` component and no NUL. Readers **must never** write outside the extraction root:
they drop (and report) an entry with a `..` component, a NUL or a component longer than 255 bytes,
and treat leading `/` and empty or `.` components as absent. `\` is an ordinary character.
Symbolic links are created after every other entry and **must not** point outside the
extraction root unless the user allows it; nothing is ever written through a symbolic link.
setuid, setgid and sticky bits are cleared on extraction.

## 6. Encryption

### 6.1 Keys

A random 256-bit **file key** encrypts the archive. From it, HKDF-SHA-256 with
`salt = archive_id` derives one 32-byte key per purpose, with `info` equal to:

| info | Use |
|---|---|
| `xiz/1/data` | frame payloads |
| `xiz/1/catalog` | the catalog |
| `xiz/1/file-mac` | content digests (§6.3) |

### 6.2 Keys block

```
magic        "XKEY"
count        u16      number of stanzas
stanzas      count × (type u8, length u16, body[length])
crc          u32      CRC32C of everything before it
```

Stanza type 1, **password** (body 104 bytes):

| Offset | Size | Field |
|---:|---:|---|
| 0 | 4 | Argon2id memory, KiB |
| 4 | 4 | Argon2id iterations |
| 8 | 4 | Argon2id parallelism |
| 12 | 32 | salt (random) |
| 44 | 12 | AES-GCM nonce (random) |
| 56 | 32 | wrapped file key |
| 88 | 16 | AES-GCM tag |

`KEK = Argon2id(password as UTF-8, salt, iterations, memory, parallelism, 32 bytes)`, no secret
and no associated data. The wrapped key is `AES-GCM(KEK, nonce, file key)` with associated data
`superblock[0..<60] ‖ 0x01 ‖ body[0..<44]`: changing the superblock or the KDF parameters makes
unwrapping fail. A wrong password is detected by the tag; there is no separate verifier.

Readers **must** refuse memory outside 19,456–2,097,152 KiB, iterations outside 1–10 and parallelism
outside 1–16. Writers use 262,144 KiB, 3 iterations, parallelism 4. Unknown stanza types are
skipped; an archive with no stanza a reader can open is refused.

### 6.3 Digests and chunking

In an encrypted archive the `digest` field is HMAC-SHA-256 under the `file-mac` key, so the
catalog never holds an unkeyed hash of plaintext. Writers that cut content into chunks derive the
chunker's parameters from the key (Xipper: the gear table is seeded with
`HMAC(file-mac key, "xiz/1/chunker")`), so chunk boundaries reveal nothing.

### 6.4 Frames

Frame *i* is `AES-GCM(data key, nonce, compressed payload, associated data)` with

- `nonce = 00 00 00 00 ‖ u64 big-endian(i)`;
- `associated data = "XIZ1frame" ‖ archive_id ‖ u32(i) ‖ codec ‖ flags ‖ u16(dictionary) ‖ u32(usize)`.

The output is ciphertext followed by the 16-byte tag. Each data key encrypts one archive only
(it depends on `archive_id`), so the counter nonce is never reused.

### 6.5 Catalog (STREAM)

The compressed catalog is split into 65,536-byte chunks (the last one may be shorter or empty).
Chunk *n* is `AES-GCM(catalog key, nonce, chunk, associated data)` with

- `nonce = 00 00 00 ‖ last ‖ u64 big-endian(n)`, where `last` is 1 for the final chunk and 0 otherwise;
- `associated data = "XIZ1catalog" ‖ archive_id ‖ u16(version_major) ‖ u16(version_minor) ‖
  u64(catalog_usize) ‖ u32(frame_count) ‖ u32(entry_count) ‖ u64(total_bytes) ‖ u64(previous_footer)`
  (the footer fields).

Sealed chunks (ciphertext ‖ tag) are concatenated. A reader **must** fail if a chunk does not
authenticate, if the final chunk is not marked `last`, or if anything follows it. Because the
catalog lists every frame with its CRC and the AEAD covers its position, truncation, reordering
and swapping of frames between archives are detected.

What stays visible in an encrypted archive: the superblock, the KDF parameters, the number and
sizes of frames and the footer counters. Names, sizes of entries, metadata and content do not.

## 7. Footer (96 bytes)

| Offset | Size | Field |
|---:|---:|---|
| 0 | 4 | magic `XIZF` |
| 4 | 2 | version_major (= superblock) |
| 6 | 2 | version_minor |
| 8 | 8 | catalog_offset |
| 16 | 8 | catalog_csize (as written) |
| 24 | 8 | catalog_usize (decompressed) |
| 32 | 4 | frame_count |
| 36 | 4 | entry_count |
| 40 | 8 | total_bytes: sum of the sizes of all entries |
| 48 | 32 | catalog_sha256 |
| 80 | 8 | previous_footer: 0 in 1.0 (reserved for `append_chain`) |
| 88 | 4 | CRC32C of bytes 0–87 |
| 92 | 4 | tail magic `XIZ!` |

`catalog_offset + catalog_csize` must equal `file_size − 96`. `frame_count`, `entry_count` and
`total_bytes` must match the catalog. A reader compares `total_bytes` with free space and its
limits **before** writing anything: expansion can be large (deduplication is legitimate) but it is
always declared and authenticated.

## 8. Reading, in order

1. Read and check the superblock (magic, CRC, version, required features).
2. If encrypted: read the keys block, check its CRC, derive the file key from the password.
3. Read and check the footer (magic, CRC, tail, catalog location).
4. Read the catalog, check its SHA-256, decrypt (if encrypted), decompress to exactly `catalog_usize`, parse.
5. Check frames: contiguous from `data_start` to `catalog_offset`, `usize` ≤ 64 MiB, consistent codec sizes.
6. Check entries: extents inside frames, sums equal to sizes, total equal to `total_bytes`.
7. Extract: per frame, compare the header with the catalog, check the CRC, decrypt, decompress to
   `usize`; per file, assemble the extents and compare the digest when present.

## 9. Version 0.1 (beta)

Xipper 0.9 betas wrote version 0.1. Superblock, frame headers and footer have the same layout with
all 1.0 fields zero; the catalog has `version = 0` and fixed records instead of TLV fields (frame
records of 21 bytes without flags and dictionary; entries with mode, uid, gid, mtime, size, link,
xattrs, extents and an optional SHA-256 in a fixed order). 0.1 had no encryption. Readers may
support it; writers must not produce it.

## 10. Evolution

- New entry fields: new tags (critical when old readers must not ignore them).
- New capabilities that change how data is read: a new required feature bit (old readers refuse
  the archive with a clear message), with `version_minor` incremented.
- Data old readers can ignore: an optional feature bit.
- `version_major` changes only for an incompatible redesign.
