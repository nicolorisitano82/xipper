/* Frames and content (§4, §8 step 7): header check, CRC-32C, AES-GCM, exact-size decoding,
 * digests. */
#include "internal.h"

int entry_keys(const xiz_archive *a, const entry_rec *e, keyset *out) {
    if (!a->encrypted) return 0;
    if (e->has_secret) { keyset_derive(out, e->secret, a->sb.id); return 1; }
    if (!a->has_dir) { *out = a->keys; return 1; }
    for (size_t i = 0; i < a->n_groups; i++)
        if (a->groups[i].id == e->group && a->groups[i].held) { *out = a->groups[i].keys; return 1; }
    return -1;
}

/* Data key of frame i: 1 found, 0 not encrypted, -1 not held. */
static int frame_data_key(const xiz_archive *a, uint32_t i, uint8_t key[32]) {
    if (!a->encrypted) return 0;
    const frame_rec *f = &a->cat.frames[i];
    if (!a->has_dir) { memcpy(key, a->keys.data, 32); return 1; }
    if (f->flags & XIZ_FLAG_ENTRY_KEY) {
        if (!a->frame_entry || a->frame_entry[i] < 0) return -1;
        keyset k;
        keyset_derive(&k, a->cat.entries[a->frame_entry[i]].secret, a->sb.id);
        memcpy(key, k.data, 32);
        secure_zero(&k, sizeof k);
        return 1;
    }
    for (size_t g = 0; g < a->n_groups; g++)
        if (a->groups[g].id == f->group) {
            if (!a->groups[g].held) return -1;
            memcpy(key, a->groups[g].keys.data, 32);
            return 1;
        }
    return -1;
}

int frame_can_open(const xiz_archive *a, uint32_t i) {
    uint8_t k[32];
    int r = frame_data_key(a, i, k);
    secure_zero(k, 32);
    return r >= 0;
}

static int ensure_ddict(xiz_archive *a, uint16_t id, const void **out, xiz_error *err);

static int decode_frame(xiz_archive *a, uint32_t i, uint8_t *dst, const void *ddict, xiz_error *err) {
    const frame_rec *f = &a->cat.frames[i];
    uint8_t hdr[XIZ_FRAME_HEADER], want[XIZ_FRAME_HEADER];
    TRY(src_read(a, f->offset, hdr, sizeof hdr, err));
    frame_header_encode(i, f, want);
    if (memcmp(hdr, want, sizeof hdr) != 0) return FAIL(XIZ_E_CORRUPT, "frame %u header does not match the catalog", i);
    if (a->scratch_cap < f->csize) {
        uint8_t *s = realloc(a->scratch, f->csize);
        if (!s) return FAIL(XIZ_E_NOMEM, "out of memory");
        a->scratch = s;
        a->scratch_cap = f->csize;
    }
    uint8_t *p = a->scratch;
    TRY(src_read(a, f->offset + XIZ_FRAME_HEADER, p, f->csize, err));
    uint32_t crc = xiz_crc32c(0, p, f->csize);
    if (crc != f->crc) return FAIL(XIZ_E_CHECKSUM, "frame %u CRC-32C %08x, expected %08x", i, crc, f->crc);
    size_t n = f->csize;
    uint8_t key[32];
    int kr = frame_data_key(a, i, key);
    if (kr < 0) return FAIL(XIZ_E_LOCKED, "frame %u belongs to a group this reader cannot open", i);
    if (kr > 0) {
        uint8_t nonce[12], aad[37];
        frame_nonce(i, nonce);
        frame_aad(a->sb.id, i, f, aad);
        n -= XIZ_TAG;
        int ok = aes_gcm_open(key, nonce, aad, sizeof aad, p, n, p + n);
        secure_zero(key, 32);
        if (!ok) return FAIL(XIZ_E_AUTH, "frame %u does not authenticate (data altered)", i);
    }
    switch (f->codec) {
    case CODEC_STORE:
        if (n != f->usize) return FAIL(XIZ_E_CORRUPT, "stored frame %u size", i);
        memcpy(dst, p, n);
        return XIZ_OK;
    case CODEC_ZSTD:
        return zstd_decode_frame(p, n, dst, f->usize, ddict, err);
    case CODEC_LZMA2:
    case CODEC_LZMA2_ARM64:
        return lzma2_decode_frame(p, n, dst, f->usize, f->codec == CODEC_LZMA2_ARM64, err);
    case CODEC_JPEG:
        return jpeg_decode_frame(p, n, dst, f->usize, err);
    case CODEC_PREFLATE:
        return preflate_decode_frame(p, n, dst, f->usize, err);
    case CODEC_OPENZL:
        return openzl_decode_frame(p, n, dst, f->usize, err);
    case CODEC_LZRAVEN:
    case CODEC_LZMESH:
        return apple_decode_frame(p, n, dst, f->usize, f->codec, err);
    default:
        return FAIL(XIZ_E_UNSUPPORTED, "frame %u codec %u", i, f->codec);
    }
}

