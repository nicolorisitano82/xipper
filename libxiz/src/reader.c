/* Opening an archive (§8): superblock, keys, footer chain, catalog or directory and group
 * catalogs, then every structural check before anything is decoded. */
#include "internal.h"

#include <stdio.h>

int src_read(const xiz_archive *a, uint64_t off, void *buf, size_t n, xiz_error *err) {
    if (off > a->src.size || n > a->src.size - off)
        return FAIL(XIZ_E_CORRUPT, "read of %zu bytes at %llu past the end of the archive", n, (unsigned long long)off);
    if (n && a->src.read(a->src.ctx, off, buf, n) != 0)
        return FAIL(XIZ_E_IO, "read of %zu bytes at %llu failed", n, (unsigned long long)off);
    return XIZ_OK;
}

static int read_alloc(const xiz_archive *a, uint64_t off, uint64_t n, uint8_t **out, xiz_error *err) {
    if (n > SIZE_MAX - 1) return FAIL(XIZ_E_LIMIT, "region too large");
    if (off > a->src.size || n > a->src.size - off) return FAIL(XIZ_E_CORRUPT, "region past the end of the archive");
    uint8_t *b = malloc(n ? (size_t)n : 1);
    if (!b) return FAIL(XIZ_E_NOMEM, "out of memory (%llu bytes)", (unsigned long long)n);
    int rc = src_read(a, off, b, (size_t)n, err);
    if (rc) { free(b); return rc; }
    *out = b;
    return XIZ_OK;
}

/* ------------------------------------------------------------------ footer */

static int footer_at(const xiz_archive *a, uint64_t at, footer *f) {
    uint8_t b[XIZ_FOOTER];
    if (src_read(a, at, b, XIZ_FOOTER, NULL) != XIZ_OK) return 0;
    if (footer_parse(b, f, NULL) != XIZ_OK) return 0;
    return f->cat_offset <= at && f->cat_csize == at - f->cat_offset;
}

int find_last_footer(const xiz_archive *a, uint64_t *at, footer *f, xiz_error *err) {
    uint64_t size = a->src.size;
    if (footer_at(a, size - XIZ_FOOTER, f)) { *at = size - XIZ_FOOTER; return XIZ_OK; }
    /* §15: a recovery record ends the file; its trailer gives the end of the archive. */
    uint8_t t[64];
    if (size >= 64 + XIZ_FOOTER && src_read(a, size - 64, t, 64, NULL) == XIZ_OK && memcmp(t, "XIZT", 4) == 0 &&
        memcmp(t + 60, "XZR!", 4) == 0 && rd32(t + 56) == xiz_crc32c(0, t, 56)) {
        uint64_t end = rd64(t + 24);
        if (end >= a->data_start + XIZ_FOOTER && end < size && footer_at(a, end - XIZ_FOOTER, f)) {
            *at = end - XIZ_FOOTER;
            return XIZ_OK;
        }
    }
    /* §11: an interrupted append left bytes after the last complete footer: search backwards
     * for the tail magic of a valid footer whose catalog ends right before it. */
    const size_t window = 1 << 20;
    uint8_t *buf = malloc(window);
    if (!buf) return FAIL(XIZ_E_NOMEM, "out of memory");
    uint64_t end = size;
    uint64_t low = a->data_start + XIZ_FOOTER;
    while (end > low) {
        uint64_t start = end - low > window ? end - window : low;
        size_t n = (size_t)(end - start);
        if (src_read(a, start, buf, n, err)) { free(buf); return XIZ_E_IO; }
        for (size_t i = n; i >= 4; i--) {
            if (memcmp(buf + i - 4, "XIZ!", 4) != 0) continue;
            uint64_t tail_end = start + i;
            if (tail_end < (uint64_t)XIZ_FOOTER + a->data_start) continue;
            uint64_t fa = tail_end - XIZ_FOOTER;
            if (fa + XIZ_FOOTER == size) continue;  /* already tried */
            if (footer_at(a, fa, f)) { free(buf); *at = fa; return XIZ_OK; }
        }
        if (start == low) break;
        end = start + 3;  /* overlap so a magic across the boundary is seen */
    }
    free(buf);
    return FAIL(XIZ_E_CORRUPT, "no valid footer");
}

/* ------------------------------------------------------------------ layout checks */

typedef struct { uint64_t start, end; } gap;

typedef struct {
    gap *g;
    size_t n, cap;
} gaps_t;

static int gap_add(gaps_t *gs, uint64_t start, uint64_t end, xiz_error *err) {
    if (gs->n == gs->cap) {
        size_t cap = gs->cap ? gs->cap * 2 : 8;
        gap *ng = realloc(gs->g, cap * sizeof(gap));
        if (!ng) return FAIL(XIZ_E_NOMEM, "out of memory");
        gs->g = ng;
        gs->cap = cap;
    }
    gs->g[gs->n].start = start;
    gs->g[gs->n].end = end;
    gs->n++;
    return XIZ_OK;
}

/* Gaps are collected newest first, so their starts decrease: the next one is found by scan. */
static uint64_t skip_gaps(const gaps_t *gs, uint64_t at, size_t *used) {
    for (;;) {
        int moved = 0;
        for (size_t i = 0; i < gs->n; i++) {
            if (gs->g[i].start == at) { at = gs->g[i].end; (*used)++; moved = 1; break; }
        }
        if (!moved) return at;
    }
}

