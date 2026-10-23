// Deflate64 ("enhanced deflate", ZIP method 9) encoder, written for Xipper from the format (see
// inflate64.c): deflate with a 64 KiB window, lengths up to 65,538 (code 285 = 3 + 16 extra bits)
// and distance codes 30–31. No permissive Deflate64 encoder exists to vendor (7-Zip's is LGPL).
//
// Hash chains over the 64 KiB window, greedy or lazy matching by level (as zlib), blocks of up to
// 32,768 symbols written dynamic, fixed or stored, whichever is smallest. Huffman lengths come from
// Moffat–Katajainen's in-place minimum-redundancy algorithm, limited to 15 (7 for the code-length
// code) by redistributing the overflow, as miniz does.
//
// Chunked use (big files, compressed in parallel): each chunk is coded with the 64 KiB before it
// as a dictionary and, unless it is the last, ends with an empty stored block (a sync flush), so
// the chunks concatenate into one Deflate64 stream.

#include "CXipShims.h"
#include <stdlib.h>
#include <string.h>

#define WSIZE 65536
#define MIN_MATCH 3
#define MAX_MATCH 65538
#define HASH_BITS 16
#define BLOCK_SYMS 32768
#define TOO_FAR 4096  // a 3-byte match farther than this costs more than its literals

typedef struct {
    uint8_t *out;
    size_t cap, pos;
    uint64_t bits;
    int nbits, overflow;
} bitw;

static void putbits(bitw *w, uint32_t v, int n) {
    w->bits |= (uint64_t)v << w->nbits;
    w->nbits += n;
    while (w->nbits >= 8) {
        if (w->pos < w->cap) w->out[w->pos++] = (uint8_t)w->bits; else w->overflow = 1;
        w->bits >>= 8;
        w->nbits -= 8;
    }
}

static void align_byte(bitw *w) { if (w->nbits > 0) putbits(w, 0, 8 - w->nbits); }

static const uint16_t len_base[29] = {3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                                      35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 3};
static const uint8_t len_extra[29] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                      3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 16};
static const uint32_t dist_base[32] = {1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                                       257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                                       8193, 12289, 16385, 24577, 32769, 49153};
static const uint8_t dist_extra[32] = {0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                       7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14};
static const uint8_t cl_order[19] = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};

// Length 3–258 → code 0–28 (as deflate, 284 reaching 258); longer → code 28 (285).
static uint8_t len_code_table[259];
static uint8_t dist_code_small[257];   // distances 1–256
static uint8_t dist_code_large[512];   // (distance − 1) >> 7 for distances 257–65536
static int tables_ready;

static void init_tables(void) {
    if (tables_ready) return;
    for (int len = 3; len <= 258; len++) {
        int c = 0;
        while (c + 1 < 28 && len_base[c + 1] <= len) c++;
        len_code_table[len] = (uint8_t)c;
    }
    for (int d = 1; d <= 256; d++) {
        int c = 0;
        while (c + 1 < 32 && dist_base[c + 1] <= (uint32_t)d) c++;
        dist_code_small[d] = (uint8_t)c;
    }
    for (int i = 0; i < 512; i++) {
        uint32_t d = ((uint32_t)i << 7) + 1;
        int c = 0;
        while (c + 1 < 32 && dist_base[c + 1] <= d) c++;
        dist_code_large[i] = (uint8_t)c;
    }
    tables_ready = 1;
}

static int len_code(uint32_t len) { return len <= 258 ? len_code_table[len] : 28; }
static int dist_code(uint32_t d) { return d <= 256 ? dist_code_small[d] : dist_code_large[(d - 1) >> 7]; }

// MARK: Huffman code lengths

typedef struct { uint32_t freq; uint16_t sym; } symfreq;

static int by_freq(const void *a, const void *b) {
    const symfreq *x = a, *y = b;
    if (x->freq != y->freq) return x->freq < y->freq ? -1 : 1;
    return (int)x->sym - (int)y->sym;
}

