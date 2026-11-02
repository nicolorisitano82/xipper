/* libxiz internals. Not installed. */
#ifndef XIZ_INTERNAL_H
#define XIZ_INTERNAL_H

#include "xiz.h"

#include "bearssl.h"

#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ constants (spec §2–§14) */

#define XIZ_SUPERBLOCK 64
#define XIZ_FRAME_HEADER 32
#define XIZ_FOOTER 96
#define XIZ_TAG 16
#define XIZ_MAX_FRAME_DATA (64u << 20)          /* §4.1 */
#define XIZ_MAX_CATALOG ((uint64_t)1 << 30)     /* §5 */
#define XIZ_MAX_KEYS_BLOCK 65536u               /* §3 */
#define XIZ_MAX_DICTIONARY (1u << 20)           /* §12 */
#define XIZ_CATALOG_CHUNK 65536u                /* §6.5 */
#define XIZ_SLOT_SIZE 60                        /* §13.7 */
/* Slack accepted on a compressed frame over its data (zstd/LZMA2 worst case on 64 MiB is far
 * below this; writers store when compression does not shrink). */
#define XIZ_FRAME_SLACK 4096u

#define XIZ_FLAG_DICTIONARY 1u   /* §12 */
#define XIZ_FLAG_ENTRY_KEY 2u    /* §13.7 */

enum { CODEC_STORE = 0, CODEC_ZSTD = 1, CODEC_LZMA2 = 2, CODEC_LZMA2_ARM64 = 3 };

enum {
    TAG_SIZE = 0x8001, TAG_EXTENTS = 0x8002, TAG_LINK = 0x8003,
    TAG_MODE = 0x0004, TAG_OWNER = 0x0005, TAG_MTIME = 0x0006, TAG_XATTR = 0x0007, TAG_DIGEST = 0x0008,
    TAG_PROOF = 0x0009, TAG_KEY_SLOT = 0x800A, TAG_SEALED_PROOF = 0x000B
};

extern const uint8_t XIZ_SUPER_MAGIC[8];

/* ------------------------------------------------------------------ errors */

int xiz_fail(xiz_error *err, int code, const char *fmt, ...)
#if defined(__GNUC__)
    __attribute__((format(printf, 3, 4)))
#endif
    ;
#define FAIL(code, ...) xiz_fail(err, (code), __VA_ARGS__)
#define TRY(x) do { int rc_ = (x); if (rc_ != XIZ_OK) return rc_; } while (0)

/* ------------------------------------------------------------------ bytes */

static inline uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static inline uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static inline uint64_t rd64(const uint8_t *p) { return (uint64_t)rd32(p) | ((uint64_t)rd32(p + 4) << 32); }
static inline void wr16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static inline void wr32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}
static inline void wr64(uint8_t *p, uint64_t v) { wr32(p, (uint32_t)v); wr32(p + 4, (uint32_t)(v >> 32)); }
static inline void wr64be(uint8_t *p, uint64_t v) {
    for (int i = 7; i >= 0; i--) { p[i] = (uint8_t)v; v >>= 8; }
}

/* Bounded reader over a byte string: every read checks the remaining length. */
typedef struct {
    const uint8_t *p;
    size_t n, at;
    int bad;
} rbuf;

static inline void rb_init(rbuf *r, const uint8_t *p, size_t n) { r->p = p; r->n = n; r->at = 0; r->bad = 0; }
static inline size_t rb_left(const rbuf *r) { return r->bad ? 0 : r->n - r->at; }
static inline const uint8_t *rb_take(rbuf *r, size_t k) {
    if (r->bad || r->n - r->at < k) { r->bad = 1; return NULL; }
    const uint8_t *q = r->p + r->at;
    r->at += k;
    return q;
}
static inline uint8_t rb_u8(rbuf *r) { const uint8_t *q = rb_take(r, 1); return q ? q[0] : 0; }
static inline uint16_t rb_u16(rbuf *r) { const uint8_t *q = rb_take(r, 2); return q ? rd16(q) : 0; }
static inline uint32_t rb_u32(rbuf *r) { const uint8_t *q = rb_take(r, 4); return q ? rd32(q) : 0; }
static inline uint64_t rb_u64(rbuf *r) { const uint8_t *q = rb_take(r, 8); return q ? rd64(q) : 0; }

