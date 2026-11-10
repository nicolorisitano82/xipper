/* XIZ 1.10 forensic profile (§20): forensic blocks, frame hashes, custody segments, images
 * against the source hashes. Written from the specification; the reference is XizForensic.swift. */
#include "internal.h"

#include <stdio.h>

#define REC_FRAME_HASHES 0x8001u
#define REC_CASE 0x0002u
#define REC_SOURCE_HASHES 0x8004u
#define REC_UNREADABLE 0x8005u

typedef struct {
    uint64_t footer_offset;
    footer ft;
    directory d;
} seg_t;

static int known_critical(uint16_t t) { return t == REC_FRAME_HASHES || t == REC_SOURCE_HASHES || t == REC_UNREADABLE; }

/* Every segment, oldest first: footer and directory (version 3). */
static int load_segments(xiz_archive *a, seg_t **out, uint32_t *count, xiz_error *err) {
    if (!(a->sb.required & XIZ_FEATURE_FORENSIC)) return FAIL(XIZ_E_UNSUPPORTED, "not a forensic archive (XIZ 1.10, §20)");
    size_t cap = 4, n = 0;
    seg_t *s = malloc(cap * sizeof *s);
    if (!s) return FAIL(XIZ_E_NOMEM, "out of memory");
    uint64_t at = a->footer_offset;
    footer f = a->ft;
    int rc = XIZ_OK;
    for (;;) {
        if (n == cap) {
            seg_t *ns = realloc(s, (cap *= 2) * sizeof *s);
            if (!ns) { rc = FAIL(XIZ_E_NOMEM, "out of memory"); break; }
            s = ns;
        }
        uint8_t *buf = NULL, h[32];
        if (f.cat_csize < 16 || f.cat_csize > XIZ_MAX_CATALOG) { rc = FAIL(XIZ_E_CORRUPT, "directory location"); break; }
        if ((rc = read_alloc(a, f.cat_offset, f.cat_csize, &buf, err))) break;
        sha256(buf, (size_t)f.cat_csize, h);
        if (!ct_equal(h, f.cat_sha, 32)) { free(buf); rc = FAIL(XIZ_E_CORRUPT, "directory SHA-256 mismatch"); break; }
        s[n].footer_offset = at;
        s[n].ft = f;
        rc = directory_parse(buf, (size_t)f.cat_csize, &s[n].d, &a->ar, err);
        free(buf);
        if (rc) break;
        if (s[n].d.version != 3) { rc = FAIL(XIZ_E_CORRUPT, "forensic segment with directory version %u", s[n].d.version); break; }
        n++;
        if (f.previous == 0) break;
        if (n >= 65536 || f.previous >= s[n - 1].d.forensic_offset) { rc = FAIL(XIZ_E_CORRUPT, "segment chain"); break; }
        at = f.previous;
        if (!footer_at(a, at, &f)) { rc = FAIL(XIZ_E_CORRUPT, "segment chain broken at footer %llu", (unsigned long long)at); break; }
    }
    if (rc) { free(s); return rc; }
    for (size_t i = 0; i < n / 2; i++) { seg_t t = s[i]; s[i] = s[n - 1 - i]; s[n - 1 - i] = t; }
    *out = s;
    *count = (uint32_t)n;
    return XIZ_OK;
}

