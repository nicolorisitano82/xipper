#include "core.h"

#include <shlobj.h>
#include <shlwapi.h>

#include <algorithm>
#include <thread>

#include "strings.h"

// ---------------------------------------------------------------- text

std::string utf8(const std::wstring &w) {
    if (w.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s((size_t)std::max(n, 0), '\0');
    if (n > 0) WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), s.data(), n, nullptr, nullptr);
    return s;
}

std::wstring wide(const char *s, size_t len) {
    if (!len) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s, (int)len, nullptr, 0);
    std::wstring w((size_t)std::max(n, 0), L'\0');
    if (n > 0) MultiByteToWideChar(CP_UTF8, 0, s, (int)len, w.data(), n);
    return w;
}

std::string password_utf8(const std::wstring &typed) {
    if (typed.empty()) return {};
    std::wstring nfc = typed;
    int n = NormalizeString(NormalizationC, typed.c_str(), (int)typed.size(), nullptr, 0);
    for (int attempt = 0; n > 0 && attempt < 4; attempt++) {
        std::wstring buf((size_t)n, L'\0');
        int r = NormalizeString(NormalizationC, typed.c_str(), (int)typed.size(), buf.data(), n);
        if (r > 0) { buf.resize((size_t)r); nfc.swap(buf); SecureZeroMemory(buf.data(), buf.size() * sizeof(wchar_t)); break; }
        if (GetLastError() != ERROR_INSUFFICIENT_BUFFER) break;  // invalid text: used as typed
        n = -r;
    }
    std::string s = utf8(nfc);
    SecureZeroMemory(nfc.data(), nfc.size() * sizeof(wchar_t));
    return s;
}

std::wstring file_name(const std::wstring &path) {
    size_t p = path.find_last_of(L"\\/");
    return p == std::wstring::npos ? path : path.substr(p + 1);
}

std::wstring parent_dir(const std::wstring &path) {
    size_t p = path.find_last_of(L"\\/");
    return p == std::wstring::npos ? L"." : path.substr(0, p);
}

std::wstring stem(const std::wstring &path) {
    std::wstring n = file_name(path);
    size_t d = n.find_last_of(L'.');
    return d == std::wstring::npos || d == 0 ? n : n.substr(0, d);
}

std::wstring exe_path() {
    std::wstring p(MAX_PATH, L'\0');
    for (;;) {
        DWORD n = GetModuleFileNameW(nullptr, p.data(), (DWORD)p.size());
        if (n < p.size()) { p.resize(n); return p; }
        p.resize(p.size() * 2);
    }
}

std::wstring byte_size(uint64_t n) {
    wchar_t buf[64];
    if (StrFormatByteSizeEx(n, SFBS_FLAGS_ROUND_TO_NEAREST_DISPLAYED_DIGIT, buf, 64) == S_OK) return buf;
    return std::to_wstring(n);
}

// ---------------------------------------------------------------- credentials

void Credentials::wipe() {
    for (auto &p : passwords) SecureZeroMemory(p.data(), p.size());
    passwords.clear();
    for (auto *v : {&identities, &pq_identities, &factors}) {
        for (auto &k : *v) SecureZeroMemory(k.data(), k.size());
        v->clear();
    }
    given.clear();
    kinds.clear();
}

void Credentials::add_password(const std::wstring &typed) {
    if (typed.empty()) return;
    passwords.push_back(password_utf8(typed));
    given.push_back(fmt(S::GivenPassword, (unsigned)passwords.size()));
    kinds.push_back(0);
}

int Credentials::add_key_file(const std::wstring &path) {
    Secret k{};
    int kind = read_secret(path, k);
    switch (kind) {
    case XIZ_SECRET_X25519: identities.push_back(k); given.push_back(fmt(S::GivenKey, file_name(path).c_str())); break;
    case XIZ_SECRET_XWING: pq_identities.push_back(k); given.push_back(fmt(S::GivenKeyPq, file_name(path).c_str())); break;
    case XIZ_SECRET_FACTOR: factors.push_back(k); given.push_back(fmt(S::GivenFactor, file_name(path).c_str())); break;
    }
    if (kind > 0) kinds.push_back(kind);
    SecureZeroMemory(k.data(), k.size());
    return kind;
}

