/* XIZ 1.3 signed segments (§13.5), Merkle trees (§13.6) and `xiz-proof-1` proofs. */
#include "internal.h"

#include "monocypher-ed25519.h"
#include "bearssl_x509.h"
#include "bearssl_ec.h"
#include "bearssl_rsa.h"
#include "mldsa.h"

#include <stdio.h>

/* ------------------------------------------------------------------ Merkle (RFC 6962 §2.1) */

void merkle_leaf(const uint8_t *data, size_t n, uint8_t out[32]) {
    sha256_ctx c;
    uint8_t z = 0;
    sha256_init(&c);
    sha256_update(&c, &z, 1);
    sha256_update(&c, data, n);
    sha256_final(&c, out);
}

static void merkle_node(const uint8_t l[32], const uint8_t r[32], uint8_t out[32]) {
    sha256_ctx c;
    uint8_t one = 1;
    sha256_init(&c);
    sha256_update(&c, &one, 1);
    sha256_update(&c, l, 32);
    sha256_update(&c, r, 32);
    sha256_final(&c, out);
}

static size_t split_point(size_t n) {
    size_t k = 1;
    while (k << 1 < n) k <<= 1;
    return k;
}

void merkle_root(const uint8_t (*leaves)[32], size_t n, uint8_t out[32]) {
    if (n == 0) { sha256("", 0, out); return; }
    if (n == 1) { memcpy(out, leaves[0], 32); return; }
    size_t k = split_point(n);
    uint8_t l[32], r[32];
    merkle_root(leaves, k, l);
    merkle_root(leaves + k, n - k, r);
    merkle_node(l, r, out);
}

/* RFC 9162 §2.1.3.2. */
int merkle_root_from_path(const uint8_t leaf[32], uint64_t index, uint64_t size, const uint8_t (*path)[32],
                          size_t n, uint8_t out[32]) {
    if (index >= size) return 0;
    uint64_t fn = index, sn = size - 1;
    uint8_t r[32];
    memcpy(r, leaf, 32);
    for (size_t i = 0; i < n; i++) {
        if (sn == 0) return 0;
        if ((fn & 1) || fn == sn) {
            merkle_node(path[i], r, r);
            if (!(fn & 1))
                while (!(fn & 1) && fn != 0) { fn >>= 1; sn >>= 1; }
        } else {
            merkle_node(r, path[i], r);
        }
        fn >>= 1;
        sn >>= 1;
    }
    if (sn != 0) return 0;
    memcpy(out, r, 32);
    return 1;
}

void leaf_data(wbuf *w, const uint8_t salt[16], const char *path, size_t path_len, uint8_t type, uint64_t size,
               const uint8_t sha[32]) {
    wb_put(w, salt, 16);
    wb_u16(w, (uint16_t)path_len);
    wb_put(w, path, path_len);
    wb_u8(w, type);
    wb_u64(w, size);
    wb_put(w, sha, 32);
}

/* ------------------------------------------------------------------ signatures */

typedef struct {
    uint8_t algorithm;           /* 1 Ed25519, 2 ECDSA P-256 + X.509, 3 RSA PKCS#1 v1.5 + X.509,
                                    4 hybrid Ed25519 + ML-DSA-65 (§22) */
    const uint8_t *pk;           /* algorithm 1: Ed25519; 4: Ed25519 [32] ‖ ML-DSA-65 [1952] */
    const uint8_t *key;          /* the key field as stored: public key, or the encoded chain */
    size_t key_len;
    const uint8_t *cert;         /* algorithms 2, 3: the signer's certificate (DER) */
    uint32_t cert_len;
    uint16_t chain_count;
    const uint8_t *label;
    uint8_t label_len;
    int64_t time;
    const uint8_t *previous;
    const uint8_t *sig;
    size_t sig_len;
    uint32_t token_len;
} sig_record;