/* Parses segment `index`'s forensic block into records (values in the archive's arena). */
static int load_block(xiz_archive *a, const seg_t *s, uint32_t index, xiz_forensic_record **recs, size_t *n, size_t *cap,
                      xiz_error *err) {
    const directory *d = &s->d;
    if (d->forensic_length < 18 || d->forensic_length > XIZ_MAX_FORENSIC_BLOCK ||
        d->forensic_offset + d->forensic_length != s->ft.cat_offset)
        return FAIL(XIZ_E_CORRUPT, "segment %u: forensic block out of place", index);
    uint8_t *b = NULL, h[32];
    int rc = read_alloc(a, d->forensic_offset, d->forensic_length, &b, err);
    if (rc) return rc;
    size_t len = d->forensic_length;
    sha256(b, len, h);
    if (!ct_equal(h, d->forensic_sha, 32)) { free(b); return FAIL(XIZ_E_CORRUPT, "segment %u: forensic block altered", index); }
    if (memcmp(b, "XFOR", 4) != 0 || rd32(b + len - 4) != xiz_crc32c(0, b, len - 4)) {
        free(b);
        return FAIL(XIZ_E_CORRUPT, "segment %u: forensic block checksum", index);
    }
    rbuf r;
    rb_init(&r, b, len - 4);
    r.at = 4;
    uint16_t version = rb_u16(&r);
    uint32_t segment = rb_u32(&r), count = rb_u32(&r);
    if (r.bad || version != 1) { free(b); return FAIL(XIZ_E_UNSUPPORTED, "segment %u: forensic block version %u", index, version); }
    if (segment != index) { free(b); return FAIL(XIZ_E_CORRUPT, "forensic block of segment %u names segment %u", index, segment); }
    if (count > rb_left(&r) / 6) { free(b); return FAIL(XIZ_E_CORRUPT, "segment %u: forensic record count", index); }
    for (uint32_t i = 0; i < count; i++) {
        uint16_t type = rb_u16(&r);
        uint32_t vlen = rb_u32(&r);
        const uint8_t *v = rb_take(&r, vlen);
        if (r.bad || !v) { rc = FAIL(XIZ_E_CORRUPT, "segment %u: forensic record %u truncated", index, i); break; }
        if ((type & 0x8000u) && !known_critical(type)) {
            rc = FAIL(XIZ_E_UNSUPPORTED, "segment %u: forensic record 0x%04x (made by a newer writer)", index, type);
            break;
        }
        if (*n == *cap) {
            size_t nc = *cap ? *cap * 2 : 16;
            xiz_forensic_record *nr = realloc(*recs, nc * sizeof **recs);
            if (!nr) { rc = FAIL(XIZ_E_NOMEM, "out of memory"); break; }
            *recs = nr;
            *cap = nc;
        }
        xiz_forensic_record *x = &(*recs)[(*n)++];
        x->segment = index;
        x->type = type;
        x->length = vlen;
        x->value = arena_dup(&a->ar, v, vlen, 1);
        if (!x->value) { rc = FAIL(XIZ_E_NOMEM, "out of memory"); break; }
    }
    if (rc == XIZ_OK && rb_left(&r) != 0) rc = FAIL(XIZ_E_CORRUPT, "segment %u: forensic block trailing data", index);
    free(b);
    return rc;
}

static int load_all(xiz_archive *a, seg_t **segs, uint32_t *nseg, xiz_forensic_record **recs, size_t *nrec, xiz_error *err) {
    *recs = NULL;
    *nrec = 0;
    size_t cap = 0;
    int rc = load_segments(a, segs, nseg, err);
    if (rc) return rc;
    for (uint32_t i = 0; i < *nseg && rc == XIZ_OK; i++) rc = load_block(a, &(*segs)[i], i, recs, nrec, &cap, err);
    if (rc) { free(*segs); free(*recs); *segs = NULL; *recs = NULL; }
    return rc;
}

int xiz_forensic_records(xiz_archive *a, xiz_forensic_record **records, size_t *count, xiz_error *err) {
    seg_t *segs = NULL;
    uint32_t n = 0;
    int rc = load_all(a, &segs, &n, records, count, err);
    free(segs);
    return rc;
}

/* ------------------------------------------------------------------ verification (§20.4) */

#if defined(__GNUC__) || defined(__clang__)
__attribute__((format(printf, 6, 7)))
#endif
static void problem_at(xiz_problem_fn fn, void *ctx, long frame, long entry, int code, const char *fmt, ...) {
    if (!fn) return;
    char msg[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);
    fn(ctx, frame, entry, code, msg);
}

static int same_groups(const directory *x, const directory *y) {
    if (x->n_groups != y->n_groups) return 0;
    for (uint16_t i = 0; i < x->n_groups; i++) {
        const dir_group *g = &x->groups[i], *h = &y->groups[i];
        if (g->group != h->group || g->segment != h->segment || g->offset != h->offset || g->csize != h->csize ||
            g->usize != h->usize || memcmp(g->sha, h->sha, 32) != 0)
            return 0;
    }
    return 1;
}

typedef struct {
    sha256_ctx sha;
    uint64_t pos;
    const uint8_t *ranges;   /* unreadable ranges: n × 24 bytes */
    uint32_t n_ranges, next;
    int nonzero;
} image_ctx;

static int image_sink(void *vctx, const void *data, size_t len) {
    image_ctx *c = vctx;
    sha256_update(&c->sha, data, len);
    uint64_t end = c->pos + len;
    while (c->next < c->n_ranges) {
        uint64_t off = rd64(c->ranges + 24 * c->next), rl = rd64(c->ranges + 24 * c->next + 8);
        if (off >= end) break;
        uint64_t lo = off > c->pos ? off : c->pos, hi = off + rl < end ? off + rl : end;
        for (uint64_t p = lo; p < hi; p++)
            if (((const uint8_t *)data)[p - c->pos]) { c->nonzero = 1; break; }
        if (off + rl <= end) c->next++;
        else break;
    }
    c->pos = end;
    return 0;
}

