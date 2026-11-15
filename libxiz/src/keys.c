/* Keys block (§6.2, §13.3): password stanzas, recipients, threshold groups and custodian shares. */
#include "internal.h"

#include "monocypher.h"
#include "mlkem.h"

static int kdf_acceptable(uint32_t mem, uint32_t it, uint32_t par) {
    return mem >= 19456 && mem <= 2097152 && it >= 1 && it <= 10 && par >= 1 && par <= 16;
}

/* ------------------------------------------------------------------ Shamir over GF(2^8) */

static uint8_t gf_mul(uint8_t a, uint8_t b) {
    uint8_t r = 0;
    for (int i = 0; i < 8; i++) {  /* constant time: no table lookups indexed by secrets */
        r ^= (uint8_t)(a & (uint8_t)(0u - (b & 1)));
        uint8_t hi = (uint8_t)(0u - (a >> 7));
        a = (uint8_t)((a << 1) ^ (hi & 0x1B));
        b >>= 1;
    }
    return r;
}

static uint8_t gf_inv(uint8_t a) {  /* a^254 */
    uint8_t r = 1, x = a;
    for (int e = 254; e; e >>= 1) {
        if (e & 1) r = gf_mul(r, x);
        x = gf_mul(x, x);
    }
    return r;
}

/* Lagrange interpolation at 0 of k shares (x distinct, non-zero). */
static void shamir_combine(const uint8_t *xs, const uint8_t (*ys)[32], size_t k, uint8_t out[32]) {
    memset(out, 0, 32);
    for (size_t i = 0; i < k; i++) {
        uint8_t basis = 1;
        for (size_t j = 0; j < k; j++) {
            if (j == i) continue;
            basis = gf_mul(basis, gf_mul(xs[j], gf_inv((uint8_t)(xs[j] ^ xs[i]))));
        }
        for (int b = 0; b < 32; b++) out[b] ^= gf_mul(ys[i][b], basis);
    }
}

/* ------------------------------------------------------------------ helpers */

typedef struct {
    const uint8_t *sb;          /* superblock bytes 0..60 */
    const xiz_open_options *opt;
    const char **passwords;
    size_t n_passwords;
} ctx_t;

/* Opens `nonce ‖ ciphertext ‖ tag` at body[header_end..] with `kek`; aad = sb[0..60] ‖ type ‖ body[..header_end]. */
static int open_box(const ctx_t *c, uint8_t type, const uint8_t *body, size_t len, size_t header_end,
                    const uint8_t kek[32], uint8_t *plain, size_t *plain_len) {
    if (len < header_end + 28) return 0;
    size_t clen = len - header_end - 28;
    uint8_t *aad = malloc(61 + header_end);
    if (!aad) return 0;
    memcpy(aad, c->sb, 60);
    aad[60] = type;
    memcpy(aad + 61, body, header_end);
    memcpy(plain, body + header_end + 12, clen);
    int ok = aes_gcm_open(kek, body + header_end, aad, 61 + header_end, plain, clen, body + len - 16);
    free(aad);
    if (ok) *plain_len = clen;
    return ok;
}

/* ------------------------------------------------------------------ X-Wing (§17) */

/* X-Wing (draft-connolly-cfrg-xwing-kem): ML-KEM-768 + X25519. The secret key is a 32-byte seed,
 * expanded with SHAKE-256 into the ML-KEM seeds d, z and the X25519 key. */
typedef struct {
    uint8_t pk[XIZ_MLKEM_PUBLICKEY + 32];  /* pk_M ‖ pk_X: the 1216-byte public key */
    uint8_t sk_m[XIZ_MLKEM_SECRETKEY];
    uint8_t sk_x[32];
    uint8_t id[8];                         /* first 8 bytes of SHA-256(pk) */
} xwing_key;

