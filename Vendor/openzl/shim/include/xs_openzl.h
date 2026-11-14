// Xipper's C interface to OpenZL (XIZ 1.11, tables): CSV/TSV pieces compressed with the CSV
// profile, and the universal decoder. Kept small so XipperKit sees none of OpenZL's headers.
#ifndef XS_OPENZL_H
#define XS_OPENZL_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

/// OpenZL format version written by Xipper: pinned, so a newer vendored OpenZL keeps writing
/// frames the readers shipped with XIZ 1.11 decode.
#define XS_OZL_FORMAT_VERSION 27

/// Worst case output size of xs_ozl_csv_compress for n input bytes.
size_t xs_ozl_bound(size_t n);

/// Compresses one piece of a delimited table (whole rows). header: the piece starts with the
/// header row. level: 1-19 (OpenZL compression level). Returns the compressed size, 0 on failure
/// (not a table OpenZL can parse, or no room).
size_t xs_ozl_csv_compress(const void *src, size_t n, void *dst, size_t cap, char separator, int header, int level);

/// Model weights (XIZ 1.11, §21): kind 1 float32, 2 bfloat16, 3 float16 (IEEE half). The values are
/// split into sign and exponent (Huffman) and mantissa (stored), as OpenZL's PyTorch profile does.
/// n must be a multiple of the element size. Returns the compressed size, 0 on failure.
size_t xs_ozl_float_compress(const void *src, size_t n, void *dst, size_t cap, int kind);

/// Size the frame decodes to, or (size_t)-1 when the header is not a valid OpenZL frame.
size_t xs_ozl_decompressed_size(const void *src, size_t n);

/// Decodes one OpenZL frame. Returns the decoded size, or (size_t)-1 on error.
size_t xs_ozl_decompress(void *dst, size_t cap, const void *src, size_t n);

#ifdef __cplusplus
}
#endif
#endif
