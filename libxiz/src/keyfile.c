/* Key files as Xipper writes them: X25519 and X-Wing identities (§13.3, §17), age identities (the
 * same keys), second factors (§24.3). */
#include "internal.h"

static int b64v(int c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '-' || c == '+') return 62;
    if (c == '_' || c == '/') return 63;
    return -1;
}

/* age's identities: Bech32 as in BIP 173 without the length limit, upper or lower case, HRP
 * "age-secret-key-pq-" (X-Wing seed) or "age-secret-key-" (X25519), 32 bytes. */
static int age_identity(const char *s, const char *end, int *pq, uint8_t out[32]) {
    static const char cs[] = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
    static const uint32_t gen[5] = {0x3b6a57b2u, 0x26508e6du, 0x1ea119fau, 0x3d4233ddu, 0x2a1462b3u};
    char low[128];
    size_t n = 0;
    int up = 0, lo = 0;
    for (; s + n < end && s[n] && s[n] != '\n' && s[n] != '\r' && s[n] != ' ' && s[n] != '\t'; n++) {
        if (n + 1 >= sizeof low) return 0;
        char c = s[n];
        if (c >= 'A' && c <= 'Z') { up = 1; c = (char)(c - 'A' + 'a'); }
        else if (c >= 'a' && c <= 'z') lo = 1;
        low[n] = c;
    }
    low[n] = 0;
    if (up && lo) return 0;
    char *sep = strrchr(low, '1');
    if (!sep || sep == low || (size_t)(low + n - sep - 1) < 6) return 0;
    size_t hl = (size_t)(sep - low);
    if (hl == 18 && !memcmp(low, "age-secret-key-pq-", 18)) *pq = 1;
    else if (hl == 15 && !memcmp(low, "age-secret-key-", 15)) *pq = 0;
    else return 0;
    uint32_t chk = 1;
#define POLY(x) do { uint32_t t_ = chk >> 25; chk = (chk & 0x1ffffffu) << 5 ^ (uint32_t)(x); \
                     for (int i_ = 0; i_ < 5; i_++) if ((t_ >> i_) & 1) chk ^= gen[i_]; } while (0)
    for (size_t i = 0; i < hl; i++) POLY((unsigned char)low[i] >> 5);
    POLY(0);
    for (size_t i = 0; i < hl; i++) POLY((unsigned char)low[i] & 31);
    size_t nd = (size_t)(low + n - sep - 1), k = 0;
    uint32_t acc = 0;
    int bits = 0;
    for (size_t i = 0; i < nd; i++) {
        const char *q = strchr(cs, sep[1 + i]);
        if (!q || !sep[1 + i]) return 0;
        uint32_t v = (uint32_t)(q - cs);
        POLY(v);
        if (i + 6 >= nd) continue;  /* the checksum */
        acc = acc << 5 | v;
        bits += 5;
        if (bits >= 8) { bits -= 8; if (k == 32) return 0; out[k++] = (uint8_t)(acc >> bits); }
    }
#undef POLY
    int ok = chk == 1 && k == 32 && bits < 5 && (acc & ((1u << bits) - 1)) == 0;
    secure_zero(low, sizeof low);
    return ok;
}

/* 32 bytes of base64url (or base64) without padding; `strict`: nothing but blanks may follow and
 * the unused bits must be zero (factor files). */
static int b64_32(const char *p, const char *end, int strict, uint8_t out[32]) {
    uint8_t buf[48];
    size_t n = 0;
    uint32_t acc = 0;
    int bits = 0;
    for (; p < end && b64v((unsigned char)*p) >= 0; p++) {
        if (n == sizeof buf) return 0;
        acc = acc << 6 | (uint32_t)b64v((unsigned char)*p);
        bits += 6;
        if (bits >= 8) { bits -= 8; buf[n++] = (uint8_t)(acc >> bits); }
    }
    if (strict) {
        while (p < end && (*p == ' ' || *p == '\t' || *p == '\r')) p++;
        if (p < end && *p != '\n') { secure_zero(buf, sizeof buf); return 0; }
        if (acc & ((1u << bits) - 1)) { secure_zero(buf, sizeof buf); return 0; }
    }
    int ok = n == 32;
    if (ok) memcpy(out, buf, 32);
    secure_zero(buf, sizeof buf);
    return ok;
}

static const char *find(const char *s, const char *end, const char *needle) {
    size_t l = strlen(needle);
    for (; s + l <= end; s++)
        if (memcmp(s, needle, l) == 0) return s;
    return NULL;
}