// Moffat–Katajainen: A sorted ascending, n ≥ 2 → A[i] = code length of item i.
static void min_redundancy(uint32_t *A, int n) {
    int root, leaf, next, avbl, used, dpth;
    A[0] += A[1];
    root = 0;
    leaf = 2;
    for (next = 1; next < n - 1; next++) {
        if (leaf >= n || A[root] < A[leaf]) { A[next] = A[root]; A[root++] = (uint32_t)next; }
        else A[next] = A[leaf++];
        if (leaf >= n || (root < next && A[root] < A[leaf])) { A[next] += A[root]; A[root++] = (uint32_t)next; }
        else A[next] += A[leaf++];
    }
    A[n - 2] = 0;
    for (next = n - 3; next >= 0; next--) A[next] = A[A[next]] + 1;
    avbl = 1;
    used = dpth = 0;
    root = n - 2;
    next = n - 1;
    while (avbl > 0) {
        while (root >= 0 && (int)A[root] == dpth) { used++; root--; }
        while (avbl > used) { A[next--] = (uint32_t)dpth; avbl--; }
        avbl = 2 * used;
        dpth++;
        used = 0;
    }
}

// Lengths (≤ maxlen) for `n` symbols; at least two symbols get a code (some decoders refuse a
// single-code table), so a lone symbol is paired with a neighbour.
static void huff_lengths(const uint32_t *freq, int n, int maxlen, uint8_t *len) {
    symfreq s[320];
    uint32_t A[320];
    int m = 0;
    memset(len, 0, (size_t)n);
    for (int i = 0; i < n; i++) if (freq[i]) { s[m].freq = freq[i]; s[m].sym = (uint16_t)i; m++; }
    if (m == 0) { len[0] = len[1] = 1; return; }
    if (m == 1) { len[s[0].sym] = 1; len[s[0].sym == 0 ? 1 : 0] = 1; return; }
    qsort(s, (size_t)m, sizeof(symfreq), by_freq);
    for (int i = 0; i < m; i++) A[i] = s[i].freq;
    min_redundancy(A, m);
    int count[33] = {0};
    for (int i = 0; i < m; i++) count[A[i] > 32 ? 32 : A[i]]++;
    for (int i = maxlen + 1; i <= 32; i++) { count[maxlen] += count[i]; count[i] = 0; }
    uint32_t total = 0;
    for (int i = maxlen; i > 0; i--) total += (uint32_t)count[i] << (maxlen - i);
    while (total != (1u << maxlen)) {
        count[maxlen]--;
        for (int i = maxlen - 1; i > 0; i--) {
            if (count[i]) { count[i]--; count[i + 1] += 2; break; }
        }
        total--;
    }
    // Shortest codes to the most frequent symbols (the end of the sorted list).
    int j = m;
    for (int l = 1; l <= maxlen; l++)
        for (int k = count[l]; k > 0; k--) len[s[--j].sym] = (uint8_t)l;
}

static void huff_codes(const uint8_t *len, int n, uint16_t *code) {
    uint16_t bl_count[16] = {0}, next_code[16];
    for (int i = 0; i < n; i++) bl_count[len[i]]++;
    bl_count[0] = 0;
    uint16_t c = 0;
    for (int b = 1; b < 16; b++) { c = (uint16_t)((c + bl_count[b - 1]) << 1); next_code[b] = c; }
    for (int i = 0; i < n; i++) {
        if (!len[i]) { code[i] = 0; continue; }
        uint16_t v = next_code[len[i]]++, r = 0;
        for (int b = 0; b < len[i]; b++) { r = (uint16_t)((r << 1) | (v & 1)); v >>= 1; }
        code[i] = r;  // bit-reversed: deflate sends Huffman codes MSB first into an LSB-first stream
    }
}

// MARK: blocks

typedef struct {
    uint32_t *lit;   // literal byte, or match length when dist > 0
    uint32_t *dist;  // 0 for a literal
    int n;
} symbuf;

// Run-length coded code lengths (codes 16, 17, 18); returns the number of items.
static int rle_lengths(const uint8_t *lens, int n, uint8_t *sym, uint8_t *extra) {
    int k = 0;
    for (int i = 0; i < n;) {
        int run = 1;
        while (i + run < n && lens[i + run] == lens[i]) run++;
        int v = lens[i];
        int left = run;
        if (v == 0) {
            while (left >= 11) { int r = left > 138 ? 138 : left; sym[k] = 18; extra[k++] = (uint8_t)(r - 11); left -= r; }
            if (left >= 3) { sym[k] = 17; extra[k++] = (uint8_t)(left - 3); left = 0; }
            while (left-- > 0) { sym[k] = 0; extra[k++] = 0; }
        } else {
            sym[k] = (uint8_t)v; extra[k++] = 0; left--;
            while (left >= 3) { int r = left > 6 ? 6 : left; sym[k] = 16; extra[k++] = (uint8_t)(r - 3); left -= r; }
            while (left-- > 0) { sym[k] = (uint8_t)v; extra[k++] = 0; }
        }
        i += run;
    }
    return k;
}

