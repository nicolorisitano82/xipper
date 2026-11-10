# XIZ archive format, version 1.10

Status: **stable**. 1.0 frozen on 2026-10-22; 1.1 (same day) adds appended segments (§11) and 1.2
(2026-10-23) zstd dictionaries (§12); older readers refuse both cleanly. **1.3** (2026-10-25, released with
Xipper 2.2.0) adds access groups, k-of-n threshold keys, signed segments, erasable entries and
inclusion proofs (§13). **1.4** (2026-11-02, Xipper 2.6) adds LZMA2 frames with an optional ARM64
branch filter (§14). **1.5** (2026-11-03, Xipper 2.7) adds an optional recovery record at the end of the
file (§15), which every reader since 1.1 skips. **1.6** (2026-11-03, Xipper 2.7) adds JPEG files
recompressed losslessly with brunsli, one per frame (§16). **1.7** (2026-11-09, Xipper 3.0) adds
post-quantum recipients and custodians with the hybrid KEM X-Wing (§17), which older readers skip. **1.8**
(2026-11-10, Xipper 3.0) adds frames compressed with Apple's LZRAVEN and LZMESH (§18), macOS 27 only. **1.9** (2026-11-10, Xipper
3.0) adds PNG, PDF and ZIP-based documents with their Deflate streams recompressed losslessly (§19). **1.10**
(draft, 2026-11-10, xipper-forensic) adds the **forensic profile** (§20): disk images, source hashes, a
cryptographic hash of every frame, unreadable-sector maps, case and custody records. Reference implementation: `Sources/XipperKit/Xiz/` in Xipper (MIT).
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
| 10 | 2 | version_minor | the highest minor version whose features the archive uses (0–10) |
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
| 5 | lzma2 | 1.4: frames with codec 2 (LZMA2) or 3 (ARM64 + LZMA2) (§14) |
| 6 | jpeg | 1.6: frames with codec 4 (a JPEG file recompressed with brunsli) (§16) |
| 7 | apple | 1.8: frames with codec 5 or 6 (Apple's LZRAVEN, LZMESH) (§18) |
| 8 | deflate | 1.9: frames with codec 7 (a document with its Deflate streams split by preflate) (§19) |
| 9 | forensic | 1.10: forensic profile: directory version 3 with a forensic block in every segment (§20) |
| 10–15 | — | reserved, zero |

**Optional features**: a reader **may** ignore them. Bit 0 (`recovery`) is reserved and never set:
the recovery record (§15) can be added to an existing archive, whose superblock is never rewritten,
so readers find it by its trailer. Bits 1–15 are reserved and zero. Recovery data can also be
written as standard **PAR2** files next to the archive (`name.xiz.par2`, `name.xiz.volNN+MM.par2`).

`encrypted` is set if and only if `keys_length > 0`. `keys_length` must not exceed 65,536.

## 4. Frames

### 4.1 Frame header (32 bytes)

| Offset | Size | Field |
|---:|---:|---|
| 0 | 4 | magic `XFR1` |
| 4 | 1 | codec: 0 = store, 1 = zstd, 2 = LZMA2, 3 = ARM64 + LZMA2 (2 and 3 need `lzma2`, §14), 4 = brunsli JPEG (needs `jpeg`, §16), 5 = LZRAVEN, 6 = LZMESH (need `apple`, §18), 7 = preflate document (needs `deflate`, §19) |
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
- `LZMA2`, `ARM64 + LZMA2`: see §14.
- `brunsli JPEG`: see §16.
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
- **Versions.** Since nothing written changes, the file's first bytes up to the end of any footer in
  the chain are a complete archive: the archive as it was after that segment. Xipper lists them
  (`xipper versions`) and reads one (`--version N`) from an APFS clone cut at that footer; only
  erased slots (§13.7) are erased in every version, since erasing overwrites them in place.

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

## 14. Version 1.4: LZMA2 frames

An archive with frames of codec 2 or 3 sets the required feature `lzma2` (superblock bit 5,
`version_minor = 4`); readers without it refuse the archive. A frame with codec 2 or 3 in an archive
without the bit is invalid.

- **Codec 2, LZMA2**: the payload (before encryption) is one byte, the LZMA2 dictionary property as
  in xz and 7z (`dictionary = (2 | (p & 1)) << (p / 2 + 11)`, at most the value for 64 MiB), followed
  by raw LZMA2 chunks ending with the end marker `0x00`. The first chunk resets the dictionary and
  sets new properties. The data decompresses to exactly `usize` bytes; a reader **must** reject any
  other length and data after the end marker.
- **Codec 3, ARM64 + LZMA2**: as codec 2; the decompressed bytes are then decoded with the ARM64
  branch filter of xz 5.4 (`lzma_bcj_arm64_decode`), start offset 0, over the whole frame. Writers
  use it for frames that are mostly arm64 executables (Mach-O, thin or universal, and ELF).
- LZMA2 frames take no zstd dictionary (`dictionary = 0`, flags bit 0 clear) and are never dictionary
  frames. The catalog stays zstd.
- Appending to an archive with `lzma2` may write frames of any codec; appending to an archive without
  it writes only codecs 0 and 1 (the superblock is never rewritten).

Xipper writes LZMA2 frames at preset 6 with the dictionary as large as the frame (4 MiB): in 4 MiB
frames preset 9 gains nothing. On the corpora of docs/BENCHMARK.md LZMA2 is about 10% smaller than
zstd 19 on executables and 3% smaller on source code, and decompresses about 10 times slower per
core; frames still decompress in parallel.

## 15. Version 1.5: recovery record

An archive may end with a **recovery record**: Reed–Solomon parity over the whole archive, so that
damaged bytes anywhere (superblock, keys block, frames, catalogs, footers) can be rebuilt from the
file alone, without the password and without separate PAR2 files. It is optional data: it changes
no feature bit and no `version_minor`, and every reader since 1.1 skips it (it looks like the tail
of an interrupted append, §11).

### 15.1 Layout

```
0                 archive: superblock … last footer          P = protected_length bytes
P                 header A                                    64
P + 64            table A                                     16 × (K + M)
                  zero padding up to the next multiple of 4096
R                 recovery slices 0 … M−1                     M × S
R + M·S           header B (copy of A)                        64
                  table B (copy of A)                         16 × (K + M)
file_size − 64    trailer                                     64
```

`P` is the end of the last footer. The protected bytes `[0, P)` are cut into `K = ⌈P / S⌉` **data
slices** of `S` bytes; the last one is padded with zeros to `S`. `R = align4096(P + 64 + 16·(K+M))`.

**Header** (64 bytes):

| Offset | Size | Field |
|---:|---:|---|
| 0 | 4 | magic `XIZR` |
| 4 | 2 | version = 1 |
| 6 | 2 | flags = 0 |
| 8 | 16 | archive_id (as the superblock) |
| 24 | 8 | protected_length `P` |
| 32 | 4 | slice_size `S`: a multiple of 4096 |
| 36 | 4 | data_slices `K` (≥ 1, = ⌈P / S⌉) |
| 40 | 4 | recovery_slices `M` (1 ≤ M ≤ K, K + M ≤ 65,536) |
| 44 | 16 | first 16 bytes of SHA256(table) |
| 60 | 4 | CRC32C of bytes 0–59 |

**Table**: `K + M` entries of 16 bytes, the first 16 bytes of the SHA-256 of each data slice (padded)
and then of each recovery slice.

**Trailer** (64 bytes, the last of the file):

| Offset | Size | Field |
|---:|---:|---|
| 0 | 4 | magic `XIZT` |
| 4 | 2 | version = 1 |
| 6 | 2 | flags = 0 |
| 8 | 16 | archive_id |
| 24 | 8 | offset of header A (= `P`) |
| 32 | 8 | offset of the recovery slices (`R`) |
| 40 | 8 | offset of header B (`R + M·S`) |
| 48 | 8 | reserved, zero |
| 56 | 4 | CRC32C of bytes 0–55 |
| 60 | 4 | tail magic `XZR!` |

### 15.2 Code

Arithmetic is in GF(2^16) with the PAR2 polynomial `x^16 + x^12 + x^3 + x + 1` (0x1100B), on
little-endian 16-bit words. Recovery slice `r` is

    R_r = Σ_{d=0}^{K−1} c(r, d) · D_d      with   c(r, d) = (x_r ⊕ y_d)^−1,  x_r = K + r,  y_d = d

a Cauchy matrix: every square submatrix is invertible, so **any** `m ≤ M` damaged data slices are
rebuilt from any `m` intact recovery slices.

### 15.3 Reading and repair

- Readers that only extract **may** use the trailer to find the footer: when the trailer is valid,
  the footer is at `P − 96`. Otherwise they search for the footer as after an interrupted append (§11).
- A repairer locates the record from the trailer; when the trailer is damaged it searches backwards
  for a header with a valid CRC at `P` or at `R + M·S` as computed from its own fields. A header is
  used only with a table that matches its hash. Header A and B are interchangeable.
- A slice is intact when its SHA-256 prefix matches the table. If the damaged data slices are no more
  than the intact recovery slices, they are rebuilt and checked against the table before being written.
- The record never decides what is extracted: rebuilt bytes still pass every check of §8 (CRC, catalog
  hash, AEAD tags, digests).
- The archive must not shrink below `P`: a file truncated inside the protected region cannot be
  repaired (header A lies beyond it). Truncation inside the record only loses the slices past the end.

### 15.4 Writing

- A writer computes the record over the finished archive and appends it after the last footer.
- Appending a segment (§11) first truncates the file at the end of the last footer, removing the
  record; the writer then writes a new record over the longer archive if it wants one.
- Xipper chooses `S` so that `K` stays near 2,000 (at least 4 KiB, at most `K = 32,768`) and `M =
  ⌈K × redundancy⌉` (default 10%): the record then repairs damage up to 10% of the archive, in as
  many places as there are recovery slices.

## 16. Version 1.6: JPEG recompression

An archive with frames of codec 4 sets the required feature `jpeg` (superblock bit 6,
`version_minor = 6`); readers without it refuse the archive. A frame with codec 4 in an archive
without the bit is invalid.

- **Codec 4, brunsli JPEG**: the payload (before encryption) is one brunsli stream, the lossless JPEG
  recompression of [google/brunsli](https://github.com/google/brunsli) (reference: its `c/dec` decoder;
  Xipper uses commit `c18b962`). Decoding it gives back the original JPEG file byte for
  byte, exactly `usize` bytes; a reader **must** reject any other length.
- The frame holds **one whole file**: the extents of the entries that use it cover the frame from
  offset 0 to `usize`. Files of up to 64 MiB qualify. Brunsli frames take no zstd dictionary
  (`dictionary = 0`, flags bit 0 clear).
- Readers decode brunsli streams that come from the archive, i.e. from anyone: they **should** run the
  decoder isolated from the rest of the process (Xipper uses its sandboxed `xipper-decoder` helper).
  The entry digests (§5) still check every rebuilt file.
- Appending to an archive with `jpeg` may write frames of any codec; appending to an archive without
  it never writes codec 4.

Xipper writes codec 4 only when asked (`xipper create --jpeg`, «Foto JPEG più piccole» in Settings),
for files with a JPEG extension that start with `FF D8 FF`, and only after decoding the stream again
and comparing it with the file: a JPEG that brunsli refuses, or that would be less than 3% smaller,
goes into an ordinary frame. Identical JPEGs are stored once (whole-file deduplication; JPEG files are
not cut into chunks). On JPEG photos the frame is about 78–84% of the file; brunsli runs at about
15–20 MB/s per core in each direction on an M3 Max, and frames are coded in parallel.

## 17. Version 1.7: post-quantum recipients

XIZ 1.7 adds two keys-block stanza types (§6.2, §13.3) whose key-encryption key comes from
**X-Wing**, the hybrid KEM that combines ML-KEM-768 (FIPS 203) with X25519
([draft-connolly-cfrg-xwing-kem](https://datatracker.ietf.org/doc/draft-connolly-cfrg-xwing-kem/)).
An attacker has to break both to open the stanza, so an archive recorded today stays closed even
for a future quantum computer ("harvest now, decrypt later"). Signatures (§13.5) stay Ed25519: they
cannot be forged retroactively.

| Type | Name | Header | KEK |
|---:|---|---|---|
| 6 | post-quantum recipient | X-Wing ciphertext[1120], recipient key id[8], label | HKDF-SHA-256(X-Wing shared secret, salt = key id, info `xiz/1.7/xwing`) |
| 7 | post-quantum custodian share | threshold id u8, x u8, X-Wing ciphertext[1120], recipient key id[8], label | as type 6; the sealed plaintext is the share (32 bytes) |

- The X-Wing public (encapsulation) key is 1216 bytes, the private key its 32-byte seed. The key id is
  the first 8 bytes of SHA-256 of the 1216-byte public key, as for X25519 (§13.3).
- The writer encapsulates to the recipient's public key once per stanza; the reader decapsulates
  with the identity whose key id matches. X-Wing rejects a damaged ciphertext implicitly (a different
  shared secret), so a damaged stanza simply does not open; the AES-GCM tag and the keys-block CRC
  catch it as for the other types.
- Bundles, nonces, associated data and labels are exactly as in §13.3. Type 7 belongs to the
  threshold group with the same id; its shares combine with those of type 5 stanzas.
- **No feature bit.** Readers skip stanza types they do not know (§6.2): an archive with recipients
  of types 6 and 7 next to passwords or X25519 keys still opens in readers since 1.3 with those
  credentials, and only the post-quantum part needs a 1.7 reader. `version_minor = 7` when the keys
  block has a stanza of type 6 or 7.
- Each post-quantum stanza takes about 1.2 KB of the 64 KiB keys block, so an archive holds about
  50 of them.

Key texts: public `xizpq1` + base64url of the 1216-byte key; secret `XIZ-SECRET-KEY-PQ-1-` +
base64url of the seed (the X25519 ones stay `xizpk1…` and `XIZ-SECRET-KEY-1-…`). Xipper creates
them with `xipper keygen --pq` or in Settings › Keys, where new identities are post-quantum by
default.

## 18. Version 1.8: Apple's LZRAVEN and LZMESH

An archive with frames of codec 5 or 6 sets the required feature `apple` (superblock bit 7,
`version_minor = 8`); readers without it refuse the archive, and a frame with codec 5 or 6 in an
archive without the bit is invalid.

- **Codec 5, LZRAVEN** and **codec 6, LZMESH**: the payload (before encryption) is the output of
  `compression_encode_buffer` with `COMPRESSION_LZRAVEN` (0xD05) or `COMPRESSION_LZMESH` (0xE05) of
  Apple's Compression framework on the frame's data. These formats are not documented; the only
  decoder is the same framework, from **macOS 27** on. Readers elsewhere refuse the archive
  (`xiz_has_apple_codecs()` in libxiz).
- Decoding must give exactly `usize` bytes: readers decode into room for `usize + 1` and reject any
  other length. Frames take no zstd dictionary (`dictionary = 0`).
- A writer that finds the output not smaller than the data stores the frame (codec 0).
- Appending to an archive with `apple` may write frames of any codec; appending to one without it
  never writes codec 5 or 6.

Xipper writes them only when asked (`--lzraven`, `--lzmesh`, «Codec di Apple» in Settings, on macOS
27). On 481 MB of compiler binaries and libraries (M3 Max, all cores): LZRAVEN 98.3 MB against 105.4
MB for LZMA2 (§14), verified in 0.23 s against 0.37 s; LZMESH 133 MB against 136 MB for zstd 12 and
151 MB for zstd 3, written in 0.75 s against 1.7 s and 0.55 s (docs/BENCHMARK.md).

## 19. Version 1.9: Deflate streams recompressed

An archive with frames of codec 7 sets the required feature `deflate` (superblock bit 8,
`version_minor = 9`); readers without it refuse the archive, and a frame with codec 7 in an archive
without the bit is invalid. Like a JPEG frame (§16), a codec 7 frame holds **one whole file** of up to
64 MiB, with no zstd dictionary.

Deflate is weak next to zstd and LZMA2, and PNG images, PDF files and ZIP-based documents (DOCX,
XLSX, PPTX, ODF, EPUB) are made mostly of Deflate streams. A codec 7 frame stores such a file
"split": the bytes outside the streams as they are, each stream's uncompressed data, and the
reconstruction information computed by [preflate](https://github.com/deus-libri/preflate) (Apache-2.0;
Xipper uses commit `609eefa`, version 0.3.5), which rebuilds the original stream bit for bit from the
uncompressed data. The split form compresses much better than the file.

**Payload** (before encryption): `inner u8 ‖ split_size u32 ‖ compressed split form`, where `inner`
is 1 for one zstd frame (§4.2) or 2 for an LZMA2 payload as in §14 (without the ARM64 filter), and the
compressed data decodes to exactly `split_size` bytes. Readers **must** refuse `split_size` above
256 MiB.

**Split form**, little-endian:

```
"XPF1" ‖ count u32 ‖ count × segment ‖ data area ‖ reconstruction area
segment = 0 ‖ length u32                                    bytes kept as they are
        | 1 ‖ unpacked u32 ‖ diff u32                        a raw Deflate stream
        | 2 ‖ chunks u32 ‖ chunks × length u32 ‖ zlib_header[2] ‖ trailer u32 ‖ unpacked u32 ‖ diff u32
                                                             the IDAT chunks of a PNG
```

The data area holds, in segment order, the literal bytes, each stream's uncompressed data, and for
type 2 the `trailer` bytes (the zlib Adler-32 and anything after the stream) followed by the
uncompressed data; the reconstruction area holds each stream's preflate record (`diff` bytes), in the
same order. The two areas must add up exactly to the rest of the split form.

**Rebuilding** the file appends, in order: literal bytes; for type 1 the stream that
`preflate_reencode(record, data)` gives; for type 2 the zlib stream `zlib_header ‖ preflate_reencode(record,
data) ‖ trailer`, cut into IDAT chunks of the given lengths, each written as
`length u32be ‖ "IDAT" ‖ data ‖ CRC-32(type ‖ data) u32be`. The result must be exactly `usize` bytes.

- Readers decode untrusted records: they **should** run preflate isolated from the rest of the process
  (Xipper uses its sandboxed `xipper-decoder` helper). The entry digests (§5) still check every file.
- Writers keep a split only after rebuilding the file from it and comparing; Xipper finds the streams
  of a PNG (consecutive IDAT chunks holding one zlib stream), of a PDF (`stream` followed by a zlib
  stream) and of a ZIP (deflated, unencrypted entries from the local headers), and stores the file as
  usual when nothing can be split or the frame would not be at least 3% smaller than the file
  compressed as usual. It uses LZMA2 for the split form at «Massimo» and zstd at the archive's level
  otherwise.
- Appending to an archive with `deflate` may write frames of any codec; appending to one without it
  never writes codec 7.

On real files (docs/BENCHMARK.md) the archive shrinks by 31% for PNG images, 17% for PDF files and 13%
for Office and EPUB documents against LZMA2 on the files as they are, at 10–28 MB/s each way; every
file was rebuilt identical. Xipper writes codec 7 only when asked (`xipper create --documents`,
«PNG, PDF e documenti più piccoli» in Settings).

## 20. Version 1.10: forensic profile

Status: **draft** (xipper-forensic, docs/XIPPER_FORENSIC.md); it may still change before xipper-forensic 0.9.

An archive made as digital evidence sets the required feature `forensic` (superblock bit 9,
`version_minor = 10`) together with `directory` (§13); readers without it refuse the archive. The
profile adds what a court copy needs and a plain archive lacks: the hashes of the **source** as it was
read, a cryptographic hash of **every frame** (so a random read is verified, not only a full one),
the map of **unreadable sectors**, the **case**, **device** and **acquisition** records, the
acquisition **log**, and **custody** records that anyone in the chain can append without the keys to
the content. Everything the profile adds is plaintext and covered by the segment's signature, so it
can be checked without any key.

Rules for an archive with `forensic`:

- codecs 0 and 1 only; the features `dictionaries`, `lzma2`, `jpeg`, `apple` and `deflate` are clear;
- no erasable entries: directory flag `erasable` clear, no frame with flags bit 1 (§13.7);
- every segment's directory has version 3 (§20.1) and a forensic block (§20.2);
- every segment **must** be signed (§13.5). A reader that only extracts may read an unsigned segment;
  a verifier reports it as a failure of the profile.

### 20.1 Directory version 3 and custody segments

Version 3 of the directory (§13.1) adds, after `merkle_root`, in the signed part:

```
forensic_offset   u64   position of this segment's forensic block
forensic_length   u32   its length
forensic_sha256   [32]  SHA-256 of the block as written
```

and flags bit 1, `custody`. Version 3 is used only with `forensic`, and `forensic` only with version 3.

A **normal segment** is laid out as in §13.1 with the forensic block between the leaf table and the
directory:

```
frames · group catalogs · leaf table · forensic block · directory · footer
```

A **custody segment** (flags bit 1) adds nothing to the content. It is only

```
forensic block · directory · footer
```

right after the previous footer. Its directory repeats the previous directory's group records byte for
byte (same `segment` numbers, offsets and hashes: the catalogs stay those of the segment that wrote
them, and keep their nonces), its leaf fields, and its footer repeats the previous footer's
`frame_count`, `entry_count` and `total_bytes`. A custody segment can therefore be written, and
signed, by someone who holds no key to the content: a courier, a court clerk, an expert for the other
party. Its forensic block holds custody records (§20.2), not frame hashes.

The region an earlier segment occupies between frames (§11, §13.1) runs from its first own group
catalog, or from its forensic block for a custody segment, to the end of its footer.

### 20.2 Forensic block

```
magic          "XFOR"
version        u16 = 1
segment        u32       the segment it belongs to (0 for the first)
record_count   u32
records        record_count × (type u16, length u32, value[length])
crc            u32       CRC32C of everything before it
```

The block is at most 64 MiB. Bit 15 of a record type marks it **critical**: a reader **must** refuse a
block with an unknown critical type and skip unknown other types. JSON values are UTF-8 objects
(RFC 8259); readers ignore keys they do not know.

| Type | Name | Value | Where |
|---|---|---|---|
| 0x8001 | frame hashes | `first u32`, `count u32`, `count` × SHA-256 of (frame header ‖ payload as written), `root[32]` | exactly once in each normal segment, for the frames it writes |
| 0x0002 | case | JSON: `case_number`, `evidence_number`, `examiner`, `organization`, `location`, `description`, `notes` | first segment, once |
| 0x0003 | device | JSON: `path` (the entry), `model`, `serial`, `firmware`, `capacity`, `interface`, `bridge`, `encryption`, `smart`, `write_blocker` | once per acquired device |
| 0x8004 | source hashes | `path_length u16`, `path`, `size u64`, `which u8` (bit 0 MD5, 1 SHA-1, 2 SHA-256), `md5[16]`, `sha1[20]`, `sha256[32]`, `started i64`, `finished i64` (milliseconds since 1970 UTC) | once per image entry (§20.3) |
| 0x8005 | unreadable sectors | `path_length u16`, `path`, `count u32`, `count` × (`offset u64`, `length u64`, `error i32`, `attempts u16`, `reserved u16`) | once per image entry with read errors |
| 0x0006 | log | JSON Lines: one object per event, with `t` (UTC, RFC 3339) and `event` | any segment |
| 0x0007 | custody | JSON: `from`, `to`, `reason`, `seals`, `notes`, `time` | custody segments, any segment |
| 0x0008 | acquisition | JSON: `tool`, `tool_version`, `os`, `hardware`, `method` (`physical`, `volume`, `logical`), `started`, `finished`, `operator`, `notes` | segments that acquire |

- **Frame hashes**: `first` is the index of the first frame the segment writes and `count` how many it
  writes (frames are numbered across segments, §11). The hash covers the 32-byte frame header and the
  payload exactly as written (ciphertext and tag when encrypted), so it is checked without the
  password. `root` is the Merkle root (RFC 6962 §2.1, as in §13.6) over leaves whose data is
  `u32(frame index) ‖ frame hash`, in index order; it lets a later proof show that one frame (a range
  of sectors) belongs to the signed archive. Every frame of the archive is covered by exactly one
  record. The signature covers the directory, which holds `forensic_sha256`: a frame changed, even
  with its CRC corrected, no longer matches a signed hash.
- **Source hashes** are computed while reading the source, before compression. They are not the
  archive's digests: `sha256` must equal the SHA-256 of the entry's content (for an image whose
  unreadable sectors were filled with zeros, of the content with those zeros); MD5 and SHA-1, when
  present, are for comparison with other tools and reports. Unused hashes are zeros.
- **Unreadable sectors**: ranges sorted, not overlapping, inside the entry. Their bytes in the entry
  are zeros that did not come from the source.

### 20.3 Image entries

A disk or volume image is a file entry (§5.2) with the non-critical field `0x000C image` (24 bytes):

```
block_size        u32   4,194,304
logical_sector    u32   the source's logical sector size (512, 4096)
physical_sector   u32   its physical sector size
flags             u32   bit 0: volume (a partition), 0: whole device
offset            u64   the volume's byte offset in its device, 0 for a whole device
```

Readers that ignore the field see an ordinary file: the raw image. The profile adds a fixed layout so
that the bytes at a given offset are found without the catalog and verified frame by frame:

- the entry has `⌈size / block_size⌉` extents; extent *i* holds stream bytes `[i·B, min((i+1)·B, size))`
  with offset 0 in its frame;
- its frame is either a frame of its own (holding block *i* only, referenced by no other extent), or
  the archive's **zero frame**: one frame of `B` zero bytes that only blocks made entirely of zeros
  reference. No other deduplication happens inside an image;
- the entry carries `digest` (§5.2) and `proof` (§13.6), and a source hashes record (§20.2).

Logical acquisitions (folders, mailboxes) are ordinary entries without `image`, under one folder
(xipper-forensic: `evidence/`). The file `forensic/inventory.jsonl` lists, one JSON object per line,
**every** item found in the sources, acquired or not (`path`, `kind`: file, folder, link, socket, fifo,
device, other; `status`: acquired, unreadable, skipped; `sha256` of acquired files; file-system metadata
such as `size`, `mode`, `uid`, `gid`, `inode`, `flags`, `mtime`, `ctime`, `atime`, `birthtime`;
`error`, `target`), and the acquisition record carries its SHA-256 as `inventory_sha256`. Since the
record is signed, the inventory is too, and through it the SHA-256 of every acquired file.

### 20.4 Verification

A verifier reports each check separately, never a single "valid":

1. structure (§8) and, when present, the recovery record (§15);
2. every frame against its frame hash, every frame hash record against its Merkle root;
3. every segment: directory version 3, forensic block hash and CRC, signature, chain (§13.5),
   time-stamp; custody segments: catalogs, leaves and counts equal to the previous segment's;
4. every image: layout (§20.3), content SHA-256 equal to the source SHA-256, unreadable sectors listed;
   every logical acquisition: the inventory's SHA-256 equal to `inventory_sha256`, each acquired file
   equal to its line, no file outside `forensic/` missing from the inventory;
5. optionally, the SHA-256 the user copied from the acquisition report: a truncated archive (its last
   segments removed) or one rebuilt and re-signed by the key holder can only be told apart by such an
   external reference.

Reading the content needs the password or a recipient key when the archive is encrypted; checks 2, 3
and the source hashes do not.