/* Growable byte string. */
typedef struct {
    uint8_t *p;
    size_t n, cap;
    int oom;
} wbuf;

int wb_reserve(wbuf *w, size_t more);
void wb_put(wbuf *w, const void *d, size_t n);
void wb_u8(wbuf *w, uint8_t v);
void wb_u16(wbuf *w, uint16_t v);
void wb_u32(wbuf *w, uint32_t v);
void wb_u64(wbuf *w, uint64_t v);
void wb_free(wbuf *w);

/* Arena for catalog strings and arrays (freed at once). */
typedef struct arena_block arena_block;
typedef struct { arena_block *head; } arena;
void *arena_alloc(arena *a, size_t n);
void *arena_dup(arena *a, const void *p, size_t n, int nul);
void arena_free(arena *a);

void secure_zero(void *p, size_t n);
int ct_equal(const void *a, const void *b, size_t n);

/* ------------------------------------------------------------------ checksums and crypto */

uint32_t xiz_crc32c(uint32_t crc, const void *data, size_t n);

typedef br_sha256_context sha256_ctx;
void sha256_init(sha256_ctx *c);
void sha256_update(sha256_ctx *c, const void *d, size_t n);
void sha256_final(sha256_ctx *c, uint8_t out[32]);
void sha256(const void *d, size_t n, uint8_t out[32]);

typedef br_hmac_context hmac_ctx;
void hmac_init(hmac_ctx *c, const uint8_t key[32]);
void hmac_update(hmac_ctx *c, const void *d, size_t n);
void hmac_final(hmac_ctx *c, uint8_t out[32]);

/* HKDF-SHA-256 (RFC 5869); salt may be NULL/0 (then HashLen zeros). */
void hkdf_sha256(const uint8_t *ikm, size_t ikm_len, const uint8_t *salt, size_t salt_len, const char *info,
                 uint8_t *out, size_t out_len);

/* AES-256-GCM, 96-bit nonce, 128-bit tag. In place. */
void aes_gcm_seal(const uint8_t key[32], const uint8_t nonce[12], const uint8_t *aad, size_t aad_len, uint8_t *data,
                  size_t len, uint8_t tag[16]);
/* Returns 1 when the tag verifies (data decrypted in place); 0 otherwise (data undefined). */
int aes_gcm_open(const uint8_t key[32], const uint8_t nonce[12], const uint8_t *aad, size_t aad_len, uint8_t *data,
                 size_t len, const uint8_t tag[16]);

int argon2id_kek(const char *password, const uint8_t salt[32], uint32_t mem_kib, uint32_t iters, uint32_t par,
                 uint8_t out[32]);

int xiz_random(void *buf, size_t n);

/* ------------------------------------------------------------------ model */

typedef struct {
    uint64_t offset;
    uint32_t csize, usize, crc;
    uint8_t codec, flags;
    uint16_t dict, group;
} frame_rec;

typedef struct { uint32_t frame, offset, length; } extent_rec;

typedef struct {
    const char *name;
    size_t name_len;
    const uint8_t *value;
    size_t value_len;
} xattr_rec;

typedef struct {
    uint8_t type;
    const char *path;
    size_t path_len;
    uint16_t mode;
    uint32_t uid, gid;
    int64_t mtime;
    uint32_t nsec;
    uint64_t size;
    const char *link;
    size_t link_len;
    extent_rec *ext;
    uint32_t n_ext;
    xattr_rec *xattrs;
    size_t n_xattrs;
    int has_digest, has_proof, has_slot, has_sealed_proof, has_secret;
    uint8_t digest[32];
    uint8_t proof[48];
    uint32_t slot_segment, slot_index;
    uint8_t slot_sha[32];
    uint8_t sealed_proof[76];
    uint8_t secret[32];          /* entry key from its slot (erasable entries) */
    uint16_t group;
} entry_rec;

