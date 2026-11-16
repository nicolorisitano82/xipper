// Xipper XIZ for Windows: opens, lists, extracts and verifies XIZ archives (docs/STUDIO_WINDOWS_XIZ.md).
// Win32 with Common Controls 6, per-monitor DPI, libxiz linked statically.

#include <windows.h>
#include <commctrl.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <uxtheme.h>

#include <cstdio>
#include <algorithm>
#include <map>
#include <memory>

#include "core.h"
#include "resource.h"
#include "strings.h"

#ifndef XIZW_VERSION
#define XIZW_VERSION "0.0.0"
#endif

namespace {

enum : int {
    ID_OPEN = 1001, ID_EXTRACT, ID_EXTRACT_SEL, ID_VERIFY, ID_ASSOC, ID_UNASSOC, ID_EXIT, ID_ABOUT, ID_CANCEL,
    ID_UNLOCK, ID_SIGS, ID_PROPS, ID_PROOF,
    ID_LIST = 1100
};

enum Exit : int { EXIT_OK = 0, EXIT_ERROR = 1, EXIT_USAGE = 2, EXIT_PASSWORD = 3, EXIT_SKIPPED = 4, EXIT_CANCELLED = 5 };

HINSTANCE g_inst;
const wchar_t kMainClass[] = L"XipperXIZ.Main";
const wchar_t kProgressClass[] = L"XipperXIZ.Progress";

// ---------------------------------------------------------------- small helpers

UINT dpi_of(HWND w) { return w ? GetDpiForWindow(w) : GetDpiForSystem(); }
int scale(int v, UINT dpi) { return MulDiv(v, (int)dpi, 96); }

HFONT make_font(UINT dpi) {
    NONCLIENTMETRICSW m{};
    m.cbSize = sizeof m;
    SystemParametersInfoForDpi(SPI_GETNONCLIENTMETRICS, sizeof m, &m, 0, dpi);
    return CreateFontIndirectW(&m.lfMessageFont);
}

void set_font_all(HWND parent, HFONT f) {
    SendMessageW(parent, WM_SETFONT, (WPARAM)f, TRUE);
    EnumChildWindows(parent, [](HWND c, LPARAM l) -> BOOL { SendMessageW(c, WM_SETFONT, (WPARAM)l, TRUE); return TRUE; }, (LPARAM)f);
}

std::wstring window_text(HWND w) {
    int n = GetWindowTextLengthW(w);
    std::wstring s((size_t)n + 1, L'\0');
    GetWindowTextW(w, s.data(), n + 1);
    s.resize((size_t)n);
    return s;
}

void wipe(std::wstring &s) {
    SecureZeroMemory(s.data(), s.size() * sizeof(wchar_t));
    s.clear();
}

int task_dialog(HWND owner, PCWSTR icon, const std::wstring &title, const std::wstring &text, const std::wstring &details = {},
                const TASKDIALOG_BUTTON *buttons = nullptr, UINT nbuttons = 0, TASKDIALOG_COMMON_BUTTON_FLAGS common = TDCBF_CLOSE_BUTTON,
                const wchar_t *verification = nullptr, BOOL *verified = nullptr) {
    TASKDIALOGCONFIG c{};
    c.cbSize = sizeof c;
    c.hwndParent = owner;
    c.hInstance = g_inst;
    c.dwFlags = TDF_ALLOW_DIALOG_CANCELLATION | TDF_POSITION_RELATIVE_TO_WINDOW | TDF_SIZE_TO_CONTENT;
    c.pszWindowTitle = T(S::AppName);
    c.pszMainIcon = icon;
    c.pszMainInstruction = title.c_str();
    c.pszContent = text.empty() ? nullptr : text.c_str();
    c.pszExpandedInformation = details.empty() ? nullptr : details.c_str();
    c.pszExpandedControlText = details.empty() ? nullptr : T(S::ShowDetails);
    c.pButtons = buttons;
    c.cButtons = nbuttons;
    c.dwCommonButtons = common;
    c.pszVerificationText = verification;
    int pressed = IDCANCEL;
    if (FAILED(TaskDialogIndirect(&c, &pressed, nullptr, verified))) {
        std::wstring all = title + (text.empty() ? L"" : L"\n\n" + text);
        MessageBoxW(owner, all.c_str(), T(S::AppName), MB_OK | (icon == TD_ERROR_ICON ? MB_ICONERROR : MB_ICONINFORMATION));
        return IDOK;
    }
    return pressed;
}

bool pick_folder(HWND owner, std::wstring &inout) {
    IFileOpenDialog *d = nullptr;
    if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&d)))) return false;
    DWORD opts = 0;
    d->GetOptions(&opts);
    d->SetOptions(opts | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM);
    IShellItem *start = nullptr;
    std::wstring dir = inout;
    while (!dir.empty() && GetFileAttributesW(dir.c_str()) == INVALID_FILE_ATTRIBUTES) dir = parent_dir(dir) == dir ? L"" : parent_dir(dir);
    if (!dir.empty() && SUCCEEDED(SHCreateItemFromParsingName(dir.c_str(), nullptr, IID_PPV_ARGS(&start)))) {
        d->SetFolder(start);
        start->Release();
    }
    bool ok = false;
    IShellItem *r = nullptr;
    if (SUCCEEDED(d->Show(owner)) && SUCCEEDED(d->GetResult(&r))) {
        PWSTR p = nullptr;
        if (SUCCEEDED(r->GetDisplayName(SIGDN_FILESYSPATH, &p))) { inout = p; CoTaskMemFree(p); ok = true; }
        r->Release();
    }
    d->Release();
    return ok;
}

bool pick_file(HWND owner, const COMDLG_FILTERSPEC *filters, UINT n, std::wstring &out) {
    IFileOpenDialog *d = nullptr;
    if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&d)))) return false;
    d->SetFileTypes(n, filters);
    DWORD opts = 0;
    d->GetOptions(&opts);
    d->SetOptions(opts | FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST);
    bool ok = false;
    IShellItem *r = nullptr;
    if (SUCCEEDED(d->Show(owner)) && SUCCEEDED(d->GetResult(&r))) {
        PWSTR p = nullptr;
        if (SUCCEEDED(r->GetDisplayName(SIGDN_FILESYSPATH, &p))) { out = p; CoTaskMemFree(p); ok = true; }
        r->Release();
    }
    d->Release();
    return ok;
}

// ---------------------------------------------------------------- password dialog

struct PwState {
    std::wstring archive, error;
    bool need_factor = false;
    std::wstring password;
    std::vector<std::array<uint8_t, 32>> factors;
};

