/* Fixed structures: superblock (§3), frame header (§4.1), catalog (§5, §9, §13.2), footer (§7),
 * directory (§13.1). Pure parsing, no I/O. */
#include "internal.h"

int superblock_parse(const uint8_t b[XIZ_SUPERBLOCK], superblock *s, int allow_beta, xiz_error *err) {
    if (memcmp(b, XIZ_SUPER_MAGIC, 8) != 0) return FAIL(XIZ_E_NOT_XIZ, "not a XIZ archive (bad magic)");
    if (rd32(b + 60) != xiz_crc32c(0, b, 60)) return FAIL(XIZ_E_CORRUPT, "superblock checksum mismatch");
    memcpy(s->raw, b, XIZ_SUPERBLOCK);
    s->major = rd16(b + 8);
    s->minor = rd16(b + 10);
    s->required = rd16(b + 12);
    s->optional = rd16(b + 14);
    memcpy(s->id, b + 16, 16);
    s->keys_length = rd32(b + 32);
    if (s->major > 1) return FAIL(XIZ_E_UNSUPPORTED, "XIZ version %u.%u (this reader knows 1.x)", s->major, s->minor);
    if (s->major == 0) {
        if (!allow_beta) return FAIL(XIZ_E_UNSUPPORTED, "XIZ 0.%u beta archive (enable beta support)", s->minor);
        if (s->required || s->keys_length) return FAIL(XIZ_E_CORRUPT, "XIZ 0.x superblock with features");
        return XIZ_OK;
    }
    uint16_t unknown = (uint16_t)(s->required & ~XIZ_FEATURES_KNOWN);
    if (unknown) {
        return FAIL(XIZ_E_UNSUPPORTED, "required feature bits 0x%04x not implemented (archive made by a newer writer)",
                    unknown);
    }
    if ((s->required & XIZ_FEATURE_JPEG) && !xiz_has_jpeg())
        return FAIL(XIZ_E_UNSUPPORTED, "required feature jpeg (0x0040): this libxiz was built without brunsli (XIZ_JPEG=OFF)");
    if ((s->required & XIZ_FEATURE_APPLE) && !xiz_has_apple_codecs())
        return FAIL(XIZ_E_UNSUPPORTED, "required feature apple (0x0080): LZRAVEN and LZMESH frames need macOS 27 or later");
    for (int i = 36; i < 60; i++)
        if (b[i]) return FAIL(XIZ_E_CORRUPT, "superblock reserved bytes are not zero");
    if (((s->required & XIZ_FEATURE_ENCRYPTED) != 0) != (s->keys_length > 0))
        return FAIL(XIZ_E_CORRUPT, "encrypted flag and keys block length disagree");
    if (s->keys_length > XIZ_MAX_KEYS_BLOCK) return FAIL(XIZ_E_LIMIT, "keys block larger than 65,536 bytes");
    return XIZ_OK;
}

void superblock_encode(const superblock *s, uint8_t out[XIZ_SUPERBLOCK]) {
    memset(out, 0, XIZ_SUPERBLOCK);
    memcpy(out, XIZ_SUPER_MAGIC, 8);
    wr16(out + 8, s->major);
    wr16(out + 10, s->minor);
    wr16(out + 12, s->required);
    wr16(out + 14, s->optional);
    memcpy(out + 16, s->id, 16);
    wr32(out + 32, s->keys_length);
    wr32(out + 60, xiz_crc32c(0, out, 60));
}

int footer_parse(const uint8_t b[XIZ_FOOTER], footer *f, xiz_error *err) {
    if (memcmp(b, "XIZF", 4) != 0 || memcmp(b + 92, "XIZ!", 4) != 0) return FAIL(XIZ_E_CORRUPT, "footer not found");
    if (rd32(b + 88) != xiz_crc32c(0, b, 88)) return FAIL(XIZ_E_CORRUPT, "footer checksum mismatch");
    f->major = rd16(b + 4);
    f->minor = rd16(b + 6);
    f->cat_offset = rd64(b + 8);
    f->cat_csize = rd64(b + 16);
    f->cat_usize = rd64(b + 24);
    f->frame_count = rd32(b + 32);
    f->entry_count = rd32(b + 36);
    f->total_bytes = rd64(b + 40);
    memcpy(f->cat_sha, b + 48, 32);
    f->previous = rd64(b + 80);
    if (f->major > 1) return FAIL(XIZ_E_UNSUPPORTED, "footer version %u.%u", f->major, f->minor);
    return XIZ_OK;
}