typedef struct {
    frame_rec *frames;
    uint32_t n_frames;
    entry_rec *entries;
    size_t n_entries;
    int version;                 /* 0 (beta), 1, 2 (group catalog) */
    const char *group_name;
    const char **prefixes;
    size_t n_prefixes;
} catalog;

/* Parses a decompressed catalog (§5, §9, §13.2) into `cat`, strings in `ar`. */
int catalog_parse(const uint8_t *b, size_t n, catalog *cat, arena *ar, int allow_beta, uint32_t max_entries,
                  xiz_error *err);

typedef struct {
    uint16_t major, minor, required, optional;
    uint8_t id[16];
    uint32_t keys_length;
    uint8_t raw[XIZ_SUPERBLOCK];
} superblock;

typedef struct {
    uint16_t major, minor;
    uint64_t cat_offset, cat_csize, cat_usize;
    uint32_t frame_count, entry_count;
    uint64_t total_bytes;
    uint8_t cat_sha[32];
    uint64_t previous;
} footer;

int superblock_parse(const uint8_t b[XIZ_SUPERBLOCK], superblock *s, int allow_beta, xiz_error *err);
void superblock_encode(const superblock *s, uint8_t out[XIZ_SUPERBLOCK]);
int footer_parse(const uint8_t b[XIZ_FOOTER], footer *f, xiz_error *err);
void footer_encode(const footer *f, uint8_t out[XIZ_FOOTER]);
void footer_auth_fields(const footer *f, uint8_t out[36]);

/* Purpose keys derived from a file/group/entry key (§6.1, §13.7). */
typedef struct {
    uint8_t data[32], catalog[32], mac[32], slot[32];
} keyset;

void keyset_derive(keyset *k, const uint8_t key[32], const uint8_t archive_id[16]);

void frame_aad(const uint8_t id[16], uint32_t index, const frame_rec *f, uint8_t out[37]);
void frame_nonce(uint32_t index, uint8_t out[12]);
void frame_header_encode(uint32_t index, const frame_rec *f, uint8_t out[XIZ_FRAME_HEADER]);
/* STREAM (§6.5). `sealed`/`plain` are full buffers; returns XIZ_E_AUTH on any failure. */
int stream_open(const uint8_t key[32], const uint8_t *aad, size_t aad_len, uint32_t segment, const uint8_t *sealed,
                size_t n, uint8_t **plain, size_t *plain_len, xiz_error *err);
int stream_seal(const uint8_t key[32], const uint8_t *aad, size_t aad_len, uint32_t segment, const uint8_t *plain,
                size_t n, wbuf *out);

/* ------------------------------------------------------------------ keys block */

typedef struct {
    int type;
    const char *label;
    int opened;
    int tid, k, n, x;
} stanza_info;

typedef struct {
    uint16_t group;
    uint8_t key[32];
} group_key;

typedef struct {
    group_key *keys;
    size_t n_keys;
    stanza_info *stanzas;
    size_t n_stanzas;
    int any_known;               /* a stanza type this reader implements */
    int partial_threshold;       /* index+1 of a threshold with some but not enough shares */
} keys_opened;

int keys_open(const uint8_t *block, size_t n, const uint8_t sb[XIZ_SUPERBLOCK], int directory,
              const xiz_open_options *opt, keys_opened *out, arena *ar, xiz_error *err);

/* ------------------------------------------------------------------ codecs */

int zstd_decode_frame(const uint8_t *src, size_t n, uint8_t *dst, size_t usize, const void *ddict, xiz_error *err);
/* Streaming decode of a catalog: output grows up to `usize`, exact size required. */
int zstd_decode_catalog(const uint8_t *src, size_t n, uint64_t usize, uint8_t **out, xiz_error *err);
int lzma2_decode_frame(const uint8_t *src, size_t n, uint8_t *dst, size_t usize, int arm64, xiz_error *err);
void *zstd_ddict_create(const uint8_t *dict, size_t n, uint16_t id, xiz_error *err);
void zstd_ddict_free(void *d);
/* Returns compressed size, 0 when it would not be smaller (the caller stores). */
size_t zstd_encode(const uint8_t *src, size_t n, int level, uint8_t *dst, size_t cap);
size_t zstd_bound(size_t n);

