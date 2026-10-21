# Integrity, Encryption and Recovery for Archive Formats (inputs for the Xipper format)

Scope: cryptographic and robustness design of archive formats. What existing formats get wrong, what a modern format should do, with ARM64 / Apple Silicon numbers where found. Researched 2026-10-21.

## 1. Weaknesses of existing archive encryption (ZipCrypto, WinZip AES AE-1/AE-2, 7z, RAR5)

### Takeaway
Every mainstream archive encryption scheme fails in at least one of these ways: a broken cipher (ZipCrypto), unauthenticated metadata and plaintext CRC leakage (WinZip AE-1/AE-2), no authentication of ciphertext plus optional header encryption (7z), or CBC with CRC/BLAKE2-based integrity instead of a real AEAD (RAR5). A new format should use one AEAD over all data and metadata, bind algorithm/version identifiers into the key derivation or AAD, and offer no unauthenticated legacy mode.

### Cited Findings
**ZipCrypto (PKWARE traditional encryption)**
- The Biham-Kocher known-plaintext attack (implemented in the `bkcrack` tool) recovers the internal state of ZipCrypto's keystream generator from about 12 bytes of known plaintext, at least 8 of them contiguous. The recovered state decrypts that entry and all other entries encrypted with the same password, and it can also seed a password search. — [bkcrack (GitHub)](https://github.com/kimci86/bkcrack); [generalzero notes](https://notes.generalzero.org/Crypto/Zip%20Plaintext%20Attack.html)
- Reported runtimes: about 24 min with only 12 known bytes, and about 3 min with 30 bytes. bkcrack does not work against WinZip AES. — [acceis.fr write-up](https://www.acceis.fr/?p=2523); [Devolutions, "Why you should never use ZipCrypto"](https://blog.devolutions.net/2020/08/why-you-should-never-use-zipcrypto)
- Known plaintext is easy to get for archives: file headers of common formats (XML, PNG, Office), or deflate stream structure.

**WinZip AES, AE-1/AE-2 (Kohno, ACM CCS 2004, "Attacking and Repairing the WinZip Encryption Scheme")**
- Kohno found the core secure ("exactly Encrypt-then-Authenticate" using AES-CTR plus HMAC-SHA1), but showed several practical attacks that come from how the format integrates it. — [Kohno 2004 PDF](https://cryptosec.sysnet.ucsd.edu/miscpapers/winzip-ccs04.pdf); [ePrint 2004/078](https://eprint.iacr.org/2004/078)
- **Compression-method field not authenticated.** An attacker changes the "compression method" metadata. The victim decompresses with the wrong method, gets garbage output G, and if the attacker learns G (for example the victim replies with it), the attacker learns the plaintext. This is a chosen-ciphertext attack driven by the interaction between compression and encryption. — [Kohno 2004](https://cryptosec.sysnet.ucsd.edu/miscpapers/winzip-ccs04.pdf)
- **File name not authenticated.** The file name is stored in clear and is not covered by the MAC, so an attacker can rename `F.dat` (for example to `.exe`) and send it to the wrong application. Kohno's lesson: "a file encryption utility must not only protect the integrity of the contents… but must also protect the integrity of all of the metadata… necessary for the surrounding system to correctly interpret that data." — [Kohno 2004](https://cryptosec.sysnet.ucsd.edu/miscpapers/winzip-ccs04.pdf)
- **AE-1 rollback and CRC oracle.** AE-2 implementations must also decrypt AE-1. AE-1 stores a 32-bit CRC of the *plaintext*, so an attacker can force AE-1 decryption of an AE-2 file and use CRC pass/fail as an oracle to confirm plaintext guesses. — [Kohno 2004](https://cryptosec.sysnet.ucsd.edu/miscpapers/winzip-ccs04.pdf)
- A 2026 pyzipper advisory says that AE-1's unencrypted plaintext CRC32 still lets someone holding the archive brute-force candidate plaintexts offline, without decrypting anything. — [CVE-2026-44722 summary](https://vuln.today/cve/CVE-2026-44722)
- **Key collisions and keystream reuse.** The salt is only 8, 12 or 16 bytes (for AES-128, 192 and 256), and the CTR counter always starts at zero. With AES-128, Kohno expects key collisions, and therefore CTR keystream reuse, after only about 2^32 files across archives. — [Kohno 2004](https://cryptosec.sysnet.ucsd.edu/miscpapers/winzip-ccs04.pdf)
- **Precomputation.** The 2-byte password verification value plus a limited salt space allow salt-indexed dictionaries. — [Kohno 2004](https://cryptosec.sysnet.ucsd.edu/miscpapers/winzip-ccs04.pdf)
- **Kohno's fixes:** authenticate the whole main file record and central directory, including the compression method and file name. Mix the method version, vendor ID and strength into the salt or KDF input, so keys derived for AE-1 and AE-2 differ (this prevents rollback). Use longer salts. — [Kohno 2004](https://cryptosec.sysnet.ucsd.edu/miscpapers/winzip-ccs04.pdf)
- PKWARE's later "filename encryption" (Strong Encryption Specification) encrypts the central directory, but Kohno notes it does not by itself give chosen-ciphertext integrity. — [Kohno 2004](https://cryptosec.sysnet.ucsd.edu/miscpapers/winzip-ccs04.pdf)

**7z**
- 7z uses AES-256 in CBC mode, with the key derived by 2^19 (524,288) iterations of SHA-256. Elcomsoft says 7z does not use a salt in practice. — [Elcomsoft, Breaking RAR5 and 7Zip passwords](https://blog.elcomsoft.com/2021/04/breaking-rar5-and-7zip-passwords) (vendor source)
- Header (file name) encryption is optional and must be enabled explicitly; otherwise names and metadata leak. — [cnx-software](https://www.cnx-software.com/2011/02/22/aes-256-encryption-and-file-names-encryption-with-7-zip-7z/); [newsoftwares blog](https://www.newsoftwares.net/blog/are-zip-passwords-secure-7-zip-done-right) (vendor)
- No source found here documents a MAC or AEAD in 7z. Integrity relies on a CRC32 of the plaintext (see Gaps).

**RAR5**
- RAR5 uses AES-256 with PBKDF2-HMAC-SHA256, 2^15 = 32,768 iterations by default. RAR4 used AES-128 with a custom SHA-1 KDF at 2^18 rounds and had no password check field. — [Elcomsoft 2026, The RAR Mystery](https://blog.elcomsoft.com/2026/07/the-rar-mystery-breaking-rar4-and-rar5-encryption/)
- RAR5 format details:
  - The KDF count is stored as log2 (1 byte), with a 16-byte salt and a 12-byte password check value (8 bytes from extra PBKDF2 rounds plus a 4-byte checksum). Together with the header CRC32, this gives about 64 bits to tell a wrong password from corruption.
  - Each encrypted header has its own 16-byte IV and padding to 16 bytes.
  - Flag 0x0002 enables "tweaked", key-dependent checksums, so CRC32 or BLAKE2sp values of plaintext cannot be used to guess file content.
  - The spec defines no MAC/AEAD; integrity is CRC32/BLAKE2sp.
  — [RARLAB technote](https://www.rarlab.com/technote.htm)
- WinRAR's own FAQ: when file names are *not* encrypted, checksums of encrypted files are changed with a password-dependent algorithm, for the same reason. — [win-rar.com, RAR5 encryption](https://www.win-rar.com/encryption-winrar-improved-rar-5.html)

### Inferences
- The recurring bug is a split between the encryption boundary and the integrity boundary. Metadata that drives how plaintext is interpreted (compression method, file name, file type, size, permissions, symlink target) sits outside the MAC. A new format should authenticate *every* byte the extractor acts on: the header, the index, and per-entry metadata, all in AEAD ciphertext or AAD.
- Plaintext checksums (CRC32, BLAKE2, SHA) stored next to ciphertext act as confirmation oracles. Either encrypt them, key them (RAR5's "tweaked" approach), or drop them in favour of the AEAD tag.
- Version and algorithm IDs must be bound into the KDF info or AAD (Kohno's rollback fix), and decoders should refuse downgraded modes. Do not ship a legacy unauthenticated mode.
- Salts should be at least 128 bits, random, and per archive. Derive per-file and per-chunk keys and nonces deterministically from a random file key (HKDF), not from the password per file.

### Gaps
- Official 7-Zip documentation or source showing the exact integrity mechanism in encrypted 7z (CRC32 of unpacked data inside the encrypted stream, with no MAC) was not retrieved. This is commonly stated but not verified here.
- RARLAB's technote does not name the cipher mode. CBC comes from third-party sources (Elcomsoft) only.
- I did not read Biham and Kocher's original 1994 FSE paper ("A Known Plaintext Attack on the PKZIP Stream Cipher"). The 12-byte figure is from bkcrack's documentation.

## 2. Modern authenticated encryption for streams and archives (AES-GCM vs ChaCha20-Poly1305, STREAM, age, Tink)

### Takeaway
Use a chunked online AEAD in the STREAM style: a per-file random nonce or salt, HKDF-derived keys, a per-chunk counter nonce, and a last-chunk flag. This gives authenticated random access per chunk and detects truncation, reordering and splicing. On Apple Silicon and Graviton, AES-256-GCM is roughly 1.3x to 4x faster than ChaCha20-Poly1305, so it is the right default, with ChaCha20-Poly1305 or XChaCha as an optional fallback for CPUs without AES instructions.

### Cited Findings
**STREAM / online AE theory**
- Hoang, Reyhanitabar, Rogaway and Vizár, "Online Authenticated-Encryption and its Nonce-Reuse Misuse-Resistance" (ePrint 2015/189, also CRYPTO 2015), define OAE2 as best-possible security for a user-chosen segmentation of the plaintext. Achieving it uses simple standard tools; the paper introduces the STREAM and CHAIN constructions. — [ePrint 2015/189](https://eprint.iacr.org/2015/189)
- The same paper argues that OAE1's promise of nonce-reuse tolerance is "effectively wrong": "even for OAE2, nonce-reuse can still be devastating" and "no OAE definition can meaningfully tolerate nonce-reuse." Lesson: do not rely on misuse resistance; generate fresh random nonces per file. — [ePrint 2015/189](https://eprint.iacr.org/2015/189)

**age (C2SP age v1 spec), a concrete STREAM deployment**
- Per-file 16-byte CSPRNG nonce, with the payload key from HKDF-SHA-256 (ikm = file key, salt = nonce, info = "payload").
- 64 KiB plaintext chunks, each sealed with ChaCha20-Poly1305.
- 12-byte chunk nonce: an 11-byte big-endian counter, then a last-chunk flag byte (0x01 for the final chunk, else 0x00). The final chunk must not be empty unless the whole payload is empty.
- "Streaming decryption MUST signal an error if the end of file is reached without successfully decrypting a final chunk." This is the truncation defence.
- Seeking relative to end-of-file must first verify the final chunk. The payload must not be modified without re-encrypting under a fresh nonce.
- The header is authenticated with HMAC-SHA-256 under HKDF(file key, info = "header").
- The file key is 128-bit random and never reused.
- The scrypt recipient uses N = 2^x (x in the stanza; the spec example uses 18), r = 8, p = 1, with a 16-byte salt and a domain-separation prefix "age-encryption.org/v1/scrypt". Identities "SHOULD apply an upper limit to the work factor" (a DoS defence), and an scrypt stanza must be the only stanza.
— [C2SP age spec](https://github.com/C2SP/C2SP/blob/main/age.md)

**Tink Streaming AEAD**
- Recommended key types are AES128/256_GCM_HKDF_1MB (about 1 MB segments) and a 4 KB-segment variant for low memory. AES-CTR-HMAC-SHA256 is the "more conservative" option.
- The page describes an "independent random 7-byte" nonce prefix and a derived per-stream key. Segments are bound to their position, "cannot be removed or reordered," and cannot be moved between ciphertexts. Modifying a ciphertext requires full re-encryption, which prevents rollback.
- Partial plaintext can be obtained without processing the whole ciphertext, which gives random access. Claimed security: CCA2 with at least 80-bit authentication strength, nOAE-secure.
— [Tink Streaming AEAD docs](https://developers.google.com/tink/streaming-aead)

**Speed on ARM64 / Apple Silicon**
- Apple M2 Pro, single core, `ring` (BoringSSL assembly), 100 B to 1 KB payloads:

  | Cipher | Encrypt (MB/s) | Decrypt (MB/s) |
  |---|---|---|
  | AES-256-GCM | 661–3,131 | 1,069–3,932 |
  | ChaCha20-Poly1305 | 327–1,088 | 402–1,021 |

  AES is 134–236% of ChaCha's speed.
- Graviton 4: AES-256 encrypts at 563–2,436 MB/s vs ChaCha20 at 280–895 MB/s. The author concludes AES-256-GCM is "up to 3x" faster on modern hardware-accelerated CPUs, and notes that poor Rust bindings can cost about 3x.
— [Ash Vardanian, ChaCha vs AES 2025](https://ashvardanian.com/posts/chacha-vs-aes-2025/)
- Apple M1, 16 MiB buffers, Python `cryptography` on OpenSSL (secondary source, indicative only):

  | Cipher | Throughput (GB/s) |
  |---|---|
  | AES-128-GCM | ~3.9–4.1 |
  | AES-256-GCM | ~3.4–3.7 |
  | ChaCha20-Poly1305 | ~0.95–0.97 |

  So AES-GCM is about 4x faster for bulk data. — [MojoAuth guide](https://mojoauth.com/security-guides/aes-192-vs-chacha20-256) (secondary, vendor blog)

### Inferences
- Recommended construction for Xipper:
  - Archive master key: from Argon2id(password, 16–32-byte salt), or a random key wrapped per recipient as in age.
  - Per-entry or per-stream keys: HKDF(master, salt = random 16–32 B, info = "xipper/v1/" ‖ algorithm ID ‖ stream ID).
  - Each chunk: AEAD(key, nonce = counter ‖ last-flag, AAD = archive ID ‖ entry ID ‖ chunk index ‖ compressed/uncompressed length).
- A chunk size of 64 KiB to 1 MiB balances random-access granularity against tag overhead. The 16-byte tag is 0.024% overhead at 64 KiB and 0.0015% at 1 MiB.
- Because each chunk is independently authenticated, compression must be chunk-aligned (independent compression frames or blocks) for random access. Encrypt *after* compression (compress-then-encrypt), and authenticate the codec ID in AAD to close Kohno's compression-method attack.
- With random 96-bit nonces under one key, AES-GCM limits are a concern for very large archives. Deriving a fresh key per stream via HKDF with a random 128–256-bit salt (age/Tink style) removes this. The counter nonce is then safe because each key is used for one stream only.
- An index/footer authenticated with a final-chunk flag, or a separate MAC over the chunk-tag list, defends against truncation and against swapping whole entries between archives encrypted under the same password.
- Compression plus encryption leaks size (CRIME-style) only when attacker-controlled data is mixed with secrets. Note this risk for interactive or online use; it is not usually relevant for archives.

### Gaps
- No primary `openssl speed -evp aes-256-gcm` vs `chacha20-poly1305` numbers for M1/M2/M3/M4 at large buffer sizes were found. The two sources above are secondary or use small payloads. Recommend benchmarking locally (CryptoKit, BoringSSL, RustCrypto `aes-gcm` with ARMv8 crypto extensions).
- AES-GCM-SIV and AEGIS-128L/256 (very fast on ARMv8 AES instructions) were not researched here. AEGIS is worth evaluating as a candidate.
- The full STREAM/CHAIN definitions and the nOAE notion were not extracted from the paper body.

## 3. Password-based key derivation (PBKDF2 vs scrypt vs Argon2id) and metadata encryption

### Takeaway
Use Argon2id. RFC 9106's two recommended profiles are 2 GiB, t=1, p=4 or 64 MiB, t=3, p=4, each with a 128-bit salt. OWASP's floor is 19 MiB, t=2, p=1. Store parameters in the authenticated header and cap them at decode time against DoS. Existing archivers (7z: 2^19 SHA-256; RAR5: 2^15 PBKDF2-SHA256) are far below current guidance, which recommends 600,000 PBKDF2-SHA256 iterations even when PBKDF2 is the only option.

### Cited Findings
- RFC 9106 names Argon2id as the primary variant; it "MUST be supported," while Argon2d and Argon2i "MAY" be. — [RFC 9106 §1](https://www.rfc-editor.org/rfc/rfc9106.html)
- RFC 9106 §4 profiles, both with a 256-bit tag:

  | Profile | Iterations (t) | Lanes (p) | Memory | Salt |
  |---|---|---|---|---|
  | FIRST RECOMMENDED | 1 | 4 | 2^21 KiB (2 GiB) | 128-bit |
  | SECOND RECOMMENDED (memory-constrained) | 3 | 4 | 2^16 KiB (64 MiB) | 128-bit |

  — [RFC 9106 §4](https://www.rfc-editor.org/rfc/rfc9106.html)
- OWASP Password Storage Cheat Sheet minimums:

  | Algorithm | Recommended setting | Equivalent alternatives |
  |---|---|---|
  | Argon2id | m = 19 MiB, t = 2, p = 1 | 46 MiB/t=1; 12 MiB/t=3; 9 MiB/t=4; 7 MiB/t=5 |
  | scrypt | N = 2^17 (128 MiB), r = 8, p = 1 | — |
  | PBKDF2-HMAC-SHA256 | 600,000 iterations | — |
  | PBKDF2-HMAC-SHA512 | 220,000 iterations | — |
  | PBKDF2-HMAC-SHA1 | 1,400,000 iterations (legacy only) | — |
  | bcrypt | cost ≥ 10 (legacy only) | — |

  — [OWASP Password Storage Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html)
- Incumbent archivers: 7z uses 2^19 SHA-256 iterations (no salt per Elcomsoft); RAR5 uses PBKDF2-HMAC-SHA256 at 2^15 by default; RAR4 used 2^18 SHA-1. — [Elcomsoft 2021](https://blog.elcomsoft.com/2021/04/breaking-rar5-and-7zip-passwords); [Elcomsoft 2026](https://blog.elcomsoft.com/2026/07/the-rar-mystery-breaking-rar4-and-rar5-encryption/)
- age stores scrypt's log2(N) in the header and tells implementations to cap it, which prevents a malicious file from forcing huge KDF work. — [age spec](https://github.com/C2SP/C2SP/blob/main/age.md)
- The BLAKE3 authors explicitly say BLAKE3 "is not a password hashing algorithm" and recommend Argon2. — [BLAKE3 README](https://github.com/BLAKE3-team/BLAKE3)
- Metadata exposure: 7z headers are encrypted only when the user opts in. Kohno says file names in clear are less serious than *unauthenticated* names, but "encrypting the filename would not hurt." PKWARE added central-directory encryption in 2004. — [cnx-software](https://www.cnx-software.com/2011/02/22/aes-256-encryption-and-file-names-encryption-with-7-zip-7z/); [Kohno 2004](https://cryptosec.sysnet.ucsd.edu/miscpapers/winzip-ccs04.pdf)
- RAR5 uses one 16-byte salt for all encrypted headers and a 12-byte password check value, giving fast wrong-password detection. — [RARLAB technote](https://www.rarlab.com/technote.htm)

### Inferences
- Header encryption should be on by default whenever an archive is encrypted. The only cleartext should be a magic number, format version, KDF ID and parameters, salt, and an optional key-check value, and all of these should be AAD for the first AEAD block.
- A password check value speeds up offline guessing only by skipping decryption of one block. With Argon2id cost dominating, it is acceptable for UX. An AEAD tag failure on a small encrypted header gives the same signal without a separate verifier.
- Suggested defaults on Apple Silicon:
  - Desktop: Argon2id m = 256 MiB–1 GiB, t = 2–3, p = 4 (target about 0.5–1 s).
  - Constrained: RFC 9106's 64 MiB/t=3/p=4 profile.
  - Decoders cap memory at a few GiB unless the user overrides.
- Offer key-file and public-key recipients (X25519 / ML-KEM hybrid, as age does with plugins) alongside passwords. Use one random file key wrapped per recipient, so passwords never directly key the data.

### Gaps
- No measured Argon2id timings on Apple M-series for these parameter sets were found.
- Post-quantum recipient options (ML-KEM hybrid in age/C2SP) were not researched in this pass.

## 4. Integrity: CRC32/CRC32C vs XXH3/XXH128 vs BLAKE3 vs SHA-256; per-block vs whole-archive; Merkle trees

### Takeaway
Use the AEAD tag for integrity of encrypted data. For unencrypted archives, use a fast non-cryptographic per-block checksum (XXH3-64 or CRC32C) to detect bit rot and localize damage, plus a BLAKE3 Merkle root over content as the cryptographic whole-archive or per-file digest. BLAKE3's tree mode (Bao) allows verifying partial reads.

### Cited Findings
- xxHash benchmarks on an i7-9700K (Clang 10, -O3):

  | Hash | Bandwidth (GB/s) |
  |---|---|
  | XXH3 (AVX2) | 59.4 |
  | XXH128 (AVX2) | 57.9 |
  | XXH3 (SSE2) | 31.5 |
  | XXH64 | 19.4 |
  | Blake2 | 1.1 |
  | SHA1 | 0.8 |
  | MD5 | 0.6 |
  | memcpy (reference) | 28 |

  — [xxHash README](https://github.com/Cyan4973/xxHash)
- "xxHash is not a cryptographic hash function", so it must not be used for signatures or any purpose needing attack resistance. All variants pass SMHasher, and collision rates match the birthday paradox. — [xxHash README](https://github.com/Cyan4973/xxHash)
- BLAKE3:
  - Claimed to be much faster than MD5, SHA-1, SHA-2, SHA-3 and BLAKE2; `b3sum` is about an order of magnitude faster than `sha256sum`.
  - Has a NEON backend for ARM.
  - Its Merkle tree enables parallel hashing, verified streaming (the Bao project) and incremental updates.
  - Default output is 256 bits. It doubles as a keyed MAC (256-bit key), KDF and XOF, and resists length extension.
  — [BLAKE3 README](https://github.com/BLAKE3-team/BLAKE3)
- Apple M1 figures from a secondary source (16 MiB buffer, Python bindings):

  | Hash | Throughput (MiB/s) |
  |---|---|
  | BLAKE3, single thread | ~1,119 |
  | BLAKE3, multithreaded | ~2,779 |
  | hardware SHA-256 | ~1,359 |
  | BLAKE2b | ~605 |

  So on M1, hardware SHA-256 roughly matches single-thread BLAKE3. — [MojoAuth BLAKE2b vs BLAKE3](https://mojoauth.com/security-guides/blake2b-vs-blake3) (secondary)
- A 2024 BLAKE3 NEON update gave about 1.2x on Apple M1 and 1.3x on Cortex-A53. — [Alpine aports MR 67583](https://gitlab.alpinelinux.org/alpine/aports/-/merge_requests/67583)
- RAR5 already uses BLAKE2sp (32 bytes) as an optional file hash next to CRC32. — [RARLAB technote](https://www.rarlab.com/technote.htm)
- PAR3 replaced PAR2's MD5 with a 16-byte truncated BLAKE3 as its block fingerprint and packet checksum, and uses CRC-64-ISO as a rolling hash to find moved blocks. — [PAR3 spec](https://parchive.github.io/doc/Parity_Volume_Set_Specification_v3.0.html)
- Academic survey of hash performance on commodity hardware: [arXiv 2407.08284](https://arxiv.org/pdf/2407.08284) (not read in detail).

### Inferences
- Layered design:
  - **Per block:** a 32- or 64-bit checksum on each compressed block (CRC32C has ARMv8 CRC instructions; XXH3 has NEON). This detects corruption before decompression, so a decompressor never sees garbage, and it pinpoints which blocks to repair.
  - **Per file:** a BLAKE3-256 of the plaintext, stored in the (authenticated) index, for end-to-end and deduplication checks.
  - **Archive:** a BLAKE3 or Merkle root over the index, signable with Ed25519 or Minisign-style signatures.
- When encrypted, the AEAD tag per chunk replaces the per-block checksum. Do not store plaintext hashes in the clear (see Section 1). Use keyed BLAKE3, or place hashes inside the encrypted index.
- BLAKE3's 1 KiB chunk tree (from the BLAKE3 spec; this pass did not extract it from the PDF) allows proofs for arbitrary byte ranges. Aligning archive blocks to power-of-two multiples of 1 KiB lets the stored per-file root verify any block individually (Bao-style outboard tree).
- A 32-bit CRC gives a 2^-32 undetected-error probability per corrupted block, which is fine for bit-rot detection across millions of blocks. A 64-bit XXH3 makes it negligible. Neither gives adversarial integrity.

### Gaps
- No primary CRC32C (ARMv8 `crc32cx`) or XXH3-NEON throughput figures on Apple M-series were retrieved. The xxhash.com platform page was not fetched.
- The BLAKE3 spec PDF (chunk size, 7 rounds, 128-bit security target) was not read in this pass. Those properties are well known, but they are uncited here.

## 5. Recovery data: Reed-Solomon, PAR2/PAR3, RAR recovery records, overhead vs protection, placement

### Takeaway
Erasure codes over GF(2^16), as in PAR2/PAR3, recover any K damaged blocks from K recovery blocks (MDS when done properly). PAR3's lesson is to use guaranteed-invertible matrices (Cauchy) and to replicate unrecoverable "vital" metadata at several offsets. For Xipper: an optional Reed-Solomon recovery section over checksummed blocks, plus redundant copies of the header and index at both the start and end of the archive.

### Cited Findings
- PAR2 uses 16-bit Reed-Solomon, following Plank's tutorial with a correction. It supports up to 32,768 source blocks and 65,535 recovery blocks, over GF(2^16) with polynomial 0x1100B and generator 2. — [Wikipedia: Parchive](https://en.wikipedia.org/wiki/Parchive); [rust-par2](https://docs.rs/crate/rust-par2/latest)
- PAR2 files are made of self-contained packets, each with its own MD5 checksum, which may appear in any order and across files. Damage to one packet doesn't invalidate the rest. — [Wikipedia: Parchive](https://en.wikipedia.org/wiki/Parchive); [PAR3 spec](https://parchive.github.io/doc/Parity_Volume_Set_Specification_v3.0.html)
- A 2008 bug showed PAR2's Reed-Solomon was not strictly MDS in exceptional cases. The PAR3 spec states that PAR2's matrix was "essentially random", so it was invertible only with high probability. — [Wikipedia: Parchive](https://en.wikipedia.org/wiki/Parchive); [PAR3 spec](https://parchive.github.io/doc/Parity_Volume_Set_Specification_v3.0.html)
- PAR3 code options:
  - Any linear code. A Cauchy matrix is strongest; a single Cauchy matrix yields Reed-Solomon. Sparse random matrices are faster but slightly more likely to fail. Explicit matrices allow LDPC/Tornado codes.
  - Any GF(2^(8·k)) field, including 8-, 16- and 128-bit.
  - Block indices are 8 bytes, so more than 2^16 files and blocks are supported.
  — [PAR3 spec](https://parchive.github.io/doc/Parity_Volume_Set_Specification_v3.0.html)
- PAR3 placement and protection rules:
  - Recovery covers file *contents* only, not metadata or the code matrix.
  - "Vital" packets (Start, Matrix, Root) cannot be recovered from recovery data, so they should be repeated at different points in the file.
  - "Par inside" embeds PAR3 packets inside a host file such as a ZIP.
  - "Par inside Par" protects a PAR3 file's non-redundant parts with a second PAR3 set.
  - An incomplete or truncated file is processed as far as its available data allows.
  — [PAR3 spec](https://parchive.github.io/doc/Parity_Volume_Set_Specification_v3.0.html)
- PAR3 status: per the reference implementation, "As of January 29, 2022 The Par3 specification is in near-final form," to be finalized once the code works. — [par3cmdline](https://github.com/Parchive/par3cmdline)
- RAR5 recovery record: a service block named "RR", flagged in the main archive header (0x0008). It sits between the file headers and the end-of-archive header, and its offset can be stored in a locator record. The technote does not document the coding. — [RARLAB technote](https://www.rarlab.com/technote.htm)

### Inferences
- Overhead equals protection: with N data blocks and R recovery blocks of equal size, any R lost or corrupt blocks can be recovered (MDS codes). For example, 5% recovery corrects up to 5% of blocks, *wherever* they are. Bursts such as truncation or a bad sector run are handled because the code is erasure-based, provided per-block checksums identify which blocks are bad. This is why per-block checksums (Section 4) are a prerequisite.
- Block-size trade-off: smaller blocks waste less on scattered single-bit errors (each bit flip costs one whole block) but need more blocks. GF(2^16) caps at 65,535 total blocks per group, so large archives need larger blocks or multiple interleaved groups.
- Placement against truncation: put recovery data and a copy of the index at the *end* and a header copy at the *start*. Truncation destroys the tail, so either interleave recovery groups throughout the file, or keep the primary index at the start and use the tail recovery section only for bit rot. PAR3's "repeat vital packets" rule applies directly to Xipper's superblock and index.
- Recovery and encryption: apply Reed-Solomon over *ciphertext* blocks, so repair works without the key and tags still verify after repair. The recovery section's own metadata must be authenticated (part of the AEAD-covered index or MAC'd) so an attacker cannot use "repair" to inject data. Its integrity rests on the AEAD tags of repaired chunks.
- Leopard/FFT-based RS (O(n log n)) is what makes large-n GF(2^16) codes fast. Worth evaluating (not researched here).

### Gaps
- RAR's recovery-record algorithm (Reed-Solomon parameters, default 3% or 5%) is not documented in RARLAB's technote, and no primary source was found.
- No primary benchmarks of Reed-Solomon encode/decode speed (par2cmdline-turbo, Leopard, ISA-L) on Apple Silicon were found.
- Whether the PAR3 spec was finalized after 2022 was not confirmed.

## 6. Safety against malicious archives: zip bombs, overlapping files, path traversal (Zip Slip), symlinks

### Takeaway
Fifield's 2019 non-recursive zip bomb exploits files that *overlap* inside the container, giving 28-million-to-1 expansion. Zip Slip (2018) showed that thousands of extractors trust stored paths. A new format should make these impossible *structurally* and validate them *mandatorily*:
- A single authoritative index with non-overlapping, monotonically increasing extents.
- Declared uncompressed sizes that the decoder enforces.
- Normalized relative path components (no `..`, no absolute paths, no separators inside a component).
- Symlinks and hardlinks as typed entries that are never followed during extraction.

### Cited Findings
**Zip bombs**
- David Fifield, "A better zip bomb" (USENIX WOOT 2019): a non-recursive bomb in which overlapping files reference one compressed "kernel." At the limits of the zip format, about 10 MB expands to about 281 TB, a ratio over 28 million. Larger ratios are possible with Zip64. It uses only DEFLATE, works with most zip parsers, and output grows quadratically with input. — [USENIX WOOT '19 presentation page](https://usenix.org/conference/woot19/presentation/fifield); [paper PDF](https://www.usenix.net/system/files/woot19-paper_fifield_0.pdf)
- The classic 42.zip reaches about 4.5 PB only through six recursive layers; Fifield's construction needs no recursion. — [Fifield paper](https://www.usenix.net/system/files/woot19-paper_fifield_0.pdf)
- Sample files cited in press: 42 kB expanding to 5.5 GB, and 46 MB expanding to 4.5 PB (Zip64 variant). — [Impress Internet Watch (JP)](https://internet.watch.impress.co.jp/docs/yajiuma/1196892.html); [mytechdecisions](https://mytechdecisions.com/network-security/a-new-zip-bomb-can-turn-a-46mb-file-into-4-5-petabytes/)
- ClamAV was reported vulnerable to the technique. — [PortSwigger Daily Swig](https://portswigger.net/daily-swig/ancient-zip-bomb-attack-given-new-lease-of-life)

**Path traversal**
- Snyk's 2018 Zip Slip disclosure: arbitrary file overwrite during extraction via `../` paths. It affects tar, jar, war, cpio, apk, rar and 7z, and "thousands of projects" in JavaScript, Ruby, Java, .NET and Go, including projects from Google, Oracle, IBM, Apache and Amazon. The impact can reach remote code execution by overwriting executables or config files. — [The Hacker News](https://thehackernews.com/2018/06/zipslip-vulnerability.html); [Snyk, Behind the disclosure](https://snyk.io/de/blog/behind-the-disclosure-the-zip-slip-vulnerability/)
- Example: the npm `unzipper` package before 0.8.13 (CVE-2018-1002203). — [Snyk vuln DB](https://security.snyk.io/vuln/npm:unzipper:20180415)

**Related lessons from other formats**
- PAR3 natively represents hard and symbolic links and permissions as typed metadata. — [PAR3 spec](https://parchive.github.io/doc/Parity_Volume_Set_Specification_v3.0.html)
- Kohno shows that unauthenticated names and types let an attacker redirect extracted data to a different application. — [Kohno 2004](https://cryptosec.sysnet.ucsd.edu/miscpapers/winzip-ccs04.pdf)
- age requires capping attacker-supplied KDF work factors. — [age spec](https://github.com/C2SP/C2SP/blob/main/age.md)

### Inferences (format-level design choices)
1. **Single source of truth.** One index (no ZIP-style duplicated local header and central directory that can disagree). Each entry's data extent is `[offset, offset+len)`, and the spec requires extents to be strictly non-overlapping and ordered. Decoders MUST reject overlaps. This kills Fifield's construction at the format level. Deduplication, if wanted, should be explicit (a reference to a content-addressed block) and should count toward output size accounting.
2. **Declared sizes are binding.** Each block and entry declares its uncompressed size in authenticated metadata. The decoder stops and errors if output exceeds it. The total uncompressed size is in the header, so the extractor can check free space and apply ratio and absolute limits *before* writing.
3. **Bounded resource parameters.** The window or dictionary size, KDF memory/iterations, block counts and nesting depth are all declared and capped by decoder policy.
4. **Paths as component lists.** Store paths as arrays of UTF-8 components. Each component is non-empty, not `.` or `..`, and contains no `/`, `\` or NUL. Paths cannot be absolute or have drive letters. Define a normalization form (NFC) and case-collision policy. Reject duplicate paths.
5. **Links.** Symlink and hardlink entries are a distinct type. Extractors create them last, never write through them, and use `openat`/`O_NOFOLLOW` (or `RESOLVE_BENEATH` on Linux). A link may by default be disallowed from targeting outside the root. A hardlink target must be an earlier entry in the same archive.
6. **Authenticate everything the extractor acts on**: type, mode bits (no setuid by default), path, size and codec, so an attacker cannot change them without detection when encrypted or signed.

### Gaps
- Fifield's paper text could not be downloaded in full (fetch timeouts), so these items are not verified from the primary source:
  - The exact zbsm/zblg/zbxl numbers.
  - The detection advice (overlap detection, local-header vs central-directory checks).
  - The Info-ZIP UnZip patch (believed to be CVE-2019-13232).
- No research was done on symlink-specific CVEs (for example tar symlink-then-write attacks, CVE-2001-1267-style issues, or Python `tarfile` filters from PEP 706). PEP 706's extraction filters (`data`/`tar`) are a relevant modern reference worth citing.
