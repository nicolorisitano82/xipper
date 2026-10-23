#pragma once
// Thin C wrappers over the system zlib / bzip2. zlib's init entry points are
// macros, which Swift cannot import, so every stream is driven through here.
#include <stddef.h>
#include <stdint.h>
#include <zlib.h>
#include <bzlib.h>

// MARK: - deflate chunk (pigz-style parallel deflate)

/// Raw-deflates one chunk of a larger stream.
/// `dict`/`dictLen`: up to the last 32 KiB of the previous chunk (NULL for the first).
/// `last` != 0 terminates the stream (BFINAL); otherwise the chunk ends with a sync
/// flush so consecutive chunk outputs can be concatenated byte-wise.
/// Returns the compressed length, or 0 on error.
size_t xs_deflate_chunk(const uint8_t *in, size_t inLen,
                        const uint8_t *dict, size_t dictLen,
                        int level, int last,
                        uint8_t *out, size_t outCap);
size_t xs_deflate_chunk_bound(size_t inLen);

uint32_t xs_crc32_combine(uint32_t crc1, uint32_t crc2, uint64_t len2);

/// PAR2 GF(2^16): 128 bytes of nibble tables for `factor`, then dst ^= factor · src
/// (little-endian words; NEON TBL, with a portable path kept for equivalence tests).
/// Deflate64 (ZIP method 9) encoder (deflate64.c): `in` coded after `dict` (at most the last 64 KiB
/// are used); not `last` → ends with a sync flush, so chunks concatenate. 0 on failure.
size_t xs_deflate64_bound(size_t n);
size_t xs_deflate64_compress(const uint8_t *in, size_t n, const uint8_t *dict, size_t dict_len,
                             int level, int last, uint8_t *out, size_t cap);

/// Deflate64 (ZIP method 9), streaming (inflate64.c).
typedef struct xs_inflate64 xs_inflate64;
enum { XS_INFLATE64_NEED_INPUT = 0, XS_INFLATE64_OUTPUT_FULL = 1, XS_INFLATE64_END = 2, XS_INFLATE64_ERROR = -1 };
xs_inflate64 *xs_inflate64_new(void);
void xs_inflate64_free(xs_inflate64 *s);
/// Decodes from `in` into `out`; `final` when no more input follows. Unused input must be passed again.
int xs_inflate64_run(xs_inflate64 *s, const uint8_t *in, size_t in_len, size_t *in_used,
                     uint8_t *out, size_t out_cap, size_t *out_len, int final);

void xs_gf16_tables(uint16_t factor, uint8_t tables[128]);
void xs_gf16_muladd(uint8_t *dst, const uint8_t *src, size_t bytes, const uint8_t tables[128]);
void xs_gf16_muladd_portable(uint8_t *dst, const uint8_t *src, size_t bytes, const uint8_t tables[128]);

// MARK: - streaming inflate

typedef struct xs_inflate xs_inflate;
/// mode 0: raw deflate, 1: gzip (multi-member aware via xs_inflate_reset)
xs_inflate *xs_inflate_new(int gzip);
/// Returns Z_OK, Z_STREAM_END, Z_BUF_ERROR (needs more input / output) or a negative error.
int xs_inflate_run(xs_inflate *s, const uint8_t *in, size_t inLen, size_t *inUsed,
                   uint8_t *out, size_t outCap, size_t *outUsed);
int xs_inflate_reset(xs_inflate *s);
void xs_inflate_free(xs_inflate *s);

// MARK: - streaming bzip2 decompress (multi-stream aware via reset)

typedef struct xs_bunzip xs_bunzip;
xs_bunzip *xs_bunzip_new(void);
/// Returns BZ_OK, BZ_STREAM_END or a negative BZ_* error.
int xs_bunzip_run(xs_bunzip *s, const uint8_t *in, size_t inLen, size_t *inUsed,
                  uint8_t *out, size_t outCap, size_t *outUsed);
int xs_bunzip_reset(xs_bunzip *s);
void xs_bunzip_free(xs_bunzip *s);

/// Parallel bzip2 decoding: the next block (kind 1) or end-of-stream (kind 2) magic at or after
/// bit `from` (SIZE_MAX if none in the n bytes), `count` ≤ 64 bits read MSB-first, and one block
/// (bits [start, end) from its magic) decoded as a stream of its own: BZ_OK, BZ_OUTBUFF_FULL
/// (retry with a bigger buffer) or an error, CRC checked.
size_t xs_bz2_next_magic(const uint8_t *p, size_t n, size_t from, int *kind);
uint64_t xs_bz2_bits(const uint8_t *p, size_t bit, int count);
int xs_bz2_decode_block(const uint8_t *src, size_t start, size_t end, int level, uint8_t *out, size_t *outLen);

/// One-shot bzip2 compression of an independent stream (parallel bzip2 = concatenated streams).
/// Returns compressed length, or 0 on error.
size_t xs_bzip2_compress(const uint8_t *in, size_t inLen, int level, uint8_t *out, size_t outCap);

// MARK: - CRC-32C (Castagnoli), ARMv8 CRC instructions (crc32c.c)

/// Updates a CRC-32C with `len` bytes. Start with crc = 0; the value is pre/post-inverted inside.
uint32_t xs_crc32c(uint32_t crc, const uint8_t *data, size_t len);