int frame_get(xiz_archive *a, uint32_t i, const uint8_t **data, size_t *len, xiz_error *err) {
    if (i >= a->cat.n_frames) return FAIL(XIZ_E_ARG, "frame %u does not exist", i);
    a->stamp++;
    for (int k = 0; k < XIZ_CACHE_SLOTS; k++) {
        if (a->cache[k].index == (long)i) {
            a->cache[k].stamp = a->stamp;
            *data = a->cache[k].data;
            *len = a->cache[k].len;
            return XIZ_OK;
        }
    }
    /* The dictionary first: loading it uses the cache too. */
    const void *ddict = NULL;
    const frame_rec *fr = &a->cat.frames[i];
    if (fr->dict && !(fr->flags & XIZ_FLAG_DICTIONARY)) TRY(ensure_ddict(a, fr->dict, &ddict, err));
    int lru = -1;
    for (int k = 0; k < XIZ_CACHE_SLOTS && lru < 0; k++)
        if (a->cache[k].index < 0) lru = k;
    if (lru < 0) {
        lru = 0;
        for (int k = 1; k < XIZ_CACHE_SLOTS; k++)
            if (a->cache[k].stamp < a->cache[lru].stamp) lru = k;
    }
    cache_slot *s = &a->cache[lru];
    const frame_rec *f = &a->cat.frames[i];
    s->index = -1;
    if (!s->data || s->cap < f->usize || s->cap > 4 * (size_t)f->usize + (1 << 20)) {
        if (s->data) secure_zero(s->data, s->cap);
        free(s->data);
        s->cap = f->usize ? f->usize : 1;
        s->data = malloc(s->cap);
        s->len = 0;
        if (!s->data) { s->cap = 0; return FAIL(XIZ_E_NOMEM, "out of memory"); }
    }
    int rc = decode_frame(a, i, s->data, ddict, err);
    if (rc) return rc;
    s->index = (long)i;
    s->len = f->usize;
    s->stamp = a->stamp;
    *data = s->data;
    *len = f->usize;
    return XIZ_OK;
}

static int ensure_ddict(xiz_archive *a, uint16_t id, const void **out, xiz_error *err) {
    size_t k;
    for (k = 0; k < a->n_dicts && a->dicts[k].id != id; k++) {}
    if (k == a->n_dicts) return FAIL(XIZ_E_CORRUPT, "dictionary %u missing", id);
    if (!a->dicts[k].ddict) {
        const uint8_t *d;
        size_t n;
        TRY(frame_get(a, a->dicts[k].frame, &d, &n, err));
        a->dicts[k].ddict = zstd_ddict_create(d, n, id, err);
        if (!a->dicts[k].ddict) return err ? err->code : XIZ_E_CORRUPT;
    }
    *out = a->dicts[k].ddict;
    return XIZ_OK;
}

/* ------------------------------------------------------------------ content */

typedef struct {
    int keyed;
    sha256_ctx sha;
    hmac_ctx mac;
} digest_ctx;

static void digest_init(digest_ctx *d, const xiz_archive *a, const entry_rec *e) {
    keyset k;
    int r = entry_keys(a, e, &k);
    d->keyed = r > 0;
    if (d->keyed) hmac_init(&d->mac, k.mac);
    else sha256_init(&d->sha);
    secure_zero(&k, sizeof k);
}
static void digest_update(digest_ctx *d, const void *p, size_t n) {
    if (d->keyed) hmac_update(&d->mac, p, n);
    else sha256_update(&d->sha, p, n);
}
static void digest_final(digest_ctx *d, uint8_t out[32]) {
    if (d->keyed) hmac_final(&d->mac, out);
    else sha256_final(&d->sha, out);
}

/* Streams an entry's content to `write`; also feeds a plain SHA-256 when `plain` is given. */
static int stream_entry(xiz_archive *a, size_t index, xiz_write_fn write, void *ctx, sha256_ctx *plain, xiz_error *err) {
    const entry_rec *e = &a->cat.entries[index];
    if (e->type == XIZ_TYPE_SYMLINK) {
        if (plain) sha256_update(plain, e->link, e->link_len);
        if (write && write(ctx, e->link, e->link_len)) return FAIL(XIZ_E_CALLBACK, "stopped");
        return XIZ_OK;
    }
    if (e->type != XIZ_TYPE_FILE) return XIZ_OK;
    keyset k;
    if (entry_keys(a, e, &k) < 0) return FAIL(XIZ_E_LOCKED, "%s: group not held", e->path);
    secure_zero(&k, sizeof k);
    digest_ctx d;
    digest_init(&d, a, e);
    for (uint32_t x = 0; x < e->n_ext; x++) {
        const uint8_t *fd;
        size_t fl;
        int rc = frame_get(a, e->ext[x].frame, &fd, &fl, err);
        if (rc) { digest_final(&d, (uint8_t[32]){0}); return rc; }
        const uint8_t *piece = fd + e->ext[x].offset;
        size_t n = e->ext[x].length;
        digest_update(&d, piece, n);
        if (plain) sha256_update(plain, piece, n);
        if (write && n && write(ctx, piece, n)) { digest_final(&d, (uint8_t[32]){0}); return FAIL(XIZ_E_CALLBACK, "stopped"); }
    }
    uint8_t h[32];
    digest_final(&d, h);
    if (e->has_digest && !ct_equal(h, e->digest, 32))
        return FAIL(XIZ_E_DIGEST, "%s: content %s mismatch", e->path, d.keyed ? "HMAC-SHA-256" : "SHA-256");
    return XIZ_OK;
}

