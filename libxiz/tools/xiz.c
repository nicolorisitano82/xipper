/* xiz — command line front end of libxiz. */
#include "xiz.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if defined(_WIN32)
#  include <fcntl.h>
#  include <io.h>
#endif

static const char *usage =
    "usage: xiz <command> [options] <archive> [...]\n"
    "\n"
    "  list    [-l] <archive>                  entries (-l: mode, size, date, group)\n"
    "  info    <archive>                       superblock, footer, segments, groups, signatures\n"
    "  test    [--frames] <archive>            check every frame and every file's digest\n"
    "  extract [-d DIR] [--overwrite] [--allow-external-symlinks] [--no-symlinks]\n"
    "          [--no-permissions] [--no-times] [--continue] <archive> [entry...]\n"
    "  cat     <archive> <entry>               write one entry to standard output\n"
    "  history <archive>                       segment signatures (XIZ 1.3)\n"
    "  forensic [--records] <archive>          forensic profile (XIZ 1.10): segments, frame hashes,\n"
    "                                         signatures, images against the source SHA-256\n"
    "  verify-proof <proof.json> <file>        check an xiz-proof-1 against a file\n"
    "  create  [-l LEVEL] [--frame-size MiB] [--overwrite] <archive> <file|folder>...\n"
    "  append  <archive> [--add FILE[:PATH]]... [--delete PATH]... [--mkdir PATH]...\n"
    "  scrub   [--repair] <archive>           check every byte against the recovery record (§15);\n"
    "                                         --repair rebuilds damaged bytes in place, no password\n"
    "  recovery add [--redundancy N] | remove | info <archive>\n"
    "\n"
    "credentials (any command that opens an archive):\n"
    "  --password-env VAR    password from an environment variable (create/append: encrypt)\n"
    "  --password-stdin      one password per line on standard input (custodians: several)\n"
    "  --identity FILE       X25519 secret key (XIZ-SECRET-KEY-1-…), repeatable\n"
    "  --beta                accept 0.1 beta archives\n";

#define MAX_PW 32
#define MAX_ID 16

static const char *passwords[MAX_PW];
static size_t n_passwords;
static uint8_t identities[MAX_ID][32];
static size_t n_identities;
static unsigned open_flags;

static void die(const char *msg) {
    fprintf(stderr, "xiz: %s\n", msg);
    exit(2);
}

static int b64v(int c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '-' || c == '+') return 62;
    if (c == '_' || c == '/') return 63;
    return -1;
}

static void load_identity(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) die("cannot read identity file");
    char line[512];
    const char *prefix = "XIZ-SECRET-KEY-1-";
    while (fgets(line, sizeof line, f)) {
        char *p = strstr(line, prefix);
        if (!p) continue;
        p += strlen(prefix);
        uint8_t out[48];
        size_t n = 0;
        uint32_t acc = 0;
        int bits = 0;
        for (; *p && b64v((unsigned char)*p) >= 0 && n < sizeof out; p++) {
            acc = acc << 6 | (uint32_t)b64v((unsigned char)*p);
            bits += 6;
            if (bits >= 8) { bits -= 8; out[n++] = (uint8_t)(acc >> bits); }
        }
        if (n != 32 || n_identities == MAX_ID) die("invalid identity file");
        memcpy(identities[n_identities++], out, 32);
        fclose(f);
        return;
    }
    fclose(f);
    die("no XIZ-SECRET-KEY-1- line in the identity file");
}

static void read_stdin_passwords(void) {
    char line[4096];
    while (n_passwords < MAX_PW && fgets(line, sizeof line, stdin)) {
        size_t l = strlen(line);
        while (l && (line[l - 1] == '\n' || line[l - 1] == '\r')) line[--l] = 0;
        if (!l) continue;
        char *copy = malloc(l + 1);
        if (!copy) die("out of memory");
        memcpy(copy, line, l + 1);
        passwords[n_passwords++] = copy;
    }
}

