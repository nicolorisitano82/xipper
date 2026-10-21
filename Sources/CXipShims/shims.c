#include "CXipShims.h"
#include <stdlib.h>
#include <string.h>
#include <limits.h>

// MARK: - deflate chunk

size_t xs_deflate_chunk_bound(size_t inLen) {
    // deflateBound for raw streams plus room for the 5-byte sync-flush marker
    return inLen + (inLen >> 12) + (inLen >> 14) + (inLen >> 25) + 64;
}

size_t xs_deflate_chunk(const uint8_t *in, size_t inLen,
                        const uint8_t *dict, size_t dictLen,
                        int level, int last,
                        uint8_t *out, size_t outCap) {
    if (inLen > UINT_MAX || outCap > UINT_MAX) return 0;
    z_stream s;
    memset(&s, 0, sizeof s);
    if (deflateInit2(&s, level, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY) != Z_OK) return 0;
    if (dict && dictLen) deflateSetDictionary(&s, dict, (uInt)dictLen);
    s.next_in = (Bytef *)in;
    s.avail_in = (uInt)inLen;
    s.next_out = out;
    s.avail_out = (uInt)outCap;
    int r = deflate(&s, last ? Z_FINISH : Z_SYNC_FLUSH);
    size_t n = outCap - s.avail_out;
    deflateEnd(&s);
    if (last ? r != Z_STREAM_END : r != Z_OK) return 0;
    if (!last && s.avail_in != 0) return 0;
    return n;
}

uint32_t xs_crc32_combine(uint32_t crc1, uint32_t crc2, uint64_t len2) {
    return (uint32_t)crc32_combine(crc1, crc2, (z_off_t)len2);
}

// MARK: - inflate

struct xs_inflate { z_stream z; };

xs_inflate *xs_inflate_new(int gzip) {
    xs_inflate *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    if (inflateInit2(&s->z, gzip ? 15 + 16 : -15) != Z_OK) { free(s); return NULL; }
    return s;
}

int xs_inflate_run(xs_inflate *s, const uint8_t *in, size_t inLen, size_t *inUsed,
                   uint8_t *out, size_t outCap, size_t *outUsed) {
    uInt ia = inLen > UINT_MAX ? UINT_MAX : (uInt)inLen;
    uInt oa = outCap > UINT_MAX ? UINT_MAX : (uInt)outCap;
    s->z.next_in = (Bytef *)in;
    s->z.avail_in = ia;
    s->z.next_out = out;
    s->z.avail_out = oa;
    int r = inflate(&s->z, Z_NO_FLUSH);
    *inUsed = ia - s->z.avail_in;
    *outUsed = oa - s->z.avail_out;
    if (r == Z_NEED_DICT) r = Z_DATA_ERROR;
    return r;
}

int xs_inflate_reset(xs_inflate *s) { return inflateReset(&s->z); }

void xs_inflate_free(xs_inflate *s) {
    if (!s) return;
    inflateEnd(&s->z);
    free(s);
}

// MARK: - bunzip

struct xs_bunzip { bz_stream b; };

xs_bunzip *xs_bunzip_new(void) {
    xs_bunzip *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    if (BZ2_bzDecompressInit(&s->b, 0, 0) != BZ_OK) { free(s); return NULL; }
    return s;
}

int xs_bunzip_run(xs_bunzip *s, const uint8_t *in, size_t inLen, size_t *inUsed,
                  uint8_t *out, size_t outCap, size_t *outUsed) {
    unsigned ia = inLen > UINT_MAX ? UINT_MAX : (unsigned)inLen;
    unsigned oa = outCap > UINT_MAX ? UINT_MAX : (unsigned)outCap;
    s->b.next_in = (char *)in;
    s->b.avail_in = ia;
    s->b.next_out = (char *)out;
    s->b.avail_out = oa;
    int r = BZ2_bzDecompress(&s->b);
    *inUsed = ia - s->b.avail_in;
    *outUsed = oa - s->b.avail_out;
    return r;
}

int xs_bunzip_reset(xs_bunzip *s) {
    BZ2_bzDecompressEnd(&s->b);
    memset(&s->b, 0, sizeof s->b);
    return BZ2_bzDecompressInit(&s->b, 0, 0);
}

void xs_bunzip_free(xs_bunzip *s) {
    if (!s) return;
    BZ2_bzDecompressEnd(&s->b);
    free(s);
}

size_t xs_bzip2_compress(const uint8_t *in, size_t inLen, int level, uint8_t *out, size_t outCap) {
    if (inLen > UINT_MAX || outCap > UINT_MAX) return 0;
    unsigned n = (unsigned)outCap;
    if (BZ2_bzBuffToBuffCompress((char *)out, &n, (char *)in, (unsigned)inLen, level, 0, 0) != BZ_OK) return 0;
    return n;
}