static int record_parse(const uint8_t *b, size_t n, sig_record *r) {
    rbuf q;
    rb_init(&q, b, n);
    memset(r, 0, sizeof *r);
    r->algorithm = rb_u8(&q);
    r->key = q.p + q.at;
    if (r->algorithm == 1) {
        r->pk = rb_take(&q, 32);
    } else if (r->algorithm == 4) {
        r->pk = rb_take(&q, 32 + XIZ_MLDSA_PUBLICKEY);
    } else if (r->algorithm == 2 || r->algorithm == 3) {
        r->chain_count = rb_u16(&q);
        if (r->chain_count < 1 || r->chain_count > 16) return 0;
        for (uint16_t i = 0; i < r->chain_count && !q.bad; i++) {
            uint32_t len = rb_u32(&q);
            if (len > 65536) return 0;
            const uint8_t *c = rb_take(&q, len);
            if (i == 0) { r->cert = c; r->cert_len = len; }
        }
    } else {
        return 0;
    }
    if (q.bad) return 0;
    r->key_len = (size_t)(q.p + q.at - r->key);
    r->label_len = rb_u8(&q);
    r->label = rb_take(&q, r->label_len);
    r->time = (int64_t)rb_u64(&q);
    r->previous = rb_take(&q, 32);
    r->sig_len = r->algorithm == 1 ? 64 : r->algorithm == 4 ? 64 + XIZ_MLDSA_SIGNATURE : rb_u16(&q);
    r->sig = rb_take(&q, r->sig_len);
    r->token_len = rb_u32(&q);
    rb_take(&q, r->token_len);
    return !q.bad && rb_left(&q) == 0;
}

/* The signer certificate's public key, with BearSSL's X.509 decoder (no chain validation here:
 * which issuers to trust is the reader's decision; libxiz reports the certificate's SHA-256). */

static int sig_verify(const sig_record *r, const uint8_t *msg, size_t msg_len) {
    if (r->algorithm == 1) return crypto_ed25519_check(r->sig, r->pk, msg, msg_len) == 0;
    if (r->algorithm == 4) {
        /* Both halves, on the same message; the ML-DSA one with its FIPS 204 context. */
        static const uint8_t ctx[] = "XIZ112hybrid";
        return crypto_ed25519_check(r->sig, r->pk, msg, msg_len) == 0 &&
               xiz_mldsa65_verify(r->sig + 64, msg, msg_len, ctx, sizeof ctx - 1, r->pk + 32) == 0;
    }
    br_x509_decoder_context dc;
    br_x509_decoder_init(&dc, NULL, NULL);
    br_x509_decoder_push(&dc, r->cert, r->cert_len);
    const br_x509_pkey *pk = br_x509_decoder_get_pkey(&dc);
    if (!pk || br_x509_decoder_last_error(&dc) != 0) return 0;
    uint8_t h[32];
    sha256(msg, msg_len, h);
    if (r->algorithm == 2) {
        if (pk->key_type != BR_KEYTYPE_EC || pk->key.ec.curve != BR_EC_secp256r1) return 0;
        return br_ecdsa_i31_vrfy_asn1(&br_ec_p256_m31, h, 32, &pk->key.ec, r->sig, r->sig_len) == 1;
    }
    if (pk->key_type != BR_KEYTYPE_RSA || pk->key.rsa.nlen < 256) return 0;
    uint8_t out[32];
    if (!br_rsa_i31_pkcs1_vrfy(r->sig, r->sig_len, BR_HASH_OID_SHA256, 32, &pk->key.rsa, out)) return 0;
    return ct_equal(out, h, 32);
}

/* "XIZ13sign" ‖ archive_id ‖ u32(segment) ‖ SHA-256(directory signed part) ‖ u64(previous_footer) ‖
 * i64(time) ‖ previous ‖ algorithm ‖ public_key ‖ label (u8 length + bytes). */
static void build_message(wbuf *w, const uint8_t id[16], uint32_t segment, const uint8_t *dir_signed, size_t dir_len,
                          uint64_t previous_footer, const sig_record *r) {
    uint8_t h[32];
    sha256(dir_signed, dir_len, h);
    wb_put(w, "XIZ13sign", 9);
    wb_put(w, id, 16);
    wb_u32(w, segment);
    wb_put(w, h, 32);
    wb_u64(w, previous_footer);
    wb_u64(w, (uint64_t)r->time);
    wb_put(w, r->previous, 32);
    wb_u8(w, r->algorithm);
    wb_put(w, r->key, r->key_len);
    wb_u8(w, r->label_len);
    wb_put(w, r->label, r->label_len);
}