static void write_symbols(bitw *w, const symbuf *sb, const uint8_t *llen, const uint16_t *lcode,
                          const uint8_t *dlen, const uint16_t *dcode) {
    for (int i = 0; i < sb->n; i++) {
        uint32_t d = sb->dist[i], l = sb->lit[i];
        if (!d) { putbits(w, lcode[l], llen[l]); continue; }
        int lc = len_code(l);
        putbits(w, lcode[257 + lc], llen[257 + lc]);
        if (len_extra[lc]) putbits(w, l - len_base[lc], len_extra[lc]);
        int dc = dist_code(d);
        putbits(w, dcode[dc], dlen[dc]);
        if (dist_extra[dc]) putbits(w, d - dist_base[dc], dist_extra[dc]);
    }
    putbits(w, lcode[256], llen[256]);
}

static uint64_t symbols_cost(const uint32_t *lf, const uint8_t *llen, const uint32_t *df, const uint8_t *dlen) {
    uint64_t bits = 0;
    for (int i = 0; i < 286; i++) bits += (uint64_t)lf[i] * (llen[i] + (i >= 257 ? len_extra[i - 257] : 0));
    for (int i = 0; i < 32; i++) bits += (uint64_t)df[i] * (dlen[i] + dist_extra[i]);
    return bits;
}

static void write_stored(bitw *w, const uint8_t *data, size_t n, int final) {
    do {
        size_t piece = n > 65535 ? 65535 : n;
        int fin = final && piece == n;
        putbits(w, (uint32_t)fin, 1);
        putbits(w, 0, 2);
        align_byte(w);
        putbits(w, (uint32_t)piece, 16);
        putbits(w, (uint32_t)(~piece & 0xFFFF), 16);
        for (size_t i = 0; i < piece; i++) putbits(w, data[i], 8);
        data += piece;
        n -= piece;
    } while (n > 0);
}

