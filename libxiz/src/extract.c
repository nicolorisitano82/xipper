/* Safe extraction (§5.3): nothing outside the destination, nothing through a symbolic link,
 * symbolic links last, setuid/setgid/sticky cleared, declared sizes checked first.
 * POSIX: every path is walked with openat(O_NOFOLLOW) from the destination's descriptor.
 * Windows: wide-character API, reparse points refused, invalid names replaced. */
#include "internal.h"

#include <stdio.h>

#if defined(_WIN32)
#  include <windows.h>
#else
#  include <errno.h>
#  include <fcntl.h>
#  include <sys/stat.h>
#  include <sys/statvfs.h>
#  include <sys/time.h>
#  include <unistd.h>
#endif

/* ------------------------------------------------------------------ path rules */

typedef struct {
    char **comp;
    size_t n;
    char *norm;                  /* "a/b/c" */
} spath;

static void spath_free(spath *p) {
    for (size_t i = 0; i < p->n; i++) free(p->comp[i]);
    free(p->comp);
    free(p->norm);
    memset(p, 0, sizeof *p);
}

/* 0 ok, XIZ_E_UNSAFE with a reason. Leading '/', empty and '.' components are dropped. */
static int sanitize(const char *path, size_t len, spath *out, const char **why) {
    memset(out, 0, sizeof *out);
    if (memchr(path, 0, len)) { *why = "NUL in the path"; return XIZ_E_UNSAFE; }
    size_t i = 0;
    out->comp = calloc(len / 2 + 2, sizeof(char *));
    out->norm = malloc(len + 1);
    if (!out->comp || !out->norm) { spath_free(out); *why = "out of memory"; return XIZ_E_NOMEM; }
    size_t nl = 0;
    while (i < len) {
        size_t j = i;
        while (j < len && path[j] != '/') j++;
        size_t cl = j - i;
        if (cl == 0 || (cl == 1 && path[i] == '.')) { i = j + 1; continue; }
        if (cl == 2 && path[i] == '.' && path[i + 1] == '.') { spath_free(out); *why = "\"..\" component"; return XIZ_E_UNSAFE; }
        if (cl > 255) { spath_free(out); *why = "component longer than 255 bytes"; return XIZ_E_UNSAFE; }
        char *c = malloc(cl + 1);
        if (!c) { spath_free(out); *why = "out of memory"; return XIZ_E_NOMEM; }
        memcpy(c, path + i, cl);
        c[cl] = 0;
        out->comp[out->n++] = c;
        if (nl) out->norm[nl++] = '/';
        memcpy(out->norm + nl, path + i, cl);
        nl += cl;
        i = j + 1;
    }
    out->norm[nl] = 0;
    if (out->n == 0) { spath_free(out); *why = "empty path"; return XIZ_E_UNSAFE; }
    return XIZ_OK;
}

/* norm = components joined with '/' (after they were made valid or renamed). */
static int spath_rebuild(spath *p) {
    size_t len = 1;
    for (size_t i = 0; i < p->n; i++) len += strlen(p->comp[i]) + 1;
    char *s = malloc(len);
    if (!s) return -1;
    size_t o = 0;
    for (size_t i = 0; i < p->n; i++) {
        if (i) s[o++] = '/';
        size_t l = strlen(p->comp[i]);
        memcpy(s + o, p->comp[i], l);
        o += l;
    }
    s[o] = 0;
    free(p->norm);
    p->norm = s;
    return 0;
}

/* "stem (k).ext" within 255 bytes, cut on a UTF-8 boundary. The extension is what follows the
 * last dot that is not the first character. */
static char *numbered_name(const char *name, unsigned k) {
    size_t len = strlen(name), dot = len;
    for (size_t i = len; i-- > 1;)
        if (name[i] == '.') { dot = i; break; }
    char suffix[16];
    int sl = snprintf(suffix, sizeof suffix, " (%u)", k);
    size_t ext = len - dot, stem = dot;
    if (ext > 64) { ext = 0; stem = len; }  /* a long "extension" is part of the name */
    while (stem && stem + (size_t)sl + ext > 255) {
        stem--;
        while (stem && ((unsigned char)name[stem] & 0xC0) == 0x80) stem--;
    }
    char *out = malloc(stem + (size_t)sl + ext + 1);
    if (!out) return NULL;
    memcpy(out, name, stem);
    memcpy(out + stem, suffix, (size_t)sl);
    memcpy(out + stem + (size_t)sl, name + len - ext, ext);
    out[stem + (size_t)sl + ext] = 0;
    return out;
}

static int spath_rename_last(spath *p, unsigned k, char **old) {
    char *nn = numbered_name(*old ? *old : p->comp[p->n - 1], k);
    if (!nn) return -1;
    if (!*old) *old = p->comp[p->n - 1];
    else free(p->comp[p->n - 1]);
    p->comp[p->n - 1] = nn;
    return spath_rebuild(p);
}

/* A symlink target stays inside the root when it is relative, its leading ".." do not climb
 * above the link's folder depth, and no ".." follows another component (which could cross an
 * in-archive symlink). */
