/*
 * libxiz — an independent C99 reader (and writer) of XIZ archives.
 * Implements docs/XIZ_SPEC.md (XIZ 1.4). MIT license, see libxiz/README.md.
 *
 * Conventions
 *  - Every function that can fail returns an `int` status (XIZ_OK = 0, otherwise a negative
 *    xiz_status) and fills the optional `xiz_error *err` with the code and a message.
 *  - Handles are opaque. An xiz_archive is not thread-safe: use one per thread (opening the
 *    same source twice is fine).
 *  - Strings are UTF-8. Paths inside an archive are '/'-separated byte strings and may contain
 *    anything but NUL; lengths are given explicitly.
 *  - Nothing is ever written outside the destination given to xiz_extract.
 */
#ifndef XIZ_H
#define XIZ_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) && defined(XIZ_SHARED)
#  ifdef XIZ_BUILDING
#    define XIZ_API __declspec(dllexport)
#  else
#    define XIZ_API __declspec(dllimport)
#  endif
#elif defined(__GNUC__) && defined(XIZ_SHARED)
#  define XIZ_API __attribute__((visibility("default")))
#else
#  define XIZ_API
#endif

#define XIZ_LIB_VERSION "0.1.0"
/* Highest XIZ minor version this library reads. */
#define XIZ_FORMAT_MINOR 4

/* ------------------------------------------------------------------ errors */

typedef enum xiz_status {
    XIZ_OK = 0,
    XIZ_E_ARG = -1,              /* invalid argument */
    XIZ_E_NOMEM = -2,
    XIZ_E_IO = -3,               /* read or write failed */
    XIZ_E_NOT_XIZ = -4,          /* no XIZ superblock */
    XIZ_E_CORRUPT = -5,          /* violates the specification */
    XIZ_E_UNSUPPORTED = -6,      /* newer version, unknown required feature, critical field… */
    XIZ_E_PASSWORD_REQUIRED = -7,
    XIZ_E_WRONG_PASSWORD = -8,   /* no credential opens the archive */
    XIZ_E_AUTH = -9,             /* AES-GCM authentication failed: data altered */
    XIZ_E_CHECKSUM = -10,        /* CRC-32C mismatch */
    XIZ_E_DIGEST = -11,          /* content SHA-256 / HMAC mismatch */
    XIZ_E_LIMIT = -12,           /* a decoder or caller limit was exceeded */
    XIZ_E_NOT_FOUND = -13,
    XIZ_E_UNSAFE = -14,          /* unsafe path or symbolic link (extraction) */
    XIZ_E_LOCKED = -15,          /* the entry's access group is not held */
    XIZ_E_ERASED = -16,          /* the entry's key slot was erased */
    XIZ_E_EXISTS = -17,          /* destination exists (extraction without overwrite) */
    XIZ_E_CALLBACK = -18         /* a callback asked to stop */
} xiz_status;

typedef struct xiz_error {
    int code;
    char message[256];
} xiz_error;

XIZ_API const char *xiz_status_name(int code);
XIZ_API const char *xiz_version(void);

/* ------------------------------------------------------------------ sources */

/* Reads exactly `len` bytes at `offset`; returns 0 on success, non-zero on failure. */
typedef int (*xiz_read_fn)(void *ctx, uint64_t offset, void *buf, size_t len);

typedef struct xiz_source {
    xiz_read_fn read;
    void *ctx;
    uint64_t size;              /* total size of the archive */
    void (*close)(void *ctx);   /* optional, called by xiz_close */
} xiz_source;

/* A source over a file (UTF-8 path; wide API on Windows). */
XIZ_API int xiz_source_file(xiz_source *out, const char *path, xiz_error *err);
/* A source over memory (not copied; must outlive the archive). */
XIZ_API void xiz_source_memory(xiz_source *out, const void *data, size_t size);

/* ------------------------------------------------------------------ opening */

typedef struct xiz_open_options {
    const char *password;               /* NULL: none */
    const char *const *passwords;       /* more passwords (custodians, recipients), may be NULL */
    size_t password_count;
    const uint8_t (*identities)[32];    /* X25519 secret keys (XIZ 1.3 public-key recipients) */
    size_t identity_count;
    uint64_t max_catalog;               /* decompressed catalog limit; 0 = 1 GiB (§5) */
    uint32_t max_entries;               /* 0 = 10,000,000 */
    unsigned flags;                     /* XIZ_OPEN_* */
} xiz_open_options;

