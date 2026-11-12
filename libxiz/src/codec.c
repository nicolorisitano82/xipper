/* Frame codecs: zstd (with dictionaries, §12), LZMA2 / ARM64 + LZMA2 (§14), brunsli JPEG (§16,
 * when built with XIZ_JPEG), Apple's LZRAVEN / LZMESH (§18, macOS 27 or later) and documents with
 * their Deflate streams split by preflate (§19, when built with XIZ_PREFLATE). Every decoder
 * writes into a buffer of exactly the declared size and rejects any other length (§4.2). */
#include "internal.h"

#define ZSTD_STATIC_LINKING_ONLY
#include "zstd.h"
#include "lzma.h"
#ifdef XIZ_HAVE_JPEG
#include <brunsli/decode.h>
#endif
#ifdef __APPLE__
#include <compression.h>
#endif
#ifdef XIZ_HAVE_PREFLATE
#include <xpf.h>
#endif

int zstd_decode_frame(const uint8_t *src, size_t n, uint8_t *dst, size_t usize, const void *ddict, xiz_error *err) {
    /* Exactly one zstd frame (§1, §4.2): no trailing frames or skippable frames. */
    size_t fs = ZSTD_findFrameCompressedSize(src, n);
    if (ZSTD_isError(fs)) return FAIL(XIZ_E_CORRUPT, "invalid zstd frame (%s)", ZSTD_getErrorName(fs));
    if (fs != n) return FAIL(XIZ_E_CORRUPT, "data after the zstd frame");
    ZSTD_DCtx *d = ZSTD_createDCtx();
    if (!d) return FAIL(XIZ_E_NOMEM, "out of memory");
    size_t r = ddict ? ZSTD_decompress_usingDDict(d, dst, usize, src, n, (const ZSTD_DDict *)ddict)
                     : ZSTD_decompressDCtx(d, dst, usize, src, n);
    ZSTD_freeDCtx(d);
    if (ZSTD_isError(r)) return FAIL(XIZ_E_CORRUPT, "zstd: %s", ZSTD_getErrorName(r));
    if (r != usize) return FAIL(XIZ_E_CORRUPT, "zstd frame decodes to %zu bytes, %zu declared", r, usize);
    return XIZ_OK;
}

int zstd_decode_catalog(const uint8_t *src, size_t n, uint64_t usize, uint8_t **out, xiz_error *err) {
    size_t fs = ZSTD_findFrameCompressedSize(src, n);
    if (ZSTD_isError(fs) || fs != n) return FAIL(XIZ_E_CORRUPT, "catalog is not one zstd frame");
    /* Grow the output as data arrives: a forged catalog_usize must not allocate 1 GiB up front. */
    size_t cap = (size_t)(usize < 1 << 20 ? usize : (uint64_t)1 << 20);
    if (cap == 0) cap = 1;
    uint8_t *buf = malloc(cap);
    ZSTD_DCtx *d = ZSTD_createDCtx();
    if (!buf || !d) { free(buf); ZSTD_freeDCtx(d); return FAIL(XIZ_E_NOMEM, "out of memory"); }
    ZSTD_DCtx_setParameter(d, ZSTD_d_windowLogMax, 27);
    ZSTD_inBuffer in = {src, n, 0};
    size_t have = 0;
    int rc = XIZ_OK;
    for (;;) {
        uint8_t extra;
        ZSTD_outBuffer o = {buf, cap, have};
        if (have == cap) {
            if (cap < usize) {
                size_t ncap = cap * 2 > usize ? (size_t)usize : cap * 2;
                uint8_t *nb = realloc(buf, ncap);
                if (!nb) { rc = FAIL(XIZ_E_NOMEM, "out of memory"); break; }
                buf = nb;
                cap = ncap;
                continue;
            }
            o.dst = &extra;  /* full: probe for excess output */
            o.size = 1;
            o.pos = 0;
        }
        size_t in_before = in.pos, out_before = o.pos;
        size_t r = ZSTD_decompressStream(d, &o, &in);
        if (ZSTD_isError(r)) { rc = FAIL(XIZ_E_CORRUPT, "catalog zstd: %s", ZSTD_getErrorName(r)); break; }
        if (o.dst == &extra) {
            if (o.pos) { rc = FAIL(XIZ_E_CORRUPT, "catalog larger than declared"); break; }
        } else {
            have = o.pos;
        }
        if (r == 0) {
            if (have != usize) rc = FAIL(XIZ_E_CORRUPT, "catalog decodes to %zu bytes, %llu declared", have, (unsigned long long)usize);
            else if (in.pos != in.size) rc = FAIL(XIZ_E_CORRUPT, "data after the catalog frame");
            break;
        }
        if (in.pos == in_before && o.pos == out_before) { rc = FAIL(XIZ_E_CORRUPT, "catalog zstd frame truncated"); break; }
    }
    ZSTD_freeDCtx(d);
    if (rc != XIZ_OK) { free(buf); return rc; }
    *out = buf;
    return XIZ_OK;
}