/* Removes credential options from argv; returns the new argc. */
static int take_credentials(int argc, char **argv) {
    int o = 1;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--password-env") && i + 1 < argc) {
            const char *v = getenv(argv[++i]);
            if (!v) die("password environment variable not set");
            if (n_passwords < MAX_PW) passwords[n_passwords++] = v;
        } else if (!strcmp(argv[i], "--password-stdin")) {
            read_stdin_passwords();
        } else if (!strcmp(argv[i], "--identity") && i + 1 < argc) {
            load_identity(argv[++i]);
        } else if (!strcmp(argv[i], "--beta")) {
            open_flags |= XIZ_OPEN_ALLOW_BETA;
        } else {
            argv[o++] = argv[i];
        }
    }
    return o;
}

static xiz_archive *open_archive_flags(const char *path, unsigned extra);
static xiz_archive *open_archive(const char *path) { return open_archive_flags(path, 0); }

static xiz_archive *open_archive_flags(const char *path, unsigned extra) {
    xiz_open_options opt;
    memset(&opt, 0, sizeof opt);
    if (n_passwords) {
        opt.password = passwords[0];
        opt.passwords = passwords + 1;
        opt.password_count = n_passwords - 1;
    }
    opt.identities = (const uint8_t(*)[32])identities;
    opt.identity_count = n_identities;
    opt.flags = open_flags | extra;
    xiz_archive *a;
    xiz_error err;
    int rc = xiz_open_file(&a, path, &opt, &err);
    if (rc) {
        fprintf(stderr, "xiz: %s: %s (%s)\n", path, err.message, xiz_status_name(rc));
        exit(rc == XIZ_E_PASSWORD_REQUIRED || rc == XIZ_E_WRONG_PASSWORD ? 3 : 1);
    }
    return a;
}

static void print_path(const char *p, size_t n) {
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)p[i];
        if (c < 0x20 || c == 0x7F) printf("\\x%02x", c);
        else putchar(c);
    }
}

static void hex(const uint8_t *b, size_t n) {
    for (size_t i = 0; i < n; i++) printf("%02x", b[i]);
}

static int cmd_list(int argc, char **argv) {
    int lng = 0;
    const char *path = NULL;
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "-l") || !strcmp(argv[i], "--long")) lng = 1;
        else path = argv[i];
    }
    if (!path) die("list: archive missing");
    xiz_archive *a = open_archive(path);
    size_t n = xiz_entry_count(a);
    for (size_t i = 0; i < n; i++) {
        xiz_entry e;
        xiz_get_entry(a, i, &e);
        if (lng) {
            char t = e.type == XIZ_TYPE_DIRECTORY ? 'd' : e.type == XIZ_TYPE_SYMLINK ? 'l' : '-';
            char date[32] = "";
            time_t tt = (time_t)e.mtime_sec;
            struct tm *tm = gmtime(&tt);
            if (tm) strftime(date, sizeof date, "%Y-%m-%d %H:%M:%S", tm);
            printf("%c%04o %12" PRIu64 "  %s  ", t, e.mode & 07777, e.size, date);
        }
        print_path(e.path, e.path_len);
        if (lng && e.type == XIZ_TYPE_SYMLINK) { printf(" -> "); print_path(e.link, e.link_len); }
        if (lng && e.group) printf("  [group %u]", e.group);
        putchar('\n');
    }
    xiz_close(a);
    return 0;
}

