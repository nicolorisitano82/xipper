/* Writer: new archives (zstd frames compressed in parallel, file-level deduplication; a password,
 * or XIZ 1.3 access groups with recipients, custodians and second factors, §13, §17, §24) and
 * appended segments to archives without a directory (§11). */
#include "internal.h"

#include <stdio.h>

#include "monocypher.h"

#if defined(_WIN32)
#  include <windows.h>
#  include <process.h>
#  include <io.h>
#  include <fcntl.h>
#  include <sys/stat.h>
#else
#  include <dirent.h>
#  include <errno.h>
#  include <pthread.h>
#  include <fcntl.h>
#  include <sys/stat.h>
#  include <unistd.h>
#endif

typedef struct {
    uint8_t type;
    char *path;
    size_t path_len;
    uint16_t mode;
    uint32_t uid, gid;
    int64_t mtime;
    uint32_t nsec;
    uint64_t size;
    char *link;
    size_t link_len;
    extent_rec *ext;
    uint32_t n_ext;
    xattr_rec *xattrs;           /* kept from the previous catalog (append) */
    size_t n_xattrs;
    int has_digest;
    uint8_t digest[32];
    uint8_t plain_sha[32];       /* dedup key; with a directory, also the proof data (§13.6) */
    int has_plain_sha;
    int removed;
    uint16_t group;              /* XIZ 1.3: its access group */
} wentry;

/* One frame on its way out: filled by the writer, compressed and sealed by a worker, written in
 * order by the writer. */
#define XIZ_WRITER_MAX_THREADS 16
typedef struct {
    struct xiz_writer *w;
    uint8_t *in;
    uint32_t used, index;
    uint16_t group;
    uint8_t *out;
    size_t out_cap, n;
    frame_rec f;
    int fail;
#if defined(_WIN32)
    HANDLE thread;
#else
    pthread_t thread;
#endif
    int started;
} wframe;

struct xiz_writer {
    int append, overwrite;
    char *path, *tmp_path;
#if defined(_WIN32)
    HANDLE h;
#else
    int fd;
#endif
    uint64_t pos, original_end;
    superblock sb;
    int encrypted;
    keyset keys;
    uint64_t previous_footer;
    uint32_t segment;
    int level;
    uint32_t frame_size;
    frame_rec *frames;
    uint32_t n_frames, cap_frames;
    wentry *entries;
    size_t n_entries, cap_entries;
    uint8_t *buf;                /* current frame data (an input buffer of `slots`) */
    uint32_t used;
    uint32_t next_index;         /* the index the current frame will have */
    int threads;                 /* frames compressed together */
    wframe *slots[2];            /* two batches: one filling, one compressing */
    uint32_t filled[2];
    int cur, running;            /* the batch being filled; the one compressing (-1: none) */
    xiz_archive *source;         /* append: keeps xattr strings alive */
    xiz_progress_fn progress;
    void *progress_ctx;
    uint64_t read_bytes;
    /* XIZ 1.3 (§13): a directory, a key per group, frames never shared between groups. */
    int dir;
    uint16_t n_groups;           /* group 0 included */
    keyset *gkeys;
    char **gname;
    char ***gprefix;
    size_t *gnprefix;
    uint16_t cur_group;          /* the group of the frame being filled */
    uint8_t *keys_block;
    size_t keys_len;
    int failed;
};

/* ------------------------------------------------------------------ file output */

static int w_write(xiz_writer *w, const void *d, size_t n, xiz_error *err) {
    const uint8_t *p = d;
#if defined(_WIN32)
    while (n) {
        DWORD chunk = n > 0x40000000u ? 0x40000000u : (DWORD)n, got = 0;
        if (!WriteFile(w->h, p, chunk, &got, NULL) || !got) { w->failed = 1; return FAIL(XIZ_E_IO, "write failed"); }
        p += got;
        n -= got;
        w->pos += got;
    }
#else
    while (n) {
        ssize_t r = write(w->fd, p, n);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) { w->failed = 1; return FAIL(XIZ_E_IO, "write failed: %s", strerror(errno)); }
        p += r;
        n -= (size_t)r;
        w->pos += (uint64_t)r;
    }
#endif
    return XIZ_OK;
}

static void w_close_file(xiz_writer *w) {
#if defined(_WIN32)
    if (w->h != INVALID_HANDLE_VALUE) CloseHandle(w->h);
    w->h = INVALID_HANDLE_VALUE;
#else
    if (w->fd >= 0) close(w->fd);
    w->fd = -1;
#endif
}

static int w_sync(xiz_writer *w) {
#if defined(_WIN32)
    return FlushFileBuffers(w->h) ? 0 : -1;
#else
    return fsync(w->fd);
#endif
}

static int w_truncate(xiz_writer *w, uint64_t at) {
#if defined(_WIN32)
    LARGE_INTEGER li;
    li.QuadPart = (LONGLONG)at;
    return SetFilePointerEx(w->h, li, NULL, FILE_BEGIN) && SetEndOfFile(w->h) ? 0 : -1;
#else
    if (ftruncate(w->fd, (off_t)at) != 0) return -1;
    return lseek(w->fd, (off_t)at, SEEK_SET) < 0 ? -1 : 0;
#endif
}

static int remove_path(const char *p) {
#if defined(_WIN32)
    wchar_t *wp = xiz_utf8_to_wide(p);
    int r = wp && DeleteFileW(wp) ? 0 : -1;
    free(wp);
    return r;
#else
    return unlink(p);
#endif
}

static int rename_path(const char *from, const char *to, int overwrite) {
#if defined(_WIN32)
    wchar_t *a = xiz_utf8_to_wide(from), *b = xiz_utf8_to_wide(to);
    int r = a && b && MoveFileExW(a, b, overwrite ? MOVEFILE_REPLACE_EXISTING : 0) ? 0 : -1;
    free(a);
    free(b);
    return r;
#else
    if (!overwrite) {
        /* link + unlink refuses an existing destination atomically */
        if (link(from, to) != 0) return -1;
        return unlink(from);
    }
    return rename(from, to);
#endif
}

/* ------------------------------------------------------------------ frames */

static const keyset *keys_for(const xiz_writer *w, uint16_t group) {
    return w->dir ? &w->gkeys[group] : &w->keys;
}

/* §13.2: the group with the longest prefix equal to the path or to a leading run of its components. */
static uint16_t group_of(const xiz_writer *w, const char *path) {
    if (!w->dir) return 0;
    while (*path == '/') path++;
    size_t pl = strlen(path);
    while (pl && path[pl - 1] == '/') pl--;
    uint16_t best = 0;
    size_t best_len = 0;
    for (uint16_t g = 1; g < w->n_groups; g++)
        for (size_t i = 0; i < w->gnprefix[g]; i++) {
            const char *x = w->gprefix[g][i];
            size_t xl = strlen(x);
            if (xl > best_len && xl <= pl && memcmp(path, x, xl) == 0 && (xl == pl || path[xl] == '/')) {
                best = g;
                best_len = xl;
            }
        }
    return best;
}

/* Compresses (zstd, or store when it does not shrink) and seals one frame: no shared state, so
 * workers run it in parallel. */
static void seal_frame(wframe *p) {
    xiz_writer *w = p->w;
    size_t need = zstd_bound(p->used) + XIZ_TAG;
    if (p->out_cap < need) {
        uint8_t *o = realloc(p->out, need);
        if (!o) { p->fail = 1; return; }
        p->out = o;
        p->out_cap = need;
    }
    memset(&p->f, 0, sizeof p->f);
    p->f.usize = p->used;
    size_t n = zstd_encode(p->in, p->used, w->level, p->out, p->out_cap - XIZ_TAG);
    if (n && n < p->used) {
        p->f.codec = CODEC_ZSTD;
    } else {
        p->f.codec = CODEC_STORE;
        memcpy(p->out, p->in, p->used);
        n = p->used;
    }
    if (w->encrypted) {
        uint8_t nonce[12], aad[37];
        frame_nonce(p->index, nonce);
        frame_aad(w->sb.id, p->index, &p->f, aad);
        aes_gcm_seal(keys_for(w, p->group)->data, nonce, aad, sizeof aad, p->out, n, p->out + n);
        n += XIZ_TAG;
    }
    p->f.csize = (uint32_t)n;
    p->f.group = w->dir ? p->group : 0;
    p->f.crc = xiz_crc32c(0, p->out, n);
    p->n = n;
}

#if defined(_WIN32)
static unsigned __stdcall seal_thread(void *arg) { seal_frame(arg); return 0; }
#else
static void *seal_thread(void *arg) { seal_frame(arg); return NULL; }
#endif

static int cpu_count(void) {
#if defined(_WIN32)
    DWORD n = GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
    return n ? (int)n : 1;
#else
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    return n > 0 ? (int)n : 1;
#endif
}

static void start_batch(xiz_writer *w, int set) {
    for (uint32_t i = 0; i < w->filled[set]; i++) {
        wframe *p = &w->slots[set][i];
        p->started = 0;
        if (w->threads > 1) {
#if defined(_WIN32)
            p->thread = (HANDLE)_beginthreadex(NULL, 0, seal_thread, p, 0, NULL);
            p->started = p->thread != 0;
#else
            p->started = pthread_create(&p->thread, NULL, seal_thread, p) == 0;
#endif
        }
        if (!p->started) seal_frame(p);  /* one thread, or no thread available */
    }
    w->running = set;
}