static int xwing_expand(const uint8_t seed[32], xwing_key *k) {
    uint8_t e[96];
    xiz_mlkem768_shake256(e, sizeof e, seed, 32);
    int rc = xiz_mlkem768_keypair_derand(k->pk, k->sk_m, e);
    memcpy(k->sk_x, e + 64, 32);
    crypto_x25519_public_key(k->pk + XIZ_MLKEM_PUBLICKEY, k->sk_x);
    uint8_t h[32];
    sha256(k->pk, sizeof k->pk, h);
    memcpy(k->id, h, 8);
    secure_zero(e, sizeof e);
    return rc == 0;
}

/* Shared secret for a 1120-byte ciphertext ct_M ‖ ct_X. A damaged ciphertext gives another secret. */
static int xwing_decap(const xwing_key *k, const uint8_t ct[1120], uint8_t ss[32]) {
    static const uint8_t label[6] = {0x5c, 0x2e, 0x2f, 0x2f, 0x5e, 0x5c};  /* "\\.//^\\" */
    uint8_t in[32 + 32 + 32 + 32 + 6];
    if (xiz_mlkem768_dec(in, ct, k->sk_m) != 0) return 0;
    crypto_x25519(in + 32, k->sk_x, ct + XIZ_MLKEM_CIPHERTEXT);
    memcpy(in + 64, ct + XIZ_MLKEM_CIPHERTEXT, 32);
    memcpy(in + 96, k->pk + XIZ_MLKEM_PUBLICKEY, 32);
    memcpy(in + 128, label, 6);
    xiz_mlkem768_sha3_256(ss, in, sizeof in);
    secure_zero(in, sizeof in);
    return 1;
}

/* KEKs for a credential header at body[p..]: kind 1 password (44 bytes), kind 2 X25519 (40 bytes),
 * kind 3 X-Wing (1128 bytes: ciphertext, key id). */
typedef struct {
    uint8_t (*keks)[32];
    size_t n;
    size_t header;
} keks_t;

static int credential_keks(const ctx_t *c, int kind, const uint8_t *body, size_t len, size_t p, keks_t *out,
                           xiz_error *err) {
    out->n = 0;
    out->keks = NULL;
    if (kind == 1) {
        if (len < p + 44) return FAIL(XIZ_E_CORRUPT, "keys block: password stanza truncated");
        const uint8_t *h = body + p;
        uint32_t mem = rd32(h), it = rd32(h + 4), par = rd32(h + 8);
        if (!kdf_acceptable(mem, it, par))
            return FAIL(XIZ_E_LIMIT, "Argon2id parameters out of bounds (memory %u KiB, %u iterations, parallelism %u)",
                        mem, it, par);
        out->header = 44;
        if (!c->n_passwords) return XIZ_OK;
        out->keks = calloc(c->n_passwords, 32);
        if (!out->keks) return FAIL(XIZ_E_NOMEM, "out of memory");
        for (size_t i = 0; i < c->n_passwords; i++) {
            if (argon2id_kek(c->passwords[i], h + 12, mem, it, par, out->keks[out->n]) != 0)
                return FAIL(XIZ_E_NOMEM, "Argon2id failed (memory)");
            out->n++;
        }
        return XIZ_OK;
    }
    if (kind == 3) {
        if (len < p + 1128) return FAIL(XIZ_E_CORRUPT, "keys block: post-quantum stanza truncated");
        out->header = 1128;
        const uint8_t *ct = body + p, *id = body + p + 1120;
        if (!c->opt || !c->opt->pq_identity_count) return XIZ_OK;
        out->keks = calloc(c->opt->pq_identity_count, 32);
        xwing_key *k = malloc(sizeof *k);
        if (!out->keks || !k) { free(k); return FAIL(XIZ_E_NOMEM, "out of memory"); }
        for (size_t i = 0; i < c->opt->pq_identity_count; i++) {
            uint8_t ss[32];
            if (!xwing_expand(c->opt->pq_identities[i], k) || memcmp(k->id, id, 8) != 0) continue;
            if (!xwing_decap(k, ct, ss)) continue;
            hkdf_sha256(ss, 32, id, 8, "xiz/1.7/xwing", out->keks[out->n++], 32);
            secure_zero(ss, 32);
        }
        secure_zero(k, sizeof *k);
        free(k);
        return XIZ_OK;
    }
    if (kind != 2) return FAIL(XIZ_E_UNSUPPORTED, "keys block: credential kind %d", kind);
    if (len < p + 40) return FAIL(XIZ_E_CORRUPT, "keys block: public-key stanza truncated");
    out->header = 40;
    const uint8_t *eph = body + p, *id = body + p + 32;
    if (!c->opt || !c->opt->identity_count) return XIZ_OK;
    out->keks = calloc(c->opt->identity_count, 32);
    if (!out->keks) return FAIL(XIZ_E_NOMEM, "out of memory");
    for (size_t i = 0; i < c->opt->identity_count; i++) {
        uint8_t pub[32], h[32], shared[32], salt[64];
        crypto_x25519_public_key(pub, c->opt->identities[i]);
        sha256(pub, 32, h);
        if (memcmp(h, id, 8) != 0) continue;
        crypto_x25519(shared, c->opt->identities[i], eph);
        static const uint8_t zero[32];
        if (ct_equal(shared, zero, 32)) continue;  /* low-order point */
        memcpy(salt, eph, 32);
        memcpy(salt + 32, pub, 32);
        hkdf_sha256(shared, 32, salt, 64, "xiz/1.3/x25519", out->keks[out->n++], 32);
        secure_zero(shared, 32);
    }
    return XIZ_OK;
}

