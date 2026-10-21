// Xipper spike — codec / checksum / crypto micro-benchmarks on Apple Silicon.
// Build: see spike/bench/Makefile. Usage: bench <file> [sample_MB]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <time.h>
#include <pthread.h>
#include <arm_acle.h>

#include <zlib.h>
#include <bzlib.h>
#include <compression.h>
#include <CommonCrypto/CommonCrypto.h>
#include <CommonCrypto/CommonKeyDerivation.h>

#include "libdeflate.h"
#define ZSTD_STATIC_LINKING_ONLY
#include "zstd.h"
#include "lzma.h"

static double now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9; }
static int g_threads;

static void die(const char *m) { fprintf(stderr, "FATAL: %s\n", m); exit(1); }

static void report(const char *name, size_t in, size_t out, double tc, double td) {
    printf("%-28s ratio %6.2f%%  comp %8.1f MB/s  decomp %8.1f MB/s\n",
           name, 100.0 * out / in, in / tc / 1e6, in / td / 1e6);
    fflush(stdout);
}

static void check(const uint8_t *a, const uint8_t *b, size_t n, const char *name) {
    if (memcmp(a, b, n) != 0) { fprintf(stderr, "ROUNDTRIP MISMATCH %s\n", name); exit(2); }
}

/* ---------------- zlib (system) ---------------- */
static void bench_zlib(const uint8_t *in, size_t n, int level) {
    uLongf cap = compressBound(n); uint8_t *c = malloc(cap); uint8_t *d = malloc(n);
    double t0 = now(); if (compress2(c, &cap, in, n, level) != Z_OK) die("zlib c");
    double t1 = now(); uLongf dn = n; if (uncompress(d, &dn, c, cap) != Z_OK) die("zlib d");
    double t2 = now(); check(in, d, n, "zlib");
    char nm[64]; snprintf(nm, sizeof nm, "zlib(system) -%d", level);
    report(nm, n, cap, t1 - t0, t2 - t1); free(c); free(d);
}

/* ---------------- libdeflate ---------------- */
static void bench_libdeflate(const uint8_t *in, size_t n, int level) {
    struct libdeflate_compressor *co = libdeflate_alloc_compressor(level);
    struct libdeflate_decompressor *de = libdeflate_alloc_decompressor();
    size_t cap = libdeflate_deflate_compress_bound(co, n); uint8_t *c = malloc(cap); uint8_t *d = malloc(n);
    double t0 = now(); size_t cn = libdeflate_deflate_compress(co, in, n, c, cap); if (!cn) die("ld c");
    double t1 = now(); size_t dn; if (libdeflate_deflate_decompress(de, c, cn, d, n, &dn) != LIBDEFLATE_SUCCESS) die("ld d");
    double t2 = now(); check(in, d, n, "libdeflate");
    char nm[64]; snprintf(nm, sizeof nm, "libdeflate -%d", level);
    report(nm, n, cn, t1 - t0, t2 - t1);
    libdeflate_free_compressor(co); libdeflate_free_decompressor(de); free(c); free(d);
}

/* ---------------- Apple Compression.framework ---------------- */
static void bench_apple(const uint8_t *in, size_t n, compression_algorithm alg, const char *name) {
    size_t cap = n + n / 8 + 65536; uint8_t *c = malloc(cap); uint8_t *d = malloc(n + 1);
    void *sc = malloc(compression_encode_scratch_buffer_size(alg));
    void *sd = malloc(compression_decode_scratch_buffer_size(alg));
    double t0 = now(); size_t cn = compression_encode_buffer(c, cap, in, n, sc, alg); if (!cn) die(name);
    double t1 = now(); size_t dn = compression_decode_buffer(d, n + 1, c, cn, sd, alg); if (dn != n) die(name);
    double t2 = now(); check(in, d, n, name);
    report(name, n, cn, t1 - t0, t2 - t1); free(c); free(d); free(sc); free(sd);
}

/* ---------------- bzip2 (system) ---------------- */
static void bench_bz2(const uint8_t *in, size_t n) {
    unsigned cap = (unsigned)(n + n / 100 + 600); char *c = malloc(cap); char *d = malloc(n);
    double t0 = now(); if (BZ2_bzBuffToBuffCompress(c, &cap, (char *)in, (unsigned)n, 9, 0, 0) != BZ_OK) die("bz c");
    double t1 = now(); unsigned dn = (unsigned)n; if (BZ2_bzBuffToBuffDecompress(d, &dn, c, cap, 0, 0) != BZ_OK) die("bz d");
    double t2 = now(); check(in, (uint8_t *)d, n, "bz2");
    report("bzip2(system) -9", n, cap, t1 - t0, t2 - t1); free(c); free(d);
}