static void join_batch(xiz_writer *w, int set) {
    for (uint32_t i = 0; i < w->filled[set]; i++) {
        wframe *p = &w->slots[set][i];
        if (!p->started) continue;
#if defined(_WIN32)
        WaitForSingleObject(p->thread, INFINITE);
        CloseHandle(p->thread);
#else
        pthread_join(p->thread, NULL);
#endif
        p->started = 0;
    }
}

/* Waits for the batch being compressed and writes its frames, in order. */
static int write_batch(xiz_writer *w, xiz_error *err) {
    if (w->running < 0) return XIZ_OK;
    int set = w->running;
    w->running = -1;
    join_batch(w, set);
    int rc = XIZ_OK;
    for (uint32_t i = 0; i < w->filled[set] && rc == XIZ_OK; i++) {
        wframe *p = &w->slots[set][i];
        if (p->fail) { rc = FAIL(XIZ_E_NOMEM, "out of memory"); break; }
        if (w->n_frames == w->cap_frames) {
            uint32_t cap = w->cap_frames ? w->cap_frames * 2 : 64;
            frame_rec *nf = realloc(w->frames, cap * sizeof(frame_rec));
            if (!nf) { rc = FAIL(XIZ_E_NOMEM, "out of memory"); break; }
            w->frames = nf;
            w->cap_frames = cap;
        }
        p->f.offset = w->pos;
        uint8_t hdr[XIZ_FRAME_HEADER];
        frame_header_encode(p->index, &p->f, hdr);
        if ((rc = w_write(w, hdr, sizeof hdr, err)) == XIZ_OK && (rc = w_write(w, p->out, p->n, err)) == XIZ_OK)
            w->frames[w->n_frames++] = p->f;
    }
    w->filled[set] = 0;
    return rc;
}

/* The current frame is complete (or the data ends): it joins the batch; a full batch starts
 * compressing while the next one fills, after the previous one is written. */
static int flush_frame(xiz_writer *w, int final, xiz_error *err) {
    int cur = w->cur;
    if (w->used) {
        wframe *p = &w->slots[cur][w->filled[cur]++];
        p->used = w->used;
        p->index = w->next_index++;
        p->group = w->cur_group;
        w->used = 0;
    }
    if (w->filled[cur] == (uint32_t)w->threads || (final && w->filled[cur])) {
        TRY(write_batch(w, err));
        start_batch(w, cur);
        w->cur = cur ^ 1;
    }
    if (final) TRY(write_batch(w, err));
    w->buf = w->slots[w->cur][w->filled[w->cur]].in;
    return XIZ_OK;
}

static int add_extent(wentry *e, uint32_t frame, uint32_t off, uint32_t len) {
    if (e->n_ext && e->ext[e->n_ext - 1].frame == frame && e->ext[e->n_ext - 1].offset + e->ext[e->n_ext - 1].length == off) {
        e->ext[e->n_ext - 1].length += len;
        return 1;
    }
    extent_rec *ne = realloc(e->ext, (e->n_ext + 1) * sizeof(extent_rec));
    if (!ne) return 0;
    e->ext = ne;
    e->ext[e->n_ext].frame = frame;
    e->ext[e->n_ext].offset = off;
    e->ext[e->n_ext].length = len;
    e->n_ext++;
    return 1;
}

static int put_data(xiz_writer *w, wentry *e, const uint8_t *d, size_t n, xiz_error *err) {
    if (w->dir && e->group != w->cur_group) {  /* a frame holds one group's data only */
        if (w->used) TRY(flush_frame(w, 0, err));
        w->cur_group = e->group;
    }
    while (n) {
        uint32_t room = w->frame_size - w->used;
        uint32_t k = n < room ? (uint32_t)n : room;
        memcpy(w->buf + w->used, d, k);
        if (!add_extent(e, w->next_index, w->used, k)) return FAIL(XIZ_E_NOMEM, "out of memory");
        w->used += k;
        d += k;
        n -= k;
        if (w->used == w->frame_size) TRY(flush_frame(w, 0, err));
    }
    return XIZ_OK;
}

/* ------------------------------------------------------------------ entries */

static void entry_free(wentry *e) {
    free(e->path);
    free(e->link);
    free(e->ext);
    memset(e, 0, sizeof *e);
}

/* Normalized archive path: no leading '/', no empty, "." or ".." component, no NUL. */
static char *norm_path(const char *p, size_t *len, xiz_error *err) {
    size_t n = strlen(p);
    char *o = malloc(n + 1);
    if (!o) { FAIL(XIZ_E_NOMEM, "out of memory"); return NULL; }
    size_t k = 0, i = 0;
    while (i < n) {
        size_t j = i;
        while (j < n && p[j] != '/') j++;
        size_t cl = j - i;
        if (cl == 2 && p[i] == '.' && p[i + 1] == '.') { free(o); FAIL(XIZ_E_ARG, "\"..\" in %s", p); return NULL; }
        if (cl > 255) { free(o); FAIL(XIZ_E_ARG, "component longer than 255 bytes in %s", p); return NULL; }
        if (cl && !(cl == 1 && p[i] == '.')) {
            if (k) o[k++] = '/';
            memcpy(o + k, p + i, cl);
            k += cl;
        }
        i = j + 1;
    }
    o[k] = 0;
    if (!k || k > 65535) { free(o); FAIL(XIZ_E_ARG, "invalid archive path \"%s\"", p); return NULL; }
    *len = k;
    return o;
}

static int under(const wentry *e, const char *p, size_t n) {
    return e->path_len == n ? memcmp(e->path, p, n) == 0
                            : e->path_len > n && memcmp(e->path, p, n) == 0 && e->path[n] == '/';
}

static wentry *new_entry(xiz_writer *w, uint8_t type, const char *path, const xiz_entry_meta *m, xiz_error *err) {
    size_t len;
    char *p = norm_path(path, &len, err);
    if (!p) return NULL;
    for (size_t i = 0; i < w->n_entries; i++) {
        wentry *o = &w->entries[i];
        if (!o->removed && o->path_len == len && memcmp(o->path, p, len) == 0) {
            if (o->type == 1 && type == 1) { free(p); return o; }  /* folders merge */
            o->removed = 1;                                        /* files replace */
        }
    }
    if (w->n_entries == w->cap_entries) {
        size_t cap = w->cap_entries ? w->cap_entries * 2 : 64;
        wentry *ne = realloc(w->entries, cap * sizeof(wentry));
        if (!ne) { free(p); FAIL(XIZ_E_NOMEM, "out of memory"); return NULL; }
        w->entries = ne;
        w->cap_entries = cap;
    }
    wentry *e = &w->entries[w->n_entries++];
    memset(e, 0, sizeof *e);
    e->type = type;
    e->path = p;
    e->path_len = len;
    e->group = group_of(w, p);
    e->mode = m && m->mode ? (uint16_t)(m->mode & 07777) : (type == 1 ? 0755 : 0644);
    if (m) {
        e->uid = m->uid;
        e->gid = m->gid;
        e->mtime = m->mtime_sec;
        e->nsec = m->mtime_nsec;
    }
    return e;
}

static int check_writer(xiz_writer *w, xiz_error *err) {
    if (!w) return FAIL(XIZ_E_ARG, "no writer");
    if (w->failed) return FAIL(XIZ_E_IO, "the writer failed earlier");
    return XIZ_OK;
}

/* A previous entry with the same content: reuse its extents (file-level deduplication). */
static const wentry *find_same(const xiz_writer *w, const wentry *e) {
    for (size_t i = 0; i + 1 < w->n_entries; i++) {
        const wentry *o = &w->entries[i];
        if (o->type == 0 && o->has_plain_sha && o->group == e->group && o->size == e->size &&
            memcmp(o->plain_sha, e->plain_sha, 32) == 0)  /* inside a group only (§13.2) */
            return o;
    }
    return NULL;
}

static int reuse(wentry *e, const wentry *same, xiz_error *err) {
    e->ext = malloc(same->n_ext * sizeof(extent_rec) + 1);
    if (!e->ext) return FAIL(XIZ_E_NOMEM, "out of memory");
    if (same->n_ext) memcpy(e->ext, same->ext, same->n_ext * sizeof(extent_rec));
    e->n_ext = same->n_ext;
    memcpy(e->digest, same->digest, 32);
    e->has_digest = same->has_digest;
    return XIZ_OK;
}

int xiz_writer_add_data(xiz_writer *w, const char *path, const void *data, size_t len, const xiz_entry_meta *meta,
                        xiz_error *err) {
    TRY(check_writer(w, err));
    wentry *e = new_entry(w, 0, path, meta, err);
    if (!e) return err ? err->code : XIZ_E_ARG;
    e->size = len;
    sha256(data, len, e->plain_sha);
    e->has_plain_sha = 1;
    const wentry *same = find_same(w, e);
    if (same) return reuse(e, same, err);
    if (w->encrypted) {
        hmac_ctx h;
        hmac_init(&h, keys_for(w, e->group)->mac);
        hmac_update(&h, data, len);
        hmac_final(&h, e->digest);
    } else {
        memcpy(e->digest, e->plain_sha, 32);
    }
    e->has_digest = 1;
    return put_data(w, e, data, len, err);
}

/* ------------------------------------------------------------------ files from disk */

typedef struct {
#if defined(_WIN32)
    HANDLE h;
#else
    int fd;
#endif
} rfile;