INT_PTR CALLBACK pw_proc(HWND d, UINT msg, WPARAM wp, LPARAM lp) {
    auto *st = reinterpret_cast<PwState *>(GetWindowLongPtrW(d, DWLP_USER));
    switch (msg) {
    case WM_INITDIALOG: {
        st = reinterpret_cast<PwState *>(lp);
        SetWindowLongPtrW(d, DWLP_USER, lp);
        SetWindowTextW(d, T(S::PwTitle));
        SetDlgItemTextW(d, IDC_PW_LABEL, fmt(S::PwLabel, st->archive.c_str()).c_str());
        SetDlgItemTextW(d, IDC_PW_SHOW, T(S::PwShow));
        SetDlgItemTextW(d, IDC_FACTOR_LABEL, T(S::FactorLabel));
        SetDlgItemTextW(d, IDC_FACTOR_BROWSE, T(S::Browse));
        SetDlgItemTextW(d, IDCANCEL, T(S::Cancel));
        SetDlgItemTextW(d, IDC_PW_ERROR, st->error.c_str());
        SetDlgItemTextW(d, IDC_PW_EDIT, st->password.c_str());
        wipe(st->password);
        for (int id : {IDC_FACTOR_LABEL, IDC_FACTOR_EDIT, IDC_FACTOR_BROWSE})
            ShowWindow(GetDlgItem(d, id), st->need_factor ? SW_SHOW : SW_HIDE);
        HWND focus = GetDlgItem(d, st->need_factor && !st->error.empty() && GetWindowTextLengthW(GetDlgItem(d, IDC_PW_EDIT))
                                       ? IDC_FACTOR_EDIT : IDC_PW_EDIT);
        SendMessageW(GetDlgItem(d, IDC_PW_EDIT), EM_SETSEL, 0, -1);
        SetFocus(focus);
        return FALSE;
    }
    case WM_CTLCOLORSTATIC:
        if ((HWND)lp == GetDlgItem(d, IDC_PW_ERROR)) {
            SetTextColor((HDC)wp, RGB(196, 43, 28));
            SetBkMode((HDC)wp, TRANSPARENT);
            return (INT_PTR)GetSysColorBrush(COLOR_BTNFACE);
        }
        break;
    case WM_COMMAND:
        switch (LOWORD(wp)) {
        case IDC_PW_SHOW: {
            bool show = IsDlgButtonChecked(d, IDC_PW_SHOW) == BST_CHECKED;
            HWND e = GetDlgItem(d, IDC_PW_EDIT);
            SendMessageW(e, EM_SETPASSWORDCHAR, show ? 0 : (WPARAM)L'\x25CF', 0);
            InvalidateRect(e, nullptr, TRUE);
            return TRUE;
        }
        case IDC_FACTOR_BROWSE: {
            COMDLG_FILTERSPEC f[] = {{T(S::FactorFilter), L"*.xizfactor"}, {T(S::AllFiles), L"*.*"}};
            std::wstring p;
            if (pick_file(d, f, 2, p)) SetDlgItemTextW(d, IDC_FACTOR_EDIT, p.c_str());
            return TRUE;
        }
        case IDOK: {
            st->factors.clear();
            if (st->need_factor) {
                std::wstring fp = window_text(GetDlgItem(d, IDC_FACTOR_EDIT));
                if (!fp.empty()) {
                    std::array<uint8_t, 32> f{};
                    if (read_secret(fp, f) != XIZ_SECRET_FACTOR) {
                        SetDlgItemTextW(d, IDC_PW_ERROR, T(S::FactorInvalid));
                        SetFocus(GetDlgItem(d, IDC_FACTOR_EDIT));
                        return TRUE;
                    }
                    st->factors.push_back(f);
                    SecureZeroMemory(f.data(), f.size());
                }
            }
            st->password = window_text(GetDlgItem(d, IDC_PW_EDIT));
            SetDlgItemTextW(d, IDC_PW_EDIT, L"");
            EndDialog(d, IDOK);
            return TRUE;
        }
        case IDCANCEL:
            SetDlgItemTextW(d, IDC_PW_EDIT, L"");
            EndDialog(d, IDCANCEL);
            return TRUE;
        }
        break;
    }
    return FALSE;
}

// ---------------------------------------------------------------- credentials dialog (keys, custodians)

struct CredState {
    std::wstring archive, error;
    std::vector<std::wstring> access;
    Credentials creds;  // what was given so far; edited here
};

void cred_refresh(HWND d, CredState *st) {
    HWND l = GetDlgItem(d, IDC_CR_LIST);
    SendMessageW(l, LB_RESETCONTENT, 0, 0);
    for (auto &g : st->creds.given) SendMessageW(l, LB_ADDSTRING, 0, (LPARAM)g.c_str());
    EnableWindow(GetDlgItem(d, IDC_CR_REMOVE), !st->creds.given.empty());
}

// Removes the i-th given credential.
void cred_remove(Credentials &c, size_t i) {
    if (i >= c.given.size() || i >= c.kinds.size()) return;
    int kind = c.kinds[i];
    size_t nth = 0;
    for (size_t k = 0; k < i; k++) nth += c.kinds[k] == kind;
    auto drop = [](std::vector<Secret> &v, size_t n) { if (n < v.size()) { SecureZeroMemory(v[n].data(), 32); v.erase(v.begin() + (long)n); } };
    if (kind == XIZ_SECRET_X25519) drop(c.identities, nth);
    else if (kind == XIZ_SECRET_XWING) drop(c.pq_identities, nth);
    else if (kind == XIZ_SECRET_FACTOR) drop(c.factors, nth);
    else if (nth < c.passwords.size()) { SecureZeroMemory(c.passwords[nth].data(), c.passwords[nth].size()); c.passwords.erase(c.passwords.begin() + (long)nth); }
    c.given.erase(c.given.begin() + (long)i);
    c.kinds.erase(c.kinds.begin() + (long)i);
}

void cred_add_typed(HWND d, CredState *st) {
    HWND e = GetDlgItem(d, IDC_CR_PW);
    std::wstring pw = window_text(e);
    if (pw.empty()) return;
    st->creds.add_password(pw);
    wipe(pw);
    SetWindowTextW(e, L"");
    cred_refresh(d, st);
}

INT_PTR CALLBACK cred_proc(HWND d, UINT msg, WPARAM wp, LPARAM lp) {
    auto *st = reinterpret_cast<CredState *>(GetWindowLongPtrW(d, DWLP_USER));
    switch (msg) {
    case WM_INITDIALOG: {
        st = reinterpret_cast<CredState *>(lp);
        SetWindowLongPtrW(d, DWLP_USER, lp);
        SetWindowTextW(d, T(S::CrTitle));
        SetDlgItemTextW(d, IDC_CR_HEADER, fmt(S::CrHeader, st->archive.c_str()).c_str());
        std::wstring acc;
        for (auto &a : st->access) acc += a + L"\r\n";
        SetDlgItemTextW(d, IDC_CR_ACCESS, acc.c_str());
        SetDlgItemTextW(d, IDC_CR_PWLABEL, T(S::CrPassword));
        SetDlgItemTextW(d, IDC_CR_ADDPW, T(S::CrAddPw));
        SetDlgItemTextW(d, IDC_CR_ADDKEY, T(S::CrAddKey));
        SetDlgItemTextW(d, IDC_CR_GIVEN, T(S::CrGiven));
        SetDlgItemTextW(d, IDC_CR_REMOVE, T(S::CrRemove));
        SetDlgItemTextW(d, IDC_CR_ERROR, st->error.c_str());
        SetDlgItemTextW(d, IDOK, T(S::CrOpen));
        SetDlgItemTextW(d, IDCANCEL, T(S::Cancel));
        cred_refresh(d, st);
        SetFocus(GetDlgItem(d, IDC_CR_PW));
        return FALSE;
    }
    case WM_CTLCOLORSTATIC:
        if ((HWND)lp == GetDlgItem(d, IDC_CR_ERROR)) {
            SetTextColor((HDC)wp, RGB(196, 43, 28));
            SetBkMode((HDC)wp, TRANSPARENT);
            return (INT_PTR)GetSysColorBrush(COLOR_BTNFACE);
        }
        break;
    case WM_COMMAND:
        switch (LOWORD(wp)) {
        case IDC_CR_ADDPW: cred_add_typed(d, st); SetFocus(GetDlgItem(d, IDC_CR_PW)); return TRUE;
        case IDC_CR_ADDKEY: {
            COMDLG_FILTERSPEC f[] = {{T(S::KeyFilter), L"*.key;*.xizfactor;*.txt"}, {T(S::AllFiles), L"*.*"}};
            std::wstring p;
            if (pick_file(d, f, 2, p)) {
                if (st->creds.add_key_file(p) <= 0) SetDlgItemTextW(d, IDC_CR_ERROR, T(S::CrKeyInvalid));
                else SetDlgItemTextW(d, IDC_CR_ERROR, L"");
                cred_refresh(d, st);
            }
            return TRUE;
        }
        case IDC_CR_REMOVE: {
            LRESULT i = SendMessageW(GetDlgItem(d, IDC_CR_LIST), LB_GETCURSEL, 0, 0);
            if (i == LB_ERR && !st->creds.given.empty()) i = (LRESULT)st->creds.given.size() - 1;
            if (i != LB_ERR) cred_remove(st->creds, (size_t)i);
            cred_refresh(d, st);
            return TRUE;
        }
        case IDOK:
            cred_add_typed(d, st);
            EndDialog(d, IDOK);
            return TRUE;
        case IDCANCEL:
            SetDlgItemTextW(d, IDC_CR_PW, L"");
            EndDialog(d, IDCANCEL);
            return TRUE;
        }
        break;
    }
    return FALSE;
}

