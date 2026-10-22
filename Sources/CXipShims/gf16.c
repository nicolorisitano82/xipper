// PAR2 arithmetic over GF(2^16), generator polynomial 0x1100B: dst ^= factor · src on
// little-endian 16-bit words. The product of a word is the XOR of the products of its four
// nibbles, each looked up in a 16-entry table; split into low and high bytes, the eight tables
// fit NEON's 16-byte TBL, which looks up 16 nibbles at once (ISA-L / par2cmdline-turbo technique).
#include "CXipShims.h"
#include <string.h>
#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

static uint16_t gf16_mul(uint16_t a, uint16_t b) {
    uint32_t r = 0, x = a;
    for (int i = 0; i < 16; i++) {
        if (b & (1u << i)) r ^= x;
        x <<= 1;
        if (x & 0x10000) x ^= 0x1100B;
    }
    return (uint16_t)r;
}

void xs_gf16_tables(uint16_t factor, uint8_t tables[128]) {
    for (int n = 0; n < 4; n++)
        for (int v = 0; v < 16; v++) {
            uint16_t p = gf16_mul(factor, (uint16_t)(v << (4 * n)));
            tables[n * 32 + v] = (uint8_t)p;            // low bytes of nibble n's products
            tables[n * 32 + 16 + v] = (uint8_t)(p >> 8); // high bytes
        }
}

/// Portable path (and the tail of the NEON one).
static void muladd_scalar(uint8_t *dst, const uint8_t *src, size_t words, const uint8_t *t) {
    for (size_t i = 0; i < words; i++) {
        uint8_t lo = src[2 * i], hi = src[2 * i + 1];
        uint8_t n0 = lo & 15, n1 = lo >> 4, n2 = hi & 15, n3 = hi >> 4;
        dst[2 * i] ^= t[n0] ^ t[32 + n1] ^ t[64 + n2] ^ t[96 + n3];
        dst[2 * i + 1] ^= t[16 + n0] ^ t[48 + n1] ^ t[80 + n2] ^ t[112 + n3];
    }
}

void xs_gf16_muladd_portable(uint8_t *dst, const uint8_t *src, size_t bytes, const uint8_t tables[128]) {
    muladd_scalar(dst, src, bytes / 2, tables);
}

// EOR3 (FEAT_SHA3) is on every Apple M-series core.
__attribute__((target("sha3")))
void xs_gf16_muladd(uint8_t *dst, const uint8_t *src, size_t bytes, const uint8_t tables[128]) {
    size_t words = bytes / 2, i = 0;
#if defined(__ARM_NEON)
    const uint8x16_t t0l = vld1q_u8(tables), t0h = vld1q_u8(tables + 16);
    const uint8x16_t t1l = vld1q_u8(tables + 32), t1h = vld1q_u8(tables + 48);
    const uint8x16_t t2l = vld1q_u8(tables + 64), t2h = vld1q_u8(tables + 80);
    const uint8x16_t t3l = vld1q_u8(tables + 96), t3h = vld1q_u8(tables + 112);
    const uint8x16_t mask = vdupq_n_u8(15);
    for (; i + 32 <= words; i += 32) {  // 64 bytes per iteration: two independent chains
        uint8x16x2_t s0 = vld2q_u8(src + 2 * i), s1 = vld2q_u8(src + 2 * i + 32);
        uint8x16x2_t d0 = vld2q_u8(dst + 2 * i), d1 = vld2q_u8(dst + 2 * i + 32);
#define MULADD(s, d)                                                                                   \
        do {                                                                                           \
            uint8x16_t n0 = vandq_u8(s.val[0], mask), n1 = vshrq_n_u8(s.val[0], 4);                    \
            uint8x16_t n2 = vandq_u8(s.val[1], mask), n3 = vshrq_n_u8(s.val[1], 4);                    \
            d.val[0] = veor3q_u8(d.val[0], vqtbl1q_u8(t0l, n0), vqtbl1q_u8(t1l, n1));                  \
            d.val[0] = veor3q_u8(d.val[0], vqtbl1q_u8(t2l, n2), vqtbl1q_u8(t3l, n3));                  \
            d.val[1] = veor3q_u8(d.val[1], vqtbl1q_u8(t0h, n0), vqtbl1q_u8(t1h, n1));                  \
            d.val[1] = veor3q_u8(d.val[1], vqtbl1q_u8(t2h, n2), vqtbl1q_u8(t3h, n3));                  \
        } while (0)
        MULADD(s0, d0);
        MULADD(s1, d1);
#undef MULADD
        vst2q_u8(dst + 2 * i, d0);
        vst2q_u8(dst + 2 * i + 32, d1);
    }
#endif
    muladd_scalar(dst + 2 * i, src + 2 * i, words - i, tables);
}
