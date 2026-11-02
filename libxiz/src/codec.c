/* Frame codecs: zstd (with dictionaries, §12) and LZMA2 / ARM64 + LZMA2 (§14). Every decoder
 * writes into a buffer of exactly the declared size and rejects any other length (§4.2). */
#include "internal.h"

#define ZSTD_STATIC_LINKING_ONLY
#include "zstd.h"
#include "lzma.h"

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
