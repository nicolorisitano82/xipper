/* Errors, byte buffers, arena, CRC-32C, randomness. */
#include "internal.h"

#include <stdio.h>

#if defined(_WIN32)
#  include <windows.h>
#  include <bcrypt.h>
#elif defined(__APPLE__) || defined(__OpenBSD__) || defined(__FreeBSD__) || defined(__NetBSD__)
#  include <stdlib.h>
#  define HAVE_ARC4RANDOM 1
#else
#  include <errno.h>
#  include <fcntl.h>
#  include <unistd.h>
#  include <sys/random.h>
#endif

const uint8_t XIZ_SUPER_MAGIC[8] = {0x58, 0x49, 0x5A, 0x00, 0x0D, 0x0A, 0x1A, 0x0A};

const char *xiz_version(void) { return XIZ_LIB_VERSION; }

const char *xiz_status_name(int code) {
    switch (code) {
    case XIZ_OK: return "ok";
    case XIZ_E_ARG: return "invalid argument";
    case XIZ_E_NOMEM: return "out of memory";
    case XIZ_E_IO: return "I/O error";
    case XIZ_E_NOT_XIZ: return "not a XIZ archive";
    case XIZ_E_CORRUPT: return "corrupt archive";
    case XIZ_E_UNSUPPORTED: return "unsupported";
    case XIZ_E_PASSWORD_REQUIRED: return "password required";
    case XIZ_E_WRONG_PASSWORD: return "wrong password";
    case XIZ_E_AUTH: return "authentication failed";
    case XIZ_E_CHECKSUM: return "checksum mismatch";
    case XIZ_E_DIGEST: return "digest mismatch";
    case XIZ_E_LIMIT: return "limit exceeded";
    case XIZ_E_NOT_FOUND: return "not found";
    case XIZ_E_UNSAFE: return "unsafe entry";
    case XIZ_E_LOCKED: return "access group not held";
    case XIZ_E_ERASED: return "entry erased";
    case XIZ_E_EXISTS: return "already exists";
    case XIZ_E_CALLBACK: return "stopped by callback";
    default: return "unknown error";
    }
}

int xiz_fail(xiz_error *err, int code, const char *fmt, ...) {
    if (err) {
        err->code = code;
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(err->message, sizeof err->message, fmt, ap);
        va_end(ap);
    }
    return code;
}

void xiz_free(void *p) { free(p); }

/* ------------------------------------------------------------------ wbuf */

int wb_reserve(wbuf *w, size_t more) {
    if (w->oom) return 0;
    if (w->cap - w->n >= more) return 1;
    size_t need = w->n + more;
    if (need < w->n) { w->oom = 1; return 0; }
    size_t cap = w->cap ? w->cap : 256;
    while (cap < need) {
        if (cap > SIZE_MAX / 2) { cap = need; break; }
        cap *= 2;
    }
    uint8_t *p = realloc(w->p, cap);
    if (!p) { w->oom = 1; return 0; }
    w->p = p;
    w->cap = cap;
    return 1;
}

void wb_put(wbuf *w, const void *d, size_t n) {
    if (!n || !wb_reserve(w, n)) return;
    memcpy(w->p + w->n, d, n);
    w->n += n;
}
void wb_u8(wbuf *w, uint8_t v) { wb_put(w, &v, 1); }
void wb_u16(wbuf *w, uint16_t v) { uint8_t b[2]; wr16(b, v); wb_put(w, b, 2); }
void wb_u32(wbuf *w, uint32_t v) { uint8_t b[4]; wr32(b, v); wb_put(w, b, 4); }
void wb_u64(wbuf *w, uint64_t v) { uint8_t b[8]; wr64(b, v); wb_put(w, b, 8); }
void wb_free(wbuf *w) { free(w->p); memset(w, 0, sizeof *w); }

/* ------------------------------------------------------------------ arena */

struct arena_block {
    arena_block *next;
    size_t used, cap;
    /* data follows, max-aligned */
};

#define ARENA_ALIGN 16
#define ARENA_HDR ((sizeof(arena_block) + ARENA_ALIGN - 1) & ~(size_t)(ARENA_ALIGN - 1))