// Opens `path`, asking for credentials while needed: the simple password dialog, or the
// credentials dialog when the archive takes keys or custodians (XIZ 1.3). `c` keeps what opened it.
// Returns the last xiz status; XIZ_E_PASSWORD_REQUIRED also when the user gave up.
int open_interactive(HWND owner, const std::wstring &path, Credentials &c, Archive &out, bool interactive, xiz_error &err,
                     bool always_ask = false) {
    bool asked = !c.empty();
    for (;;) {
        int rc = always_ask ? XIZ_E_PASSWORD_REQUIRED : open_archive(path, c, out, &err);
        bool forced = always_ask;
        always_ask = false;
        if (rc == XIZ_OK || !interactive) return rc;
        if (rc != XIZ_E_PASSWORD_REQUIRED && rc != XIZ_E_WRONG_PASSWORD && rc != XIZ_E_FACTOR_REQUIRED) return rc;
        Archive probe;
        xiz_error pe{};
        bool keys = open_archive(path, Credentials{}, probe, &pe, XIZ_OPEN_NO_KEYS) == XIZ_OK && needs_keys(probe.a);
        if (keys || forced) {
            CredState st;
            st.archive = file_name(path);
            st.access = probe.a ? access_lines(probe.a) : std::vector<std::wstring>{};
            st.creds = c;
            if (asked && !forced) st.error = std::wstring(T(S::CrNotEnough)) + L"\n(" + wide(err.message, strlen(err.message)) + L")";
            if (DialogBoxParamW(g_inst, MAKEINTRESOURCEW(IDD_CREDS), owner, cred_proc, (LPARAM)&st) != IDOK) return XIZ_E_PASSWORD_REQUIRED;
            c = st.creds;
            asked = true;
            continue;
        }
        PwState st;
        st.archive = file_name(path);
        st.need_factor = rc == XIZ_E_FACTOR_REQUIRED || !c.factors.empty();
        if (rc == XIZ_E_FACTOR_REQUIRED) st.error = T(c.factors.empty() ? S::FactorNeeded : S::FactorWrong);
        else if (rc == XIZ_E_WRONG_PASSWORD && asked) st.error = T(S::WrongPassword);
        if (rc == XIZ_E_FACTOR_REQUIRED && !c.passwords.empty()) st.password = wide(c.passwords[0]);  // keep what was typed
        if (DialogBoxParamW(g_inst, MAKEINTRESOURCEW(IDD_PASSWORD), owner, pw_proc, (LPARAM)&st) != IDOK) {
            wipe(st.password);
            return XIZ_E_PASSWORD_REQUIRED;
        }
        c.wipe();
        c.add_password(st.password);
        wipe(st.password);
        for (auto &f : st.factors) {
            c.factors.push_back(f);
            c.given.push_back(fmt(S::GivenFactor, L".xizfactor"));
            c.kinds.push_back(XIZ_SECRET_FACTOR);
            SecureZeroMemory(f.data(), f.size());
        }
        asked = true;
    }
}

// ---------------------------------------------------------------- extract dialog

struct ExState {
    std::wstring dest;
    bool open_after = true;
};

INT_PTR CALLBACK ex_proc(HWND d, UINT msg, WPARAM wp, LPARAM lp) {
    auto *st = reinterpret_cast<ExState *>(GetWindowLongPtrW(d, DWLP_USER));
    switch (msg) {
    case WM_INITDIALOG:
        st = reinterpret_cast<ExState *>(lp);
        SetWindowLongPtrW(d, DWLP_USER, lp);
        SetWindowTextW(d, T(S::ExTitle));
        SetDlgItemTextW(d, IDC_DEST_LABEL, T(S::ExLabel));
        SetDlgItemTextW(d, IDC_DEST_EDIT, st->dest.c_str());
        SetDlgItemTextW(d, IDC_DEST_BROWSE, T(S::Browse));
        SetDlgItemTextW(d, IDC_OPEN_AFTER, T(S::ExOpenAfter));
        SetDlgItemTextW(d, IDOK, T(S::ExButton));
        SetDlgItemTextW(d, IDCANCEL, T(S::Cancel));
        CheckDlgButton(d, IDC_OPEN_AFTER, st->open_after ? BST_CHECKED : BST_UNCHECKED);
        return TRUE;
    case WM_COMMAND:
        switch (LOWORD(wp)) {
        case IDC_DEST_BROWSE: {
            std::wstring p = window_text(GetDlgItem(d, IDC_DEST_EDIT));
            if (pick_folder(d, p)) SetDlgItemTextW(d, IDC_DEST_EDIT, p.c_str());
            return TRUE;
        }
        case IDOK:
            st->dest = window_text(GetDlgItem(d, IDC_DEST_EDIT));
            if (st->dest.empty()) { MessageBeep(MB_ICONWARNING); return TRUE; }
            st->open_after = IsDlgButtonChecked(d, IDC_OPEN_AFTER) == BST_CHECKED;
            EndDialog(d, IDOK);
            return TRUE;
        case IDCANCEL: EndDialog(d, IDCANCEL); return TRUE;
        }
        break;
    }
    return FALSE;
}

bool ask_destination(HWND owner, const std::wstring &archive, ExState &st) {
    st.dest = parent_dir(archive) + L"\\" + stem(archive);
    return DialogBoxParamW(g_inst, MAKEINTRESOURCEW(IDD_EXTRACT), owner, ex_proc, (LPARAM)&st) == IDOK;
}

// ---------------------------------------------------------------- job results

int conflict_dialog(HWND owner, Conflict &c) {
    TASKDIALOG_BUTTON b[] = {{100, T(S::ConflictReplace)}, {101, T(S::ConflictKeep)}, {102, T(S::ConflictSkip)}};
    BOOL all = FALSE;
    int r = task_dialog(owner, TD_WARNING_ICON, T(S::ConflictTitle), fmt(S::ConflictText, c.disk_path.c_str()), {}, b, 3,
                        TDCBF_CANCEL_BUTTON, T(S::ConflictAll), &all);
    c.all = all;
    switch (r) {
    case 100: return XIZ_CONFLICT_OVERWRITE;
    case 101: return XIZ_CONFLICT_RENAME;
    case 102: return XIZ_CONFLICT_SKIP;
    default: return XIZ_CONFLICT_CANCEL;
    }
}

std::wstring joined(const std::vector<std::wstring> &v) {
    std::wstring s;
    for (size_t i = 0; i < v.size() && i < 200; i++) s += v[i] + L"\n";
    if (v.size() > 200) s += L"…";
    return s;
}

int exit_code(const Job &j) {
    if (j.rc == XIZ_E_CALLBACK && j.cancel) return EXIT_CANCELLED;
    if (j.rc != XIZ_OK) return EXIT_ERROR;
    if (j.kind == Job::Test && j.has_record && (j.rrep.damaged_data_slices || j.rrep.damaged_recovery_slices)) return EXIT_SKIPPED;
    if (j.kind == Job::Extract && (j.rep.skipped || j.rep.failed)) return EXIT_SKIPPED;
    return EXIT_OK;
}

enum Next { NEXT_NONE, NEXT_REPAIR, NEXT_OPEN_COPY };

std::wstring record_line(const Job &j) {
    if (!j.has_record) return {};
    uint32_t dmg = j.rrep.damaged_data_slices + j.rrep.damaged_recovery_slices;
    if (!dmg && !j.rrep.damaged_metadata) return T(S::RecOk);
    return fmt(S::RecDamaged, dmg + j.rrep.damaged_metadata, T(j.rrep.repairable ? S::RecRepairable : S::RecNotRepairable));
}