/* ---------------- zstd ---------------- */
static void bench_zstd(const uint8_t *in, size_t n, int level, int workers, int longmode) {
    ZSTD_CCtx *cc = ZSTD_createCCtx(); ZSTD_DCtx *dc = ZSTD_createDCtx();
    ZSTD_CCtx_setParameter(cc, ZSTD_c_compressionLevel, level);
    ZSTD_CCtx_setParameter(cc, ZSTD_c_checksumFlag, 1);
    if (workers) ZSTD_CCtx_setParameter(cc, ZSTD_c_nbWorkers, workers);
    if (longmode) { ZSTD_CCtx_setParameter(cc, ZSTD_c_enableLongDistanceMatching, 1); ZSTD_CCtx_setParameter(cc, ZSTD_c_windowLog, 27); }
    ZSTD_DCtx_setParameter(dc, ZSTD_d_windowLogMax, 27);
    size_t cap = ZSTD_compressBound(n); uint8_t *c = malloc(cap); uint8_t *d = malloc(n);
    double t0 = now(); size_t cn = ZSTD_compress2(cc, c, cap, in, n); if (ZSTD_isError(cn)) die(ZSTD_getErrorName(cn));
    double t1 = now(); size_t dn = ZSTD_decompressDCtx(dc, d, n, c, cn); if (ZSTD_isError(dn) || dn != n) die("zstd d");
    double t2 = now(); check(in, d, n, "zstd");
    char nm[64]; snprintf(nm, sizeof nm, "zstd -%d%s%s", level, workers ? " MT" : "", longmode ? " --long" : "");
    report(nm, n, cn, t1 - t0, t2 - t1);
    ZSTD_freeCCtx(cc); ZSTD_freeDCtx(dc); free(c); free(d);
}

/* ---------------- xz / liblzma ---------------- */
static size_t lzma_run(lzma_stream *s, const uint8_t *in, size_t n, uint8_t *out, size_t cap) {
    s->next_in = in; s->avail_in = n; s->next_out = out; s->avail_out = cap;
    lzma_ret r = lzma_code(s, LZMA_FINISH);
    while (r == LZMA_OK) r = lzma_code(s, LZMA_FINISH);
    if (r != LZMA_STREAM_END) die("lzma_code");
    return cap - s->avail_out;
}
static void bench_xz(const uint8_t *in, size_t n, uint32_t preset, int mt) {
    size_t cap = lzma_stream_buffer_bound(n); uint8_t *c = malloc(cap); uint8_t *d = malloc(n);
    lzma_stream e = LZMA_STREAM_INIT, de = LZMA_STREAM_INIT;
    if (mt) {
        lzma_mt o = { .threads = (uint32_t)g_threads, .preset = preset, .check = LZMA_CHECK_CRC64, .block_size = 0, .timeout = 0 };
        if (lzma_stream_encoder_mt(&e, &o) != LZMA_OK) die("xz enc mt");
    } else if (lzma_easy_encoder(&e, preset, LZMA_CHECK_CRC64) != LZMA_OK) die("xz enc");
    double t0 = now(); size_t cn = lzma_run(&e, in, n, c, cap); double t1 = now();
    if (mt) {
        lzma_mt o = { .threads = (uint32_t)g_threads, .memlimit_threading = UINT64_MAX, .memlimit_stop = UINT64_MAX };
        if (lzma_stream_decoder_mt(&de, &o) != LZMA_OK) die("xz dec mt");
    } else if (lzma_stream_decoder(&de, UINT64_MAX, 0) != LZMA_OK) die("xz dec");
    double t2 = now(); size_t dn = lzma_run(&de, c, cn, d, n); double t3 = now();
    if (dn != n) die("xz size"); check(in, d, n, "xz");
    char nm[64]; snprintf(nm, sizeof nm, "xz -%u%s", preset, mt ? " MT" : "");
    report(nm, n, cn, t1 - t0, t3 - t2);
    lzma_end(&e); lzma_end(&de); free(c); free(d);
}

