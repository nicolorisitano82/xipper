/* SHA-256, HMAC, HKDF, AES-256-GCM (BearSSL, constant time) and Argon2id (PHC reference). */
#include "internal.h"

#include "argon2.h"

void sha256_init(sha256_ctx *c) { br_sha256_init(c); }
void sha256_update(sha256_ctx *c, const void *d, size_t n) { br_sha256_update(c, d, n); }
void sha256_final(sha256_ctx *c, uint8_t out[32]) { br_sha256_out(c, out); }

void sha256(const void *d, size_t n, uint8_t out[32]) {
    br_sha256_context c;
    br_sha256_init(&c);
    br_sha256_update(&c, d, n);
    br_sha256_out(&c, out);
}

void hmac_init(hmac_ctx *c, const uint8_t key[32]) {
    br_hmac_key_context kc;
    br_hmac_key_init(&kc, &br_sha256_vtable, key, 32);
    br_hmac_init(c, &kc, 0);
    secure_zero(&kc, sizeof kc);
}
void hmac_update(hmac_ctx *c, const void *d, size_t n) { br_hmac_update(c, d, n); }
void hmac_final(hmac_ctx *c, uint8_t out[32]) {
    br_hmac_out(c, out);
    secure_zero(c, sizeof *c);
}

void hkdf_sha256(const uint8_t *ikm, size_t ikm_len, const uint8_t *salt, size_t salt_len, const char *info,
                 uint8_t *out, size_t out_len) {
    br_hkdf_context hc;
    /* BearSSL: BR_HKDF_NO_SALT means "HashLen zeros", as RFC 5869 says for an absent salt. */
    br_hkdf_init(&hc, &br_sha256_vtable, salt_len ? (const void *)salt : BR_HKDF_NO_SALT, salt_len);
    br_hkdf_inject(&hc, ikm, ikm_len);
    br_hkdf_flip(&hc);
    br_hkdf_produce(&hc, info, strlen(info), out, out_len);
    secure_zero(&hc, sizeof hc);
}

typedef struct {
    br_aes_ct64_ctr_keys aes;
    br_gcm_context gcm;
} gcm_state;

static void gcm_start(gcm_state *s, const uint8_t key[32], const uint8_t nonce[12], const uint8_t *aad,
                      size_t aad_len) {
    br_aes_ct64_ctr_init(&s->aes, key, 32);
    br_gcm_init(&s->gcm, &s->aes.vtable, br_ghash_ctmul64);
    br_gcm_reset(&s->gcm, nonce, 12);
    if (aad_len) br_gcm_aad_inject(&s->gcm, aad, aad_len);
    br_gcm_flip(&s->gcm);
}

void aes_gcm_seal(const uint8_t key[32], const uint8_t nonce[12], const uint8_t *aad, size_t aad_len, uint8_t *data,
                  size_t len, uint8_t tag[16]) {
    gcm_state s;
    gcm_start(&s, key, nonce, aad, aad_len);
    if (len) br_gcm_run(&s.gcm, 1, data, len);
    br_gcm_get_tag(&s.gcm, tag);
    secure_zero(&s, sizeof s);
}

int aes_gcm_open(const uint8_t key[32], const uint8_t nonce[12], const uint8_t *aad, size_t aad_len, uint8_t *data,
                 size_t len, const uint8_t tag[16]) {
    gcm_state s;
    gcm_start(&s, key, nonce, aad, aad_len);
    if (len) br_gcm_run(&s.gcm, 0, data, len);
    int ok = (int)br_gcm_check_tag(&s.gcm, tag);
    secure_zero(&s, sizeof s);
    if (!ok && len) secure_zero(data, len);  /* never hand out unauthenticated plaintext */
    return ok;
}

int argon2id_kek(const char *password, const uint8_t salt[32], uint32_t mem_kib, uint32_t iters, uint32_t par,
                 uint8_t out[32]) {
    size_t n = password ? strlen(password) : 0;
    int rc = argon2id_hash_raw(iters, mem_kib, par, password ? password : "", n, salt, 32, out, 32);
    return rc == ARGON2_OK ? 0 : -1;
}

/* ------------------------------------------------------------------ XIZ key schedule */