// What the user sees when a job ends. Returns the exit code for the command-line modes; `next`
// gets what the user chose to do afterwards (repair a copy, open the repaired copy).
int show_result(HWND owner, Job &j, bool open_after, bool quiet, Next *next = nullptr) {
    int code = exit_code(j);
    if (next) *next = NEXT_NONE;
    if (quiet || code == EXIT_CANCELLED) return code;
    std::wstring msg = wide(j.err.message, strlen(j.err.message));
    if (j.kind == Job::Repair) {
        if (j.rc != XIZ_OK) {
            task_dialog(owner, TD_ERROR_ICON, T(S::RepairFail), msg);
            return code;
        }
        TASKDIALOG_BUTTON b[] = {{300, T(S::OpenCopy)}};
        if (task_dialog(owner, TD_INFORMATION_ICON, T(S::RepairedTitle), fmt(S::RepairedText, j.repaired.c_str()), {}, b, 1) == 300 && next)
            *next = NEXT_OPEN_COPY;
        return code;
    }
    if (j.kind == Job::Test) {
        std::wstring rec = record_line(j);
        bool damaged = j.rc != XIZ_OK || code == EXIT_SKIPPED;
        bool can_repair = j.has_record && j.rrep.repairable && (j.rrep.damaged_data_slices || j.rrep.damaged_recovery_slices || j.rrep.damaged_metadata);
        TASKDIALOG_BUTTON b[] = {{301, T(S::RepairCopy)}};
        int r = 0;
        if (!damaged)
            r = task_dialog(owner, TD_INFORMATION_ICON, T(S::VerifyOkTitle),
                            fmt(S::VerifyOkText, (unsigned long long)j.trep.files_checked, j.trep.frames_checked) + (rec.empty() ? L"" : L"\n" + rec));
        else if (j.rc == XIZ_E_CORRUPT || j.rc == XIZ_OK)
            r = task_dialog(owner, TD_ERROR_ICON, T(S::VerifyBadTitle),
                            fmt(S::VerifyBadText, j.trep.frames_failed, (unsigned long long)j.trep.files_failed) + (rec.empty() ? L"" : L"\n" + rec),
                            joined(j.problems), can_repair ? b : nullptr, can_repair ? 1 : 0);
        else
            r = task_dialog(owner, TD_ERROR_ICON, T(S::FailTitle), msg + (rec.empty() ? L"" : L"\n" + rec), joined(j.problems),
                            can_repair ? b : nullptr, can_repair ? 1 : 0);
        if (r == 301 && next) *next = NEXT_REPAIR;
        return code;
    }
    if (j.rc != XIZ_OK) {
        task_dialog(owner, TD_ERROR_ICON, T(S::FailTitle), msg, joined(j.problems));
        return code;
    }
    uint64_t issues = j.rep.skipped + j.rep.failed;
    if (!issues && !j.rep.renamed) {
        if (open_after) ShellExecuteW(owner, L"open", j.dest.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
        return code;
    }
    std::wstring text = fmt(S::DoneText, (unsigned long long)j.rep.files, (unsigned long long)j.rep.directories, j.dest.c_str());
    if (issues) text += L"\n" + fmt(S::DoneIssues, (unsigned long long)issues);
    if (j.rep.renamed) text += L"\n" + fmt(S::DoneRenamed, (unsigned long long)j.rep.renamed);
    TASKDIALOG_BUTTON b[] = {{200, T(S::OpenFolder)}};
    if (task_dialog(owner, issues ? TD_WARNING_ICON : TD_INFORMATION_ICON, T(S::DoneTitle), text, joined(j.problems), b, 1) == 200)
        ShellExecuteW(owner, L"open", j.dest.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    return code;
}

// ---------------------------------------------------------------- signatures, properties, proofs

INT_PTR CALLBACK sigs_proc(HWND d, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_INITDIALOG: {
        auto *ar = reinterpret_cast<Archive *>(lp);
        SetWindowTextW(d, (std::wstring(T(S::SigTitle)) + L" \x2014 " + file_name(ar->path)).c_str());
        SetDlgItemTextW(d, IDC_SIG_NOTE, T(S::SigNote));
        SetDlgItemTextW(d, IDCANCEL, T(S::Close));
        HWND l = GetDlgItem(d, IDC_SIG_LIST);
        SetWindowTheme(l, L"Explorer", nullptr);
        ListView_SetExtendedListViewStyle(l, LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER);
        UINT dpi = dpi_of(d);
        const S cols[] = {S::SigColSegment, S::SigColSigner, S::SigColDate, S::SigColKind, S::SigColState, S::SigColFingerprint};
        const int widths[] = {60, 150, 120, 200, 200, 260};
        LVCOLUMNW c{};
        c.mask = LVCF_TEXT | LVCF_WIDTH;
        for (int i = 0; i < 6; i++) {
            c.pszText = const_cast<wchar_t *>(T(cols[i]));
            c.cx = scale(widths[i], dpi);
            ListView_InsertColumn(l, i, &c);
        }
        auto rows = signatures(ar->a);
        bool any = false;
        for (auto &r : rows) {
            std::wstring seg = vfmt(L"#%u", r.segment);
            LVITEMW it{};
            it.mask = LVIF_TEXT;
            it.iItem = (int)r.segment;
            it.pszText = seg.data();
            int row = ListView_InsertItem(l, &it);
            if (!r.is_signed) { ListView_SetItemText(l, row, 4, const_cast<wchar_t *>(T(S::SigUnsigned))); continue; }
            any = true;
            std::wstring state = std::wstring(r.unknown ? T(S::SigUnknown) : !r.valid ? T(S::SigInvalid) : !r.chained ? T(S::SigBroken) : T(S::SigValid)) +
                                 (r.timestamp ? T(S::SigTimestamp) : L"");
            ListView_SetItemText(l, row, 1, r.signer.data());
            ListView_SetItemText(l, row, 2, r.date.data());
            ListView_SetItemText(l, row, 3, r.algorithm.data());
            ListView_SetItemText(l, row, 4, state.data());
            ListView_SetItemText(l, row, 5, r.fingerprint.data());
        }
        for (int i = 0; i < 6; i++) ListView_SetColumnWidth(l, i, LVSCW_AUTOSIZE_USEHEADER);
        if (!any) SetDlgItemTextW(d, IDC_SIG_NOTE, T(S::NoSignatures));
        return TRUE;
    }
    case WM_COMMAND:
        if (LOWORD(wp) == IDCANCEL || LOWORD(wp) == IDOK) { EndDialog(d, 0); return TRUE; }
        break;
    }
    return FALSE;
}

void show_signatures(HWND owner, Archive &ar) {
    DialogBoxParamW(g_inst, MAKEINTRESOURCEW(IDD_SIGS), owner, sigs_proc, (LPARAM)&ar);
}

INT_PTR CALLBACK props_proc(HWND d, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_INITDIALOG: {
        auto *ar = reinterpret_cast<Archive *>(lp);
        SetWindowTextW(d, (std::wstring(T(S::PropTitle)) + L" \x2014 " + file_name(ar->path)).c_str());
        SetDlgItemTextW(d, IDC_PROP_TEXT, properties_text(*ar).c_str());
        SetDlgItemTextW(d, IDCANCEL, T(S::Close));
        SetFocus(GetDlgItem(d, IDCANCEL));
        return FALSE;
    }
    case WM_COMMAND:
        if (LOWORD(wp) == IDCANCEL || LOWORD(wp) == IDOK) { EndDialog(d, 0); return TRUE; }
        break;
    }
    return FALSE;
}

void show_properties(HWND owner, Archive &ar) {
    DialogBoxParamW(g_inst, MAKEINTRESOURCEW(IDD_PROPS), owner, props_proc, (LPARAM)&ar);
}

bool read_all(const std::wstring &path, std::string &out, uint64_t limit) {
    HANDLE h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER sz;
    bool ok = GetFileSizeEx(h, &sz) && (uint64_t)sz.QuadPart <= limit;
    if (ok) {
        out.resize((size_t)sz.QuadPart);
        DWORD n = 0;
        size_t done = 0;
        while (ok && done < out.size()) {
            DWORD chunk = (DWORD)std::min<size_t>(out.size() - done, 1u << 30);
            ok = ReadFile(h, out.data() + done, chunk, &n, nullptr) && n > 0;
            done += n;
        }
    }
    CloseHandle(h);
    return ok;
}

// An xiz-proof-1 (§13.6) against a file: no archive and no key needed.
void check_proof(HWND owner) {
    COMDLG_FILTERSPEC fj[] = {{T(S::ProofFilter), L"*.json"}, {T(S::AllFiles), L"*.*"}};
    COMDLG_FILTERSPEC fa[] = {{T(S::AllFiles), L"*.*"}};
    std::wstring jp, fp;
    if (!pick_file(owner, fj, 2, jp) || !pick_file(owner, fa, 1, fp)) return;
    std::string json, content;
    if (!read_all(jp, json, 16u << 20) || !read_all(fp, content, 4ull << 30)) {
        task_dialog(owner, TD_ERROR_ICON, T(S::ProofBadTitle), fmt(S::OpenFail, file_name(read_all(jp, json, 16u << 20) ? fp : jp).c_str()));
        return;
    }
    xiz_proof_result r{};
    xiz_error e{};
    int rc = xiz_verify_proof(json.data(), json.size(), (const uint8_t *)content.data(), content.size(), &r, &e);
    if (rc != XIZ_OK || !r.content_matches || !r.in_tree) {
        task_dialog(owner, TD_ERROR_ICON, T(S::ProofBadTitle), wide(e.message, strlen(e.message)));
        return;
    }
    std::wstring text = fmt(S::ProofOkText, wide(r.path, strnlen(r.path, sizeof r.path)).c_str(), (unsigned long long)r.size, r.segment);
    if (r.is_signed) {
        const wchar_t *alg = r.algorithm == 4 ? T(S::AlgHybrid) : r.algorithm == 5 ? T(S::AlgEnclave) : r.algorithm == 2 ? T(S::AlgP256)
                             : r.algorithm == 3 ? T(S::AlgRsa) : T(S::AlgEd25519);
        text += L"\n" + fmt(S::ProofSigned, wide(r.signer, strnlen(r.signer, sizeof r.signer)).c_str(), date_time(r.signed_at).c_str(), alg);
    } else {
        text += L"\n" + std::wstring(T(S::ProofUnsigned));
    }
    task_dialog(owner, TD_INFORMATION_ICON, T(S::ProofOkTitle), text);
}

