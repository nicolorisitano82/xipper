// CRC-32C (iSCSI / Castagnoli, polynomial 0x1EDC6F41), as used by DRS/GCS `crc32c` checksums.
// Apple Silicon implements the ARMv8 CRC32C* instructions; three independent lanes hide their
// 3-cycle latency and are merged with precomputed "shift over N zero bytes" tables.
#include "CXipShims.h"
#include <arm_acle.h>
#include <pthread.h>
#include <string.h>

enum { LANE = 8192 };

__attribute__((target("crc")))
static uint32_t crc_bytes(uint32_t crc, const uint8_t *p, size_t n) {
    while (n >= 8) { uint64_t v; memcpy(&v, p, 8); crc = __crc32cd(crc, v); p += 8; n -= 8; }
    while (n--) crc = __crc32cb(crc, *p++);
    return crc;
}

// GF(2) matrix method from zlib's crc32_combine, for the reflected Castagnoli polynomial.
static uint32_t gf2_times(const uint32_t *mat, uint32_t vec) {
    uint32_t sum = 0;
    for (int i = 0; vec; vec >>= 1, i++) if (vec & 1) sum ^= mat[i];
    return sum;
}
static void gf2_square(uint32_t *sq, const uint32_t *mat) { for (int n = 0; n < 32; n++) sq[n] = gf2_times(mat, mat[n]); }

/// Raw CRC register advanced over `len` zero bytes.
static uint32_t crc_shift(uint32_t crc, size_t len) {
    uint32_t even[32], odd[32];
    odd[0] = 0x82F63B78u;
    for (int n = 1; n < 32; n++) odd[n] = 1u << (n - 1);
    gf2_square(even, odd);
    gf2_square(odd, even);
    do {
        gf2_square(even, odd);
        if (len & 1) crc = gf2_times(even, crc);
        len >>= 1;
        if (!len) break;
        gf2_square(odd, even);
        if (len & 1) crc = gf2_times(odd, crc);
        len >>= 1;
    } while (len);
    return crc;
}

// shift[s][k][b]: byte b at position k of the register, advanced over (s+1)*LANE zero bytes.
static uint32_t shift_tables[2][4][256];
static pthread_once_t tables_once = PTHREAD_ONCE_INIT;
static void build_tables(void) {
    for (int s = 0; s < 2; s++)
        for (int k = 0; k < 4; k++)
            for (int b = 0; b < 256; b++) shift_tables[s][k][b] = crc_shift((uint32_t)b << (8 * k), (size_t)(s + 1) * LANE);
}
static inline uint32_t apply(const uint32_t t[4][256], uint32_t c) {
    return t[0][c & 0xff] ^ t[1][(c >> 8) & 0xff] ^ t[2][(c >> 16) & 0xff] ^ t[3][c >> 24];
}

__attribute__((target("crc")))
uint32_t xs_crc32c(uint32_t crc, const uint8_t *data, size_t len) {
    crc = ~crc;
    if (len >= 3 * LANE) {
        pthread_once(&tables_once, build_tables);
        while (len >= 3 * LANE) {
            uint32_t c0 = crc, c1 = 0, c2 = 0;
            const uint8_t *a = data, *b = data + LANE, *c = data + 2 * LANE;
            for (size_t i = 0; i < LANE; i += 8) {
                uint64_t va, vb, vc;
                memcpy(&va, a + i, 8); memcpy(&vb, b + i, 8); memcpy(&vc, c + i, 8);
                c0 = __crc32cd(c0, va); c1 = __crc32cd(c1, vb); c2 = __crc32cd(c2, vc);
            }
            crc = apply(shift_tables[1], c0) ^ apply(shift_tables[0], c1) ^ c2;
            data += 3 * LANE; len -= 3 * LANE;
        }
    }
    return ~crc_bytes(crc, data, len);
}