int read_secret(const std::wstring &path, Secret &out) {
    HANDLE h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
    if (h == INVALID_HANDLE_VALUE) return XIZ_E_IO;
    char buf[4096];
    DWORD n = 0;
    BOOL ok = ReadFile(h, buf, sizeof buf, &n, nullptr);
    CloseHandle(h);
    if (!ok) return XIZ_E_IO;
    int kind = xiz_parse_secret(buf, n, out.data());
    SecureZeroMemory(buf, sizeof buf);
    return kind;
}

// ---------------------------------------------------------------- opening

static std::string read_zone(const std::wstring &path) {
    HANDLE h = CreateFileW((path + L":Zone.Identifier").c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
    if (h == INVALID_HANDLE_VALUE) return {};
    char buf[4096];
    DWORD n = 0;
    std::string z;
    if (ReadFile(h, buf, sizeof buf, &n, nullptr) && n > 0 && n < sizeof buf) z.assign(buf, n);
    CloseHandle(h);
    return z;
}

int open_archive(const std::wstring &path, const Credentials &c, Archive &out, xiz_error *err, unsigned flags) {
    xiz_open_options o{};
    o.flags = flags;
    std::vector<const char *> more;
    for (size_t i = 0; i < c.passwords.size(); i++) {
        if (i == 0) o.password = c.passwords[0].c_str();
        else more.push_back(c.passwords[i].c_str());
    }
    o.passwords = more.empty() ? nullptr : more.data();
    o.password_count = more.size();
    auto keys = [](const std::vector<Secret> &v) { return v.empty() ? nullptr : reinterpret_cast<const uint8_t(*)[32]>(v.data()); };
    o.identities = keys(c.identities);
    o.identity_count = c.identities.size();
    o.pq_identities = keys(c.pq_identities);
    o.pq_identity_count = c.pq_identities.size();
    o.factors = keys(c.factors);
    o.factor_count = c.factors.size();
    xiz_archive *a = nullptr;
    int rc = xiz_open_file(&a, utf8(path).c_str(), &o, err);
    if (rc != XIZ_OK) return rc;
    wchar_t full[32768];
    DWORD fl = GetFullPathNameW(path.c_str(), 32768, full, nullptr);
    out.path = fl > 0 && fl < 32768 ? std::wstring(full, fl) : path;
    out.a = a;
    xiz_get_info(a, &out.info);
    size_t n = xiz_entry_count(a);
    out.entries.reserve(n);
    for (size_t i = 0; i < n; i++) {
        xiz_entry e;
        if (xiz_get_entry(a, i, &e) != XIZ_OK) continue;
        Entry r;
        r.stored.assign(e.path, e.path_len);
        r.path = wide(r.stored);
        std::replace(r.path.begin(), r.path.end(), L'/', L'\\');
        r.size = e.size;
        r.mtime = e.mtime_sec;
        r.type = e.type;
        r.group = e.group;
        if (e.type == XIZ_TYPE_FILE) out.bytes += e.size;
        out.entries.push_back(std::move(r));
    }
    std::sort(out.entries.begin(), out.entries.end(), [](const Entry &x, const Entry &y) {
        return CompareStringOrdinal(x.path.c_str(), (int)x.path.size(), y.path.c_str(), (int)y.path.size(), TRUE) == CSTR_LESS_THAN;
    });
    out.zone = read_zone(path);
    return XIZ_OK;
}

// ---------------------------------------------------------------- describing an archive

std::wstring date_time(int64_t t) {
    wchar_t buf[96];
    ULONGLONG ft = (ULONGLONG)(t + 11644473600LL) * 10000000ULL;
    FILETIME f{(DWORD)ft, (DWORD)(ft >> 32)}, lf;
    SYSTEMTIME s;
    buf[0] = 0;
    if (t <= 0 || !FileTimeToLocalFileTime(&f, &lf) || !FileTimeToSystemTime(&lf, &s)) return buf;
    int n = GetDateFormatEx(LOCALE_NAME_USER_DEFAULT, DATE_SHORTDATE, &s, nullptr, buf, 64, nullptr);
    if (n > 0) {
        buf[n - 1] = L' ';
        GetTimeFormatEx(LOCALE_NAME_USER_DEFAULT, TIME_NOSECONDS, &s, nullptr, buf + n, 96 - n);
    }
    return buf;
}

static std::wstring hex(const uint8_t *p, size_t n) {
    std::wstring s;
    for (size_t i = 0; i < n; i++) s += vfmt(L"%02x", p[i]);
    return s;
}

bool needs_keys(xiz_archive *a) {
    for (size_t i = 0; i < xiz_stanza_count(a); i++) {
        xiz_stanza st;
        if (xiz_get_stanza(a, i, &st) == XIZ_OK && st.type >= 2 && st.type <= 7) return true;
    }
    return false;
}

std::vector<std::wstring> access_lines(xiz_archive *a) {
    std::vector<std::wstring> lines;
    std::vector<xiz_stanza> all;
    for (size_t i = 0; i < xiz_stanza_count(a); i++) {
        xiz_stanza st;
        if (xiz_get_stanza(a, i, &st) == XIZ_OK) all.push_back(st);
    }
    auto label = [](const xiz_stanza &st) { return wide(st.label, strlen(st.label)); };
    bool plain_pw = false;
    for (auto &st : all) {
        std::wstring l;
        switch (st.type) {
        case 1: if (plain_pw) continue; plain_pw = true; l = T(S::AccPassword); break;
        case 2: l = st.label[0] ? fmt(S::AccPasswordLabel, label(st).c_str()) : T(S::AccPassword); break;
        case 3: l = fmt(S::AccKey, label(st).c_str()); break;
        case 6: l = fmt(S::AccKeyPq, label(st).c_str()); break;
        case 8: l = T(S::AccPasswordFactor); break;
        case 4: {
            std::wstring names;
            for (auto &sh : all)
                if ((sh.type == 5 || sh.type == 7) && sh.threshold_id == st.threshold_id)
                    names += (names.empty() ? L"" : L", ") + label(sh) + (sh.opened ? T(S::AccOpened) : L"");
            l = fmt(S::AccThreshold, st.k, st.n, names.c_str());
            break;
        }
        default: continue;
        }
        if (st.opened && st.type != 4) l += T(S::AccOpened);
        lines.push_back(L"\x2022 " + l);
    }
    return lines;
}

std::wstring group_name(xiz_archive *a, uint16_t id) {
    for (size_t g = 0; g < xiz_group_count(a); g++) {
        xiz_group gr;
        if (xiz_get_group(a, g, &gr) != XIZ_OK || gr.id != id) continue;
        if (gr.name && *gr.name) return wide(gr.name, strlen(gr.name));
        break;
    }
    return T(S::GroupDefault);
}

std::vector<SigRow> signatures(xiz_archive *a) {
    std::vector<SigRow> rows;
    uint32_t n = 0;
    if (xiz_signature_count(a, &n) != XIZ_OK) return rows;
    for (uint32_t i = 0; i < n; i++) {
        xiz_signature sg;
        xiz_error e;
        SigRow r;
        r.segment = i;
        if (xiz_get_signature(a, i, &sg, &e) != XIZ_OK) { r.signer = wide(e.message, strlen(e.message)); rows.push_back(r); continue; }
        r.is_signed = sg.is_signed;
        r.valid = sg.valid;
        r.chained = sg.chained;
        r.unknown = sg.unknown_algorithm;
        r.timestamp = sg.has_timestamp;
        r.signer = wide(sg.label, strnlen(sg.label, sizeof sg.label));
        r.date = sg.time ? date_time(sg.time) : L"";
        switch (sg.algorithm) {
        case 1: r.algorithm = T(S::AlgEd25519); r.fingerprint = L"ed25519:" + hex(sg.public_key, 16); break;
        case 2: r.algorithm = T(S::AlgP256); r.fingerprint = L"sha256:" + hex(sg.certificate_sha256, 32); break;
        case 3: r.algorithm = T(S::AlgRsa); r.fingerprint = L"sha256:" + hex(sg.certificate_sha256, 32); break;
        case 4: r.algorithm = T(S::AlgHybrid); r.fingerprint = L"xizsigpq1:" + hex(sg.key_sha256, 16); break;
        case 5: r.algorithm = T(S::AlgEnclave); r.fingerprint = L"xizsigse1:" + hex(sg.key_sha256, 16); break;
        default: r.algorithm = vfmt(L"#%d", sg.algorithm);
        }
        rows.push_back(r);
    }
    return rows;
}

std::wstring properties_text(const Archive &ar) {
    const xiz_info &i = ar.info;
    std::vector<std::wstring> l;
    l.push_back(ar.path);
    l.push_back(L"");
    l.push_back(fmt(S::PropFormat, (unsigned)i.version_major, (unsigned)i.version_minor));
    l.push_back(fmt(S::PropId, hex(i.archive_id, 16).c_str()));
    l.push_back(fmt(S::PropEncrypted, T(i.encrypted ? S::Yes : S::No)));
    auto sigs = signatures(ar.a);
    unsigned signed_n = 0;
    for (auto &r : sigs) signed_n += r.is_signed;
    l.push_back(fmt(S::PropSegments, i.segments, signed_n));
    l.push_back(fmt(S::PropEntries, i.entry_count, (unsigned long long)i.visible_entries));
    l.push_back(fmt(S::PropBytes, byte_size(ar.bytes).c_str()));
    WIN32_FILE_ATTRIBUTE_DATA fa;
    if (GetFileAttributesExW(ar.path.c_str(), GetFileExInfoStandard, &fa))
        l.push_back(fmt(S::PropFile, byte_size((uint64_t)fa.nFileSizeHigh << 32 | fa.nFileSizeLow).c_str()));
    xiz_recovery_info ri;
    xiz_error e;
    if (xiz_recovery_info_file(utf8(ar.path).c_str(), &ri, &e) == XIZ_OK) l.push_back(fmt(S::PropRecovery, ri.recovery_slices, ri.slice_size / 1024));
    else l.push_back(T(S::PropNoRecovery));
    l.push_back(fmt(S::PropWindows, (i.required_features & XIZ_FEATURE_APPLE) ? T(S::PropAppleNo) : T(S::Yes)));
    if (i.has_directory && xiz_group_count(ar.a) > 0) {
        l.push_back(L"");
        l.push_back(T(S::PropGroups));
        for (size_t g = 0; g < xiz_group_count(ar.a); g++) {
            xiz_group gr;
            if (xiz_get_group(ar.a, g, &gr) != XIZ_OK) continue;
            std::wstring line = vfmt(L"  %u  ", (unsigned)gr.id) + (gr.held ? group_name(ar.a, gr.id) : std::wstring(L"(") + T(S::PropLocked) + L")");
            for (size_t p = 0; p < gr.prefix_count; p++) {
                const char *px = xiz_group_prefix(ar.a, g, p);
                line += (p ? L", " : L": ") + wide(px, strlen(px));
            }
            l.push_back(line);
        }
    }
    auto acc = access_lines(ar.a);
    if (!acc.empty()) {
        l.push_back(L"");
        l.push_back(T(S::PropAccess));
        for (auto &x : acc) l.push_back(L"  " + x);
    }
    if (signed_n) {
        l.push_back(L"");
        l.push_back(std::wstring(T(S::SigTitle)) + L":");
        for (auto &r : sigs) {
            if (!r.is_signed) { l.push_back(vfmt(L"  #%u  ", r.segment) + T(S::SigUnsigned)); continue; }
            const wchar_t *state = r.unknown ? T(S::SigUnknown) : !r.valid ? T(S::SigInvalid) : !r.chained ? T(S::SigBroken) : T(S::SigValid);
            l.push_back(vfmt(L"  #%u  ", r.segment) + r.signer + L"  " + r.date + L"  " + r.algorithm + L"  " + state +
                        (r.timestamp ? T(S::SigTimestamp) : L"") + L"  " + r.fingerprint);
        }
    }
    std::wstring s;
    for (auto &x : l) s += x + L"\r\n";
    return s;
}

// The superblock's required features (§3), read directly: the archive may not open.
static uint16_t required_features(const std::wstring &path) {
    HANDLE h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
    if (h == INVALID_HANDLE_VALUE) return 0;
    uint8_t sb[16] = {0};
    DWORD n = 0;
    ReadFile(h, sb, sizeof sb, &n, nullptr);
    CloseHandle(h);
    return n == sizeof sb ? (uint16_t)(sb[12] | sb[13] << 8) : 0;
}

std::wstring open_error(const std::wstring &path, int rc, const xiz_error &err) {
    std::wstring head = fmt(S::OpenFail, file_name(path).c_str()) + L"\n\n";
    switch (rc) {
    case XIZ_E_NOT_XIZ: return head + T(S::NotXiz);
    case XIZ_E_UNSUPPORTED:
        if (required_features(path) & XIZ_FEATURE_APPLE) return head + T(S::AppleCodec);
        return head + T(S::Newer) + L"\n(" + wide(err.message, strlen(err.message)) + L")";
    case XIZ_E_CORRUPT:
    case XIZ_E_CHECKSUM:
    case XIZ_E_AUTH: return head + T(S::Damaged) + L"\n(" + wide(err.message, strlen(err.message)) + L")";
    default: return head + wide(err.message, strlen(err.message));
    }
}

// ---------------------------------------------------------------- jobs

static int on_bytes(void *ctx, uint64_t done, uint64_t total) {
    Job &j = *static_cast<Job *>(ctx);
    if (j.notify) {
        int pm = total ? (int)(done * 1000 / total) : 1000;
        ULONGLONG now = GetTickCount64();
        if (pm != j.last_permille && (now - j.last_post >= 50 || pm == 1000)) {
            j.last_permille = pm;
            j.last_post = now;
            PostMessageW(j.notify, WM_JOB_PROGRESS, (WPARAM)pm, 0);
        }
    }
    return j.cancel.load() ? 1 : 0;
}

static int on_conflict(void *ctx, const char *path, const char *disk) {
    (void)path;
    Job &j = *static_cast<Job *>(ctx);
    if (j.sticky >= 0) return j.sticky;
    if (!j.notify) return j.quiet_conflict;
    Conflict c;
    c.disk_path = wide(disk, strlen(disk));
    std::replace(c.disk_path.begin(), c.disk_path.end(), L'/', L'\\');
    int answer = (int)SendMessageW(j.notify, WM_JOB_CONFLICT, 0, (LPARAM)&c);
    if (c.all && answer != XIZ_CONFLICT_CANCEL) j.sticky = answer;
    return answer;
}

// The archive's Mark of the Web goes on every file written, as Explorer does for ZIP files: a
// program downloaded inside an archive keeps SmartScreen's warning.
static void on_written(void *ctx, const char *path, const char *disk) {
    (void)path;
    Job &j = *static_cast<Job *>(ctx);
    if (j.zone.empty()) return;
    std::wstring rel = wide(disk, strlen(disk));
    std::replace(rel.begin(), rel.end(), L'/', L'\\');
    std::wstring full = j.dest + L"\\" + rel;
    if (full.rfind(L"\\\\", 0) != 0) full = L"\\\\?\\" + full;
    DWORD at = GetFileAttributesW(full.c_str());
    if (at == INVALID_FILE_ATTRIBUTES || (at & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT))) return;
    bool ro = at & FILE_ATTRIBUTE_READONLY;
    if (ro) SetFileAttributesW(full.c_str(), at & ~FILE_ATTRIBUTE_READONLY);
    HANDLE h = CreateFileW((full + L":Zone.Identifier").c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr);
    if (h != INVALID_HANDLE_VALUE) {
        DWORD w = 0;
        WriteFile(h, j.zone.data(), (DWORD)j.zone.size(), &w, nullptr);
        CloseHandle(h);
    }
    if (ro) SetFileAttributesW(full.c_str(), at);
}