void *zstd_ddict_create(const uint8_t *dict, size_t n, uint16_t id, xiz_error *err) {
    if (n < 8 || rd32(dict) != 0xEC30A437u) { FAIL(XIZ_E_CORRUPT, "dictionary %u is not a zstd dictionary", id); return NULL; }
    if (ZSTD_getDictID_fromDict(dict, n) != id) { FAIL(XIZ_E_CORRUPT, "dictionary %u declares another ID", id); return NULL; }
    ZSTD_DDict *d = ZSTD_createDDict(dict, n);
    if (!d) FAIL(XIZ_E_CORRUPT, "dictionary %u cannot be loaded", id);
    return d;
}

void zstd_ddict_free(void *d) { ZSTD_freeDDict((ZSTD_DDict *)d); }

size_t zstd_bound(size_t n) { return ZSTD_compressBound(n); }

size_t zstd_encode(const uint8_t *src, size_t n, int level, uint8_t *dst, size_t cap) {
    ZSTD_CCtx *c = ZSTD_createCCtx();
    if (!c) return 0;
    ZSTD_CCtx_setParameter(c, ZSTD_c_compressionLevel, level);
    ZSTD_CCtx_setParameter(c, ZSTD_c_checksumFlag, 0);
    ZSTD_CCtx_setPledgedSrcSize(c, n);
    size_t r = ZSTD_compress2(c, dst, cap, src, n);
    ZSTD_freeCCtx(c);
    if (ZSTD_isError(r)) return 0;
    return r;
}

/* ------------------------------------------------------------------ LZMA2 (§14) */

int lzma2_decode_frame(const uint8_t *src, size_t n, uint8_t *dst, size_t usize, int arm64, xiz_error *err) {
    if (n < 2) return FAIL(XIZ_E_CORRUPT, "LZMA2 frame too short");
    uint8_t p = src[0];
    if (p > 28) return FAIL(XIZ_E_CORRUPT, "LZMA2 dictionary property %u above 64 MiB", p);
    uint32_t dict = (uint32_t)(2 | (p & 1)) << (p / 2 + 11);
    lzma_options_lzma o;
    memset(&o, 0, sizeof o);
    /* The output is at most usize bytes, so a larger window is never used: cap it. */
    o.dict_size = dict < usize ? dict : (uint32_t)usize;
    if (o.dict_size < LZMA_DICT_SIZE_MIN) o.dict_size = LZMA_DICT_SIZE_MIN;
    o.lc = 3; o.lp = 0; o.pb = 2;
    lzma_filter filters[2] = {{LZMA_FILTER_LZMA2, &o}, {LZMA_VLI_UNKNOWN, NULL}};
    lzma_stream s = LZMA_STREAM_INIT;
    if (lzma_raw_decoder(&s, filters) != LZMA_OK) return FAIL(XIZ_E_NOMEM, "LZMA2 decoder");
    s.next_in = src + 1;
    s.avail_in = n - 1;
    s.next_out = dst;
    s.avail_out = usize;
    lzma_ret r;
    do r = lzma_code(&s, LZMA_FINISH); while (r == LZMA_OK && s.avail_out > 0);
    int rc = XIZ_OK;
    if (r == LZMA_OK) {  /* output full, end marker not seen yet: anything more is too much */
        uint8_t extra;
        s.next_out = &extra;
        s.avail_out = 1;
        r = lzma_code(&s, LZMA_FINISH);
        if (s.avail_out == 0) rc = FAIL(XIZ_E_CORRUPT, "LZMA2 frame larger than declared");
    }
    if (rc == XIZ_OK) {
        if (r != LZMA_STREAM_END) rc = FAIL(XIZ_E_CORRUPT, "LZMA2 data invalid or truncated (%d)", (int)r);
        else if (s.total_out != usize) rc = FAIL(XIZ_E_CORRUPT, "LZMA2 frame decodes to %llu bytes, %zu declared",
                                                (unsigned long long)s.total_out, usize);
        else if (s.avail_in != 0) rc = FAIL(XIZ_E_CORRUPT, "data after the LZMA2 end marker");
    }
    lzma_end(&s);
    if (rc == XIZ_OK && arm64 && usize) lzma_bcj_arm64_decode(0, dst, usize);
    return rc;
}