/* ---------------- CRC32 variants ---------------- */
static uint32_t crc_table[256];
static void crc_table_init(void) {
    for (uint32_t i = 0; i < 256; i++) { uint32_t c = i; for (int k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320u ^ (c >> 1) : c >> 1; crc_table[i] = c; }
}
static uint32_t crc32_table(const uint8_t *p, size_t n) {
    uint32_t c = ~0u; while (n--) c = crc_table[(c ^ *p++) & 0xff] ^ (c >> 8); return ~c;
}
// ARMv8 CRC32 instruction, single dependency chain (8 bytes/instr, latency-bound).
static uint32_t crc32_hw(const uint8_t *p, size_t n) {
    uint32_t c = ~0u;
    while (n >= 8) { uint64_t v; memcpy(&v, p, 8); c = __crc32d(c, v); p += 8; n -= 8; }
    while (n--) c = __crc32b(c, *p++);
    return ~c;
}
static void bench_sum(const char *name, uint32_t (*fn)(const uint8_t *, size_t), const uint8_t *in, size_t n, uint32_t *out) {
    double t0 = now(); uint32_t r = fn(in, n); double t1 = now();
    printf("%-28s %10.2f GB/s   (0x%08x)\n", name, n / (t1 - t0) / 1e9, r); *out = r;
}
static uint32_t w_zlib_crc(const uint8_t *p, size_t n) { return (uint32_t)crc32(0, p, (uInt)n); }
static uint32_t w_ld_crc(const uint8_t *p, size_t n) { return libdeflate_crc32(0, p, n); }
static uint32_t w_zlib_adler(const uint8_t *p, size_t n) { return (uint32_t)adler32(1, p, (uInt)n); }
static uint32_t w_ld_adler(const uint8_t *p, size_t n) { return libdeflate_adler32(1, p, n); }

/* ---------------- crypto (CommonCrypto, HW AES/SHA) ---------------- */
static void bench_crypto(const uint8_t *in, size_t n) {
    uint8_t key[32] = {1}, iv[16] = {2}, dig[32];
    uint8_t *out = malloc(n);
    double t0 = now(); CC_SHA256(in, (CC_LONG)n, dig); double t1 = now();
    printf("%-28s %10.2f GB/s\n", "SHA-256 (CommonCrypto)", n / (t1 - t0) / 1e9);
    t0 = now(); CC_SHA1(in, (CC_LONG)n, dig); t1 = now();
    printf("%-28s %10.2f GB/s\n", "SHA-1 (CommonCrypto)", n / (t1 - t0) / 1e9);
    CCCryptorRef cr; size_t moved;
    CCCryptorCreateWithMode(kCCEncrypt, kCCModeCTR, kCCAlgorithmAES, ccNoPadding, iv, key, 32, NULL, 0, 0, kCCModeOptionCTR_BE, &cr);
    t0 = now(); CCCryptorUpdate(cr, in, n, out, n, &moved); t1 = now(); CCCryptorRelease(cr);
    printf("%-28s %10.2f GB/s\n", "AES-256-CTR (CommonCrypto)", n / (t1 - t0) / 1e9);
    CCCryptorCreateWithMode(kCCEncrypt, kCCModeCBC, kCCAlgorithmAES, ccNoPadding, iv, key, 32, NULL, 0, 0, 0, &cr);
    size_t m = n & ~(size_t)15;
    t0 = now(); CCCryptorUpdate(cr, in, m, out, n, &moved); t1 = now(); CCCryptorRelease(cr);
    printf("%-28s %10.2f GB/s\n", "AES-256-CBC enc (CC)", m / (t1 - t0) / 1e9);
    CCHmacContext h; CCHmacInit(&h, kCCHmacAlgSHA1, key, 32);
    t0 = now(); CCHmacUpdate(&h, in, n); CCHmacFinal(&h, dig); t1 = now();
    printf("%-28s %10.2f GB/s\n", "HMAC-SHA1 (ZIP AES auth)", n / (t1 - t0) / 1e9);
    uint8_t dk[66];
    t0 = now(); for (int i = 0; i < 100; i++) CCKeyDerivationPBKDF(kCCPBKDF2, "password", 8, iv, 16, kCCPRFHmacAlgSHA1, 1000, dk, 66); t1 = now();
    printf("%-28s %10.3f ms/key\n", "PBKDF2-SHA1 x1000 (ZIP AES)", (t1 - t0) * 10);
    // 7z KDF: SHA-256 over (salt+password) repeated 2^19 times
    uint8_t blk[8 + 16]; memset(blk, 'p', sizeof blk);
    t0 = now(); CC_SHA256_CTX s; CC_SHA256_Init(&s);
    for (uint64_t i = 0; i < (1u << 19); i++) { memcpy(blk + 16, &i, 8); CC_SHA256_Update(&s, blk, sizeof blk); }
    CC_SHA256_Final(dig, &s); t1 = now();
    printf("%-28s %10.3f ms/key\n", "7z KDF SHA-256 x2^19", (t1 - t0) * 1000);
    free(out);
}

static uint8_t *sample(const uint8_t *src, size_t n, size_t want) {
    // stripe 1 MiB slices evenly across the source so the sample keeps the corpus mix
    if (want >= n) { uint8_t *b = malloc(n); memcpy(b, src, n); return b; }
    const size_t sl = 1 << 20; size_t k = want / sl; uint8_t *b = malloc(k * sl);
    for (size_t i = 0; i < k; i++) memcpy(b + i * sl, src + (n - sl) * i / (k - 1 ? k - 1 : 1), sl);
    return b;
}

int main(int argc, char **argv) {
    if (argc < 2) die("usage: bench <file> [sample_MB] [section]");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
    int p = 0, e = 0; size_t sz = sizeof p;
    sysctlbyname("hw.perflevel0.physicalcpu", &p, &sz, NULL, 0); sz = sizeof e;
    sysctlbyname("hw.perflevel1.physicalcpu", &e, &sz, NULL, 0);
    g_threads = p + e;
    const char *section = argc > 3 ? argv[3] : "all";
    int fd = open(argv[1], O_RDONLY); struct stat st; fstat(fd, &st);
    size_t n = st.st_size; uint8_t *map = mmap(NULL, n, PROT_READ, MAP_PRIVATE, fd, 0);
    uint8_t *full = malloc(n); memcpy(full, map, n); munmap(map, n); close(fd);
    size_t sm = (argc > 2 ? atoi(argv[2]) : 64) * (size_t)(1 << 20);
    uint8_t *s = sample(full, n, sm); if (sm > n) sm = n;
    printf("# file %s  full %.1f MB  sample %.1f MB  P-cores %d E-cores %d\n\n", argv[1], n / 1e6, sm / 1e6, p, e);

    if (!strcmp(section, "all") || !strcmp(section, "st")) {
        printf("## single-thread, sample %.0f MB\n", sm / 1e6);
        bench_zlib(s, sm, 1); bench_zlib(s, sm, 6); bench_zlib(s, sm, 9);
        bench_libdeflate(s, sm, 1); bench_libdeflate(s, sm, 6); bench_libdeflate(s, sm, 9); bench_libdeflate(s, sm, 12);
        bench_apple(s, sm, COMPRESSION_ZLIB, "Apple ZLIB (lvl5)");
        bench_apple(s, sm, COMPRESSION_LZFSE, "Apple LZFSE");
        bench_apple(s, sm, COMPRESSION_LZ4, "Apple LZ4");
        bench_apple(s, sm, COMPRESSION_LZBITMAP, "Apple LZBITMAP");
        bench_apple(s, sm, COMPRESSION_LZMA, "Apple LZMA (xz, lvl6)");
        bench_bz2(s, sm);
        bench_zstd(s, sm, 1, 0, 0); bench_zstd(s, sm, 3, 0, 0); bench_zstd(s, sm, 9, 0, 0); bench_zstd(s, sm, 19, 0, 0);
        bench_xz(s, sm, 6, 0);
        printf("\n");
    }
    if (!strcmp(section, "all") || !strcmp(section, "mt")) {
        printf("## multi-thread (%d threads), full %.0f MB\n", g_threads, n / 1e6);
        bench_zstd(full, n, 3, g_threads, 0); bench_zstd(full, n, 9, g_threads, 0);
        bench_zstd(full, n, 19, g_threads, 0); bench_zstd(full, n, 9, g_threads, 1);
        bench_xz(full, n, 6, 1);
        printf("\n");
    }
    if (!strcmp(section, "all") || !strcmp(section, "sum")) {
        printf("## checksums, full %.0f MB\n", n / 1e6);
        crc_table_init(); uint32_t r[4];
        bench_sum("CRC32 table (bytewise)", crc32_table, full, n, &r[0]);
        bench_sum("CRC32 zlib(system)", w_zlib_crc, full, n, &r[1]);
        bench_sum("CRC32 ARMv8 __crc32d", crc32_hw, full, n, &r[2]);
        bench_sum("CRC32 libdeflate (PMULL)", w_ld_crc, full, n, &r[3]);
        if (r[0] != r[1] || r[1] != r[2] || r[2] != r[3]) die("crc mismatch");
        bench_sum("Adler32 zlib(system)", w_zlib_adler, full, n, &r[0]);
        bench_sum("Adler32 libdeflate (NEON)", w_ld_adler, full, n, &r[1]);
        if (r[0] != r[1]) die("adler mismatch");
        printf("\n## crypto, full %.0f MB\n", n / 1e6);
        bench_crypto(full, n);
    }
    return 0;
}