static int label_end(const uint8_t *body, size_t len, size_t p, size_t *end, xiz_error *err) {
    if (p >= len || p + 1 + body[p] > len) return FAIL(XIZ_E_CORRUPT, "keys block: stanza label");
    *end = p + 1 + body[p];
    return XIZ_OK;
}

static const char *label_dup(arena *ar, const uint8_t *body, size_t p) {
    return arena_dup(ar, body + p + 1, body[p], 1);
}

static int add_bundle(keys_opened *out, const uint8_t *b, size_t n, xiz_error *err) {
    rbuf r;
    rb_init(&r, b, n);
    uint16_t count = rb_u16(&r);
    if (r.bad || rb_left(&r) != (size_t)count * 34) return FAIL(XIZ_E_CORRUPT, "keys block: key bundle");
    group_key *nk = realloc(out->keys, (out->n_keys + count + 1) * sizeof(group_key));
    if (!nk) return FAIL(XIZ_E_NOMEM, "out of memory");
    out->keys = nk;
    for (uint16_t i = 0; i < count; i++) {
        uint16_t g = rb_u16(&r);
        const uint8_t *k = rb_take(&r, 32);
        int dup = 0;
        for (size_t j = 0; j < out->n_keys; j++)
            if (out->keys[j].group == g) dup = 1;  /* first one wins */
        if (dup) continue;
        out->keys[out->n_keys].group = g;
        memcpy(out->keys[out->n_keys].key, k, 32);
        out->n_keys++;
    }
    return XIZ_OK;
}

typedef struct {
    uint8_t type;
    uint16_t len;
    const uint8_t *body;
} raw_stanza;

