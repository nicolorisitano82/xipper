// Umbrella header for SwiftPM (Xipper): LZ4 block compressors and xxHash32 (namespaced as the
// target is built, so it never clashes with zstd's copy).
#define XXH_NAMESPACE LZ4_
#include "../lib/lz4.h"
#include "../lib/lz4hc.h"
#include "../lib/xxhash.h"