void *arena_alloc(arena *a, size_t n) {
    n = (n + ARENA_ALIGN - 1) & ~(size_t)(ARENA_ALIGN - 1);
    if (n == 0) n = ARENA_ALIGN;
    arena_block *b = a->head;
    if (!b || b->cap - b->used < n) {
        size_t cap = n > 65536 ? n : 65536;
        b = malloc(ARENA_HDR + cap);
        if (!b) return NULL;
        b->cap = cap;
        b->used = 0;
        b->next = a->head;
        a->head = b;
    }
    void *p = (uint8_t *)b + ARENA_HDR + b->used;
    b->used += n;
    return p;
}

void *arena_dup(arena *a, const void *p, size_t n, int nul) {
    uint8_t *q = arena_alloc(a, n + (nul ? 1 : 0));
    if (!q) return NULL;
    if (n) memcpy(q, p, n);
    if (nul) q[n] = 0;
    return q;
}

void arena_free(arena *a) {
    arena_block *b = a->head;
    while (b) {
        arena_block *n = b->next;
        secure_zero((uint8_t *)b + ARENA_HDR, b->used);
        free(b);
        b = n;
    }
    a->head = NULL;
}

void secure_zero(void *p, size_t n) {
    volatile uint8_t *v = p;
    while (n--) *v++ = 0;
}

int ct_equal(const void *a, const void *b, size_t n) {
    const uint8_t *x = a, *y = b;
    uint8_t d = 0;
    for (size_t i = 0; i < n; i++) d |= (uint8_t)(x[i] ^ y[i]);
    return d == 0;
}

/* ------------------------------------------------------------------ CRC-32C */

#if defined(__aarch64__) && defined(__ARM_FEATURE_CRC32)
#  include <arm_acle.h>
uint32_t xiz_crc32c(uint32_t crc, const void *data, size_t n) {
    const uint8_t *p = data;
    crc = ~crc;
    while (n && ((uintptr_t)p & 7)) { crc = __crc32cb(crc, *p++); n--; }
    while (n >= 8) { uint64_t v; memcpy(&v, p, 8); crc = __crc32cd(crc, v); p += 8; n -= 8; }
    while (n--) crc = __crc32cb(crc, *p++);
    return ~crc;
}
#else
static uint32_t crc_table[8][256];
static int crc_ready;

static void crc_init(void) {
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0x82F63B78u & (0u - (c & 1)));
        crc_table[0][i] = c;
    }
    for (uint32_t i = 0; i < 256; i++)
        for (int t = 1; t < 8; t++) crc_table[t][i] = (crc_table[t - 1][i] >> 8) ^ crc_table[0][crc_table[t - 1][i] & 0xFF];
    crc_ready = 1;
}

uint32_t xiz_crc32c(uint32_t crc, const void *data, size_t n) {
    if (!crc_ready) crc_init();  /* idempotent: concurrent first calls compute the same table */
    const uint8_t *p = data;
    crc = ~crc;
    while (n >= 8) {
        uint32_t lo = crc ^ rd32(p), hi = rd32(p + 4);
        crc = crc_table[7][lo & 0xFF] ^ crc_table[6][(lo >> 8) & 0xFF] ^ crc_table[5][(lo >> 16) & 0xFF] ^
              crc_table[4][lo >> 24] ^ crc_table[3][hi & 0xFF] ^ crc_table[2][(hi >> 8) & 0xFF] ^
              crc_table[1][(hi >> 16) & 0xFF] ^ crc_table[0][hi >> 24];
        p += 8;
        n -= 8;
    }
    while (n--) crc = (crc >> 8) ^ crc_table[0][(crc ^ *p++) & 0xFF];
    return ~crc;
}
#endif

/* ------------------------------------------------------------------ randomness */

int xiz_random(void *buf, size_t n) {
#if defined(_WIN32)
    return BCryptGenRandom(NULL, buf, (ULONG)n, BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0 ? 0 : -1;
#elif defined(HAVE_ARC4RANDOM)
    arc4random_buf(buf, n);
    return 0;
#else
    uint8_t *p = buf;
    while (n) {
        ssize_t r = getrandom(p, n, 0);
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        p += r;
        n -= (size_t)r;
    }
    return 0;
#endif
}