static int cmd_info(int argc, char **argv) {
    if (argc < 1) die("info: archive missing");
    xiz_archive *a = open_archive(argv[0]);
    xiz_info in;
    xiz_get_info(a, &in);
    printf("format          XIZ %u.%u\n", in.version_major, in.version_minor);
    printf("archive id      ");
    hex(in.archive_id, 16);
    printf("\nfeatures        0x%04x%s%s%s%s%s%s%s%s\n", in.required_features,
           in.required_features & XIZ_FEATURE_ENCRYPTED ? " encrypted" : "",
           in.required_features & XIZ_FEATURE_DICTIONARIES ? " dictionaries" : "",
           in.required_features & XIZ_FEATURE_DIRECTORY ? " directory" : "",
           in.required_features & XIZ_FEATURE_LZMA2 ? " lzma2" : "",
           in.required_features & XIZ_FEATURE_JPEG ? " jpeg" : "",
           in.required_features & XIZ_FEATURE_APPLE ? " apple" : "",
           in.required_features & XIZ_FEATURE_DEFLATE ? " deflate" : "",
           in.required_features & XIZ_FEATURE_TABLES ? " tables" : "");
    printf("segments        %u\n", in.segments);
    printf("frames          %u (store %u, zstd %u, LZMA2 %u, ARM64+LZMA2 %u, JPEG %u, LZRAVEN %u, LZMESH %u, preflate %u, OpenZL %u)\n", in.frame_count,
           in.codec_frames[0], in.codec_frames[1], in.codec_frames[2], in.codec_frames[3], in.codec_frames[4],
           in.codec_frames[5], in.codec_frames[6], in.codec_frames[7], in.codec_frames[8]);
    printf("dictionaries    %u\n", in.dictionaries);
    printf("entries         %u (%zu visible)\n", in.entry_count, in.visible_entries);
    printf("total bytes     %" PRIu64 "\n", in.total_bytes);
    if (in.trailing_bytes) printf("trailing bytes  %" PRIu64 " (interrupted append)\n", in.trailing_bytes);
    if (in.has_directory) {
        printf("groups          %u (%u hidden)%s\n", in.group_count, in.hidden_groups, in.erasable ? ", erasable" : "");
        for (size_t g = 0; g < xiz_group_count(a); g++) {
            xiz_group gr;
            xiz_get_group(a, g, &gr);
            printf("  group %u  %s", gr.id, gr.held ? (gr.name && *gr.name ? gr.name : "(default)") : "(no key)");
            for (size_t p = 0; p < gr.prefix_count; p++) printf("%s%s", p ? ", " : "  folders: ", xiz_group_prefix(a, g, p));
            putchar('\n');
        }
        if (in.erased_entries) printf("erased entries  %u\n", in.erased_entries);
    }
    for (size_t s = 0; s < xiz_stanza_count(a); s++) {
        xiz_stanza st;
        xiz_get_stanza(a, s, &st);
        static const char *names[] = {"?", "password", "password recipient", "public-key recipient", "threshold", "custodian share"};
        printf("key stanza      %s%s%s%s", names[st.type <= 5 ? st.type : 0], *st.label ? " \"" : "", st.label, *st.label ? "\"" : "");
        if (st.type == 4) printf(" (%d of %d)", st.k, st.n);
        printf("%s\n", st.opened ? " [opened]" : "");
    }
    xiz_close(a);
    return 0;
}

static void on_problem(void *ctx, long frame, long entry, int code, const char *message) {
    (void)ctx;
    (void)entry;
    if (frame >= 0) fprintf(stderr, "frame %ld: %s (%s)\n", frame, message, xiz_status_name(code));
    else fprintf(stderr, "%s (%s)\n", message, xiz_status_name(code));
}

static int cmd_test(int argc, char **argv) {
    int frames = 0;
    const char *path = NULL;
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "--frames")) frames = 1;
        else path = argv[i];
    }
    if (!path) die("test: archive missing");
    xiz_archive *a = open_archive(path);
    xiz_test_report r;
    xiz_error err;
    int rc = xiz_test(a, frames, on_problem, NULL, &r, &err);
    printf("%u frames checked (%u failed, %u not openable), %" PRIu64 " files checked (%" PRIu64 " failed)\n",
           r.frames_checked, r.frames_failed, r.frames_skipped, r.files_checked, r.files_failed);
    if (rc == XIZ_OK) printf("OK\n");
    else fprintf(stderr, "xiz: %s\n", err.message);
    xiz_close(a);
    return rc == XIZ_OK ? 0 : 1;
}

