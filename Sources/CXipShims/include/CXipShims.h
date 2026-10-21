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

/// One-shot bzip2 compression of an independent stream (parallel bzip2 = concatenated streams).
/// Returns compressed length, or 0 on error.
size_t xs_bzip2_compress(const uint8_t *in, size_t inLen, int level, uint8_t *out, size_t outCap);
