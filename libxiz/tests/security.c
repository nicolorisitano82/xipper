/* Malformed archives and hostile extraction. Archives are forged here byte by byte (one frame,
 * plain XIZ 1.x) so every rule can be broken on purpose; fixtures written by Xipper are mutated
 * too. Usage: xiz_security <fixtures dir> <scratch dir> */
#include "internal.h"

#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

static int failures, checks;
#define CHECK(c) do { checks++; if (!(c)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

/* ------------------------------------------------------------------ forge */

typedef struct {
    uint8_t type;
    const char *path;
    const char *data;            /* file content */
    uint16_t mode;
    const char *link;
} fentry;

typedef struct {
    uint16_t required;
    int codec;                   /* -1: store the data */
    const uint8_t *payload;      /* frame payload override */
    size_t payload_len;
    uint32_t usize_override;     /* 0: actual */
    uint16_t extra_tag;          /* one more field on entry 0 */
    int64_t total_delta;
    uint32_t extent_offset_delta;
    int catalog_trailing;
    int gap;                     /* bytes between frame and catalog */
    uint64_t usize_lie;          /* footer catalog_usize override */
} knobs;

static wbuf forge(const fentry *es, size_t n, const knobs *k) {
    wbuf data = {0}, cat = {0}, out = {0};
    for (size_t i = 0; i < n; i++)
        if (es[i].type == 0) wb_put(&data, es[i].data, strlen(es[i].data));
    superblock sb;
    memset(&sb, 0, sizeof sb);
    sb.major = 1;
    sb.minor = k->required & XIZ_FEATURE_LZMA2 ? 4 : 0;
    sb.required = k->required;
    for (int i = 0; i < 16; i++) sb.id[i] = (uint8_t)(i * 7 + 1);
    uint8_t sbb[64];
    superblock_encode(&sb, sbb);
    wb_put(&out, sbb, 64);
    frame_rec f;
    memset(&f, 0, sizeof f);
    f.offset = 64;
    f.codec = (uint8_t)(k->codec < 0 ? 0 : k->codec);
    const uint8_t *payload = k->payload ? k->payload : data.p;
    size_t plen = k->payload ? k->payload_len : data.n;
    f.csize = (uint32_t)plen;
    f.usize = k->usize_override ? k->usize_override : (uint32_t)data.n;
    f.crc = xiz_crc32c(0, payload ? payload : (const uint8_t *)"", plen);
    uint8_t fh[32];
    frame_header_encode(0, &f, fh);
    wb_put(&out, fh, 32);
    wb_put(&out, payload, plen);
    for (int i = 0; i < k->gap; i++) wb_u8(&out, 0);
    /* catalog */
    wb_put(&cat, "XCAT", 4);
    wb_u16(&cat, 1);
    wb_u32(&cat, 1);
    wb_u64(&cat, f.offset);
    wb_u32(&cat, f.csize);
    wb_u32(&cat, f.usize);
    wb_u32(&cat, f.crc);
    wb_u8(&cat, f.codec);
    wb_u8(&cat, 0);
    wb_u16(&cat, 0);
    wb_u32(&cat, (uint32_t)n);
    uint32_t at = 0;
    uint64_t total = 0;
    for (size_t i = 0; i < n; i++) {
        const fentry *e = &es[i];
        wb_u8(&cat, e->type);
        wb_u16(&cat, (uint16_t)strlen(e->path));
        wb_put(&cat, e->path, strlen(e->path));
        uint16_t nf = 1 + (e->type == 0 ? 2 : 0) + (e->type == 2 ? 1 : 0) + (i == 0 && k->extra_tag ? 1 : 0);
        wb_u16(&cat, nf);
        wb_u16(&cat, TAG_MODE); wb_u32(&cat, 2); wb_u16(&cat, e->mode ? e->mode : (e->type == 1 ? 0755 : 0644));
        if (e->type == 0) {
            uint32_t len = (uint32_t)strlen(e->data);
            wb_u16(&cat, TAG_SIZE); wb_u32(&cat, 8); wb_u64(&cat, len);
            wb_u16(&cat, TAG_EXTENTS); wb_u32(&cat, 12);
            wb_u32(&cat, 0); wb_u32(&cat, at + (i == 0 ? k->extent_offset_delta : 0)); wb_u32(&cat, len);
            at += len;
            total += len;
        }
        if (e->type == 2) { wb_u16(&cat, TAG_LINK); wb_u32(&cat, (uint32_t)strlen(e->link)); wb_put(&cat, e->link, strlen(e->link)); }
        if (i == 0 && k->extra_tag) { wb_u16(&cat, k->extra_tag); wb_u32(&cat, 3); wb_put(&cat, "abc", 3); }
    }
    for (int i = 0; i < k->catalog_trailing; i++) wb_u8(&cat, 0);
    size_t cap = zstd_bound(cat.n);
    uint8_t *z = malloc(cap);
    size_t zn = zstd_encode(cat.p, cat.n, 3, z, cap);
    footer ft;
    memset(&ft, 0, sizeof ft);
    ft.major = 1;
    ft.cat_offset = out.n;
    ft.cat_csize = zn;
    ft.cat_usize = k->usize_lie ? k->usize_lie : cat.n;
    ft.frame_count = 1;
    ft.entry_count = (uint32_t)n;
    ft.total_bytes = (uint64_t)((int64_t)total + k->total_delta);
    sha256(z, zn, ft.cat_sha);
    wb_put(&out, z, zn);
    uint8_t fb[96];
    footer_encode(&ft, fb);
    wb_put(&out, fb, 96);
    free(z);
    wb_free(&cat);
    wb_free(&data);
    return out;
}

static int open_mem(const wbuf *b, xiz_archive **a, xiz_error *e) {
    xiz_source s;
    xiz_source_memory(&s, b->p, b->n);
    return xiz_open(a, &s, NULL, e);
}

static int open_test(const uint8_t *p, size_t n) {
    xiz_source s;
    xiz_source_memory(&s, p, n);
    xiz_archive *a;
    xiz_error e;
    int rc = xiz_open(&a, &s, NULL, &e);
    if (rc) return rc;
    rc = xiz_test(a, 0, NULL, NULL, NULL, &e);
    xiz_close(a);
    return rc;
}

static const fentry basic[] = {
    {0, "hello.txt", "hello, world\n", 0, NULL},
    {1, "dir", NULL, 0, NULL},
    {0, "dir/b.txt", "second file\n", 0, NULL},
};

/* ------------------------------------------------------------------ structural rules */