static void on_skipped(void *ctx, const char *path, int code, const char *reason) {
    (void)code;
    Job &j = *static_cast<Job *>(ctx);
    std::lock_guard<std::mutex> l(j.mu);
    if (j.problems.size() < 1000)
        j.problems.push_back(wide(path, strlen(path)) + L": " + wide(reason, strlen(reason)));
}

static void on_problem(void *ctx, long frame, long entry, int code, const char *message) {
    (void)code;
    Job &j = *static_cast<Job *>(ctx);
    std::wstring what;
    if (entry >= 0) {
        xiz_entry e;
        if (xiz_get_entry(j.a, (size_t)entry, &e) == XIZ_OK) what = wide(e.path, e.path_len);
    } else {
        what = L"#" + std::to_wstring(frame);
    }
    std::lock_guard<std::mutex> l(j.mu);
    if (j.problems.size() < 1000) j.problems.push_back(what + L": " + wide(message, strlen(message)));
}

static void check_record(Job &j) {
    xiz_recovery_info ri;
    xiz_error e;
    if (xiz_recovery_info_file(utf8(j.path).c_str(), &ri, &e) != XIZ_OK) return;
    j.has_record = xiz_recovery_scrub(utf8(j.path).c_str(), 0, &j.rrep, &e) == XIZ_OK;
}