int signature_message(wbuf *w, const uint8_t id[16], uint32_t segment, const uint8_t *dir_signed, size_t dir_len,
                      uint64_t previous_footer, const uint8_t *sig, size_t sig_len, const uint8_t **signature64) {
    sig_record r;
    if (!record_parse(sig, sig_len, &r)) return 0;
    build_message(w, id, segment, dir_signed, dir_len, previous_footer, &r);
    if (signature64) *signature64 = r.algorithm == 1 ? r.sig : NULL;
    return !w->oom;
}

int xiz_signature_count(const xiz_archive *a, uint32_t *count) {
    if (!a || !count) return XIZ_E_ARG;
    *count = a->segments;
    return XIZ_OK;
}

/* Directories of every segment, oldest first. */
typedef struct {
    footer ft;
    directory dir;
} seg_dir;

static int load_segments(xiz_archive *a, seg_dir **out, uint32_t *n, xiz_error *err) {
    seg_dir *s = calloc(a->segments, sizeof *s);
    if (!s) return FAIL(XIZ_E_NOMEM, "out of memory");
    uint64_t at = a->footer_offset;
    footer f = a->ft;
    for (uint32_t k = a->segments; k-- > 0;) {
        uint8_t *b = malloc((size_t)f.cat_csize);
        if (!b) { free(s); return FAIL(XIZ_E_NOMEM, "out of memory"); }
        int rc = src_read(a, f.cat_offset, b, (size_t)f.cat_csize, err);
        uint8_t h[32];
        if (!rc) {
            sha256(b, (size_t)f.cat_csize, h);
            if (!ct_equal(h, f.cat_sha, 32)) rc = FAIL(XIZ_E_CORRUPT, "directory %u SHA-256 mismatch", k);
        }
        if (!rc) rc = directory_parse(b, (size_t)f.cat_csize, &s[k].dir, &a->ar, err);
        free(b);
        if (rc) { free(s); return rc; }
        s[k].ft = f;
        (void)at;
        if (k == 0) break;
        uint8_t fb[XIZ_FOOTER];
        if ((rc = src_read(a, f.previous, fb, sizeof fb, err)) || (rc = footer_parse(fb, &f, err))) { free(s); return rc; }
        at = f.previous;
    }
    *out = s;
    *n = a->segments;
    return XIZ_OK;
}

int xiz_get_signature(xiz_archive *a, uint32_t segment, xiz_signature *o, xiz_error *err) {
    if (!a || !o || segment >= a->segments) return FAIL(XIZ_E_ARG, "no segment %u", segment);
    memset(o, 0, sizeof *o);
    o->segment = segment;
    if (!a->has_dir) return XIZ_OK;
    seg_dir *s = NULL;
    uint32_t n = 0;
    TRY(load_segments(a, &s, &n, err));
    uint8_t previous[32] = {0};
    for (uint32_t k = 0; k <= segment; k++) {
        const directory *d = &s[k].dir;
        sig_record r;
        int is_signed = d->signature_len && record_parse(d->signature, d->signature_len, &r);
        /* A record of an algorithm this reader does not know (§13.5): signed, not verified. */
        int unknown = !is_signed && d->signature_len && (d->signature[0] < 1 || d->signature[0] > 4);
        uint8_t chained[32] = {0};
        int valid = 0, chain_ok = 0;
        if (is_signed) {
            wbuf m = {0};
            build_message(&m, a->sb.id, k, d->raw, d->signed_len, s[k].ft.previous, &r);
            if (m.oom) { wb_free(&m); free(s); return FAIL(XIZ_E_NOMEM, "out of memory"); }
            valid = sig_verify(&r, m.p, m.n);
            chain_ok = memcmp(r.previous, previous, 32) == 0;
            wb_put(&m, r.sig, r.sig_len);
            sha256(m.p, m.n, chained);
            wb_free(&m);
        }
        if (k == segment && unknown) {
            o->is_signed = 1;
            o->unknown_algorithm = 1;
            o->algorithm = d->signature[0];
        }
        if (k == segment && !unknown) {
            o->is_signed = is_signed;
            o->valid = valid;
            o->chained = chain_ok;
            if (is_signed) {
                memcpy(o->label, r.label, r.label_len);
                o->label[r.label_len] = 0;
                o->algorithm = r.algorithm;
                if (r.algorithm == 1) memcpy(o->public_key, r.pk, 32);
                else if (r.algorithm == 4) { memcpy(o->public_key, r.pk, 32); sha256(r.pk, 32 + XIZ_MLDSA_PUBLICKEY, o->key_sha256); }
                else { sha256(r.cert, r.cert_len, o->certificate_sha256); o->chain_count = r.chain_count; }
                o->time = r.time;
                o->has_timestamp = r.token_len > 0;
                o->timestamp_length = r.token_len;
                memcpy(o->chained_digest, chained, 32);
            }
        }
        memcpy(previous, chained, 32);  /* zeros after an unsigned segment */
    }
    free(s);
    return XIZ_OK;
}