static int symlink_inside(const char *t, size_t len, size_t depth) {
    if (len == 0 || t[0] == '/') return 0;
#if defined(_WIN32)
    if (t[0] == '\\' || (len >= 2 && t[1] == ':')) return 0;
#endif
    size_t i = 0, ups = 0;
    int named = 0;
    while (i < len) {
        size_t j = i;
        while (j < len && t[j] != '/'
#if defined(_WIN32)
               && t[j] != '\\'
#endif
        )
            j++;
        size_t cl = j - i;
        if (cl == 2 && t[i] == '.' && t[i + 1] == '.') {
            if (named) return 0;
            if (++ups > depth) return 0;
        } else if (cl && !(cl == 1 && t[i] == '.')) {
            named = 1;
        }
        i = j + 1;
    }
    return 1;
}

size_t xiz_windows_name(const char *c, size_t len, char *out, size_t cap) {
    if (!cap) return 0;
    size_t n = 0;
    static const char *reserved[] = {"CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6",
                                     "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6",
                                     "LPT7", "LPT8", "LPT9", "CONIN$", "CONOUT$"};
    /* Base name up to the first dot, case-insensitive. */
    size_t base = 0;
    while (base < len && c[base] != '.') base++;
    while (base > 0 && c[base - 1] == ' ') base--;
    int dev = 0;
    for (size_t r = 0; r < sizeof reserved / sizeof *reserved; r++) {
        size_t rl = strlen(reserved[r]);
        if (rl != base) continue;
        size_t k;
        for (k = 0; k < rl; k++) {
            char a = c[k], b = reserved[r][k];
            if (a >= 'a' && a <= 'z') a = (char)(a - 32);
            if (a != b) break;
        }
        if (k == rl) dev = 1;
    }
    if (dev && n + 1 < cap) out[n++] = '_';
    size_t end = len;
    while (end > 0 && (c[end - 1] == '.' || c[end - 1] == ' ')) end--;
    for (size_t i = 0; i < end && n + 1 < cap; i++) {
        unsigned char ch = (unsigned char)c[i];
        out[n++] = (ch < 0x20 || strchr("<>:\"|?*\\", ch)) ? '_' : (char)ch;
    }
    if (n == 0 && n + 1 < cap) out[n++] = '_';
    out[n] = 0;
    return n;
}

/* ------------------------------------------------------------------ platform layer */

typedef struct {
    const xiz_extract_options *opt;
    xiz_extract_report *rep;
    unsigned flags;
#if defined(_WIN32)
    wchar_t *root;               /* \\?\C:\…\dest */
#else
    int root;
#endif
    uint64_t done, total;        /* bytes, for opt->bytes */
    int cancelled;
} ex_ctx;

static void skipped(ex_ctx *x, const char *path, int code, const char *why) {
    x->rep->skipped++;
    if (x->opt && x->opt->skipped) x->opt->skipped(x->opt->ctx, path, code, why);
}

static void written(ex_ctx *x, const char *path, const spath *p) {
    if (x->opt && x->opt->written) x->opt->written(x->opt->ctx, path, p->norm);
}

/* 1 when the caller asked to stop. */
static int report_bytes(ex_ctx *x) {
    if (x->cancelled) return 1;
    if (x->opt && x->opt->bytes && x->opt->bytes(x->opt->ctx, x->done, x->total)) x->cancelled = 1;
    return x->cancelled;
}

static int disk_exists(ex_ctx *x, const spath *p, int *is_dir);

#if !defined(_WIN32)

/* Opens (creating when asked) the directory made of comp[0..n) under root, never following links.
 * Returns an fd or -1 with *why set. */