// A copy next to the original ("name (repaired).xiz"), repaired in place with its recovery record.
static void repair(Job &j) {
    std::wstring base = parent_dir(j.path) + L"\\" + stem(j.path) + T(S::RepairedSuffix);
    std::wstring dst = base + L".xiz";
    for (int k = 2; GetFileAttributesW(dst.c_str()) != INVALID_FILE_ATTRIBUTES; k++) dst = base + vfmt(L" %d.xiz", k);
    if (!CopyFileW(j.path.c_str(), dst.c_str(), TRUE)) {
        j.rc = XIZ_E_IO;
        snprintf(j.err.message, sizeof j.err.message, "cannot copy the archive (error %lu)", GetLastError());
        return;
    }
    j.rc = xiz_recovery_scrub(utf8(dst).c_str(), 1, &j.rrep, &j.err);
    j.has_record = j.rrep.has_record;
    bool ok = j.rc == XIZ_OK && j.rrep.has_record && (j.rrep.repaired || (!j.rrep.damaged_data_slices && !j.rrep.damaged_recovery_slices));
    if (!ok) {
        DeleteFileW(dst.c_str());
        if (j.rc == XIZ_OK) {
            j.rc = XIZ_E_CORRUPT;
            snprintf(j.err.message, sizeof j.err.message, "%s", j.rrep.has_record ? "too much damage for the recovery record" : "no recovery record");
        }
        return;
    }
    j.repaired = dst;
}

