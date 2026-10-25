# XIZ archive format, version 1.3

Status: **stable**. 1.0 frozen on 2026-10-22; 1.1 (same day) adds appended segments (§11) and 1.2
(2026-10-23) zstd dictionaries (§12); older readers refuse both cleanly. **1.3** (2026-10-25, released with
Xipper 2.2.0) adds access groups, k-of-n threshold keys, signed segments, erasable entries and
inclusion proofs (§13). Reference implementation: `Sources/XipperKit/Xiz/` in Xipper (MIT).
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
- "zstd frame" means one complete Zstandard frame (RFC 8878), without dictionary unless the frame
  names one (§12).
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
| 10 | 2 | version_minor | 0; 2 when `dictionaries` is set |
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
| 1 | dictionaries | 1.2: dictionary frames and frames compressed with them (§12) |
| 2 | append_chain | reserved, never set (appended segments are signalled by the footer, §11: the superblock is authenticated by the keys block and is never rewritten) |
| 3 | genomic_codecs | reserved for the genomic profile XIG (docs/XIG_DESIGN.md), not yet specified |
| 4 | directory | 1.3: catalog directory, access groups, threshold keys, signed segments (§13) |
| 5–15 | — | reserved, zero |

**Optional features**: a reader **may** ignore them. Bit 0 (`recovery`) is reserved for embedded
recovery data; bits 1–15 are reserved and zero. Recovery data for XIZ (and any other archive) is
written as standard **PAR2** files next to the archive (`name.xiz.par2`, `name.xiz.volNN+MM.par2`).

`encrypted` is set if and only if `keys_length > 0`. `keys_length` must not exceed 65,536.

## 4. Frames

### 4.1 Frame header (32 bytes)

| Offset | Size | Field |
|---:|---:|---|
| 0 | 4 | magic `XFR1` |
| 4 | 1 | codec: 0 = store, 1 = zstd |
| 5 | 1 | flags: bit 0 = dictionary frame (§12); other bits zero |
| 6 | 2 | dictionary id: 0, or the dictionary defined (bit 0 set) or used (§12) |
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

Writers use 4 MiB frames: small files share a frame, big files span several. The order of data in
the frames is the writer's choice (Xipper sorts by extension, name, size and path, so similar files
share frames); readers follow the extents and never depend on it.

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

- `nonce = u24 big-endian(segment) ‖ last ‖ u64 big-endian(n)`, where `last` is 1 for the final
  chunk and 0 otherwise and `segment` is 0 for the first catalog (§11);
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
| 80 | 8 | previous_footer: offset of the previous segment's footer, 0 for the first (§11) |
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

## 11. Version 1.1: appended segments

An archive can change in place: a writer appends new frames, then a **complete** new catalog and a
new footer, after the current end of the file. Nothing already written changes.

- The new footer has `version_minor = 1` and `previous_footer` = offset of the footer it supersedes.
  Each earlier footer keeps pointing at its own predecessor, down to the first (`previous_footer = 0`).
- The new catalog lists every frame of every segment (frame indexes keep counting) and every entry
  of the archive as it is now: renamed and deleted entries simply change or disappear; their data
  stays in the file until the archive is rewritten ("compaction").
- Between frames, the only gaps allowed are the catalogs and footers of earlier segments: a reader
  follows the chain of `previous_footer` (offsets strictly decreasing, each footer valid, its
  catalog ending at its footer) and accepts a gap only if it is exactly such a region. Overlaps are
  never allowed.
- Encrypted archives: frames keep using `u64(frame index)` nonces (indexes are unique across
  segments); the catalog of segment *k* (k = number of earlier footers) uses `segment = k` in its
  nonce (§6.5), so no two catalogs share a nonce.
- An interrupted append leaves bytes after the last complete footer. A reader that does not find a
  valid footer in the last 96 bytes searches backwards for the last footer whose CRC is valid and
  whose catalog ends right before it; the next writer truncates the file there before appending.
- 1.0 readers refuse appended archives (they require `previous_footer = 0`).

## 12. Version 1.2: dictionaries

Many small files compress better with a zstd dictionary (RFC 8878 §5) trained on them. An archive
that uses one sets the required feature `dictionaries` (superblock bit 1, `version_minor = 2`);
readers without it refuse the archive.

