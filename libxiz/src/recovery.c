/* Recovery record (§15): Cauchy Reed–Solomon over GF(2^16) on fixed slices of the whole archive,
 * after the last footer. Check, repair in place, add and remove. Single-threaded and portable; the
 * GF(2^16) multiply-add uses two 256-entry tables per factor (NEON nibble tables on AArch64). */
#include "internal.h"

#if defined(_WIN32)
#  include <windows.h>
#else
#  include <errno.h>
#  include <fcntl.h>
#  include <unistd.h>
#endif
#if defined(__aarch64__) && defined(__ARM_NEON)
#  include <arm_neon.h>
#endif

#define R_HEADER 64
#define R_TRAILER 64
#define R_HASH 16
#define R_TARGET 2000
#define R_MAX_DATA 32768

/* ------------------------------------------------------------------ GF(2^16), PAR2 polynomial */

typedef struct gf {
    uint16_t log[65536], exp[65536];
} gf;

static gf *gf_new(void) {
    gf *g = malloc(sizeof *g);
    if (!g) return NULL;
    uint32_t b = 1;
    for (uint32_t l = 0; l < 65535; l++) {
        g->exp[l] = (uint16_t)b;
        g->log[b] = (uint16_t)l;
        b <<= 1;
        if (b & 0x10000) b ^= 0x1100B;
    }
    g->exp[65535] = g->exp[0];
    g->log[0] = 0;
    return g;
}

static uint16_t gf_mul(const gf *g, uint16_t a, uint16_t b) {
    if (!a || !b) return 0;
    return g->exp[((uint32_t)g->log[a] + g->log[b]) % 65535];
}

static uint16_t gf_inv(const gf *g, uint16_t a) { return g->exp[(65535 - g->log[a]) % 65535]; }

/* 1 / ((K + r) ⊕ d) */
static uint16_t coef(const gf *g, uint32_t r, uint32_t d, uint32_t k) { return gf_inv(g, (uint16_t)((k + r) ^ d)); }

/* dst ^= f · src over little-endian 16-bit words; bytes is even. */
static void muladd(const gf *g, uint8_t *dst, const uint8_t *src, size_t bytes, uint16_t f) {
    if (!f) return;
    size_t i = 0;
#if defined(__aarch64__) && defined(__ARM_NEON)
    uint8_t t[128];
    for (int n = 0; n < 4; n++)
        for (int v = 0; v < 16; v++) {
            uint16_t p = gf_mul(g, f, (uint16_t)(v << (4 * n)));
            t[n * 32 + v] = (uint8_t)p;
            t[n * 32 + 16 + v] = (uint8_t)(p >> 8);
        }
    const uint8x16_t t0l = vld1q_u8(t), t0h = vld1q_u8(t + 16), t1l = vld1q_u8(t + 32), t1h = vld1q_u8(t + 48);
    const uint8x16_t t2l = vld1q_u8(t + 64), t2h = vld1q_u8(t + 80), t3l = vld1q_u8(t + 96), t3h = vld1q_u8(t + 112);
    const uint8x16_t mask = vdupq_n_u8(15);
    for (; i + 32 <= bytes; i += 32) {
        uint8x16x2_t s = vld2q_u8(src + i), d = vld2q_u8(dst + i);
        uint8x16_t n0 = vandq_u8(s.val[0], mask), n1 = vshrq_n_u8(s.val[0], 4);
        uint8x16_t n2 = vandq_u8(s.val[1], mask), n3 = vshrq_n_u8(s.val[1], 4);
        d.val[0] = veorq_u8(d.val[0], veorq_u8(veorq_u8(vqtbl1q_u8(t0l, n0), vqtbl1q_u8(t1l, n1)),
                                               veorq_u8(vqtbl1q_u8(t2l, n2), vqtbl1q_u8(t3l, n3))));
        d.val[1] = veorq_u8(d.val[1], veorq_u8(veorq_u8(vqtbl1q_u8(t0h, n0), vqtbl1q_u8(t1h, n1)),
                                               veorq_u8(vqtbl1q_u8(t2h, n2), vqtbl1q_u8(t3h, n3))));
        vst2q_u8(dst + i, d);
    }
#endif
    if (i >= bytes) return;
    uint16_t lo[256], hi[256];
    for (int v = 0; v < 256; v++) {
        lo[v] = gf_mul(g, f, (uint16_t)v);
        hi[v] = gf_mul(g, f, (uint16_t)(v << 8));
    }
    for (; i + 1 < bytes; i += 2) {
        uint16_t p = lo[src[i]] ^ hi[src[i + 1]];
        dst[i] ^= (uint8_t)p;
        dst[i + 1] ^= (uint8_t)(p >> 8);
    }
}

