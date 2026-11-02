/* Prints a sorted description of a directory tree, one line per entry:
 *   path TAB f MODE MTIME SHA256 | path TAB d MODE MTIME | path TAB l - - TARGET
 * Used to compare what xiz extracts with what xipper archived (POSIX only). */
#define _XOPEN_SOURCE 700
#define _DARWIN_C_SOURCE
#include "internal.h"

#include <dirent.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

static char **lines;
static size_t n, cap;
static int with_mtime = 1;

static void add(const char *s) {
    if (n == cap) {
        cap = cap ? cap * 2 : 64;
        lines = realloc(lines, cap * sizeof *lines);
    }
    lines[n++] = strdup(s);
}

static void walk(const char *root, const char *rel) {
    char full[4096];
    snprintf(full, sizeof full, "%s%s%s", root, *rel ? "/" : "", rel);
    DIR *d = opendir(full);
    if (!d) return;
    struct dirent *de;
    while ((de = readdir(d))) {
        if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, "..")) continue;
        char r[4096], p[4096], line[8192];
        snprintf(r, sizeof r, "%s%s%s", rel, *rel ? "/" : "", de->d_name);
        snprintf(p, sizeof p, "%s/%s", root, r);
        struct stat st;
        if (lstat(p, &st)) continue;
        long long mt = with_mtime ? (long long)st.st_mtime : 0;
        if (S_ISLNK(st.st_mode)) {
            char t[4096];
            ssize_t k = readlink(p, t, sizeof t - 1);
            t[k < 0 ? 0 : k] = 0;
            snprintf(line, sizeof line, "%s\tl - - %s", r, t);
            add(line);
        } else if (S_ISDIR(st.st_mode)) {
            snprintf(line, sizeof line, "%s\td %04o %lld", r, (unsigned)(st.st_mode & 07777), mt);
            add(line);
            walk(root, r);
        } else if (S_ISREG(st.st_mode)) {
            FILE *f = fopen(p, "rb");
            sha256_ctx c;
            sha256_init(&c);
            uint8_t buf[65536], h[32];
            size_t k;
            while (f && (k = fread(buf, 1, sizeof buf, f)) > 0) sha256_update(&c, buf, k);
            if (f) fclose(f);
            sha256_final(&c, h);
            char hex[65];
            for (int i = 0; i < 32; i++) sprintf(hex + 2 * i, "%02x", h[i]);
            snprintf(line, sizeof line, "%s\tf %04o %lld %s", r, (unsigned)(st.st_mode & 07777), mt, hex);
            add(line);
        }
    }
    closedir(d);
}

static int cmp(const void *a, const void *b) {
    return strcmp(*(char *const *)a, *(char *const *)b);
}

int main(int argc, char **argv) {
    if (argc > 2 && !strcmp(argv[1], "--no-mtime")) { with_mtime = 0; argv++; argc--; }
    if (argc != 2) { fprintf(stderr, "usage: xiz_manifest [--no-mtime] DIR\n"); return 2; }
    walk(argv[1], "");
    qsort(lines, n, sizeof *lines, cmp);
    for (size_t i = 0; i < n; i++) puts(lines[i]);
    return 0;
}