static int open_dirs(ex_ctx *x, char *const *comp, size_t n, int create, const char **why) {
    int fd = dup(x->root);
    if (fd < 0) { *why = strerror(errno); return -1; }
    for (size_t i = 0; i < n; i++) {
        int next = openat(fd, comp[i], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0 && errno == ENOENT && create) {
            if (mkdirat(fd, comp[i], 0755) != 0 && errno != EEXIST) { *why = strerror(errno); close(fd); return -1; }
            next = openat(fd, comp[i], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        }
        if (next < 0) {
            struct stat st;
            if (errno == ELOOP || (fstatat(fd, comp[i], &st, AT_SYMLINK_NOFOLLOW) == 0 && S_ISLNK(st.st_mode)))
                *why = "a folder on its path is a symbolic link";
            else if (errno == ENOTDIR)
                *why = "a folder on its path is a file";
            else
                *why = strerror(errno);
            close(fd);
            return -1;
        }
        close(fd);
        fd = next;
    }
    return fd;
}

static int platform_init(ex_ctx *x, const char *dest, xiz_error *err) {
    if (mkdir(dest, 0755) != 0 && errno != EEXIST) return FAIL(XIZ_E_IO, "cannot create %s: %s", dest, strerror(errno));
    x->root = open(dest, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (x->root < 0) return FAIL(XIZ_E_IO, "cannot open %s: %s", dest, strerror(errno));
    return XIZ_OK;
}

static void platform_done(ex_ctx *x) { if (x->root >= 0) close(x->root); }

static int free_space(ex_ctx *x, uint64_t *out) {
    struct statvfs s;
    if (fstatvfs(x->root, &s) != 0) return 0;
    *out = (uint64_t)s.f_bavail * s.f_frsize;
    return 1;
}

static void set_times(int fd, const entry_rec *e, unsigned flags) {
    if (flags & XIZ_EXTRACT_NO_TIMES) return;
    struct timespec ts[2];
    ts[0].tv_sec = ts[1].tv_sec = (time_t)e->mtime;
    ts[0].tv_nsec = ts[1].tv_nsec = e->nsec < 1000000000u ? (long)e->nsec : 0;
    futimens(fd, ts);
}

static int make_dir(ex_ctx *x, const spath *p, const char **why) {
    int fd = open_dirs(x, p->comp, p->n, 1, why);
    if (fd < 0) return -1;
    close(fd);
    return 0;
}

static void finish_dir(ex_ctx *x, const spath *p, const entry_rec *e) {
    const char *why;
    int fd = open_dirs(x, p->comp, p->n, 0, &why);
    if (fd < 0) return;
    if (!(x->flags & XIZ_EXTRACT_NO_PERMISSIONS)) fchmod(fd, (mode_t)(e->mode & 0777));
    if (x->flags & XIZ_EXTRACT_OWNER) { if (fchown(fd, e->uid, e->gid) != 0) { /* not privileged */ } }
    set_times(fd, e, x->flags);
    close(fd);
}

static int disk_exists(ex_ctx *x, const spath *p, int *is_dir) {
    const char *why;
    int dfd = open_dirs(x, p->comp, p->n - 1, 0, &why);
    if (dfd < 0) return 0;
    struct stat st;
    int r = fstatat(dfd, p->comp[p->n - 1], &st, AT_SYMLINK_NOFOLLOW) == 0;
    if (r) *is_dir = S_ISDIR(st.st_mode);
    close(dfd);
    return r;
}

/* Removes an existing file or symlink (never followed); folders are never removed. */
static void remove_existing(ex_ctx *x, const spath *p) {
    const char *why;
    int dfd = open_dirs(x, p->comp, p->n - 1, 0, &why);
    if (dfd < 0) return;
    unlinkat(dfd, p->comp[p->n - 1], 0);
    close(dfd);
}

static int case_insensitive(ex_ctx *x) {
#if defined(__APPLE__) && defined(_PC_CASE_SENSITIVE)
    return fpathconf(x->root, _PC_CASE_SENSITIVE) == 0;
#else
    (void)x;
    return 0;
#endif
}

typedef struct {
    int fd;
    int dirfd;
    const char *name;
    ex_ctx *x;
} out_file;

static int create_file(ex_ctx *x, const spath *p, out_file *o, int *code, const char **why) {
    o->x = x;
    o->dirfd = open_dirs(x, p->comp, p->n - 1, 1, why);
    if (o->dirfd < 0) { *code = XIZ_E_UNSAFE; return -1; }
    o->name = p->comp[p->n - 1];
    o->fd = openat(o->dirfd, o->name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (o->fd >= 0) return 0;
    if (errno == EEXIST) { *code = XIZ_E_EXISTS; *why = "already exists"; }
    else { *code = XIZ_E_IO; *why = strerror(errno); }
    close(o->dirfd);
    return -1;
}

static int write_file_cb(void *ctx, const void *d, size_t n) {
    out_file *o = ctx;
    const uint8_t *p = d;
    size_t total = n;
    while (n) {
        ssize_t w = write(o->fd, p, n);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return 1;
        p += w;
        n -= (size_t)w;
    }
    o->x->done += total;
    return report_bytes(o->x);
}

static void close_file(ex_ctx *x, out_file *o, const entry_rec *e, int ok) {
    if (ok) {
        if (!(x->flags & XIZ_EXTRACT_NO_PERMISSIONS)) fchmod(o->fd, (mode_t)(e->mode & 0777));  /* no suid/sgid/sticky */
        else fchmod(o->fd, 0644);
        if (x->flags & XIZ_EXTRACT_OWNER) { if (fchown(o->fd, e->uid, e->gid) != 0) { /* not privileged */ } }
        set_times(o->fd, e, x->flags);
    }
    close(o->fd);
    if (!ok) unlinkat(o->dirfd, o->name, 0);
    close(o->dirfd);
}

static int make_symlink(ex_ctx *x, const spath *p, const entry_rec *e, int *code, const char **why) {
    int dfd = open_dirs(x, p->comp, p->n - 1, 1, why);
    if (dfd < 0) { *code = XIZ_E_UNSAFE; return -1; }
    const char *name = p->comp[p->n - 1];
    int rc = symlinkat(e->link, dfd, name);
    if (rc != 0) {
        *code = errno == EEXIST ? XIZ_E_EXISTS : XIZ_E_IO;
        *why = errno == EEXIST ? "already exists" : strerror(errno);
        close(dfd);
        return -1;
    }
    if (!(x->flags & XIZ_EXTRACT_NO_TIMES)) {
        struct timespec ts[2];
        ts[0].tv_sec = ts[1].tv_sec = (time_t)e->mtime;
        ts[0].tv_nsec = ts[1].tv_nsec = e->nsec < 1000000000u ? (long)e->nsec : 0;
        utimensat(dfd, name, ts, AT_SYMLINK_NOFOLLOW);
    }
    close(dfd);
    return 0;
}

#else /* _WIN32 */

wchar_t *xiz_utf8_to_wide(const char *s) {
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t *w = malloc((size_t)n * sizeof(wchar_t));
    if (w && MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n) <= 0) { free(w); return NULL; }
    return w;
}

/* root + "\" + sanitized components [0..n) */
static wchar_t *win_path(ex_ctx *x, char *const *comp, size_t n) {
    size_t cap = wcslen(x->root) + 2;
    for (size_t i = 0; i < n; i++) cap += (strlen(comp[i]) + 2) * 2 + 2;
    wchar_t *w = malloc(cap * sizeof(wchar_t));
    if (!w) return NULL;
    wcscpy(w, x->root);
    for (size_t i = 0; i < n; i++) {
        char nm[1024];
        xiz_windows_name(comp[i], strlen(comp[i]), nm, sizeof nm);
        wchar_t *wc = xiz_utf8_to_wide(nm);
        if (!wc) { free(w); return NULL; }
        wcscat(w, L"\\");
        wcscat(w, wc);
        free(wc);
    }
    return w;
}

/* Every existing component must be a real directory (no reparse point); missing ones are created. */
static int ensure_dirs(ex_ctx *x, char *const *comp, size_t n, int create, const char **why) {
    for (size_t i = 1; i <= n; i++) {
        wchar_t *w = win_path(x, comp, i);
        if (!w) { *why = "invalid name"; return -1; }
        DWORD at = GetFileAttributesW(w);
        if (at == INVALID_FILE_ATTRIBUTES) {
            if (!create || !CreateDirectoryW(w, NULL)) { free(w); *why = "cannot create folder"; return -1; }
        } else if (at & FILE_ATTRIBUTE_REPARSE_POINT) {
            free(w); *why = "a folder on its path is a symbolic link or junction"; return -1;
        } else if (!(at & FILE_ATTRIBUTE_DIRECTORY)) {
            free(w); *why = "a folder on its path is a file"; return -1;
        }
        free(w);
    }
    return 0;
}

static int platform_init(ex_ctx *x, const char *dest, xiz_error *err) {
    wchar_t *w = xiz_utf8_to_wide(dest);
    if (!w) return FAIL(XIZ_E_ARG, "invalid destination");
    CreateDirectoryW(w, NULL);
    DWORD n = GetFullPathNameW(w, 0, NULL, NULL);
    wchar_t *full = malloc((n + 8) * sizeof(wchar_t));
    if (!full) { free(w); return FAIL(XIZ_E_NOMEM, "out of memory"); }
    wcscpy(full, L"\\\\?\\");
    GetFullPathNameW(w, n, full + 4, NULL);
    free(w);
    size_t l = wcslen(full);
    if (l && full[l - 1] == L'\\') full[l - 1] = 0;
    DWORD at = GetFileAttributesW(full);
    if (at == INVALID_FILE_ATTRIBUTES || !(at & FILE_ATTRIBUTE_DIRECTORY)) {
        free(full);
        return FAIL(XIZ_E_IO, "cannot create %s", dest);
    }
    x->root = full;
    return XIZ_OK;
}

static void platform_done(ex_ctx *x) { free(x->root); }

static int free_space(ex_ctx *x, uint64_t *out) {
    ULARGE_INTEGER avail;
    if (!GetDiskFreeSpaceExW(x->root, &avail, NULL, NULL)) return 0;
    *out = avail.QuadPart;
    return 1;
}

static FILETIME to_filetime(int64_t sec, uint32_t nsec) {
    uint64_t t = (uint64_t)(sec + 11644473600LL) * 10000000ull + nsec / 100;
    FILETIME ft;
    ft.dwLowDateTime = (DWORD)t;
    ft.dwHighDateTime = (DWORD)(t >> 32);
    return ft;
}

static int make_dir(ex_ctx *x, const spath *p, const char **why) { return ensure_dirs(x, p->comp, p->n, 1, why); }

static void finish_dir(ex_ctx *x, const spath *p, const entry_rec *e) {
    if (x->flags & XIZ_EXTRACT_NO_TIMES) return;
    wchar_t *w = win_path(x, p->comp, p->n);
    if (!w) return;
    HANDLE h = CreateFileW(w, FILE_WRITE_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING,
                           FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    free(w);
    if (h == INVALID_HANDLE_VALUE) return;
    FILETIME ft = to_filetime(e->mtime, e->nsec);
    SetFileTime(h, NULL, NULL, &ft);
    CloseHandle(h);
}

/* A real folder: a directory that is not a symlink or junction. */
static int disk_exists(ex_ctx *x, const spath *p, int *is_dir) {
    wchar_t *w = win_path(x, p->comp, p->n);
    if (!w) return 0;
    DWORD at = GetFileAttributesW(w);
    free(w);
    if (at == INVALID_FILE_ATTRIBUTES) return 0;
    *is_dir = (at & FILE_ATTRIBUTE_DIRECTORY) && !(at & FILE_ATTRIBUTE_REPARSE_POINT);
    return 1;
}

static void remove_existing(ex_ctx *x, const spath *p) {
    wchar_t *w = win_path(x, p->comp, p->n);
    if (!w) return;
    DWORD at = GetFileAttributesW(w);
    if (at != INVALID_FILE_ATTRIBUTES) {
        SetFileAttributesW(w, FILE_ATTRIBUTE_NORMAL);
        if (at & FILE_ATTRIBUTE_DIRECTORY) RemoveDirectoryW(w);  /* a directory symlink/junction itself */
        else DeleteFileW(w);                                       /* a file or file symlink itself */
    }
    free(w);
}

static int case_insensitive(ex_ctx *x) { (void)x; return 1; }

typedef struct {
    HANDLE h;
    wchar_t *path;
    ex_ctx *x;
} out_file;

static int create_file(ex_ctx *x, const spath *p, out_file *o, int *code, const char **why) {
    o->x = x;
    if (ensure_dirs(x, p->comp, p->n - 1, 1, why) != 0) { *code = XIZ_E_UNSAFE; return -1; }
    o->path = win_path(x, p->comp, p->n);
    if (!o->path) { *code = XIZ_E_UNSAFE; *why = "invalid name"; return -1; }
    o->h = CreateFileW(o->path, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (o->h == INVALID_HANDLE_VALUE) {
        DWORD e = GetLastError();
        *code = e == ERROR_FILE_EXISTS || e == ERROR_ALREADY_EXISTS ? XIZ_E_EXISTS : XIZ_E_IO;
        *why = *code == XIZ_E_EXISTS ? "already exists" : "cannot create file";
        free(o->path);
        return -1;
    }
    return 0;
}

static int write_file_cb(void *ctx, const void *d, size_t n) {
    out_file *o = ctx;
    const uint8_t *p = d;
    size_t total = n;
    while (n) {
        DWORD chunk = n > 0x40000000u ? 0x40000000u : (DWORD)n, w = 0;
        if (!WriteFile(o->h, p, chunk, &w, NULL) || w == 0) return 1;
        p += w;
        n -= w;
    }
    o->x->done += total;
    return report_bytes(o->x);
}

static void close_file(ex_ctx *x, out_file *o, const entry_rec *e, int ok) {
    if (ok && !(x->flags & XIZ_EXTRACT_NO_TIMES)) {
        FILETIME ft = to_filetime(e->mtime, e->nsec);
        SetFileTime(o->h, NULL, NULL, &ft);
    }
    CloseHandle(o->h);
    if (!ok) DeleteFileW(o->path);
    else if (!(x->flags & XIZ_EXTRACT_NO_PERMISSIONS) && !(e->mode & 0222))
        SetFileAttributesW(o->path, FILE_ATTRIBUTE_READONLY);
    free(o->path);
}

static int make_symlink(ex_ctx *x, const spath *p, const entry_rec *e, int *code, const char **why) {
    if (ensure_dirs(x, p->comp, p->n - 1, 1, why) != 0) { *code = XIZ_E_UNSAFE; return -1; }
    wchar_t *w = win_path(x, p->comp, p->n);
    char *t = malloc(e->link_len + 1);
    if (!w || !t) { free(w); free(t); *code = XIZ_E_NOMEM; *why = "out of memory"; return -1; }
    for (size_t i = 0; i <= e->link_len; i++) t[i] = e->link[i] == '/' ? '\\' : e->link[i];
    wchar_t *wt = xiz_utf8_to_wide(t);
    free(t);
    if (!wt) { free(w); *code = XIZ_E_UNSAFE; *why = "invalid target"; return -1; }
    if (GetFileAttributesW(w) != INVALID_FILE_ATTRIBUTES) { free(w); free(wt); *code = XIZ_E_EXISTS; *why = "already exists"; return -1; }
    /* A target that is a folder (resolved against the link's folder) needs the directory flag. */
    DWORD flags = 0x2; /* SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE */
    wchar_t *parent = win_path(x, p->comp, p->n - 1);
    if (parent) {
        size_t cap = wcslen(parent) + wcslen(wt) + 2;
        wchar_t *res = malloc(cap * sizeof(wchar_t));
        if (res) {
            wcscpy(res, parent);
            wcscat(res, L"\\");
            wcscat(res, wt);
            DWORD at = GetFileAttributesW(res);
            if (at != INVALID_FILE_ATTRIBUTES && (at & FILE_ATTRIBUTE_DIRECTORY)) flags |= SYMBOLIC_LINK_FLAG_DIRECTORY;
            free(res);
        }
        free(parent);
    }
    BOOL ok = CreateSymbolicLinkW(w, wt, flags);
    free(w);
    free(wt);
    if (!ok) { *code = XIZ_E_IO; *why = "cannot create symbolic link (needs Developer Mode or privilege)"; return -1; }
    return 0;
}

#endif

/* ------------------------------------------------------------------ driver */

static int selected(const xiz_extract_options *opt, const char *norm) {
    if (!opt || !opt->select || !opt->select_count) return 1;
    size_t nl = strlen(norm);
    for (size_t i = 0; i < opt->select_count; i++) {
        const char *s = opt->select[i];
        while (*s == '/') s++;
        while (s[0] == '.' && s[1] == '/') s += 2;
        size_t sl = strlen(s);
        while (sl && s[sl - 1] == '/') sl--;
        if (sl == 0) return 1;
        if (nl >= sl && memcmp(norm, s, sl) == 0 && (nl == sl || norm[sl] == '/')) return 1;
    }
    return 0;
}

typedef struct {
    size_t index;
    spath p;
} job;

static int job_cmp_frame(const void *a, const void *b, const xiz_archive *ar) {
    const entry_rec *x = &ar->cat.entries[((const job *)a)->index], *y = &ar->cat.entries[((const job *)b)->index];
    uint32_t fx = x->n_ext ? x->ext[0].frame : 0, fy = y->n_ext ? y->ext[0].frame : 0;
    return fx < fy ? -1 : fx > fy;
}

/* Insertion-merge sort with context (qsort_r is not portable). */
static void sort_jobs(job *j, size_t n, const xiz_archive *a) {
    if (n < 2) return;
    size_t h = n / 2;
    sort_jobs(j, h, a);
    sort_jobs(j + h, n - h, a);
    job *tmp = malloc(n * sizeof *tmp);
    if (!tmp) return;  /* unsorted is only slower */
    size_t i = 0, k = h, o = 0;
    while (i < h && k < n) tmp[o++] = job_cmp_frame(&j[k], &j[i], a) < 0 ? j[k++] : j[i++];
    while (i < h) tmp[o++] = j[i++];
    while (k < n) tmp[o++] = j[k++];
    memcpy(j, tmp, n * sizeof *tmp);
    free(tmp);
}

/* An existing destination: the `conflict` callback (or the overwrite flag) decides. 0 go on (the
 * path may have been renamed), -1 skip or cancel with *code and *why. */
static int prepare_target(ex_ctx *x, const char *path, spath *p, int *code, const char **why) {
    int is_dir = 0;
    if (!disk_exists(x, p, &is_dir)) return 0;
    int act = x->opt && x->opt->conflict ? x->opt->conflict(x->opt->ctx, path, p->norm)
              : (x->flags & XIZ_EXTRACT_OVERWRITE) ? XIZ_CONFLICT_OVERWRITE : XIZ_CONFLICT_SKIP;
    if (act == XIZ_CONFLICT_CANCEL) {
        x->cancelled = 1;
        *code = XIZ_E_CALLBACK;
        *why = "cancelled";
        return -1;
    }
    if (act == XIZ_CONFLICT_OVERWRITE) {
        if (is_dir) { *code = XIZ_E_EXISTS; *why = "a folder with that name exists"; return -1; }
        remove_existing(x, p);  /* a file or a link itself, never followed */
        return 0;
    }
    if (act == XIZ_CONFLICT_RENAME) {
        char *orig = NULL;
        for (unsigned k = 2; k < 100000; k++) {
            if (spath_rename_last(p, k, &orig)) { free(orig); *code = XIZ_E_NOMEM; *why = "out of memory"; return -1; }
            int d;
            if (!disk_exists(x, p, &d)) { free(orig); x->rep->renamed++; return 0; }
        }
        free(orig);
        *code = XIZ_E_EXISTS;
        *why = "no free name";
        return -1;
    }
    *code = XIZ_E_EXISTS;
    *why = "already exists";
    return -1;
}

/* ---- names equal but for case (§6 of docs/STUDIO_WINDOWS_XIZ.md) */

/* Upper-cased copy: Unicode on Windows (as NTFS compares), ASCII elsewhere. */
static char *fold_name(const char *s, size_t len) {
#if defined(_WIN32)
    char *tmp = malloc(len + 1);
    if (!tmp) return NULL;
    memcpy(tmp, s, len);
    tmp[len] = 0;
    wchar_t *w = xiz_utf8_to_wide(tmp);
    free(tmp);
    if (!w) return NULL;
    int wn = (int)wcslen(w) + 1;
    wchar_t *u = malloc((size_t)wn * sizeof(wchar_t));
    if (!u || !LCMapStringEx(L"", LCMAP_UPPERCASE, w, wn, u, wn, NULL, NULL, 0)) { free(w); free(u); return NULL; }
    free(w);
    int n = WideCharToMultiByte(CP_UTF8, 0, u, -1, NULL, 0, NULL, NULL);
    char *out = n > 0 ? malloc((size_t)n) : NULL;
    if (out && WideCharToMultiByte(CP_UTF8, 0, u, -1, out, n, NULL, NULL) <= 0) { free(out); out = NULL; }
    free(u);
    return out;
#else
    char *out = malloc(len + 1);
    if (!out) return NULL;
    for (size_t i = 0; i < len; i++) out[i] = (s[i] >= 'a' && s[i] <= 'z') ? (char)(s[i] - 32) : s[i];
    out[len] = 0;
    return out;
#endif
}

typedef struct {
    char *key;
    int leaf;                    /* 0 folder (stored or implied by a path), 1 file or link */
    size_t order;                /* catalog index */
    spath *p;                    /* leaves */
} fold_item;

static int fold_cmp(const void *a, const void *b) {
    const fold_item *x = a, *y = b;
    int c = strcmp(x->key, y->key);
    if (c) return c;
    if (x->leaf != y->leaf) return x->leaf - y->leaf;
    return x->order < y->order ? -1 : x->order > y->order;
}

static int fold_has(const fold_item *it, size_t n, const char *key) {
    size_t lo = 0, hi = n;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        int c = strcmp(it[mid].key, key);
        if (c == 0) return 1;
        if (c < 0) lo = mid + 1;
        else hi = mid;
    }
    return 0;
}

/* A file or link whose name collides (case-insensitively) with a folder or an earlier file gets
 * "name (k).ext", a name no other entry uses. */
static int fold_collisions(ex_ctx *x, job *dirs, size_t nd, job *files, size_t nf, job *links, size_t nl) {
    size_t cap = nd;
    for (size_t i = 0; i < nf; i++) cap += files[i].p.n;
    for (size_t i = 0; i < nl; i++) cap += links[i].p.n;
    fold_item *it = calloc(cap + 1, sizeof *it);
    char **taken = NULL;
    size_t n = 0, nt = 0;
    int rc = -1;
    if (!it) return -1;
    for (size_t i = 0; i < nd; i++) {
        if (!(it[n].key = fold_name(dirs[i].p.norm, strlen(dirs[i].p.norm)))) goto out;
        it[n].order = dirs[i].index;
        n++;
    }
    job *sets[2] = {files, links};
    size_t counts[2] = {nf, nl};
    for (int s = 0; s < 2; s++)
        for (size_t i = 0; i < counts[s]; i++) {
            spath *p = &sets[s][i].p;
            size_t off = 0;
            for (size_t c = 0; c < p->n; c++) {
                off += strlen(p->comp[c]) + (c ? 1 : 0);
                if (!(it[n].key = fold_name(p->norm, off))) goto out;
                it[n].order = sets[s][i].index;
                if (c == p->n - 1) { it[n].leaf = 1; it[n].p = p; }
                n++;
            }
        }
    qsort(it, n, sizeof *it, fold_cmp);
    for (size_t i = 0; i < n;) {
        size_t j = i;
        while (j < n && strcmp(it[j].key, it[i].key) == 0) j++;
        int keep_first = !it[i].leaf ? 0 : 1;  /* a folder wins over every file of that name */
        for (size_t k = i; k < j; k++) {
            if (!it[k].leaf) continue;
            if (keep_first) { keep_first = 0; continue; }
            char *orig = NULL, *key = NULL;
            for (unsigned num = 2;; num++) {
                free(key);
                key = NULL;
                if (spath_rename_last(it[k].p, num, &orig)) { free(orig); goto out; }
                if (!(key = fold_name(it[k].p->norm, strlen(it[k].p->norm)))) { free(orig); goto out; }
                int used = fold_has(it, n, key);
                for (size_t t = 0; t < nt && !used; t++) used = strcmp(taken[t], key) == 0;
                if (!used) break;
            }
            free(orig);
            char **nt2 = realloc(taken, (nt + 1) * sizeof *taken);
            if (!nt2) { free(key); goto out; }
            taken = nt2;
            taken[nt++] = key;
            x->rep->renamed++;
        }
        i = j;
    }
    rc = 0;
out:
    for (size_t i = 0; i < n; i++) free(it[i].key);
    free(it);
    for (size_t i = 0; i < nt; i++) free(taken[i]);
    free(taken);
    return rc;
}

int xiz_extract(xiz_archive *a, const char *dest, const xiz_extract_options *opt, xiz_extract_report *report,
                xiz_error *err) {
    if (!a || !dest) return FAIL(XIZ_E_ARG, "missing argument");
    xiz_extract_report rep = {0};
    ex_ctx x;
    memset(&x, 0, sizeof x);
    x.opt = opt;
    x.rep = &rep;
    x.flags = opt ? opt->flags : 0;
#if !defined(_WIN32)
    x.root = -1;
#endif
    size_t n = a->cat.n_entries;
    job *dirs = calloc(n + 1, sizeof(job)), *files = calloc(n + 1, sizeof(job)), *links = calloc(n + 1, sizeof(job));
    size_t nd = 0, nf = 0, nl = 0;
    int rc = XIZ_OK;
    if (!dirs || !files || !links) { rc = FAIL(XIZ_E_NOMEM, "out of memory"); goto out; }
    uint64_t declared = 0;
    for (size_t i = 0; i < n; i++) {
        const entry_rec *e = &a->cat.entries[i];
        spath p;
        const char *why;
        int r = sanitize(e->path, e->path_len, &p, &why);
        if (r == XIZ_E_NOMEM) { rc = FAIL(r, "out of memory"); goto out; }
        if (r) {
            if (strcmp(why, "empty path") == 0) continue;  /* the root itself: nothing to do */
            if (selected(opt, e->path)) skipped(&x, e->path, r, why);
            continue;
        }
        if (!selected(opt, p.norm)) { spath_free(&p); continue; }
#if defined(_WIN32)
        /* The names the files get on disk, so collisions, conflicts and callbacks see them. */
        for (size_t c = 0; c < p.n; c++) {
            char nm[1024];
            size_t l = xiz_windows_name(p.comp[c], strlen(p.comp[c]), nm, sizeof nm);
            if (l == strlen(p.comp[c]) && memcmp(nm, p.comp[c], l) == 0) continue;
            char *d = malloc(l + 1);
            if (!d) { spath_free(&p); rc = FAIL(XIZ_E_NOMEM, "out of memory"); goto out; }
            memcpy(d, nm, l + 1);
            free(p.comp[c]);
            p.comp[c] = d;
        }
        if (spath_rebuild(&p)) { spath_free(&p); rc = FAIL(XIZ_E_NOMEM, "out of memory"); goto out; }
#endif
        job j = {i, p};
        if (e->type == XIZ_TYPE_DIRECTORY) dirs[nd++] = j;
        else if (e->type == XIZ_TYPE_SYMLINK) links[nl++] = j;
        else { files[nf++] = j; declared += e->size; }
    }
    /* §7: declared sizes against limits and free space before anything is written. */
    if (opt && opt->max_bytes && declared > opt->max_bytes) {
        rc = FAIL(XIZ_E_LIMIT, "the selection declares %llu bytes (limit %llu)", (unsigned long long)declared,
                  (unsigned long long)opt->max_bytes);
        goto out;
    }
    if ((rc = platform_init(&x, dest, err))) goto out;
    uint64_t avail;
    if (free_space(&x, &avail) && declared > avail) {
        rc = FAIL(XIZ_E_LIMIT, "%llu bytes to extract, %llu free", (unsigned long long)declared, (unsigned long long)avail);
        goto out;
    }
    if (((x.flags & XIZ_EXTRACT_FOLD_CASE) || case_insensitive(&x)) &&
        fold_collisions(&x, dirs, nd, files, nf, links, nl) != 0) {
        rc = FAIL(XIZ_E_NOMEM, "out of memory");
        goto out;
    }
    x.total = declared;
    if (report_bytes(&x)) { rc = FAIL(XIZ_E_CALLBACK, "cancelled"); goto out; }
    for (size_t i = 0; i < nd; i++) {
        const char *why;
        const char *path = a->cat.entries[dirs[i].index].path;
        if (make_dir(&x, &dirs[i].p, &why) != 0) skipped(&x, path, XIZ_E_UNSAFE, why);
        else { rep.directories++; written(&x, path, &dirs[i].p); }
    }
    sort_jobs(files, nf, a);
    for (size_t i = 0; i < nf; i++) {
        const entry_rec *e = &a->cat.entries[files[i].index];
        uint64_t before = x.done;
        out_file o;
        int code;
        const char *why;
        if (prepare_target(&x, e->path, &files[i].p, &code, &why) != 0 ||
            create_file(&x, &files[i].p, &o, &code, &why) != 0) {
            if (x.cancelled) { rc = FAIL(XIZ_E_CALLBACK, "cancelled"); goto out; }
            skipped(&x, e->path, code, why);
            x.done = before + e->size;
            if (report_bytes(&x)) { rc = FAIL(XIZ_E_CALLBACK, "cancelled"); goto out; }
            continue;
        }
        xiz_error ee;
        int r = xiz_read_entry(a, files[i].index, write_file_cb, &o, &ee);
        if (r == XIZ_E_CALLBACK && x.cancelled) {
            close_file(&x, &o, e, 0);  /* the partial file is removed */
            rc = FAIL(XIZ_E_CALLBACK, "cancelled");
            goto out;
        }
        if (r == XIZ_E_CALLBACK) r = xiz_fail(&ee, XIZ_E_IO, "%s: write failed", e->path);
        close_file(&x, &o, e, r == XIZ_OK);
        x.done = before + e->size;
        if (r != XIZ_OK) {
            rep.failed++;
            if (opt && opt->skipped) opt->skipped(opt->ctx, e->path, r, ee.message);
            if (!(x.flags & XIZ_EXTRACT_CONTINUE) || r == XIZ_E_NOMEM) {
                rc = xiz_fail(err, r, "%s", ee.message);
                goto out;
            }
            if (report_bytes(&x)) { rc = FAIL(XIZ_E_CALLBACK, "cancelled"); goto out; }
            continue;
        }
        rep.files++;
        rep.bytes += e->size;
        written(&x, e->path, &files[i].p);
        if (opt && opt->progress) opt->progress(opt->ctx, e->path, e->size);
        if (report_bytes(&x)) { rc = FAIL(XIZ_E_CALLBACK, "cancelled"); goto out; }
    }
    /* Symbolic links last, so nothing above was written through one. */
    for (size_t i = 0; i < nl; i++) {
        const entry_rec *e = &a->cat.entries[links[i].index];
        if (x.flags & XIZ_EXTRACT_NO_SYMLINKS) { skipped(&x, e->path, XIZ_E_UNSAFE, "symbolic links disabled"); continue; }
        if (memchr(e->link, 0, e->link_len)) { skipped(&x, e->path, XIZ_E_UNSAFE, "NUL in the link target"); continue; }
        if (!(x.flags & XIZ_EXTRACT_EXTERNAL_SYMLINKS) && !symlink_inside(e->link, e->link_len, links[i].p.n - 1)) {
            skipped(&x, e->path, XIZ_E_UNSAFE, "symbolic link points outside the destination");
            continue;
        }
        int code;
        const char *why;
        if (prepare_target(&x, e->path, &links[i].p, &code, &why) != 0 ||
            make_symlink(&x, &links[i].p, e, &code, &why) != 0) {
            if (x.cancelled) { rc = FAIL(XIZ_E_CALLBACK, "cancelled"); goto out; }
            skipped(&x, e->path, code, why);
        } else {
            rep.symlinks++;
            written(&x, e->path, &links[i].p);
        }
    }
    /* Folder modes and times last (deepest first), so read-only folders do not block writes. */
    for (size_t i = nd; i-- > 0;) finish_dir(&x, &dirs[i].p, &a->cat.entries[dirs[i].index]);
out:
    for (size_t i = 0; i < nd; i++) spath_free(&dirs[i].p);
    for (size_t i = 0; i < nf; i++) spath_free(&files[i].p);
    for (size_t i = 0; i < nl; i++) spath_free(&links[i].p);
    free(dirs);
    free(files);
    free(links);
#if defined(_WIN32)
    if (x.root) platform_done(&x);
#else
    if (x.root >= 0) platform_done(&x);
#endif
    if (report) *report = rep;
    return rc;
}
