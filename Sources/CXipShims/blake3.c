// BLAKE3 (https://github.com/BLAKE3-team/BLAKE3, spec and reference_impl.rs; CC0/Apache-2.0),
// written from the specification: portable, one thread, 32-byte output. Used by the hash tool.
#include "CXipShims.h"
#include <stdlib.h>
#include <string.h>

static const uint32_t IV[8] = {0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
                               0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19};
// Message word order of each of the 7 rounds: the permutation {2,6,3,10,7,0,4,13,1,11,12,5,9,14,15,8}
// applied r times, so that every index is a constant once the rounds are unrolled.
static const uint8_t SCHEDULE[7][16] = {
    {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
    {2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8},
    {3, 4, 10, 12, 13, 2, 7, 14, 6, 5, 9, 0, 11, 15, 8, 1},
    {10, 7, 12, 9, 14, 3, 13, 15, 4, 0, 11, 2, 5, 8, 1, 6},
    {12, 13, 9, 11, 15, 10, 14, 8, 7, 2, 5, 3, 0, 1, 6, 4},
    {9, 14, 11, 5, 8, 12, 15, 1, 13, 3, 0, 10, 2, 6, 4, 7},
    {11, 15, 5, 0, 1, 9, 8, 6, 14, 10, 2, 12, 3, 4, 7, 13},
};
enum { CHUNK_START = 1, CHUNK_END = 2, PARENT = 4, ROOT = 8, CHUNK_LEN = 1024, BLOCK_LEN = 64 };

static inline uint32_t rotr(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

static inline void g(uint32_t *s, int a, int b, int c, int d, uint32_t mx, uint32_t my) {
    s[a] = s[a] + s[b] + mx; s[d] = rotr(s[d] ^ s[a], 16);
    s[c] = s[c] + s[d];      s[b] = rotr(s[b] ^ s[c], 12);
    s[a] = s[a] + s[b] + my; s[d] = rotr(s[d] ^ s[a], 8);
    s[c] = s[c] + s[d];      s[b] = rotr(s[b] ^ s[c], 7);
}

static inline void round_fn(uint32_t *s, const uint32_t *m, const uint8_t *k) {
    g(s, 0, 4, 8, 12, m[k[0]], m[k[1]]);   g(s, 1, 5, 9, 13, m[k[2]], m[k[3]]);
    g(s, 2, 6, 10, 14, m[k[4]], m[k[5]]);  g(s, 3, 7, 11, 15, m[k[6]], m[k[7]]);
    g(s, 0, 5, 10, 15, m[k[8]], m[k[9]]);  g(s, 1, 6, 11, 12, m[k[10]], m[k[11]]);
    g(s, 2, 7, 8, 13, m[k[12]], m[k[13]]); g(s, 3, 4, 9, 14, m[k[14]], m[k[15]]);
}

/// The 16-word compression output; the chaining value is its first 8 words.
static void b3_compress(const uint32_t cv[8], const uint32_t block[16], uint64_t counter, uint32_t len, uint32_t flags, uint32_t out[16]) {
    uint32_t s[16] = {cv[0], cv[1], cv[2], cv[3], cv[4], cv[5], cv[6], cv[7],
                      IV[0], IV[1], IV[2], IV[3], (uint32_t)counter, (uint32_t)(counter >> 32), len, flags};
    _Pragma("clang loop unroll(full)")
    for (int r = 0; r < 7; r++) round_fn(s, block, SCHEDULE[r]);
    for (int i = 0; i < 8; i++) { out[i] = s[i] ^ s[i + 8]; out[i + 8] = s[i + 8] ^ cv[i]; }
}

static void words(const uint8_t *b, uint32_t w[16]) {
    for (int i = 0; i < 16; i++) w[i] = (uint32_t)b[4 * i] | (uint32_t)b[4 * i + 1] << 8 | (uint32_t)b[4 * i + 2] << 16 | (uint32_t)b[4 * i + 3] << 24;
}

#if defined(__aarch64__)
#include <arm_neon.h>
// Four whole chunks at once, one per NEON lane (the official implementation's hash_many):
// 16 blocks each, the message transposed so that lane L holds chunk L's words.
#define ROTR(x, n) vsriq_n_u32(vshlq_n_u32((x), 32 - (n)), (x), (n))
static inline uint32x4_t rotr16(uint32x4_t x) { return vreinterpretq_u32_u16(vrev32q_u16(vreinterpretq_u16_u32(x))); }
static inline void g4(uint32x4_t *v, int a, int b, int c, int d, uint32x4_t x, uint32x4_t y) {
    v[a] = vaddq_u32(vaddq_u32(v[a], v[b]), x); v[d] = rotr16(veorq_u32(v[d], v[a]));
    v[c] = vaddq_u32(v[c], v[d]);               v[b] = ROTR(veorq_u32(v[b], v[c]), 12);
    v[a] = vaddq_u32(vaddq_u32(v[a], v[b]), y); v[d] = ROTR(veorq_u32(v[d], v[a]), 8);
    v[c] = vaddq_u32(v[c], v[d]);               v[b] = ROTR(veorq_u32(v[b], v[c]), 7);
}

static void hash4(const uint8_t *in, uint64_t counter, uint32_t out[4][8]) {
    uint32x4_t h[8];
    for (int i = 0; i < 8; i++) h[i] = vdupq_n_u32(IV[i]);
    const uint32_t lo[4] = {(uint32_t)counter, (uint32_t)(counter + 1), (uint32_t)(counter + 2), (uint32_t)(counter + 3)};
    const uint32_t hi[4] = {(uint32_t)(counter >> 32), (uint32_t)((counter + 1) >> 32), (uint32_t)((counter + 2) >> 32), (uint32_t)((counter + 3) >> 32)};
    const uint32x4_t ctr_lo = vld1q_u32(lo), ctr_hi = vld1q_u32(hi);
    for (int b = 0; b < CHUNK_LEN / BLOCK_LEN; b++) {
        uint32x4_t m[16];
        for (int g = 0; g < 4; g++) {
            uint32x4_t r0 = vld1q_u32((const uint32_t *)(in + 0 * CHUNK_LEN + b * BLOCK_LEN + g * 16));
            uint32x4_t r1 = vld1q_u32((const uint32_t *)(in + 1 * CHUNK_LEN + b * BLOCK_LEN + g * 16));
            uint32x4_t r2 = vld1q_u32((const uint32_t *)(in + 2 * CHUNK_LEN + b * BLOCK_LEN + g * 16));
            uint32x4_t r3 = vld1q_u32((const uint32_t *)(in + 3 * CHUNK_LEN + b * BLOCK_LEN + g * 16));
            uint64x2_t t0 = vreinterpretq_u64_u32(vtrn1q_u32(r0, r1)), t1 = vreinterpretq_u64_u32(vtrn2q_u32(r0, r1));
            uint64x2_t t2 = vreinterpretq_u64_u32(vtrn1q_u32(r2, r3)), t3 = vreinterpretq_u64_u32(vtrn2q_u32(r2, r3));
            m[4 * g + 0] = vreinterpretq_u32_u64(vtrn1q_u64(t0, t2));
            m[4 * g + 1] = vreinterpretq_u32_u64(vtrn1q_u64(t1, t3));
            m[4 * g + 2] = vreinterpretq_u32_u64(vtrn2q_u64(t0, t2));
            m[4 * g + 3] = vreinterpretq_u32_u64(vtrn2q_u64(t1, t3));
        }
        uint32_t flags = (b == 0 ? CHUNK_START : 0) | (b == CHUNK_LEN / BLOCK_LEN - 1 ? CHUNK_END : 0);
        uint32x4_t v[16] = {h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7],
                            vdupq_n_u32(IV[0]), vdupq_n_u32(IV[1]), vdupq_n_u32(IV[2]), vdupq_n_u32(IV[3]),
                            ctr_lo, ctr_hi, vdupq_n_u32(BLOCK_LEN), vdupq_n_u32(flags)};
        _Pragma("clang loop unroll(full)")
        for (int r = 0; r < 7; r++) {
            const uint8_t *k = SCHEDULE[r];
            g4(v, 0, 4, 8, 12, m[k[0]], m[k[1]]);   g4(v, 1, 5, 9, 13, m[k[2]], m[k[3]]);
            g4(v, 2, 6, 10, 14, m[k[4]], m[k[5]]);  g4(v, 3, 7, 11, 15, m[k[6]], m[k[7]]);
            g4(v, 0, 5, 10, 15, m[k[8]], m[k[9]]);  g4(v, 1, 6, 11, 12, m[k[10]], m[k[11]]);
            g4(v, 2, 7, 8, 13, m[k[12]], m[k[13]]); g4(v, 3, 4, 9, 14, m[k[14]], m[k[15]]);
        }
        for (int i = 0; i < 8; i++) h[i] = veorq_u32(v[i], v[i + 8]);
    }
    for (int i = 0; i < 8; i++) {
        out[0][i] = vgetq_lane_u32(h[i], 0); out[1][i] = vgetq_lane_u32(h[i], 1);
        out[2][i] = vgetq_lane_u32(h[i], 2); out[3][i] = vgetq_lane_u32(h[i], 3);
    }
}
#endif

/// The stack holds one complete subtree per set bit of the chunks hashed so far. A subtree of
/// 2^level chunks ending at chunk `total` merges with the stack top once per zero bit above `level`.
static void push_subtree_cv(xs_blake3 *h, uint32_t cv[8], uint64_t total, int level) {
    total >>= level;
    while ((total & 1) == 0) {
        uint32_t block[16], out[16];
        h->stack_len--;
        memcpy(block, h->stack[h->stack_len], 32);
        memcpy(block + 8, cv, 32);
        b3_compress(IV, block, 0, BLOCK_LEN, PARENT, out);
        memcpy(cv, out, 32);
        total >>= 1;
    }
    memcpy(h->stack[h->stack_len++], cv, 32);
}

static void chunk_reset(xs_blake3 *h, uint64_t counter) {
    memcpy(h->cv, IV, sizeof h->cv);
    h->chunk_counter = counter;
    h->buf_len = 0;
    h->blocks_compressed = 0;
}

void xs_blake3_init(xs_blake3 *h) {
    chunk_reset(h, 0);
    h->stack_len = 0;
}

static uint32_t start_flag(const xs_blake3 *h) { return h->blocks_compressed == 0 ? CHUNK_START : 0; }

/// Merges finished subtrees: after chunk number `total` (1-based), one merge per trailing zero bit.
static void push_chunk_cv(xs_blake3 *h, uint32_t cv[8], uint64_t total) { push_subtree_cv(h, cv, total, 0); }

void xs_blake3_update(xs_blake3 *h, const void *data, size_t len) {
    const uint8_t *p = data;
    while (len > 0) {
#if defined(__aarch64__)
        // At a chunk boundary with more than four chunks to come: none of them is the root.
        if (h->buf_len == 0 && h->blocks_compressed == 0 && len > 4 * CHUNK_LEN) {
            uint32_t cvs[4][8];
            hash4(p, h->chunk_counter, cvs);
            for (int i = 0; i < 4; i++) push_chunk_cv(h, cvs[i], h->chunk_counter + 1 + i);
            chunk_reset(h, h->chunk_counter + 4);
            p += 4 * CHUNK_LEN;
            len -= 4 * CHUNK_LEN;
            continue;
        }
#endif
        if (h->blocks_compressed * BLOCK_LEN + h->buf_len == CHUNK_LEN) {
            // The chunk is full and more input follows: it is not the root.
            uint32_t w[16], out[16];
            words(h->buf, w);
            b3_compress(h->cv, w, h->chunk_counter, BLOCK_LEN, start_flag(h) | CHUNK_END, out);
            uint64_t total = h->chunk_counter + 1;
            push_chunk_cv(h, out, total);
            chunk_reset(h, total);
        }
        if (h->buf_len == BLOCK_LEN) {
            uint32_t w[16], out[16];
            words(h->buf, w);
            b3_compress(h->cv, w, h->chunk_counter, BLOCK_LEN, start_flag(h), out);
            memcpy(h->cv, out, 32);
            h->blocks_compressed++;
            h->buf_len = 0;
        }
        size_t take = BLOCK_LEN - h->buf_len;
        if (take > len) take = len;
        memcpy(h->buf + h->buf_len, p, take);
        h->buf_len += (uint32_t)take;
        p += take;
        len -= take;
    }
}

void xs_blake3_final(const xs_blake3 *h, uint8_t out32[32]) {
    // The last chunk's output node, then parents up the stack; the top one is the root.
    uint32_t cv[8], block[16], flags = start_flag(h) | CHUNK_END;
    uint8_t padded[BLOCK_LEN] = {0};
    memcpy(padded, h->buf, h->buf_len);
    words(padded, block);
    memcpy(cv, h->cv, 32);
    uint64_t counter = h->chunk_counter;
    uint32_t len = h->buf_len;
    for (int i = h->stack_len; i > 0; i--) {
        uint32_t out[16];
        b3_compress(cv, block, counter, len, flags, out);
        memcpy(block, h->stack[i - 1], 32);
        memcpy(block + 8, out, 32);
        memcpy(cv, IV, 32);
        counter = 0;
        len = BLOCK_LEN;
        flags = PARENT;
    }
    uint32_t out[16];
    b3_compress(cv, block, counter, len, flags | ROOT, out);
    for (int i = 0; i < 8; i++) {
        out32[4 * i] = (uint8_t)out[i]; out32[4 * i + 1] = (uint8_t)(out[i] >> 8);
        out32[4 * i + 2] = (uint8_t)(out[i] >> 16); out32[4 * i + 3] = (uint8_t)(out[i] >> 24);
    }
}

/// Chaining value of a complete subtree of `chunks` chunks (a power of two, at least 4), which
/// starts at chunk `counter` (a multiple of `chunks`) and is not the whole input.
void xs_blake3_subtree(const uint8_t *in, uint64_t chunks, uint64_t counter, uint32_t out[8]) {
    uint32_t (*cvs)[8] = malloc(sizeof(uint32_t[8]) * chunks);
    if (cvs == NULL) abort();
    for (uint64_t c = 0; c < chunks; c += 4) {
#if defined(__aarch64__)
        hash4(in + c * CHUNK_LEN, counter + c, (uint32_t (*)[8])cvs[c]);
#else
        for (int i = 0; i < 4; i++) {
            uint32_t cv[8], w[16], o[16];
            memcpy(cv, IV, 32);
            for (int b = 0; b < CHUNK_LEN / BLOCK_LEN; b++) {
                words(in + (c + i) * CHUNK_LEN + b * BLOCK_LEN, w);
                uint32_t f = (b == 0 ? CHUNK_START : 0) | (b == CHUNK_LEN / BLOCK_LEN - 1 ? CHUNK_END : 0);
                b3_compress(cv, w, counter + c + i, BLOCK_LEN, f, o);
                memcpy(cv, o, 32);
            }
            memcpy(cvs[c + i], cv, 32);
        }
#endif
    }
    for (uint64_t n = chunks; n > 1; n /= 2) {
        for (uint64_t i = 0; i < n / 2; i++) {
            uint32_t block[16], o[16];
            memcpy(block, cvs[2 * i], 32);
            memcpy(block + 8, cvs[2 * i + 1], 32);
            b3_compress(IV, block, 0, BLOCK_LEN, PARENT, o);
            memcpy(cvs[i], o, 32);
        }
    }
    memcpy(out, cvs[0], 32);
    free(cvs);
}

int xs_blake3_at_boundary(const xs_blake3 *h, uint64_t chunks) {
    return h->buf_len == 0 && h->blocks_compressed == 0 && h->chunk_counter % chunks == 0;
}

void xs_blake3_push_subtree(xs_blake3 *h, const uint32_t cv[8], uint64_t chunks) {
    uint32_t c[8];
    memcpy(c, cv, 32);
    int level = 0;
    while ((1ull << level) < chunks) level++;
    push_subtree_cv(h, c, h->chunk_counter + chunks, level);
    chunk_reset(h, h->chunk_counter + chunks);
}