static int check_frames(xiz_archive *a, const gaps_t *gs, uint64_t frame_end, int allow_dicts, xiz_error *err) {
    const uint32_t overhead = a->encrypted ? XIZ_TAG : 0;
    uint64_t next = a->data_start;
    size_t used = 0;
    const catalog *c = &a->cat;
    for (uint32_t i = 0; i < c->n_frames; i++) {
        const frame_rec *f = &c->frames[i];
        next = skip_gaps(gs, next, &used);
        if (f->offset != next)
            return FAIL(XIZ_E_CORRUPT, "frame %u at %llu, expected %llu: frames overlap or leave gaps", i,
                        (unsigned long long)f->offset, (unsigned long long)next);
        if (f->usize > XIZ_MAX_FRAME_DATA) return FAIL(XIZ_E_LIMIT, "frame %u declares %u bytes (limit 64 MiB)", i, f->usize);
        if (f->csize > XIZ_MAX_FRAME_DATA + XIZ_FRAME_SLACK)
            return FAIL(XIZ_E_LIMIT, "frame %u payload of %u bytes", i, f->csize);
        if (f->csize < overhead) return FAIL(XIZ_E_CORRUPT, "frame %u shorter than its tag", i);
        if (f->codec == CODEC_STORE && f->csize != f->usize + overhead)
            return FAIL(XIZ_E_CORRUPT, "stored frame %u: payload %u, data %u", i, f->csize, f->usize);
        if (f->codec >= CODEC_LZMA2) {
            if (!(a->sb.required & XIZ_FEATURE_LZMA2)) return FAIL(XIZ_E_CORRUPT, "frame %u uses LZMA2, not declared", i);
            if (f->flags & XIZ_FLAG_DICTIONARY || f->dict) return FAIL(XIZ_E_CORRUPT, "LZMA2 frame %u with a dictionary", i);
        }
        if (f->flags & XIZ_FLAG_ENTRY_KEY && !a->encrypted) return FAIL(XIZ_E_CORRUPT, "entry-key frame %u, not encrypted", i);
        if ((f->flags & XIZ_FLAG_DICTIONARY || f->dict) && !allow_dicts)
            return FAIL(XIZ_E_CORRUPT, "frame %u: dictionary not allowed here", i);
        next = f->offset + XIZ_FRAME_HEADER + f->csize;
        if (next > frame_end) return FAIL(XIZ_E_CORRUPT, "frame %u overlaps the catalog", i);
    }
    next = skip_gaps(gs, next, &used);
    if (next != frame_end) return FAIL(XIZ_E_CORRUPT, "frames end at %llu, catalog at %llu", (unsigned long long)next,
                                       (unsigned long long)frame_end);
    if (used != gs->n) return FAIL(XIZ_E_CORRUPT, "frames overlap an earlier segment's catalog");
    /* §12: each dictionary defined once, before its users. */
    for (uint32_t i = 0; i < c->n_frames; i++) {
        const frame_rec *f = &c->frames[i];
        if (!f->flags && !f->dict) continue;
        if (f->flags & XIZ_FLAG_ENTRY_KEY) {
            if (f->dict) return FAIL(XIZ_E_CORRUPT, "entry-key frame %u with a dictionary", i);
            continue;
        }
        if (!(a->sb.required & XIZ_FEATURE_DICTIONARIES)) return FAIL(XIZ_E_CORRUPT, "frame %u: dictionary not declared", i);
        if (f->dict == 0) return FAIL(XIZ_E_CORRUPT, "frame %u: dictionary flag without ID", i);
        size_t k;
        for (k = 0; k < a->n_dicts && a->dicts[k].id != f->dict; k++) {}
        if (f->flags & XIZ_FLAG_DICTIONARY) {
            if (k < a->n_dicts) return FAIL(XIZ_E_CORRUPT, "dictionary %u defined twice", f->dict);
            if (f->usize > XIZ_MAX_DICTIONARY) return FAIL(XIZ_E_LIMIT, "dictionary %u larger than 1 MiB", f->dict);
            if (f->codec > CODEC_ZSTD) return FAIL(XIZ_E_CORRUPT, "dictionary frame %u codec", i);
            void *nd = realloc(a->dicts, (a->n_dicts + 1) * sizeof *a->dicts);
            if (!nd) return FAIL(XIZ_E_NOMEM, "out of memory");
            a->dicts = nd;
            a->dicts[a->n_dicts].id = f->dict;
            a->dicts[a->n_dicts].frame = i;
            a->dicts[a->n_dicts].ddict = NULL;
            a->n_dicts++;
        } else {
            if (f->codec != CODEC_ZSTD) return FAIL(XIZ_E_CORRUPT, "frame %u: dictionary with codec %u", i, f->codec);
            if (k == a->n_dicts) return FAIL(XIZ_E_CORRUPT, "frame %u uses dictionary %u, not defined before it", i, f->dict);
        }
    }
    return XIZ_OK;
}