- A **dictionary frame** has flags bit 0 set and `dictionary` = its ID (1–65,535). Its data
  (`usize` ≤ 1,048,576, codec `store` or `zstd` without dictionary) is a zstd dictionary in the
  ZDICT format (magic `37 A4 30 EC`) whose own dictionary ID equals the frame's. Each ID is defined
  once. Extents **must not** point into a dictionary frame.
- A **data frame** with `dictionary ≠ 0` and flags bit 0 clear has codec `zstd` and is decoded with
  that dictionary, which **must** be defined by an earlier frame (lower index).
- A frame with flags or dictionary ≠ 0 in an archive without the feature bit is invalid.
- Encryption, CRC and frame headers are unchanged: the AEAD associated data already covers the
  flags and the dictionary ID (§6.4), so a frame cannot be pointed at another dictionary.
- Appended segments (§11) may use the dictionaries of earlier segments. The superblock is never
  rewritten, so an archive created without the feature cannot gain dictionaries by appending.

Xipper trains one dictionary (112,640 bytes, zstd's `ZDICT_trainFromBuffer`) on up to 100 times
its size of files under 128 KiB, only from zstd level 9 and when such files add up to 32 MiB or
more. It uses the dictionary for frames made at least half of such files, loaded into the window
(`ZSTD_dictForceLoad`) rather than attached. On 20,000 source files (53.6 MB) the archive is 1.0%
smaller at level 12 and 1.1% at level 19, for about 0.4 s of training; at level 3 the gain is nil.

## 13. Version 1.3: access groups, threshold keys, signed segments

An archive that uses any of the following sets the required feature `directory` (superblock bit 4,
`version_minor = 3`); readers without it refuse the archive.

- **Access groups**: parts of the archive (folders) encrypted under different keys, so that each
  recipient sees and extracts only the groups it holds keys for.
- **Recipients**: the keys block can hold several recipients, each with a password or an X25519
  public key, each unlocking its own set of groups.
- **Threshold keys**: a set of groups can be unlocked only by *k* of *n* custodians together
  (Shamir secret sharing); no custodian alone can open it.
- **Signed segments**: every segment (§11) can carry an Ed25519 signature of its author, chained to
  the previous segment's signature and optionally time-stamped by an RFC 3161 authority, so the
  history of the archive's changes is attributable and tamper-evident.
- **Inclusion proofs**: every segment commits to all its entries with a Merkle tree; one file can be
  shown to belong to a (signed) archive without revealing anything else (§13.6).
- **Erasable entries**: each file can have its own key, kept in a key slot that can be overwritten in
  place; erasing the slot makes the file's content unreadable in this archive, in every segment and in
  every copy made afterwards (§13.7).

### 13.1 Layout and directory

With `directory`, the footer's catalog fields (§7) locate the **directory** instead of a catalog:
`catalog_offset`/`catalog_csize` are its position and length, `catalog_usize` equals `catalog_csize`,
`catalog_sha256` is its SHA-256. Each segment is laid out as

```
frames                 (§4; frames of a group are sealed with that group's data key)
key slots              this segment's key slot table, when it adds erasable entries (§13.7)
group catalogs         one per group, in group order
leaf table             leaf_count × 32 bytes: the Merkle leaves (§13.6)
directory              plaintext, never compressed or encrypted
footer                 (§7)
```

Directory:

```
magic             "XDIR"
version           u16 = 2 (1: the same without the fields marked *)
* flags           u16: bit 0 = erasable (§13.7: files added by later segments get key slots too);
                  other bits zero
group_count       u16, at least 1
groups            group_count × (group u16, segment u32, catalog_offset u64,
                                 catalog_csize u64, catalog_usize u64, catalog_sha256[32])
* slot_tables     u16 count, then count × (segment u32, offset u64, slot_count u32): every key slot
                  table of the archive, in segment order
* leaf_offset     u64, leaf_count u32, merkle_root[32] (§13.6)
signature_length  u32 (0: unsigned)
signature         signature_length bytes (§13.5)
crc               u32: CRC32C of everything before it
```

- `group` values are strictly increasing; group 0 is always present.
- `segment` is the segment whose nonces seal that catalog (§6.5): the current one for catalogs written
  in this segment.
- The key slot table, the group catalogs, the leaf table and the directory sit right after the last
  frame of the segment and right before the footer, in that order, with no gaps; between frames, the
  regions allowed by §11 are those of earlier segments, from their slot table (or first catalog) to
  the end of their footer.
- `frame_count`, `entry_count` and `total_bytes` in the footer are the totals over all groups.

### 13.2 Group catalogs

A group catalog is a catalog (§5) with `version = 2`:

- its frame table lists **every** frame of the archive (frame headers are public anyway), so frame
  indexes in extents stay global; each frame record is followed by `group u16`, the group whose key
  seals the frame (also written in bytes 24–25 of the frame header, §4.1, which are zero otherwise),
  so a reader knows which frames it can open, including frames no entry uses any more;
- its entries are the entries of that group only;
- after the last entry: `name_length u16`, `name` (UTF-8), `prefix_count u16`, then `prefix_count` ×
  (`length u16`, path prefix as UTF-8). Group 0 has no prefixes ("everything else").

An entry belongs to the group with the longest prefix equal to its path or to a leading run of its
path components; otherwise to group 0. Writers list a directory in the group of its own path and
**must not** let a group's extents point at frames sealed for another group: deduplication happens
inside a group only. With more than one group, dictionaries (§12) are not used.

Unencrypted archives with `directory` have exactly one group, 0, and their catalog is compressed as
in §5 but not sealed (signed segments are their main use). In encrypted archives each group catalog
is sealed as in §6.5 with that group's catalog key, nonces from the directory's `segment`, and

`associated data = "XIZ13catalog" ‖ archive_id ‖ u16(group) ‖ u32(segment) ‖ u64(catalog_usize) ‖ u32(frame_count)`

where `frame_count` is the footer's. Entry counts and sizes of a group are visible only inside its
sealed catalog.

### 13.3 Group keys and recipients

Each group has its own random 256-bit **group key**; its data, catalog and file-MAC keys are derived
from it as in §6.1. A recipient unlocks a **bundle** of group keys:

```
bundle = count u16, count × (group u16, key[32])
```

sealed with AES-256-GCM under a recipient key-encryption key (KEK), random 12-byte nonce, and
`associated data = superblock[0..<60] ‖ type ‖ header`, where `header` is the stanza body up to the
nonce. New stanza types in the keys block (§6.2):

| Type | Name | Header | KEK |
|---:|---|---|---|
| 2 | password recipient | Argon2id memory u32, iterations u32, parallelism u32, salt[32], label | Argon2id as §6.2 |
| 3 | public-key recipient | ephemeral X25519 public key[32], recipient key id[8], label | HKDF-SHA-256(X25519(ephemeral, recipient), salt = ephemeral ‖ recipient public key, info `xiz/1.3/x25519`) |
| 4 | threshold group | threshold id u8, k u8, n u8, label | HKDF-SHA-256(T, salt = archive_id, info `xiz/1.3/threshold`) |
| 5 | custodian share | threshold id u8, x u8, kind u8, then as type 2 (kind 1) or type 3 (kind 2) without the label, label | as type 2 or 3; the sealed plaintext is the share (32 bytes) instead of a bundle |

- `label` is `u8 length` + UTF-8 (who the recipient is: "Laboratorio", "DPO"…); it is visible.
- The recipient key id is the first 8 bytes of SHA-256 of the recipient's X25519 public key, so a
  reader holding several identities tries only the matching one.
- Each stanza body ends with `nonce[12] ‖ ciphertext ‖ tag[16]`.
- **Threshold**: T is a random 256-bit secret split with Shamir's scheme over GF(2^8) (polynomial
  x⁸+x⁴+x³+x+1), byte by byte, with a random polynomial of degree k−1 per byte; share *x* (1…n) is the
  32 values at *x*. Any *k* shares rebuild T by Lagrange interpolation at 0; fewer reveal nothing.
  `2 ≤ k ≤ n ≤ 255`.