void footer_encode(const footer *f, uint8_t out[XIZ_FOOTER]) {
    memcpy(out, "XIZF", 4);
    wr16(out + 4, f->major);
    wr16(out + 6, f->minor);
    wr64(out + 8, f->cat_offset);
    wr64(out + 16, f->cat_csize);
    wr64(out + 24, f->cat_usize);
    wr32(out + 32, f->frame_count);
    wr32(out + 36, f->entry_count);
    wr64(out + 40, f->total_bytes);
    memcpy(out + 48, f->cat_sha, 32);
    wr64(out + 80, f->previous);
    wr32(out + 88, xiz_crc32c(0, out, 88));
    memcpy(out + 92, "XIZ!", 4);
}

/* u16 major ‖ u16 minor ‖ u64 catalog_usize ‖ u32 frame_count ‖ u32 entry_count ‖ u64 total ‖ u64 previous */
void footer_auth_fields(const footer *f, uint8_t out[36]) {
    wr16(out, f->major);
    wr16(out + 2, f->minor);
    wr64(out + 4, f->cat_usize);
    wr32(out + 12, f->frame_count);
    wr32(out + 16, f->entry_count);
    wr64(out + 20, f->total_bytes);
    wr64(out + 28, f->previous);
}

void frame_header_encode(uint32_t index, const frame_rec *f, uint8_t out[XIZ_FRAME_HEADER]) {
    memset(out, 0, XIZ_FRAME_HEADER);
    memcpy(out, "XFR1", 4);
    out[4] = f->codec;
    out[5] = f->flags;
    wr16(out + 6, f->dict);
    wr32(out + 8, index);
    wr32(out + 12, f->csize);
    wr32(out + 16, f->usize);
    wr32(out + 20, f->crc);
    wr16(out + 24, f->group);  /* §13.2: the group sealing the frame, zero otherwise */
}

/* ------------------------------------------------------------------ catalog */