static void test_structure(void) {
    knobs k = {0};
    k.codec = -1;
    wbuf b = forge(basic, 3, &k);
    CHECK(open_test(b.p, b.n) == XIZ_OK);

    /* Every single-byte change is detected (superblock CRC, frame header and CRC, catalog
     * SHA-256, footer CRC cover every byte). */
    int undetected = 0;
    for (size_t i = 0; i < b.n; i++) {
        b.p[i] ^= 0x01;
        if (open_test(b.p, b.n) == XIZ_OK) { undetected++; fprintf(stderr, "  byte %zu flip undetected\n", i); }
        b.p[i] ^= 0x01;
    }
    CHECK(undetected == 0);
    /* Every truncation fails cleanly. */
    int accepted = 0;
    for (size_t n = 0; n < b.n; n++) accepted += open_test(b.p, n) == XIZ_OK;
    CHECK(accepted == 0);
    wb_free(&b);

    xiz_archive *a;
    xiz_error e;
    /* Unknown required feature bits (bit 2 is reserved, 11–15 unknown). */
    k.required = 0x0800;
    b = forge(basic, 3, &k);
    CHECK(open_mem(&b, &a, &e) == XIZ_E_UNSUPPORTED);
    wb_free(&b);
    /* Forensic profile (bit 9) without a version 3 directory: refused. */
    k.required = XIZ_FEATURE_FORENSIC;
    b = forge(basic, 3, &k);
    CHECK(open_mem(&b, &a, &e) != XIZ_OK);
    wb_free(&b);
    k.required = XIZ_FEATURE_APPEND_CHAIN;
    b = forge(basic, 3, &k);
    CHECK(open_mem(&b, &a, &e) == XIZ_E_UNSUPPORTED);
    wb_free(&b);
    k.required = XIZ_FEATURE_GENOMIC;
    b = forge(basic, 3, &k);
    CHECK(open_mem(&b, &a, &e) == XIZ_E_UNSUPPORTED);
    wb_free(&b);
    k.required = 0;

    /* Unknown critical field: refused; unknown non-critical field: skipped. */
    k.extra_tag = 0x8F00;
    b = forge(basic, 3, &k);
    CHECK(open_mem(&b, &a, &e) == XIZ_E_UNSUPPORTED);
    wb_free(&b);
    k.extra_tag = 0x0F00;
    b = forge(basic, 3, &k);
    CHECK(open_mem(&b, &a, &e) == XIZ_OK);
    if (a) xiz_close(a);
    wb_free(&b);
    k.extra_tag = 0;

    /* total_bytes, extents, trailing catalog bytes, gaps. */
    k.total_delta = 1;
    b = forge(basic, 3, &k);
    CHECK(open_mem(&b, &a, &e) == XIZ_E_CORRUPT);
    wb_free(&b);
    k.total_delta = 0;
    k.extent_offset_delta = 100;
    b = forge(basic, 3, &k);
    CHECK(open_mem(&b, &a, &e) == XIZ_E_CORRUPT);
    wb_free(&b);
    k.extent_offset_delta = 0;
    k.catalog_trailing = 1;
    b = forge(basic, 3, &k);
    CHECK(open_mem(&b, &a, &e) == XIZ_E_CORRUPT);
    wb_free(&b);
    k.catalog_trailing = 0;
    k.gap = 5;
    b = forge(basic, 3, &k);
    CHECK(open_mem(&b, &a, &e) == XIZ_E_CORRUPT);
    wb_free(&b);
    k.gap = 0;

    /* A forged catalog_usize must be refused by the limit, not allocated. */
    k.usize_lie = (uint64_t)1 << 30;
    b = forge(basic, 3, &k);
    {
        xiz_source s;
        xiz_source_memory(&s, b.p, b.n);
        xiz_open_options o;
        memset(&o, 0, sizeof o);
        o.max_catalog = 1 << 20;
        CHECK(xiz_open(&a, &s, &o, &e) == XIZ_E_LIMIT);
        CHECK(xiz_open(&a, &s, NULL, &e) == XIZ_E_CORRUPT);  /* streams, finds the real size */
    }
    wb_free(&b);
    k.usize_lie = 0;

    /* Decompression bombs: a frame declaring more than 64 MiB; a zstd frame decoding larger. */
    k.usize_override = XIZ_MAX_FRAME_DATA + 1;
    k.codec = 1;
    uint8_t zbuf[256];
    char big[200];
    memset(big, 'x', sizeof big);
    size_t zn = zstd_encode((const uint8_t *)big, sizeof big, 3, zbuf, sizeof zbuf);
    k.payload = zbuf;
    k.payload_len = zn;
    b = forge(basic, 3, &k);
    CHECK(open_mem(&b, &a, &e) == XIZ_E_LIMIT);
    wb_free(&b);
    k.usize_override = 0;  /* declared 25 bytes, the zstd frame decodes to 200: refused */
    b = forge(basic, 3, &k);
    CHECK(open_test(b.p, b.n) == XIZ_E_CORRUPT);
    wb_free(&b);
    k.payload = NULL;
    k.codec = -1;
}

/* LZMA2 uncompressed chunks, written by hand: 0x01, u16be(size-1), data; end marker 0x00. */
static void test_lzma2(void) {
    const char *content = "hello, world\nsecond file\n";
    size_t n = strlen(content);
    uint8_t p[64];
    size_t pl = 0;
    p[pl++] = 16;  /* dictionary property: 256 KiB */
    p[pl++] = 0x01;
    p[pl++] = (uint8_t)((n - 1) >> 8);
    p[pl++] = (uint8_t)(n - 1);
    memcpy(p + pl, content, n);
    pl += n;
    p[pl++] = 0x00;
    knobs k = {0};
    k.codec = 2;
    k.payload = p;
    k.payload_len = pl;
    k.required = XIZ_FEATURE_LZMA2;
    wbuf b = forge(basic, 3, &k);
    CHECK(open_test(b.p, b.n) == XIZ_OK);
    wb_free(&b);
    k.required = 0;  /* codec 2 without the feature bit */
    b = forge(basic, 3, &k);
    CHECK(open_test(b.p, b.n) == XIZ_E_CORRUPT);
    wb_free(&b);
    k.required = XIZ_FEATURE_LZMA2;
    p[pl] = 0x00;  /* data after the end marker */
    k.payload_len = pl + 1;
    b = forge(basic, 3, &k);
    CHECK(open_test(b.p, b.n) == XIZ_E_CORRUPT);
    wb_free(&b);
    k.payload_len = pl - 1;  /* no end marker */
    b = forge(basic, 3, &k);
    CHECK(open_test(b.p, b.n) == XIZ_E_CORRUPT);
    wb_free(&b);
    k.payload_len = pl;
    p[0] = 29;  /* dictionary above 64 MiB */
    b = forge(basic, 3, &k);
    CHECK(open_test(b.p, b.n) == XIZ_E_CORRUPT);
    wb_free(&b);
    p[0] = 16;
    k.codec = 3;  /* ARM64 + LZMA2: decodes, then the filter changes nothing in text */
    b = forge(basic, 3, &k);
    CHECK(open_test(b.p, b.n) == XIZ_OK);
    wb_free(&b);
}

static uint8_t *slurp(const char *path, size_t *n);

/* Brunsli frames (§16): the streams of jpeg.xiz, forged into archives with and without the
 * feature bit, then mutated. Every outcome must be a status; a decoder abort fails the test run. */