static void write_block(bitw *w, const symbuf *sb, const uint8_t *raw, size_t raw_len, int final) {
    uint32_t lf[286] = {0}, df[32] = {0};
    for (int i = 0; i < sb->n; i++) {
        if (!sb->dist[i]) { lf[sb->lit[i]]++; continue; }
        lf[257 + len_code(sb->lit[i])]++;
        df[dist_code(sb->dist[i])]++;
    }
    lf[256] = 1;

    // Dynamic.
    uint8_t llen[286], dlen[32];
    huff_lengths(lf, 286, 15, llen);
    huff_lengths(df, 32, 15, dlen);
    int hlit = 286;
    while (hlit > 257 && !llen[hlit - 1]) hlit--;
    int hdist = 32;
    while (hdist > 1 && !dlen[hdist - 1]) hdist--;
    uint8_t all[318], rsym[318], rext[318];
    memcpy(all, llen, (size_t)hlit);
    memcpy(all + hlit, dlen, (size_t)hdist);
    int nr = rle_lengths(all, hlit + hdist, rsym, rext);
    uint32_t cf[19] = {0};
    for (int i = 0; i < nr; i++) cf[rsym[i]]++;
    uint8_t clen[19];
    huff_lengths(cf, 19, 7, clen);
    int hclen = 19;
    while (hclen > 4 && !clen[cl_order[hclen - 1]]) hclen--;
    uint64_t dyn = 3 + 5 + 5 + 4 + 3 * (uint64_t)hclen;
    for (int i = 0; i < nr; i++) dyn += clen[rsym[i]] + (rsym[i] == 16 ? 2 : rsym[i] == 17 ? 3 : rsym[i] == 18 ? 7 : 0);
    dyn += symbols_cost(lf, llen, df, dlen);

    // Fixed.
    uint8_t flen[288], fdlen[32];
    for (int i = 0; i < 288; i++) flen[i] = i < 144 ? 8 : i < 256 ? 9 : i < 280 ? 7 : 8;
    for (int i = 0; i < 32; i++) fdlen[i] = 5;
    uint64_t fix = 3 + symbols_cost(lf, flen, df, fdlen);

    // Stored: header, alignment (at most 7 bits) and LEN/NLEN per 65,535 bytes.
    uint64_t sto = (uint64_t)raw_len * 8 + ((raw_len + 65534) / 65535 + (raw_len == 0)) * (3 + 7 + 32);

    if (sto <= dyn && sto <= fix) {
        write_stored(w, raw, raw_len, final);
    } else if (fix <= dyn) {
        uint16_t fcode[288], fdcode[32];
        huff_codes(flen, 288, fcode);
        huff_codes(fdlen, 32, fdcode);
        putbits(w, (uint32_t)final, 1);
        putbits(w, 1, 2);
        write_symbols(w, sb, flen, fcode, fdlen, fdcode);
    } else {
        uint16_t lcode[286], dcode[32], ccode[19];
        huff_codes(llen, 286, lcode);
        huff_codes(dlen, 32, dcode);
        huff_codes(clen, 19, ccode);
        putbits(w, (uint32_t)final, 1);
        putbits(w, 2, 2);
        putbits(w, (uint32_t)(hlit - 257), 5);
        putbits(w, (uint32_t)(hdist - 1), 5);
        putbits(w, (uint32_t)(hclen - 4), 4);
        for (int i = 0; i < hclen; i++) putbits(w, clen[cl_order[i]], 3);
        for (int i = 0; i < nr; i++) {
            putbits(w, ccode[rsym[i]], clen[rsym[i]]);
            if (rsym[i] == 16) putbits(w, rext[i], 2);
            else if (rsym[i] == 17) putbits(w, rext[i], 3);
            else if (rsym[i] == 18) putbits(w, rext[i], 7);
        }
        write_symbols(w, sb, llen, lcode, dlen, dcode);
    }
}

// MARK: matching

typedef struct { int chain, lazy, nice; } level_params;

static const level_params levels[10] = {
    {0, 0, 0}, {4, 0, 16}, {8, 0, 32}, {16, 0, 64}, {16, 16, 32}, {32, 32, 64},
    {128, 128, 128}, {256, 258, 258}, {1024, 258, 1024}, {4096, 258, MAX_MATCH},
};

static inline uint32_t hash3(const uint8_t *p) {
    uint32_t v = (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16;
    return (v * 2654435761u) >> (32 - HASH_BITS);
}

static inline uint32_t match_len(const uint8_t *a, const uint8_t *b, uint32_t max) {
    uint32_t n = 0;
    while (n + 8 <= max) {
        uint64_t x, y;
        memcpy(&x, a + n, 8);
        memcpy(&y, b + n, 8);
        if (x != y) return n + (uint32_t)(__builtin_ctzll(x ^ y) >> 3);
        n += 8;
    }
    while (n < max && a[n] == b[n]) n++;
    return n;
}

size_t xs_deflate64_bound(size_t n) { return n + n / 8 + 4096; }

size_t xs_deflate64_compress(const uint8_t *in, size_t n, const uint8_t *dict, size_t dict_len,
                             int level, int last, uint8_t *out, size_t cap) {
    init_tables();
    if (level < 1) level = 1;
    if (level > 9) level = 9;
    const level_params P = levels[level];
    if (dict_len > WSIZE) { dict += dict_len - WSIZE; dict_len = WSIZE; }
    size_t total = dict_len + n;
    uint8_t *buf = malloc(total ? total : 1);
    int32_t *head = malloc(sizeof(int32_t) << HASH_BITS);
    int32_t *prev = malloc(sizeof(int32_t) * (total ? total : 1));
    symbuf sb = {malloc(sizeof(uint32_t) * BLOCK_SYMS), malloc(sizeof(uint32_t) * BLOCK_SYMS), 0};
    bitw w = {out, cap, 0, 0, 0, 0};
    size_t result = 0;
    if (!buf || !head || !prev || !sb.lit || !sb.dist) goto done;
    if (dict_len) memcpy(buf, dict, dict_len);
    if (n) memcpy(buf + dict_len, in, n);
    memset(head, 0xFF, sizeof(int32_t) << HASH_BITS);

#define INSERT(p) do { if ((p) + 2 < total) { uint32_t h_ = hash3(buf + (p)); prev[p] = head[h_]; head[h_] = (int32_t)(p); } } while (0)
    for (size_t p = 0; p < dict_len; p++) INSERT(p);

    size_t pos = dict_len, block_start = dict_len, covered = dict_len;
    int have_prev = 0;
    uint32_t prev_len = 0, prev_dist = 0;

#define FLUSH_IF_FULL() do { if (sb.n >= BLOCK_SYMS) { write_block(&w, &sb, buf + block_start, covered - block_start, 0); \
    sb.n = 0; block_start = covered; } } while (0)