static int parse_beta_entries(rbuf *r, catalog *c, arena *ar, uint32_t max_entries, xiz_error *err) {
    uint32_t n = rb_u32(r);
    if (r->bad) return FAIL(XIZ_E_CORRUPT, "catalog truncated");
    if (n > max_entries || n > rb_left(r) / 30) return FAIL(XIZ_E_CORRUPT, "catalog entry count");
    c->entries = arena_alloc(ar, (size_t)n * sizeof(entry_rec) + 1);
    if (!c->entries) return FAIL(XIZ_E_NOMEM, "out of memory");
    memset(c->entries, 0, (size_t)n * sizeof(entry_rec));
    for (uint32_t i = 0; i < n; i++) {
        entry_rec *e = &c->entries[i];
        e->type = rb_u8(r);
        if (e->type > 2) return FAIL(XIZ_E_UNSUPPORTED, "entry type %u", e->type);
        e->path_len = rb_u16(r);
        const uint8_t *p = rb_take(r, e->path_len);
        e->mode = rb_u16(r);
        e->uid = rb_u32(r);
        e->gid = rb_u32(r);
        e->mtime = (int64_t)rb_u64(r);
        e->nsec = rb_u32(r);
        e->size = rb_u64(r);
        e->link_len = rb_u16(r);
        const uint8_t *l = rb_take(r, e->link_len);
        uint16_t nx = rb_u16(r);
        if (r->bad) return FAIL(XIZ_E_CORRUPT, "catalog truncated");
        e->path = arena_dup(ar, p, e->path_len, 1);
        e->link = arena_dup(ar, l, e->link_len, 1);
        e->xattrs = arena_alloc(ar, (size_t)nx * sizeof(xattr_rec) + 1);
        if (!e->path || !e->link || !e->xattrs) return FAIL(XIZ_E_NOMEM, "out of memory");
        for (uint16_t k = 0; k < nx; k++) {
            uint8_t nl = rb_u8(r);
            const uint8_t *nm = rb_take(r, nl);
            uint32_t vl = rb_u32(r);
            const uint8_t *v = rb_take(r, vl);
            if (r->bad) return FAIL(XIZ_E_CORRUPT, "catalog truncated");
            xattr_rec *x = &e->xattrs[e->n_xattrs++];
            x->name = arena_dup(ar, nm, nl, 1);
            x->name_len = nl;
            x->value = arena_dup(ar, v, vl, 0);
            x->value_len = vl;
            if (!x->name || (vl && !x->value)) return FAIL(XIZ_E_NOMEM, "out of memory");
        }
        uint32_t ne = rb_u32(r);
        if (r->bad || ne > rb_left(r) / 12) return FAIL(XIZ_E_CORRUPT, "catalog extent count");
        e->ext = arena_alloc(ar, (size_t)ne * sizeof(extent_rec) + 1);
        if (!e->ext) return FAIL(XIZ_E_NOMEM, "out of memory");
        for (uint32_t k = 0; k < ne; k++) {
            e->ext[k].frame = rb_u32(r);
            e->ext[k].offset = rb_u32(r);
            e->ext[k].length = rb_u32(r);
        }
        e->n_ext = ne;
        if (rb_u8(r) == 1) {
            const uint8_t *h = rb_take(r, 32);
            if (h) { memcpy(e->digest, h, 32); e->has_digest = 1; }
        }
        if (r->bad) return FAIL(XIZ_E_CORRUPT, "catalog truncated");
    }
    c->n_entries = n;
    return XIZ_OK;
}

