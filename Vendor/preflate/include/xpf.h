/* Xipper's C interface to preflate (not part of preflate): split a raw deflate stream into the
 * uncompressed data and the reconstruction information, and rebuild the identical stream. */
#ifndef XPF_H
#define XPF_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* A buffer allocated with malloc by these functions; free it with xpf_free. */
typedef struct {
    uint8_t *data;
    size_t size;
} xpf_buffer;

/* Decodes the raw deflate stream at the start of `in` (it may be followed by other bytes).
 * Returns 1 and fills `unpacked`, `diff` and `consumed` (bytes of the deflate stream), or 0 when
 * the data is not a complete deflate stream or preflate does not take it. `max_unpacked` bounds
 * the uncompressed size. */
int xpf_decode(const uint8_t *in, size_t n, size_t max_unpacked, xpf_buffer *unpacked, xpf_buffer *diff, size_t *consumed);

/* Rebuilds the raw deflate stream from the reconstruction information and the uncompressed data.
 * Returns 1 and fills `out`, or 0 on damaged input. */
int xpf_reencode(const uint8_t *diff, size_t diff_size, const uint8_t *unpacked, size_t unpacked_size, xpf_buffer *out);

void xpf_free(xpf_buffer *b);

#ifdef __cplusplus
}
#endif

#endif /* XPF_H */