static void test_jpeg(const char *dir) {
    char path[1024];
    snprintf(path, sizeof path, "%s/jpeg.xiz", dir);
    size_t n;
    uint8_t *b = slurp(path, &n);
    CHECK(b != NULL);
    if (!b) return;
    if (!xiz_has_jpeg()) {
        CHECK(open_test(b, n) == XIZ_E_UNSUPPORTED);
        free(b);
        return;
    }
    CHECK(open_test(b, n) == XIZ_OK);
    xiz_source src;
    xiz_source_memory(&src, b, n);
    xiz_archive *a;
    xiz_error e;
    CHECK(xiz_open(&a, &src, NULL, &e) == XIZ_OK);
    const frame_rec *jf = NULL;
    for (uint32_t i = 0; i < a->cat.n_frames; i++)
        if (a->cat.frames[i].codec == CODEC_JPEG) jf = &a->cat.frames[i];
    CHECK(jf != NULL);
    if (!jf) { xiz_close(a); free(b); return; }
    size_t pl = jf->csize;
    uint32_t usize = jf->usize;
    uint8_t *p = malloc(pl);
    memcpy(p, b + jf->offset + 32, pl);
    xiz_close(a);
    knobs k = {0};
    k.codec = CODEC_JPEG;
    k.payload = p;
    k.payload_len = pl;
    k.usize_override = usize;
    wbuf w = forge(basic, 3, &k);  /* codec 4 without the feature bit */
    CHECK(open_test(w.p, w.n) == XIZ_E_CORRUPT);
    wb_free(&w);
    k.required = XIZ_FEATURE_JPEG;
    k.usize_override = usize - 1;  /* decodes to more than declared */
    w = forge(basic, 3, &k);
    CHECK(open_test(w.p, w.n) == XIZ_E_CORRUPT);
    wb_free(&w);
    k.usize_override = usize;
    uint32_t seed = 12345;
    int ok = 0;
    for (int round = 0; round < 500; round++) {
        uint8_t *m = malloc(pl);
        memcpy(m, p, pl);
        size_t ml = pl;
        seed = seed * 1103515245u + 12345u;
        if (round % 3 == 0) {
            ml = 1 + (seed >> 8) % (pl - 1);  /* truncated */
        } else {
            for (int j = 0; j < 1 + round % 8; j++) {
                seed = seed * 1103515245u + 12345u;
                m[(seed >> 8) % pl] ^= (uint8_t)(1 + (seed >> 3) % 255);
            }
        }
        k.payload = m;
        k.payload_len = ml;
        w = forge(basic, 3, &k);
        int rc = open_test(w.p, w.n);  /* the forged entries do not match the JPEG: never OK */
        if (rc == XIZ_OK) ok++;
        wb_free(&w);
        free(m);
    }
    CHECK(ok == 0);
    free(p);
    free(b);
}

/* preflate frames (§19): the first codec 7 frame of docs.xiz, forged and mutated like test_jpeg. */
static void test_preflate(const char *dir) {
    char path[1024];
    snprintf(path, sizeof path, "%s/docs.xiz", dir);
    size_t n;
    uint8_t *b = slurp(path, &n);
    CHECK(b != NULL);
    if (!b) return;
    if (!xiz_has_preflate()) {
        CHECK(open_test(b, n) == XIZ_E_UNSUPPORTED);
        free(b);
        return;
    }
    CHECK(open_test(b, n) == XIZ_OK);
    xiz_source src;
    xiz_source_memory(&src, b, n);
    xiz_archive *a;
    xiz_error e;
    CHECK(xiz_open(&a, &src, NULL, &e) == XIZ_OK);
    const frame_rec *pf = NULL;
    for (uint32_t i = 0; i < a->cat.n_frames && !pf; i++)
        if (a->cat.frames[i].codec == CODEC_PREFLATE) pf = &a->cat.frames[i];
    CHECK(pf != NULL);
    if (!pf) { xiz_close(a); free(b); return; }
    size_t pl = pf->csize;
    uint32_t usize = pf->usize;
    uint8_t *p = malloc(pl);
    memcpy(p, b + pf->offset + 32, pl);
    xiz_close(a);
    knobs k = {0};
    k.codec = CODEC_PREFLATE;
    k.payload = p;
    k.payload_len = pl;
    k.usize_override = usize;
    wbuf w = forge(basic, 3, &k);  /* codec 7 without the feature bit */
    CHECK(open_test(w.p, w.n) == XIZ_E_CORRUPT);
    wb_free(&w);
    k.required = XIZ_FEATURE_DEFLATE;
    uint32_t seed = 4242;
    int ok = 0;
    for (int round = 0; round < 300; round++) {
        uint8_t *m = malloc(pl);
        memcpy(m, p, pl);
        size_t ml = pl;
        seed = seed * 1103515245u + 12345u;
        if (round % 3 == 0) {
            ml = 1 + (seed >> 8) % (pl - 1);
        } else {
            for (int j = 0; j < 1 + round % 8; j++) {
                seed = seed * 1103515245u + 12345u;
                m[(seed >> 8) % pl] ^= (uint8_t)(1 + (seed >> 3) % 255);
            }
        }
        k.payload = m;
        k.payload_len = ml;
        w = forge(basic, 3, &k);
        if (open_test(w.p, w.n) == XIZ_OK) ok++;
        wb_free(&w);
        free(m);
    }
    CHECK(ok == 0);
    free(p);
    free(b);
}

/* ------------------------------------------------------------------ extraction */

static int exists(const char *p) {
    struct stat st;
    return lstat(p, &st) == 0;
}

static void extract_forged(const fentry *es, size_t n, const char *dest, unsigned flags, xiz_extract_report *rep) {
    knobs k = {0};
    k.codec = -1;
    wbuf b = forge(es, n, &k);
    xiz_archive *a;
    xiz_error e;
    int rc = open_mem(&b, &a, &e);
    CHECK(rc == XIZ_OK);
    if (rc) { fprintf(stderr, "  %s\n", e.message); wb_free(&b); return; }
    xiz_extract_options o;
    memset(&o, 0, sizeof o);
    o.flags = flags;
    memset(rep, 0, sizeof *rep);
    xiz_extract(a, dest, &o, rep, &e);
    xiz_close(a);
    wb_free(&b);
}

static void test_extraction(const char *scratch) {
    char root[1024], dest[1100], p[1200];
    snprintf(root, sizeof root, "%s/secXXXXXX", scratch);
    mkdir(scratch, 0755);
    if (!mkdtemp(root)) { CHECK(0); return; }
    snprintf(dest, sizeof dest, "%s/dest", root);
    xiz_extract_report r;

    static const fentry traversal[] = {
        {0, "../escape.txt", "x", 0, NULL},
        {0, "a/../../escape2.txt", "x", 0, NULL},
        {0, "/abs/file.txt", "absolute\n", 0, NULL},
        {0, "./dot/./file.txt", "dots\n", 0, NULL},
        {0, "suid", "s\n", 04755, NULL},
    };
    extract_forged(traversal, 5, dest, 0, &r);
    snprintf(p, sizeof p, "%s/escape.txt", root);
    CHECK(!exists(p));
    snprintf(p, sizeof p, "%s/../escape2.txt", root);
    CHECK(!exists(p));
    snprintf(p, sizeof p, "%s/abs/file.txt", dest);
    CHECK(exists(p));
    snprintf(p, sizeof p, "%s/dot/file.txt", dest);
    CHECK(exists(p));
    CHECK(r.skipped == 2);
    struct stat st;
    snprintf(p, sizeof p, "%s/suid", dest);
    CHECK(stat(p, &st) == 0 && (st.st_mode & 07777) == 0755);

    /* Symbolic links: outside targets refused, inside ones kept, nothing written through one. */
    snprintf(dest, sizeof dest, "%s/dest2", root);
    static const fentry links[] = {
        {2, "up", NULL, 0, "../outside"},
        {2, "abs", NULL, 0, "/etc"},
        {2, "self", NULL, 0, "."},
        {2, "climb", NULL, 0, "self/.."},
        {2, "ok", NULL, 0, "sub/target.txt"},
        {2, "sub/back", NULL, 0, "../ok"},
        {0, "sub/target.txt", "t\n", 0, NULL},
        {2, "w", NULL, 0, "/tmp"},
        {0, "w/pwned.txt", "should be a real folder\n", 0, NULL},
    };
    extract_forged(links, 9, dest, 0, &r);
    snprintf(p, sizeof p, "%s/up", dest);
    CHECK(!exists(p));
    snprintf(p, sizeof p, "%s/abs", dest);
    CHECK(!exists(p));
    snprintf(p, sizeof p, "%s/climb", dest);
    CHECK(!exists(p));
    snprintf(p, sizeof p, "%s/ok", dest);
    CHECK(lstat(p, &st) == 0 && S_ISLNK(st.st_mode));
    snprintf(p, sizeof p, "%s/sub/back", dest);
    CHECK(lstat(p, &st) == 0 && S_ISLNK(st.st_mode));
    snprintf(p, sizeof p, "%s/w", dest);
    CHECK(lstat(p, &st) == 0 && S_ISDIR(st.st_mode));  /* the file made it a folder; the link was refused */
    CHECK(r.symlinks == 3);

    /* A symlink already in the destination is never followed. */
    char outside[1100];
    snprintf(dest, sizeof dest, "%s/dest3", root);
    snprintf(outside, sizeof outside, "%s/outside3", root);
    mkdir(dest, 0755);
    mkdir(outside, 0755);
    snprintf(p, sizeof p, "%s/pre", dest);
    CHECK(symlink(outside, p) == 0);
    static const fentry pre[] = {{0, "pre/f.txt", "through a link\n", 0, NULL}, {0, "pre", "replace\n", 0, NULL}};
    extract_forged(pre, 1, dest, XIZ_EXTRACT_OVERWRITE, &r);
    snprintf(p, sizeof p, "%s/f.txt", outside);
    CHECK(!exists(p));
    CHECK(r.skipped == 1);
    /* Overwriting a symlink with a file replaces the link, not its target. */
    extract_forged(pre + 1, 1, dest, XIZ_EXTRACT_OVERWRITE, &r);
    snprintf(p, sizeof p, "%s/pre", dest);
    CHECK(lstat(p, &st) == 0 && S_ISREG(st.st_mode));
    /* Without overwrite an existing file is kept. */
    extract_forged(pre + 1, 1, dest, 0, &r);
    CHECK(r.skipped == 1 && r.files == 0);
}