static int rf_open(rfile *f, const char *p) {
#if defined(_WIN32)
    wchar_t *wp = xiz_utf8_to_wide(p);
    f->h = wp ? CreateFileW(wp, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL)
              : INVALID_HANDLE_VALUE;
    free(wp);
    return f->h == INVALID_HANDLE_VALUE ? -1 : 0;
#else
    f->fd = open(p, O_RDONLY | O_CLOEXEC);
    return f->fd < 0 ? -1 : 0;
#endif
}

static long rf_read(rfile *f, uint8_t *b, size_t n) {
#if defined(_WIN32)
    DWORD got = 0;
    if (!ReadFile(f->h, b, (DWORD)n, &got, NULL)) return -1;
    return (long)got;
#else
    for (;;) {
        ssize_t r = read(f->fd, b, n);
        if (r < 0 && errno == EINTR) continue;
        return (long)r;
    }
#endif
}

static void rf_rewind(rfile *f) {
#if defined(_WIN32)
    LARGE_INTEGER z;
    z.QuadPart = 0;
    SetFilePointerEx(f->h, z, NULL, FILE_BEGIN);
#else
    lseek(f->fd, 0, SEEK_SET);
#endif
}

static void rf_close(rfile *f) {
#if defined(_WIN32)
    CloseHandle(f->h);
#else
    close(f->fd);
#endif
}

#define IOBUF (1u << 20)

int xiz_writer_add_file(xiz_writer *w, const char *path, const char *disk_path, const xiz_entry_meta *meta,
                        xiz_error *err) {
    TRY(check_writer(w, err));
    rfile f;
    if (rf_open(&f, disk_path) != 0) return FAIL(XIZ_E_IO, "cannot open %s", disk_path);
    uint8_t *b = malloc(IOBUF);
    if (!b) { rf_close(&f); return FAIL(XIZ_E_NOMEM, "out of memory"); }
    /* First pass: plain SHA-256 (deduplication) and the stored digest. */
    sha256_ctx sc;
    hmac_ctx hc;
    sha256_init(&sc);
    if (w->encrypted) hmac_init(&hc, keys_for(w, group_of(w, path))->mac);
    uint64_t size = 0;
    long r;
    int rc = XIZ_OK;
    while ((r = rf_read(&f, b, IOBUF)) > 0) {
        sha256_update(&sc, b, (size_t)r);
        if (w->encrypted) hmac_update(&hc, b, (size_t)r);
        size += (uint64_t)r;
        w->read_bytes += (uint64_t)r;
        if (w->progress && w->progress(w->progress_ctx, w->read_bytes, 0)) { rc = FAIL(XIZ_E_CALLBACK, "cancelled"); break; }
    }
    if (!rc && r < 0) rc = FAIL(XIZ_E_IO, "cannot read %s", disk_path);
    wentry *e = rc ? NULL : new_entry(w, 0, path, meta, err);
    if (!rc && !e) rc = err ? err->code : XIZ_E_ARG;
    uint8_t mac[32];
    if (w->encrypted) hmac_final(&hc, mac);
    if (!rc && e) {
        e->size = size;
        sha256_final(&sc, e->plain_sha);
        e->has_plain_sha = 1;
        memcpy(e->digest, w->encrypted ? mac : e->plain_sha, 32);
        e->has_digest = 1;
        const wentry *same = find_same(w, e);
        if (same) {
            rc = reuse(e, same, err);
        } else {
            /* Second pass: the data; the file must not change in between. */
            rf_rewind(&f);
            sha256_ctx again;
            sha256_init(&again);
            uint64_t got = 0;
            while (!rc && (r = rf_read(&f, b, IOBUF)) > 0) {
                if (got + (uint64_t)r > size) { rc = FAIL(XIZ_E_IO, "%s changed while being read", disk_path); break; }
                sha256_update(&again, b, (size_t)r);
                rc = put_data(w, e, b, (size_t)r, err);
                got += (uint64_t)r;
                w->read_bytes += (uint64_t)r;
                if (!rc && w->progress && w->progress(w->progress_ctx, w->read_bytes, 0)) {
                    w->failed = 1;
                    rc = FAIL(XIZ_E_CALLBACK, "cancelled");
                }
            }
            uint8_t h2[32];
            sha256_final(&again, h2);
            if (!rc && (r < 0 || got != size || memcmp(h2, e->plain_sha, 32) != 0)) {
                w->failed = 1;  /* data already in frames: the archive cannot be finished consistently */
                rc = FAIL(XIZ_E_IO, "%s changed while being read", disk_path);
            }
        }
    }
    free(b);
    rf_close(&f);
    return rc;
}

int xiz_writer_add_directory(xiz_writer *w, const char *path, const xiz_entry_meta *meta, xiz_error *err) {
    TRY(check_writer(w, err));
    wentry *e = new_entry(w, 1, path, meta, err);
    return e ? XIZ_OK : (err ? err->code : XIZ_E_ARG);
}

int xiz_writer_add_symlink(xiz_writer *w, const char *path, const char *target, const xiz_entry_meta *meta,
                           xiz_error *err) {
    TRY(check_writer(w, err));
    wentry *e = new_entry(w, 2, path, meta, err);
    if (!e) return err ? err->code : XIZ_E_ARG;
    e->link_len = strlen(target);
    e->link = malloc(e->link_len + 1);
    if (!e->link) return FAIL(XIZ_E_NOMEM, "out of memory");
    memcpy(e->link, target, e->link_len + 1);
    if (!meta || !meta->mode) e->mode = 0755;
    return XIZ_OK;
}

int xiz_writer_remove(xiz_writer *w, const char *path, xiz_error *err) {
    TRY(check_writer(w, err));
    size_t n;
    char *p = norm_path(path, &n, err);
    if (!p) return err ? err->code : XIZ_E_ARG;
    int found = 0;
    for (size_t i = 0; i < w->n_entries; i++)
        if (!w->entries[i].removed && under(&w->entries[i], p, n)) { w->entries[i].removed = 1; found = 1; }
    free(p);
    return found ? XIZ_OK : FAIL(XIZ_E_NOT_FOUND, "no entry %s", path);
}

