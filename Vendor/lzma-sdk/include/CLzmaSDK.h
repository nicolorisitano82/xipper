#pragma once
// Codecs from the LZMA SDK (public domain), seen by Swift only through these wrappers.
//
// PPMd variant H with the 7z range coder (7z method 030401).
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

// LZMA / LZMA2 decoder of the LZMA SDK, with 7-Zip's ARM64 assembly main loop
// (Asm/arm64/LzmaDecOpt.S). liblzma remains the portable path in XipperKit.

typedef struct xs_lzdec xs_lzdec;

/// Raw LZMA1 (5 property bytes) / LZMA2 (1 property byte). `dictCap` > 0 caps the dictionary
/// (no stream needs more than its own size). Returns NULL on bad properties or no memory.
xs_lzdec *xs_lzma_dec_new(const uint8_t *props, uint32_t dictCap);
xs_lzdec *xs_lzma2_dec_new(uint8_t prop, uint32_t dictCap);
void xs_lzdec_free(xs_lzdec *d);

/// Decodes from `in` to `out`. `finishEnd` != 0: the caller wants exactly `outCap` more bytes
/// (LZMA1 with known size). Returns -1 on invalid data, otherwise the SDK's ELzmaStatus:
/// 1 finished with end mark, 2 not finished, 3 needs more input, 4 maybe finished without mark.
int xs_lzdec_run(xs_lzdec *d, const uint8_t *in, size_t inLen, size_t *inUsed,
                 uint8_t *out, size_t outCap, size_t *outUsed, int finishEnd);