static int check_entries(xiz_archive *a, int exact, xiz_error *err) {
    const catalog *c = &a->cat;
    uint64_t total = 0;
    for (size_t i = 0; i < c->n_entries; i++) {
        const entry_rec *e = &c->entries[i];
        uint64_t sum = 0;
        for (uint32_t x = 0; x < e->n_ext; x++) {
            const extent_rec *ex = &e->ext[x];
            if (ex->frame >= c->n_frames) return FAIL(XIZ_E_CORRUPT, "%s: extent in frame %u of %u", e->path, ex->frame, c->n_frames);
            const frame_rec *f = &c->frames[ex->frame];
            if (f->flags & XIZ_FLAG_DICTIONARY) return FAIL(XIZ_E_CORRUPT, "%s: extent inside a dictionary frame", e->path);
            if ((uint64_t)ex->offset + ex->length > f->usize) return FAIL(XIZ_E_CORRUPT, "%s: extent outside its frame", e->path);
            if (a->has_dir) {
                if (f->group != e->group) return FAIL(XIZ_E_CORRUPT, "%s: extent in another group's frame", e->path);
                if (((f->flags & XIZ_FLAG_ENTRY_KEY) != 0) != (e->has_slot != 0))
                    return FAIL(XIZ_E_CORRUPT, "%s: entry key and frame disagree", e->path);
            }
            sum += ex->length;
        }
        if (e->type == XIZ_TYPE_FILE ? sum != e->size : (e->n_ext || e->size))
            return FAIL(XIZ_E_CORRUPT, "%s: size %llu does not match its data", e->path, (unsigned long long)e->size);
        if (total + e->size < total) return FAIL(XIZ_E_CORRUPT, "total size overflows");
        total += e->size;
    }
    if (exact ? total != a->ft.total_bytes : total > a->ft.total_bytes)
        return FAIL(XIZ_E_CORRUPT, "entries add up to %llu bytes, footer declares %llu", (unsigned long long)total,
                    (unsigned long long)a->ft.total_bytes);
    return XIZ_OK;
}

/* ------------------------------------------------------------------ 1.0–1.2, 1.4 */

static int open_catalog(xiz_archive *a, const xiz_open_options *opt, xiz_error *err) {
    const footer *ft = &a->ft;
    gaps_t gs = {0};
    uint32_t segment = 0;
    uint64_t prev = ft->previous, bound = a->footer_offset;
    int rc = XIZ_OK;
    while (prev != 0) {
        footer older;
        if (prev < a->data_start || prev + XIZ_FOOTER > bound || segment >= 65535 || !footer_at(a, prev, &older) ||
            older.cat_offset < a->data_start || older.major != a->sb.major) {
            rc = FAIL(XIZ_E_CORRUPT, "segment chain broken at footer %llu", (unsigned long long)prev);
            goto out;
        }
        if ((rc = gap_add(&gs, older.cat_offset, prev + XIZ_FOOTER, err))) goto out;
        bound = older.cat_offset;
        prev = older.previous;
        segment++;
    }
    a->segments = segment + 1;
    uint64_t max_cat = opt && opt->max_catalog ? opt->max_catalog : XIZ_MAX_CATALOG;
    if (ft->cat_offset < a->data_start || ft->cat_csize == 0 || ft->cat_csize > XIZ_MAX_CATALOG + XIZ_MAX_CATALOG / 4096 * 16 + 16)
        { rc = FAIL(XIZ_E_CORRUPT, "invalid catalog location"); goto out; }
    if (ft->cat_usize > max_cat) {
        rc = FAIL(XIZ_E_LIMIT, "catalog of %llu bytes (limit %llu)", (unsigned long long)ft->cat_usize, (unsigned long long)max_cat);
        goto out;
    }
    uint8_t *packed = NULL, *plain = NULL, *raw = NULL;
    if ((rc = read_alloc(a, ft->cat_offset, ft->cat_csize, &packed, err))) goto out;
    uint8_t h[32];
    sha256(packed, (size_t)ft->cat_csize, h);
    if (!ct_equal(h, ft->cat_sha, 32)) { free(packed); rc = FAIL(XIZ_E_CORRUPT, "catalog SHA-256 mismatch"); goto out; }
    size_t plen = (size_t)ft->cat_csize;
    if (a->encrypted) {
        uint8_t aad[11 + 16 + 36];
        memcpy(aad, "XIZ1catalog", 11);
        memcpy(aad + 11, a->sb.id, 16);
        footer_auth_fields(ft, aad + 27);
        rc = stream_open(a->keys.catalog, aad, sizeof aad, segment, packed, plen, &plain, &plen, err);
        free(packed);
        if (rc) goto out;
        packed = plain;
    }
    rc = zstd_decode_catalog(packed, plen, ft->cat_usize, &raw, err);
    free(packed);
    if (rc) goto out;
    uint32_t max_entries = opt && opt->max_entries ? opt->max_entries : 10000000u;
    rc = catalog_parse(raw, (size_t)ft->cat_usize, &a->cat, &a->ar, a->sb.major == 0, max_entries, err);
    free(raw);
    if (rc) goto out;
    if (a->cat.version == 2) { rc = FAIL(XIZ_E_CORRUPT, "group catalog without directory feature"); goto out; }
    if ((a->cat.version == 0) != (a->sb.major == 0)) { rc = FAIL(XIZ_E_CORRUPT, "catalog version does not match the superblock"); goto out; }
    if (a->cat.n_frames != ft->frame_count || a->cat.n_entries != ft->entry_count) {
        rc = FAIL(XIZ_E_CORRUPT, "catalog lists %u frames and %zu entries, footer %u and %u", a->cat.n_frames,
                  a->cat.n_entries, ft->frame_count, ft->entry_count);
        goto out;
    }
    if ((rc = check_frames(a, &gs, ft->cat_offset, 1, err))) goto out;
    rc = check_entries(a, 1, err);
out:
    free(gs.g);
    return rc;
}