- A reader opens every stanza it can with the credentials it was given (passwords, X25519
  identities, custodian credentials), unions the group keys, and shows only the groups it has keys
  for. An archive where no group can be opened is refused like a wrong password.
- Type 1 (§6.2) is not used together with `directory`.
- The keys block is written once with the superblock: adding or removing recipients rewrites the archive.

### 13.4 Appending

A writer appends a segment (§11) only if it holds the keys of **all** groups: every group catalog is
complete and rewritten in the new segment. (Holders of some groups only read.)

### 13.5 Signed segments

```
algorithm        u8 = 1 (Ed25519)
public_key       [32]
label            u8 length + UTF-8 (the signer's name, visible)
time             i64: seconds since 1970 UTC, by the signer's clock
previous         [32]: the chained digest of the previous segment's signature, zeros if the previous
                 segment is unsigned or there is none
signature        [64]
token_length     u32, then an RFC 3161 TimeStampToken (DER), or 0
```

- The signed message is
  `"XIZ13sign" ‖ archive_id ‖ u32(segment) ‖ SHA-256(directory bytes before signature_length) ‖
  u64(previous_footer) ‖ i64(time) ‖ previous ‖ algorithm ‖ public_key ‖ label`.
  The directory lists the SHA-256 of every group catalog, each catalog lists every frame with its
  CRC (and the AEAD binds each frame to its index), so the signature covers the whole segment.
  It can be checked without any key to the content.