static void on_skip(void *ctx, const char *path, int code, const char *reason) {
    (void)ctx;
    fprintf(stderr, "skipped %s: %s (%s)\n", path, reason, xiz_status_name(code));
}

static int cmd_extract(int argc, char **argv) {
    xiz_extract_options o;
    memset(&o, 0, sizeof o);
    const char *dest = ".", *path = NULL;
    const char **sel = calloc((size_t)argc + 1, sizeof(char *));
    size_t nsel = 0;
    if (!sel) die("out of memory");
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "-d") && i + 1 < argc) dest = argv[++i];
        else if (!strcmp(argv[i], "--overwrite")) o.flags |= XIZ_EXTRACT_OVERWRITE;
        else if (!strcmp(argv[i], "--allow-external-symlinks")) o.flags |= XIZ_EXTRACT_EXTERNAL_SYMLINKS;
        else if (!strcmp(argv[i], "--no-symlinks")) o.flags |= XIZ_EXTRACT_NO_SYMLINKS;
        else if (!strcmp(argv[i], "--no-permissions")) o.flags |= XIZ_EXTRACT_NO_PERMISSIONS;
        else if (!strcmp(argv[i], "--no-times")) o.flags |= XIZ_EXTRACT_NO_TIMES;
        else if (!strcmp(argv[i], "--continue")) o.flags |= XIZ_EXTRACT_CONTINUE;
        else if (!path) path = argv[i];
        else sel[nsel++] = argv[i];
    }
    if (!path) die("extract: archive missing");
    o.select = sel;
    o.select_count = nsel;
    o.skipped = on_skip;
    xiz_archive *a = open_archive(path);
    xiz_extract_report r;
    xiz_error err;
    int rc = xiz_extract(a, dest, &o, &r, &err);
    printf("%" PRIu64 " files (%" PRIu64 " bytes), %" PRIu64 " folders, %" PRIu64 " links; %" PRIu64 " skipped, %" PRIu64
           " failed\n", r.files, r.bytes, r.directories, r.symlinks, r.skipped, r.failed);
    if (rc) fprintf(stderr, "xiz: %s (%s)\n", err.message, xiz_status_name(rc));
    xiz_close(a);
    free(sel);
    return rc ? 1 : (r.failed || r.skipped ? 4 : 0);
}

static int stdout_write(void *ctx, const void *d, size_t n) {
    (void)ctx;
    return fwrite(d, 1, n, stdout) != n;
}

static int cmd_cat(int argc, char **argv) {
    if (argc < 2) die("cat: archive and entry needed");
    xiz_archive *a = open_archive(argv[0]);
    size_t i;
    if (xiz_find(a, argv[1], &i) != XIZ_OK) { fprintf(stderr, "xiz: no entry %s\n", argv[1]); xiz_close(a); return 1; }
#if defined(_WIN32)
    _setmode(_fileno(stdout), _O_BINARY);
#endif
    xiz_error err;
    int rc = xiz_read_entry(a, i, stdout_write, NULL, &err);
    fflush(stdout);
    if (rc) fprintf(stderr, "xiz: %s (%s)\n", err.message, xiz_status_name(rc));
    xiz_close(a);
    return rc ? 1 : 0;
}

static void b64url(const uint8_t *b, size_t n) {
    static const char *t = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    uint32_t acc = 0;
    int bits = 0;
    for (size_t i = 0; i < n; i++) {
        acc = acc << 8 | b[i];
        bits += 8;
        while (bits >= 6) { bits -= 6; putchar(t[(acc >> bits) & 63]); }
    }
    if (bits) putchar(t[(acc << (6 - bits)) & 63]);
}

