// Pull-style wrapper over the LZMA SDK's Ppmd7z decoder (see include/CPpmd.h).
#include <stdlib.h>
#include "../C/Precomp.h"
#include "../C/Ppmd7.h"
#include "../include/CLzmaSDK.h"

static void *xs_alloc(ISzAllocPtr p, size_t size) { (void)p; return malloc(size); }
static void xs_free(ISzAllocPtr p, void *address) { (void)p; free(address); }
static const ISzAlloc xs_allocator = { xs_alloc, xs_free };

struct xs_ppmd7_dec {
    IByteIn vt;  // first member: the SDK calls Read with a pointer to it
    xs_ppmd_fill fill;
    void *ctx;
    size_t pos, len;
    int eof;     // set when the input ran out; further reads return 0
    int started;
    unsigned order;
    CPpmd7 ppmd;
    uint8_t buf[1 << 16];
};

static Byte xs_read_byte(IByteInPtr p) {
    struct xs_ppmd7_dec *d = (struct xs_ppmd7_dec *)(void *)p;
    if (d->pos == d->len) {
        if (d->eof) return 0;
        size_t n = d->fill(d->ctx, d->buf, sizeof d->buf);
        if (n == 0) { d->eof = 1; return 0; }
        d->pos = 0;
        d->len = n;
    }
    return d->buf[d->pos++];
}

xs_ppmd7_dec *xs_ppmd7_dec_new(unsigned order, uint32_t memSize, xs_ppmd_fill fill, void *ctx) {
    if (order < PPMD7_MIN_ORDER || order > PPMD7_MAX_ORDER || memSize < PPMD7_MIN_MEM_SIZE || memSize > PPMD7_MAX_MEM_SIZE)
        return NULL;
    struct xs_ppmd7_dec *d = calloc(1, sizeof *d);
    if (!d) return NULL;
    d->vt.Read = xs_read_byte;
    d->fill = fill;
    d->ctx = ctx;
    d->order = order;
    Ppmd7_Construct(&d->ppmd);
    if (!Ppmd7_Alloc(&d->ppmd, memSize, &xs_allocator)) { free(d); return NULL; }
    return d;
}

void xs_ppmd7_dec_free(xs_ppmd7_dec *d) {
    if (!d) return;
    Ppmd7_Free(&d->ppmd, &xs_allocator);
    free(d);
}

int xs_ppmd7_dec_read(xs_ppmd7_dec *d, uint8_t *out, size_t count) {
    if (!d->started) {
        d->started = 1;
        d->ppmd.rc.dec.Stream = &d->vt;
        if (!Ppmd7z_RangeDec_Init(&d->ppmd.rc.dec)) return d->eof ? -2 : -1;
        Ppmd7_Init(&d->ppmd, d->order);
    }
    for (size_t i = 0; i < count; i++) {
        int sym = Ppmd7z_DecodeSymbol(&d->ppmd);
        if (d->eof) return -2;
        if (sym < 0) return -1;
        out[i] = (uint8_t)sym;
    }
    return 0;
}
