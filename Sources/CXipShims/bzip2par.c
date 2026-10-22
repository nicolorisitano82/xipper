// Parallel bzip2 decoding (lbzip2's approach): bzip2 blocks are independent but start at any bit,
// so the decoder finds their 48-bit magics, then decodes each block as a stream of its own.
#include "CXipShims.h"
#include <bzlib.h>
#include <pthread.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

static const uint64_t BLOCK_MAGIC = 0x314159265359ull, END_MAGIC = 0x177245385090ull;

static uint64_t be64(const uint8_t *p) {
    uint64_t v;
    memcpy(&v, p, 8);
    return __builtin_bswap64(v);
}

/// Byte i+2 of a magic placed at bit offset s of byte i, per shift: a one-lookup pre-filter, so
/// only a few positions in 256 get the full 48-bit comparison.
static uint16_t filter[256];
static void build_filter(void) {
    for (int s = 0; s < 8; s++) {
        filter[(uint8_t)((BLOCK_MAGIC << (16 - s)) >> 40)] |= (uint16_t)(1u << s);
        filter[(uint8_t)((END_MAGIC << (16 - s)) >> 40)] |= (uint16_t)(1u << (8 + s));
    }
}

size_t xs_bz2_next_magic(const uint8_t *p, size_t n, size_t from, int *kind) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, build_filter);
    if (n < 8) return SIZE_MAX;
    for (size_t i = from / 8; i + 8 <= n; i++) {
        uint16_t m = filter[p[i + 2]];
        if (!m) continue;
        uint64_t w = be64(p + i);
        for (int s = 0; s < 8; s++) {
            size_t bit = i * 8 + (size_t)s;
            if (bit < from) continue;
            uint64_t v = (w >> (16 - s)) & 0xFFFFFFFFFFFFull;
            if ((m >> s) & 1 && v == BLOCK_MAGIC) { *kind = 1; return bit; }
            if ((m >> (8 + s)) & 1 && v == END_MAGIC) { *kind = 2; return bit; }
        }
    }
    return SIZE_MAX;
}

uint64_t xs_bz2_bits(const uint8_t *p, size_t bit, int count) {
    uint64_t v = 0;
    for (int k = 0; k < count; k++, bit++) v = v << 1 | ((p[bit >> 3] >> (7 - (bit & 7))) & 1);
    return v;
}

int xs_bz2_decode_block(const uint8_t *src, size_t start, size_t end, int level, uint8_t *out, size_t *outLen) {
    size_t bits = end - start, body = (bits + 7) / 8;
    uint8_t *s = malloc(4 + body + 12);
    if (!s) return BZ_MEM_ERROR;
    s[0] = 'B'; s[1] = 'Z'; s[2] = 'h'; s[3] = (uint8_t)('0' + level);
    const uint8_t *p = src + start / 8;
    int off = (int)(start & 7);
    if (off == 0) memcpy(s + 4, p, body);
    else {
        size_t avail = (end + 7) / 8 - start / 8;  // never read past the block's last byte
        for (size_t k = 0; k < body; k++) s[4 + k] = (uint8_t)(p[k] << off | (k + 1 < avail ? p[k + 1] : 0) >> (8 - off));
    }
    if (bits & 7) s[4 + body - 1] &= (uint8_t)(0xFF << (8 - (bits & 7)));
    // End of stream: magic and combined CRC (= the block's CRC, bits 48–79), then zero padding.
    uint64_t crc = xs_bz2_bits(src, start + 48, 32);
    size_t at = 32 + bits;
    memset(s + 4 + body, 0, 12);
    uint64_t trailer[2] = { END_MAGIC, crc };
    int widths[2] = { 48, 32 };
    for (int t = 0; t < 2; t++)
        for (int k = widths[t] - 1; k >= 0; k--, at++)
            if ((trailer[t] >> k) & 1) s[at >> 3] |= (uint8_t)(0x80 >> (at & 7));
    unsigned cap = *outLen > UINT_MAX ? UINT_MAX : (unsigned)*outLen;
    int r = BZ2_bzBuffToBuffDecompress((char *)out, &cap, (char *)s, (unsigned)((at + 7) / 8), 0, 0);
    free(s);
    *outLen = cap;
    return r;
}