static int cmd_history(int argc, char **argv) {
    if (argc < 1) die("history: archive missing");
    xiz_archive *a = open_archive_flags(argv[0], XIZ_OPEN_NO_KEYS);  /* signatures need no key */
    uint32_t n;
    xiz_signature_count(a, &n);
    int bad = 0;
    for (uint32_t s = 0; s < n; s++) {
        xiz_signature sg;
        xiz_error err;
        if (xiz_get_signature(a, s, &sg, &err)) { fprintf(stderr, "xiz: %s\n", err.message); bad = 1; break; }
        if (!sg.is_signed) { printf("#%u  unsigned\n", s); continue; }
        char date[32] = "?";
        time_t tt = (time_t)sg.time;
        struct tm *tm = gmtime(&tt);
        if (tm) strftime(date, sizeof date, "%Y-%m-%d %H:%M:%SZ", tm);
        if (sg.unknown_algorithm) {
            printf("#%u  signed with algorithm %d, unknown to this xiz: not verified\n", s, sg.algorithm);
            bad = 1;
            continue;
        }
        if (sg.algorithm == 1) {
            printf("#%u  %s  %s  xizsig1", s, sg.label, date);
            b64url(sg.public_key, 32);
        } else if (sg.algorithm == 4) {
            printf("#%u  %s  %s  xizsigpq1:", s, sg.label, date);
            for (int i = 0; i < 16; i++) printf("%02x", sg.key_sha256[i]);
            printf(" (Ed25519 + ML-DSA-65)");
        } else if (sg.algorithm == 5) {
            printf("#%u  %s  %s  xizsigse1:", s, sg.label, date);
            for (int i = 0; i < 16; i++) printf("%02x", sg.key_sha256[i]);
            printf(" (Secure Enclave, P-256 + ML-DSA-65)");
        } else {
            printf("#%u  %s  %s  x509:", s, sg.label, date);
            for (int i = 0; i < 32; i++) printf("%02x", sg.certificate_sha256[i]);
            printf(" (%s, %u certificates, chain not checked)", sg.algorithm == 2 ? "ECDSA P-256" : "RSA", sg.chain_count);
        }
        printf("  signature %s, chain %s%s\n", sg.valid ? "valid" : "INVALID", sg.chained ? "ok" : "BROKEN",
               sg.has_timestamp ? ", time-stamp present (not verified)" : "");
        if (!sg.valid || !sg.chained) bad = 1;
    }
    if (n && xiz_entry_count(a)) {
        xiz_error err;
        int rc = xiz_check_tree(a, &err);
        if (rc == XIZ_OK) printf("inclusion tree  ok\n");
        else if (rc != XIZ_E_UNSUPPORTED) { printf("inclusion tree  %s\n", err.message); bad = 1; }
    }
    xiz_close(a);
    return bad;
}

static void forensic_problem(void *ctx, long frame, long entry, int code, const char *message) {
    (void)frame; (void)entry; (void)code;
    ++*(int *)ctx;
    printf("FAIL  %s\n", message);
}

