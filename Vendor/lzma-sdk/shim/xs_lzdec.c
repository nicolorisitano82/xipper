// Streaming wrapper over the LZMA SDK's LzmaDec / Lzma2Dec (see include/CLzmaSDK.h).
#include <stdlib.h>
#include <string.h>
#include "../C/Precomp.h"
#include "../C/LzmaDec.h"
#include "../C/Lzma2Dec.h"
#include "../include/CLzmaSDK.h"

static void *xs_alloc(ISzAllocPtr p, size_t size) { (void)p; return malloc(size); }
static void xs_free(ISzAllocPtr p, void *address) { (void)p; free(address); }
static const ISzAlloc xs_allocator = { xs_alloc, xs_free };

struct xs_lzdec {
    int lzma2;
    CLzmaDec lz;
    CLzma2Dec lz2;
};

static uint32_t cap_dict(uint32_t d, uint32_t cap) {
    if (cap == 0) return d;
    if (cap < 4096) cap = 4096;
    return d > cap ? cap : d;
}

xs_lzdec *xs_lzma_dec_new(const uint8_t *props, uint32_t dictCap) {
    uint8_t p[5];
    memcpy(p, props, 5);
    uint32_t d = (uint32_t)p[1] | (uint32_t)p[2] << 8 | (uint32_t)p[3] << 16 | (uint32_t)p[4] << 24;
    d = cap_dict(d, dictCap);
    p[1] = (uint8_t)d; p[2] = (uint8_t)(d >> 8); p[3] = (uint8_t)(d >> 16); p[4] = (uint8_t)(d >> 24);
    struct xs_lzdec *x = calloc(1, sizeof *x);
    if (!x) return NULL;
    LzmaDec_CONSTRUCT(&x->lz)
    if (LzmaDec_Allocate(&x->lz, p, 5, &xs_allocator) != SZ_OK) { free(x); return NULL; }
    LzmaDec_Init(&x->lz);
    return x;
}

static uint32_t lzma2_dict(unsigned prop) {
    return prop == 40 ? 0xFFFFFFFF : (2 | (prop & 1)) << (prop / 2 + 11);
}

xs_lzdec *xs_lzma2_dec_new(uint8_t prop, uint32_t dictCap) {
    if (prop > 40) return NULL;
    // Smallest property whose dictionary still covers the cap.
    unsigned p = prop;
    if (dictCap) {
        uint32_t want = cap_dict(lzma2_dict(prop), dictCap);
        while (p > 0 && lzma2_dict(p - 1) >= want) p--;
    }
    struct xs_lzdec *x = calloc(1, sizeof *x);
    if (!x) return NULL;
    x->lzma2 = 1;
    Lzma2Dec_CONSTRUCT(&x->lz2)
    if (Lzma2Dec_Allocate(&x->lz2, (Byte)p, &xs_allocator) != SZ_OK) { free(x); return NULL; }
    Lzma2Dec_Init(&x->lz2);
    return x;
}

void xs_lzdec_free(xs_lzdec *x) {
    if (!x) return;
    if (x->lzma2) Lzma2Dec_Free(&x->lz2, &xs_allocator); else LzmaDec_Free(&x->lz, &xs_allocator);
    free(x);
}

int xs_lzdec_run(xs_lzdec *x, const uint8_t *in, size_t inLen, size_t *inUsed,
                 uint8_t *out, size_t outCap, size_t *outUsed, int finishEnd) {
    SizeT dl = outCap, sl = inLen;
    ELzmaStatus st = LZMA_STATUS_NOT_SPECIFIED;
    static const Byte empty[1] = {0};
    if (!in) in = empty;
    ELzmaFinishMode mode = finishEnd ? LZMA_FINISH_END : LZMA_FINISH_ANY;
    SRes r = x->lzma2 ? Lzma2Dec_DecodeToBuf(&x->lz2, out, &dl, in, &sl, mode, &st)
                      : LzmaDec_DecodeToBuf(&x->lz, out, &dl, in, &sl, mode, &st);
    *inUsed = sl;
    *outUsed = dl;
    return r == SZ_OK ? (int)st : -1;
}