int xiz_parse_secret(const char *text, size_t len, uint8_t out[32]) {
    if (!text || !out) return XIZ_E_ARG;
    const char *end = text + len;
    for (const char *line = text; line < end;) {
        const char *nl = memchr(line, '\n', (size_t)(end - line));
        const char *le = nl ? nl : end;
        const char *g = find(line, le, "AGE-SECRET-KEY-");
        if (!g) g = find(line, le, "age-secret-key-");
        int pq = 0;
        if (g) return age_identity(g, le, &pq, out) ? (pq ? XIZ_SECRET_XWING : XIZ_SECRET_X25519) : XIZ_E_ARG;
        const char *p;
        if ((p = find(line, le, "XIZ-SECRET-KEY-PQ-1-")))
            return b64_32(p + 20, le, 0, out) ? XIZ_SECRET_XWING : XIZ_E_ARG;
        if ((p = find(line, le, "XIZ-SECRET-KEY-1-")))
            return b64_32(p + 17, le, 0, out) ? XIZ_SECRET_X25519 : XIZ_E_ARG;
        p = line;
        while (p < le && (*p == ' ' || *p == '\t')) p++;
        if ((size_t)(le - p) >= 13 && memcmp(p, "XIZ-FACTOR-1-", 13) == 0)
            return b64_32(p + 13, le, 1, out) ? XIZ_SECRET_FACTOR : XIZ_E_ARG;
        line = nl ? nl + 1 : end;
    }
    return XIZ_E_NOT_FOUND;
}

/* ------------------------------------------------------------------ public keys, new keys */

#include "monocypher.h"

static const char b64url[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/* base64url without padding; returns the length written (NUL included in cap). */
static size_t b64_encode(const uint8_t *in, size_t n, char *out, size_t cap) {
    size_t o = 0;
    uint32_t acc = 0;
    int bits = 0;
    for (size_t i = 0; i < n; i++) {
        acc = acc << 8 | in[i];
        bits += 8;
        while (bits >= 6) {
            bits -= 6;
            if (o + 1 < cap) out[o] = b64url[(acc >> bits) & 63];
            o++;
        }
    }
    if (bits) {
        if (o + 1 < cap) out[o] = b64url[(acc << (6 - bits)) & 63];
        o++;
    }
    if (cap) out[o < cap ? o : cap - 1] = 0;
    return o;
}

static size_t b64_decode(const char *p, const char *end, uint8_t *out, size_t cap) {
    size_t n = 0;
    uint32_t acc = 0;
    int bits = 0;
    for (; p < end && b64v((unsigned char)*p) >= 0; p++) {
        acc = acc << 6 | (uint32_t)b64v((unsigned char)*p);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (n < cap) out[n] = (uint8_t)(acc >> bits);
            n++;
        }
    }
    return n;
}

/* Bech32 (BIP 173, constant 1) without the length limit: hrp, then the data as bytes. */
static size_t bech32_decode(const char *s, size_t len, char *hrp, size_t hrp_cap, uint8_t *out, size_t cap) {
    static const char cs[] = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
    static const uint32_t gen[5] = {0x3b6a57b2u, 0x26508e6du, 0x1ea119fau, 0x3d4233ddu, 0x2a1462b3u};
    size_t sep = len;
    for (size_t i = len; i-- > 0;)
        if (s[i] == '1') { sep = i; break; }
    if (sep == len || sep == 0 || sep + 7 > len || sep >= hrp_cap) return 0;
    uint32_t chk = 1;
#define POLY(x) do { uint32_t t_ = chk >> 25; chk = (chk & 0x1ffffffu) << 5 ^ (uint32_t)(x); \
                     for (int i_ = 0; i_ < 5; i_++) if ((t_ >> i_) & 1) chk ^= gen[i_]; } while (0)
    for (size_t i = 0; i < sep; i++) {
        char c = s[i];
        if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
        hrp[i] = c;
    }
    hrp[sep] = 0;
    for (size_t i = 0; i < sep; i++) POLY((unsigned char)hrp[i] >> 5);
    POLY(0);
    for (size_t i = 0; i < sep; i++) POLY((unsigned char)hrp[i] & 31);
    size_t n = 0, nd = len - sep - 1;
    uint32_t acc = 0;
    int bits = 0;
    for (size_t i = 0; i < nd; i++) {
        char c = s[sep + 1 + i];
        if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
        const char *q = c ? strchr(cs, c) : NULL;
        if (!q) return 0;
        uint32_t v = (uint32_t)(q - cs);
        POLY(v);
        if (i + 6 >= nd) continue;
        acc = acc << 5 | v;
        bits += 5;
        if (bits >= 8) {
            bits -= 8;
            if (n < cap) out[n] = (uint8_t)(acc >> bits);
            n++;
        }
    }
