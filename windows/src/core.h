#pragma once
// Everything that is not a window: UTF-8/UTF-16, credentials, opening an archive, the extraction
// and verification jobs (run on a worker thread), the Mark of the Web, the .xiz association.

#include <windows.h>

#include <array>
#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

#include "xiz.h"

std::string utf8(const std::wstring &w);
std::wstring wide(const char *s, size_t n);
inline std::wstring wide(const std::string &s) { return wide(s.data(), s.size()); }
// A password as typed, normalized to NFC (XIZ 1.14, §24.2) and encoded in UTF-8.
std::string password_utf8(const std::wstring &typed);
std::wstring file_name(const std::wstring &path);
std::wstring parent_dir(const std::wstring &path);
std::wstring stem(const std::wstring &path);
std::wstring exe_path();
// "12,3 MB" in the user's locale.
std::wstring byte_size(uint64_t n);

struct Credentials {
    std::string password;                        // NFC, UTF-8; empty: none
    std::vector<std::array<uint8_t, 32>> factors;
    void wipe();
    ~Credentials() { wipe(); }
};

// Reads a key file; returns its kind (XIZ_SECRET_*) or a negative xiz status.
int read_secret(const std::wstring &path, std::array<uint8_t, 32> &out);

struct Entry {
    std::wstring path;   // '\'-separated for display
    std::string stored;  // as stored, for selections
    uint64_t size;
    int64_t mtime;
    int type;
};

struct Archive {
    std::wstring path;
    xiz_archive *a = nullptr;
    xiz_info info{};
    std::vector<Entry> entries;  // sorted by path
    uint64_t bytes = 0;
    std::string zone;            // the archive's Zone.Identifier stream (Mark of the Web), if any
    ~Archive() { if (a) xiz_close(a); }
};

// Opens with the given credentials; on success fills `out` (entries, info, zone).
int open_archive(const std::wstring &path, const Credentials &c, Archive &out, xiz_error *err);
// A message for a failed open, in the user's language (Apple codecs, newer version, damage…).
std::wstring open_error(const std::wstring &path, int rc, const xiz_error &err);

// ---- jobs

constexpr UINT WM_JOB_PROGRESS = WM_APP + 1;  // wParam: per mille
constexpr UINT WM_JOB_DONE = WM_APP + 2;      // lParam: Job*
constexpr UINT WM_JOB_CONFLICT = WM_APP + 3;  // lParam: Conflict*, returns XIZ_CONFLICT_*

struct Conflict {
    std::wstring disk_path;
    bool all = false;  // apply the answer to the next conflicts
};

struct Job {
    enum Kind { Extract, Test } kind = Extract;
    HWND notify = nullptr;          // receives WM_JOB_*; nullptr: run quietly
    xiz_archive *a = nullptr;
    std::wstring dest;              // extraction folder
    std::vector<std::string> select;
    std::string zone;
    int quiet_conflict = XIZ_CONFLICT_SKIP;  // the answer when nobody can be asked
    std::atomic<bool> cancel{false};
    // results
    int rc = XIZ_OK;
    xiz_error err{};
    xiz_extract_report rep{};
    xiz_test_report trep{};
    std::vector<std::wstring> problems;
    // private
    int sticky = -1;
    int last_permille = -1;
    ULONGLONG last_post = 0;
    std::mutex mu;
};

// Runs synchronously (the caller decides the thread).
void run_job(Job &j);
// Starts on a new thread; WM_JOB_DONE arrives at j.notify when it ends.
void start_job(Job &j);

// ---- shell

bool register_association();
bool unregister_association();