/* ------------------------------------------------------------------ 1.3 directory */

static const keyset *group_keys(const xiz_archive *a, uint16_t group) {
    for (size_t i = 0; i < a->n_groups; i++)
        if (a->groups[i].id == group) return a->groups[i].held ? &a->groups[i].keys : NULL;
    return NULL;
}

static int open_directory(xiz_archive *a, const xiz_open_options *opt, const keys_opened *ko, xiz_error *err) {
    const footer *ft = &a->ft;
    int rc = XIZ_OK;
    gaps_t gs = {0};
    uint8_t *buf = NULL;
    if (ft->cat_offset < a->data_start || ft->cat_csize < 16 || ft->cat_csize > XIZ_MAX_CATALOG ||
        ft->cat_usize != ft->cat_csize)
        return FAIL(XIZ_E_CORRUPT, "invalid directory location");
    if ((rc = read_alloc(a, ft->cat_offset, ft->cat_csize, &buf, err))) return rc;
    uint8_t h[32];
    sha256(buf, (size_t)ft->cat_csize, h);
    if (!ct_equal(h, ft->cat_sha, 32)) { free(buf); return FAIL(XIZ_E_CORRUPT, "directory SHA-256 mismatch"); }
    rc = directory_parse(buf, (size_t)ft->cat_csize, &a->dir, &a->ar, err);
    free(buf);
    buf = NULL;
    if (rc) return rc;
    const directory *d = &a->dir;

    /* Earlier segments: from their slot table (or first catalog) to the end of their footer. */
    uint32_t segment = 0;
    uint64_t prev = ft->previous, bound = ft->cat_offset;
    while (prev != 0) {
        footer older;
        directory od;
        if (prev < a->data_start || prev + XIZ_FOOTER > bound || segment >= 65535 || !footer_at(a, prev, &older) ||
            older.cat_offset < a->data_start || older.cat_csize < 16 || older.cat_csize > XIZ_MAX_CATALOG ||
            older.major != a->sb.major) {
            rc = FAIL(XIZ_E_CORRUPT, "segment chain broken at footer %llu", (unsigned long long)prev);
            goto out;
        }
        if ((rc = read_alloc(a, older.cat_offset, older.cat_csize, &buf, err))) goto out;
        sha256(buf, (size_t)older.cat_csize, h);
        if (!ct_equal(h, older.cat_sha, 32)) { rc = FAIL(XIZ_E_CORRUPT, "earlier directory SHA-256 mismatch"); goto out; }
        if ((rc = directory_parse(buf, (size_t)older.cat_csize, &od, &a->ar, err))) goto out;
        free(buf);
        buf = NULL;
        uint64_t start = od.groups[0].offset;
        for (uint16_t i = 0; i < od.n_groups; i++)
            if (od.groups[i].offset < start) start = od.groups[i].offset;
        for (uint16_t i = 0; i < od.n_slots; i++)
            if (od.slots[i].count && od.slots[i].offset + (uint64_t)od.slots[i].count * XIZ_SLOT_SIZE == start) {
                start = od.slots[i].offset;
                break;
            }
        if (start < a->data_start || start > older.cat_offset) { rc = FAIL(XIZ_E_CORRUPT, "segment chain region"); goto out; }
        if ((rc = gap_add(&gs, start, prev + XIZ_FOOTER, err))) goto out;
        bound = start;
        prev = older.previous;
        segment++;
    }
    a->segments = segment + 1;

    /* This segment's slot table, then the group catalogs, in order, with no gaps. */
    uint64_t next = d->groups[0].offset, frame_end = next;
    for (uint16_t i = 0; i < d->n_slots; i++) {
        if (d->slots[i].segment != segment) continue;
        if (d->slots[i].offset + (uint64_t)d->slots[i].count * XIZ_SLOT_SIZE != next)
            { rc = FAIL(XIZ_E_CORRUPT, "key slots out of place"); goto out; }
        frame_end = d->slots[i].offset;
    }
    if (!a->encrypted && d->n_groups != 1) { rc = FAIL(XIZ_E_CORRUPT, "unencrypted archive with several groups"); goto out; }

    a->groups = arena_alloc(&a->ar, d->n_groups * sizeof(group_state));
    if (!a->groups) { rc = FAIL(XIZ_E_NOMEM, "out of memory"); goto out; }
    a->n_groups = d->n_groups;
    uint64_t max_cat = opt && opt->max_catalog ? opt->max_catalog : XIZ_MAX_CATALOG;
    uint32_t max_entries = opt && opt->max_entries ? opt->max_entries : 10000000u;
    size_t total_entries = 0;
    catalog *cats = calloc(d->n_groups, sizeof(catalog));
    if (!cats) { rc = FAIL(XIZ_E_NOMEM, "out of memory"); goto out; }
    const frame_rec *frames = NULL;
    for (uint16_t gi = 0; gi < d->n_groups; gi++) {
        const dir_group *g = &d->groups[gi];
        group_state *gs_ = &a->groups[gi];
        memset(gs_, 0, sizeof *gs_);
        gs_->id = g->group;
        if (g->offset != next || g->csize == 0 || g->usize == 0 || g->segment != segment || g->csize > XIZ_MAX_CATALOG + 65536) {
            rc = FAIL(XIZ_E_CORRUPT, "group catalog %u out of place", g->group);
            break;
        }
        if (g->usize > max_cat) { rc = FAIL(XIZ_E_LIMIT, "group catalog of %llu bytes", (unsigned long long)g->usize); break; }
        next = g->offset + g->csize;
        const uint8_t *gk = NULL;
        for (size_t k = 0; k < ko->n_keys; k++)
            if (ko->keys[k].group == g->group) gk = ko->keys[k].key;
        if (a->encrypted && !gk) { a->hidden_groups++; continue; }
        gs_->held = 1;
        if (gk) keyset_derive(&gs_->keys, gk, a->sb.id);
        uint8_t *packed = NULL, *raw = NULL;
        if ((rc = read_alloc(a, g->offset, g->csize, &packed, err))) break;
        sha256(packed, (size_t)g->csize, h);
        if (!ct_equal(h, g->sha, 32)) { free(packed); rc = FAIL(XIZ_E_CORRUPT, "group catalog %u SHA-256 mismatch", g->group); break; }
        size_t plen = (size_t)g->csize;
        if (a->encrypted) {
            uint8_t aad[12 + 16 + 2 + 4 + 8 + 4], *plain = NULL;
            memcpy(aad, "XIZ13catalog", 12);
            memcpy(aad + 12, a->sb.id, 16);
            wr16(aad + 28, g->group);
            wr32(aad + 30, g->segment);
            wr64(aad + 34, g->usize);
            wr32(aad + 42, ft->frame_count);
            rc = stream_open(gs_->keys.catalog, aad, sizeof aad, g->segment, packed, plen, &plain, &plen, err);
            free(packed);
            if (rc) break;
            packed = plain;
        }
        rc = zstd_decode_catalog(packed, plen, g->usize, &raw, err);
        free(packed);
        if (rc) break;
        rc = catalog_parse(raw, (size_t)g->usize, &cats[gi], &a->ar, 0, max_entries, err);
        free(raw);
        if (rc) break;
        catalog *c = &cats[gi];
        if (c->version != 2 || c->n_frames != ft->frame_count) { rc = FAIL(XIZ_E_CORRUPT, "group catalog %u", g->group); break; }
        if (frames && memcmp(frames, c->frames, c->n_frames * sizeof(frame_rec)) != 0) {
            rc = FAIL(XIZ_E_CORRUPT, "group catalogs disagree on the frames");
            break;
        }
        frames = c->frames;
        gs_->name = c->group_name;
        gs_->prefixes = c->prefixes;
        gs_->n_prefixes = c->n_prefixes;
        for (size_t e = 0; e < c->n_entries; e++) c->entries[e].group = g->group;
        total_entries += c->n_entries;
        if (gi == 0 && c->n_prefixes) { rc = FAIL(XIZ_E_CORRUPT, "group 0 with prefixes"); break; }
    }
    if (rc == XIZ_OK) {
        if (d->version >= 2) {
            if (d->leaf_offset != next || next + (uint64_t)d->leaf_count * 32 != ft->cat_offset || d->leaf_count > ft->entry_count)
                rc = FAIL(XIZ_E_CORRUPT, "leaf table out of place");
        } else if (next != ft->cat_offset) {
            rc = FAIL(XIZ_E_CORRUPT, "group catalogs do not reach the directory");
        }
    }
    for (uint16_t i = 0; rc == XIZ_OK && i < d->n_slots; i++) {
        const dir_slots *t = &d->slots[i];
        if (t->segment > segment || t->offset < a->data_start ||
            t->offset + (uint64_t)t->count * XIZ_SLOT_SIZE > ft->cat_offset)
            rc = FAIL(XIZ_E_CORRUPT, "key slot table");
    }
    /* Merge visible entries; erasable ones need their key slot. */
    if (rc == XIZ_OK) {
        a->cat.version = 2;
        a->cat.frames = (frame_rec *)frames;
        a->cat.n_frames = frames ? ft->frame_count : 0;
        a->cat.entries = arena_alloc(&a->ar, total_entries * sizeof(entry_rec) + 1);
        if (!a->cat.entries) rc = FAIL(XIZ_E_NOMEM, "out of memory");
    }
    for (uint16_t gi = 0; rc == XIZ_OK && gi < d->n_groups; gi++) {
        for (size_t k = 0; rc == XIZ_OK && k < cats[gi].n_entries; k++) {
            entry_rec e = cats[gi].entries[k];
            if (e.has_slot) {
                const dir_slots *t = NULL;
                for (uint16_t i = 0; i < d->n_slots; i++)
                    if (d->slots[i].segment == e.slot_segment) t = &d->slots[i];
                const keyset *ks = group_keys(a, e.group);
                if (!t || e.slot_index >= t->count || !ks || !a->encrypted) { rc = FAIL(XIZ_E_CORRUPT, "%s: key slot", e.path); break; }
                uint8_t slot[XIZ_SLOT_SIZE];
                if ((rc = src_read(a, t->offset + (uint64_t)e.slot_index * XIZ_SLOT_SIZE, slot, sizeof slot, err))) break;
                static const uint8_t zero[XIZ_SLOT_SIZE];
                if (memcmp(slot, zero, sizeof slot) == 0) { a->erased++; continue; }
                sha256(slot, sizeof slot, h);
                if (!ct_equal(h, e.slot_sha, 32)) { rc = FAIL(XIZ_E_CORRUPT, "%s: key slot altered", e.path); break; }
                uint8_t aad[9 + 16 + 4 + 4];
                memcpy(aad, "XIZ13slot", 9);
                memcpy(aad + 9, a->sb.id, 16);
                wr32(aad + 25, e.slot_segment);
                wr32(aad + 29, e.slot_index);
                memcpy(e.secret, slot + 12, 32);
                if (!aes_gcm_open(ks->slot, slot, aad, sizeof aad, e.secret, 32, slot + 44)) {
                    rc = FAIL(XIZ_E_AUTH, "%s: key slot does not authenticate", e.path);
                    break;
                }
                e.has_secret = 1;
            }
            a->cat.entries[a->cat.n_entries++] = e;
        }
    }
    free(cats);
    if (rc == XIZ_OK && frames) {
        int dicts = d->n_groups == 1;  /* §13.2: no dictionaries with more than one group */
        if ((rc = check_frames(a, &gs, frame_end, dicts, err)) == XIZ_OK) {
            for (uint32_t i = 0; i < a->cat.n_frames; i++) {
                int found = 0;
                for (uint16_t g = 0; g < d->n_groups; g++) found |= d->groups[g].group == a->cat.frames[i].group;
                if (!found) { rc = FAIL(XIZ_E_CORRUPT, "frame %u sealed for an unknown group", i); break; }
            }
        }
    }
    if (rc == XIZ_OK && a->cat.n_frames) {
        a->frame_entry = calloc(a->cat.n_frames, sizeof(long));
        if (!a->frame_entry) rc = FAIL(XIZ_E_NOMEM, "out of memory");
        for (uint32_t i = 0; rc == XIZ_OK && i < a->cat.n_frames; i++) a->frame_entry[i] = -1;
        for (size_t i = 0; rc == XIZ_OK && i < a->cat.n_entries; i++) {
            const entry_rec *e = &a->cat.entries[i];
            if (!e->has_secret) continue;
            for (uint32_t x = 0; x < e->n_ext; x++) {
                uint32_t f = e->ext[x].frame;
                if (f >= a->cat.n_frames) continue;  /* reported by check_entries */
                if (a->frame_entry[f] >= 0 && a->frame_entry[f] != (long)i) {
                    rc = FAIL(XIZ_E_CORRUPT, "entry-key frame %u shared by two entries", f);
                    break;
                }
                a->frame_entry[f] = (long)i;
            }
        }
    }
    if (rc == XIZ_OK) {
        int exact = a->hidden_groups == 0 && a->erased == 0;
        if (exact && a->cat.n_entries != ft->entry_count)
            rc = FAIL(XIZ_E_CORRUPT, "catalogs list %zu entries, footer %u", a->cat.n_entries, ft->entry_count);
        else if (a->cat.n_entries > ft->entry_count)
            rc = FAIL(XIZ_E_CORRUPT, "more entries than the footer declares");
        else
            rc = check_entries(a, exact, err);
    }
out:
    free(buf);
    free(gs.g);
    return rc;
}