/* Gauss–Jordan inverse of the n×n matrix a (destroyed) into inv. */
static int gf_invert(const gf *g, uint16_t *a, uint16_t *inv, size_t n) {
    for (size_t i = 0; i < n; i++)
        for (size_t j = 0; j < n; j++) inv[i * n + j] = i == j;
    for (size_t c = 0; c < n; c++) {
        size_t p = c;
        while (p < n && !a[p * n + c]) p++;
        if (p == n) return -1;
        if (p != c)
            for (size_t k = 0; k < n; k++) {
                uint16_t t = a[c * n + k]; a[c * n + k] = a[p * n + k]; a[p * n + k] = t;
                t = inv[c * n + k]; inv[c * n + k] = inv[p * n + k]; inv[p * n + k] = t;
            }
        uint16_t q = gf_inv(g, a[c * n + c]);
        for (size_t k = 0; k < n; k++) { a[c * n + k] = gf_mul(g, a[c * n + k], q); inv[c * n + k] = gf_mul(g, inv[c * n + k], q); }
        for (size_t r = 0; r < n; r++) {
            uint16_t f = a[r * n + c];
            if (r == c || !f) continue;
            for (size_t k = 0; k < n; k++) { a[r * n + k] ^= gf_mul(g, f, a[c * n + k]); inv[r * n + k] ^= gf_mul(g, f, inv[c * n + k]); }
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ read-write file */

typedef struct rwfile {
#if defined(_WIN32)
    HANDLE h;
#else
    int fd;
#endif
} rwfile;

static int rw_open(rwfile *f, const char *path, xiz_error *err) {
#if defined(_WIN32)
    wchar_t *w = xiz_utf8_to_wide(path);
    f->h = w ? CreateFileW(w, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL)
             : INVALID_HANDLE_VALUE;
    free(w);
    if (f->h == INVALID_HANDLE_VALUE) return FAIL(XIZ_E_IO, "cannot open %s for writing", path);
#else
    f->fd = open(path, O_RDWR | O_CLOEXEC);
    if (f->fd < 0) return FAIL(XIZ_E_IO, "cannot open %s for writing: %s", path, strerror(errno));
#endif
    return XIZ_OK;
}

static void rw_close(rwfile *f) {
#if defined(_WIN32)
    CloseHandle(f->h);
#else
    close(f->fd);
#endif
}

static int rw_write(rwfile *f, uint64_t off, const void *data, size_t n, xiz_error *err) {
    const uint8_t *p = data;
    while (n) {
#if defined(_WIN32)
        DWORD chunk = n > 0x40000000u ? 0x40000000u : (DWORD)n, put = 0;
        OVERLAPPED ov;
        memset(&ov, 0, sizeof ov);
        ov.Offset = (DWORD)off;
        ov.OffsetHigh = (DWORD)(off >> 32);
        if (!WriteFile(f->h, p, chunk, &put, &ov) || !put) return FAIL(XIZ_E_IO, "write failed");
        size_t r = put;
#else
        ssize_t w = pwrite(f->fd, p, n, (off_t)off);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return FAIL(XIZ_E_IO, "write failed: %s", strerror(errno));
        size_t r = (size_t)w;
#endif
        p += r;
        off += r;
        n -= r;
    }
    return XIZ_OK;
}

static int rw_truncate(rwfile *f, uint64_t at, xiz_error *err) {
#if defined(_WIN32)
    LARGE_INTEGER li;
    li.QuadPart = (LONGLONG)at;
    if (!SetFilePointerEx(f->h, li, NULL, FILE_BEGIN) || !SetEndOfFile(f->h)) return FAIL(XIZ_E_IO, "cannot truncate");
#else
    if (ftruncate(f->fd, (off_t)at) != 0) return FAIL(XIZ_E_IO, "cannot truncate: %s", strerror(errno));
#endif
    return XIZ_OK;
}

static int rw_sync(rwfile *f, xiz_error *err) {
#if defined(_WIN32)
    if (!FlushFileBuffers(f->h)) return FAIL(XIZ_E_IO, "flush failed");
#elif defined(__APPLE__)
    if (fcntl(f->fd, F_FULLFSYNC) != 0 && fsync(f->fd) != 0) return FAIL(XIZ_E_IO, "fsync failed");
#else
    if (fsync(f->fd) != 0) return FAIL(XIZ_E_IO, "fsync failed");
#endif
    return XIZ_OK;
}

/* ------------------------------------------------------------------ structures */

typedef struct rheader {
    uint8_t archive_id[16];
    uint64_t p;              /* protected length */
    uint32_t s, k, m;        /* slice size, data slices, recovery slices */
    uint8_t table_hash[16];
} rheader;

static uint64_t table_bytes(const rheader *h) { return (uint64_t)R_HASH * (h->k + h->m); }
static uint64_t rec_offset(const rheader *h) { return (h->p + R_HEADER + table_bytes(h) + 4095) & ~(uint64_t)4095; }
static uint64_t header_b(const rheader *h) { return rec_offset(h) + (uint64_t)h->m * h->s; }
static uint64_t record_end(const rheader *h) { return header_b(h) + R_HEADER + table_bytes(h) + R_TRAILER; }

static uint16_t r16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }

static void header_encode(const rheader *h, uint8_t b[R_HEADER]) {
    memset(b, 0, R_HEADER);
    memcpy(b, "XIZR", 4);
    wr16(b + 4, 1);
    memcpy(b + 8, h->archive_id, 16);
    wr64(b + 24, h->p);
    wr32(b + 32, h->s);
    wr32(b + 36, h->k);
    wr32(b + 40, h->m);
    memcpy(b + 44, h->table_hash, 16);
    wr32(b + 60, xiz_crc32c(0, b, 60));
}

static int header_decode(const uint8_t b[R_HEADER], rheader *h) {
    memset(h, 0, sizeof *h);  /* padding too: copies are compared with memcmp */
    if (memcmp(b, "XIZR", 4) != 0 || rd32(b + 60) != xiz_crc32c(0, b, 60) || r16(b + 4) != 1 || r16(b + 6) != 0) return 0;
    memcpy(h->archive_id, b + 8, 16);
    h->p = rd64(b + 24);
    h->s = rd32(b + 32);
    h->k = rd32(b + 36);
    h->m = rd32(b + 40);
    memcpy(h->table_hash, b + 44, 16);
    return h->s >= 4096 && h->s % 4096 == 0 && h->k >= 1 && h->k <= R_MAX_DATA && h->m >= 1 && h->m <= h->k &&
           h->p > 64 + XIZ_FOOTER && (h->p + h->s - 1) / h->s == h->k;
}

static void trailer_encode(const rheader *h, uint8_t b[R_TRAILER]) {
    memset(b, 0, R_TRAILER);
    memcpy(b, "XIZT", 4);
    wr16(b + 4, 1);
    memcpy(b + 8, h->archive_id, 16);
    wr64(b + 24, h->p);
    wr64(b + 32, rec_offset(h));
    wr64(b + 40, header_b(h));
    wr32(b + 56, xiz_crc32c(0, b, 56));
    memcpy(b + 60, "XZR!", 4);
}

static int src_get(const xiz_source *s, uint64_t off, void *buf, size_t n) {
    if (off > s->size || n > s->size - off) return -1;
    return n ? s->read(s->ctx, off, buf, n) : 0;
}

static void prefix_hash(const void *d, size_t n, uint8_t out[R_HASH]) {
    uint8_t full[32];
    sha256(d, n, full);
    memcpy(out, full, R_HASH);
}

/* The header at `off` with its table (malloc'd), when both check out and `off` is one of its copies. */
static int candidate(const xiz_source *s, uint64_t off, rheader *h, uint8_t **table) {
    uint8_t b[R_HEADER];
    if (src_get(s, off, b, R_HEADER) || !header_decode(b, h) || (off != h->p && off != header_b(h))) return 0;
    uint64_t n = table_bytes(h);
    uint8_t *t = malloc((size_t)n), hash[R_HASH];
    if (!t) return 0;
    if (src_get(s, off + R_HEADER, t, (size_t)n)) { free(t); return 0; }
    prefix_hash(t, (size_t)n, hash);
    if (memcmp(hash, h->table_hash, R_HASH) != 0) { free(t); return 0; }
    *table = t;
    return 1;
}

/* Finds the record: trailer first, else the last valid header from the end. */
static int locate(const xiz_source *s, rheader *h, uint8_t **table, uint32_t *damaged) {
    uint8_t t[R_TRAILER];
    int trailer_ok = 0, found = 0;
    uint64_t ta = 0, tb = 0;
    if (s->size >= R_TRAILER && !src_get(s, s->size - R_TRAILER, t, R_TRAILER) && memcmp(t, "XIZT", 4) == 0 &&
        memcmp(t + 60, "XZR!", 4) == 0 && rd32(t + 56) == xiz_crc32c(0, t, 56) && r16(t + 4) == 1) {
        trailer_ok = 1;
        ta = rd64(t + 24);
        tb = rd64(t + 40);
        found = candidate(s, ta, h, table) || candidate(s, tb, h, table);
        if (found && (h->p != ta || header_b(h) != tb || record_end(h) != s->size)) trailer_ok = 0;
    }
    if (!found) {
        trailer_ok = 0;
        const size_t window = 1 << 20;
        uint8_t *buf = malloc(window);
        if (!buf) return 0;
        uint64_t end = s->size;
        while (!found && end > 64) {
            uint64_t start = end > window ? end - window : 0;
            size_t n = (size_t)(end - start);
            if (src_get(s, start, buf, n)) break;
            for (size_t i = n; i >= 4 && !found; i--)
                if (memcmp(buf + i - 4, "XIZR", 4) == 0) found = candidate(s, start + i - 4, h, table);
            if (start == 0) break;
            end = start + 3;
        }
        free(buf);
        if (!found) return 0;
    }
    *damaged = trailer_ok ? 0 : 1;
    uint64_t copies[2] = {h->p, header_b(h)};
    for (int c = 0; c < 2; c++) {
        rheader o;
        uint8_t *ot = NULL;
        if (!candidate(s, copies[c], &o, &ot) || memcmp(&o, h, sizeof o) != 0 || memcmp(ot, *table, (size_t)table_bytes(h)) != 0) (*damaged)++;
        free(ot);
    }
    return 1;
}

/* Data slice d from byte lo, n bytes, zero past the protected end or the end of the file. */
static void read_piece(const xiz_source *s, const rheader *h, uint32_t d, uint32_t lo, uint8_t *buf, size_t n) {
    memset(buf, 0, n);
    uint64_t start = (uint64_t)d * h->s + lo, limit = h->p < s->size ? h->p : s->size;
    if (start >= limit) return;
    size_t take = (size_t)(limit - start < n ? limit - start : n);
    if (src_get(s, start, buf, take)) memset(buf, 0xFF, n);  /* unreadable: treated as damaged by the hash */
}

static void slice_hash(const xiz_source *s, const rheader *h, uint32_t i, uint8_t *buf, uint8_t out[R_HASH], int *beyond) {
    *beyond = 0;
    if (i < h->k) {
        read_piece(s, h, i, 0, buf, h->s);
        uint64_t end = (uint64_t)(i + 1) * h->s;
        if (end > h->p) end = h->p;
        *beyond = s->size < end;
    } else {
        uint64_t at = rec_offset(h) + (uint64_t)(i - h->k) * h->s;
        if (src_get(s, at, buf, h->s)) { *beyond = 1; memset(out, 0, R_HASH); return; }
    }
    prefix_hash(buf, h->s, out);
}

/* Recovery slices `rows` (n of them) written in place; their hashes into hashes[n]. */
static int encode(const xiz_source *s, rwfile *f, const gf *g, const rheader *h, const uint32_t *rows, uint32_t n,
                  uint8_t *hashes, xiz_error *err) {
    size_t window = ((size_t)(256u << 20) / n) & ~(size_t)63;
    if (window < 64) window = 64;
    if (window > h->s) window = h->s;
    uint8_t *bufs = malloc(window * n), *piece = malloc(window);
    sha256_ctx *ctx = malloc(sizeof *ctx * n);
    int rc = XIZ_OK;
    if (!bufs || !piece || !ctx) { rc = FAIL(XIZ_E_NOMEM, "out of memory"); goto done; }
    for (uint32_t j = 0; j < n; j++) sha256_init(&ctx[j]);
    for (uint32_t lo = 0; lo < h->s; lo += (uint32_t)window) {
        size_t w = h->s - lo < window ? h->s - lo : window;
        memset(bufs, 0, window * n);
        for (uint32_t d = 0; d < h->k; d++) {
            read_piece(s, h, d, lo, piece, w);
            for (uint32_t j = 0; j < n; j++) muladd(g, bufs + j * window, piece, w, coef(g, rows[j], d, h->k));
        }
        for (uint32_t j = 0; j < n; j++) {
            sha256_update(&ctx[j], bufs + j * window, w);
            if ((rc = rw_write(f, rec_offset(h) + (uint64_t)rows[j] * h->s + lo, bufs + j * window, w, err))) goto done;
        }
    }
    for (uint32_t j = 0; j < n; j++) {
        uint8_t full[32];
        sha256_final(&ctx[j], full);
        memcpy(hashes + (size_t)j * R_HASH, full, R_HASH);
    }
done:
    free(bufs);
    free(piece);
    free(ctx);
    return rc;
}

/* Both header and table copies, the trailer, the exact length, then sync. */
static int write_metadata(rwfile *f, const rheader *h, const uint8_t *table, xiz_error *err) {
    uint8_t hb[R_HEADER], tb[R_TRAILER];
    header_encode(h, hb);
    trailer_encode(h, tb);
    size_t pad = (size_t)(rec_offset(h) - h->p - R_HEADER - table_bytes(h));
    uint8_t *zeros = calloc(1, pad + 1);
    if (!zeros) return FAIL(XIZ_E_NOMEM, "out of memory");
    int rc;
    if ((rc = rw_write(f, h->p, hb, R_HEADER, err)) || (rc = rw_write(f, h->p + R_HEADER, table, (size_t)table_bytes(h), err)) ||
        (rc = rw_write(f, h->p + R_HEADER + table_bytes(h), zeros, pad, err)) || (rc = rw_write(f, header_b(h), hb, R_HEADER, err)) ||
        (rc = rw_write(f, header_b(h) + R_HEADER, table, (size_t)table_bytes(h), err)) ||
        (rc = rw_write(f, record_end(h) - R_TRAILER, tb, R_TRAILER, err)) || (rc = rw_truncate(f, record_end(h), err)) ||
        (rc = rw_sync(f, err))) {
        free(zeros);
        return rc;
    }
    free(zeros);
    return XIZ_OK;
}

/* Rebuilds data slices miss[m] from recovery rows[m] and the intact data, in place. */
static int rebuild(const xiz_source *s, rwfile *f, const gf *g, const rheader *h, const uint32_t *miss, const uint32_t *rows,
                   uint32_t m, xiz_error *err) {
    size_t window = ((size_t)(128u << 20) / m) & ~(size_t)63;
    if (window < 64) window = 64;
    if (window > h->s) window = h->s;
    uint16_t *a = malloc(sizeof *a * m * m), *inv = malloc(sizeof *inv * m * m);
    uint8_t *b = malloc(window * m), *out = malloc(window), *piece = malloc(window), *is_miss = calloc(h->k, 1);
    int rc = XIZ_OK;
    if (!a || !inv || !b || !out || !piece || !is_miss) { rc = FAIL(XIZ_E_NOMEM, "out of memory"); goto done; }
    for (uint32_t j = 0; j < m; j++)
        for (uint32_t i = 0; i < m; i++) a[j * m + i] = coef(g, rows[j], miss[i], h->k);
    if (gf_invert(g, a, inv, m)) { rc = FAIL(XIZ_E_CORRUPT, "recovery matrix is singular"); goto done; }
    for (uint32_t i = 0; i < m; i++) is_miss[miss[i]] = 1;
    for (uint32_t lo = 0; lo < h->s; lo += (uint32_t)window) {
        size_t w = h->s - lo < window ? h->s - lo : window;
        for (uint32_t j = 0; j < m; j++)
            if (src_get(s, rec_offset(h) + (uint64_t)rows[j] * h->s + lo, b + j * window, w)) { rc = FAIL(XIZ_E_IO, "read failed"); goto done; }
        for (uint32_t d = 0; d < h->k; d++) {
            if (is_miss[d]) continue;
            read_piece(s, h, d, lo, piece, w);
            for (uint32_t j = 0; j < m; j++) muladd(g, b + j * window, piece, w, coef(g, rows[j], d, h->k));
        }
        for (uint32_t i = 0; i < m; i++) {
            memset(out, 0, w);
            for (uint32_t j = 0; j < m; j++) muladd(g, out, b + j * window, w, inv[i * m + j]);
            uint64_t start = (uint64_t)miss[i] * h->s + lo;
            if (start >= h->p) continue;
            size_t n = (size_t)(h->p - start < w ? h->p - start : w);
            if ((rc = rw_write(f, start, out, n, err))) goto done;
        }
    }
    rc = rw_sync(f, err);
done:
    free(a); free(inv); free(b); free(out); free(piece); free(is_miss);
    return rc;
}

/* ------------------------------------------------------------------ public */

static void fill_info(const rheader *h, xiz_recovery_info *out) {
    if (!out) return;
    out->slice_size = h->s;
    out->data_slices = h->k;
    out->recovery_slices = h->m;
    out->protected_length = h->p;
    out->record_bytes = record_end(h) - h->p;
}

/* The end of the archive proper: before the record, or after the last valid footer. */
static int protected_end(const xiz_source *s, uint64_t *end, uint8_t id[16], xiz_error *err) {
    uint8_t sb[64];
    if (src_get(s, 0, sb, 64)) return FAIL(XIZ_E_NOT_XIZ, "file too small");
    xiz_archive tmp;
    memset(&tmp, 0, sizeof tmp);
    int rc = superblock_parse(sb, &tmp.sb, 0, err);
    if (rc) return rc;
    tmp.src = *s;
    tmp.data_start = 64 + (uint64_t)tmp.sb.keys_length;
    uint64_t at;
    footer f;
    if ((rc = find_last_footer(&tmp, &at, &f, err))) return rc;
    *end = at + XIZ_FOOTER;
    memcpy(id, tmp.sb.id, 16);
    return XIZ_OK;
}

int xiz_recovery_info_file(const char *path, xiz_recovery_info *out, xiz_error *err) {
    xiz_source s;
    int rc = xiz_source_file(&s, path, err);
    if (rc) return rc;
    rheader h;
    uint8_t *table = NULL;
    uint32_t damaged;
    int found = locate(&s, &h, &table, &damaged);
    free(table);
    if (s.close) s.close(s.ctx);
    if (!found) return FAIL(XIZ_E_NOT_FOUND, "no recovery record");
    fill_info(&h, out);
    return XIZ_OK;
}

int xiz_recovery_scrub(const char *path, int repair, xiz_recovery_report *rep, xiz_error *err) {
    if (!path || !rep) return FAIL(XIZ_E_ARG, "missing argument");
    memset(rep, 0, sizeof *rep);
    xiz_source s;
    int rc = xiz_source_file(&s, path, err);
    if (rc) return rc;
    rheader h;
    uint8_t *table = NULL, *buf = NULL, *bad = NULL;
    uint32_t *miss = NULL, *rows = NULL, *bad_rows = NULL;
    gf *g = NULL;
    rwfile f;
    int opened = 0;
    if (!locate(&s, &h, &table, &rep->damaged_metadata)) goto done;
    rep->has_record = 1;
    fill_info(&h, &rep->info);
    uint32_t total = h.k + h.m;
    buf = malloc(h.s);
    bad = calloc(total, 1);
    miss = malloc(sizeof *miss * h.k);
    rows = malloc(sizeof *rows * h.m);
    bad_rows = malloc(sizeof *bad_rows * h.m);
    if (!buf || !bad || !miss || !rows || !bad_rows) { rc = FAIL(XIZ_E_NOMEM, "out of memory"); goto done; }
    uint32_t nmiss = 0, ngood = 0, nbad = 0;
    for (uint32_t i = 0; i < total; i++) {
        uint8_t hash[R_HASH];
        int beyond;
        slice_hash(&s, &h, i, buf, hash, &beyond);
        bad[i] = beyond || memcmp(hash, table + (size_t)i * R_HASH, R_HASH) != 0;
        if (i < h.k && bad[i]) miss[nmiss++] = i;
        else if (i >= h.k && bad[i]) bad_rows[nbad++] = i - h.k;
        else if (i >= h.k) rows[ngood++] = i - h.k;
    }
    rep->damaged_data_slices = nmiss;
    rep->damaged_recovery_slices = nbad;
    rep->repairable = nmiss <= ngood;
    int clean = !nmiss && !nbad && !rep->damaged_metadata;
    if (!repair || clean || !rep->repairable) goto done;

    if (!(g = gf_new())) { rc = FAIL(XIZ_E_NOMEM, "out of memory"); goto done; }
    if ((rc = rw_open(&f, path, err))) goto done;
    opened = 1;
    if (nmiss) {
        if ((rc = rebuild(&s, &f, g, &h, miss, rows, nmiss, err))) goto done;
        for (uint32_t i = 0; i < nmiss; i++) {
            uint8_t hash[R_HASH];
            int beyond;
            slice_hash(&s, &h, miss[i], buf, hash, &beyond);
            if (memcmp(hash, table + (size_t)miss[i] * R_HASH, R_HASH) != 0) {
                rc = FAIL(XIZ_E_CORRUPT, "the rebuilt bytes do not match the recovery record");
                goto done;
            }
        }
    }
    if (nbad) {
        if (s.size < record_end(&h)) {
            if ((rc = rw_truncate(&f, record_end(&h), err))) goto done;
            s.size = record_end(&h);
        }
        uint8_t *hashes = malloc((size_t)nbad * R_HASH);
        if (!hashes) { rc = FAIL(XIZ_E_NOMEM, "out of memory"); goto done; }
        rc = encode(&s, &f, g, &h, bad_rows, nbad, hashes, err);
        for (uint32_t j = 0; !rc && j < nbad; j++)
            if (memcmp(hashes + (size_t)j * R_HASH, table + (size_t)(h.k + bad_rows[j]) * R_HASH, R_HASH) != 0)
                rc = FAIL(XIZ_E_CORRUPT, "the rebuilt recovery slices do not match the recovery record");
        free(hashes);
        if (rc) goto done;
    }
    if ((rc = write_metadata(&f, &h, table, err))) goto done;
    rep->repaired = 1;
done:
    if (opened) rw_close(&f);
    if (s.close) s.close(s.ctx);
    free(table); free(buf); free(bad); free(miss); free(rows); free(bad_rows); free(g);
    return rc;
}

int xiz_recovery_add(const char *path, double redundancy, xiz_recovery_info *out, xiz_error *err) {
    if (!path || !(redundancy > 0 && redundancy <= 100)) return FAIL(XIZ_E_ARG, "redundancy must be between 1 and 100%%");
    xiz_source s;
    int rc = xiz_source_file(&s, path, err);
    if (rc) return rc;
    rheader h;
    memset(&h, 0, sizeof h);
    uint8_t *table = NULL;
    uint32_t *rows = NULL;
    gf *g = NULL;
    rwfile f;
    int opened = 0;
    if ((rc = protected_end(&s, &h.p, h.archive_id, err))) goto done;
    uint64_t size = ((h.p + R_TARGET - 1) / R_TARGET + 4095) & ~(uint64_t)4095;
    if (size < 4096) size = 4096;
    while ((h.p + size - 1) / size > R_MAX_DATA) size *= 2;
    if (size > 0x80000000u) { rc = FAIL(XIZ_E_LIMIT, "archive too large for a recovery record"); goto done; }
    h.s = (uint32_t)size;
    h.k = (uint32_t)((h.p + size - 1) / size);
    double mm = (double)h.k * redundancy / 100;
    h.m = (uint32_t)mm + ((double)(uint32_t)mm < mm);
    if (h.m < 1) h.m = 1;
    if (h.m > h.k) h.m = h.k;
    table = malloc((size_t)table_bytes(&h));
    rows = malloc(sizeof *rows * h.m);
    uint8_t *buf = malloc(h.s);
    g = gf_new();
    if (!table || !rows || !buf || !g) { free(buf); rc = FAIL(XIZ_E_NOMEM, "out of memory"); goto done; }
    if ((rc = rw_open(&f, path, err))) { free(buf); goto done; }
    opened = 1;
    /* The old record goes first: an interrupted run leaves the archive without one. */
    if ((rc = rw_truncate(&f, h.p, err))) { free(buf); goto done; }
    s.size = h.p;
    for (uint32_t d = 0; d < h.k; d++) {
        int beyond;
        slice_hash(&s, &h, d, buf, table + (size_t)d * R_HASH, &beyond);
    }
    free(buf);
    for (uint32_t j = 0; j < h.m; j++) rows[j] = j;
    if ((rc = encode(&s, &f, g, &h, rows, h.m, table + (size_t)h.k * R_HASH, err))) goto done;
    prefix_hash(table, (size_t)table_bytes(&h), h.table_hash);
    if ((rc = write_metadata(&f, &h, table, err))) goto done;
    fill_info(&h, out);
done:
    if (opened) rw_close(&f);
    if (s.close) s.close(s.ctx);
    free(table); free(rows); free(g);
    return rc;
}

int xiz_recovery_remove(const char *path, int *removed, xiz_error *err) {
    if (removed) *removed = 0;
    xiz_source s;
    int rc = xiz_source_file(&s, path, err);
    if (rc) return rc;
    rheader h;
    uint8_t *table = NULL, id[16];
    uint32_t damaged;
    uint64_t end = 0;
    int found = locate(&s, &h, &table, &damaged);
    free(table);
    if (found && !(rc = protected_end(&s, &end, id, err)) && end != h.p)
        rc = FAIL(XIZ_E_CORRUPT, "the recovery record does not follow the archive's footer");
    if (s.close) s.close(s.ctx);
    if (!found || rc) return rc;
    rwfile f;
    if ((rc = rw_open(&f, path, err))) return rc;
    rc = rw_truncate(&f, h.p, err);
    if (!rc) rc = rw_sync(&f, err);
    rw_close(&f);
    if (!rc && removed) *removed = 1;
    return rc;
}