// ---------------------------------------------------------------- main window

struct Main {
    HWND wnd = nullptr, list = nullptr, empty = nullptr, status = nullptr, progress = nullptr, cancel = nullptr;
    HWND buttons[4] = {};
    HFONT font = nullptr;
    UINT dpi = 96;
    std::unique_ptr<Archive> ar;
    Credentials creds;  // what opened `ar`, for unlocking more groups
    std::unique_ptr<Job> job;
    bool open_after = true, close_when_done = false, group_col = false;
    std::wstring idle_status;
    ITaskbarList3 *taskbar = nullptr;
    std::map<std::wstring, int> icons;
    int folder_icon = -1;
} M;

void layout() {
    RECT rc;
    GetClientRect(M.wnd, &rc);
    int pad = scale(8, M.dpi), bh = scale(28, M.dpi), x = pad, w = rc.right, h = rc.bottom;
    HDC dc = GetDC(M.wnd);
    HGDIOBJ old = SelectObject(dc, M.font);
    for (HWND b : M.buttons) {
        std::wstring t = window_text(b);
        SIZE sz{};
        GetTextExtentPoint32W(dc, t.c_str(), (int)t.size(), &sz);
        int bw = sz.cx + scale(28, M.dpi);
        MoveWindow(b, x, pad, bw, bh, TRUE);
        x += bw + scale(6, M.dpi);
    }
    SelectObject(dc, old);
    ReleaseDC(M.wnd, dc);
    int top = pad + bh + pad, bottom_h = scale(30, M.dpi), list_h = h - top - bottom_h;
    MoveWindow(M.list, 0, top, w, list_h, TRUE);
    MoveWindow(M.empty, pad, top + list_h / 2 - scale(12, M.dpi), w - 2 * pad, scale(24, M.dpi), TRUE);
    int by = top + list_h + (bottom_h - scale(24, M.dpi)) / 2, cw = scale(90, M.dpi), pw = scale(220, M.dpi);
    MoveWindow(M.cancel, w - pad - cw, by, cw, scale(24, M.dpi), TRUE);
    MoveWindow(M.progress, w - pad - cw - scale(8, M.dpi) - pw, by + scale(4, M.dpi), pw, scale(16, M.dpi), TRUE);
    bool busy = M.job != nullptr;
    int sw = busy ? w - 3 * pad - cw - pw - scale(8, M.dpi) : w - 2 * pad;
    MoveWindow(M.status, pad, by + scale(4, M.dpi), sw, scale(20, M.dpi), TRUE);
}

void set_busy(bool busy, const wchar_t *what) {
    for (HWND b : M.buttons) EnableWindow(b, !busy && M.ar);
    EnableWindow(M.buttons[0], !busy);
    EnableWindow(M.buttons[2], !busy && M.ar && ListView_GetSelectedCount(M.list) > 0);
    HMENU menu = GetMenu(M.wnd);
    for (int id : {ID_OPEN, ID_EXTRACT, ID_EXTRACT_SEL, ID_VERIFY, ID_PROPS, ID_PROOF})
        EnableMenuItem(menu, (UINT)id, MF_BYCOMMAND | ((!busy && (M.ar || id == ID_OPEN || id == ID_PROOF)) ? MF_ENABLED : MF_GRAYED));
    bool dir = M.ar && M.ar->info.has_directory;
    EnableMenuItem(menu, ID_SIGS, MF_BYCOMMAND | (!busy && dir ? MF_ENABLED : MF_GRAYED));
    EnableMenuItem(menu, ID_UNLOCK, MF_BYCOMMAND | (!busy && dir && M.ar->info.hidden_groups ? MF_ENABLED : MF_GRAYED));
    SendMessageW(M.progress, PBM_SETMARQUEE, FALSE, 0);
    SetWindowLongPtrW(M.progress, GWL_STYLE, GetWindowLongPtrW(M.progress, GWL_STYLE) & ~PBS_MARQUEE);
    ShowWindow(M.progress, busy ? SW_SHOW : SW_HIDE);
    ShowWindow(M.cancel, busy ? SW_SHOW : SW_HIDE);
    SendMessageW(M.progress, PBM_SETPOS, 0, 0);
    SetWindowTextW(M.status, busy ? what : M.idle_status.c_str());
    if (M.taskbar) M.taskbar->SetProgressState(M.wnd, busy ? TBPF_NORMAL : TBPF_NOPROGRESS);
    layout();
}

void show_archive() {
    bool has = M.ar != nullptr;
    ShowWindow(M.list, has ? SW_SHOW : SW_HIDE);
    ShowWindow(M.empty, has ? SW_HIDE : SW_SHOW);
    bool want_group = has && M.ar->info.has_directory && xiz_group_count(M.ar->a) > 1;
    if (want_group != M.group_col) {
        if (want_group) {
            LVCOLUMNW c{};
            c.mask = LVCF_TEXT | LVCF_WIDTH;
            c.pszText = const_cast<wchar_t *>(T(S::ColGroup));
            c.cx = scale(140, M.dpi);
            ListView_InsertColumn(M.list, 3, &c);
        } else {
            ListView_DeleteColumn(M.list, 3);
        }
        M.group_col = want_group;
    }
    ListView_SetItemCountEx(M.list, has ? (int)M.ar->entries.size() : 0, 0);
    if (has) {
        const xiz_info &i = M.ar->info;
        M.idle_status = fmt(S::Summary, (unsigned long long)M.ar->entries.size(), byte_size(M.ar->bytes).c_str());
        if (i.encrypted) M.idle_status += std::wstring(L" \x2022 ") + T(S::Encrypted);
        M.idle_status += vfmt(L" \x2022 XIZ %u.%u", (unsigned)i.version_major, (unsigned)i.version_minor);
        if (i.hidden_groups) M.idle_status += L" \x2022 " + fmt(S::HiddenGroups, (unsigned)i.hidden_groups);
        SetWindowTextW(M.wnd, (file_name(M.ar->path) + L" \x2014 " + T(S::AppName)).c_str());
    } else {
        M.idle_status.clear();
        SetWindowTextW(M.wnd, T(S::AppName));
    }
    set_busy(false, nullptr);
}

void start_repair(const std::wstring &path) {
    if (M.job) return;
    auto j = std::make_unique<Job>();
    j->kind = Job::Repair;
    j->notify = M.wnd;
    j->path = path;
    M.job = std::move(j);
    set_busy(true, T(S::Repairing));
    SetWindowLongPtrW(M.progress, GWL_STYLE, GetWindowLongPtrW(M.progress, GWL_STYLE) | PBS_MARQUEE);
    SendMessageW(M.progress, PBM_SETMARQUEE, TRUE, 30);
    start_job(*M.job);
}

bool has_record(const std::wstring &path) {
    xiz_recovery_info ri;
    xiz_error e;
    return xiz_recovery_info_file(utf8(path).c_str(), &ri, &e) == XIZ_OK;
}

void open_path(const std::wstring &path, bool ask = false) {
    if (M.job) return;
    auto ar = std::make_unique<Archive>();
    Credentials c = ask ? M.creds : Credentials{};
    xiz_error err{};
    int rc = open_interactive(M.wnd, path, c, *ar, true, err, ask);
    if (rc == XIZ_E_PASSWORD_REQUIRED) return;  // the user gave up
    if (rc != XIZ_OK) {
        bool damage = rc == XIZ_E_CORRUPT || rc == XIZ_E_CHECKSUM || rc == XIZ_E_AUTH || rc == XIZ_E_DIGEST;
        if (damage && has_record(path)) {
            TASKDIALOG_BUTTON b[] = {{301, T(S::RepairCopy)}};
            if (task_dialog(M.wnd, TD_ERROR_ICON, T(S::FailTitle), open_error(path, rc, err) + L"\n\n" + T(S::DamagedRepairable), {}, b, 1) == 301)
                start_repair(path);
            return;
        }
        task_dialog(M.wnd, TD_ERROR_ICON, T(S::FailTitle), open_error(path, rc, err));
        return;
    }
    M.ar = std::move(ar);
    M.creds = c;
    show_archive();
    SetFocus(M.list);
}