/* ------------------------------------------------------------------ open / close */

int xiz_open(xiz_archive **out, const xiz_source *src, const xiz_open_options *opt, xiz_error *err) {
    if (!out || !src || !src->read) return FAIL(XIZ_E_ARG, "missing argument");
    *out = NULL;
    xiz_archive *a = calloc(1, sizeof *a);
    if (!a) return FAIL(XIZ_E_NOMEM, "out of memory");
    a->src = *src;
    for (int i = 0; i < XIZ_CACHE_SLOTS; i++) a->cache[i].index = -1;
    int rc;
    keys_opened ko = {0};
    if (src->size < XIZ_SUPERBLOCK + XIZ_FOOTER) {
        uint8_t m[8];
        if (src->size >= 8 && src->read(src->ctx, 0, m, 8) == 0 && memcmp(m, XIZ_SUPER_MAGIC, 8) == 0)
            rc = FAIL(XIZ_E_CORRUPT, "archive truncated (%llu bytes)", (unsigned long long)src->size);
        else
            rc = FAIL(XIZ_E_NOT_XIZ, "not a XIZ archive (too small)");
        goto fail;
    }
    uint8_t sbb[XIZ_SUPERBLOCK];
    if ((rc = src_read(a, 0, sbb, sizeof sbb, err))) goto fail;
    if ((rc = superblock_parse(sbb, &a->sb, opt && (opt->flags & XIZ_OPEN_ALLOW_BETA), err))) goto fail;
    a->data_start = XIZ_SUPERBLOCK + (uint64_t)a->sb.keys_length;
    a->encrypted = (a->sb.required & XIZ_FEATURE_ENCRYPTED) != 0;
    a->has_dir = (a->sb.required & XIZ_FEATURE_DIRECTORY) != 0;
    if (a->data_start + XIZ_FOOTER > src->size) { rc = FAIL(XIZ_E_CORRUPT, "keys block past the end"); goto fail; }
    if (a->encrypted) {
        int have = (opt && (opt->password || opt->password_count || opt->identity_count));
        int structure = !have && a->has_dir && opt && (opt->flags & XIZ_OPEN_NO_KEYS);
        if (!have && !structure) { rc = FAIL(XIZ_E_PASSWORD_REQUIRED, "the archive is encrypted: a password is required"); goto fail; }
        uint8_t *block = NULL;
        if ((rc = read_alloc(a, XIZ_SUPERBLOCK, a->sb.keys_length, &block, err))) goto fail;
        rc = keys_open(block, a->sb.keys_length, a->sb.raw, a->has_dir, opt, &ko, &a->ar, err);
        free(block);
        if (rc) goto fail;
        a->stanzas = ko.stanzas;
        a->n_stanzas = ko.n_stanzas;
        if (!ko.any_known) { rc = FAIL(XIZ_E_UNSUPPORTED, "no key stanza this reader implements"); goto fail; }
        if (!ko.n_keys && !structure) {
            if (ko.partial_threshold) {
                const stanza_info *t = &ko.stanzas[ko.partial_threshold - 1];
                rc = FAIL(XIZ_E_WRONG_PASSWORD, "\"%s\" needs %d custodians", t->label, t->k);
            } else {
                rc = FAIL(XIZ_E_WRONG_PASSWORD, "wrong password or key");
            }
            goto fail;
        }
        if (!a->has_dir) keyset_derive(&a->keys, ko.keys[0].key, a->sb.id);
        a->structure_only = structure;
    }
    if ((rc = find_last_footer(a, &a->footer_offset, &a->ft, err))) goto fail;
    if (a->ft.major != a->sb.major) { rc = FAIL(XIZ_E_CORRUPT, "footer version does not match the superblock"); goto fail; }
    if (a->has_dir) rc = open_directory(a, opt, &ko, err);
    else rc = open_catalog(a, opt, err);
    if (rc) goto fail;
    if (ko.keys) secure_zero(ko.keys, ko.n_keys * sizeof(group_key));
    free(ko.keys);
    *out = a;
    return XIZ_OK;
fail:
    if (ko.keys) secure_zero(ko.keys, ko.n_keys * sizeof(group_key));
    free(ko.keys);
    a->src.close = NULL;  /* the caller keeps ownership of the source on failure */
    xiz_close(a);
    return rc;
}