/* ------------------------------------------------------------------ callbacks (app API) */

typedef struct {
    int conflict_answer;
    int conflicts;
    uint64_t last_done, last_total;
    int byte_calls;
    int cancel_after;            /* > 0: cancel at that byte call */
    char written[8][256];
    int n_written;
} cb_state;

static int cb_bytes(void *ctx, uint64_t done, uint64_t total) {
    cb_state *s = ctx;
    s->byte_calls++;
    if (done < s->last_done || done > total) s->last_done = UINT64_MAX;  /* monotonic, within total */
    else s->last_done = done;
    s->last_total = total;
    return s->cancel_after && s->byte_calls >= s->cancel_after;
}

static void cb_written(void *ctx, const char *path, const char *disk) {
    (void)path;
    cb_state *s = ctx;
    if (s->n_written < 8) snprintf(s->written[s->n_written++], 256, "%s", disk);
}

static int cb_conflict(void *ctx, const char *path, const char *disk) {
    (void)path;
    (void)disk;
    cb_state *s = ctx;
    s->conflicts++;
    return s->conflict_answer;
}

static int extract_cb(const fentry *es, size_t n, const char *dest, unsigned flags, cb_state *s,
                      xiz_extract_report *rep) {
    knobs k = {0};
    k.codec = -1;
    wbuf b = forge(es, n, &k);
    xiz_archive *a;
    xiz_error e;
    int rc = open_mem(&b, &a, &e);
    CHECK(rc == XIZ_OK);
    if (rc) { wb_free(&b); return rc; }
    xiz_extract_options o;
    memset(&o, 0, sizeof o);
    o.flags = flags;
    o.ctx = s;
    o.bytes = cb_bytes;
    o.written = cb_written;
    o.conflict = s->conflict_answer >= 0 ? cb_conflict : NULL;
    memset(rep, 0, sizeof *rep);
    rc = xiz_extract(a, dest, &o, rep, &e);
    xiz_close(a);
    wb_free(&b);
    return rc;
}

static int has_written(const cb_state *s, const char *disk) {
    for (int i = 0; i < s->n_written; i++)
        if (strcmp(s->written[i], disk) == 0) return 1;
    return 0;
}

static void test_callbacks(const char *scratch) {
    char root[1024], dest[1100], p[1200];
    snprintf(root, sizeof root, "%s/cbXXXXXX", scratch);
    mkdir(scratch, 0755);
    if (!mkdtemp(root)) { CHECK(0); return; }
    xiz_extract_report r;
    cb_state s;
    struct stat st;

    /* Byte progress reaches the declared total; written() gives the disk names. */
    static const fentry two[] = {{0, "d/one.txt", "first file\n", 0, NULL}, {0, "two.txt", "second\n", 0, NULL}};
    snprintf(dest, sizeof dest, "%s/progress", root);
    memset(&s, 0, sizeof s);
    s.conflict_answer = -1;
    CHECK(extract_cb(two, 2, dest, 0, &s, &r) == XIZ_OK);
    CHECK(s.last_done == 18 && s.last_total == 18);
    CHECK(has_written(&s, "d/one.txt") && has_written(&s, "two.txt"));
    CHECK(r.files == 2);

    /* Conflicts: skip, rename, overwrite, cancel. */
    memset(&s, 0, sizeof s);
    s.conflict_answer = XIZ_CONFLICT_SKIP;
    CHECK(extract_cb(two, 2, dest, 0, &s, &r) == XIZ_OK);
    CHECK(s.conflicts == 2 && r.skipped == 2 && r.files == 0);
    CHECK(s.last_done == 18);  /* skipped files still advance the progress */
    memset(&s, 0, sizeof s);
    s.conflict_answer = XIZ_CONFLICT_RENAME;
    CHECK(extract_cb(two, 2, dest, 0, &s, &r) == XIZ_OK);
    CHECK(r.files == 2 && r.renamed == 2);
    CHECK(has_written(&s, "d/one (2).txt") && has_written(&s, "two (2).txt"));
    snprintf(p, sizeof p, "%s/d/one (2).txt", dest);
    CHECK(exists(p));
    memset(&s, 0, sizeof s);
    s.conflict_answer = XIZ_CONFLICT_RENAME;
    CHECK(extract_cb(two, 1, dest, 0, &s, &r) == XIZ_OK);
    CHECK(has_written(&s, "d/one (3).txt"));
    memset(&s, 0, sizeof s);
    s.conflict_answer = XIZ_CONFLICT_OVERWRITE;
    CHECK(extract_cb(two, 2, dest, 0, &s, &r) == XIZ_OK);
    CHECK(r.files == 2 && r.renamed == 0);
    memset(&s, 0, sizeof s);
    s.conflict_answer = XIZ_CONFLICT_CANCEL;
    CHECK(extract_cb(two, 2, dest, 0, &s, &r) == XIZ_E_CALLBACK);
    CHECK(s.conflicts == 1);

    /* Cancelling from the byte callback removes the file being written. */
    static const fentry big[] = {{0, "big.bin", "0123456789abcdef0123456789abcdef", 0, NULL}};
    snprintf(dest, sizeof dest, "%s/cancel", root);
    memset(&s, 0, sizeof s);
    s.conflict_answer = -1;
    s.cancel_after = 2;  /* call 1: before anything, call 2: after the first write */
    CHECK(extract_cb(big, 1, dest, 0, &s, &r) == XIZ_E_CALLBACK);
    snprintf(p, sizeof p, "%s/big.bin", dest);
    CHECK(!exists(p));
    CHECK(r.files == 0);

    /* Names equal but for case: a folder wins, then the first file. */
    static const fentry cases[] = {
        {0, "Readme.txt", "first\n", 0, NULL},
        {0, "README.TXT", "second\n", 0, NULL},
        {0, "readme.txt", "third\n", 0, NULL},
        {0, "docs", "a file named like a folder\n", 0, NULL},
        {0, "DOCS/inside.txt", "in the folder\n", 0, NULL},
        {0, "Readme (2).txt", "already this name\n", 0, NULL},
    };
    snprintf(dest, sizeof dest, "%s/case", root);
    memset(&s, 0, sizeof s);
    s.conflict_answer = -1;
    CHECK(extract_cb(cases, 6, dest, XIZ_EXTRACT_FOLD_CASE, &s, &r) == XIZ_OK);
    CHECK(r.files == 6 && r.skipped == 0 && r.renamed == 3);
    CHECK(has_written(&s, "Readme.txt"));
    CHECK(has_written(&s, "Readme (2).txt"));
    CHECK(has_written(&s, "README (3).TXT"));
    CHECK(has_written(&s, "readme (4).txt"));
    CHECK(has_written(&s, "docs (2)"));
    CHECK(has_written(&s, "DOCS/inside.txt"));
    snprintf(p, sizeof p, "%s/DOCS", dest);
    CHECK(stat(p, &st) == 0 && S_ISDIR(st.st_mode));

    /* xiz_test with progress and cancellation. */
    knobs k = {0};
    k.codec = -1;
    wbuf b = forge(two, 2, &k);
    xiz_archive *a;
    xiz_error e;
    CHECK(open_mem(&b, &a, &e) == XIZ_OK);
    memset(&s, 0, sizeof s);
    CHECK(xiz_test_progress(a, 0, NULL, cb_bytes, &s, NULL, &e) == XIZ_OK);
    CHECK(s.last_total == 36 && s.last_done == 36);  /* frames (18) + files (18) */
    memset(&s, 0, sizeof s);
    s.cancel_after = 1;
    CHECK(xiz_test_progress(a, 0, NULL, cb_bytes, &s, NULL, &e) == XIZ_E_CALLBACK);
    xiz_close(a);
    wb_free(&b);
}

