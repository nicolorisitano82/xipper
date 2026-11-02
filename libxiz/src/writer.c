/* Writer: new archives (XIZ 1.0, zstd frames, file-level deduplication, optional password
 * encryption) and appended segments (§11). Never produces 1.3 structures. */
#include "internal.h"

#include <stdio.h>

#if defined(_WIN32)
#  include <windows.h>
#  include <io.h>
#  include <fcntl.h>
#  include <sys/stat.h>
#else
#  include <dirent.h>
#  include <errno.h>
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
    uint8_t plain_sha[32];       /* dedup key, never written */
    int has_plain_sha;
    int removed;
} wentry;

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
    uint8_t *buf;                /* current frame data */
    uint32_t used;
    uint8_t *out;                /* compressed / sealed payload */
    size_t out_cap;
    xiz_archive *source;         /* append: keeps xattr strings alive */
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

static int flush_frame(xiz_writer *w, xiz_error *err) {
    if (w->used == 0) return XIZ_OK;
    if (w->n_frames == w->cap_frames) {
        uint32_t cap = w->cap_frames ? w->cap_frames * 2 : 64;
        frame_rec *nf = realloc(w->frames, cap * sizeof(frame_rec));
        if (!nf) return FAIL(XIZ_E_NOMEM, "out of memory");
        w->frames = nf;
        w->cap_frames = cap;
    }
    size_t need = zstd_bound(w->used) + XIZ_TAG;
    if (w->out_cap < need) {
        uint8_t *o = realloc(w->out, need);
        if (!o) return FAIL(XIZ_E_NOMEM, "out of memory");
        w->out = o;
        w->out_cap = need;
    }
    frame_rec f;
    memset(&f, 0, sizeof f);
    uint32_t index = w->n_frames;
    f.offset = w->pos;
    f.usize = w->used;
    size_t n = zstd_encode(w->buf, w->used, w->level, w->out, w->out_cap - XIZ_TAG);
    if (n && n < w->used) {
        f.codec = CODEC_ZSTD;
    } else {
        f.codec = CODEC_STORE;
        memcpy(w->out, w->buf, w->used);
        n = w->used;
    }
    if (w->encrypted) {
        uint8_t nonce[12], aad[37];
        frame_nonce(index, nonce);
        frame_aad(w->sb.id, index, &f, aad);
        aes_gcm_seal(w->keys.data, nonce, aad, sizeof aad, w->out, n, w->out + n);
        n += XIZ_TAG;
    }
    f.csize = (uint32_t)n;
    f.crc = xiz_crc32c(0, w->out, n);
    uint8_t hdr[XIZ_FRAME_HEADER];
    frame_header_encode(index, &f, hdr);
    TRY(w_write(w, hdr, sizeof hdr, err));
    TRY(w_write(w, w->out, n, err));
    w->frames[w->n_frames++] = f;
    w->used = 0;
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
    while (n) {
        uint32_t room = w->frame_size - w->used;
        uint32_t k = n < room ? (uint32_t)n : room;
        memcpy(w->buf + w->used, d, k);
        if (!add_extent(e, w->n_frames, w->used, k)) return FAIL(XIZ_E_NOMEM, "out of memory");
        w->used += k;
        d += k;
        n -= k;
        if (w->used == w->frame_size) TRY(flush_frame(w, err));
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
        if (o->type == 0 && o->has_plain_sha && o->size == e->size && memcmp(o->plain_sha, e->plain_sha, 32) == 0)
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
        hmac_init(&h, w->keys.mac);
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
    if (w->encrypted) hmac_init(&hc, w->keys.mac);
    uint64_t size = 0;
    long r;
    while ((r = rf_read(&f, b, IOBUF)) > 0) {
        sha256_update(&sc, b, (size_t)r);
        if (w->encrypted) hmac_update(&hc, b, (size_t)r);
        size += (uint64_t)r;
    }
    int rc = XIZ_OK;
    if (r < 0) rc = FAIL(XIZ_E_IO, "cannot read %s", disk_path);
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

#if !defined(_WIN32)
static int cmp_names(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

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
    DWORD at = wp ? GetFileAttributesW(wp) : INVALID_FILE_ATTRIBUTES;
    if (at == INVALID_FILE_ATTRIBUTES) { free(wp); return FAIL(XIZ_E_IO, "cannot stat %s", disk_path); }
    if (!(at & FILE_ATTRIBUTE_DIRECTORY)) { free(wp); return xiz_writer_add_file(w, path, disk_path, NULL, err); }
    TRY(xiz_writer_add_directory(w, path, NULL, err));
    size_t wl = wcslen(wp);
    wchar_t *pat = malloc((wl + 3) * sizeof(wchar_t));
    if (!pat) { free(wp); return FAIL(XIZ_E_NOMEM, "out of memory"); }
    wcscpy(pat, wp);
    wcscat(pat, L"\\*");
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(pat, &fd);
    free(pat);
    free(wp);
    int rc = XIZ_OK;
    if (h == INVALID_HANDLE_VALUE) return XIZ_OK;
    do {
        if (!wcscmp(fd.cFileName, L".") || !wcscmp(fd.cFileName, L"..")) continue;
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) continue;  /* links are not followed */
        char name[1024];
        if (!WideCharToMultiByte(CP_UTF8, 0, fd.cFileName, -1, name, sizeof name, NULL, NULL)) continue;
        size_t n1 = strlen(path) + strlen(name) + 2, n2 = strlen(disk_path) + strlen(name) + 2;
        char *ap = malloc(n1), *dp = malloc(n2);
        if (!ap || !dp) { free(ap); free(dp); rc = FAIL(XIZ_E_NOMEM, "out of memory"); break; }
        snprintf(ap, n1, "%s/%s", path, name);
        snprintf(dp, n2, "%s\\%s", disk_path, name);
        rc = xiz_writer_add_tree(w, ap, dp, err);
        free(ap);
        free(dp);
    } while (!rc && FindNextFileW(h, &fd));
    FindClose(h);
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
    w->buf = malloc(w->frame_size);
    if (!w->buf) { free(w); return NULL; }
    return w;
}

static void writer_free(xiz_writer *w) {
    if (!w) return;
    w_close_file(w);
    for (size_t i = 0; i < w->n_entries; i++) entry_free(&w->entries[i]);
    free(w->entries);
    free(w->frames);
    free(w->buf);
    free(w->out);
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
    uint8_t keys_block[117];
    if (opt && opt->password) {
        uint32_t mem = opt->kdf_memory_kib ? opt->kdf_memory_kib : 262144, it = opt->kdf_iterations ? opt->kdf_iterations : 3,
                 par = opt->kdf_parallelism ? opt->kdf_parallelism : 4;
        if (mem < 19456 || mem > 2097152 || it < 1 || it > 10 || par < 1 || par > 16) {
            rc = FAIL(XIZ_E_ARG, "Argon2id parameters outside what readers accept");
            goto fail;
        }
        w->encrypted = 1;
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
        /* "XKEY" ‖ count ‖ type 1 ‖ length 104 ‖ body ‖ CRC */
        uint8_t *k = keys_block;
        memcpy(k, "XKEY", 4);
        wr16(k + 4, 1);
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
        wr32(k + 113, xiz_crc32c(0, k, 113));
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
        wb_u8(&c, e->type);
        wb_u16(&c, (uint16_t)e->path_len);
        wb_put(&c, e->path, e->path_len);
        uint16_t nf = 3 + (e->type == 0 ? 2 : 0) + (e->type == 2) + (uint16_t)e->n_xattrs + (e->has_digest && e->type == 0);
        wb_u16(&c, nf);
        if (e->type == 0) {
            wb_u16(&c, TAG_SIZE); wb_u32(&c, 8); wb_u64(&c, e->size);
            wb_u16(&c, TAG_EXTENTS); wb_u32(&c, e->n_ext * 12);
            for (uint32_t x = 0; x < e->n_ext; x++) { wb_u32(&c, e->ext[x].frame); wb_u32(&c, e->ext[x].offset); wb_u32(&c, e->ext[x].length); }
            total += e->size;
        }
        if (e->type == 2) { wb_u16(&c, TAG_LINK); wb_u32(&c, (uint32_t)e->link_len); wb_put(&c, e->link, e->link_len); }
        wb_u16(&c, TAG_MODE); wb_u32(&c, 2); wb_u16(&c, e->mode);
        wb_u16(&c, TAG_OWNER); wb_u32(&c, 8); wb_u32(&c, e->uid); wb_u32(&c, e->gid);
        wb_u16(&c, TAG_MTIME); wb_u32(&c, 12); wb_u64(&c, (uint64_t)e->mtime); wb_u32(&c, e->nsec);
        for (size_t x = 0; x < e->n_xattrs; x++) {
            wb_u16(&c, TAG_XATTR);
            wb_u32(&c, (uint32_t)(2 + e->xattrs[x].name_len + e->xattrs[x].value_len));
            wb_u16(&c, (uint16_t)e->xattrs[x].name_len);
            wb_put(&c, e->xattrs[x].name, e->xattrs[x].name_len);
            wb_put(&c, e->xattrs[x].value, e->xattrs[x].value_len);
        }
        if (e->has_digest && e->type == 0) { wb_u16(&c, TAG_DIGEST); wb_u32(&c, 32); wb_put(&c, e->digest, 32); }
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
    if (!rc) rc = flush_frame(w, err);
    if (!rc) rc = write_catalog(w, err);
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