void start(Job::Kind kind, bool selection) {
    if (!M.ar || M.job) return;
    auto j = std::make_unique<Job>();
    j->kind = kind;
    j->notify = M.wnd;
    j->a = M.ar->a;
    j->path = M.ar->path;
    if (kind == Job::Extract) {
        if (selection) {
            for (int i = -1; (i = ListView_GetNextItem(M.list, i, LVNI_SELECTED)) >= 0;) j->select.push_back(M.ar->entries[(size_t)i].stored);
            if (j->select.empty()) return;
        }
        ExState st;
        st.open_after = M.open_after;
        if (!ask_destination(M.wnd, M.ar->path, st)) return;
        M.open_after = st.open_after;
        j->dest = st.dest;
        j->zone = M.ar->zone;
    }
    M.job = std::move(j);
    set_busy(true, T(kind == Job::Test ? S::Verifying : S::Working));
    start_job(*M.job);
}

int icon_for(const Entry &e) {
    SHFILEINFOW fi{};
    if (e.type == XIZ_TYPE_DIRECTORY) {
        if (M.folder_icon < 0 &&
            SHGetFileInfoW(L"folder", FILE_ATTRIBUTE_DIRECTORY, &fi, sizeof fi, SHGFI_USEFILEATTRIBUTES | SHGFI_SYSICONINDEX | SHGFI_SMALLICON))
            M.folder_icon = fi.iIcon;
        return M.folder_icon;
    }
    std::wstring name = file_name(e.path);
    size_t dot = name.find_last_of(L'.');
    std::wstring ext = dot == std::wstring::npos ? L"" : name.substr(dot);
    CharLowerW(ext.data());
    auto it = M.icons.find(ext);
    if (it != M.icons.end()) return it->second;
    int idx = 0;
    if (SHGetFileInfoW((L"x" + ext).c_str(), FILE_ATTRIBUTE_NORMAL, &fi, sizeof fi, SHGFI_USEFILEATTRIBUTES | SHGFI_SYSICONINDEX | SHGFI_SMALLICON))
        idx = fi.iIcon;
    M.icons[ext] = idx;
    return idx;
}

void add_columns() {
    LVCOLUMNW c{};
    c.mask = LVCF_TEXT | LVCF_WIDTH | LVCF_FMT;
    const S names[] = {S::ColName, S::ColSize, S::ColModified};
    const int widths[] = {460, 110, 160};
    for (int i = 0; i < 3; i++) {
        c.pszText = const_cast<wchar_t *>(T(names[i]));
        c.cx = scale(widths[i], M.dpi);
        c.fmt = i == 1 ? LVCFMT_RIGHT : LVCFMT_LEFT;
        ListView_InsertColumn(M.list, i, &c);
    }
}

