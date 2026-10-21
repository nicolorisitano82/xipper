#pragma once
// PPMd variant H with the 7z range coder (7z method 030401), from the LZMA SDK
// (public domain). Only this small wrapper is visible to Swift.
#include <stddef.h>
#include <stdint.h>

/// Pulls compressed input: fills up to `cap` bytes, returns 0 at end of input or on error.
typedef size_t (*xs_ppmd_fill)(void *ctx, uint8_t *buf, size_t cap);

typedef struct xs_ppmd7_dec xs_ppmd7_dec;

/// `order` 2...64, `memSize` 2 KiB...4 GiB (the 5 property bytes of the 7z coder).
/// Returns NULL if the model memory cannot be allocated.
xs_ppmd7_dec *xs_ppmd7_dec_new(unsigned order, uint32_t memSize, xs_ppmd_fill fill, void *ctx);
void xs_ppmd7_dec_free(xs_ppmd7_dec *d);

/// Decodes exactly `count` bytes. Returns 0 on success, -1 on invalid data,
/// -2 when the input ended before `count` bytes were decoded.
int xs_ppmd7_dec_read(xs_ppmd7_dec *d, uint8_t *out, size_t count);