static int cmp_names(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

#if defined(_WIN32)
/* Windows has no mode bits: folders 0755, files 0644, read-only files 0444; mtime from the
 * last-write FILETIME (100 ns ticks since 1601). */
static void win_meta(DWORD attrs, const FILETIME *ft, xiz_entry_meta *m) {
    memset(m, 0, sizeof *m);
    m->mode = (attrs & FILE_ATTRIBUTE_DIRECTORY) ? 0755 : (attrs & FILE_ATTRIBUTE_READONLY) ? 0444 : 0644;
    uint64_t t = (uint64_t)ft->dwHighDateTime << 32 | ft->dwLowDateTime;
    m->mtime_sec = (int64_t)(t / 10000000u) - 11644473600LL;
    m->mtime_nsec = (uint32_t)(t % 10000000u) * 100u;
}
#else

static void meta_of(const struct stat *st, xiz_entry_meta *m) {
    memset(m, 0, sizeof *m);
    m->mode = (uint16_t)(st->st_mode & 07777);  /* 0 (chmod 000) falls back to the default */
    m->uid = (uint32_t)st->st_uid;
    m->gid = (uint32_t)st->st_gid;
    m->mtime_sec = (int64_t)st->st_mtime;
#  if defined(__APPLE__)
    m->mtime_nsec = (uint32_t)st->st_mtimespec.tv_nsec;
#  else
    m->mtime_nsec = (uint32_t)st->st_mtim.tv_nsec;
#  endif
}
#endif

int xiz_writer_add_tree(xiz_writer *w, const char *path, const char *disk_path, xiz_error *err) {
    TRY(check_writer(w, err));
#if defined(_WIN32)
    wchar_t *wp = xiz_utf8_to_wide(disk_path);
    WIN32_FILE_ATTRIBUTE_DATA fa;
    if (!wp || !GetFileAttributesExW(wp, GetFileExInfoStandard, &fa)) { free(wp); return FAIL(XIZ_E_IO, "cannot stat %s", disk_path); }
    xiz_entry_meta m;
    win_meta(fa.dwFileAttributes, &fa.ftLastWriteTime, &m);
    if (!(fa.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) { free(wp); return xiz_writer_add_file(w, path, disk_path, &m, err); }
    int rc = xiz_writer_add_directory(w, path, &m, err);
    if (rc) { free(wp); return rc; }
    size_t wl = wcslen(wp);
    wchar_t *pat = malloc((wl + 3) * sizeof(wchar_t));
    if (!pat) { free(wp); return FAIL(XIZ_E_NOMEM, "out of memory"); }
    wcscpy(pat, wp);
    wcscat(pat, L"\\*");
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(pat, &fd);
    free(pat);
    free(wp);
    if (h == INVALID_HANDLE_VALUE) return XIZ_OK;
    char **names = NULL;
    size_t n = 0, cap = 0;
    do {
        if (!wcscmp(fd.cFileName, L".") || !wcscmp(fd.cFileName, L"..")) continue;
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) continue;  /* links and junctions are not followed */
        /* Explorer's own files, as .DS_Store on a Mac (docs/STUDIO_WINDOWS_XIZ.md §12.3). */
        if (!_wcsicmp(fd.cFileName, L"desktop.ini") || !_wcsicmp(fd.cFileName, L"Thumbs.db")) continue;
        char name[1024];
        if (!WideCharToMultiByte(CP_UTF8, 0, fd.cFileName, -1, name, sizeof name, NULL, NULL)) continue;
        if (n == cap) {
            cap = cap ? cap * 2 : 32;
            char **nn = realloc(names, cap * sizeof *names);
            if (!nn) { rc = FAIL(XIZ_E_NOMEM, "out of memory"); break; }
            names = nn;
        }
        names[n] = malloc(strlen(name) + 1);
        if (!names[n]) { rc = FAIL(XIZ_E_NOMEM, "out of memory"); break; }
        strcpy(names[n++], name);
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    if (n) qsort(names, n, sizeof *names, cmp_names);  /* reproducible order, as on POSIX */
    for (size_t i = 0; i < n && !rc; i++) {
        size_t n1 = strlen(path) + strlen(names[i]) + 2, n2 = strlen(disk_path) + strlen(names[i]) + 2;
        char *ap = malloc(n1), *dp = malloc(n2);
        if (!ap || !dp) { free(ap); free(dp); rc = FAIL(XIZ_E_NOMEM, "out of memory"); break; }
        snprintf(ap, n1, "%s/%s", path, names[i]);
        snprintf(dp, n2, "%s\\%s", disk_path, names[i]);
        rc = xiz_writer_add_tree(w, ap, dp, err);
        free(ap);
        free(dp);
    }
    for (size_t i = 0; i < n; i++) free(names[i]);
    free(names);
    return rc;
#else
    struct stat st;
    if (lstat(disk_path, &st) != 0) return FAIL(XIZ_E_IO, "cannot stat %s: %s", disk_path, strerror(errno));
    xiz_entry_meta m;
    meta_of(&st, &m);
    if (S_ISREG(st.st_mode)) return xiz_writer_add_file(w, path, disk_path, &m, err);
    if (S_ISLNK(st.st_mode)) {
        char t[4096];
        ssize_t k = readlink(disk_path, t, sizeof t - 1);
        if (k < 0) return FAIL(XIZ_E_IO, "cannot read link %s", disk_path);
        t[k] = 0;
        return xiz_writer_add_symlink(w, path, t, &m, err);
    }
    if (!S_ISDIR(st.st_mode)) return XIZ_OK;  /* devices, sockets, fifos: not archived */
    TRY(xiz_writer_add_directory(w, path, &m, err));
    DIR *d = opendir(disk_path);
    if (!d) return FAIL(XIZ_E_IO, "cannot open %s: %s", disk_path, strerror(errno));
    char **names = NULL;
    size_t n = 0, cap = 0;
    struct dirent *de;
    int rc = XIZ_OK;
    while ((de = readdir(d))) {
        if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, "..")) continue;
        if (n == cap) {
            cap = cap ? cap * 2 : 32;
            char **nn = realloc(names, cap * sizeof *names);
            if (!nn) { rc = FAIL(XIZ_E_NOMEM, "out of memory"); break; }
            names = nn;
        }
        names[n] = malloc(strlen(de->d_name) + 1);
        if (!names[n]) { rc = FAIL(XIZ_E_NOMEM, "out of memory"); break; }
        strcpy(names[n++], de->d_name);
    }
    closedir(d);
    if (n) qsort(names, n, sizeof *names, cmp_names);  /* reproducible order */
    for (size_t i = 0; i < n && !rc; i++) {
        size_t n1 = strlen(path) + strlen(names[i]) + 2, n2 = strlen(disk_path) + strlen(names[i]) + 2;
        char *ap = malloc(n1), *dp = malloc(n2);
        if (!ap || !dp) { free(ap); free(dp); rc = FAIL(XIZ_E_NOMEM, "out of memory"); break; }
        snprintf(ap, n1, "%s/%s", path, names[i]);
        snprintf(dp, n2, "%s/%s", disk_path, names[i]);
        rc = xiz_writer_add_tree(w, ap, dp, err);
        free(ap);
        free(dp);
    }
    for (size_t i = 0; i < n; i++) free(names[i]);
    free(names);
    return rc;
#endif
}

/* ------------------------------------------------------------------ create / append */

static xiz_writer *writer_new(const xiz_writer_options *opt) {
    xiz_writer *w = calloc(1, sizeof *w);
    if (!w) return NULL;
#if defined(_WIN32)
    w->h = INVALID_HANDLE_VALUE;
#else
    w->fd = -1;
#endif
    w->level = opt && opt->level ? opt->level : 9;
    if (w->level < 1) w->level = 1;
    if (w->level > 22) w->level = 22;
    w->frame_size = opt && opt->frame_size ? opt->frame_size : 4u << 20;
    if (w->frame_size > XIZ_MAX_FRAME_DATA) w->frame_size = XIZ_MAX_FRAME_DATA;
    if (w->frame_size < 4096) w->frame_size = 4096;
    int t = opt && opt->threads > 0 ? opt->threads : cpu_count();
    w->threads = t < 1 ? 1 : t > 8 && !(opt && opt->threads > 0) ? 8 : t > XIZ_WRITER_MAX_THREADS ? XIZ_WRITER_MAX_THREADS : t;
    w->running = -1;
    if (opt) { w->progress = opt->progress; w->progress_ctx = opt->progress_ctx; }
    for (int s = 0; s < 2; s++) {
        w->slots[s] = calloc((size_t)w->threads, sizeof(wframe));
        if (!w->slots[s]) { free(w->slots[0]); free(w); return NULL; }
        for (int i = 0; i < w->threads; i++) {
            w->slots[s][i].w = w;
            w->slots[s][i].in = malloc(w->frame_size);
            if (!w->slots[s][i].in) {
                for (int q = 0; q <= s; q++) {
                    for (int j = 0; j < w->threads; j++) free(w->slots[q][j].in);
                    free(w->slots[q]);
                }
                free(w);
                return NULL;
            }
        }
    }
    w->buf = w->slots[0][0].in;
    return w;
}

static void writer_free(xiz_writer *w) {
    if (!w) return;
    w_close_file(w);
    for (size_t i = 0; i < w->n_entries; i++) entry_free(&w->entries[i]);
    free(w->entries);
    free(w->frames);
    if (w->running >= 0) join_batch(w, w->running);
    for (uint16_t g = 0; g < w->n_groups; g++) {
        if (w->gname) free(w->gname[g]);
        if (w->gprefix && w->gprefix[g]) {
            for (size_t k = 0; k < w->gnprefix[g]; k++) free(w->gprefix[g][k]);
            free(w->gprefix[g]);
        }
    }
    if (w->gkeys) secure_zero(w->gkeys, w->n_groups * sizeof(keyset));
    free(w->gkeys);
    free(w->gname);
    free(w->gprefix);
    free(w->gnprefix);
    if (w->keys_block) secure_zero(w->keys_block, w->keys_len);
    free(w->keys_block);
    for (int s = 0; s < 2; s++) {
        if (!w->slots[s]) continue;
        for (int i = 0; i < w->threads; i++) {
            free(w->slots[s][i].in);
            free(w->slots[s][i].out);
        }
        free(w->slots[s]);
    }
    free(w->path);
    free(w->tmp_path);
    secure_zero(&w->keys, sizeof w->keys);
    if (w->source) xiz_close(w->source);
    free(w);
}

static char *dup_str(const char *s) {
    size_t n = strlen(s) + 1;
    char *d = malloc(n);
    if (d) memcpy(d, s, n);
    return d;
}

/* ------------------------------------------------------------------ XIZ 1.3 keys block (§13.3, §17, §24) */

#define XIZ_WRITER_MAX_GROUPS 64

static int recipient_kind_ok(int t) {
    return t == XIZ_RECIPIENT_PASSWORD || t == XIZ_RECIPIENT_X25519 || t == XIZ_RECIPIENT_XWING;
}

static size_t label_len(const char *l) { return l ? strlen(l) : 0; }

/* Credential header lengths: password (Argon2id) 44, X25519 40, X-Wing 1128. */
static size_t cred_len(int t) { return t == XIZ_RECIPIENT_PASSWORD ? 44 : t == XIZ_RECIPIENT_X25519 ? 40 : 1128; }

/* Writes the credential header of `t` into `h` and derives its key-encryption key. */
static int put_credential(wbuf *h, int t, const char *password, const uint8_t *pub, uint32_t mem, uint32_t it, uint32_t par,
                          uint8_t kek[32], xiz_error *err) {
    if (t == XIZ_RECIPIENT_PASSWORD) {
        uint8_t salt[32];
        if (!password) return FAIL(XIZ_E_ARG, "a password recipient without a password");
        if (xiz_random(salt, 32)) return FAIL(XIZ_E_IO, "no randomness");
        wb_u32(h, mem); wb_u32(h, it); wb_u32(h, par); wb_put(h, salt, 32);
        if (argon2id_kek(password, salt, mem, it, par, kek) != 0) return FAIL(XIZ_E_NOMEM, "Argon2id failed");
        return XIZ_OK;
    }
    if (!pub) return FAIL(XIZ_E_ARG, "a key recipient without a public key");
    uint8_t id[32];
    if (t == XIZ_RECIPIENT_X25519) {
        uint8_t esk[32], epk[32], shared[32], salt[64];
        static const uint8_t zero[32];
        if (xiz_random(esk, 32)) return FAIL(XIZ_E_IO, "no randomness");
        crypto_x25519_public_key(epk, esk);
        crypto_x25519(shared, esk, pub);
        secure_zero(esk, 32);
        if (ct_equal(shared, zero, 32)) return FAIL(XIZ_E_ARG, "invalid X25519 public key");
        sha256(pub, 32, id);
        memcpy(salt, epk, 32);
        memcpy(salt + 32, pub, 32);
        hkdf_sha256(shared, 32, salt, 64, "xiz/1.3/x25519", kek, 32);
        secure_zero(shared, 32);
        wb_put(h, epk, 32);
        wb_put(h, id, 8);
        return XIZ_OK;
    }
    uint8_t ct[1120], ss[32];
    if (!xwing_encap(pub, ct, ss)) return FAIL(XIZ_E_ARG, "invalid post-quantum public key");
    sha256(pub, 1216, id);
    hkdf_sha256(ss, 32, id, 8, "xiz/1.7/xwing", kek, 32);
    secure_zero(ss, 32);
    wb_put(h, ct, 1120);
    wb_put(h, id, 8);
    return XIZ_OK;
}

