#pragma once
#include <stddef.h>
#include <stdint.h>
#include <zlib.h>
#include "libdeflate.h"

// Raw-deflate one chunk of a larger stream, pigz style.
// dict/dictLen: last <=32 KiB of the previous chunk (NULL for the first chunk).
// last != 0 terminates the stream (BFINAL); otherwise ends with a sync flush
// so chunk outputs can be concatenated byte-wise.
// Returns compressed length, or 0 on error.
size_t xz_deflate_chunk(const uint8_t *in, size_t inLen,
                        const uint8_t *dict, size_t dictLen,
                        int level, int last,
                        uint8_t *out, size_t outCap);

size_t xz_deflate_chunk_bound(size_t inLen);