/* Accept 0.1 beta archives (§9). */
#define XIZ_OPEN_ALLOW_BETA 1u
/* Open an encrypted XIZ 1.3 archive without credentials: structure, groups and signatures
 * only (every group hidden). Encrypted 1.0–1.2 archives still need a password. */
#define XIZ_OPEN_NO_KEYS 2u

typedef struct xiz_archive xiz_archive;

XIZ_API int xiz_open(xiz_archive **out, const xiz_source *src, const xiz_open_options *opt, xiz_error *err);
XIZ_API int xiz_open_file(xiz_archive **out, const char *path, const xiz_open_options *opt, xiz_error *err);
XIZ_API void xiz_close(xiz_archive *a);

/* Required feature bits (§3). */
#define XIZ_FEATURE_ENCRYPTED    0x0001u
#define XIZ_FEATURE_DICTIONARIES 0x0002u
#define XIZ_FEATURE_APPEND_CHAIN 0x0004u
#define XIZ_FEATURE_GENOMIC      0x0008u
#define XIZ_FEATURE_DIRECTORY    0x0010u
#define XIZ_FEATURE_LZMA2        0x0020u
#define XIZ_FEATURES_KNOWN       (XIZ_FEATURE_ENCRYPTED | XIZ_FEATURE_DICTIONARIES | XIZ_FEATURE_DIRECTORY | XIZ_FEATURE_LZMA2)

typedef struct xiz_info {
    uint16_t version_major, version_minor;  /* superblock */
    uint16_t required_features, optional_features;
    uint8_t archive_id[16];
    int encrypted;
    uint32_t segments;          /* 1 + appended segments (§11) */
    uint32_t frame_count;       /* footer */
    uint32_t entry_count;       /* footer: every entry, including hidden groups */
    uint64_t total_bytes;       /* footer */
    size_t visible_entries;     /* entries this reader can list */
    uint32_t dictionaries;      /* dictionary frames (§12) */
    int has_directory;          /* XIZ 1.3 directory (§13) */
    uint16_t group_count;       /* groups in the directory (1.3) */
    uint16_t hidden_groups;     /* groups whose key this reader does not hold */
    uint32_t erased_entries;    /* erasable entries whose slot was erased (§13.7) */
    int erasable;               /* directory flag: erasable archive */
    uint64_t data_start;        /* 64 + keys block */
    uint64_t footer_offset;     /* of the current footer */
    uint64_t trailing_bytes;    /* bytes after the footer (an interrupted append) */
    uint32_t codec_frames[4];   /* frames per codec: store, zstd, LZMA2, ARM64+LZMA2 */
} xiz_info;

XIZ_API int xiz_get_info(const xiz_archive *a, xiz_info *out);

/* ------------------------------------------------------------------ entries */

#define XIZ_TYPE_FILE 0
#define XIZ_TYPE_DIRECTORY 1
#define XIZ_TYPE_SYMLINK 2

typedef struct xiz_entry {
    const char *path;           /* NUL-terminated copy; path_len is authoritative */
    size_t path_len;
    int type;
    uint64_t size;
    uint16_t mode;              /* permission bits as stored (0o7777) */
    uint32_t uid, gid;
    int64_t mtime_sec;
    uint32_t mtime_nsec;
    const char *link;           /* symlink target, NUL-terminated copy */
    size_t link_len;
    int has_digest;
    uint8_t digest[32];         /* SHA-256, or HMAC-SHA-256 when encrypted (§6.3) */
    uint16_t group;             /* access group (1.3), 0 otherwise */
    int erasable;               /* has a key slot (§13.7) */
    int has_proof;              /* 1.3 proof data (salt and plain SHA-256) is readable */
    uint8_t proof_salt[16];
    uint8_t proof_sha256[32];
    size_t xattr_count;
    uint32_t extent_count;
} xiz_entry;

XIZ_API size_t xiz_entry_count(const xiz_archive *a);
XIZ_API int xiz_get_entry(const xiz_archive *a, size_t index, xiz_entry *out);
XIZ_API int xiz_get_xattr(const xiz_archive *a, size_t index, size_t i, const char **name, size_t *name_len,
                          const uint8_t **value, size_t *value_len);
/* Exact path lookup (leading '/' and './' ignored). */
XIZ_API int xiz_find(const xiz_archive *a, const char *path, size_t *index);

/* Receives content; return non-zero to stop (XIZ_E_CALLBACK). */
typedef int (*xiz_write_fn)(void *ctx, const void *data, size_t len);