static void put_label(wbuf *h, const char *label) {
    size_t l = label_len(label);
    wb_u8(h, (uint8_t)l);
    if (l) wb_put(h, label, l);
}

/* type ‖ length ‖ header ‖ nonce ‖ AES-GCM(kek, plain) ‖ tag, with aad = superblock[0..<60] ‖ type ‖ header. */
static int put_box(wbuf *blk, const uint8_t sbb[XIZ_SUPERBLOCK], uint8_t type, const wbuf *h, const uint8_t kek[32],
                   const uint8_t *plain, size_t plen, xiz_error *err) {
    uint8_t nonce[12], tag[16];
    uint8_t *aad = malloc(61 + h->n), *ct = malloc(plen + 1);
    if (!aad || !ct || h->oom) { free(aad); free(ct); return FAIL(XIZ_E_NOMEM, "out of memory"); }
    if (xiz_random(nonce, 12)) { free(aad); free(ct); return FAIL(XIZ_E_IO, "no randomness"); }
    memcpy(aad, sbb, 60);
    aad[60] = type;
    memcpy(aad + 61, h->p, h->n);
    memcpy(ct, plain, plen);
    aes_gcm_seal(kek, nonce, aad, 61 + h->n, ct, plen, tag);
    wb_u8(blk, type);
    wb_u16(blk, (uint16_t)(h->n + 12 + plen + 16));
    wb_put(blk, h->p, h->n);
    wb_put(blk, nonce, 12);
    wb_put(blk, ct, plen);
    wb_put(blk, tag, 16);
    free(aad);
    secure_zero(ct, plen);
    free(ct);
    return XIZ_OK;
}

static size_t bundle_len(const uint16_t *groups, size_t count, uint16_t n_groups) {
    return 2 + 34 * (groups ? count : n_groups);
}

static void put_bundle(wbuf *b, const uint16_t *groups, size_t count, uint16_t n_groups, const uint8_t (*gk)[32]) {
    size_t n = groups ? count : n_groups;
    wb_u16(b, (uint16_t)n);
    for (size_t i = 0; i < n; i++) {
        uint16_t g = groups ? groups[i] : (uint16_t)i;
        wb_u16(b, g);
        wb_put(b, gk[g], 32);
    }
}

static int groups_ok(const uint16_t *groups, size_t count, uint16_t n_groups) {
    if (groups && !count) return 0;
    for (size_t i = 0; groups && i < count; i++) {
        if (groups[i] >= n_groups) return 0;
        for (size_t j = 0; j < i; j++)
            if (groups[j] == groups[i]) return 0;
    }
    return 1;
}

static char *norm_prefix(const char *p) {
    while (*p == '/') p++;
    size_t l = strlen(p);
    while (l && p[l - 1] == '/') l--;
    if (!l) return NULL;
    char *d = malloc(l + 1);
    if (d) { memcpy(d, p, l); d[l] = 0; }
    return d;
}

/* Groups, group keys and the keys block of a new XIZ 1.3 archive; fills w->sb and w->keys_block. */
static int setup_directory(xiz_writer *w, const xiz_writer_options *o, xiz_error *err) {
    if (o->password) return FAIL(XIZ_E_ARG, "with recipients a password is a recipient (XIZ_RECIPIENT_PASSWORD)");
    if (o->group_count + 1 > XIZ_WRITER_MAX_GROUPS) return FAIL(XIZ_E_LIMIT, "at most %d groups", XIZ_WRITER_MAX_GROUPS - 1);
    uint32_t mem = o->kdf_memory_kib ? o->kdf_memory_kib : 262144, it = o->kdf_iterations ? o->kdf_iterations : 3,
             par = o->kdf_parallelism ? o->kdf_parallelism : 4;
    if (mem < 19456 || mem > 2097152 || it < 1 || it > 10 || par < 1 || par > 16)
        return FAIL(XIZ_E_ARG, "Argon2id parameters outside what readers accept");
    uint16_t ng = (uint16_t)(o->group_count + 1);
    w->dir = 1;
    w->n_groups = ng;
    w->gkeys = calloc(ng, sizeof(keyset));
    w->gname = calloc(ng, sizeof(char *));
    w->gprefix = calloc(ng, sizeof(char **));
    w->gnprefix = calloc(ng, sizeof(size_t));
    if (!w->gkeys || !w->gname || !w->gprefix || !w->gnprefix) return FAIL(XIZ_E_NOMEM, "out of memory");
    for (uint16_t g = 1; g < ng; g++) {
        const xiz_group_spec *gs = &o->groups[g - 1];
        w->gname[g] = dup_str(gs->name ? gs->name : "");
        w->gprefix[g] = calloc(gs->prefix_count + 1, sizeof(char *));
        if (!w->gname[g] || !w->gprefix[g]) return FAIL(XIZ_E_NOMEM, "out of memory");
        if (!gs->prefix_count) return FAIL(XIZ_E_ARG, "group %u without folders", g);
        for (size_t k = 0; k < gs->prefix_count; k++) {
            if (!(w->gprefix[g][k] = norm_prefix(gs->prefixes[k]))) return FAIL(XIZ_E_ARG, "group %u: empty folder", g);
            w->gnprefix[g]++;
        }
    }
    /* Sizes first: the superblock, authenticated by every stanza, holds the block's length. */
    size_t total = 4 + 2 + 4, stanzas = 0;
    for (size_t i = 0; i < o->recipient_count; i++) {
        const xiz_recipient *r = &o->recipients[i];
        size_t L = label_len(r->label), B = bundle_len(r->groups, r->group_count, ng), h;
        if (L > 255 || !groups_ok(r->groups, r->group_count, ng)) return FAIL(XIZ_E_ARG, "recipient %zu: label or groups", i + 1);
        if (r->type == XIZ_RECIPIENT_PASSWORD_FACTOR) {
            if (!r->password || !r->factor) return FAIL(XIZ_E_ARG, "recipient %zu: password and factor", i + 1);
            h = 52;
        } else if (recipient_kind_ok(r->type)) {
            h = cred_len(r->type);
        } else {
            return FAIL(XIZ_E_ARG, "recipient %zu: type %d", i + 1, r->type);
        }
        total += 3 + h + 1 + L + 28 + B;
        stanzas++;
    }
    for (size_t t = 0; t < o->threshold_count; t++) {
        const xiz_threshold *th = &o->thresholds[t];
        size_t n = th->custodian_count, L = label_len(th->label);
        if (t > 255 || th->k < 2 || (size_t)th->k > n || n > 255 || L > 255 || !groups_ok(th->groups, th->group_count, ng))
            return FAIL(XIZ_E_ARG, "custodians %zu: k of n, label or groups", t + 1);
        total += 3 + 3 + 1 + L + 28 + bundle_len(th->groups, th->group_count, ng);
        stanzas++;
        for (size_t c = 0; c < n; c++) {
            const xiz_custodian *cu = &th->custodians[c];
            size_t cl = label_len(cu->label);
            if (!recipient_kind_ok(cu->type) || cl > 255) return FAIL(XIZ_E_ARG, "custodian %zu: type or label", c + 1);
            total += 3 + (cu->type == XIZ_RECIPIENT_XWING ? 2 + 1128 : 3 + cred_len(cu->type)) + 1 + cl + 28 + 32;
            stanzas++;
        }
    }
    if (!stanzas) return FAIL(XIZ_E_ARG, "no recipient");
    total += 3 + 2 + 34 * (size_t)ng;  /* key commitment (§24.1) */
    stanzas++;
    if (total > 65536 || stanzas > 65535) return FAIL(XIZ_E_LIMIT, "too many recipients for the 64 KiB keys block");
    w->encrypted = 1;
    w->sb.minor = 14;
    w->sb.required = XIZ_FEATURE_ENCRYPTED | XIZ_FEATURE_DIRECTORY;
    w->sb.keys_length = (uint32_t)total;
    uint8_t sbb[XIZ_SUPERBLOCK];
    superblock_encode(&w->sb, sbb);
    uint8_t (*gk)[32] = malloc((size_t)ng * 32);
    if (!gk || xiz_random(gk, (size_t)ng * 32)) { free(gk); return FAIL(XIZ_E_IO, "no randomness"); }
    for (uint16_t g = 0; g < ng; g++) keyset_derive(&w->gkeys[g], gk[g], w->sb.id);
    wbuf blk = {0};
    wb_put(&blk, "XKEY", 4);
    wb_u16(&blk, (uint16_t)stanzas);
    int rc = XIZ_OK;
    uint8_t kek[32];
    for (size_t i = 0; i < o->recipient_count && rc == XIZ_OK; i++) {
        const xiz_recipient *r = &o->recipients[i];
        wbuf h = {0}, b = {0};
        uint8_t type = (uint8_t)r->type;
        if (r->type == XIZ_RECIPIENT_PASSWORD_FACTOR) {
            /* KEK = HKDF(Argon2id(password) ‖ factor, salt = archive_id) (§24.3) */
            uint8_t a[32], ikm[64], fid[32];
            rc = put_credential(&h, XIZ_RECIPIENT_PASSWORD, r->password, NULL, mem, it, par, a, err);
            if (rc == XIZ_OK) {
                sha256(r->factor, 32, fid);
                wb_put(&h, fid, 8);
                memcpy(ikm, a, 32);
                memcpy(ikm + 32, r->factor, 32);
                hkdf_sha256(ikm, 64, w->sb.id, 16, "xiz/1.14/password+factor", kek, 32);
            }
            secure_zero(a, 32);
            secure_zero(ikm, 64);
        } else {
            rc = put_credential(&h, r->type, r->password, r->public_key, mem, it, par, kek, err);
        }
        put_label(&h, r->label);
        put_bundle(&b, r->groups, r->group_count, ng, (const uint8_t(*)[32])gk);
        if (rc == XIZ_OK) rc = put_box(&blk, sbb, type, &h, kek, b.p, b.n, err);
        if (b.p) secure_zero(b.p, b.n);
        wb_free(&h);
        wb_free(&b);
    }
    for (size_t t = 0; t < o->threshold_count && rc == XIZ_OK; t++) {
        const xiz_threshold *th = &o->thresholds[t];
        uint8_t secret[32], (*shares)[32] = malloc(th->custodian_count * 32);
        if (!shares || xiz_random(secret, 32) || !shamir_split(secret, th->k, (int)th->custodian_count, shares)) {
            free(shares);
            rc = FAIL(XIZ_E_IO, "no randomness");
            break;
        }
        wbuf h = {0}, b = {0};
        wb_u8(&h, (uint8_t)t);
        wb_u8(&h, (uint8_t)th->k);
        wb_u8(&h, (uint8_t)th->custodian_count);
        put_label(&h, th->label);
        put_bundle(&b, th->groups, th->group_count, ng, (const uint8_t(*)[32])gk);
        hkdf_sha256(secret, 32, w->sb.id, 16, "xiz/1.3/threshold", kek, 32);
        rc = put_box(&blk, sbb, 4, &h, kek, b.p, b.n, err);
        if (b.p) secure_zero(b.p, b.n);
        wb_free(&h);
        wb_free(&b);
        for (size_t c = 0; c < th->custodian_count && rc == XIZ_OK; c++) {
            const xiz_custodian *cu = &th->custodians[c];
            wbuf sh = {0};
            wb_u8(&sh, (uint8_t)t);
            wb_u8(&sh, (uint8_t)(c + 1));
            uint8_t type = cu->type == XIZ_RECIPIENT_XWING ? 7 : 5;
            if (type == 5) wb_u8(&sh, cu->type == XIZ_RECIPIENT_PASSWORD ? 1 : 2);
            rc = put_credential(&sh, cu->type, cu->password, cu->public_key, mem, it, par, kek, err);
            put_label(&sh, cu->label);
            if (rc == XIZ_OK) rc = put_box(&blk, sbb, type, &sh, kek, shares[c], 32, err);
            wb_free(&sh);
        }
        secure_zero(secret, 32);
        secure_zero(shares, th->custodian_count * 32);
        free(shares);
    }
    secure_zero(kek, 32);
    if (rc == XIZ_OK) {
        wb_u8(&blk, 9);
        wb_u16(&blk, (uint16_t)(2 + 34 * ng));
        wb_u16(&blk, ng);
        for (uint16_t g = 0; g < ng; g++) {
            uint8_t c[32];
            hkdf_sha256(gk[g], 32, w->sb.id, 16, "xiz/1.14/commit", c, 32);
            wb_u16(&blk, g);
            wb_put(&blk, c, 32);
        }
        wb_u32(&blk, xiz_crc32c(0, blk.p, blk.n));
        if (blk.oom) rc = FAIL(XIZ_E_NOMEM, "out of memory");
        else if (blk.n != total) rc = FAIL(XIZ_E_ARG, "keys block of %zu bytes, %zu expected", blk.n, total);
    }
    secure_zero(gk, (size_t)ng * 32);
    free(gk);
    if (rc) { if (blk.p) secure_zero(blk.p, blk.n); wb_free(&blk); return rc; }
    w->keys_block = blk.p;
    w->keys_len = blk.n;
    return XIZ_OK;
}