int xiz_open_file(xiz_archive **out, const char *path, const xiz_open_options *opt, xiz_error *err) {
    xiz_source s;
    TRY(xiz_source_file(&s, path, err));
    int rc = xiz_open(out, &s, opt, err);
    if (rc && s.close) s.close(s.ctx);
    return rc;
}

void cache_drop(xiz_archive *a) {
    for (int i = 0; i < XIZ_CACHE_SLOTS; i++) {
        if (a->cache[i].data) secure_zero(a->cache[i].data, a->cache[i].cap);
        free(a->cache[i].data);
        a->cache[i].data = NULL;
        a->cache[i].index = -1;
        a->cache[i].len = a->cache[i].cap = 0;
    }
}

void xiz_close(xiz_archive *a) {
    if (!a) return;
    cache_drop(a);
    for (size_t i = 0; i < a->n_dicts; i++)
        if (a->dicts[i].ddict) zstd_ddict_free(a->dicts[i].ddict);
    free(a->dicts);
    free(a->frame_entry);
    free(a->scratch);
    secure_zero(&a->keys, sizeof a->keys);
    if (a->groups) secure_zero(a->groups, a->n_groups * sizeof(group_state));
    arena_free(&a->ar);
    if (a->src.close) a->src.close(a->src.ctx);
    free(a);
}