/* ------------------------------------------------------------------ brunsli JPEG (§16) */

#ifdef XIZ_HAVE_JPEG
typedef struct { uint8_t *dst; size_t cap, len; } jpeg_sink;

static size_t jpeg_put(void *ctx, const uint8_t *buf, size_t size) {
    jpeg_sink *s = ctx;
    if (size > s->cap - s->len) return 0;  /* larger than declared: brunsli stops with an error */
    memcpy(s->dst + s->len, buf, size);
    s->len += size;
    return size;
}

int xiz_has_jpeg(void) { return 1; }

/* brunsli aborts the process on some internal checks: callers that read untrusted archives
 * should decode in a separate process (§16). */
int jpeg_decode_frame(const uint8_t *src, size_t n, uint8_t *dst, size_t usize, xiz_error *err) {
    jpeg_sink s = {dst, usize, 0};
    if (!DecodeBrunsli(n, src, &s, jpeg_put)) return FAIL(XIZ_E_CORRUPT, "brunsli data invalid, truncated or larger than declared");
    if (s.len != usize) return FAIL(XIZ_E_CORRUPT, "brunsli frame decodes to %zu bytes, %zu declared", s.len, usize);
    return XIZ_OK;
}
#else
int xiz_has_jpeg(void) { return 0; }

int jpeg_decode_frame(const uint8_t *src, size_t n, uint8_t *dst, size_t usize, xiz_error *err) {
    (void)src; (void)n; (void)dst; (void)usize;
    return FAIL(XIZ_E_UNSUPPORTED, "brunsli JPEG frames: this libxiz was built without XIZ_JPEG");
}
#endif

/* ------------------------------------------------------------------ LZRAVEN / LZMESH (§18) */

#ifdef __APPLE__
int xiz_has_apple_codecs(void) {
    if (__builtin_available(macOS 27, *)) return 1;
    return 0;
}

int apple_decode_frame(const uint8_t *src, size_t n, uint8_t *dst, size_t usize, int codec, xiz_error *err) {
    if (__builtin_available(macOS 27, *)) {
        if (n == 0) return FAIL(XIZ_E_CORRUPT, "empty Apple-codec frame");
        /* One byte of room more than declared, so a stream that decodes to more is caught. */
        uint8_t *buf = malloc(usize + 1);
        if (!buf) return FAIL(XIZ_E_NOMEM, "out of memory");
        size_t got = compression_decode_buffer(buf, usize + 1, src, n, NULL,
                                               codec == CODEC_LZRAVEN ? COMPRESSION_LZRAVEN : COMPRESSION_LZMESH);
        if (got == usize) memcpy(dst, buf, usize);
        free(buf);
        if (got != usize) return FAIL(XIZ_E_CORRUPT, "Apple-codec frame decodes to %zu bytes, %zu declared", got, usize);
        return XIZ_OK;
    }
    (void)src; (void)n; (void)dst; (void)usize; (void)codec;
    return FAIL(XIZ_E_UNSUPPORTED, "LZRAVEN and LZMESH frames need macOS 27 or later");
}
#else
int xiz_has_apple_codecs(void) { return 0; }