/* ------------------------------------------------------------------ writer: 1.14, threads */

static int count_progress(void *ctx, uint64_t done, uint64_t total) {
    (void)total;
    *(uint64_t *)ctx = done;
    return 0;
}

static int stop_progress(void *ctx, uint64_t done, uint64_t total) {
    (void)ctx;
    (void)total;
    return done > 0;
}

static void test_writer(const char *scratch) {
    char root[1024], a1[1100], a8[1100], src[1100];
    snprintf(root, sizeof root, "%s/wrXXXXXX", scratch);
    mkdir(scratch, 0755);
    if (!mkdtemp(root)) { CHECK(0); return; }
    snprintf(src, sizeof src, "%s/data.bin", root);
    FILE *f = fopen(src, "wb");
    for (int i = 0; i < 3 * 1024 * 1024; i++) fputc((i * 7 + i / 1000) & 0xff, f);
    fclose(f);
    xiz_error e;
    /* Encrypted: XIZ 1.14 with a key commitment that libxiz checks when opening (§24.1). */
    snprintf(a1, sizeof a1, "%s/p.xiz", root);
    xiz_writer_options o;
    memset(&o, 0, sizeof o);
    o.password = "pw";
    o.kdf_memory_kib = 19456;
    o.kdf_iterations = 1;
    o.kdf_parallelism = 1;
    o.frame_size = 1u << 20;
    o.threads = 4;
    uint64_t seen = 0;
    o.progress = count_progress;
    o.progress_ctx = &seen;
    xiz_writer *w;
    CHECK(xiz_writer_create(&w, a1, &o, 1, &e) == XIZ_OK);
    CHECK(xiz_writer_add_file(w, "data.bin", src, NULL, &e) == XIZ_OK);
    CHECK(xiz_writer_finish(w, &e) == XIZ_OK);
    CHECK(seen == 2ull * 3 * 1024 * 1024);  /* read twice: hash, then data */
    xiz_open_options oo;
    memset(&oo, 0, sizeof oo);
    oo.password = "pw";
    xiz_archive *a;
    CHECK(xiz_open_file(&a, a1, &oo, &e) == XIZ_OK);
    xiz_info in;
    xiz_get_info(a, &in);
    CHECK(in.version_minor == 14);
    int commit = 0;
    for (size_t i = 0; i < xiz_stanza_count(a); i++) {
        xiz_stanza st;
        xiz_get_stanza(a, i, &st);
        commit += st.type == 9;
    }
    CHECK(commit == 1);
    CHECK(xiz_test(a, 0, NULL, NULL, NULL, &e) == XIZ_OK);
    xiz_close(a);
    oo.password = "wrong";
    CHECK(xiz_open_file(&a, a1, &oo, &e) == XIZ_E_WRONG_PASSWORD);
    /* One thread or eight: the same frames (the archive id differs, so compare the frame table). */
    snprintf(a8, sizeof a8, "%s/t8.xiz", root);
    snprintf(a1, sizeof a1, "%s/t1.xiz", root);
    for (int t = 1; t <= 8; t += 7) {
        memset(&o, 0, sizeof o);
        o.frame_size = 1u << 20;
        o.threads = t;
        CHECK(xiz_writer_create(&w, t == 1 ? a1 : a8, &o, 1, &e) == XIZ_OK);
        CHECK(xiz_writer_add_file(w, "data.bin", src, NULL, &e) == XIZ_OK);
        CHECK(xiz_writer_finish(w, &e) == XIZ_OK);
    }
    xiz_archive *b;
    memset(&oo, 0, sizeof oo);
    CHECK(xiz_open_file(&a, a1, &oo, &e) == XIZ_OK);
    CHECK(xiz_open_file(&b, a8, &oo, &e) == XIZ_OK);
    CHECK(a->cat.n_frames == b->cat.n_frames && a->cat.n_frames >= 3);
    for (uint32_t i = 0; i < a->cat.n_frames && i < b->cat.n_frames; i++)
        CHECK(a->cat.frames[i].csize == b->cat.frames[i].csize && a->cat.frames[i].crc == b->cat.frames[i].crc &&
              a->cat.frames[i].offset == b->cat.frames[i].offset);
    CHECK(xiz_test(b, 0, NULL, NULL, NULL, &e) == XIZ_OK);
    xiz_close(a);
    xiz_close(b);
    /* Cancelled from the progress callback: nothing is left. */
    snprintf(a1, sizeof a1, "%s/c.xiz", root);
    memset(&o, 0, sizeof o);
    o.progress = stop_progress;
    CHECK(xiz_writer_create(&w, a1, &o, 1, &e) == XIZ_OK);
    CHECK(xiz_writer_add_file(w, "data.bin", src, NULL, &e) == XIZ_E_CALLBACK);
    xiz_writer_abort(w);
    CHECK(!exists(a1));
}

/* ------------------------------------------------------------------ writer: XIZ 1.3 */

static size_t visible(xiz_archive *a, const char *prefix) {
    size_t n = 0;
    for (size_t i = 0; i < xiz_entry_count(a); i++) {
        xiz_entry e;
        xiz_get_entry(a, i, &e);
        if (!strncmp(e.path, prefix, strlen(prefix))) n++;
    }
    return n;
}

static int open_with(const char *path, const xiz_open_options *o, xiz_archive **a) {
    xiz_error e;
    return xiz_open_file(a, path, o, &e);
}