void run_job(Job &j) {
    if (j.kind == Job::Repair) {
        repair(j);
        return;
    }
    if (j.kind == Job::Test) {
        if (j.a) j.rc = xiz_test_progress(j.a, 0, on_problem, on_bytes, &j, &j.trep, &j.err);
        if (!j.cancel && !j.path.empty()) check_record(j);
        return;
    }
    wchar_t full[32768];
    DWORD fl = GetFullPathNameW(j.dest.c_str(), 32768, full, nullptr);
    if (fl > 0 && fl < 32768) j.dest.assign(full, fl);
    while (j.dest.size() > 3 && (j.dest.back() == L'\\' || j.dest.back() == L'/')) j.dest.pop_back();
    SHCreateDirectoryExW(nullptr, j.dest.c_str(), nullptr);  // libxiz creates only the last folder
    std::vector<const char *> sel;
    for (auto &s : j.select) sel.push_back(s.c_str());
    xiz_extract_options o{};
    o.select = sel.empty() ? nullptr : sel.data();
    o.select_count = sel.size();
    o.skipped = on_skipped;
    o.bytes = on_bytes;
    o.written = on_written;
    o.conflict = on_conflict;
    o.ctx = &j;
    j.rc = xiz_extract(j.a, utf8(j.dest).c_str(), &o, &j.rep, &j.err);
}

