/* libFuzzer: the whole read path on an in-memory archive (open, list, test, read every entry). */
#include "internal.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

static int sink(void *ctx, const void *d, size_t n) {
    (void)ctx; (void)d; (void)n;
    return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    xiz_source s;
    xiz_source_memory(&s, data, size);
    xiz_open_options o;
    memset(&o, 0, sizeof o);
    o.max_catalog = 16u << 20;
    o.max_entries = 100000;
    o.flags = XIZ_OPEN_ALLOW_BETA | XIZ_OPEN_NO_KEYS;
    xiz_archive *a;
    xiz_error e;
    if (xiz_open(&a, &s, &o, &e) != XIZ_OK) return 0;
    xiz_info in;
    xiz_get_info(a, &in);
    for (size_t i = 0; i < xiz_entry_count(a) && i < 64; i++) {
        xiz_entry en;
        xiz_get_entry(a, i, &en);
        xiz_read_entry(a, i, sink, NULL, &e);
    }
    xiz_test(a, 0, NULL, NULL, NULL, &e);
    uint32_t n;
    xiz_signature_count(a, &n);
    for (uint32_t k = 0; k < n && k < 8; k++) {
        xiz_signature sg;
        xiz_get_signature(a, k, &sg, &e);
    }
    xiz_check_tree(a, &e);
    xiz_close(a);
    return 0;
}