static void test_writer13(const char *scratch) {
    char root[1024], path[1100];
    snprintf(root, sizeof root, "%s/w13XXXXXX", scratch);
    mkdir(scratch, 0755);
    if (!mkdtemp(root)) { CHECK(0); return; }
    snprintf(path, sizeof path, "%s/a.xiz", root);
    /* Keys: an X25519 and an X-Wing identity, a factor. */
    char sec[64], pub[64], sec_pq[64], pub_pq[1700], ftext[64];
    uint8_t x_pub[1216], q_pub[1216], factor[32], x_sec[32], q_sec[32], f2[32];
    size_t kl;
    CHECK(xiz_generate_identity(0, sec, sizeof sec, pub, sizeof pub) == XIZ_OK);
    CHECK(xiz_generate_identity(1, sec_pq, sizeof sec_pq, pub_pq, sizeof pub_pq) == XIZ_OK);
    CHECK(xiz_parse_public_key(pub, strlen(pub), x_pub, sizeof x_pub, &kl) == XIZ_SECRET_X25519 && kl == 32);
    CHECK(xiz_parse_public_key(pub_pq, strlen(pub_pq), q_pub, sizeof q_pub, &kl) == XIZ_SECRET_XWING && kl == 1216);
    CHECK(xiz_parse_secret(sec, strlen(sec), x_sec) == XIZ_SECRET_X25519);
    CHECK(xiz_parse_secret(sec_pq, strlen(sec_pq), q_sec) == XIZ_SECRET_XWING);
    char again[1700];
    CHECK(xiz_public_from_secret(sec_pq, strlen(sec_pq), again, sizeof again) == XIZ_OK && !strcmp(again, pub_pq));
    CHECK(xiz_generate_factor(ftext, sizeof ftext, factor) == XIZ_OK);
    CHECK(xiz_parse_secret(ftext, strlen(ftext), f2) == XIZ_SECRET_FACTOR && !memcmp(f2, factor, 32));
    /* An age recipient: the same key as age's Bech32 (test vector computed here from x_pub). */
    CHECK(xiz_parse_public_key("xizpk1short", 11, x_pub + 600, 616, &kl) < 0);

    xiz_writer_options o;
    memset(&o, 0, sizeof o);
    o.kdf_memory_kib = 19456;
    o.kdf_iterations = 1;
    o.kdf_parallelism = 1;
    o.frame_size = 64 * 1024;
    static const char *const lab[] = {"lab"};
    xiz_group_spec g[1] = {{"Laboratorio", lab, 1}};
    static const uint16_t only_lab[] = {1}, only_main[] = {0};
    xiz_recipient r[4];
    memset(r, 0, sizeof r);
    r[0].type = XIZ_RECIPIENT_PASSWORD; r[0].label = "Tutto"; r[0].password = "all secret";
    r[1].type = XIZ_RECIPIENT_X25519; r[1].label = "Chiave"; r[1].public_key = x_pub; r[1].groups = only_lab; r[1].group_count = 1;
    r[2].type = XIZ_RECIPIENT_XWING; r[2].label = "PQ"; r[2].public_key = q_pub; r[2].groups = only_main; r[2].group_count = 1;
    r[3].type = XIZ_RECIPIENT_PASSWORD_FACTOR; r[3].label = "Fattore"; r[3].password = "with factor"; r[3].factor = factor;
    xiz_custodian cu[3];
    memset(cu, 0, sizeof cu);
    cu[0].type = XIZ_RECIPIENT_PASSWORD; cu[0].label = "C1"; cu[0].password = "c one";
    cu[1].type = XIZ_RECIPIENT_X25519; cu[1].label = "C2"; cu[1].public_key = x_pub;
    cu[2].type = XIZ_RECIPIENT_XWING; cu[2].label = "C3"; cu[2].public_key = q_pub;
    xiz_threshold th = {2, cu, 3, "Custodi", only_lab, 1};
    o.groups = g; o.group_count = 1;
    o.recipients = r; o.recipient_count = 4;
    o.thresholds = &th; o.threshold_count = 1;
    xiz_writer *w;
    xiz_error e;
    int rc = xiz_writer_create(&w, path, &o, 1, &e);
    CHECK(rc == XIZ_OK);
    if (rc) { fprintf(stderr, "  %s\n", e.message); return; }
    char big[200000];
    for (size_t i = 0; i < sizeof big; i++) big[i] = (char)(i * 13 + i / 777);
    CHECK(xiz_writer_add_directory(w, "lab", NULL, &e) == XIZ_OK);
    CHECK(xiz_writer_add_data(w, "lab/r1.txt", "referto 1\n", 10, NULL, &e) == XIZ_OK);
    CHECK(xiz_writer_add_data(w, "lab/big.bin", big, sizeof big, NULL, &e) == XIZ_OK);
    CHECK(xiz_writer_add_data(w, "doc/a.txt", "documento\n", 10, NULL, &e) == XIZ_OK);
    CHECK(xiz_writer_add_data(w, "doc/big-copy.bin", big, sizeof big, NULL, &e) == XIZ_OK);  /* no dedup across groups */
    CHECK(xiz_writer_add_symlink(w, "doc/link", "a.txt", NULL, &e) == XIZ_OK);
    rc = xiz_writer_finish(w, &e);
    CHECK(rc == XIZ_OK);
    if (rc) { fprintf(stderr, "  %s\n", e.message); return; }

    xiz_open_options oo;
    xiz_archive *a;
    memset(&oo, 0, sizeof oo);
    oo.password = "all secret";
    CHECK(open_with(path, &oo, &a) == XIZ_OK);
    xiz_info in;
    xiz_get_info(a, &in);
    CHECK(in.has_directory && in.version_minor == 14 && in.group_count == 2 && in.hidden_groups == 0);
    CHECK(visible(a, "lab/") == 2 && visible(a, "doc/") == 3);
    CHECK(xiz_test(a, 0, NULL, NULL, NULL, &e) == XIZ_OK);
    CHECK(xiz_check_tree(a, &e) == XIZ_OK);
    uint32_t leaf;
    CHECK(xiz_check_inclusion(a, 1, &leaf, &e) == XIZ_OK);
    xiz_group gr;
    CHECK(xiz_get_group(a, 1, &gr) == XIZ_OK && gr.name && !strcmp(gr.name, "Laboratorio") && gr.prefix_count == 1);
    xiz_close(a);
    /* The X25519 key: the laboratory only. */
    memset(&oo, 0, sizeof oo);
    oo.identities = (const uint8_t(*)[32])x_sec; oo.identity_count = 1;
    CHECK(open_with(path, &oo, &a) == XIZ_OK);
    xiz_get_info(a, &in);
    CHECK(in.hidden_groups == 1 && visible(a, "lab/") == 2 && visible(a, "doc/") == 0);
    CHECK(xiz_test(a, 0, NULL, NULL, NULL, &e) == XIZ_OK);
    xiz_close(a);
    /* The X-Wing key: everything else. */
    memset(&oo, 0, sizeof oo);
    oo.pq_identities = (const uint8_t(*)[32])q_sec; oo.pq_identity_count = 1;
    CHECK(open_with(path, &oo, &a) == XIZ_OK);
    CHECK(visible(a, "lab/") == 0 && visible(a, "doc/") == 3);
    xiz_close(a);
    /* Password with factor: needs the factor. */
    memset(&oo, 0, sizeof oo);
    oo.password = "with factor";
    CHECK(open_with(path, &oo, &a) == XIZ_E_FACTOR_REQUIRED);
    oo.factors = (const uint8_t(*)[32])factor; oo.factor_count = 1;
    CHECK(open_with(path, &oo, &a) == XIZ_OK);
    CHECK(visible(a, "lab/") == 2 && visible(a, "doc/") == 3);
    xiz_close(a);
    /* Custodians: one is not enough, two (password + X-Wing) are. */
    memset(&oo, 0, sizeof oo);
    oo.password = "c one";
    CHECK(open_with(path, &oo, &a) == XIZ_E_FACTOR_REQUIRED);  /* nothing opened, a factor stanza untried */
    oo.pq_identities = (const uint8_t(*)[32])q_sec; oo.pq_identity_count = 1;
    CHECK(open_with(path, &oo, &a) == XIZ_OK);
    CHECK(visible(a, "lab/") == 2);  /* the custodians' group, plus the X-Wing recipient's */
    xiz_close(a);
    memset(&oo, 0, sizeof oo);
    oo.password = "wrong";
    CHECK(open_with(path, &oo, &a) == XIZ_E_FACTOR_REQUIRED);
    /* Bad options are refused. */
    o.password = "also";
    CHECK(xiz_writer_create(&w, path, &o, 1, &e) == XIZ_E_ARG);
    o.password = NULL;
    th.k = 4;
    CHECK(xiz_writer_create(&w, path, &o, 1, &e) == XIZ_E_ARG);
    th.k = 2;
    /* Kept with its keys for cross-checks by other readers (Xipper for Mac). */
    const char *files[3][2] = {{"x25519.key", sec}, {"xwing.key", sec_pq}, {"f.xizfactor", ftext}};
    for (int i = 0; i < 3; i++) {
        char kp[1200];
        snprintf(kp, sizeof kp, "%s/%s", root, files[i][0]);
        FILE *kf = fopen(kp, "w");
        if (kf) { fprintf(kf, "%s\n", files[i][1]); fclose(kf); }
    }
    printf("w13: %s\n", path);
}