/* Streams one file's content (a symlink: its target) and checks the stored digest at the end. */
XIZ_API int xiz_read_entry(xiz_archive *a, size_t index, xiz_write_fn write, void *ctx, xiz_error *err);
/* Reads into a new buffer (free with xiz_free); at most `max` bytes, 0 = no limit. */
XIZ_API int xiz_read_entry_alloc(xiz_archive *a, size_t index, uint64_t max, uint8_t **data, size_t *len, xiz_error *err);
XIZ_API void xiz_free(void *p);

/* ------------------------------------------------------------------ verification */

typedef struct xiz_test_report {
    uint32_t frames_checked;
    uint32_t frames_failed;
    uint32_t frames_skipped;    /* groups this reader cannot open */
    uint64_t files_checked;
    uint64_t files_failed;
    uint64_t bytes_checked;
} xiz_test_report;

/* Called for every problem found: frame index or entry index (the other is -1). */
typedef void (*xiz_problem_fn)(void *ctx, long frame, long entry, int code, const char *message);

/* Checks every frame (header, CRC-32C, authentication, exact size) and, unless `frames_only`,
 * every file's digest. Returns XIZ_OK when nothing failed. */
XIZ_API int xiz_test(xiz_archive *a, int frames_only, xiz_problem_fn problem, void *ctx, xiz_test_report *report,
                     xiz_error *err);

/* ------------------------------------------------------------------ extraction */

#define XIZ_EXTRACT_OVERWRITE          0x01u  /* replace existing files (never through a symlink) */
#define XIZ_EXTRACT_EXTERNAL_SYMLINKS  0x02u  /* allow symlinks pointing outside the destination */
#define XIZ_EXTRACT_NO_PERMISSIONS     0x04u  /* ignore stored modes (umask defaults) */
#define XIZ_EXTRACT_NO_TIMES           0x08u  /* do not restore mtimes */
#define XIZ_EXTRACT_OWNER              0x10u  /* restore uid/gid (POSIX, needs privileges) */
#define XIZ_EXTRACT_NO_SYMLINKS        0x20u  /* skip every symlink */
#define XIZ_EXTRACT_CONTINUE           0x40u  /* go on after a damaged file (it is removed) */

typedef struct xiz_extract_options {
    unsigned flags;
    const char *const *select;   /* entries (or folders) to extract; NULL = all */
    size_t select_count;
    uint64_t max_bytes;          /* refuse when the selection declares more; 0 = no limit */
    /* Called for each entry skipped or failed (path as stored). */
    void (*skipped)(void *ctx, const char *path, int code, const char *reason);
    /* Called after each entry is written. */
    void (*progress)(void *ctx, const char *path, uint64_t bytes);
    void *ctx;
} xiz_extract_options;

typedef struct xiz_extract_report {
    uint64_t files, directories, symlinks, bytes;
    uint64_t skipped;            /* unsafe paths, unsafe symlinks, existing files */
    uint64_t failed;             /* damaged content (with XIZ_EXTRACT_CONTINUE) */
} xiz_extract_report;

/* Extracts into `dest` (created if missing). Declared sizes are compared with max_bytes before
 * anything is written. */
XIZ_API int xiz_extract(xiz_archive *a, const char *dest, const xiz_extract_options *opt, xiz_extract_report *report,
                        xiz_error *err);

/* Windows: the file name an archive component gets on disk (<>:"|?*\ and controls → '_', reserved
 * device names prefixed with '_', trailing dots and spaces dropped). Exposed for tests; works on
 * every platform. Writes at most cap bytes including the NUL; returns the length. */
XIZ_API size_t xiz_windows_name(const char *component, size_t len, char *out, size_t cap);

/* ------------------------------------------------------------------ XIZ 1.3 */

typedef struct xiz_group {
    uint16_t id;
    int held;                    /* this reader holds its key (or the archive is not encrypted) */
    const char *name;            /* NULL when not held */
    size_t prefix_count;
} xiz_group;

XIZ_API size_t xiz_group_count(const xiz_archive *a);
XIZ_API int xiz_get_group(const xiz_archive *a, size_t i, xiz_group *out);
XIZ_API const char *xiz_group_prefix(const xiz_archive *a, size_t i, size_t p);

typedef struct xiz_stanza {
    int type;                    /* 1 password, 2 password recipient, 3 public key, 4 threshold, 5 share */
    const char *label;           /* visible label (types 2–5), "" otherwise */
    int opened;                  /* a credential opened it */
    int threshold_id, k, n, x;   /* threshold (4) and share (5) */
} xiz_stanza;

XIZ_API size_t xiz_stanza_count(const xiz_archive *a);
XIZ_API int xiz_get_stanza(const xiz_archive *a, size_t i, xiz_stanza *out);