/* The latest record of `type` naming `path` (path_length u16 + path at the start of the value). */
static const xiz_forensic_record *record_for(const xiz_forensic_record *recs, size_t n, uint16_t type, const char *path,
                                             size_t path_len) {
    const xiz_forensic_record *found = NULL;
    for (size_t i = 0; i < n; i++) {
        const xiz_forensic_record *r = &recs[i];
        if (r->type != type || r->length < 2) continue;
        size_t pl = rd16(r->value);
        if (pl == path_len && 2 + pl <= r->length && memcmp(r->value + 2, path, pl) == 0) found = r;
    }
    return found;
}

int xiz_forensic_verify(xiz_archive *a, xiz_problem_fn problem, void *ctx, xiz_forensic_report *rep, xiz_error *err) {
    memset(rep, 0, sizeof *rep);
    seg_t *segs = NULL;
    uint32_t nseg = 0;
    xiz_forensic_record *recs = NULL;
    size_t nrec = 0;
    int rc = load_all(a, &segs, &nseg, &recs, &nrec, err);
    if (rc) return rc;
    rep->segments = nseg;
    int profile_ok = 1;

    /* 1. Segments: custody segments repeat their predecessor; one frame hash record per normal segment. */
    int has_case = 0;
    for (uint32_t i = 0; i < nseg; i++) {
        const seg_t *s = &segs[i];
        uint32_t hashes = 0;
        for (size_t k = 0; k < nrec; k++) {
            if (recs[k].segment != i) continue;
            if (recs[k].type == REC_FRAME_HASHES) hashes++;
            if (recs[k].type == REC_CASE && i == 0) has_case = 1;
        }
        if (s->d.flags & XIZ_DIR_ERASABLE) { profile_ok = 0; problem_at(problem, ctx, -1, -1, XIZ_E_CORRUPT, "segment %u: erasable", i); }
        if (s->d.flags & XIZ_DIR_CUSTODY) {
            rep->custody_segments++;
            const seg_t *p = i ? &segs[i - 1] : NULL;
            if (!p || !same_groups(&p->d, &s->d) || p->d.leaf_offset != s->d.leaf_offset || p->d.leaf_count != s->d.leaf_count ||
                memcmp(p->d.root, s->d.root, 32) != 0 || p->ft.frame_count != s->ft.frame_count ||
                p->ft.entry_count != s->ft.entry_count || p->ft.total_bytes != s->ft.total_bytes ||
                s->d.forensic_offset != p->footer_offset + XIZ_FOOTER || hashes != 0) {
                profile_ok = 0;
                problem_at(problem, ctx, -1, -1, XIZ_E_CORRUPT, "segment %u: custody segment differs from its predecessor", i);
            }
        } else if (hashes != 1) {
            profile_ok = 0;
            problem_at(problem, ctx, -1, -1, XIZ_E_CORRUPT, "segment %u: %u frame hash records", i, hashes);
        }
    }
    if (!has_case) { profile_ok = 0; problem_at(problem, ctx, -1, -1, XIZ_E_CORRUPT, "no case record in segment 0"); }

    /* 2. Frame hashes: every frame covered once, roots, then every frame as written. */
    uint32_t nf = segs[nseg - 1].ft.frame_count;
    uint8_t (*table)[32] = nf ? calloc(nf, 32) : NULL;
    uint8_t *have = nf ? calloc(nf, 1) : NULL;
    if (nf && (!table || !have)) { free(table); free(have); free(segs); free(recs); return FAIL(XIZ_E_NOMEM, "out of memory"); }
    for (size_t k = 0; k < nrec; k++) {
        const xiz_forensic_record *r = &recs[k];
        if (r->type != REC_FRAME_HASHES) continue;
        uint32_t first = r->length >= 8 ? rd32(r->value) : 0, cnt = r->length >= 8 ? rd32(r->value + 4) : 0;
        if (r->length < 40 || (r->length - 40) / 32 != cnt || (r->length - 40) % 32) {
            profile_ok = 0;
            problem_at(problem, ctx, -1, -1, XIZ_E_CORRUPT, "segment %u: frame hash record length", r->segment);
            continue;
        }
        uint8_t (*leaves)[32] = cnt ? malloc((size_t)cnt * 32) : NULL, root[32];
        if (cnt && !leaves) { rc = FAIL(XIZ_E_NOMEM, "out of memory"); break; }
        for (uint32_t j = 0; j < cnt; j++) {
            uint8_t data[36];
            wr32(data, first + j);
            memcpy(data + 4, r->value + 8 + 32 * (size_t)j, 32);
            merkle_leaf(data, sizeof data, leaves[j]);
            uint64_t idx = (uint64_t)first + j;
            if (idx >= nf || have[idx]) {
                profile_ok = 0;
                problem_at(problem, ctx, (long)idx, -1, XIZ_E_CORRUPT, "frame %llu hashed twice or out of range", (unsigned long long)idx);
                continue;
            }
            have[idx] = 1;
            memcpy(table[idx], r->value + 8 + 32 * (size_t)j, 32);
        }
        merkle_root((const uint8_t (*)[32])leaves, cnt, root);
        free(leaves);
        if (memcmp(root, r->value + 8 + 32 * (size_t)cnt, 32) != 0) {
            profile_ok = 0;
            problem_at(problem, ctx, -1, -1, XIZ_E_CORRUPT, "segment %u: frame hash Merkle root", r->segment);
        }
    }
    for (uint32_t i = 0; rc == XIZ_OK && i < nf; i++)
        if (!have[i]) { rep->frames_unhashed++; problem_at(problem, ctx, (long)i, -1, XIZ_E_CORRUPT, "frame %u has no hash", i); }
    /* Walk the frames from the data start, skipping the regions of earlier segments. */
    uint64_t at = a->data_start;
    for (uint32_t i = 0; rc == XIZ_OK && i < nf; i++) {
        for (int moved = 1; moved;) {
            moved = 0;
            for (uint32_t k = 0; k + 1 < nseg; k++) {
                const seg_t *s = &segs[k];
                uint64_t start = s->d.forensic_offset;
                if (!(s->d.flags & XIZ_DIR_CUSTODY))
                    for (uint16_t g = 0; g < s->d.n_groups; g++)
                        if (s->d.groups[g].offset < start) start = s->d.groups[g].offset;
                if (start == at) { at = s->footer_offset + XIZ_FOOTER; moved = 1; }
            }
        }
        uint8_t hdr[XIZ_FRAME_HEADER];
        if ((rc = src_read(a, at, hdr, sizeof hdr, err))) break;
        uint32_t csize = rd32(hdr + 12);
        if (memcmp(hdr, "XFR1", 4) != 0 || rd32(hdr + 8) != i || csize > XIZ_MAX_FRAME_DATA + XIZ_FRAME_SLACK) {
            rc = FAIL(XIZ_E_CORRUPT, "frame %u: no frame header at %llu", i, (unsigned long long)at);
            break;
        }
        uint8_t *payload = NULL, h[32];
        if ((rc = read_alloc(a, at + XIZ_FRAME_HEADER, csize, &payload, err))) break;
        sha256_ctx c;
        sha256_init(&c);
        sha256_update(&c, hdr, sizeof hdr);
        sha256_update(&c, payload, csize);
        sha256_final(&c, h);
        free(payload);
        rep->frames_checked++;
        if (have[i] && !ct_equal(h, table[i], 32)) {
            rep->frames_altered++;
            problem_at(problem, ctx, (long)i, -1, XIZ_E_CORRUPT, "frame %u does not match its signed SHA-256", i);
        }
        at += XIZ_FRAME_HEADER + (uint64_t)csize;
    }
    free(table);
    free(have);

    /* 3. Images: layout (§20.3) and content against the source hashes (needs the keys). */
    for (size_t ei = 0; rc == XIZ_OK && ei < a->cat.n_entries; ei++) {
        const entry_rec *e = &a->cat.entries[ei];
        if (!e->has_image) continue;
        rep->images++;
        if (a->structure_only) continue;
        int bad = 0;
        uint64_t bs = e->image_block;
        if (bs != 4194304u) { bad = 1; problem_at(problem, ctx, -1, (long)ei, XIZ_E_CORRUPT, "%s: block size %llu", e->path, (unsigned long long)bs); }
        else {
            uint64_t blocks = (e->size + bs - 1) / bs;
            long zero_frame = -1;
            if (e->n_ext != blocks) { bad = 1; problem_at(problem, ctx, -1, (long)ei, XIZ_E_CORRUPT, "%s: %u extents for %llu blocks", e->path, e->n_ext, (unsigned long long)blocks); }
            for (uint32_t x = 0; !bad && x < e->n_ext; x++) {
                const extent_rec *xr = &e->ext[x];
                uint64_t want = e->size - (uint64_t)x * bs < bs ? e->size - (uint64_t)x * bs : bs;
                if (xr->offset != 0 || xr->length != want) { bad = 1; problem_at(problem, ctx, -1, (long)ei, XIZ_E_CORRUPT, "%s: block %u extent", e->path, x); break; }
                uint32_t uses = 0;
                for (size_t ej = 0; ej < a->cat.n_entries; ej++)
                    for (uint32_t y = 0; y < a->cat.entries[ej].n_ext; y++) uses += a->cat.entries[ej].ext[y].frame == xr->frame;
                if (uses == 1 || (long)xr->frame == zero_frame) continue;
                const uint8_t *data;
                size_t len;
                int is_zero = zero_frame < 0 && xr->frame < a->cat.n_frames && a->cat.frames[xr->frame].usize == bs &&
                              frame_get(a, xr->frame, &data, &len, err) == XIZ_OK;
                for (size_t p = 0; is_zero && p < len; p++) is_zero = data[p] == 0;
                if (is_zero) zero_frame = (long)xr->frame;
                else { bad = 1; problem_at(problem, ctx, (long)xr->frame, (long)ei, XIZ_E_CORRUPT, "%s: block %u shares a frame that is not the zero frame", e->path, x); }
            }
        }
        const xiz_forensic_record *src = record_for(recs, nrec, REC_SOURCE_HASHES, e->path, e->path_len);
        const xiz_forensic_record *unr = record_for(recs, nrec, REC_UNREADABLE, e->path, e->path_len);
        image_ctx ic;
        memset(&ic, 0, sizeof ic);
        sha256_init(&ic.sha);
        if (unr) {
            size_t pl = rd16(unr->value);
            if (unr->length >= 6 + pl) {
                ic.n_ranges = rd32(unr->value + 2 + pl);
                if ((uint64_t)unr->length != 6 + pl + (uint64_t)ic.n_ranges * 24) {
                    bad = 1;
                    ic.n_ranges = 0;
                    problem_at(problem, ctx, -1, (long)ei, XIZ_E_CORRUPT, "%s: unreadable sectors record", e->path);
                }
                ic.ranges = unr->value + 6 + pl;
                for (uint32_t k = 0; k < ic.n_ranges; k++) {
                    uint64_t off = rd64(ic.ranges + 24 * k), rl = rd64(ic.ranges + 24 * k + 8);
                    uint64_t prev_end = k ? rd64(ic.ranges + 24 * (k - 1)) + rd64(ic.ranges + 24 * (k - 1) + 8) : 0;
                    if (rl == 0 || off + rl > e->size || off < prev_end) {
                        bad = 1;
                        problem_at(problem, ctx, -1, (long)ei, XIZ_E_CORRUPT, "%s: unreadable range %u", e->path, k);
                    }
                }
            }
        }
        xiz_error rerr;
        if (xiz_read_entry(a, ei, image_sink, &ic, &rerr) != XIZ_OK) {
            bad = 1;
            problem_at(problem, ctx, -1, (long)ei, rerr.code, "%s: %s", e->path, rerr.message);
        } else {
            uint8_t got[32];
            sha256_final(&ic.sha, got);
            size_t pl = src ? rd16(src->value) : 0;
            if (!src || src->length != 2 + pl + 8 + 1 + 16 + 20 + 32 + 16) {
                bad = 1;
                problem_at(problem, ctx, -1, (long)ei, XIZ_E_CORRUPT, "%s: no source hashes record", e->path);
            } else {
                const uint8_t *v = src->value + 2 + pl;
                if (rd64(v) != e->size) { bad = 1; problem_at(problem, ctx, -1, (long)ei, XIZ_E_CORRUPT, "%s: source size differs", e->path); }
                if (!(v[8] & 4) || !ct_equal(got, v + 9 + 16 + 20, 32)) {
                    bad = 1;
                    problem_at(problem, ctx, -1, (long)ei, XIZ_E_CORRUPT, "%s: SHA-256 differs from the source's", e->path);
                }
                memcpy(rep->last_image_sha256, got, 32);
            }
            if (ic.nonzero) { bad = 1; problem_at(problem, ctx, -1, (long)ei, XIZ_E_CORRUPT, "%s: unreadable ranges hold data", e->path); }
        }
        rep->images_checked++;
        if (bad) rep->images_failed++;
    }
    rep->profile_ok = profile_ok;
    free(segs);
    free(recs);
    return rc;
}
