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
