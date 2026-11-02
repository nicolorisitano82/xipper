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
    /* Unknown required feature bits (bit 2 is reserved, 6–15 unknown). */
    k.required = 0x0040;
    b = forge(basic, 3, &k);
    CHECK(open_mem(&b, &a, &e) == XIZ_E_UNSUPPORTED);
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

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: xiz_security FIXTURES SCRATCH\n"); return 2; }
    test_structure();
    test_lzma2();
    test_extraction(argv[2]);
    test_fixture_flips(argv[1]);
    test_erased_slot(argv[1]);
    if (failures) { fprintf(stderr, "security: %d of %d checks failed\n", failures, checks); return 1; }
    printf("security: %d checks passed\n", checks);
    return 0;
}