#undef POLY
    if (chk != 1 || bits >= 5 || (acc & ((1u << bits) - 1))) return 0;
    return n;
}

int xiz_parse_public_key(const char *text, size_t len, uint8_t *out, size_t cap, size_t *out_len) {
    if (!text || !out || cap < 1216) return XIZ_E_ARG;
    while (len && (text[0] == ' ' || text[0] == '\t' || text[0] == '\r' || text[0] == '\n')) { text++; len--; }
    while (len && (text[len - 1] == ' ' || text[len - 1] == '\t' || text[len - 1] == '\r' || text[len - 1] == '\n')) len--;
    size_t n = 0;
    int kind = 0;
    if (len > 6 && !memcmp(text, "xizpk1", 6)) {
        n = b64_decode(text + 6, text + len, out, cap);
        kind = n == 32 && 6 + b64_encode(out, 32, NULL, 0) == len ? XIZ_SECRET_X25519 : 0;
    } else if (len > 6 && !memcmp(text, "xizpq1", 6)) {
        n = b64_decode(text + 6, text + len, out, cap);
        kind = n == 1216 && 6 + b64_encode(out, 1216, NULL, 0) == len ? XIZ_SECRET_XWING : 0;
    } else if (len > 4 && (!memcmp(text, "age1", 4) || !memcmp(text, "AGE1", 4))) {
        char hrp[16];
        n = bech32_decode(text, len, hrp, sizeof hrp, out, cap);
        if (!strcmp(hrp, "age") && n == 32) kind = XIZ_SECRET_X25519;
        else if (!strcmp(hrp, "age1pq") && n == 1216) kind = XIZ_SECRET_XWING;
    }
    if (!kind) return XIZ_E_ARG;
    if (out_len) *out_len = n;
    return kind;
}

static int public_text(int kind, const uint8_t secret[32], char *pub, size_t cap) {
    if (kind == XIZ_SECRET_XWING) {
        uint8_t *pk = malloc(1216);
        if (!pk) return XIZ_E_NOMEM;
        int ok = xwing_public(secret, pk);
        if (ok && cap > 6) { memcpy(pub, "xizpq1", 6); b64_encode(pk, 1216, pub + 6, cap - 6); }
        free(pk);
        return ok && cap >= 6 + 1622 + 1 ? XIZ_OK : XIZ_E_ARG;
    }
    uint8_t pk[32];
    crypto_x25519_public_key(pk, secret);
    if (cap < 6 + 43 + 1) return XIZ_E_ARG;
    memcpy(pub, "xizpk1", 6);
    b64_encode(pk, 32, pub + 6, cap - 6);
    return XIZ_OK;
}

int xiz_public_from_secret(const char *text, size_t len, char *pub, size_t cap) {
    uint8_t s[32];
    int kind = xiz_parse_secret(text, len, s);
    if (kind != XIZ_SECRET_X25519 && kind != XIZ_SECRET_XWING) return kind < 0 ? kind : XIZ_E_ARG;
    int rc = public_text(kind, s, pub, cap);
    secure_zero(s, 32);
    return rc;
}

int xiz_generate_identity(int post_quantum, char *secret, size_t secret_cap, char *pub, size_t pub_cap) {
    uint8_t s[32];
    if (xiz_random(s, 32)) return XIZ_E_IO;
    const char *prefix = post_quantum ? "XIZ-SECRET-KEY-PQ-1-" : "XIZ-SECRET-KEY-1-";
    size_t pl = strlen(prefix);
    if (secret_cap < pl + 44) { secure_zero(s, 32); return XIZ_E_ARG; }
    memcpy(secret, prefix, pl);
    b64_encode(s, 32, secret + pl, secret_cap - pl);
    int rc = public_text(post_quantum ? XIZ_SECRET_XWING : XIZ_SECRET_X25519, s, pub, pub_cap);
    secure_zero(s, 32);
    return rc;
}

int xiz_generate_factor(char *text, size_t cap, uint8_t out[32]) {
    uint8_t s[32];
    if (cap < 13 + 44 || xiz_random(s, 32)) return XIZ_E_ARG;
    memcpy(text, "XIZ-FACTOR-1-", 13);
    b64_encode(s, 32, text + 13, cap - 13);
    if (out) memcpy(out, s, 32);
    secure_zero(s, 32);
    return XIZ_OK;
}
