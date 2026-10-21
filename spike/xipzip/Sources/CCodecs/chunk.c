#include "CCodecs.h"
#include <string.h>

size_t xz_deflate_chunk_bound(size_t inLen) {
    // deflateBound for raw streams plus room for the 5-byte sync-flush marker
    return inLen + (inLen >> 12) + (inLen >> 14) + (inLen >> 25) + 64;
}

size_t xz_deflate_chunk(const uint8_t *in, size_t inLen,
                        const uint8_t *dict, size_t dictLen,
                        int level, int last,
                        uint8_t *out, size_t outCap) {
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
    return n;
}
