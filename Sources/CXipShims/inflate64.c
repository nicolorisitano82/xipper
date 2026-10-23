// Deflate64 ("enhanced deflate", ZIP method 9) decoder, streaming. Written for Xipper from the
// format as 7-Zip, zlib's contrib/infback9 and PKWARE describe it: deflate with a 64 KiB window,
// length code 285 = 3 + 16 extra bits (up to 65538) and distance codes 30 and 31 (32769 and
// 49153, 14 extra bits). Huffman decoding is canonical, one bit at a time (as zlib's puff):
// Deflate64 is rare in practice, simplicity wins over speed.
//
// Streaming without rollback: a symbol (at most 60 bits) or a block header (at most ~300 bytes)
// is decoded only when enough input is buffered, or when the caller says the input is final.

#include "CXipShims.h"
#include <stdlib.h>
#include <string.h>

#define WSIZE 65536u
#define WMASK (WSIZE - 1)

struct huff {
    short count[16];
    short symbol[320];
};

enum { ST_HEADER, ST_STORED, ST_CODES, ST_DONE };

struct xs_inflate64 {
    uint64_t bitbuf;
    int bitcnt;
    const uint8_t *in, *end;
    uint8_t *out;
    size_t outlen, outcap;
    int state, last, error;
    uint32_t stored_left;
    uint32_t copy_left, copy_dist;
    uint64_t total;
    struct huff lencode, distcode;
    uint8_t window[WSIZE];
};

static const short len_base[29] = {3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                                   35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 3};
static const short len_extra[29] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 16};
static const unsigned dist_base[32] = {1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                                       257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                                       8193, 12289, 16385, 24577, 32769, 49153};
static const short dist_extra[32] = {0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                     7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14};

xs_inflate64 *xs_inflate64_new(void) {
    xs_inflate64 *s = calloc(1, sizeof(*s));
    return s;
}

void xs_inflate64_free(xs_inflate64 *s) { free(s); }

static size_t available(const xs_inflate64 *s) { return (size_t)(s->end - s->in) + (size_t)(s->bitcnt / 8); }

static int bits(xs_inflate64 *s, int n) {
    while (s->bitcnt < n) {
        if (s->in == s->end) { s->error = 1; return 0; }
        s->bitbuf |= (uint64_t)*s->in++ << s->bitcnt;
        s->bitcnt += 8;
    }
    int v = (int)(s->bitbuf & ((1ull << n) - 1));
    s->bitbuf >>= n;
    s->bitcnt -= n;
    return v;
}

static int decode(xs_inflate64 *s, const struct huff *h) {
    int code = 0, first = 0, index = 0;
    for (int len = 1; len < 16; len++) {
        code |= bits(s, 1);
        if (s->error) return -1;
        int count = h->count[len];
        if (code - count < first) return h->symbol[index + (code - first)];
        index += count;
        first += count;
        first <<= 1;
        code <<= 1;
    }
    return -1;
}

// Canonical code from lengths; < 0 when over-subscribed, > 0 when incomplete.
static int construct(struct huff *h, const short *length, int n) {
    short offs[16];
    memset(h->count, 0, sizeof(h->count));
    for (int i = 0; i < n; i++) h->count[length[i]]++;
    if (h->count[0] == n) return 0;
    int left = 1;
    for (int len = 1; len < 16; len++) {
        left <<= 1;
        left -= h->count[len];
        if (left < 0) return left;
    }
    offs[1] = 0;
    for (int len = 1; len < 15; len++) offs[len + 1] = offs[len] + h->count[len];
    for (int i = 0; i < n; i++)
        if (length[i] != 0) h->symbol[offs[length[i]]++] = (short)i;
    return left;
}

static void put(xs_inflate64 *s, uint8_t b) {
    s->out[s->outlen++] = b;
    s->window[s->total & WMASK] = b;
    s->total++;
}

static int fixed_tables(xs_inflate64 *s) {
    short lengths[320];
    int i = 0;
    for (; i < 144; i++) lengths[i] = 8;
    for (; i < 256; i++) lengths[i] = 9;
    for (; i < 280; i++) lengths[i] = 7;
    for (; i < 288; i++) lengths[i] = 8;
    construct(&s->lencode, lengths, 288);
    for (i = 0; i < 32; i++) lengths[i] = 5;
    construct(&s->distcode, lengths, 32);
    return 0;
}