/* ------------------------------------------------------------------ inclusion */

static int load_leaves(xiz_archive *a, uint8_t (**leaves)[32], xiz_error *err) {
    const directory *d = &a->dir;
    if (!a->has_dir || d->version < 2 || d->leaf_count == 0)
        return FAIL(XIZ_E_UNSUPPORTED, "this archive has no inclusion tree (XIZ 1.3 directory version 2)");
    uint8_t (*l)[32] = malloc((size_t)d->leaf_count * 32);
    if (!l) return FAIL(XIZ_E_NOMEM, "out of memory");
    int rc = src_read(a, d->leaf_offset, l, (size_t)d->leaf_count * 32, err);
    if (rc) { free(l); return rc; }
    *leaves = l;
    return XIZ_OK;
}

int xiz_check_tree(xiz_archive *a, xiz_error *err) {
    if (!a) return FAIL(XIZ_E_ARG, "no archive");
    uint8_t (*l)[32];
    TRY(load_leaves(a, &l, err));
    uint8_t root[32];
    merkle_root((const uint8_t(*)[32])l, a->dir.leaf_count, root);
    int ok = memcmp(root, a->dir.root, 32) == 0;
    for (uint32_t i = 1; ok && i < a->dir.leaf_count; i++)
        if (memcmp(l[i - 1], l[i], 32) > 0) return free(l), FAIL(XIZ_E_CORRUPT, "leaf table is not sorted");
    free(l);
    return ok ? XIZ_OK : FAIL(XIZ_E_CORRUPT, "leaf table does not lead to the directory's Merkle root");
}

int xiz_check_inclusion(xiz_archive *a, size_t index, uint32_t *leaf_index, xiz_error *err) {
    if (!a || index >= a->cat.n_entries) return FAIL(XIZ_E_ARG, "no entry %zu", index);
    const entry_rec *e = &a->cat.entries[index];
    uint8_t salt[16], sha[32];
    if (!entry_proof_data(a, e, salt, sha)) return FAIL(XIZ_E_UNSUPPORTED, "%s has no proof data", e->path);
    TRY(xiz_check_tree(a, err));
    wbuf w = {0};
    leaf_data(&w, salt, e->path, e->path_len, e->type, e->size, sha);
    if (w.oom) { wb_free(&w); return FAIL(XIZ_E_NOMEM, "out of memory"); }
    uint8_t leaf[32];
    merkle_leaf(w.p, w.n, leaf);
    wb_free(&w);
    uint8_t (*l)[32];
    TRY(load_leaves(a, &l, err));
    int rc = FAIL(XIZ_E_NOT_FOUND, "%s: leaf not in the tree", e->path);
    for (uint32_t i = 0; i < a->dir.leaf_count; i++)
        if (memcmp(l[i], leaf, 32) == 0) {
            if (leaf_index) *leaf_index = i;
            rc = XIZ_OK;
            break;
        }
    free(l);
    return rc;
}

/* ------------------------------------------------------------------ xiz-proof-1 (JSON) */

typedef enum { J_NULL, J_BOOL, J_NUM, J_STR, J_ARR, J_OBJ } jtype;
typedef struct jval jval;
struct jval {
    jtype t;
    double num;
    char *str;
    size_t len;
    jval **items;
    char **keys;
    size_t n;
};

typedef struct {
    const char *p, *end;
    arena *ar;
    int depth;
} jparser;

static void jws(jparser *j) {
    while (j->p < j->end && (*j->p == ' ' || *j->p == '\t' || *j->p == '\n' || *j->p == '\r')) j->p++;
}

