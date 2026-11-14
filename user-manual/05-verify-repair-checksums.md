# 5. Verifying, repairing and checksums

## Verify

**Verify** (toolbar), or **Verify with Xipper** in the Finder, checks every entry of an archive without writing anything. It decompresses each one and compares it with the checksum the archive stores (CRC-32, SHA-256, AES authentication).

For XIZ, verification also checks:
- the catalog's hash;
- every frame's checksum;
- the signatures and their chain.

A damaged entry is named in the report, together with what failed.

```bash
xipper test archive.7z
xipper test --sha256 archive.zip > SHA256SUMS   # also a sha256sum-style list of the content
```

## Recovery data

Recovery data lets Xipper rebuild an archive that was damaged later: a bad sector, a broken download, a flipped bit.

| Format | Where it is |
|---|---|
| **XIZ** | Inside the archive, so it travels with every copy. Any XIZ reader can open the archive with it, and readers that don't know about it simply ignore it |
| **Others** | `.par2` files next to the archive, compatible with par2cmdline and MultiPar |

How to add it:
- in the inspector, **Recovery Data › Create Recovery Data**;
- for every new archive, **Settings › General › Recovery Data**.

**Redundancy** (5%, 10% or 20%) is the share of the archive that can be lost and rebuilt.

**Settings › General › Check XIZ archives with recovery data every month** runs a quiet check in the background and tells you if something needs repair.

### Repairing

When an archive with recovery data fails its check, the error offers **Repair**. PAR2 repair also finds blocks moved by an insertion or a deletion, so they don't use up recovery data.

```bash
xipper recovery add --redundancy 10 archive.xiz   # add, remove or inspect the record inside an XIZ
xipper scrub archive.xiz                          # check every byte against the recovery record
xipper repair archive.xiz                         # rebuild damaged bytes in place (no password needed)
xipper par2 create --redundancy 10 archive.zip    # PAR2 files for any other file
xipper par2 repair archive.zip.par2
```

## Repairing a ZIP without recovery data

A ZIP file damaged at its end, such as an interrupted download or a truncated copy, often loses only its directory. **Repair** rebuilds the directory from the entries themselves:
- entries are copied without recompressing them;
- those that fail their CRC are left out and listed;
- the original is never changed: the result is a new file, `name (riparato).zip`.

```bash
xipper repair -o fixed.zip damaged.zip
```

## Checksums

**File › Compute Checksums…** and **File › Verify Checksums…** work on files, folders and the content of archives.

Algorithms:
- SHA-256 (default), SHA-512, SHA3-256, BLAKE3;
- XXH3, XXH128;
- SHA-1, MD5, CRC-32, CRC-32C.

The lists are compatible with `sha256sum -c` and `b3sum -c`, or written as BSD-tagged lines or JSON.

```bash
xipper hash -a sha256,blake3 -o SUMS ~/Delivery           # several algorithms
xipper hash --contents archive.zip                        # the files inside, without extracting
xipper hash -c SHA256SUMS                                 # check a list
```

For genomic data, `xipper manifest` writes DRS-style JSON manifests ([chapter 9](09-genomics.md)).