HMENU build_menu() {
    HMENU bar = CreateMenu(), file = CreatePopupMenu(), help = CreatePopupMenu();
    AppendMenuW(file, MF_STRING, ID_OPEN, T(S::MenuOpen));
    AppendMenuW(file, MF_STRING, ID_EXTRACT, T(S::MenuExtract));
    AppendMenuW(file, MF_STRING, ID_EXTRACT_SEL, T(S::MenuExtractSel));
    AppendMenuW(file, MF_STRING, ID_VERIFY, T(S::MenuVerify));
    AppendMenuW(file, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(file, MF_STRING, ID_UNLOCK, T(S::MenuUnlock));
    AppendMenuW(file, MF_STRING, ID_SIGS, T(S::MenuSignatures));
    AppendMenuW(file, MF_STRING, ID_PROPS, T(S::MenuProperties));
    AppendMenuW(file, MF_STRING, ID_PROOF, T(S::MenuProof));
    AppendMenuW(file, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(file, MF_STRING, ID_ASSOC, T(S::MenuAssociate));
    AppendMenuW(file, MF_STRING, ID_UNASSOC, T(S::MenuUnassociate));
    AppendMenuW(file, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(file, MF_STRING, ID_EXIT, T(S::MenuExit));
    AppendMenuW(help, MF_STRING, ID_ABOUT, T(S::MenuAbout));
    AppendMenuW(bar, MF_POPUP, (UINT_PTR)file, T(S::MenuFile));
    AppendMenuW(bar, MF_POPUP, (UINT_PTR)help, T(S::MenuHelp));
    return bar;
}

void command(int id) {
    switch (id) {
    case ID_OPEN: {
        COMDLG_FILTERSPEC f[] = {{T(S::OpenFilter), L"*.xiz"}, {T(S::AllFiles), L"*.*"}};
        std::wstring p;
        if (pick_file(M.wnd, f, 2, p)) open_path(p);
        break;
    }
    case ID_EXTRACT: start(Job::Extract, false); break;
    case ID_EXTRACT_SEL: start(Job::Extract, true); break;
    case ID_VERIFY: start(Job::Test, false); break;
    case ID_CANCEL: if (M.job) M.job->cancel = true; break;
    case ID_UNLOCK: if (M.ar) open_path(M.ar->path, true); break;
    case ID_SIGS: if (M.ar) show_signatures(M.wnd, *M.ar); break;
    case ID_PROPS: if (M.ar) show_properties(M.wnd, *M.ar); break;
    case ID_PROOF: check_proof(M.wnd); break;
    case ID_ASSOC:
        if (register_association()) task_dialog(M.wnd, TD_INFORMATION_ICON, T(S::Associated), L"");
        break;
    case ID_UNASSOC:
        unregister_association();
        task_dialog(M.wnd, TD_INFORMATION_ICON, T(S::Unassociated), L"");
        break;
    case ID_ABOUT: {
        std::wstring about = fmt(S::About, wide(XIZW_VERSION, strlen(XIZW_VERSION)).c_str());
        size_t nl = about.find(L'\n');
        task_dialog(M.wnd, MAKEINTRESOURCEW(IDI_APP), about.substr(0, nl), about.substr(nl + 1));
        break;
    }
    case ID_EXIT: PostMessageW(M.wnd, WM_CLOSE, 0, 0); break;
    }
}

LRESULT CALLBACK main_proc(HWND w, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE: {
        M.wnd = w;
        M.dpi = dpi_of(w);
        M.font = make_font(M.dpi);
        const S labels[] = {S::Open, S::ExtractAll, S::ExtractSel, S::Verify};
        const int ids[] = {ID_OPEN, ID_EXTRACT, ID_EXTRACT_SEL, ID_VERIFY};
        for (int i = 0; i < 4; i++)
            M.buttons[i] = CreateWindowW(L"BUTTON", T(labels[i]), WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 0, 0, w,
                                         (HMENU)(INT_PTR)ids[i], g_inst, nullptr);
        M.list = CreateWindowExW(0, WC_LISTVIEWW, L"", WS_CHILD | WS_TABSTOP | LVS_REPORT | LVS_OWNERDATA | LVS_SHOWSELALWAYS | LVS_SHAREIMAGELISTS,
                                 0, 0, 0, 0, w, (HMENU)(INT_PTR)ID_LIST, g_inst, nullptr);
        SetWindowTheme(M.list, L"Explorer", nullptr);
        ListView_SetExtendedListViewStyle(M.list, LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER);
        SHFILEINFOW fi{};
        auto sys = (HIMAGELIST)SHGetFileInfoW(L"", 0, &fi, sizeof fi, SHGFI_SYSICONINDEX | SHGFI_SMALLICON);
        if (sys) ListView_SetImageList(M.list, sys, LVSIL_SMALL);
        add_columns();
        M.empty = CreateWindowW(L"STATIC", T(S::Empty), WS_CHILD | WS_VISIBLE | SS_CENTER, 0, 0, 0, 0, w, nullptr, g_inst, nullptr);
        M.status = CreateWindowW(L"STATIC", L"", WS_CHILD | WS_VISIBLE | SS_LEFT | SS_ENDELLIPSIS | SS_NOPREFIX, 0, 0, 0, 0, w, nullptr, g_inst, nullptr);
        M.progress = CreateWindowW(PROGRESS_CLASSW, L"", WS_CHILD, 0, 0, 0, 0, w, nullptr, g_inst, nullptr);
        SendMessageW(M.progress, PBM_SETRANGE32, 0, 1000);
        M.cancel = CreateWindowW(L"BUTTON", T(S::Cancel), WS_CHILD | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 0, 0, w,
                                 (HMENU)(INT_PTR)ID_CANCEL, g_inst, nullptr);
        set_font_all(w, M.font);
        DragAcceptFiles(w, TRUE);
        show_archive();
        return 0;
    }
    case WM_SIZE: layout(); return 0;
    case WM_GETMINMAXINFO: {
        auto *mm = reinterpret_cast<MINMAXINFO *>(lp);
        mm->ptMinTrackSize = {scale(520, M.dpi), scale(320, M.dpi)};
        return 0;
    }
    case WM_DPICHANGED: {
        UINT old = M.dpi;
        M.dpi = HIWORD(wp);
        HFONT f = make_font(M.dpi);
        set_font_all(w, f);
        if (M.font) DeleteObject(M.font);
        M.font = f;
        for (int i = 0; i < 3; i++) ListView_SetColumnWidth(M.list, i, MulDiv(ListView_GetColumnWidth(M.list, i), (int)M.dpi, (int)old));
        auto *r = reinterpret_cast<RECT *>(lp);
        SetWindowPos(w, nullptr, r->left, r->top, r->right - r->left, r->bottom - r->top, SWP_NOZORDER | SWP_NOACTIVATE);
        layout();
        return 0;
    }
    case WM_COMMAND: command(LOWORD(wp)); return 0;
    case WM_DROPFILES: {
        auto drop = (HDROP)wp;
        UINT n = DragQueryFileW(drop, 0, nullptr, 0);
        std::wstring p((size_t)n + 1, L'\0');
        DragQueryFileW(drop, 0, p.data(), n + 1);
        p.resize(n);
        DragFinish(drop);
        open_path(p);
        return 0;
    }
    case WM_NOTIFY: {
        auto *h = reinterpret_cast<NMHDR *>(lp);
        if (h->idFrom == ID_LIST && h->code == LVN_GETDISPINFOW && M.ar) {
            auto *d = reinterpret_cast<NMLVDISPINFOW *>(lp);
            if (d->item.iItem < 0 || (size_t)d->item.iItem >= M.ar->entries.size()) return 0;
            const Entry &e = M.ar->entries[(size_t)d->item.iItem];
            if (d->item.mask & LVIF_IMAGE) d->item.iImage = icon_for(e);
            if (d->item.mask & LVIF_TEXT) {
                static std::wstring text;
                if (d->item.iSubItem == 0) text = e.path;
                else if (d->item.iSubItem == 1) text = e.type == XIZ_TYPE_FILE ? byte_size(e.size) : L"";
                else if (d->item.iSubItem == 2) text = date_time(e.mtime);
                else text = group_name(M.ar->a, e.group);
                lstrcpynW(d->item.pszText, text.c_str(), d->item.cchTextMax);
            }
            return 0;
        }
        if (h->idFrom == ID_LIST && h->code == LVN_ITEMCHANGED)
            EnableWindow(M.buttons[2], !M.job && ListView_GetSelectedCount(M.list) > 0);
        break;
    }
    case WM_JOB_PROGRESS:
        SendMessageW(M.progress, PBM_SETPOS, wp, 0);
        if (M.taskbar) M.taskbar->SetProgressValue(w, wp, 1000);
        return 0;
    case WM_JOB_CONFLICT: return conflict_dialog(w, *reinterpret_cast<Conflict *>(lp));
    case WM_JOB_DONE: {
        std::unique_ptr<Job> j = std::move(M.job);
        set_busy(false, nullptr);
        if (M.close_when_done) { DestroyWindow(w); return 0; }
        Next next = NEXT_NONE;
        show_result(w, *j, M.open_after, false, &next);
        if (j->rc == XIZ_E_CALLBACK && j->cancel) SetWindowTextW(M.status, T(S::Cancelled));
        if (next == NEXT_REPAIR) start_repair(j->path);
        else if (next == NEXT_OPEN_COPY) open_path(j->repaired);
        return 0;
    }
    case WM_CLOSE:
        if (M.job) { M.job->cancel = true; M.close_when_done = true; return 0; }
        DestroyWindow(w);
        return 0;
    case WM_DESTROY:
        M.ar.reset();
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(w, msg, wp, lp);
}

// ---------------------------------------------------------------- progress window (/x, /xto, /t)

struct Prog {
    HWND wnd = nullptr, label = nullptr, bar = nullptr, cancel = nullptr;
    HFONT font = nullptr;
    Job *job = nullptr;
    bool open_after = false;
    int exit = EXIT_OK;
} P;

void prog_layout() {
    UINT dpi = dpi_of(P.wnd);
    RECT rc;
    GetClientRect(P.wnd, &rc);
    int pad = scale(14, dpi);
    MoveWindow(P.label, pad, pad, rc.right - 2 * pad, scale(20, dpi), TRUE);
    MoveWindow(P.bar, pad, pad + scale(28, dpi), rc.right - 2 * pad, scale(16, dpi), TRUE);
    MoveWindow(P.cancel, rc.right - pad - scale(90, dpi), rc.bottom - pad - scale(26, dpi), scale(90, dpi), scale(26, dpi), TRUE);
}

LRESULT CALLBACK prog_proc(HWND w, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE: {
        P.wnd = w;
        P.label = CreateWindowW(L"STATIC", L"", WS_CHILD | WS_VISIBLE | SS_LEFT | SS_ENDELLIPSIS | SS_NOPREFIX, 0, 0, 0, 0, w, nullptr, g_inst, nullptr);
        P.bar = CreateWindowW(PROGRESS_CLASSW, L"", WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, w, nullptr, g_inst, nullptr);
        SendMessageW(P.bar, PBM_SETRANGE32, 0, 1000);
        P.cancel = CreateWindowW(L"BUTTON", T(S::Cancel), WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 0, 0, w,
                                 (HMENU)(INT_PTR)ID_CANCEL, g_inst, nullptr);
        P.font = make_font(dpi_of(w));
        set_font_all(w, P.font);
        return 0;
    }
    case WM_SIZE: prog_layout(); return 0;
    case WM_DPICHANGED: {
        HFONT f = make_font(HIWORD(wp));
        set_font_all(w, f);
        if (P.font) DeleteObject(P.font);
        P.font = f;
        auto *r = reinterpret_cast<RECT *>(lp);
        SetWindowPos(w, nullptr, r->left, r->top, r->right - r->left, r->bottom - r->top, SWP_NOZORDER | SWP_NOACTIVATE);
        return 0;
    }
    case WM_COMMAND:
        if (LOWORD(wp) == ID_CANCEL && P.job) { P.job->cancel = true; EnableWindow(P.cancel, FALSE); }
        return 0;
    case WM_CLOSE:
        if (P.job) { P.job->cancel = true; EnableWindow(P.cancel, FALSE); }
        return 0;
    case WM_JOB_PROGRESS: SendMessageW(P.bar, PBM_SETPOS, wp, 0); return 0;
    case WM_JOB_CONFLICT: return conflict_dialog(w, *reinterpret_cast<Conflict *>(lp));
    case WM_JOB_DONE:
        ShowWindow(w, SW_HIDE);
        P.exit = show_result(nullptr, *P.job, P.open_after, false);
        P.job = nullptr;
        DestroyWindow(w);
        return 0;
    case WM_DESTROY: PostQuitMessage(0); return 0;
    }
    return DefWindowProcW(w, msg, wp, lp);
}

// ---------------------------------------------------------------- command line

struct Args {
    std::wstring mode, archive, dest, log;
    std::vector<std::wstring> passenv, keys;  // repeatable: custodians, recipients, factors
    bool quiet = false, keep_both = false;
};

void write_log(const std::wstring &path, const std::string &text) {
    if (path.empty()) return;
    HANDLE h = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr);
    if (h == INVALID_HANDLE_VALUE) return;
    DWORD n = 0;
    WriteFile(h, text.data(), (DWORD)text.size(), &n, nullptr);
    CloseHandle(h);
}

std::string job_log(const Job &j, int code) {
    char buf[512];
    snprintf(buf, sizeof buf, "exit %d\nstatus %d\nfiles %llu\nfolders %llu\nlinks %llu\nskipped %llu\nfailed %llu\nrenamed %llu\n"
             "checked %llu\ndamaged %llu\n", code, j.rc, (unsigned long long)j.rep.files, (unsigned long long)j.rep.directories,
             (unsigned long long)j.rep.symlinks, (unsigned long long)j.rep.skipped, (unsigned long long)j.rep.failed,
             (unsigned long long)j.rep.renamed, (unsigned long long)j.trep.files_checked, (unsigned long long)j.trep.files_failed);
    std::string s = buf;
    if (j.has_record) {
        snprintf(buf, sizeof buf, "record yes\nrecord-damage %u\nrepairable %d\n",
                 j.rrep.damaged_data_slices + j.rrep.damaged_recovery_slices + j.rrep.damaged_metadata, j.rrep.repairable);
        s += buf;
    }
    if (!j.repaired.empty()) s += "repaired " + utf8(j.repaired) + "\n";
    if (j.rc != XIZ_OK) s += std::string("error ") + j.err.message + "\n";
    for (auto &p : j.problems) s += "problem " + utf8(p) + "\n";
    return s;
}

int run_command(const Args &a) {
    bool interactive = !a.quiet;
    if (a.mode == L"/register" || a.mode == L"/unregister") {
        bool ok = a.mode == L"/register" ? register_association() : unregister_association();
        if (interactive) task_dialog(nullptr, TD_INFORMATION_ICON, T(a.mode == L"/register" ? S::Associated : S::Unassociated), L"");
        return ok ? EXIT_OK : EXIT_ERROR;
    }
    if (a.archive.empty()) {
        if (interactive) task_dialog(nullptr, TD_INFORMATION_ICON, T(S::AppName), T(S::Usage));
        return EXIT_USAGE;
    }
    Credentials c;
    for (auto &var : a.passenv) {
        std::wstring v(32768, L'\0');
        DWORD n = GetEnvironmentVariableW(var.c_str(), v.data(), (DWORD)v.size());
        v.resize(n < v.size() ? n : 0);
        c.add_password(v);
        wipe(v);
    }
    for (auto &k : a.keys) {
        if (c.add_key_file(k) <= 0) {
            write_log(a.log, "exit 2\nerror invalid key file\n");
            if (interactive) task_dialog(nullptr, TD_ERROR_ICON, T(S::FailTitle), T(S::CrKeyInvalid));
            return EXIT_USAGE;
        }
    }
    Job j;
    Archive ar;  // outlives the job, which reads it
    bool open_after = false;
    if (a.mode == L"/repair") {
        j.kind = Job::Repair;
        j.path = a.archive;
    } else {
    xiz_error err{};
    int rc = open_interactive(nullptr, a.archive, c, ar, interactive, err);
    if (rc != XIZ_OK) {
        bool pw = rc == XIZ_E_PASSWORD_REQUIRED || rc == XIZ_E_WRONG_PASSWORD || rc == XIZ_E_FACTOR_REQUIRED;
        if (interactive && !pw) task_dialog(nullptr, TD_ERROR_ICON, T(S::FailTitle), open_error(a.archive, rc, err));
        std::string shown = utf8(open_error(a.archive, rc, err));
        for (char &ch : shown) if (ch == '\n') ch = ' ';
        write_log(a.log, "exit " + std::to_string(pw ? EXIT_PASSWORD : EXIT_ERROR) + "\nstatus " + std::to_string(rc) + "\nerror " + err.message +
                             "\nmessage " + shown + "\n");
        return pw ? EXIT_PASSWORD : EXIT_ERROR;
    }
    c.wipe();
    if (a.mode == L"/info") {
        std::wstring text = properties_text(ar);
        write_log(a.log, utf8(text));
        if (interactive) show_properties(nullptr, ar);
        return EXIT_OK;
    }
    j.a = ar.a;
    j.path = ar.path;
    j.kind = a.mode == L"/t" ? Job::Test : Job::Extract;
    j.zone = ar.zone;
    j.quiet_conflict = a.keep_both ? XIZ_CONFLICT_RENAME : XIZ_CONFLICT_SKIP;
    if (j.kind == Job::Extract) {
        if (a.mode == L"/xto") {
            ExState st;
            if (!a.dest.empty()) st.dest = a.dest;
            if (!ask_destination(nullptr, ar.path, st)) return EXIT_CANCELLED;
            j.dest = st.dest;
            open_after = st.open_after;
        } else {
            j.dest = a.dest.empty() ? parent_dir(ar.path) + L"\\" + stem(ar.path) : a.dest;
        }
    }
    }
    int code;
    if (!interactive) {
        run_job(j);
        code = exit_code(j);
    } else {
        P.job = &j;
        P.open_after = open_after;
        UINT dpi = GetDpiForSystem();
        RECT r{0, 0, scale(420, dpi), scale(120, dpi)};
        AdjustWindowRectExForDpi(&r, WS_CAPTION | WS_SYSMENU, FALSE, 0, dpi);
        HWND w = CreateWindowExW(0, kProgressClass, T(S::AppName), WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX, CW_USEDEFAULT, CW_USEDEFAULT,
                                 r.right - r.left, r.bottom - r.top, nullptr, nullptr, g_inst, nullptr);
        S what = j.kind == Job::Test ? S::Verifying : j.kind == Job::Repair ? S::Repairing : S::Working;
        SetWindowTextW(P.label, (std::wstring(T(what)) + L" " + file_name(a.archive)).c_str());
        if (j.kind == Job::Repair) {
            SetWindowLongPtrW(P.bar, GWL_STYLE, GetWindowLongPtrW(P.bar, GWL_STYLE) | PBS_MARQUEE);
            SendMessageW(P.bar, PBM_SETMARQUEE, TRUE, 30);
        }
        prog_layout();
        ShowWindow(w, SW_SHOWNORMAL);
        j.notify = w;
        start_job(j);
        MSG m;
        while (GetMessageW(&m, nullptr, 0, 0) > 0) {
            if (!IsDialogMessageW(w, &m)) { TranslateMessage(&m); DispatchMessageW(&m); }
        }
        code = P.exit;
    }
    write_log(a.log, job_log(j, code));
    return code;
}

}  // namespace

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int show) {
    g_inst = inst;
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    INITCOMMONCONTROLSEX icc{sizeof icc, ICC_LISTVIEW_CLASSES | ICC_PROGRESS_CLASS | ICC_STANDARD_CLASSES};
    InitCommonControlsEx(&icc);

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof wc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hIcon = LoadIconW(inst, MAKEINTRESOURCEW(IDI_APP));
    wc.hbrBackground = GetSysColorBrush(COLOR_BTNFACE);
    wc.lpfnWndProc = main_proc;
    wc.lpszClassName = kMainClass;
    RegisterClassExW(&wc);
    wc.lpfnWndProc = prog_proc;
    wc.lpszClassName = kProgressClass;
    RegisterClassExW(&wc);

    int argc = 0;
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    Args a;
    std::wstring first;
    for (int i = 1; i < argc; i++) {
        std::wstring s = argv[i];
        auto next = [&](std::wstring &dst) { if (i + 1 < argc) dst = argv[++i]; };
        if (s == L"/x" || s == L"/xto" || s == L"/t" || s == L"/repair" || s == L"/info") { a.mode = s; next(a.archive); }
        else if (s == L"/register" || s == L"/unregister") a.mode = s;
        else if (s == L"/d") next(a.dest);
        else if (s == L"/passenv") { std::wstring v; next(v); a.passenv.push_back(v); }
        else if (s == L"/factor" || s == L"/identity") { std::wstring v; next(v); a.keys.push_back(v); }
        else if (s == L"/log") next(a.log);
        else if (s == L"/quiet") a.quiet = true;
        else if (s == L"/keep-both") a.keep_both = true;
        else if (s == L"/?" || s == L"/help") a.mode = L"/help";
        else if (first.empty()) first = s;
    }
    LocalFree(argv);
    if (!a.mode.empty()) {
        int code = run_command(a);
        CoUninitialize();
        return code;
    }

    UINT dpi = GetDpiForSystem();
    HWND w = CreateWindowExW(0, kMainClass, T(S::AppName), WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, scale(900, dpi),
                             scale(600, dpi), nullptr, build_menu(), inst, nullptr);
    if (SUCCEEDED(CoCreateInstance(CLSID_TaskbarList, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&M.taskbar))) &&
        FAILED(M.taskbar->HrInit())) {
        M.taskbar->Release();
        M.taskbar = nullptr;
    }
    set_busy(false, nullptr);
    ShowWindow(w, show);
    UpdateWindow(w);
    if (!first.empty()) open_path(first);

    ACCEL acc[] = {{FCONTROL | FVIRTKEY, 'O', ID_OPEN}, {FCONTROL | FVIRTKEY, 'E', ID_EXTRACT}, {FCONTROL | FVIRTKEY, 'T', ID_VERIFY},
                   {FALT | FVIRTKEY, VK_RETURN, ID_PROPS}};
    HACCEL accel = CreateAcceleratorTableW(acc, 4);
    MSG m;
    while (GetMessageW(&m, nullptr, 0, 0) > 0) {
        if (!TranslateAcceleratorW(w, accel, &m)) {
            TranslateMessage(&m);
            DispatchMessageW(&m);
        }
    }
    DestroyAcceleratorTable(accel);
    if (M.taskbar) M.taskbar->Release();
    CoUninitialize();
    return 0;
}