int catalog_parse(const uint8_t *b, size_t n, catalog *c, arena *ar, int allow_beta, uint32_t max_entries,
                  xiz_error *err) {
    rbuf r;
    rb_init(&r, b, n);
    memset(c, 0, sizeof *c);
    const uint8_t *magic = rb_take(&r, 4);
    if (!magic || memcmp(magic, "XCAT", 4) != 0) return FAIL(XIZ_E_CORRUPT, "catalog magic");
    uint16_t version = rb_u16(&r);
    if (r.bad) return FAIL(XIZ_E_CORRUPT, "catalog truncated");
    if (version == 0 && !allow_beta) return FAIL(XIZ_E_UNSUPPORTED, "0.1 beta catalog");
    if (version > 2) return FAIL(XIZ_E_UNSUPPORTED, "catalog version %u", version);
    c->version = version;
    const size_t rec = version == 0 ? 21 : version == 2 ? 26 : 24;
    uint32_t nf = rb_u32(&r);
    if (r.bad || nf > rb_left(&r) / rec) return FAIL(XIZ_E_CORRUPT, "catalog frame count");
    c->frames = arena_alloc(ar, (size_t)nf * sizeof(frame_rec) + 1);
    if (!c->frames) return FAIL(XIZ_E_NOMEM, "out of memory");
    for (uint32_t i = 0; i < nf; i++) {
        frame_rec *f = &c->frames[i];
        memset(f, 0, sizeof *f);
        f->offset = rb_u64(&r);
        f->csize = rb_u32(&r);
        f->usize = rb_u32(&r);
        f->crc = rb_u32(&r);
        f->codec = rb_u8(&r);
        if (version > 0) {
            f->flags = rb_u8(&r);
            f->dict = rb_u16(&r);
        }
        if (version == 2) f->group = rb_u16(&r);
        if (f->codec > CODEC_LZMESH) return FAIL(XIZ_E_UNSUPPORTED, "frame %u: codec %u", i, f->codec);
        uint8_t allowed = version == 2 ? (XIZ_FLAG_DICTIONARY | XIZ_FLAG_ENTRY_KEY) : XIZ_FLAG_DICTIONARY;
        if (f->flags & ~allowed) return FAIL(XIZ_E_UNSUPPORTED, "frame %u: flags 0x%02x", i, f->flags);
    }
    c->n_frames = nf;
    if (version == 0) {
        TRY(parse_beta_entries(&r, c, ar, max_entries, err));
        if (rb_left(&r) != 0 || r.bad) return FAIL(XIZ_E_CORRUPT, "catalog trailing data");
        return XIZ_OK;
    }
    uint32_t ne = rb_u32(&r);
    if (r.bad) return FAIL(XIZ_E_CORRUPT, "catalog truncated");
    if (ne > max_entries) return FAIL(XIZ_E_LIMIT, "%u entries (limit %u)", ne, max_entries);
    if (ne > rb_left(&r) / 5) return FAIL(XIZ_E_CORRUPT, "catalog entry count");
    c->entries = arena_alloc(ar, (size_t)ne * sizeof(entry_rec) + 1);
    if (!c->entries) return FAIL(XIZ_E_NOMEM, "out of memory");
    memset(c->entries, 0, (size_t)ne * sizeof(entry_rec));
    for (uint32_t i = 0; i < ne; i++) {
        entry_rec *e = &c->entries[i];
        e->type = rb_u8(&r);
        if (r.bad) return FAIL(XIZ_E_CORRUPT, "catalog truncated");
        if (e->type > 2) return FAIL(XIZ_E_UNSUPPORTED, "entry %u: type %u", i, e->type);
        e->path_len = rb_u16(&r);
        const uint8_t *p = rb_take(&r, e->path_len);
        uint16_t nfields = rb_u16(&r);
        if (r.bad) return FAIL(XIZ_E_CORRUPT, "catalog truncated");
        e->path = arena_dup(ar, p, e->path_len, 1);
        if (!e->path) return FAIL(XIZ_E_NOMEM, "out of memory");
        e->mode = e->type == 1 ? 0755 : 0644;
        e->link = "";
        int saw_size = 0, saw_ext = 0;
        /* Count xattr fields first (one allocation). */
        size_t mark = r.at, nxa = 0;
        for (uint16_t k = 0; k < nfields; k++) {
            uint16_t tag = rb_u16(&r);
            uint32_t len = rb_u32(&r);
            if (!rb_take(&r, len)) return FAIL(XIZ_E_CORRUPT, "entry %u: field length", i);
            if (tag == TAG_XATTR) nxa++;
        }
        r.at = mark;
        if (nxa) {
            e->xattrs = arena_alloc(ar, nxa * sizeof(xattr_rec));
            if (!e->xattrs) return FAIL(XIZ_E_NOMEM, "out of memory");
        }
        for (uint16_t k = 0; k < nfields; k++) {
            uint16_t tag = rb_u16(&r);
            uint32_t len = rb_u32(&r);
            const uint8_t *v = rb_take(&r, len);
            switch (tag) {
            case TAG_SIZE:
                if (len != 8) return FAIL(XIZ_E_CORRUPT, "entry %u: size field length %u", i, len);
                e->size = rd64(v);
                saw_size = 1;
                break;
            case TAG_EXTENTS:
                if (len % 12) return FAIL(XIZ_E_CORRUPT, "entry %u: extents field length %u", i, len);
                e->n_ext = len / 12;
                e->ext = arena_alloc(ar, (size_t)e->n_ext * sizeof(extent_rec) + 1);
                if (!e->ext) return FAIL(XIZ_E_NOMEM, "out of memory");
                for (uint32_t x = 0; x < e->n_ext; x++) {
                    e->ext[x].frame = rd32(v + 12 * x);
                    e->ext[x].offset = rd32(v + 12 * x + 4);
                    e->ext[x].length = rd32(v + 12 * x + 8);
                }
                saw_ext = 1;
                break;
            case TAG_LINK:
                e->link = arena_dup(ar, v, len, 1);
                e->link_len = len;
                if (!e->link) return FAIL(XIZ_E_NOMEM, "out of memory");
                break;
            case TAG_MODE:
                if (len != 2) return FAIL(XIZ_E_CORRUPT, "entry %u: mode field length %u", i, len);
                e->mode = rd16(v);
                break;
            case TAG_OWNER:
                if (len != 8) return FAIL(XIZ_E_CORRUPT, "entry %u: owner field length %u", i, len);
                e->uid = rd32(v);
                e->gid = rd32(v + 4);
                break;
            case TAG_MTIME:
                if (len != 12) return FAIL(XIZ_E_CORRUPT, "entry %u: mtime field length %u", i, len);
                e->mtime = (int64_t)rd64(v);
                e->nsec = rd32(v + 8);
                break;
            case TAG_XATTR: {
                if (len < 2 || rd16(v) > len - 2) return FAIL(XIZ_E_CORRUPT, "entry %u: xattr field", i);
                xattr_rec *x = &e->xattrs[e->n_xattrs++];
                x->name_len = rd16(v);
                x->name = arena_dup(ar, v + 2, x->name_len, 1);
                if (!x->name) return FAIL(XIZ_E_NOMEM, "out of memory");
                x->value_len = len - 2 - x->name_len;
                x->value = arena_dup(ar, v + 2 + x->name_len, x->value_len, 0);
                if (x->value_len && !x->value) return FAIL(XIZ_E_NOMEM, "out of memory");
                break;
            }
            case TAG_DIGEST:
                if (len != 32) return FAIL(XIZ_E_CORRUPT, "entry %u: digest field length %u", i, len);
                memcpy(e->digest, v, 32);
                e->has_digest = 1;
                break;
            case TAG_PROOF:
                if (len != 48) return FAIL(XIZ_E_CORRUPT, "entry %u: proof field length %u", i, len);
                memcpy(e->proof, v, 48);
                e->has_proof = 1;
                break;
            case TAG_KEY_SLOT:
                if (len != 40) return FAIL(XIZ_E_CORRUPT, "entry %u: key slot field length %u", i, len);
                e->slot_segment = rd32(v);
                e->slot_index = rd32(v + 4);
                memcpy(e->slot_sha, v + 8, 32);
                e->has_slot = 1;
                break;
            case TAG_SEALED_PROOF:
                if (len != 76) return FAIL(XIZ_E_CORRUPT, "entry %u: sealed proof field length %u", i, len);
                memcpy(e->sealed_proof, v, 76);
                e->has_sealed_proof = 1;
                break;
            default:
                if (tag & 0x8000)
                    return FAIL(XIZ_E_UNSUPPORTED, "entry %u: unknown critical field 0x%04x (made by a newer writer)",
                                i, tag);
                break;  /* unknown non-critical: skipped (§5.2) */
            }
        }
        if (e->type == 0 && !(saw_size && saw_ext)) return FAIL(XIZ_E_CORRUPT, "file without size or extents: %s", e->path);
        if (e->has_slot && version != 2) return FAIL(XIZ_E_CORRUPT, "key slot outside a group catalog");
    }
    c->n_entries = ne;
    if (version == 2) {
        uint16_t nl = rb_u16(&r);
        const uint8_t *nm = rb_take(&r, nl);
        uint16_t np = rb_u16(&r);
        if (r.bad) return FAIL(XIZ_E_CORRUPT, "group catalog trailer truncated");
        c->group_name = arena_dup(ar, nm, nl, 1);
        c->prefixes = arena_alloc(ar, (size_t)np * sizeof(char *) + 1);
        if (!c->group_name || !c->prefixes) return FAIL(XIZ_E_NOMEM, "out of memory");
        for (uint16_t k = 0; k < np; k++) {
            uint16_t pl = rb_u16(&r);
            const uint8_t *pp = rb_take(&r, pl);
            if (r.bad) return FAIL(XIZ_E_CORRUPT, "group catalog trailer truncated");
            c->prefixes[k] = arena_dup(ar, pp, pl, 1);
            if (!c->prefixes[k]) return FAIL(XIZ_E_NOMEM, "out of memory");
        }
        c->n_prefixes = np;
    }
    if (r.bad) return FAIL(XIZ_E_CORRUPT, "catalog truncated");
    if (rb_left(&r) != 0) return FAIL(XIZ_E_CORRUPT, "catalog trailing data (%zu bytes)", rb_left(&r));
    return XIZ_OK;
}