/* ------------------------------------------------------------------ accessors */

int xiz_get_info(const xiz_archive *a, xiz_info *o) {
    if (!a || !o) return XIZ_E_ARG;
    memset(o, 0, sizeof *o);
    o->version_major = a->sb.major;
    o->version_minor = a->sb.minor;
    o->required_features = a->sb.required;
    o->optional_features = a->sb.optional;
    memcpy(o->archive_id, a->sb.id, 16);
    o->encrypted = a->encrypted;
    o->segments = a->segments;
    o->frame_count = a->ft.frame_count;
    o->entry_count = a->ft.entry_count;
    o->total_bytes = a->ft.total_bytes;
    o->visible_entries = a->cat.n_entries;
    o->dictionaries = (uint32_t)a->n_dicts;
    o->has_directory = a->has_dir;
    o->group_count = (uint16_t)a->n_groups;
    o->hidden_groups = a->hidden_groups;
    o->erased_entries = a->erased;
    o->erasable = a->has_dir && (a->dir.flags & 1);
    o->data_start = a->data_start;
    o->footer_offset = a->footer_offset;
    o->trailing_bytes = a->src.size - a->footer_offset - XIZ_FOOTER;
    for (uint32_t i = 0; i < a->cat.n_frames; i++) o->codec_frames[a->cat.frames[i].codec & 3]++;
    return XIZ_OK;
}

size_t xiz_entry_count(const xiz_archive *a) { return a ? a->cat.n_entries : 0; }

