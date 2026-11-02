/* Sources: files (pread / ReadFile with an offset) and memory. */
#include "internal.h"

#if defined(_WIN32)
#  include <windows.h>
#else
#  include <errno.h>
#  include <fcntl.h>
#  include <sys/stat.h>
#  include <unistd.h>
#endif

#if defined(_WIN32)
wchar_t *xiz_utf8_to_wide(const char *s);  /* extract.c */

static int file_read(void *ctx, uint64_t off, void *buf, size_t len) {
    HANDLE h = (HANDLE)ctx;
    uint8_t *p = buf;
    while (len) {
        DWORD chunk = len > 0x40000000u ? 0x40000000u : (DWORD)len, got = 0;
        OVERLAPPED ov;
        memset(&ov, 0, sizeof ov);
        ov.Offset = (DWORD)off;
        ov.OffsetHigh = (DWORD)(off >> 32);
        if (!ReadFile(h, p, chunk, &got, &ov) || got == 0) return -1;
        p += got;
        off += got;
        len -= got;
    }
    return 0;
}

static void file_close(void *ctx) { CloseHandle((HANDLE)ctx); }

int xiz_source_file(xiz_source *out, const char *path, xiz_error *err) {
    wchar_t *w = xiz_utf8_to_wide(path);
    if (!w) return FAIL(XIZ_E_ARG, "invalid path");
    HANDLE h = CreateFileW(w, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
                           FILE_ATTRIBUTE_NORMAL, NULL);
    free(w);
    if (h == INVALID_HANDLE_VALUE) return FAIL(XIZ_E_IO, "cannot open %s (error %lu)", path, GetLastError());
    LARGE_INTEGER sz;
    if (!GetFileSizeEx(h, &sz)) { CloseHandle(h); return FAIL(XIZ_E_IO, "cannot stat %s", path); }
    out->read = file_read;
    out->ctx = (void *)h;
    out->size = (uint64_t)sz.QuadPart;
    out->close = file_close;
    return XIZ_OK;
}
#else
static int file_read(void *ctx, uint64_t off, void *buf, size_t len) {
    int fd = (int)(intptr_t)ctx;
    uint8_t *p = buf;
    while (len) {
        ssize_t r = pread(fd, p, len, (off_t)off);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return -1;
        p += r;
        off += (uint64_t)r;
        len -= (size_t)r;
    }
    return 0;
}

static void file_close(void *ctx) { close((int)(intptr_t)ctx); }

int xiz_source_file(xiz_source *out, const char *path, xiz_error *err) {
    if (!out || !path) return FAIL(XIZ_E_ARG, "missing argument");
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return FAIL(XIZ_E_IO, "cannot open %s: %s", path, strerror(errno));
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        return FAIL(XIZ_E_IO, "%s is not a regular file", path);
    }
    out->read = file_read;
    out->ctx = (void *)(intptr_t)fd;
    out->size = (uint64_t)st.st_size;
    out->close = file_close;
    return XIZ_OK;
}
#endif

static int memory_read(void *ctx, uint64_t off, void *buf, size_t len) {
    const uint8_t *base = ctx;
    memcpy(buf, base + off, len);  /* bounds checked by src_read against the declared size */
    return 0;
}

void xiz_source_memory(xiz_source *out, const void *data, size_t size) {
    out->read = memory_read;
    out->ctx = (void *)data;
    out->size = size;
    out->close = NULL;
}