static int dynamic_tables(xs_inflate64 *s) {
    static const short order[19] = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};
    short lengths[320];
    int nlen = bits(s, 5) + 257, ndist = bits(s, 5) + 1, ncode = bits(s, 4) + 4;
    if (s->error || nlen > 286 || ndist > 32) return -1;
    int i = 0;
    for (; i < ncode; i++) lengths[order[i]] = (short)bits(s, 3);
    for (; i < 19; i++) lengths[order[i]] = 0;
    if (s->error || construct(&s->lencode, lengths, 19) != 0) return -1;
    i = 0;
    while (i < nlen + ndist) {
        int sym = decode(s, &s->lencode);
        if (sym < 0) return -1;
        if (sym < 16) { lengths[i++] = (short)sym; continue; }
        short len = 0;
        int rep;
        if (sym == 16) {
            if (i == 0) return -1;
            len = lengths[i - 1];
            rep = 3 + bits(s, 2);
        } else if (sym == 17) {
            rep = 3 + bits(s, 3);
        } else {
            rep = 11 + bits(s, 7);
        }
        if (s->error || i + rep > nlen + ndist) return -1;
        while (rep--) lengths[i++] = len;
    }
    if (lengths[256] == 0) return -1;
    int err = construct(&s->lencode, lengths, nlen);
    if (err < 0 || (err > 0 && nlen - s->lencode.count[0] != 1)) return -1;
    err = construct(&s->distcode, lengths + nlen, ndist);
    if (err < 0 || (err > 0 && ndist - s->distcode.count[0] != 1)) return -1;
    return 0;
}

int xs_inflate64_run(xs_inflate64 *s, const uint8_t *in, size_t in_len, size_t *in_used,
                     uint8_t *out, size_t out_cap, size_t *out_len, int final) {
    s->in = in;
    s->end = in + in_len;
    s->out = out;
    s->outlen = 0;
    s->outcap = out_cap;
    int status = XS_INFLATE64_NEED_INPUT;
    for (;;) {
        if (s->copy_left) {
            while (s->copy_left && s->outlen < s->outcap) {
                put(s, s->window[(s->total - s->copy_dist) & WMASK]);
                s->copy_left--;
            }
            if (s->copy_left) { status = XS_INFLATE64_OUTPUT_FULL; break; }
        }
        if (s->state == ST_DONE) { status = XS_INFLATE64_END; break; }
        if (s->state == ST_HEADER) {
            if (!final && available(s) < 512) break;
            if (available(s) == 0) { status = XS_INFLATE64_ERROR; break; }
            s->last = bits(s, 1);
            int type = bits(s, 2);
            if (type == 0) {
                s->bitbuf >>= s->bitcnt & 7;
                s->bitcnt -= s->bitcnt & 7;
                unsigned len = (unsigned)bits(s, 16), nlen = (unsigned)bits(s, 16);
                if (s->error || len != (~nlen & 0xFFFF)) { status = XS_INFLATE64_ERROR; break; }
                s->stored_left = len;
                s->state = ST_STORED;
            } else if (type == 1) {
                fixed_tables(s);
                s->state = ST_CODES;
            } else if (type == 2) {
                if (dynamic_tables(s) != 0) { status = XS_INFLATE64_ERROR; break; }
                s->state = ST_CODES;
            } else {
                status = XS_INFLATE64_ERROR;
                break;
            }
            continue;
        }
        if (s->state == ST_STORED) {
            while (s->stored_left && s->outlen < s->outcap) {
                if (s->bitcnt >= 8) {
                    put(s, (uint8_t)s->bitbuf);
                    s->bitbuf >>= 8;
                    s->bitcnt -= 8;
                } else if (s->in < s->end) {
                    put(s, *s->in++);
                } else {
                    break;
                }
                s->stored_left--;
            }
            if (s->stored_left) {
                if (s->outlen == s->outcap) status = XS_INFLATE64_OUTPUT_FULL;
                else if (final) status = XS_INFLATE64_ERROR;
                break;
            }
            s->state = s->last ? ST_DONE : ST_HEADER;
            continue;
        }
        // ST_CODES
        if (s->outlen == s->outcap) { status = XS_INFLATE64_OUTPUT_FULL; break; }
        if (!final && available(s) < 16) break;
        int sym = decode(s, &s->lencode);
        if (sym < 0) { status = XS_INFLATE64_ERROR; break; }
        if (sym < 256) { put(s, (uint8_t)sym); continue; }
        if (sym == 256) { s->state = s->last ? ST_DONE : ST_HEADER; continue; }
        sym -= 257;
        if (sym >= 29) { status = XS_INFLATE64_ERROR; break; }
        unsigned len = (unsigned)len_base[sym] + (unsigned)bits(s, len_extra[sym]);
        int dsym = decode(s, &s->distcode);
        if (dsym < 0 || dsym >= 32) { status = XS_INFLATE64_ERROR; break; }
        unsigned dist = dist_base[dsym] + (unsigned)bits(s, dist_extra[dsym]);
        if (s->error || dist > s->total || dist > WSIZE) { status = XS_INFLATE64_ERROR; break; }
        s->copy_left = len;
        s->copy_dist = dist;
    }
    if (s->error) status = XS_INFLATE64_ERROR;
    *in_used = (size_t)(s->in - in);
    *out_len = s->outlen;
    return status;
}