int xiz_writer_create(xiz_writer **out, const char *path, const xiz_writer_options *opt, int overwrite, xiz_error *err) {
    if (!out || !path) return FAIL(XIZ_E_ARG, "missing argument");
    *out = NULL;
    xiz_writer *w = writer_new(opt);
    if (!w) return FAIL(XIZ_E_NOMEM, "out of memory");
    int rc = XIZ_OK;
    w->overwrite = overwrite;
    w->path = dup_str(path);
    w->tmp_path = malloc(strlen(path) + 16);
    if (!w->path || !w->tmp_path) { writer_free(w); return FAIL(XIZ_E_NOMEM, "out of memory"); }
    sprintf(w->tmp_path, "%s.partial", path);
    if (!overwrite) {
        xiz_source s;
        if (xiz_source_file(&s, path, NULL) == XIZ_OK) {
            s.close(s.ctx);
            writer_free(w);
            return FAIL(XIZ_E_EXISTS, "%s already exists", path);
        }
    }
#if defined(_WIN32)
    wchar_t *wp = xiz_utf8_to_wide(w->tmp_path);
    w->h = wp ? CreateFileW(wp, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL) : INVALID_HANDLE_VALUE;
    free(wp);
    if (w->h == INVALID_HANDLE_VALUE) { writer_free(w); return FAIL(XIZ_E_IO, "cannot create %s", path); }
#else
    w->fd = open(w->tmp_path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
    if (w->fd < 0) {
        rc = FAIL(XIZ_E_IO, "cannot create %s: %s", w->tmp_path, strerror(errno));
        writer_free(w);
        return rc;
    }
#endif
    w->sb.major = 1;
    w->sb.minor = 0;
    if (xiz_random(w->sb.id, 16) != 0) { rc = FAIL(XIZ_E_IO, "no randomness"); goto fail; }
    if (opt && (opt->recipient_count || opt->threshold_count)) {
        if ((rc = setup_directory(w, opt, err))) goto fail;
        superblock_encode(&w->sb, w->sb.raw);
        if ((rc = w_write(w, w->sb.raw, XIZ_SUPERBLOCK, err)) || (rc = w_write(w, w->keys_block, w->keys_len, err))) goto fail;
        *out = w;
        return XIZ_OK;
    }
    /* "XKEY" ‖ count 2 ‖ type 1 (104) ‖ type 9 (36: the key commitment, XIZ 1.14 §24.1) ‖ CRC */
    uint8_t keys_block[4 + 2 + 3 + 104 + 3 + 36 + 4];
    if (opt && opt->password) {
        uint32_t mem = opt->kdf_memory_kib ? opt->kdf_memory_kib : 262144, it = opt->kdf_iterations ? opt->kdf_iterations : 3,
                 par = opt->kdf_parallelism ? opt->kdf_parallelism : 4;
        if (mem < 19456 || mem > 2097152 || it < 1 || it > 10 || par < 1 || par > 16) {
            rc = FAIL(XIZ_E_ARG, "Argon2id parameters outside what readers accept");
            goto fail;
        }
        w->encrypted = 1;
        w->sb.minor = 14;  /* every encrypted archive carries the commitment (§24.1) */
        w->sb.required = XIZ_FEATURE_ENCRYPTED;
        w->sb.keys_length = sizeof keys_block;
        uint8_t sbb[XIZ_SUPERBLOCK];
        superblock_encode(&w->sb, sbb);
        uint8_t file_key[32], salt[32], kek[32], nonce[12];
        if (xiz_random(file_key, 32) || xiz_random(salt, 32) || xiz_random(nonce, 12)) {
            rc = FAIL(XIZ_E_IO, "no randomness");
            goto fail;
        }
        if (argon2id_kek(opt->password, salt, mem, it, par, kek) != 0) { rc = FAIL(XIZ_E_NOMEM, "Argon2id failed"); goto fail; }
        uint8_t *k = keys_block;
        memcpy(k, "XKEY", 4);
        wr16(k + 4, 2);
        k[6] = 1;
        wr16(k + 7, 104);
        uint8_t *body = k + 9;
        wr32(body, mem);
        wr32(body + 4, it);
        wr32(body + 8, par);
        memcpy(body + 12, salt, 32);
        memcpy(body + 44, nonce, 12);
        memcpy(body + 56, file_key, 32);
        uint8_t aad[61 + 44];
        memcpy(aad, sbb, 60);
        aad[60] = 1;
        memcpy(aad + 61, body, 44);
        aes_gcm_seal(kek, nonce, aad, sizeof aad, body + 56, 32, body + 88);
        uint8_t *c9 = k + 113;
        c9[0] = 9;
        wr16(c9 + 1, 36);
        wr16(c9 + 3, 1);  /* one entry: group 0, the file key */
        wr16(c9 + 5, 0);
        hkdf_sha256(file_key, 32, w->sb.id, 16, "xiz/1.14/commit", c9 + 7, 32);
        wr32(k + 152, xiz_crc32c(0, k, 152));
        keyset_derive(&w->keys, file_key, w->sb.id);
        secure_zero(file_key, 32);
        secure_zero(kek, 32);
    }
    superblock_encode(&w->sb, w->sb.raw);
    if ((rc = w_write(w, w->sb.raw, XIZ_SUPERBLOCK, err))) goto fail;
    if (w->encrypted && (rc = w_write(w, keys_block, sizeof keys_block, err))) goto fail;
    *out = w;
    return XIZ_OK;
fail:
    w_close_file(w);
    remove_path(w->tmp_path);
    writer_free(w);
    return rc;
}

int xiz_writer_append(xiz_writer **out, const char *path, const xiz_writer_options *opt, xiz_error *err) {
    if (!out || !path) return FAIL(XIZ_E_ARG, "missing argument");
    *out = NULL;
    xiz_writer *w = writer_new(opt);
    if (!w) return FAIL(XIZ_E_NOMEM, "out of memory");
    xiz_open_options oo;
    memset(&oo, 0, sizeof oo);
    oo.password = opt ? opt->password : NULL;
    int rc = xiz_open_file(&w->source, path, &oo, err);
    if (rc) { writer_free(w); return rc; }
    xiz_archive *a = w->source;
    if (a->has_dir) { writer_free(w); return FAIL(XIZ_E_UNSUPPORTED, "appending to XIZ 1.3 archives (directory) is not supported"); }
    if (a->sb.major != 1) { writer_free(w); return FAIL(XIZ_E_UNSUPPORTED, "appending to a beta archive"); }
    if (a->segments >= (1u << 24)) { writer_free(w); return FAIL(XIZ_E_LIMIT, "too many segments"); }
    w->append = 1;
    w->sb = a->sb;
    w->encrypted = a->encrypted;
    w->keys = a->keys;
    w->previous_footer = a->footer_offset;
    w->segment = a->segments;
    w->original_end = a->footer_offset + XIZ_FOOTER;
    w->path = dup_str(path);
    /* Existing frames and entries. */
    w->cap_frames = a->cat.n_frames + 64;
    w->frames = malloc(w->cap_frames * sizeof(frame_rec));
    w->cap_entries = a->cat.n_entries + 64;
    w->entries = calloc(w->cap_entries, sizeof(wentry));
    if (!w->path || !w->frames || !w->entries) { writer_free(w); return FAIL(XIZ_E_NOMEM, "out of memory"); }
    memcpy(w->frames, a->cat.frames, a->cat.n_frames * sizeof(frame_rec));
    w->n_frames = a->cat.n_frames;
    w->next_index = a->cat.n_frames;
    for (size_t i = 0; i < a->cat.n_entries; i++) {
        const entry_rec *s = &a->cat.entries[i];
        wentry *e = &w->entries[w->n_entries++];
        e->type = s->type;
        e->path = malloc(s->path_len + 1);
        e->link = malloc(s->link_len + 1);
        e->ext = malloc(s->n_ext * sizeof(extent_rec) + 1);
        if (!e->path || !e->link || !e->ext) { writer_free(w); return FAIL(XIZ_E_NOMEM, "out of memory"); }
        memcpy(e->path, s->path, s->path_len + 1);
        e->path_len = s->path_len;
        memcpy(e->link, s->link, s->link_len + 1);
        e->link_len = s->link_len;
        if (s->n_ext) memcpy(e->ext, s->ext, s->n_ext * sizeof(extent_rec));
        e->n_ext = s->n_ext;
        e->mode = s->mode;
        e->uid = s->uid;
        e->gid = s->gid;
        e->mtime = s->mtime;
        e->nsec = s->nsec;
        e->size = s->size;
        e->xattrs = s->xattrs;
        e->n_xattrs = s->n_xattrs;
        e->has_digest = s->has_digest;
        memcpy(e->digest, s->digest, 32);
        /* Unencrypted digests are the plain SHA-256: they deduplicate new data too. */
        if (!w->encrypted && s->has_digest && s->type == 0) { memcpy(e->plain_sha, s->digest, 32); e->has_plain_sha = 1; }
    }
#if defined(_WIN32)
    wchar_t *wp = xiz_utf8_to_wide(path);
    w->h = wp ? CreateFileW(wp, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL)
              : INVALID_HANDLE_VALUE;
    free(wp);
    if (w->h == INVALID_HANDLE_VALUE) { writer_free(w); return FAIL(XIZ_E_IO, "cannot open %s for writing", path); }
#else
    w->fd = open(path, O_RDWR | O_CLOEXEC);
    if (w->fd < 0) { rc = FAIL(XIZ_E_IO, "cannot open %s for writing: %s", path, strerror(errno)); writer_free(w); return rc; }
#endif
    /* §11: an interrupted append left bytes after the last footer: cut them. */
    if (w_truncate(w, w->original_end) != 0) { writer_free(w); return FAIL(XIZ_E_IO, "cannot truncate %s", path); }
    w->pos = w->original_end;
    *out = w;
    return XIZ_OK;
}

/* ------------------------------------------------------------------ finish */

/* One catalog entry (§5.2); `proof` (salt ‖ content SHA-256) adds field 0x0009 (§13.6). */
static void put_entry(wbuf *c, const wentry *e, const uint8_t proof[48]) {
    wb_u8(c, e->type);
    wb_u16(c, (uint16_t)e->path_len);
    wb_put(c, e->path, e->path_len);
    uint16_t nf = 3 + (e->type == 0 ? 2 : 0) + (e->type == 2) + (uint16_t)e->n_xattrs + (e->has_digest && e->type == 0) + (proof != NULL);
    wb_u16(c, nf);
    if (e->type == 0) {
        wb_u16(c, TAG_SIZE); wb_u32(c, 8); wb_u64(c, e->size);
        wb_u16(c, TAG_EXTENTS); wb_u32(c, e->n_ext * 12);
        for (uint32_t x = 0; x < e->n_ext; x++) { wb_u32(c, e->ext[x].frame); wb_u32(c, e->ext[x].offset); wb_u32(c, e->ext[x].length); }
    }
    if (e->type == 2) { wb_u16(c, TAG_LINK); wb_u32(c, (uint32_t)e->link_len); wb_put(c, e->link, e->link_len); }
    wb_u16(c, TAG_MODE); wb_u32(c, 2); wb_u16(c, e->mode);
    wb_u16(c, TAG_OWNER); wb_u32(c, 8); wb_u32(c, e->uid); wb_u32(c, e->gid);
    wb_u16(c, TAG_MTIME); wb_u32(c, 12); wb_u64(c, (uint64_t)e->mtime); wb_u32(c, e->nsec);
    for (size_t x = 0; x < e->n_xattrs; x++) {
        wb_u16(c, TAG_XATTR);
        wb_u32(c, (uint32_t)(2 + e->xattrs[x].name_len + e->xattrs[x].value_len));
        wb_u16(c, (uint16_t)e->xattrs[x].name_len);
        wb_put(c, e->xattrs[x].name, e->xattrs[x].name_len);
        wb_put(c, e->xattrs[x].value, e->xattrs[x].value_len);
    }
    if (e->has_digest && e->type == 0) { wb_u16(c, TAG_DIGEST); wb_u32(c, 32); wb_put(c, e->digest, 32); }
    if (proof) { wb_u16(c, TAG_PROOF); wb_u32(c, 48); wb_put(c, proof, 48); }
}

static int leaf_cmp(const void *a, const void *b) { return memcmp(a, b, 32); }

/* XIZ 1.3 (§13.1): after the frames, one catalog per group (version 2, sealed with that group's
 * catalog key), the Merkle leaf table, the directory (plaintext, unsigned) and the footer. */
static int write_directory(xiz_writer *w, xiz_error *err) {
    uint32_t count = 0;
    uint64_t total = 0;
    for (size_t i = 0; i < w->n_entries; i++)
        if (!w->entries[i].removed) {
            count++;
            if (w->entries[i].type == 0) total += w->entries[i].size;
        }
    /* Proof data and leaves of every entry. */
    uint8_t (*proof)[48] = calloc(w->n_entries + 1, 48);
    uint8_t (*leaves)[32] = calloc(count + 1, 32);
    uint64_t *coff = calloc(w->n_groups, sizeof *coff), *ccs = calloc(w->n_groups, sizeof *ccs), *cus = calloc(w->n_groups, sizeof *cus);
    uint8_t (*csha)[32] = calloc(w->n_groups, 32);
    int rc = XIZ_OK;
    if (!proof || !leaves || !coff || !ccs || !cus || !csha) { rc = FAIL(XIZ_E_NOMEM, "out of memory"); goto out; }
    size_t nl = 0;
    for (size_t i = 0; i < w->n_entries; i++) {
        const wentry *e = &w->entries[i];
        if (e->removed) continue;
        if (xiz_random(proof[i], 16)) { rc = FAIL(XIZ_E_IO, "no randomness"); goto out; }
        if (e->type == 0) memcpy(proof[i] + 16, e->plain_sha, 32);
        else if (e->type == 2) sha256(e->link, e->link_len, proof[i] + 16);  /* the target; zeros for folders */
        wbuf ld = {0};
        leaf_data(&ld, proof[i], e->path, e->path_len, e->type, e->type == 0 ? e->size : 0, proof[i] + 16);
        if (ld.oom) { wb_free(&ld); rc = FAIL(XIZ_E_NOMEM, "out of memory"); goto out; }
        merkle_leaf(ld.p, ld.n, leaves[nl++]);
        wb_free(&ld);
    }
    qsort(leaves, nl, 32, leaf_cmp);
    for (uint16_t g = 0; g < w->n_groups && rc == XIZ_OK; g++) {
        wbuf c = {0};
        wb_put(&c, "XCAT", 4);
        wb_u16(&c, 2);
        wb_u32(&c, w->n_frames);
        for (uint32_t i = 0; i < w->n_frames; i++) {
            const frame_rec *f = &w->frames[i];
            wb_u64(&c, f->offset); wb_u32(&c, f->csize); wb_u32(&c, f->usize); wb_u32(&c, f->crc);
            wb_u8(&c, f->codec); wb_u8(&c, f->flags); wb_u16(&c, f->dict); wb_u16(&c, f->group);
        }
        uint32_t ng = 0;
        for (size_t i = 0; i < w->n_entries; i++) ng += !w->entries[i].removed && w->entries[i].group == g;
        wb_u32(&c, ng);
        for (size_t i = 0; i < w->n_entries; i++)
            if (!w->entries[i].removed && w->entries[i].group == g) put_entry(&c, &w->entries[i], proof[i]);
        const char *name = w->gname[g] ? w->gname[g] : "";
        wb_u16(&c, (uint16_t)strlen(name));
        wb_put(&c, name, strlen(name));
        wb_u16(&c, (uint16_t)w->gnprefix[g]);
        for (size_t k = 0; k < w->gnprefix[g]; k++) {
            wb_u16(&c, (uint16_t)strlen(w->gprefix[g][k]));
            wb_put(&c, w->gprefix[g][k], strlen(w->gprefix[g][k]));
        }
        if (c.oom) { wb_free(&c); rc = FAIL(XIZ_E_NOMEM, "out of memory"); break; }
        size_t cap = zstd_bound(c.n);
        uint8_t *z = malloc(cap);
        size_t zn = z ? zstd_encode(c.p, c.n, w->level, z, cap) : 0;
        cus[g] = c.n;
        wb_free(&c);
        if (!zn) { free(z); rc = FAIL(XIZ_E_NOMEM, "catalog compression failed"); break; }
        wbuf sealed = {0};
        const uint8_t *cat = z;
        size_t cat_len = zn;
        if (w->encrypted) {
            uint8_t aad[12 + 16 + 2 + 4 + 8 + 4];
            memcpy(aad, "XIZ13catalog", 12);
            memcpy(aad + 12, w->sb.id, 16);
            wr16(aad + 28, g);
            wr32(aad + 30, w->segment);
            wr64(aad + 34, cus[g]);
            wr32(aad + 42, w->n_frames);
            if (stream_seal(w->gkeys[g].catalog, aad, sizeof aad, w->segment, z, zn, &sealed) != XIZ_OK) {
                free(z);
                wb_free(&sealed);
                rc = FAIL(XIZ_E_NOMEM, "out of memory");
                break;
            }
            cat = sealed.p;
            cat_len = sealed.n;
        }
        coff[g] = w->pos;
        ccs[g] = cat_len;
        sha256(cat, cat_len, csha[g]);
        rc = w_write(w, cat, cat_len, err);
        free(z);
        wb_free(&sealed);
    }
    if (rc) goto out;
    uint64_t leaf_offset = w->pos;
    if ((rc = w_write(w, leaves, nl * 32, err))) goto out;
    uint8_t root[32];
    merkle_root((const uint8_t(*)[32])leaves, nl, root);
    wbuf d = {0};
    wb_put(&d, "XDIR", 4);
    wb_u16(&d, 2);
    wb_u16(&d, 0);  /* flags */
    wb_u16(&d, w->n_groups);
    for (uint16_t g = 0; g < w->n_groups; g++) {
        wb_u16(&d, g); wb_u32(&d, w->segment); wb_u64(&d, coff[g]); wb_u64(&d, ccs[g]); wb_u64(&d, cus[g]); wb_put(&d, csha[g], 32);
    }
    wb_u16(&d, 0);  /* no key slot tables */
    wb_u64(&d, leaf_offset);
    wb_u32(&d, (uint32_t)nl);
    wb_put(&d, root, 32);
    wb_u32(&d, 0);  /* unsigned */
    if (d.oom) { wb_free(&d); rc = FAIL(XIZ_E_NOMEM, "out of memory"); goto out; }
    wb_u32(&d, xiz_crc32c(0, d.p, d.n));
    footer ft;
    memset(&ft, 0, sizeof ft);
    ft.major = 1;
    ft.minor = w->sb.minor;
    ft.cat_offset = w->pos;
    ft.cat_csize = ft.cat_usize = d.n;
    sha256(d.p, d.n, ft.cat_sha);
    ft.frame_count = w->n_frames;
    ft.entry_count = count;
    ft.total_bytes = total;
    rc = w_write(w, d.p, d.n, err);
    wb_free(&d);
    if (rc) goto out;
    uint8_t fb[XIZ_FOOTER];
    footer_encode(&ft, fb);
    rc = w_write(w, fb, sizeof fb, err);
out:
    if (proof) secure_zero(proof, (w->n_entries + 1) * 48);
    free(proof);
    free(leaves);
    free(coff);
    free(ccs);
    free(cus);
    free(csha);
    return rc;
}

static int write_catalog(xiz_writer *w, xiz_error *err) {
    wbuf c = {0};
    wb_put(&c, "XCAT", 4);
    wb_u16(&c, 1);
    wb_u32(&c, w->n_frames);
    for (uint32_t i = 0; i < w->n_frames; i++) {
        const frame_rec *f = &w->frames[i];
        wb_u64(&c, f->offset);
        wb_u32(&c, f->csize);
        wb_u32(&c, f->usize);
        wb_u32(&c, f->crc);
        wb_u8(&c, f->codec);
        wb_u8(&c, f->flags);
        wb_u16(&c, f->dict);
    }
    uint32_t count = 0;
    uint64_t total = 0;
    for (size_t i = 0; i < w->n_entries; i++) count += !w->entries[i].removed;
    wb_u32(&c, count);
    for (size_t i = 0; i < w->n_entries; i++) {
        const wentry *e = &w->entries[i];
        if (e->removed) continue;
        put_entry(&c, e, NULL);
        if (e->type == 0) total += e->size;
    }
    if (c.oom) { wb_free(&c); return FAIL(XIZ_E_NOMEM, "out of memory"); }
    size_t cap = zstd_bound(c.n);
    uint8_t *z = malloc(cap);
    if (!z) { wb_free(&c); return FAIL(XIZ_E_NOMEM, "out of memory"); }
    size_t zn = zstd_encode(c.p, c.n, w->level, z, cap);
    if (!zn) { free(z); wb_free(&c); return FAIL(XIZ_E_NOMEM, "catalog compression failed"); }
    footer ft;
    memset(&ft, 0, sizeof ft);
    ft.major = 1;
    ft.minor = w->previous_footer ? (w->sb.minor > 1 ? w->sb.minor : 1) : w->sb.minor;
    ft.cat_offset = w->pos;
    ft.cat_usize = c.n;
    ft.frame_count = w->n_frames;
    ft.entry_count = count;
    ft.total_bytes = total;
    ft.previous = w->previous_footer;
    wb_free(&c);
    wbuf sealed = {0};
    const uint8_t *cat = z;
    size_t cat_len = zn;
    if (w->encrypted) {
        uint8_t aad[11 + 16 + 36];
        memcpy(aad, "XIZ1catalog", 11);
        memcpy(aad + 11, w->sb.id, 16);
        footer_auth_fields(&ft, aad + 27);
        if (stream_seal(w->keys.catalog, aad, sizeof aad, w->segment, z, zn, &sealed) != XIZ_OK) {
            free(z);
            wb_free(&sealed);
            return FAIL(XIZ_E_NOMEM, "out of memory");
        }
        cat = sealed.p;
        cat_len = sealed.n;
    }
    ft.cat_csize = cat_len;
    sha256(cat, cat_len, ft.cat_sha);
    int rc = w_write(w, cat, cat_len, err);
    free(z);
    wb_free(&sealed);
    if (rc) return rc;
    uint8_t fb[XIZ_FOOTER];
    footer_encode(&ft, fb);
    return w_write(w, fb, sizeof fb, err);
}

int xiz_writer_finish(xiz_writer *w, xiz_error *err) {
    if (!w) return FAIL(XIZ_E_ARG, "no writer");
    int rc = check_writer(w, err);
    if (!rc) rc = flush_frame(w, 1, err);
    if (!rc) rc = w->dir ? write_directory(w, err) : write_catalog(w, err);
    if (!rc && w_sync(w) != 0) rc = FAIL(XIZ_E_IO, "sync failed");
    if (rc) { xiz_writer_abort(w); return rc; }
    w_close_file(w);
    if (!w->append && rename_path(w->tmp_path, w->path, w->overwrite) != 0) {
        rc = FAIL(XIZ_E_IO, "cannot rename %s", w->tmp_path);
        remove_path(w->tmp_path);
    }
    writer_free(w);
    return rc;
}

void xiz_writer_abort(xiz_writer *w) {
    if (!w) return;
    if (w->append) {
        w_truncate(w, w->original_end);  /* the archive is exactly as before */
    } else {
        w_close_file(w);
        if (w->tmp_path) remove_path(w->tmp_path);
    }
    writer_free(w);
}