/* ------------------------------------------------------------------ fixtures */

static uint8_t *slurp(const char *path, size_t *n) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long l = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc((size_t)l + 1);
    if (b && fread(b, 1, (size_t)l, f) != (size_t)l) { free(b); b = NULL; }
    fclose(f);
    *n = (size_t)l;
    return b;
}

static void test_fixture_flips(const char *dir) {
    char path[1024];
    snprintf(path, sizeof path, "%s/lzma2-arm64.xiz", dir);
    size_t n;
    uint8_t *b = slurp(path, &n);
    CHECK(b != NULL);
    if (!b) return;
    CHECK(open_test(b, n) == XIZ_OK);
    int undetected = 0;
    for (size_t i = 0; i < n; i++) {
        b[i] ^= 0x80;
        if (open_test(b, n) == XIZ_OK) undetected++;
        b[i] ^= 0x80;
    }
    CHECK(undetected == 0);
    free(b);
}

static void test_erased_slot(const char *dir) {
    char path[1024];
    snprintf(path, sizeof path, "%s/erasable.xiz", dir);
    size_t n;
    uint8_t *b = slurp(path, &n);
    CHECK(b != NULL);
    if (!b) return;
    xiz_open_options o;
    memset(&o, 0, sizeof o);
    o.password = "alpha secret";
    xiz_source s;
    xiz_source_memory(&s, b, n);
    xiz_archive *a;
    xiz_error e;
    CHECK(xiz_open(&a, &s, &o, &e) == XIZ_OK);
    size_t idx;
    CHECK(xiz_find(a, "tree/docs/b.md", &idx) == XIZ_OK);
    const entry_rec *en = &a->cat.entries[idx];
    CHECK(en->has_slot && en->has_secret);
    uint64_t at = 0;
    for (uint16_t i = 0; i < a->dir.n_slots; i++)
        if (a->dir.slots[i].segment == en->slot_segment) at = a->dir.slots[i].offset + (uint64_t)en->slot_index * XIZ_SLOT_SIZE;
    size_t before = xiz_entry_count(a);
    uint32_t leaf;
    CHECK(xiz_check_inclusion(a, idx, &leaf, &e) == XIZ_OK);
    xiz_close(a);
    /* Altered slot: corruption. Zeroed slot: the entry is erased (§13.7). */
    b[at + 20] ^= 1;
    CHECK(xiz_open(&a, &s, &o, &e) == XIZ_E_CORRUPT);
    memset(b + at, 0, XIZ_SLOT_SIZE);
    CHECK(xiz_open(&a, &s, &o, &e) == XIZ_OK);
    if (a) {
        xiz_info in;
        xiz_get_info(a, &in);
        CHECK(in.erased_entries == 1 && xiz_entry_count(a) == before - 1);
        CHECK(xiz_find(a, "tree/docs/b.md", &idx) == XIZ_E_NOT_FOUND);
        CHECK(xiz_test(a, 0, NULL, NULL, NULL, &e) == XIZ_OK);
        xiz_close(a);
    }
    free(b);
}

/* The 32-byte secret after `prefix` in a key file (base64url). */
static int key_from_file(const char *path, const char *prefix, uint8_t out[32]) {
    size_t n;
    uint8_t *b = slurp(path, &n);
    if (!b) return 0;
    b[n] = 0;
    const char *p = strstr((const char *)b, prefix);
    size_t k = 0;
    if (p) {
        uint32_t acc = 0;
        int bits = 0;
        for (p += strlen(prefix); *p && k < 32; p++) {
            int c = *p, v = c >= 'A' && c <= 'Z' ? c - 'A' : c >= 'a' && c <= 'z' ? c - 'a' + 26
                          : c >= '0' && c <= '9' ? c - '0' + 52 : c == '-' ? 62 : c == '_' ? 63 : -1;
            if (v < 0) break;
            acc = acc << 6 | (uint32_t)v;
            bits += 6;
            if (bits >= 8) { bits -= 8; out[k++] = (uint8_t)(acc >> bits); }
        }
    }
    free(b);
    return k == 32;
}

static int open_pq(const uint8_t *b, size_t n, const uint8_t seed[32]) {
    xiz_open_options o;
    memset(&o, 0, sizeof o);
    o.pq_identities = (const uint8_t(*)[32])seed;
    o.pq_identity_count = 1;
    xiz_source s;
    xiz_source_memory(&s, b, n);
    xiz_archive *a = NULL;
    xiz_error e;
    int rc = xiz_open(&a, &s, &o, &e);
    if (a) xiz_close(a);
    return rc;
}

/* X-Wing stanzas (§17): every damaged byte of the ciphertext or key id, with the keys block's CRC
 * fixed so the damage reaches the decapsulation, leaves the stanza closed (implicit rejection). */
static void test_pq_stanza(const char *dir) {
    char path[1024];
    uint8_t seed[32];
    snprintf(path, sizeof path, "%s/identity-pq.key", dir);
    CHECK(key_from_file(path, "XIZ-SECRET-KEY-PQ-1-", seed));
    snprintf(path, sizeof path, "%s/access-pq.xiz", dir);
    size_t n;
    uint8_t *b = slurp(path, &n);
    CHECK(b != NULL);
    if (!b) return;
    CHECK(open_pq(b, n, seed) == XIZ_OK);
    uint8_t *blk = b + XIZ_SUPERBLOCK;
    size_t klen = rd32(b + 32);  /* keys_length (§3) */
    CHECK(klen > 10 && XIZ_SUPERBLOCK + klen <= n && memcmp(blk, "XKEY", 4) == 0);
    if (!(klen > 10 && XIZ_SUPERBLOCK + klen <= n)) { free(b); return; }
    size_t at = 6, body = 0;
    for (uint16_t i = 0, count = rd16(blk + 4); i < count && at + 3 <= klen - 4; i++) {
        if (blk[at] == 6) { body = at + 3; break; }
        at += 3 + rd16(blk + at + 1);
    }
    CHECK(body != 0);
    int opened = 0;
    for (size_t i = 0; body && i < 1128; i += i < 1080 ? 97 : 1) {  /* ML-KEM part sampled, X25519 part and id every byte */
        blk[body + i] ^= 0x01;
        uint32_t crc = xiz_crc32c(0, blk, klen - 4);
        uint8_t old[4];
        memcpy(old, blk + klen - 4, 4);
        blk[klen - 4] = (uint8_t)crc; blk[klen - 3] = (uint8_t)(crc >> 8);
        blk[klen - 2] = (uint8_t)(crc >> 16); blk[klen - 1] = (uint8_t)(crc >> 24);
        if (open_pq(b, n, seed) == XIZ_OK) opened++;
        memcpy(blk + klen - 4, old, 4);
        blk[body + i] ^= 0x01;
    }
    CHECK(opened == 0);
    CHECK(open_pq(b, n, seed) == XIZ_OK);
    free(b);
}