static int cmd_forensic(int argc, char **argv) {
    int records = 0;
    if (argc >= 1 && !strcmp(argv[0], "--records")) { records = 1; argc--; argv++; }
    if (argc < 1) die("forensic: archive missing");
    xiz_archive *a = open_archive_flags(argv[0], XIZ_OPEN_NO_KEYS);  /* opens with keys when credentials were given */
    xiz_error err;
    int bad = 0;
    if (records) {
        xiz_forensic_record *r = NULL;
        size_t n = 0;
        if (xiz_forensic_records(a, &r, &n, &err)) { fprintf(stderr, "xiz: %s\n", err.message); xiz_close(a); return 1; }
        for (size_t i = 0; i < n; i++) {
            int text = !(r[i].type & 0x8000u);
            printf("segment %u  0x%04x  %zu bytes%s%s\n", r[i].segment, r[i].type, r[i].length, text ? "  " : "",
                   text ? (const char *)r[i].value : "");
        }
        xiz_free(r);
        xiz_close(a);
        return 0;
    }
    xiz_forensic_report rep;
    if (xiz_forensic_verify(a, forensic_problem, &bad, &rep, &err)) { fprintf(stderr, "xiz: %s\n", err.message); xiz_close(a); return 1; }
    printf("%s  segments: %u (%u of custody)\n", rep.profile_ok ? "ok  " : "FAIL", rep.segments, rep.custody_segments);
    printf("%s  frame hashes: %u frames checked, %u altered, %u without hash\n",
           rep.frames_altered || rep.frames_unhashed ? "FAIL" : "ok  ", rep.frames_checked, rep.frames_altered, rep.frames_unhashed);
    uint32_t n;
    xiz_signature_count(a, &n);
    int sig_bad = 0;
    for (uint32_t s = 0; s < n; s++) {
        xiz_signature sg;
        if (xiz_get_signature(a, s, &sg, &err) || !sg.is_signed || !sg.valid || !sg.chained) sig_bad = 1;
    }
    printf("%s  signatures: %u segments%s\n", sig_bad ? "FAIL" : "ok  ", n, sig_bad ? ", unsigned, invalid or chain broken" : " signed, chain ok");
    xiz_info info;
    xiz_get_info(a, &info);
    if (rep.images_checked == 0 && (rep.images || (info.encrypted && info.visible_entries == 0)))
        printf("skip  images: the content needs the password or a key\n");
    else if (rep.images_failed)
        printf("FAIL  images: %u checked, %u failed\n", rep.images_checked, rep.images_failed);
    else if (rep.images) {
        printf("ok    images: %u checked, SHA-256 equal to the source's (last: ", rep.images_checked);
        for (int i = 0; i < 32; i++) printf("%02x", rep.last_image_sha256[i]);
        printf(")\n");
    }
    if (rep.has_inventory) {
        if (!rep.inventory_ok && !rep.inventory_failed) printf("skip  files: the inventory needs the password or a key\n");
        else printf("%s  files: %u checked against the signed inventory, %u problems\n", rep.inventory_failed ? "FAIL" : "ok  ",
                    rep.inventory_files, rep.inventory_failed);
    }
    int failed = bad || rep.inventory_failed || !rep.profile_ok || rep.frames_altered || rep.frames_unhashed || sig_bad || rep.images_failed;
    printf(failed ? "VERIFICATION FAILED\n" : "verified\n");
    xiz_close(a);
    return failed ? 1 : 0;
}

static uint8_t *slurp(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    size_t cap = 1 << 16, n = 0;
    uint8_t *b = malloc(cap);
    while (b) {
        size_t r = fread(b + n, 1, cap - n, f);
        n += r;
        if (n < cap) break;
        uint8_t *nb = realloc(b, cap *= 2);
        if (!nb) { free(b); b = NULL; }
        else b = nb;
    }
    fclose(f);
    *len = n;
    return b;
}

static int cmd_verify_proof(int argc, char **argv) {
    if (argc < 2) die("verify-proof: proof and file needed");
    size_t jl, cl;
    uint8_t *j = slurp(argv[0], &jl), *c = slurp(argv[1], &cl);
    if (!j || !c) die("cannot read the proof or the file");
    xiz_proof_result r;
    xiz_error err;
    int rc = xiz_verify_proof((const char *)j, jl, c, cl, &r, &err);
    free(j);
    free(c);
    if (rc) { fprintf(stderr, "xiz: %s\n", err.message); return 1; }
    printf("%s (%" PRIu64 " bytes), segment %u\n", r.path, r.size, r.segment);
    printf("  content  %s\n", r.content_matches ? "matches" : "DOES NOT MATCH");
    printf("  tree     %s\n", r.in_tree ? "leads to the directory root" : "DOES NOT lead to the root");
    printf("  signed   %s%s%s\n", r.is_signed ? "yes, by " : "no", r.is_signed ? r.signer : "", "");
    return r.content_matches && r.in_tree && r.is_signed ? 0 : 1;
}