int keys_open(const uint8_t *block, size_t n, const uint8_t sb[XIZ_SUPERBLOCK], int has_dir,
              const xiz_open_options *opt, keys_opened *out, arena *ar, xiz_error *err) {
    memset(out, 0, sizeof *out);
    if (n < 10 || memcmp(block, "XKEY", 4) != 0) return FAIL(XIZ_E_CORRUPT, "keys block magic");
    if (rd32(block + n - 4) != xiz_crc32c(0, block, n - 4)) return FAIL(XIZ_E_CORRUPT, "keys block checksum mismatch");
    rbuf r;
    rb_init(&r, block, n - 4);
    r.at = 4;
    uint16_t count = rb_u16(&r);
    if (count > rb_left(&r) / 3) return FAIL(XIZ_E_CORRUPT, "keys block stanza count");
    raw_stanza *st = calloc(count + 1u, sizeof *st);
    out->stanzas = arena_alloc(ar, (count + 1u) * sizeof(stanza_info));
    if (!st || !out->stanzas) { free(st); return FAIL(XIZ_E_NOMEM, "out of memory"); }
    for (uint16_t i = 0; i < count; i++) {
        st[i].type = rb_u8(&r);
        st[i].len = rb_u16(&r);
        st[i].body = rb_take(&r, st[i].len);
    }
    if (r.bad || rb_left(&r) != 0) { free(st); return FAIL(XIZ_E_CORRUPT, "keys block layout"); }

    const char *pw[64];
    size_t npw = 0;
    if (opt && opt->password) pw[npw++] = opt->password;
    for (size_t i = 0; opt && i < opt->password_count && npw < 64; i++)
        if (opt->passwords[i]) pw[npw++] = opt->passwords[i];
    ctx_t c = {sb, opt, pw, npw};

    int rc = XIZ_OK;
    /* Shares opened per threshold id: x values and y. */
    uint8_t (*share_x)[255] = calloc(256, sizeof *share_x);
    uint8_t (*share_y)[255][32] = calloc(256, sizeof *share_y);
    int share_n[256] = {0};
    if (!share_x || !share_y) { free(share_x); free(share_y); free(st); return FAIL(XIZ_E_NOMEM, "out of memory"); }
    uint8_t plain[65536];
    size_t plain_len;
    keks_t kk = {0};

    for (uint16_t i = 0; i < count && rc == XIZ_OK; i++) {
        const uint8_t *b = st[i].body;
        size_t len = st[i].len;
        stanza_info *si = &out->stanzas[out->n_stanzas];
        memset(si, 0, sizeof *si);
        si->type = st[i].type;
        si->label = "";
        free(kk.keks);
        kk.keks = NULL;
        if (!has_dir && st[i].type == 1) {
            out->any_known = 1;
            out->n_stanzas++;
            if (len != 104) { rc = FAIL(XIZ_E_CORRUPT, "password stanza of %zu bytes", len); break; }
            uint32_t mem = rd32(b), it = rd32(b + 4), par = rd32(b + 8);
            if (!kdf_acceptable(mem, it, par)) {
                rc = FAIL(XIZ_E_LIMIT, "Argon2id parameters out of bounds (memory %u KiB, %u iterations, parallelism %u)",
                          mem, it, par);
                break;
            }
            uint8_t aad[61 + 44];
            memcpy(aad, sb, 60);
            aad[60] = 1;
            memcpy(aad + 61, b, 44);
            for (size_t p = 0; p < npw && !si->opened; p++) {
                uint8_t kek[32], key[32];
                if (argon2id_kek(pw[p], b + 12, mem, it, par, kek) != 0) { rc = FAIL(XIZ_E_NOMEM, "Argon2id failed"); break; }
                memcpy(key, b + 56, 32);
                if (aes_gcm_open(kek, b + 44, aad, sizeof aad, key, 32, b + 88)) {
                    si->opened = 1;
                    if (out->n_keys == 0) {
                        out->keys = malloc(sizeof(group_key));
                        if (!out->keys) { rc = FAIL(XIZ_E_NOMEM, "out of memory"); break; }
                        out->keys[0].group = 0;
                        memcpy(out->keys[0].key, key, 32);
                        out->n_keys = 1;
                    }
                }
                secure_zero(kek, 32);
                secure_zero(key, 32);
            }
            continue;
        }
        if (!has_dir || st[i].type < 2 || st[i].type > 7) continue;  /* unknown here: skipped (§6.2) */
        out->any_known = 1;
        out->n_stanzas++;
        switch (st[i].type) {
        case 2:
        case 3:
        case 6: {
            rc = credential_keks(&c, st[i].type == 2 ? 1 : st[i].type == 3 ? 2 : 3, b, len, 0, &kk, err);
            if (rc) break;
            size_t end = 0;
            if ((rc = label_end(b, len, kk.header, &end, err))) break;
            si->label = label_dup(ar, b, kk.header);
            for (size_t k = 0; k < kk.n && !si->opened; k++) {
                if (open_box(&c, st[i].type, b, len, end, kk.keks[k], plain, &plain_len)) {
                    si->opened = 1;
                    rc = add_bundle(out, plain, plain_len, err);
                }
            }
            break;
        }
        case 4: {
            if (len < 4) { rc = FAIL(XIZ_E_CORRUPT, "threshold stanza"); break; }
            size_t end = 0;
            if ((rc = label_end(b, len, 3, &end, err))) break;
            si->tid = b[0];
            si->k = b[1];
            si->n = b[2];
            si->label = label_dup(ar, b, 3);
            break;
        }
        case 5:
        case 7: {
            /* type 5: tid, x, kind, credential; type 7: tid, x, X-Wing credential */
            size_t cp = st[i].type == 5 ? 3 : 2;
            if (len < cp + 1) { rc = FAIL(XIZ_E_CORRUPT, "share stanza"); break; }
            rc = credential_keks(&c, st[i].type == 5 ? b[2] : 3, b, len, cp, &kk, err);
            if (rc) break;
            size_t end = 0;
            if ((rc = label_end(b, len, cp + kk.header, &end, err))) break;
            si->tid = b[0];
            si->x = b[1];
            si->label = label_dup(ar, b, cp + kk.header);
            for (size_t k = 0; k < kk.n && !si->opened; k++) {
                if (open_box(&c, st[i].type, b, len, end, kk.keks[k], plain, &plain_len)) {
                    si->opened = 1;
                    int t = b[0], dup = b[1] == 0;
                    for (int j = 0; j < share_n[t]; j++)
                        if (share_x[t][j] == b[1]) dup = 1;
                    if (plain_len == 32 && !dup && share_n[t] < 255) {
                        share_x[t][share_n[t]] = b[1];
                        memcpy(share_y[t][share_n[t]], plain, 32);
                        share_n[t]++;
                    }
                }
            }
            break;
        }
        }
    }
    free(kk.keks);
    /* Thresholds: k shares rebuild T, whose HKDF opens the threshold stanza's bundle. */
    for (size_t i = 0; i < out->n_stanzas && rc == XIZ_OK; i++) {
        stanza_info *si = &out->stanzas[i];
        if (si->type != 4) continue;
        int t = si->tid, have = share_n[t];
        if (have > 0 && have < si->k && !out->partial_threshold) out->partial_threshold = (int)i + 1;
        if (si->k < 2 || have < si->k) continue;
        /* Find the raw stanza again (same order, skipping unknown ones). */
        size_t seen = 0;
        for (uint16_t j = 0; j < count; j++) {
            if (!(has_dir ? (st[j].type >= 2 && st[j].type <= 7) : st[j].type == 1)) continue;
            if (seen++ != i) continue;
            uint8_t secret[32], kek[32];
            shamir_combine(share_x[t], (const uint8_t(*)[32])share_y[t], (size_t)si->k, secret);
            hkdf_sha256(secret, 32, sb + 16, 16, "xiz/1.3/threshold", kek, 32);
            size_t end = 4 + st[j].body[3];
            if (open_box(&c, 4, st[j].body, st[j].len, end, kek, plain, &plain_len)) {
                si->opened = 1;
                rc = add_bundle(out, plain, plain_len, err);
            }
            secure_zero(secret, 32);
            secure_zero(kek, 32);
            break;
        }
    }
    secure_zero(plain, sizeof plain);
    secure_zero(share_y, 256 * sizeof *share_y);
    free(share_y);
    free(share_x);
    free(st);
    if (rc != XIZ_OK) {
        if (out->keys) secure_zero(out->keys, out->n_keys * sizeof(group_key));
        free(out->keys);
        out->keys = NULL;
        out->n_keys = 0;
    }
    return rc;
}