int xiz_read_entry(xiz_archive *a, size_t index, xiz_write_fn write, void *ctx, xiz_error *err) {
    if (!a || index >= a->cat.n_entries) return FAIL(XIZ_E_ARG, "no entry %zu", index);
    return stream_entry(a, index, write, ctx, NULL, err);
}

typedef struct {
    uint8_t *p;
    size_t n, cap;
    uint64_t max;
} membuf;

static int mem_write(void *ctx, const void *d, size_t n) {
    membuf *m = ctx;
    if (m->max && m->n + n > m->max) n = (size_t)(m->max - m->n);
    if (m->n + n > m->cap) {
        size_t cap = m->cap ? m->cap : 4096;
        while (cap < m->n + n) cap *= 2;
        uint8_t *q = realloc(m->p, cap);
        if (!q) return 1;
        m->p = q;
        m->cap = cap;
    }
    memcpy(m->p + m->n, d, n);
    m->n += n;
    return m->max && m->n >= m->max;
}

int xiz_read_entry_alloc(xiz_archive *a, size_t index, uint64_t max, uint8_t **data, size_t *len, xiz_error *err) {
    if (!a || !data || !len || index >= a->cat.n_entries) return FAIL(XIZ_E_ARG, "bad argument");
    const entry_rec *e = &a->cat.entries[index];
    membuf m = {NULL, 0, 0, max};
    if (!max && e->size > SIZE_MAX / 2) return FAIL(XIZ_E_LIMIT, "entry too large for memory");
    if (e->type == XIZ_TYPE_FILE && (!max || e->size < max)) {
        m.cap = (size_t)e->size + 1;
        m.p = malloc(m.cap);
        if (!m.p) return FAIL(XIZ_E_NOMEM, "out of memory");
    }
    int rc = stream_entry(a, index, mem_write, &m, NULL, err);
    if (rc == XIZ_E_CALLBACK && max && m.n >= max) rc = XIZ_OK;  /* truncated on purpose */
    if (rc) { free(m.p); return rc; }
    if (!m.p) m.p = malloc(1);
    *data = m.p;
    *len = m.n;
    return XIZ_OK;
}

/* ------------------------------------------------------------------ test */

int xiz_test(xiz_archive *a, int frames_only, xiz_problem_fn problem, void *ctx, xiz_test_report *rep,
             xiz_error *err) {
    if (!a) return FAIL(XIZ_E_ARG, "no archive");
    xiz_test_report r = {0};
    uint8_t *bad = calloc(a->cat.n_frames + 1, 1);
    if (!bad) return FAIL(XIZ_E_NOMEM, "out of memory");
    xiz_error e;
    for (uint32_t i = 0; i < a->cat.n_frames; i++) {
        if (!frame_can_open(a, i)) { r.frames_skipped++; continue; }
        const uint8_t *d;
        size_t n;
        int rc = frame_get(a, i, &d, &n, &e);
        if (rc == XIZ_E_NOMEM) { free(bad); return FAIL(rc, "%s", e.message); }
        r.frames_checked++;
        if (rc) {
            r.frames_failed++;
            bad[i] = 1;
            if (problem) problem(ctx, (long)i, -1, rc, e.message);
        } else {
            r.bytes_checked += n;
        }
    }
    for (size_t i = 0; i < a->cat.n_entries; i++) {
        const entry_rec *en = &a->cat.entries[i];
        if (en->type != XIZ_TYPE_FILE) continue;
        int damaged = 0;
        for (uint32_t x = 0; x < en->n_ext; x++)
            if (en->ext[x].frame < a->cat.n_frames && bad[en->ext[x].frame]) damaged = 1;
        r.files_checked++;
        if (damaged) {
            r.files_failed++;
            if (problem) problem(ctx, -1, (long)i, XIZ_E_CORRUPT, "content in a damaged frame");
            continue;
        }
        if (frames_only) continue;
        int rc = stream_entry(a, i, NULL, NULL, NULL, &e);
        if (rc == XIZ_E_NOMEM) { free(bad); return FAIL(rc, "%s", e.message); }
        if (rc) {
            r.files_failed++;
            if (problem) problem(ctx, -1, (long)i, rc, e.message);
        }
    }
    free(bad);
    if (rep) *rep = r;
    if (r.frames_failed || r.files_failed)
        return FAIL(XIZ_E_CORRUPT, "%u damaged frames, %llu damaged files", r.frames_failed,
                    (unsigned long long)r.files_failed);
    return XIZ_OK;
}