int apple_decode_frame(const uint8_t *src, size_t n, uint8_t *dst, size_t usize, int codec, xiz_error *err) {
    (void)src; (void)n; (void)dst; (void)usize; (void)codec;
    return FAIL(XIZ_E_UNSUPPORTED, "LZRAVEN and LZMESH frames exist only on macOS 27 or later");
}
#endif

/* ------------------------------------------------------------------ preflate documents (§19) */

#define XPF_MAX_SPLIT ((size_t)256 << 20)

#ifdef XIZ_HAVE_PREFLATE
int xiz_has_preflate(void) { return 1; }

static uint32_t crc32_iso(uint32_t crc, const uint8_t *p, size_t n) {
    static uint32_t table[256];
    static int ready;
    if (!ready) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[i] = c;
        }
        ready = 1;
    }
    crc = ~crc;
    while (n--) crc = table[(crc ^ *p++) & 0xFF] ^ (crc >> 8);
    return ~crc;
}

typedef struct { uint8_t *dst; size_t cap, len; } out_t;

static int put(out_t *o, const uint8_t *p, size_t n) {
    if (n > o->cap - o->len) return 0;
    if (n) memcpy(o->dst + o->len, p, n);
    o->len += n;
    return 1;
}

static int put_be32(out_t *o, uint32_t v) {
    uint8_t b[4] = {(uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v};
    return put(o, b, 4);
}

/* Rebuilds the file from its split form (§19) into dst (exactly usize bytes). */
static int rebuild(const uint8_t *s, size_t n, uint8_t *dst, size_t usize, xiz_error *err) {
#define BAD() FAIL(XIZ_E_CORRUPT, "damaged Deflate recompression data")
    if (n < 8 || memcmp(s, "XPF1", 4) != 0) return BAD();
    size_t count = rd32(s + 4), at = 8;
    if (count > n / 5) return BAD();
    /* First pass: sizes of the two areas. */
    size_t data = 0, diff = 0, p = at;
    for (size_t i = 0; i < count; i++) {
        if (p + 1 > n) return BAD();
        uint8_t type = s[p++];
        if (type == 0) { if (p + 4 > n) return BAD(); data += rd32(s + p); p += 4; }
        else if (type == 1) { if (p + 8 > n) return BAD(); data += rd32(s + p); diff += rd32(s + p + 4); p += 8; }
        else if (type == 2) {
            if (p + 4 > n) return BAD();
            size_t c = rd32(s + p); p += 4;
            if (c < 1 || c > (n - p) / 4) return BAD();
            p += 4 * c;
            if (p + 14 > n) return BAD();
            data += (size_t)rd32(s + p + 2) + rd32(s + p + 6); diff += rd32(s + p + 10); p += 14;
        } else return BAD();
        if (data > n || diff > n) return BAD();
    }
    if (data + diff != n - p) return BAD();
    size_t d = p, r = p + data;
    out_t o = {dst, usize, 0};
    p = at;
    for (size_t i = 0; i < count; i++) {
        uint8_t type = s[p++];
        if (type == 0) {
            size_t l = rd32(s + p); p += 4;
            if (!put(&o, s + d, l)) return BAD();
            d += l;
        } else if (type == 1) {
            size_t u = rd32(s + p), k = rd32(s + p + 4); p += 8;
            xpf_buffer b = {NULL, 0};
            if (!xpf_reencode(s + r, k, s + d, u, &b)) return BAD();
            int ok = put(&o, b.data, b.size);
            xpf_free(&b);
            if (!ok) return BAD();
            d += u; r += k;
        } else {
            size_t c = rd32(s + p); p += 4;
            const uint8_t *lens = s + p; p += 4 * c;
            const uint8_t *hdr = s + p;
            size_t t = rd32(s + p + 2), u = rd32(s + p + 6), k = rd32(s + p + 10); p += 14;
            xpf_buffer b = {NULL, 0};
            if (!xpf_reencode(s + r, k, s + d + t, u, &b)) return BAD();
            /* The zlib stream: header, rebuilt Deflate, trailer; cut into IDAT chunks. */
            size_t zlen = 2 + b.size + t, total = 0;
            for (size_t j = 0; j < c; j++) total += rd32(lens + 4 * j);
            uint8_t *z = total == zlen ? malloc(zlen) : NULL;
            if (!z) { xpf_free(&b); return BAD(); }
            memcpy(z, hdr, 2); memcpy(z + 2, b.data, b.size); memcpy(z + 2 + b.size, s + d, t);
            xpf_free(&b);
            size_t zat = 0;
            int ok = 1;
            for (size_t j = 0; j < c && ok; j++) {
                uint32_t len = rd32(lens + 4 * j);
                uint32_t crc = crc32_iso(crc32_iso(0, (const uint8_t *)"IDAT", 4), z + zat, len);
                ok = put_be32(&o, len) && put(&o, (const uint8_t *)"IDAT", 4) && put(&o, z + zat, len) && put_be32(&o, crc);
                zat += len;
            }
            free(z);
            if (!ok) return BAD();
            d += t + u; r += k;
        }
    }
    if (o.len != usize) return FAIL(XIZ_E_CORRUPT, "preflate frame rebuilds %zu bytes, %zu declared", o.len, usize);
    return XIZ_OK;
#undef BAD
}

/* brunsli-like caveat: preflate decodes untrusted records in this process (§19 recommends isolation). */
int preflate_decode_frame(const uint8_t *src, size_t n, uint8_t *dst, size_t usize, xiz_error *err) {
    if (n <= 5) return FAIL(XIZ_E_CORRUPT, "preflate frame too short");
    size_t split = rd32(src + 1);
    if (split > XPF_MAX_SPLIT) return FAIL(XIZ_E_LIMIT, "preflate split form of %zu bytes (limit 256 MiB)", split);
    uint8_t *buf = malloc(split ? split : 1);
    if (!buf) return FAIL(XIZ_E_NOMEM, "out of memory");
    int rc;
    if (src[0] == 1) rc = zstd_decode_frame(src + 5, n - 5, buf, split, NULL, err);
    else if (src[0] == 2) rc = lzma2_decode_frame(src + 5, n - 5, buf, split, 0, err);
    else rc = FAIL(XIZ_E_CORRUPT, "preflate frame: inner codec %u", src[0]);
    if (rc == XIZ_OK) rc = rebuild(buf, split, dst, usize, err);
    free(buf);
    return rc;
}
#else
int xiz_has_preflate(void) { return 0; }

int preflate_decode_frame(const uint8_t *src, size_t n, uint8_t *dst, size_t usize, xiz_error *err) {
    (void)src; (void)n; (void)dst; (void)usize;
    return FAIL(XIZ_E_UNSUPPORTED, "preflate frames: this libxiz was built without XIZ_PREFLATE");
}
#endif

/* ------------------------------------------------------------------ OpenZL tables (§21) */

#ifdef XIZ_HAVE_OPENZL
#include "openzl/zl_decompress.h"

int xiz_has_openzl(void) { return 1; }

/* One OpenZL frame (universal decoder): exactly usize bytes, content checksum checked. */
int openzl_decode_frame(const uint8_t *src, size_t n, uint8_t *dst, size_t usize, xiz_error *err) {
    ZL_Report r = ZL_getDecompressedSize(src, n);
    if (ZL_isError(r) || ZL_validResult(r) != usize) return FAIL(XIZ_E_CORRUPT, "OpenZL frame size");
    ZL_DCtx *d = ZL_DCtx_create();
    if (!d) return FAIL(XIZ_E_NOMEM, "OpenZL context");
    ZL_DCtx_setParameter(d, ZL_DParam_checkContentChecksum, ZL_TernaryParam_enable);
    r = ZL_DCtx_decompress(d, dst, usize, src, n);
    ZL_DCtx_free(d);
    if (ZL_isError(r) || ZL_validResult(r) != usize) return FAIL(XIZ_E_CORRUPT, "OpenZL frame does not decode");
    return XIZ_OK;
}
#else
int xiz_has_openzl(void) { return 0; }

int openzl_decode_frame(const uint8_t *src, size_t n, uint8_t *dst, size_t usize, xiz_error *err) {
    (void)src; (void)n; (void)dst; (void)usize;
    return FAIL(XIZ_E_UNSUPPORTED, "OpenZL frames: this libxiz was built without XIZ_OPENZL");
}
#endif