static int cmd_create(int argc, char **argv) {
    xiz_writer_options wo;
    memset(&wo, 0, sizeof wo);
    int overwrite = 0;
    const char *out = NULL;
    const char **inputs = calloc((size_t)argc + 1, sizeof(char *));
    size_t ni = 0;
    if (!inputs) die("out of memory");
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "-l") && i + 1 < argc) wo.level = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--frame-size") && i + 1 < argc) wo.frame_size = (uint32_t)atoi(argv[++i]) << 20;
        else if (!strcmp(argv[i], "--overwrite")) overwrite = 1;
        else if (!out) out = argv[i];
        else inputs[ni++] = argv[i];
    }
    if (!out || !ni) die("create: archive and inputs needed");
    if (n_passwords) wo.password = passwords[0];
    const char *kdf = getenv("XIZ_TEST_FAST_KDF");  /* tests only: minimum Argon2id cost */
    if (kdf && *kdf == '1') { wo.kdf_memory_kib = 19456; wo.kdf_iterations = 1; wo.kdf_parallelism = 1; }
    xiz_writer *w;
    xiz_error err;
    if (xiz_writer_create(&w, out, &wo, overwrite, &err)) { fprintf(stderr, "xiz: %s\n", err.message); free(inputs); return 1; }
    for (size_t i = 0; i < ni; i++) {
        const char *base = inputs[i] + strlen(inputs[i]);
        while (base > inputs[i] && (base[-1] == '/' || base[-1] == '\\')) base--;
        const char *end = base;
        while (base > inputs[i] && base[-1] != '/' && base[-1] != '\\') base--;
        char name[4096];
        snprintf(name, sizeof name, "%.*s", (int)(end - base), base);
        if (xiz_writer_add_tree(w, name, inputs[i], &err)) {
            fprintf(stderr, "xiz: %s\n", err.message);
            xiz_writer_abort(w);
            free(inputs);
            return 1;
        }
    }
    free(inputs);
    if (xiz_writer_finish(w, &err)) { fprintf(stderr, "xiz: %s\n", err.message); return 1; }
    return 0;
}

static int cmd_append(int argc, char **argv) {
    if (argc < 1) die("append: archive missing");
    xiz_writer_options wo;
    memset(&wo, 0, sizeof wo);
    if (n_passwords) wo.password = passwords[0];
    const char *path = NULL;
    for (int i = 0; i < argc; i++)
        if (argv[i][0] != '-') { path = argv[i]; break; }
        else i++;
    if (!path) die("append: archive missing");
    xiz_writer *w;
    xiz_error err;
    if (xiz_writer_append(&w, path, &wo, &err)) { fprintf(stderr, "xiz: %s\n", err.message); return 1; }
    for (int i = 0; i < argc; i++) {
        int rc = XIZ_OK;
        if (!strcmp(argv[i], "--add") && i + 1 < argc) {
            char *spec = argv[++i], *colon = strrchr(spec, ':');
            char disk[4096], inner[4096];
            if (colon && colon != spec && colon[1]) {
                snprintf(disk, sizeof disk, "%.*s", (int)(colon - spec), spec);
                snprintf(inner, sizeof inner, "%s", colon + 1);
            } else {
                snprintf(disk, sizeof disk, "%s", spec);
                const char *b = strrchr(spec, '/');
                snprintf(inner, sizeof inner, "%s", b ? b + 1 : spec);
            }
            xiz_writer_remove(w, inner, NULL);
            rc = xiz_writer_add_tree(w, inner, disk, &err);
        } else if (!strcmp(argv[i], "--delete") && i + 1 < argc) {
            rc = xiz_writer_remove(w, argv[++i], &err);
        } else if (!strcmp(argv[i], "--mkdir") && i + 1 < argc) {
            rc = xiz_writer_add_directory(w, argv[++i], NULL, &err);
        }
        if (rc) { fprintf(stderr, "xiz: %s\n", err.message); xiz_writer_abort(w); return 1; }
    }
    if (xiz_writer_finish(w, &err)) { fprintf(stderr, "xiz: %s\n", err.message); return 1; }
    return 0;
}

static void print_recovery(const xiz_recovery_info *i) {
    printf("recovery record: %" PRIu64 " bytes, %u recovery slices for %u slices of %u bytes: repairs up to %u damaged places\n",
           i->record_bytes, i->recovery_slices, i->data_slices, i->slice_size, i->recovery_slices);
}

