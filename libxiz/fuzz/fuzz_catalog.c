/* libFuzzer: the parsers without I/O: catalog, directory, keys block (no credential, so no
 * Argon2), superblock, footer, LZMA2 and zstd frame decoding, proofs. */
#include "internal.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size < 1) return 0;
    uint8_t which = data[0];
    data++;
    size--;
    xiz_error e;
    arena ar = {0};
    switch (which % 7) {
    case 0: {
        catalog c;
        catalog_parse(data, size, &c, &ar, which & 0x80, 100000, &e);
        break;
    }
    case 1: {
        directory d;
        directory_parse(data, size, &d, &ar, &e);
        break;
    }
    case 2: {
        if (size < XIZ_SUPERBLOCK) break;
        keys_opened k;
        if (keys_open(data + XIZ_SUPERBLOCK, size - XIZ_SUPERBLOCK, data, which & 0x80, NULL, &k, &ar, &e) == XIZ_OK) free(k.keys);
        break;
    }
    case 3: {
        if (size < XIZ_SUPERBLOCK + XIZ_FOOTER) break;
        superblock sb;
        footer f;
        superblock_parse(data, &sb, 1, &e);
        footer_parse(data + XIZ_SUPERBLOCK, &f, &e);
        break;
    }
    case 4: {
        uint8_t *out = malloc(1 << 16);
        if (out) lzma2_decode_frame(data, size, out, (size_t)(which >> 3) << 11, which & 4, &e);
        free(out);
        break;
    }
    case 5: {
        uint8_t *out = malloc(1 << 16);
        if (out) zstd_decode_frame(data, size, out, (size_t)(which >> 3) << 11, NULL, &e);
        free(out);
        uint8_t *cat = NULL;
        if (zstd_decode_catalog(data, size, 1 << 16, &cat, &e) == XIZ_OK) free(cat);
        break;
    }
    case 6: {
        xiz_proof_result r;
        xiz_verify_proof((const char *)data, size, data, size / 2, &r, &e);
        break;
    }
    }
    arena_free(&ar);
    return 0;
}