#define EMIT_LIT(p) do { sb.lit[sb.n] = buf[p]; sb.dist[sb.n++] = 0; covered = (p) + 1; FLUSH_IF_FULL(); } while (0)
#define EMIT_MATCH(p, l, d) do { sb.lit[sb.n] = (l); sb.dist[sb.n++] = (d); covered = (p) + (l); FLUSH_IF_FULL(); } while (0)

    while (pos < total) {
        // Longest match at pos among the earlier positions with the same hash.
        uint32_t best = 0, best_dist = 0;
        uint32_t maxlen = total - pos > MAX_MATCH ? MAX_MATCH : (uint32_t)(total - pos);
        if (maxlen >= MIN_MATCH) {
            uint32_t h = hash3(buf + pos);
            int32_t cand = head[h];
            int chain = P.chain;
            if (have_prev && prev_len >= (uint32_t)P.lazy / 2) chain >>= 2;  // already a good match
            while (cand >= 0 && chain-- > 0) {
                size_t d = pos - (size_t)cand;
                if (d > WSIZE || best >= maxlen) break;
                if (buf[cand + best] == buf[pos + best]) {
                    uint32_t l = match_len(buf + cand, buf + pos, maxlen);
                    if (l > best) { best = l; best_dist = (uint32_t)d; if (l >= (uint32_t)P.nice) break; }
                }
                cand = prev[cand];
            }
            prev[pos] = head[h];
            head[h] = (int32_t)pos;
            if (best == MIN_MATCH && best_dist > TOO_FAR) best = 0;
            if (best < MIN_MATCH) best = 0;
        }

        if (have_prev) {
            if (best > prev_len) {  // the match one byte later is better: emit a literal instead
                EMIT_LIT(pos - 1);
                prev_len = best;
                prev_dist = best_dist;
                pos++;
                continue;
            }
            size_t start = pos - 1;
            EMIT_MATCH(start, prev_len, prev_dist);
            for (size_t p = pos + 1; p < start + prev_len; p++) INSERT(p);
            pos = start + prev_len;
            have_prev = 0;
            continue;
        }
        if (best && P.lazy && best < (uint32_t)P.lazy && pos + 1 < total) {
            have_prev = 1;
            prev_len = best;
            prev_dist = best_dist;
            pos++;
            continue;
        }
        if (best) {
            EMIT_MATCH(pos, best, best_dist);
            for (size_t p = pos + 1; p < pos + best; p++) INSERT(p);
            pos += best;
        } else {
            EMIT_LIT(pos);
            pos++;
        }
    }
    if (have_prev) {
        // The deferred match at pos − 1 (pos == total here only if it fits; else literals).
        size_t start = pos - 1;
        if (start + prev_len <= total) { EMIT_MATCH(start, prev_len, prev_dist); }
        else { for (size_t p = start; p < total; p++) EMIT_LIT(p); }
    }
    write_block(&w, &sb, buf + block_start, covered - block_start, last);
    if (!last) {
        // Sync flush: an empty stored block ends the chunk on a byte boundary.
        putbits(&w, 0, 1);
        putbits(&w, 0, 2);
        align_byte(&w);
        putbits(&w, 0, 16);
        putbits(&w, 0xFFFF, 16);
    }
    align_byte(&w);
    if (!w.overflow) result = w.pos;

done:
    free(buf);
    free(head);
    free(prev);
    free(sb.lit);
    free(sb.dist);
    return result;
#undef INSERT
#undef FLUSH_IF_FULL
#undef EMIT_LIT
#undef EMIT_MATCH
}