void start_job(Job &j) {
    std::thread([&j] {
        run_job(j);
        PostMessageW(j.notify, WM_JOB_DONE, 0, (LPARAM)&j);
    }).detach();
}

// ---------------------------------------------------------------- association (per user, no admin)

static const wchar_t kProgId[] = L"XipperXIZ.Archive";

static bool set_value(const std::wstring &key, const wchar_t *name, const std::wstring &value) {
    return RegSetKeyValueW(HKEY_CURRENT_USER, key.c_str(), name, REG_SZ, value.c_str(),
                           (DWORD)((value.size() + 1) * sizeof(wchar_t))) == ERROR_SUCCESS;
}

bool register_association() {
    std::wstring exe = exe_path(), q = L"\"" + exe + L"\"";
    std::wstring cls = std::wstring(L"Software\\Classes\\") + kProgId;
    bool ok = set_value(cls, nullptr, T(S::FileType)) &&
              set_value(cls + L"\\DefaultIcon", nullptr, exe + L",-2") &&
              set_value(cls + L"\\shell", nullptr, L"open") &&
              set_value(cls + L"\\shell\\open\\command", nullptr, q + L" \"%1\"") &&
              set_value(cls + L"\\shell\\extracthere", L"MUIVerb", T(S::VerbExtractHere)) &&
              set_value(cls + L"\\shell\\extracthere\\command", nullptr, q + L" /x \"%1\"") &&
              set_value(cls + L"\\shell\\extractto", L"MUIVerb", T(S::VerbExtractTo)) &&
              set_value(cls + L"\\shell\\extractto\\command", nullptr, q + L" /xto \"%1\"") &&
              set_value(L"Software\\Classes\\.xiz", nullptr, kProgId) &&
              set_value(L"Software\\Classes\\.xiz", L"Content Type", L"application/x-xiz") &&
              RegSetKeyValueW(HKEY_CURRENT_USER, L"Software\\Classes\\.xiz\\OpenWithProgids", kProgId, REG_NONE, nullptr, 0) == ERROR_SUCCESS;
    SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nullptr, nullptr);
    return ok;
}

bool unregister_association() {
    RegDeleteTreeW(HKEY_CURRENT_USER, (std::wstring(L"Software\\Classes\\") + kProgId).c_str());
    HKEY k;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\Classes\\.xiz", 0, KEY_READ | KEY_WRITE, &k) == ERROR_SUCCESS) {
        wchar_t v[128] = {0};
        DWORD n = sizeof v - sizeof(wchar_t), type = 0;
        if (RegQueryValueExW(k, nullptr, nullptr, &type, (BYTE *)v, &n) == ERROR_SUCCESS && wcscmp(v, kProgId) == 0)
            RegDeleteValueW(k, nullptr);
        RegCloseKey(k);
        RegDeleteKeyValueW(HKEY_CURRENT_USER, L"Software\\Classes\\.xiz\\OpenWithProgids", kProgId);
    }
    SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nullptr, nullptr);
    return true;
}