/* ------------------------------------------------------------------ the archive */

typedef struct {
    uint16_t group;
    uint32_t segment;
    uint64_t offset, csize, usize;
    uint8_t sha[32];
} dir_group;

typedef struct {
    uint32_t segment;
    uint64_t offset;
    uint32_t count;
} dir_slots;

typedef struct {
    uint16_t version, flags;
    dir_group *groups;
    uint16_t n_groups;
    dir_slots *slots;
    uint16_t n_slots;
    uint64_t leaf_offset;
    uint32_t leaf_count;
    uint8_t root[32];
    const uint8_t *signature;
    uint32_t signature_len;
    size_t signed_len;           /* bytes before signature_length */
    uint8_t *raw;                /* the directory bytes (arena) */
    size_t raw_len;
} directory;

int directory_parse(const uint8_t *b, size_t n, directory *d, arena *ar, xiz_error *err);

typedef struct {
    uint16_t id;
    int held;
    keyset keys;
    const char *name;
    const char **prefixes;
    size_t n_prefixes;
} group_state;

typedef struct {
    long index;                  /* frame index, -1 when free */
    uint8_t *data;
    size_t len, cap;
    uint64_t stamp;
} cache_slot;

#define XIZ_CACHE_SLOTS 6

struct xiz_archive {
    xiz_source src;
    arena ar;
    superblock sb;
    footer ft;
    uint64_t footer_offset;
    uint64_t data_start;
    uint32_t segments;
    int encrypted;
    int structure_only;          /* XIZ_OPEN_NO_KEYS: no group opened */
    keyset keys;                 /* 1.0–1.2 encrypted: the file key's purposes */
    catalog cat;                 /* frames + visible entries */
    /* 1.2 dictionaries: id → frame index, decoded lazily */
    struct { uint16_t id; uint32_t frame; void *ddict; } *dicts;
    size_t n_dicts;
    /* 1.3 */
    int has_dir;
    directory dir;
    group_state *groups;
    size_t n_groups;
    uint16_t hidden_groups;
    uint32_t erased;
    stanza_info *stanzas;
    size_t n_stanzas;
    /* entry-key frames: frame index → entry (keys derived on demand) */
    long *frame_entry;
    cache_slot cache[XIZ_CACHE_SLOTS];
    uint64_t stamp;
    uint8_t *scratch;            /* compressed payload buffer */
    size_t scratch_cap;
};

int src_read(const xiz_archive *a, uint64_t off, void *buf, size_t n, xiz_error *err);
/* Decoded frame `i`, checked (header, CRC, AEAD, size). Owned by the cache; valid until the
 * next frame_get. */
int frame_get(xiz_archive *a, uint32_t i, const uint8_t **data, size_t *len, xiz_error *err);
int frame_can_open(const xiz_archive *a, uint32_t i);
/* The keys an entry's frames and digest use (NULL when not encrypted). */
int entry_keys(const xiz_archive *a, const entry_rec *e, keyset *out);
void cache_drop(xiz_archive *a);

/* Leaf data (§13.6) for an entry; 0 when it has no proof data. */
int entry_proof_data(const xiz_archive *a, const entry_rec *e, uint8_t salt[16], uint8_t sha[32]);
void merkle_leaf(const uint8_t *data, size_t n, uint8_t out[32]);
void merkle_root(const uint8_t (*leaves)[32], size_t n, uint8_t out[32]);
int merkle_root_from_path(const uint8_t leaf[32], uint64_t index, uint64_t size, const uint8_t (*path)[32],
                          size_t n, uint8_t out[32]);
void leaf_data(wbuf *w, const uint8_t salt[16], const char *path, size_t path_len, uint8_t type, uint64_t size,
               const uint8_t sha[32]);
int signature_message(wbuf *w, const uint8_t id[16], uint32_t segment, const uint8_t *dir_signed, size_t dir_len,
                      uint64_t previous_footer, const uint8_t *sig, size_t sig_len, const uint8_t **signature64);

/* Last valid footer (§11 recovery from an interrupted append). */
int find_last_footer(const xiz_archive *a, uint64_t *at, footer *f, xiz_error *err);

#endif