static int hexv(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static void put_utf8(wbuf *w, uint32_t cp) {
    if (cp < 0x80) wb_u8(w, (uint8_t)cp);
    else if (cp < 0x800) { wb_u8(w, (uint8_t)(0xC0 | (cp >> 6))); wb_u8(w, (uint8_t)(0x80 | (cp & 0x3F))); }
    else if (cp < 0x10000) {
        wb_u8(w, (uint8_t)(0xE0 | (cp >> 12)));
        wb_u8(w, (uint8_t)(0x80 | ((cp >> 6) & 0x3F)));
        wb_u8(w, (uint8_t)(0x80 | (cp & 0x3F)));
    } else {
        wb_u8(w, (uint8_t)(0xF0 | (cp >> 18)));
        wb_u8(w, (uint8_t)(0x80 | ((cp >> 12) & 0x3F)));
        wb_u8(w, (uint8_t)(0x80 | ((cp >> 6) & 0x3F)));
        wb_u8(w, (uint8_t)(0x80 | (cp & 0x3F)));
    }
}

static int jstring(jparser *j, char **out, size_t *len) {
    if (j->p >= j->end || *j->p != '"') return 0;
    j->p++;
    wbuf w = {0};
    while (j->p < j->end && *j->p != '"') {
        char c = *j->p++;
        if ((unsigned char)c < 0x20) { wb_free(&w); return 0; }
        if (c != '\\') { wb_u8(&w, (uint8_t)c); continue; }
        if (j->p >= j->end) break;
        c = *j->p++;
        switch (c) {
        case '"': case '\\': case '/': wb_u8(&w, (uint8_t)c); break;
        case 'b': wb_u8(&w, 8); break;
        case 'f': wb_u8(&w, 12); break;
        case 'n': wb_u8(&w, 10); break;
        case 'r': wb_u8(&w, 13); break;
        case 't': wb_u8(&w, 9); break;
        case 'u': {
            uint32_t cp = 0;
            for (int i = 0; i < 4; i++) {
                int v = j->p < j->end ? hexv(*j->p++) : -1;
                if (v < 0) { wb_free(&w); return 0; }
                cp = cp << 4 | (uint32_t)v;
            }
            if (cp >= 0xD800 && cp < 0xDC00 && j->end - j->p >= 6 && j->p[0] == '\\' && j->p[1] == 'u') {
                uint32_t lo = 0;
                int okv = 1;
                for (int i = 0; i < 4; i++) {
                    int v = hexv(j->p[2 + i]);
                    if (v < 0) okv = 0;
                    lo = lo << 4 | (uint32_t)(v < 0 ? 0 : v);
                }
                if (okv && lo >= 0xDC00 && lo < 0xE000) {
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    j->p += 6;
                }
            }
            put_utf8(&w, cp);
            break;
        }
        default: wb_free(&w); return 0;
        }
    }
    if (j->p >= j->end || w.oom) { wb_free(&w); return 0; }
    j->p++;
    *out = arena_dup(j->ar, w.p ? (const void *)w.p : "", w.n, 1);
    *len = w.n;
    wb_free(&w);
    return *out != NULL;
}

static jval *jvalue(jparser *j);

static jval *jnew(jparser *j, jtype t) {
    jval *v = arena_alloc(j->ar, sizeof *v);
    if (v) { memset(v, 0, sizeof *v); v->t = t; }
    return v;
}

static int jpush(jparser *j, jval *v, char *key, jval *item) {
    jval **ni = arena_alloc(j->ar, (v->n + 1) * sizeof *ni);
    char **nk = arena_alloc(j->ar, (v->n + 1) * sizeof *nk);
    if (!ni || !nk) return 0;
    if (v->n) { memcpy(ni, v->items, v->n * sizeof *ni); memcpy(nk, v->keys, v->n * sizeof *nk); }
    ni[v->n] = item;
    nk[v->n] = key;
    v->items = ni;
    v->keys = nk;
    v->n++;
    return 1;
}

static jval *jvalue(jparser *j) {
    if (++j->depth > 32) return NULL;
    jws(j);
    if (j->p >= j->end) return NULL;
    jval *v = NULL;
    char c = *j->p;
    if (c == '{' || c == '[') {
        int obj = c == '{';
        v = jnew(j, obj ? J_OBJ : J_ARR);
        if (!v) return NULL;
        j->p++;
        jws(j);
        if (j->p < j->end && *j->p == (obj ? '}' : ']')) { j->p++; j->depth--; return v; }
        for (;;) {
            char *key = NULL;
            size_t kl;
            jws(j);
            if (obj) {
                if (!jstring(j, &key, &kl)) return NULL;
                jws(j);
                if (j->p >= j->end || *j->p != ':') return NULL;
                j->p++;
            }
            jval *item = jvalue(j);
            if (!item || !jpush(j, v, key, item)) return NULL;
            jws(j);
            if (j->p >= j->end) return NULL;
            if (*j->p == ',') { j->p++; continue; }
            if (*j->p == (obj ? '}' : ']')) { j->p++; break; }
            return NULL;
        }
    } else if (c == '"') {
        v = jnew(j, J_STR);
        if (!v || !jstring(j, &v->str, &v->len)) return NULL;
    } else if (c == '-' || (c >= '0' && c <= '9')) {
        v = jnew(j, J_NUM);
        if (!v) return NULL;
        char buf[64];
        size_t k = 0;
        while (j->p < j->end && k < sizeof buf - 1 && strchr("+-.0123456789eE", *j->p)) buf[k++] = *j->p++;
        buf[k] = 0;
        v->num = strtod(buf, NULL);
    } else if (j->end - j->p >= 4 && !memcmp(j->p, "true", 4)) { v = jnew(j, J_BOOL); if (v) v->num = 1; j->p += 4; }
    else if (j->end - j->p >= 5 && !memcmp(j->p, "false", 5)) { v = jnew(j, J_BOOL); j->p += 5; }
    else if (j->end - j->p >= 4 && !memcmp(j->p, "null", 4)) { v = jnew(j, J_NULL); j->p += 4; }
    j->depth--;
    return v;
}

static const jval *jget(const jval *o, const char *key, jtype t) {
    if (!o || o->t != J_OBJ) return NULL;
    for (size_t i = 0; i < o->n; i++)
        if (strcmp(o->keys[i], key) == 0) return o->items[i]->t == t ? o->items[i] : NULL;
    return NULL;
}

static int unhex(const char *s, size_t n, uint8_t *out, size_t want) {
    if (n != want * 2) return 0;
    for (size_t i = 0; i < want; i++) {
        int h = hexv(s[2 * i]), l = hexv(s[2 * i + 1]);
        if (h < 0 || l < 0) return 0;
        out[i] = (uint8_t)(h << 4 | l);
    }
    return 1;
}

static int b64v(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+' || c == '-') return 62;
    if (c == '/' || c == '_') return 63;
    return -1;
}

static int unbase64(const char *s, size_t n, wbuf *out) {
    uint32_t acc = 0;
    int bits = 0;
    for (size_t i = 0; i < n; i++) {
        if (s[i] == '=') break;
        if (s[i] == '\n' || s[i] == '\r') continue;
        int v = b64v(s[i]);
        if (v < 0) return 0;
        acc = acc << 6 | (uint32_t)v;
        bits += 6;
        if (bits >= 8) { bits -= 8; wb_u8(out, (uint8_t)(acc >> bits)); }
    }
    return !out->oom;
}

static uint64_t parse_u64(const char *s, int *ok) {
    uint64_t v = 0;
    *ok = *s != 0;
    for (; *s; s++) {
        if (*s < '0' || *s > '9' || v > (UINT64_MAX - 9) / 10) { *ok = 0; return 0; }
        v = v * 10 + (uint64_t)(*s - '0');
    }
    return v;
}

int xiz_verify_proof(const char *json, size_t json_len, const uint8_t *content, size_t content_len,
                     xiz_proof_result *o, xiz_error *err) {
    if (!json || !o) return FAIL(XIZ_E_ARG, "missing argument");
    memset(o, 0, sizeof *o);
    arena ar = {0};
    jparser j = {json, json + json_len, &ar, 0};
    jval *root = jvalue(&j);
    int rc = XIZ_OK;
    wbuf dirb = {0}, sigb = {0}, full = {0}, leafd = {0}, msg = {0};
    uint8_t (*path)[32] = NULL;
    const jval *fmt = jget(root, "format", J_STR), *aid = jget(root, "archive_id", J_STR),
               *seg = jget(root, "segment", J_NUM), *pf = jget(root, "previous_footer", J_STR),
               *dir = jget(root, "directory", J_STR), *sig = jget(root, "signature", J_STR),
               *ent = jget(root, "entry", J_OBJ), *idx = jget(root, "index", J_NUM), *ts = jget(root, "tree_size", J_NUM),
               *ap = jget(root, "audit_path", J_ARR);
    const jval *ep = jget(ent, "path", J_STR), *et = jget(ent, "type", J_NUM), *es = jget(ent, "size", J_STR),
               *esalt = jget(ent, "salt", J_STR), *esha = jget(ent, "sha256", J_STR);
    uint8_t id[16], salt[16], sha[32];
    int ok1, ok2;
    uint64_t prevf = pf ? parse_u64(pf->str, &ok1) : (ok1 = 0, 0);
    uint64_t size = es ? parse_u64(es->str, &ok2) : (ok2 = 0, 0);
    if (!root || !fmt || strcmp(fmt->str, "xiz-proof-1") != 0 || !aid || !unhex(aid->str, aid->len, id, 16) || !seg ||
        !ok1 || !dir || !sig || !ent || !ep || !et || !ok2 || !esalt || !unhex(esalt->str, esalt->len, salt, 16) ||
        !esha || !unhex(esha->str, esha->len, sha, 32) || !idx || !ts || !ap || seg->num < 0 || idx->num < 0 ||
        ts->num < 1 || et->num < 0 || et->num > 2 || !unbase64(dir->str, dir->len, &dirb) ||
        !unbase64(sig->str, sig->len, &sigb)) {
        rc = FAIL(XIZ_E_ARG, "not an xiz-proof-1 document");
        goto out;
    }
    path = malloc((ap->n + 1) * 32);
    if (!path) { rc = FAIL(XIZ_E_NOMEM, "out of memory"); goto out; }
    for (size_t i = 0; i < ap->n; i++)
        if (ap->items[i]->t != J_STR || !unhex(ap->items[i]->str, ap->items[i]->len, path[i], 32)) {
            rc = FAIL(XIZ_E_ARG, "audit path");
            goto out;
        }
    /* The directory: its signed part plus an empty signature and a CRC, to reuse the parser. */
    wb_put(&full, dirb.p, dirb.n);
    wb_u32(&full, 0);
    if (full.oom) { rc = FAIL(XIZ_E_NOMEM, "out of memory"); goto out; }
    wb_u32(&full, xiz_crc32c(0, full.p, full.n));
    directory d;
    if (full.oom || directory_parse(full.p, full.n, &d, &ar, NULL) != XIZ_OK || d.signed_len != dirb.n || d.version < 2) {
        rc = FAIL(XIZ_E_CORRUPT, "proof directory");
        goto out;
    }
    snprintf(o->path, sizeof o->path, "%s", ep->str);
    o->size = size;
    o->segment = (uint32_t)seg->num;
    uint8_t got[32];
    sha256(content ? (const void *)content : "", content_len, got);
    if (et->num == XIZ_TYPE_DIRECTORY) memset(got, 0, 32);
    o->content_matches = ct_equal(got, sha, 32) && (et->num != XIZ_TYPE_FILE || content_len == size);
    leaf_data(&leafd, salt, ep->str, ep->len, (uint8_t)et->num, size, sha);
    uint8_t leaf[32], r[32];
    merkle_leaf(leafd.p, leafd.n, leaf);
    o->in_tree = merkle_root_from_path(leaf, (uint64_t)idx->num, (uint64_t)ts->num, (const uint8_t(*)[32])path, ap->n, r) &&
                 memcmp(r, d.root, 32) == 0 && (uint64_t)ts->num == d.leaf_count;
    sig_record rec;
    if (sigb.n && record_parse(sigb.p, sigb.n, &rec)) {
        build_message(&msg, id, o->segment, dirb.p, dirb.n, prevf, &rec);
        o->is_signed = !msg.oom && sig_verify(&rec, msg.p, msg.n);
        memcpy(o->signer, rec.label, rec.label_len);
        o->signer[rec.label_len] = 0;
        o->algorithm = rec.algorithm;
        if (rec.algorithm == 1) memcpy(o->signer_key, rec.pk, 32);
        else if (rec.algorithm == 4) sha256(rec.pk, 32 + XIZ_MLDSA_PUBLICKEY, o->signer_key);
        else sha256(rec.cert, rec.cert_len, o->signer_key);
        o->signed_at = rec.time;
    }
out:
    free(path);
    wb_free(&dirb);
    wb_free(&sigb);
    wb_free(&full);
    wb_free(&leafd);
    wb_free(&msg);
    arena_free(&ar);
    return rc;
}
