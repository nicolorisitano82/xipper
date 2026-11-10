/* Unit tests: primitives against published vectors, path helpers. */
#include "internal.h"

#include <stdio.h>

static int failures;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

typedef struct { char k[64], v[256]; int n; } kv_last;
static int kv_cb(void *ctx, const char *key, size_t klen, const char *val, size_t vlen) {
    kv_last *l = ctx;
    if (klen >= sizeof l->k || vlen >= sizeof l->v) return 1;
    memcpy(l->k, key, klen + 1);
    memcpy(l->v, val, vlen + 1);
    l->n++;
    return 0;
}
static int json(const char *s, kv_last *l) {
    memset(l, 0, sizeof *l);
    return json_flat_parse((const uint8_t *)s, strlen(s), kv_cb, l);
}

static void unhex(const char *s, uint8_t *out) {
    for (size_t i = 0; s[2 * i]; i++) {
        unsigned v;
        sscanf(s + 2 * i, "%2x", &v);
        out[i] = (uint8_t)v;
    }
}

int main(void) {
    uint8_t h[64], want[64];
    /* CRC-32C check value */
    CHECK(xiz_crc32c(0, "123456789", 9) == 0xE3069283u);
    /* SHA-256("abc") */
    sha256("abc", 3, h);
    unhex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", want);
    CHECK(memcmp(h, want, 32) == 0);
    /* RFC 5869 test case 1 */
    {
        uint8_t ikm[22], salt[13], okm[42];
        memset(ikm, 0x0b, 22);
        unhex("000102030405060708090a0b0c", salt);
        /* info 0xf0..0xf9 is not printable: use the generic path via a NUL-free string */
        const char info[] = "\xf0\xf1\xf2\xf3\xf4\xf5\xf6\xf7\xf8\xf9";
        hkdf_sha256(ikm, 22, salt, 13, info, okm, 42);
        uint8_t w[42];
        unhex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865", w);
        CHECK(memcmp(okm, w, 42) == 0);
    }
    /* AES-256-GCM, NIST/McGrew-Viega test case 16 (with AAD) */
    {
        uint8_t key[32], iv[12], pt[60], aad[20], ct[60], tag[16];
        unhex("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308", key);
        unhex("cafebabefacedbaddecaf888", iv);
        unhex("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39", pt);
        unhex("feedfacedeadbeeffeedfacedeadbeefabaddad2", aad);
        unhex("522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662", ct);
        unhex("76fc6ece0f4e1768cddf8853bb2d551b", tag);
        uint8_t buf[60], t[16];
        memcpy(buf, pt, 60);
        aes_gcm_seal(key, iv, aad, 20, buf, 60, t);
        CHECK(memcmp(buf, ct, 60) == 0 && memcmp(t, tag, 16) == 0);
        CHECK(aes_gcm_open(key, iv, aad, 20, buf, 60, tag) && memcmp(buf, pt, 60) == 0);
        memcpy(buf, ct, 60);
        buf[3] ^= 1;
        CHECK(!aes_gcm_open(key, iv, aad, 20, buf, 60, tag));
    }
    /* HMAC-SHA-256, RFC 4231 test case 2 is keyed with "Jefe" (4 bytes): our API takes 32-byte keys,
     * so check HMAC against a 32-byte key computed independently (RFC 4231 case 1 has 20 bytes). */
    {
        uint8_t key[32];
        memset(key, 0x0b, 32);
        hmac_ctx c;
        hmac_init(&c, key);
        hmac_update(&c, "Hi There", 8);
        hmac_final(&c, h);
        unhex("198a607eb44bfbc69903a0f1cf2bbdc5ba0aa3f3d9ae3c1c7a3b1696a0b68cf7", want);
        CHECK(memcmp(h, want, 32) == 0);
    }
    /* Merkle: empty tree, one leaf */
    {
        uint8_t r[32], e[32];
        merkle_root(NULL, 0, r);
        sha256("", 0, e);
        CHECK(memcmp(r, e, 32) == 0);
        uint8_t leaves[5][32];
        for (int i = 0; i < 5; i++) merkle_leaf((uint8_t *)&i, 1, leaves[i]);
        merkle_root((const uint8_t(*)[32])leaves, 5, r);
        /* audit path of leaf 4 in a 5-leaf tree: [root of leaves 0..3] */
        uint8_t p[1][32], got[32];
        merkle_root((const uint8_t(*)[32])leaves, 4, p[0]);
        CHECK(merkle_root_from_path(leaves[4], 4, 5, (const uint8_t(*)[32])p, 1, got) && memcmp(got, r, 32) == 0);
    }
    /* Windows names */
    {
        char out[64];
        xiz_windows_name("CON.txt", 7, out, sizeof out);
        CHECK(strcmp(out, "_CON.txt") == 0);
        xiz_windows_name("a:b?.", 5, out, sizeof out);
        CHECK(strcmp(out, "a_b_") == 0);
        xiz_windows_name("back\\slash", 10, out, sizeof out);
        CHECK(strcmp(out, "back_slash") == 0);
        xiz_windows_name("com1", 4, out, sizeof out);
        CHECK(strcmp(out, "_com1") == 0);
        xiz_windows_name("normal name", 11, out, sizeof out);
        CHECK(strcmp(out, "normal name") == 0);
    }
    {   /* §15 recovery record: add, damage, repair byte for byte; appending removes it. */
        const char *path = "unit-recovery.xiz";
        xiz_error err;
        xiz_writer *w;
        xiz_writer_options wo;
        memset(&wo, 0, sizeof wo);
        wo.level = 1;
        size_t n = 700000;
        uint8_t *data = malloc(n);
        uint32_t x = 12345;
        for (size_t i = 0; i < n; i++) { x = x * 1103515245u + 12345u; data[i] = (uint8_t)(x >> 16); }
        CHECK(xiz_writer_create(&w, path, &wo, 1, &err) == XIZ_OK);
        CHECK(xiz_writer_add_data(w, "r.bin", data, n, NULL, &err) == XIZ_OK);
        CHECK(xiz_writer_finish(w, &err) == XIZ_OK);
        xiz_recovery_info info;
        CHECK(xiz_recovery_info_file(path, &info, &err) == XIZ_E_NOT_FOUND);
        CHECK(xiz_recovery_add(path, 10, &info, &err) == XIZ_OK);
        CHECK(info.recovery_slices == (info.data_slices + 9) / 10);
        FILE *f = fopen(path, "rb");
        fseek(f, 0, SEEK_END);
        long size = ftell(f);
        uint8_t *orig = malloc((size_t)size), *bad = malloc((size_t)size);
        fseek(f, 0, SEEK_SET);
        CHECK(fread(orig, 1, (size_t)size, f) == (size_t)size);
        fclose(f);
        memcpy(bad, orig, (size_t)size);
        long offs[] = {0, 70, 300000, (long)info.protected_length - 20, size - 20};
        for (size_t i = 0; i < sizeof offs / sizeof *offs; i++) bad[offs[i]] ^= 0xFF;
        f = fopen(path, "wb");
        fwrite(bad, 1, (size_t)size, f);
        fclose(f);
        xiz_recovery_report r;
        CHECK(xiz_recovery_scrub(path, 0, &r, &err) == XIZ_OK);
        CHECK(r.has_record && r.damaged_data_slices == 3 && r.damaged_metadata == 1 && r.repairable && !r.repaired);
        CHECK(xiz_recovery_scrub(path, 1, &r, &err) == XIZ_OK && r.repaired);
        f = fopen(path, "rb");
        CHECK(fread(bad, 1, (size_t)size, f) == (size_t)size && memcmp(bad, orig, (size_t)size) == 0);
        fclose(f);
        xiz_archive *a;
        CHECK(xiz_open_file(&a, path, NULL, &err) == XIZ_OK);
        if (a) xiz_close(a);
        CHECK(xiz_writer_append(&w, path, &wo, &err) == XIZ_OK);
        CHECK(xiz_writer_add_data(w, "more.txt", "more", 4, NULL, &err) == XIZ_OK);
        CHECK(xiz_writer_finish(w, &err) == XIZ_OK);
        CHECK(xiz_recovery_info_file(path, &info, &err) == XIZ_E_NOT_FOUND);
        int removed = 1;
        CHECK(xiz_recovery_remove(path, &removed, &err) == XIZ_OK && !removed);
        free(data); free(orig); free(bad);
        remove(path);
    }
    /* Flat JSON (forensic records and inventory lines, §20.2): untrusted input. */
    {
        kv_last l;
        CHECK(json("{}", &l) == 0 && l.n == 0);
        CHECK(json(" { \"a\" : \"b\" , \"size\":12 } ", &l) == 0 && l.n == 2 && !strcmp(l.k, "size") && !strcmp(l.v, "12"));
        CHECK(json("{\"p\":\"citt\\u00e0\\/x\\n\"}", &l) == 0 && !strcmp(l.v, "citt\xc3\xa0/x\n"));
        CHECK(json("{\"p\":\"\\ud83d\\ude00\"}", &l) == 0 && !strcmp(l.v, "\xf0\x9f\x98\x80"));
        CHECK(json("{\"t\":true,\"f\":false,\"n\":null,\"x\":-1.5e3}", &l) == 0 && l.n == 4);
        const char *bad[] = {"", "{", "}", "[]", "{\"a\"}", "{\"a\":}", "{\"a\":\"b\"", "{\"a\":\"b\",}", "{\"a\":\"b\"} x",
                             "{\"a\":{}}", "{\"a\":[1]}", "{\"a\":\"\\u0000\"}", "{\"a\":\"\\ud800\"}", "{\"a\":\"\\udc00\"}",
                             "{\"a\":\"\\q\"}", "{\"a\":\"\x01\"}", "{\"a\":inf}", "{\"a\":nan}", "{\"a\":\"\\u12\"}", "{a:\"b\"}"};
        for (size_t i = 0; i < sizeof bad / sizeof *bad; i++) {
            if (json(bad[i], &l) == 0) { fprintf(stderr, "FAIL json accepted: %s\n", bad[i]); failures++; }
        }
    }
    if (failures) { fprintf(stderr, "%d failures\n", failures); return 1; }
    printf("unit: all passed\n");
    return 0;
}