int entry_proof_data(const xiz_archive *a, const entry_rec *e, uint8_t salt[16], uint8_t sha[32]) {
    if (e->has_proof) {
        memcpy(salt, e->proof, 16);
        memcpy(sha, e->proof + 16, 32);
        return 1;
    }
    if (!e->has_sealed_proof || !e->has_secret) return 0;
    /* Erasable entries: salt ‖ SHA-256 sealed with HKDF(entry key, info "xiz/1.3/proof"),
     * aad "XIZ13proof" (reference implementation; see SPEC_NOTES.md). */
    (void)a;
    uint8_t k[32], plain[48];
    hkdf_sha256(e->secret, 32, NULL, 0, "xiz/1.3/proof", k, 32);
    memcpy(plain, e->sealed_proof + 12, 48);
    int ok = aes_gcm_open(k, e->sealed_proof, (const uint8_t *)"XIZ13proof", 10, plain, 48, e->sealed_proof + 60);
    secure_zero(k, 32);
    if (!ok) return 0;
    memcpy(salt, plain, 16);
    memcpy(sha, plain + 16, 32);
    return 1;
}

int xiz_get_entry(const xiz_archive *a, size_t index, xiz_entry *o) {
    if (!a || !o || index >= a->cat.n_entries) return XIZ_E_ARG;
    const entry_rec *e = &a->cat.entries[index];
    memset(o, 0, sizeof *o);
    o->path = e->path;
    o->path_len = e->path_len;
    o->type = e->type;
    o->size = e->size;
    o->mode = e->mode;
    o->uid = e->uid;
    o->gid = e->gid;
    o->mtime_sec = e->mtime;
    o->mtime_nsec = e->nsec;
    o->link = e->link ? e->link : "";
    o->link_len = e->link_len;
    o->has_digest = e->has_digest;
    memcpy(o->digest, e->digest, 32);
    o->group = e->group;
    o->erasable = e->has_slot;
    o->has_proof = entry_proof_data(a, e, o->proof_salt, o->proof_sha256);
    o->xattr_count = e->n_xattrs;
    o->extent_count = e->n_ext;
    return XIZ_OK;
}

int xiz_get_xattr(const xiz_archive *a, size_t index, size_t i, const char **name, size_t *name_len,
                  const uint8_t **value, size_t *value_len) {
    if (!a || index >= a->cat.n_entries || i >= a->cat.entries[index].n_xattrs) return XIZ_E_ARG;
    const xattr_rec *x = &a->cat.entries[index].xattrs[i];
    if (name) *name = x->name;
    if (name_len) *name_len = x->name_len;
    if (value) *value = x->value;
    if (value_len) *value_len = x->value_len;
    return XIZ_OK;
}

/* Compares two paths component by component, ignoring empty and "." components. */
static int path_equal(const char *a, size_t na, const char *b, size_t nb) {
    size_t i = 0, j = 0;
    for (;;) {
        while (i < na && a[i] == '/') i++;
        while (j < nb && b[j] == '/') j++;
        if (i + 1 <= na && a[i] == '.' && (i + 1 == na || a[i + 1] == '/')) { i++; continue; }
        if (j + 1 <= nb && b[j] == '.' && (j + 1 == nb || b[j + 1] == '/')) { j++; continue; }
        if (i == na || j == nb) return i == na && j == nb;
        size_t ei = i, ej = j;
        while (ei < na && a[ei] != '/') ei++;
        while (ej < nb && b[ej] != '/') ej++;
        if (ei - i != ej - j || memcmp(a + i, b + j, ei - i) != 0) return 0;
        i = ei;
        j = ej;
    }
}

int xiz_find(const xiz_archive *a, const char *path, size_t *index) {
    if (!a || !path) return XIZ_E_ARG;
    size_t n = strlen(path);
    for (size_t i = 0; i < a->cat.n_entries; i++) {
        const entry_rec *e = &a->cat.entries[i];
        if (path_equal(e->path, e->path_len, path, n)) {
            if (index) *index = i;
            return XIZ_OK;
        }
    }
    return XIZ_E_NOT_FOUND;
}

size_t xiz_group_count(const xiz_archive *a) { return a ? a->n_groups : 0; }

int xiz_get_group(const xiz_archive *a, size_t i, xiz_group *o) {
    if (!a || !o || i >= a->n_groups) return XIZ_E_ARG;
    o->id = a->groups[i].id;
    o->held = a->groups[i].held;
    o->name = a->groups[i].held ? a->groups[i].name : NULL;
    o->prefix_count = a->groups[i].held ? a->groups[i].n_prefixes : 0;
    return XIZ_OK;
}

const char *xiz_group_prefix(const xiz_archive *a, size_t i, size_t p) {
    if (!a || i >= a->n_groups || !a->groups[i].held || p >= a->groups[i].n_prefixes) return NULL;
    return a->groups[i].prefixes[p];
}

size_t xiz_stanza_count(const xiz_archive *a) { return a ? a->n_stanzas : 0; }

int xiz_get_stanza(const xiz_archive *a, size_t i, xiz_stanza *o) {
    if (!a || !o || i >= a->n_stanzas) return XIZ_E_ARG;
    const stanza_info *s = &a->stanzas[i];
    o->type = s->type;
    o->label = s->label ? s->label : "";
    o->opened = s->opened;
    o->threshold_id = s->tid;
    o->k = s->k;
    o->n = s->n;
    o->x = s->x;
    return XIZ_OK;
}