- The **chained digest** of a signature is SHA-256(message ‖ signature); the next segment's
  `previous` must equal it. A reader reports, for every segment: signed or not, signer key and
  label, time, whether the chain holds, and the time-stamp. Which keys are trusted is up to the
  reader (Xipper keeps a list).
- The time-stamp token's message imprint is SHA-256 of the 64-byte signature. Readers verify the
  token's CMS signature and report its `genTime` and authority; a time-stamp only proves that the
  signature existed at that time.
- Writers time-stamp only when the user configures an authority URL (Xipper makes no network
  connection otherwise).

### 13.6 Inclusion proofs

Each segment commits to every entry of the archive (all groups) with a Merkle tree as in RFC 6962
§2.1 (`leaf = SHA-256(0x00 ‖ data)`, `node = SHA-256(0x01 ‖ left ‖ right)`, split at the largest power
of two below the size). Leaves are sorted by their hash bytes. A leaf's data is

`salt[16] ‖ u16(path length) ‖ path ‖ u8(type) ‖ u64(size) ‖ content_sha256[32]`

- `salt` is random per entry, so a leaf hash reveals nothing about small or guessable files;
- `content_sha256` is the plain SHA-256 of the content (of the target for symbolic links, zeros for
  directories), even in encrypted archives;
- both are stored with the entry in field `0x0009 proof` (48 bytes: salt, content SHA-256), inside the
  group's sealed catalog.

The leaf table (plaintext) lists the leaf hashes in order; the directory gives its position, its size
and the root. The root is in the signed part of the directory, so a signed segment vouches for
every leaf.

A **proof** for one entry consists of: the archive ID, the segment number, the directory bytes before
`signature_length`, the signature record, the footer's `previous_footer`, the leaf data, the leaf's
index and the audit path (RFC 6962 §2.1.1). A verifier needs no key and no other part of the
archive: it hashes the file it was given, rebuilds the leaf and the root, compares the root with
the directory, and checks the signature (§13.5). Xipper writes proofs as JSON (`xiz-proof-1`).

### 13.7 Erasable entries

An archive created with `erasable` gives each file its own random 256-bit **entry key**:

- the file's data goes into frames of its own (no other file's data, deduplication only within the
  file), with flags bit 1 set (`entry key`) and sealed with the data key derived from the entry key
  (§6.1); such frames are allowed only in encrypted archives with `directory`;
- the entry key is wrapped in a 60-byte **key slot**: `nonce[12] ‖ AES-256-GCM(slot key, entry key) ‖
  tag[16]`, with `slot key = HKDF-SHA-256(group key, salt = archive_id, info "xiz/1.3/slots")` and
  `associated data = "XIZ13slot" ‖ archive_id ‖ u32(segment) ‖ u32(index)`;
- each segment that adds such files writes its slots as one table; the directory lists every table;
- the entry carries field `0x800A key slot` (critical): `segment u32`, `index u32`, and the SHA-256 of
  the slot bytes as written.

**Erasing** an entry overwrites its 60 slot bytes with zeros, in place: the only write XIZ allows
outside appending. A reader that finds a zeroed slot reports the entry as erased and never shows its
content; a non-zero slot whose SHA-256 differs from the stored one is corruption. Signatures and
proofs stay valid: they cover the slot's hash, not the slot. The erased entry is then removed from the
catalog by appending a segment (when the eraser holds every group); its name stays in the sealed
catalogs of earlier segments, readable by holders of its group key, until the archive is rewritten.
Copies of the archive made before the erasure still hold the slot.