typedef struct xiz_signature {
    uint32_t segment;
    int is_signed;
    int valid;                   /* Ed25519 signature verifies over the segment (§13.5) */
    int chained;                 /* `previous` equals the previous segment's chained digest */
    char label[256];
    uint8_t public_key[32];
    int64_t time;
    int has_timestamp;           /* an RFC 3161 token is present (not verified by libxiz) */
    uint32_t timestamp_length;
    uint8_t chained_digest[32];
} xiz_signature;

/* Signatures of every segment, oldest first. Needs no key. For archives without a directory,
 * every segment is reported unsigned. */
XIZ_API int xiz_signature_count(const xiz_archive *a, uint32_t *count);
XIZ_API int xiz_get_signature(xiz_archive *a, uint32_t segment, xiz_signature *out, xiz_error *err);

/* Merkle tree (§13.6): checks that the current segment's leaf table leads to the directory's
 * root and that the entry's leaf (needs its proof data) is in it. */
XIZ_API int xiz_check_inclusion(xiz_archive *a, size_t index, uint32_t *leaf_index, xiz_error *err);
/* Checks the whole leaf table against the directory's root. */
XIZ_API int xiz_check_tree(xiz_archive *a, xiz_error *err);

typedef struct xiz_proof_result {
    char path[1024];
    uint64_t size;
    int content_matches;
    int in_tree;
    int is_signed;               /* signature present and valid */
    char signer[256];
    uint8_t signer_key[32];
    int64_t signed_at;
    uint32_t segment;
} xiz_proof_result;

/* Verifies an `xiz-proof-1` JSON proof against a file's content (or a symlink target given as
 * the content). Needs no archive and no key. */
XIZ_API int xiz_verify_proof(const char *json, size_t json_len, const uint8_t *content, size_t content_len,
                             xiz_proof_result *out, xiz_error *err);

/* ------------------------------------------------------------------ writing */

typedef struct xiz_writer xiz_writer;

typedef struct xiz_writer_options {
    int level;                   /* zstd level, 0 = 9 */
    uint32_t frame_size;         /* 0 = 4 MiB (max 64 MiB) */
    const char *password;        /* encrypt with a password stanza (§6); NULL: plain */
    uint32_t kdf_memory_kib, kdf_iterations, kdf_parallelism; /* 0 = 262144, 3, 4 */
    int threads;                 /* unused for now */
} xiz_writer_options;

/* A new archive at `path` (must not exist unless `overwrite`). */
XIZ_API int xiz_writer_create(xiz_writer **out, const char *path, const xiz_writer_options *opt, int overwrite,
                              xiz_error *err);
/* Opens an archive to append a segment (§11). Plain 1.0–1.2/1.4 or password-encrypted archives
 * without directory. The new catalog starts as the current one. */
XIZ_API int xiz_writer_append(xiz_writer **out, const char *path, const xiz_writer_options *opt, xiz_error *err);

typedef struct xiz_entry_meta {
    uint16_t mode;               /* 0 = default */
    uint32_t uid, gid;
    int64_t mtime_sec;
    uint32_t mtime_nsec;
} xiz_entry_meta;

XIZ_API int xiz_writer_add_data(xiz_writer *w, const char *path, const void *data, size_t len,
                                const xiz_entry_meta *meta, xiz_error *err);
/* A file from disk, read in streaming fashion. */
XIZ_API int xiz_writer_add_file(xiz_writer *w, const char *path, const char *disk_path, const xiz_entry_meta *meta,
                                xiz_error *err);
XIZ_API int xiz_writer_add_directory(xiz_writer *w, const char *path, const xiz_entry_meta *meta, xiz_error *err);
XIZ_API int xiz_writer_add_symlink(xiz_writer *w, const char *path, const char *target, const xiz_entry_meta *meta,
                                   xiz_error *err);
/* Adds a file or folder tree from disk under `path` (metadata from the file system). */
XIZ_API int xiz_writer_add_tree(xiz_writer *w, const char *path, const char *disk_path, xiz_error *err);
/* Append mode: removes an entry (and everything below a folder). */
XIZ_API int xiz_writer_remove(xiz_writer *w, const char *path, xiz_error *err);
/* Writes the catalog and the footer; frees the writer in every case. */
XIZ_API int xiz_writer_finish(xiz_writer *w, xiz_error *err);
/* Abandons: a new archive is deleted, an append is truncated back. */
XIZ_API void xiz_writer_abort(xiz_writer *w);

#ifdef __cplusplus
}
#endif
#endif