void keyset_derive(keyset *k, const uint8_t key[32], const uint8_t archive_id[16]) {
    hkdf_sha256(key, 32, archive_id, 16, "xiz/1/data", k->data, 32);
    hkdf_sha256(key, 32, archive_id, 16, "xiz/1/catalog", k->catalog, 32);
    hkdf_sha256(key, 32, archive_id, 16, "xiz/1/file-mac", k->mac, 32);
    hkdf_sha256(key, 32, archive_id, 16, "xiz/1.3/slots", k->slot, 32);
}

void frame_nonce(uint32_t index, uint8_t out[12]) {
    memset(out, 0, 4);
    wr64be(out + 4, index);
}

/* "XIZ1frame" ‖ archive_id ‖ u32(i) ‖ codec ‖ flags ‖ u16(dictionary) ‖ u32(usize) = 9+16+4+1+1+2+4 */
void frame_aad(const uint8_t id[16], uint32_t index, const frame_rec *f, uint8_t out[37]) {
    memcpy(out, "XIZ1frame", 9);
    memcpy(out + 9, id, 16);
    wr32(out + 25, index);
    out[29] = f->codec;
    out[30] = f->flags;
    wr16(out + 31, f->dict);
    wr32(out + 33, f->usize);
}

static void stream_nonce(uint32_t segment, int last, uint64_t counter, uint8_t n[12]) {
    n[0] = (uint8_t)(segment >> 16);
    n[1] = (uint8_t)(segment >> 8);
    n[2] = (uint8_t)segment;
    n[3] = last ? 1 : 0;
    wr64be(n + 4, counter);
}

int stream_open(const uint8_t key[32], const uint8_t *aad, size_t aad_len, uint32_t segment, const uint8_t *sealed,
                size_t n, uint8_t **plain, size_t *plain_len, xiz_error *err) {
    if (segment >= (1u << 24)) return FAIL(XIZ_E_CORRUPT, "segment number too large for a catalog nonce");
    const size_t step = XIZ_CATALOG_CHUNK + XIZ_TAG;
    if (n < XIZ_TAG) return FAIL(XIZ_E_AUTH, "encrypted catalog truncated");
    /* Chunk count: full chunks, then a final one (possibly empty) which carries `last`. */
    uint8_t *out = malloc(n ? n : 1);
    if (!out) return FAIL(XIZ_E_NOMEM, "out of memory");
    size_t start = 0, len = 0;
    uint64_t counter = 0;
    while (start < n) {
        size_t end = n - start > step ? start + step : n;
        int last = end == n;
        if (end - start < XIZ_TAG) { free(out); return FAIL(XIZ_E_AUTH, "encrypted catalog truncated"); }
        size_t clen = end - start - XIZ_TAG;
        uint8_t nonce[12];
        stream_nonce(segment, last, counter, nonce);
        memcpy(out + len, sealed + start, clen);
        if (!aes_gcm_open(key, nonce, aad, aad_len, out + len, clen, sealed + end - XIZ_TAG)) {
            free(out);
            return FAIL(XIZ_E_AUTH, "catalog chunk %llu does not authenticate (altered, truncated or wrong key)",
                        (unsigned long long)counter);
        }
        len += clen;
        start = end;
        counter++;
    }
    *plain = out;
    *plain_len = len;
    return XIZ_OK;
}

int stream_seal(const uint8_t key[32], const uint8_t *aad, size_t aad_len, uint32_t segment, const uint8_t *plain,
                size_t n, wbuf *out) {
    size_t start = 0;
    uint64_t counter = 0;
    do {
        size_t end = n - start > XIZ_CATALOG_CHUNK ? start + XIZ_CATALOG_CHUNK : n;
        uint8_t nonce[12], tag[16];
        stream_nonce(segment, end == n, counter, nonce);
        size_t at = out->n;
        wb_put(out, plain + start, end - start);
        if (out->oom) return XIZ_E_NOMEM;
        aes_gcm_seal(key, nonce, aad, aad_len, out->p + at, end - start, tag);
        wb_put(out, tag, 16);
        start = end;
        counter++;
    } while (start < n);
    return out->oom ? XIZ_E_NOMEM : XIZ_OK;
}