/* Body offset (inside the keys block) of the first stanza of `type`, 0 if none. */
static size_t find_stanza(const uint8_t *blk, size_t klen, uint8_t type) {
    size_t at = 6;
    for (uint16_t i = 0, count = rd16(blk + 4); i < count && at + 3 <= klen - 4; i++) {
        if (blk[at] == type) return at + 3;
        at += 3 + rd16(blk + at + 1);
    }
    return 0;
}

static void fix_keys_crc(uint8_t *blk, size_t klen) {
    uint32_t crc = xiz_crc32c(0, blk, klen - 4);
    blk[klen - 4] = (uint8_t)crc; blk[klen - 3] = (uint8_t)(crc >> 8);
    blk[klen - 2] = (uint8_t)(crc >> 16); blk[klen - 1] = (uint8_t)(crc >> 24);
}

static int open_creds(const uint8_t *b, size_t n, const char *pw, const uint8_t *factor, xiz_error *e) {
    xiz_open_options o;
    memset(&o, 0, sizeof o);
    o.password = pw;
    o.factors = (const uint8_t(*)[32])factor;
    o.factor_count = factor ? 1 : 0;
    xiz_source s;
    xiz_source_memory(&s, b, n);
    xiz_archive *a = NULL;
    int rc = xiz_open(&a, &s, &o, e);
    if (a) xiz_close(a);
    return rc;
}

/* XIZ 1.14 (§24): the key commitment (type 9) on a password archive (file key, group 0) and on a
 * directory archive whose recipient is a password with a factor (type 8). The CRC is fixed after each
 * change, so only the commitment rule can refuse. */
static void test_commitment(const char *dir) {
    static const char *pw = "correct horse battery staple";
    char path[1024];
    uint8_t factor[32];
    snprintf(path, sizeof path, "%s/factor.xizfactor", dir);
    CHECK(key_from_file(path, "XIZ-FACTOR-1-", factor));
    for (int which = 0; which < 2; which++) {
        snprintf(path, sizeof path, "%s/%s", dir, which ? "factor.xiz" : "password-114.xiz");
        const uint8_t *f = which ? factor : NULL;
        size_t n;
        uint8_t *b = slurp(path, &n);
        CHECK(b != NULL);
        if (!b) continue;
        xiz_error e;
        uint8_t *blk = b + XIZ_SUPERBLOCK;
        size_t klen = rd32(b + 32);
        CHECK(rd16(b + 10) >= 14);
        CHECK(klen > 10 && XIZ_SUPERBLOCK + klen <= n);
        size_t c = klen > 10 && XIZ_SUPERBLOCK + klen <= n ? find_stanza(blk, klen, 9) : 0;
        CHECK(c != 0 && rd16(blk + c - 2) == 36 && rd16(blk + c) == 1 && rd16(blk + c + 2) == 0);
        if (!c) { free(b); continue; }
        CHECK(open_creds(b, n, pw, f, &e) == XIZ_OK);
        /* One byte of the commitment: refused. */
        blk[c + 4 + 17] ^= 0x40;
        fix_keys_crc(blk, klen);
        CHECK(open_creds(b, n, pw, f, &e) == XIZ_E_CORRUPT && strstr(e.message, "commitment"));
        blk[c + 4 + 17] ^= 0x40;
        /* The entry moved to another group: the key has no entry, refused. */
        blk[c + 2] = 1;
        fix_keys_crc(blk, klen);
        CHECK(open_creds(b, n, pw, f, &e) == XIZ_E_CORRUPT);
        blk[c + 2] = 0;
        /* A count that does not match the length. */
        blk[c] = 2;
        fix_keys_crc(blk, klen);
        CHECK(open_creds(b, n, pw, f, &e) == XIZ_E_CORRUPT);
        blk[c] = 1;
        /* The stanza removed (retyped to an unknown type, so the layout stays): a 1.14 archive without
         * commitment is refused; lowering version_minor too breaks the stanza's associated data. */
        blk[c - 3] = 0xEE;
        fix_keys_crc(blk, klen);
        CHECK(open_creds(b, n, pw, f, &e) == XIZ_E_CORRUPT && strstr(e.message, "without key commitment"));
        uint8_t minor = b[10];
        b[10] = 13;
        CHECK(open_creds(b, n, pw, f, &e) != XIZ_OK);
        b[10] = minor;
        blk[c - 3] = 9;
        fix_keys_crc(blk, klen);
        CHECK(open_creds(b, n, pw, f, &e) == XIZ_OK);
        if (which) {
            /* Type 8 without its factor, or with another one: reported as such, not as a wrong password. */
            CHECK(open_creds(b, n, pw, NULL, &e) == XIZ_E_FACTOR_REQUIRED);
            uint8_t other[32];
            memcpy(other, factor, 32);
            other[0] ^= 1;
            CHECK(open_creds(b, n, pw, other, &e) == XIZ_E_FACTOR_REQUIRED);
            CHECK(open_creds(b, n, "not the password", factor, &e) == XIZ_E_WRONG_PASSWORD);
            /* A factor whose id matches but whose bytes differ cannot be forged; a damaged factor id
             * in the stanza makes the factor missing. */
            size_t t8 = find_stanza(blk, klen, 8);
            CHECK(t8 != 0);
            if (t8) {
                blk[t8 + 44] ^= 1;
                fix_keys_crc(blk, klen);
                CHECK(open_creds(b, n, pw, factor, &e) == XIZ_E_FACTOR_REQUIRED);
                blk[t8 + 44] ^= 1;
                fix_keys_crc(blk, klen);
            }
        }
        free(b);
    }
    /* Older archives (minor < 14, no commitment) open as before. */
    snprintf(path, sizeof path, "%s/password.xiz", dir);
    size_t n;
    uint8_t *b = slurp(path, &n);
    CHECK(b != NULL && rd16(b + 10) < 14);
    xiz_error e;
    if (b) CHECK(open_creds(b, n, pw, NULL, &e) == XIZ_OK);
    free(b);
}

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: xiz_security FIXTURES SCRATCH\n"); return 2; }
    test_pq_stanza(argv[1]);
    test_commitment(argv[1]);
    test_structure();
    test_lzma2();
    test_jpeg(argv[1]);
    test_preflate(argv[1]);
    test_extraction(argv[2]);
    test_callbacks(argv[2]);
    test_writer(argv[2]);
    test_writer13(argv[2]);
    test_fixture_flips(argv[1]);
    test_erased_slot(argv[1]);
    if (failures) { fprintf(stderr, "security: %d of %d checks failed\n", failures, checks); return 1; }
    printf("security: %d checks passed\n", checks);
    return 0;
}