static int cmd_scrub(int argc, char **argv) {
    int repair = 0;
    const char *path = NULL;
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "--repair")) repair = 1;
        else path = argv[i];
    }
    if (!path) die("scrub: archive missing");
    xiz_recovery_report r;
    xiz_error err;
    if (xiz_recovery_scrub(path, repair, &r, &err)) { fprintf(stderr, "xiz: %s\n", err.message); return 1; }
    if (!r.has_record) { printf("no recovery record\n"); return 1; }
    print_recovery(&r.info);
    if (r.damaged_data_slices) printf("DAMAGED %u data slices\n", r.damaged_data_slices);
    if (r.damaged_recovery_slices) printf("DAMAGED %u recovery slices\n", r.damaged_recovery_slices);
    if (r.damaged_metadata) printf("DAMAGED %u of 3 copies of the record's index\n", r.damaged_metadata);
    if (!r.damaged_data_slices && !r.damaged_recovery_slices && !r.damaged_metadata) { printf("all bytes intact\n"); return 0; }
    if (r.repaired) { printf("repaired\n"); return 0; }
    printf(r.repairable ? "repair possible: xiz scrub --repair\n" : "repair NOT possible\n");
    return 1;
}

static int cmd_recovery(int argc, char **argv) {
    double pct = 10;
    const char *op = NULL, *path = NULL;
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "--redundancy") && i + 1 < argc) pct = atof(argv[++i]);
        else if (!op) op = argv[i];
        else path = argv[i];
    }
    if (!op || !path) die("recovery: add, remove or info and an archive");
    xiz_error err;
    xiz_recovery_info info;
    if (!strcmp(op, "add")) {
        if (xiz_recovery_add(path, pct, &info, &err)) { fprintf(stderr, "xiz: %s\n", err.message); return 1; }
        print_recovery(&info);
    } else if (!strcmp(op, "remove")) {
        int removed;
        if (xiz_recovery_remove(path, &removed, &err)) { fprintf(stderr, "xiz: %s\n", err.message); return 1; }
        printf(removed ? "recovery record removed\n" : "no recovery record\n");
    } else if (!strcmp(op, "info")) {
        if (xiz_recovery_info_file(path, &info, &err)) { printf("no recovery record\n"); return 1; }
        print_recovery(&info);
    } else die("recovery: add, remove or info");
    return 0;
}

int main(int argc, char **argv) {
    argc = take_credentials(argc, argv);
    if (argc < 2 || !strcmp(argv[1], "-h") || !strcmp(argv[1], "--help")) { fputs(usage, argc < 2 ? stderr : stdout); return argc < 2 ? 2 : 0; }
    if (!strcmp(argv[1], "--version")) { printf("xiz %s (XIZ 1.%d)\n", xiz_version(), XIZ_FORMAT_MINOR); return 0; }
    const char *c = argv[1];
    int n = argc - 2;
    char **v = argv + 2;
    if (!strcmp(c, "list") || !strcmp(c, "ls")) return cmd_list(n, v);
    if (!strcmp(c, "info")) return cmd_info(n, v);
    if (!strcmp(c, "test")) return cmd_test(n, v);
    if (!strcmp(c, "extract") || !strcmp(c, "x")) return cmd_extract(n, v);
    if (!strcmp(c, "cat")) return cmd_cat(n, v);
    if (!strcmp(c, "history")) return cmd_history(n, v);
    if (!strcmp(c, "forensic")) return cmd_forensic(n, v);
    if (!strcmp(c, "verify-proof")) return cmd_verify_proof(n, v);
    if (!strcmp(c, "create")) return cmd_create(n, v);
    if (!strcmp(c, "append")) return cmd_append(n, v);
    if (!strcmp(c, "scrub")) return cmd_scrub(n, v);
    if (!strcmp(c, "recovery")) return cmd_recovery(n, v);
    fputs(usage, stderr);
    return 2;
}