/* ------------------------------------------------------------------ directory (§13.1) */

int directory_parse(const uint8_t *b, size_t n, directory *d, arena *ar, xiz_error *err) {
    memset(d, 0, sizeof *d);
    if (n < 16 || memcmp(b, "XDIR", 4) != 0) return FAIL(XIZ_E_CORRUPT, "directory magic");
    if (rd32(b + n - 4) != xiz_crc32c(0, b, n - 4)) return FAIL(XIZ_E_CORRUPT, "directory checksum mismatch");
    d->raw = arena_dup(ar, b, n, 0);
    if (!d->raw) return FAIL(XIZ_E_NOMEM, "out of memory");
    d->raw_len = n;
    rbuf r;
    rb_init(&r, d->raw, n - 4);
    r.at = 4;
    d->version = rb_u16(&r);
    if (d->version != 1 && d->version != 2) return FAIL(XIZ_E_UNSUPPORTED, "directory version %u", d->version);
    if (d->version >= 2) d->flags = rb_u16(&r);
    if (d->flags & ~1u) return FAIL(XIZ_E_UNSUPPORTED, "directory flags 0x%04x", d->flags);
    d->n_groups = rb_u16(&r);
    if (r.bad || d->n_groups < 1) return FAIL(XIZ_E_CORRUPT, "directory without groups");
    if (d->n_groups > rb_left(&r) / 62) return FAIL(XIZ_E_CORRUPT, "directory group count");
    d->groups = arena_alloc(ar, d->n_groups * sizeof(dir_group));
    if (!d->groups) return FAIL(XIZ_E_NOMEM, "out of memory");
    for (uint16_t i = 0; i < d->n_groups; i++) {
        dir_group *g = &d->groups[i];
        g->group = rb_u16(&r);
        g->segment = rb_u32(&r);
        g->offset = rb_u64(&r);
        g->csize = rb_u64(&r);
        g->usize = rb_u64(&r);
        const uint8_t *h = rb_take(&r, 32);
        if (!h) return FAIL(XIZ_E_CORRUPT, "directory truncated");
        memcpy(g->sha, h, 32);
        if (i > 0 && g->group <= d->groups[i - 1].group) return FAIL(XIZ_E_CORRUPT, "directory groups out of order");
    }
    if (d->groups[0].group != 0) return FAIL(XIZ_E_CORRUPT, "directory without group 0");
    if (d->version >= 2) {
        d->n_slots = rb_u16(&r);
        if (r.bad || d->n_slots > rb_left(&r) / 16) return FAIL(XIZ_E_CORRUPT, "directory slot tables");
        d->slots = arena_alloc(ar, (size_t)d->n_slots * sizeof(dir_slots) + 1);
        if (!d->slots) return FAIL(XIZ_E_NOMEM, "out of memory");
        for (uint16_t i = 0; i < d->n_slots; i++) {
            d->slots[i].segment = rb_u32(&r);
            d->slots[i].offset = rb_u64(&r);
            d->slots[i].count = rb_u32(&r);
            if (i > 0 && d->slots[i].segment <= d->slots[i - 1].segment)
                return FAIL(XIZ_E_CORRUPT, "directory slot tables out of order");
        }
        d->leaf_offset = rb_u64(&r);
        d->leaf_count = rb_u32(&r);
        const uint8_t *root = rb_take(&r, 32);
        if (!root) return FAIL(XIZ_E_CORRUPT, "directory truncated");
        memcpy(d->root, root, 32);
    }
    d->signed_len = r.at;
    d->signature_len = rb_u32(&r);
    d->signature = rb_take(&r, d->signature_len);
    if (r.bad) return FAIL(XIZ_E_CORRUPT, "directory truncated");
    if (rb_left(&r) != 0) return FAIL(XIZ_E_CORRUPT, "directory trailing data");
    return XIZ_OK;
}
