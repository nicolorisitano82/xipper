// XXH3 64/128-bit (xxHash 0.8, BSD-2-Clause) for the hash tool, inlined from xxhash/xxhash.h so
// its symbols do not clash with the copies inside zstd and LZ4.
#include "CXipShims.h"
#define XXH_INLINE_ALL
#include "xxhash/xxhash.h"

// The 64- and 128-bit digests come from the same state: both resets and updates are the same.
void *xs_xxh3_new(void) {
    XXH3_state_t *s = XXH3_createState();
    if (s != NULL) XXH3_128bits_reset(s);
    return s;
}

void xs_xxh3_update(void *s, const void *data, size_t len) { XXH3_128bits_update((XXH3_state_t *)s, data, len); }

uint64_t xs_xxh3_64(void *s) { return XXH3_64bits_digest((XXH3_state_t *)s); }

void xs_xxh3_128(void *s, uint64_t *high, uint64_t *low) {
    XXH128_hash_t h = XXH3_128bits_digest((XXH3_state_t *)s);
    *high = h.high64;
    *low = h.low64;
}

void xs_xxh3_free(void *s) { XXH3_freeState((XXH3_state_t *)s); }
