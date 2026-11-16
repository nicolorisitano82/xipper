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
#include "dragdrop.h"
#include "resource.h"
#include "strings.h"

#ifndef XIZW_VERSION
#define XIZW_VERSION "0.0.0"
#endif

namespace {

enum : int {
    ID_OPEN = 1001, ID_EXTRACT, ID_EXTRACT_SEL, ID_VERIFY, ID_ASSOC, ID_UNASSOC, ID_EXIT, ID_ABOUT, ID_CANCEL,
    ID_UNLOCK, ID_SIGS, ID_PROPS, ID_PROOF, ID_BACK, ID_UP, ID_NEW, ID_ADD, ID_ADDDIR, ID_DELETE,
    ID_LIST = 1100, ID_TREE
};

enum Exit : int { EXIT_OK = 0, EXIT_ERROR = 1, EXIT_USAGE = 2, EXIT_PASSWORD = 3, EXIT_SKIPPED = 4, EXIT_CANCELLED = 5 };

HINSTANCE g_inst;
const wchar_t kMainClass[] = L"XipperXIZ.Main";
const wchar_t kProgressClass[] = L"XipperXIZ.Progress";
const wchar_t kCollectClass[] = L"XipperXIZ.Collect";

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

// ---------------------------------------------------------------- new archive dialog

struct NewState {
    std::wstring path;
    std::vector<std::wstring> sources;
    int level = 9;
    std::wstring password;
    bool strong = false, recovery = false;
};

bool lots_of_memory() {
    MEMORYSTATUSEX m{};
    m.dwLength = sizeof m;
    return GlobalMemoryStatusEx(&m) && m.ullTotalPhys >= (8ull << 30);  // the strong profile wants 1 GiB per opening
}

std::wstring unique_path(const std::wstring &want) {
    if (GetFileAttributesW(want.c_str()) == INVALID_FILE_ATTRIBUTES) return want;
    std::wstring base = want.size() > 4 ? want.substr(0, want.size() - 4) : want;
    for (int k = 2;; k++) {
        std::wstring p = base + vfmt(L" %d.xiz", k);
        if (GetFileAttributesW(p.c_str()) == INVALID_FILE_ATTRIBUTES) return p;
    }
}

// Next to the first item: "name.xiz" for one item, "<its folder>.xiz" for several.
std::wstring default_archive(const std::vector<std::wstring> &sources) {
    if (sources.empty()) {
        PWSTR docs = nullptr;
        std::wstring dir = L".";
        if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_Documents, 0, nullptr, &docs))) { dir = docs; CoTaskMemFree(docs); }
        return unique_path(dir + L"\\" + T(S::DefaultArchiveName) + L".xiz");
    }
    std::wstring first = sources[0];
    while (first.size() > 3 && (first.back() == L'\\' || first.back() == L'/')) first.pop_back();
    std::wstring dir = parent_dir(first);
    std::wstring name = sources.size() == 1 ? stem(first) : file_name(dir);
    if (name.empty() || name.back() == L':') name = T(S::DefaultArchiveName);
    return unique_path(dir + L"\\" + name + L".xiz");
}

void new_refresh(HWND d, NewState *st) {
    HWND l = GetDlgItem(d, IDC_NEW_SOURCES);
    SendMessageW(l, LB_RESETCONTENT, 0, 0);
    LONG wide_px = 0;
    HDC dc = GetDC(l);
    HGDIOBJ old = SelectObject(dc, (HFONT)SendMessageW(l, WM_GETFONT, 0, 0));
    for (auto &x : st->sources) {
        SendMessageW(l, LB_ADDSTRING, 0, (LPARAM)x.c_str());
        SIZE sz{};
        GetTextExtentPoint32W(dc, x.c_str(), (int)x.size(), &sz);
        wide_px = std::max(wide_px, sz.cx + 8);
    }
    SelectObject(dc, old);
    ReleaseDC(l, dc);
    SendMessageW(l, LB_SETHORIZONTALEXTENT, (WPARAM)wide_px, 0);
}

void new_enable(HWND d) {
    bool pw = IsDlgButtonChecked(d, IDC_NEW_USEPW) == BST_CHECKED;
    for (int id : {IDC_NEW_PWLABEL, IDC_NEW_PW, IDC_NEW_PW2LABEL, IDC_NEW_PW2, IDC_NEW_STRENGTH}) EnableWindow(GetDlgItem(d, id), pw);
    EnableWindow(GetDlgItem(d, IDC_NEW_STRONG), pw && lots_of_memory());
}

int g_strength = -1;  // the level shown, for its colour

void new_strength(HWND d) {
    std::wstring pw = window_text(GetDlgItem(d, IDC_NEW_PW));
    if (pw.empty()) { g_strength = -1; SetDlgItemTextW(d, IDC_NEW_STRENGTH, L""); return; }
    g_strength = strength_level(password_bits(pw));
    wipe(pw);
    const S names[] = {S::StrengthWeak, S::StrengthFair, S::StrengthGood, S::StrengthExcellent};
    SetDlgItemTextW(d, IDC_NEW_STRENGTH, fmt(S::StrengthLabel, T(names[g_strength])).c_str());
    InvalidateRect(GetDlgItem(d, IDC_NEW_STRENGTH), nullptr, TRUE);
}

bool pick_save(HWND owner, std::wstring &inout) {
    IFileSaveDialog *d = nullptr;
    if (FAILED(CoCreateInstance(CLSID_FileSaveDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&d)))) return false;
    COMDLG_FILTERSPEC f[] = {{T(S::OpenFilter), L"*.xiz"}};
    d->SetFileTypes(1, f);
    d->SetDefaultExtension(L"xiz");
    d->SetFileName(file_name(inout).c_str());
    IShellItem *start = nullptr;
    if (SUCCEEDED(SHCreateItemFromParsingName(parent_dir(inout).c_str(), nullptr, IID_PPV_ARGS(&start)))) {
        d->SetFolder(start);
        start->Release();
    }
    DWORD opts = 0;
    d->GetOptions(&opts);
    d->SetOptions(opts | FOS_FORCEFILESYSTEM | FOS_OVERWRITEPROMPT);
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

// Several files at once (IFileOpenDialog with multiple selection), or one folder.
bool pick_many(HWND owner, bool folders, std::vector<std::wstring> &out) {
    IFileOpenDialog *d = nullptr;
    if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&d)))) return false;
    DWORD opts = 0;
    d->GetOptions(&opts);
    d->SetOptions(opts | FOS_FORCEFILESYSTEM | (folders ? FOS_PICKFOLDERS : FOS_ALLOWMULTISELECT | FOS_FILEMUSTEXIST));
    bool ok = false;
    IShellItemArray *items = nullptr;
    if (SUCCEEDED(d->Show(owner)) && SUCCEEDED(d->GetResults(&items))) {
        DWORD n = 0;
        items->GetCount(&n);
        for (DWORD i = 0; i < n; i++) {
            IShellItem *it = nullptr;
            PWSTR p = nullptr;
            if (SUCCEEDED(items->GetItemAt(i, &it)) && SUCCEEDED(it->GetDisplayName(SIGDN_FILESYSPATH, &p))) {
                out.push_back(p);
                CoTaskMemFree(p);
                ok = true;
            }
            if (it) it->Release();
        }
        items->Release();
    }
    d->Release();
    return ok;
}

INT_PTR CALLBACK new_proc(HWND d, UINT msg, WPARAM wp, LPARAM lp) {
    auto *st = reinterpret_cast<NewState *>(GetWindowLongPtrW(d, DWLP_USER));
    switch (msg) {
    case WM_INITDIALOG: {
        st = reinterpret_cast<NewState *>(lp);
        SetWindowLongPtrW(d, DWLP_USER, lp);
        SetWindowTextW(d, T(S::NewTitle));
        const std::pair<int, S> texts[] = {
            {IDC_NEW_PATHLABEL, S::NewArchiveLabel}, {IDC_NEW_PATHBROWSE, S::Browse}, {IDC_NEW_CONTENTS, S::NewContents},
            {IDC_NEW_ADDFILES, S::NewAddFiles}, {IDC_NEW_ADDDIR, S::NewAddFolder}, {IDC_NEW_REMOVE, S::NewRemove},
            {IDC_NEW_LEVELLABEL, S::NewLevel}, {IDC_NEW_USEPW, S::NewUsePw}, {IDC_NEW_PWLABEL, S::NewPw}, {IDC_NEW_PW2LABEL, S::NewPw2},
            {IDC_NEW_STRONG, S::NewStrong}, {IDC_NEW_RECOVERY, S::NewRecovery}, {IDOK, S::NewCreate}, {IDCANCEL, S::Cancel}};
        for (auto &t : texts) SetDlgItemTextW(d, t.first, T(t.second));
        if (st->path.empty()) st->path = default_archive(st->sources);
        SetDlgItemTextW(d, IDC_NEW_PATH, st->path.c_str());
        HWND lv = GetDlgItem(d, IDC_NEW_LEVEL);
        for (S x : {S::LevelFast, S::LevelNormal, S::LevelMax}) SendMessageW(lv, CB_ADDSTRING, 0, (LPARAM)T(x));
        SendMessageW(lv, CB_SETCURSEL, st->level <= 3 ? 0 : st->level >= 19 ? 2 : 1, 0);
        CheckDlgButton(d, IDC_NEW_RECOVERY, st->recovery ? BST_CHECKED : BST_UNCHECKED);
        new_refresh(d, st);
        new_enable(d);
        return TRUE;
    }
    case WM_CTLCOLORSTATIC: {
        HWND c = (HWND)lp;
        COLORREF col = 0;
        bool colour = false;
        if (c == GetDlgItem(d, IDC_NEW_ERROR)) { col = RGB(196, 43, 28); colour = true; }
        else if (c == GetDlgItem(d, IDC_NEW_STRENGTH) && g_strength >= 0) {
            static const COLORREF levels[] = {RGB(196, 43, 28), RGB(202, 120, 0), RGB(16, 124, 16), RGB(16, 124, 16)};
            col = levels[g_strength];
            colour = true;
        }
        if (colour) {
            SetTextColor((HDC)wp, col);
            SetBkMode((HDC)wp, TRANSPARENT);
            return (INT_PTR)GetSysColorBrush(COLOR_BTNFACE);
        }
        break;
    }
    case WM_COMMAND:
        switch (LOWORD(wp)) {
        case IDC_NEW_PATHBROWSE: {
            std::wstring p = window_text(GetDlgItem(d, IDC_NEW_PATH));
            if (pick_save(d, p)) SetDlgItemTextW(d, IDC_NEW_PATH, p.c_str());
            return TRUE;
        }
        case IDC_NEW_ADDFILES:
        case IDC_NEW_ADDDIR: {
            std::vector<std::wstring> more;
            if (pick_many(d, LOWORD(wp) == IDC_NEW_ADDDIR, more)) {
                bool first = st->sources.empty();
                for (auto &m : more)
                    if (std::find(st->sources.begin(), st->sources.end(), m) == st->sources.end()) st->sources.push_back(m);
                new_refresh(d, st);
                if (first) SetDlgItemTextW(d, IDC_NEW_PATH, default_archive(st->sources).c_str());
            }
            return TRUE;
        }
        case IDC_NEW_REMOVE: {
            HWND l = GetDlgItem(d, IDC_NEW_SOURCES);
            for (int i = (int)st->sources.size() - 1; i >= 0; i--)
                if (SendMessageW(l, LB_GETSEL, (WPARAM)i, 0) > 0) st->sources.erase(st->sources.begin() + i);
            new_refresh(d, st);
            return TRUE;
        }
        case IDC_NEW_USEPW:
            new_enable(d);
            if (IsDlgButtonChecked(d, IDC_NEW_USEPW) == BST_CHECKED) SetFocus(GetDlgItem(d, IDC_NEW_PW));
            return TRUE;
        case IDC_NEW_PW:
            if (HIWORD(wp) == EN_CHANGE) new_strength(d);
            return TRUE;
        case IDOK: {
            auto fail = [&](S why) { SetDlgItemTextW(d, IDC_NEW_ERROR, T(why)); MessageBeep(MB_ICONWARNING); };
            if (st->sources.empty()) { fail(S::NewNoSources); return TRUE; }
            std::wstring path = window_text(GetDlgItem(d, IDC_NEW_PATH));
            if (path.empty()) return TRUE;
            if (path.size() < 4 || _wcsicmp(path.c_str() + path.size() - 4, L".xiz") != 0) path += L".xiz";
            st->password.clear();
            if (IsDlgButtonChecked(d, IDC_NEW_USEPW) == BST_CHECKED) {
                std::wstring a = window_text(GetDlgItem(d, IDC_NEW_PW)), b = window_text(GetDlgItem(d, IDC_NEW_PW2));
                bool same = a == b;
                wipe(b);
                if (a.empty()) { fail(S::NewPwEmpty); return TRUE; }
                if (!same) { wipe(a); fail(S::NewPwMismatch); SetFocus(GetDlgItem(d, IDC_NEW_PW2)); return TRUE; }
                if (password_bits(a) < kMinimumBits) {
                    TASKDIALOG_BUTTON bt[] = {{400, T(S::UseAnyway)}};
                    if (task_dialog(d, TD_WARNING_ICON, T(S::WeakTitle), T(S::WeakText), {}, bt, 1, TDCBF_CANCEL_BUTTON) != 400) {
                        wipe(a);
                        SetFocus(GetDlgItem(d, IDC_NEW_PW));
                        return TRUE;
                    }
                }
                st->password = a;
                wipe(a);
                st->strong = IsDlgButtonChecked(d, IDC_NEW_STRONG) == BST_CHECKED;
            }
            if (GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES) {
                TASKDIALOG_BUTTON bt[] = {{401, T(S::ConflictReplace)}};
                if (task_dialog(d, TD_WARNING_ICON, fmt(S::NewExists, file_name(path).c_str()), L"", {}, bt, 1, TDCBF_CANCEL_BUTTON) != 401)
                    return TRUE;
            }
            static const int levels[] = {3, 9, 19};
            LRESULT sel = SendMessageW(GetDlgItem(d, IDC_NEW_LEVEL), CB_GETCURSEL, 0, 0);
            st->level = levels[sel >= 0 && sel < 3 ? sel : 1];
            st->recovery = IsDlgButtonChecked(d, IDC_NEW_RECOVERY) == BST_CHECKED;
            st->path = path;
            SetDlgItemTextW(d, IDC_NEW_PW, L"");
            SetDlgItemTextW(d, IDC_NEW_PW2, L"");
            EndDialog(d, IDOK);
            return TRUE;
        }
        case IDCANCEL:
            SetDlgItemTextW(d, IDC_NEW_PW, L"");
            SetDlgItemTextW(d, IDC_NEW_PW2, L"");
            EndDialog(d, IDCANCEL);
            return TRUE;
        }
        break;
    }
    return FALSE;
}

// The dialog, then a Create job ready to start (password in NFC).
bool ask_new(HWND owner, const std::vector<std::wstring> &sources, Job &j) {
    NewState st;
    st.sources = sources;
    if (DialogBoxParamW(g_inst, MAKEINTRESOURCEW(IDD_NEW), owner, new_proc, (LPARAM)&st) != IDOK) { wipe(st.password); return false; }
    j.kind = Job::Create;
    j.path = st.path;
    j.sources = st.sources;
    j.level = st.level;
    j.password = password_utf8(st.password);
    wipe(st.password);
    j.strong = st.strong;
    j.recovery = st.recovery;
    return true;
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

enum Next { NEXT_NONE, NEXT_REPAIR, NEXT_OPEN_COPY, NEXT_OPEN_CREATED, NEXT_REOPEN };

void show_in_folder(const std::wstring &path) {
    ShellExecuteW(nullptr, L"open", L"explorer.exe", (L"/select,\"" + path + L"\"").c_str(), nullptr, SW_SHOWNORMAL);
}

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
    if (j.kind == Job::Create || j.kind == Job::Update) {
        if (j.rc != XIZ_OK) {
            task_dialog(owner, TD_ERROR_ICON, T(S::FailTitle), msg);
            return code;
        }
        if (next) { *next = j.kind == Job::Create ? NEXT_OPEN_CREATED : NEXT_REOPEN; return code; }  // the main window shows it
        WIN32_FILE_ATTRIBUTE_DATA fa{};
        GetFileAttributesExW(j.path.c_str(), GetFileExInfoStandard, &fa);
        uint64_t out = (uint64_t)fa.nFileSizeHigh << 32 | fa.nFileSizeLow;
        TASKDIALOG_BUTTON b[] = {{500, T(S::ShowInFolder)}};
        if (task_dialog(owner, TD_INFORMATION_ICON, T(S::CreatedTitle),
                        fmt(S::CreatedText, j.path.c_str(), (unsigned long long)j.files, byte_size(j.bytes_in).c_str(), byte_size(out).c_str()),
                        {}, b, 1) == 500)
            show_in_folder(j.path);
        return code;
    }
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

// The archive as folders, like File Explorer: the folder tree on the left, the open folder's
// contents on the right, an address bar with Back and Up. Folders that the archive does not store
// as entries (implied by a file's path) are folders all the same.
struct Node {
    std::wstring name;
    std::string stored;          // "a/b" (empty for the root)
    int parent = -1;
    std::vector<int> dirs;       // child folders, sorted by name
    std::vector<size_t> files;   // entries (files and links) directly inside
    int entry = -1;              // the folder's own entry, when stored
    HTREEITEM item = nullptr;
    bool filled = false;         // children inserted in the tree
};

struct Row {
    bool dir;
    size_t idx;                  // node (dir) or entry
};

enum { B_NEW, B_OPEN, B_EXTRACT, B_EXTRACT_SEL, B_VERIFY, B_ADD, B_DELETE };

struct Main {
    HWND wnd = nullptr, tree = nullptr, list = nullptr, addr = nullptr, back = nullptr, up = nullptr, tips = nullptr;
    HWND empty = nullptr, status = nullptr, progress = nullptr, cancel = nullptr;
    HWND buttons[7] = {};  // B_*
    HFONT font = nullptr;
    UINT dpi = 96;
    std::unique_ptr<Archive> ar;
    Credentials creds;  // what opened `ar`, for unlocking more groups
    std::unique_ptr<Job> job;
    bool open_after = true, close_when_done = false, group_col = false;
    std::wstring idle_status;
    ITaskbarList3 *taskbar = nullptr;
    std::map<std::wstring, int> icons;
    std::map<std::wstring, std::wstring> types;
    int folder_icon = -1, folder_open_icon = -1;
    std::vector<Node> nodes;
    std::vector<Row> rows;
    std::vector<int> history;
    int cur = -1;
    int sort_col = 0;
    bool sort_desc = false, tree_sync = false;
    int split = 240;             // tree width at 96 DPI
    bool splitting = false;
} M;

// ---- the folder model

int child_dir(int parent, const std::wstring &name, const std::string &stored) {
    for (int c : M.nodes[(size_t)parent].dirs)
        if (M.nodes[(size_t)c].name == name) return c;
    Node n;
    n.name = name;
    n.stored = stored;
    n.parent = parent;
    M.nodes.push_back(n);
    int id = (int)M.nodes.size() - 1;
    M.nodes[(size_t)parent].dirs.push_back(id);
    return id;
}

std::wstring name_of(const Entry &e) {
    size_t p = e.stored.find_last_of('/');
    return wide(p == std::string::npos ? e.stored : e.stored.substr(p + 1));
}

bool name_less(const std::wstring &a, const std::wstring &b) {
    return CompareStringEx(LOCALE_NAME_USER_DEFAULT, LINGUISTIC_IGNORECASE | SORT_DIGITSASNUMBERS, a.c_str(), (int)a.size(), b.c_str(),
                           (int)b.size(), nullptr, nullptr, 0) == CSTR_LESS_THAN;
}

void build_nodes() {
    M.nodes.clear();
    M.history.clear();
    M.cur = -1;
    if (!M.ar) return;
    Node root;
    root.name = file_name(M.ar->path);
    M.nodes.push_back(root);
    for (size_t i = 0; i < M.ar->entries.size(); i++) {
        const Entry &e = M.ar->entries[i];
        int at = 0;
        size_t start = 0;
        for (;;) {
            size_t slash = e.stored.find('/', start);
            std::string comp = e.stored.substr(start, slash == std::string::npos ? std::string::npos : slash - start);
            bool last = slash == std::string::npos;
            if (comp.empty() || comp == ".") { if (last) break; start = slash + 1; continue; }
            std::string stored = e.stored.substr(0, last ? e.stored.size() : slash);
            if (last) {
                if (e.type == XIZ_TYPE_DIRECTORY) M.nodes[(size_t)child_dir(at, wide(comp), stored)].entry = (int)i;
                else M.nodes[(size_t)at].files.push_back(i);
                break;
            }
            at = child_dir(at, wide(comp), stored);
            start = slash + 1;
        }
    }
    for (auto &n : M.nodes)
        std::sort(n.dirs.begin(), n.dirs.end(), [](int a, int b) { return name_less(M.nodes[(size_t)a].name, M.nodes[(size_t)b].name); });
}

// ---- icons and type names (the system's, by extension)

std::wstring ext_of(const std::wstring &name) {
    size_t dot = name.find_last_of(L'.');
    std::wstring ext = dot == std::wstring::npos || dot == 0 ? L"" : name.substr(dot);
    CharLowerW(ext.data());
    return ext;
}

void load_folder_icons() {
    if (M.folder_icon >= 0) return;
    SHFILEINFOW fi{};
    if (SHGetFileInfoW(L"folder", FILE_ATTRIBUTE_DIRECTORY, &fi, sizeof fi, SHGFI_USEFILEATTRIBUTES | SHGFI_SYSICONINDEX | SHGFI_SMALLICON))
        M.folder_icon = fi.iIcon;
    if (SHGetFileInfoW(L"folder", FILE_ATTRIBUTE_DIRECTORY, &fi, sizeof fi,
                       SHGFI_USEFILEATTRIBUTES | SHGFI_SYSICONINDEX | SHGFI_SMALLICON | SHGFI_OPENICON))
        M.folder_open_icon = fi.iIcon;
    if (SHGetFileInfoW(L"folder", FILE_ATTRIBUTE_DIRECTORY, &fi, sizeof fi, SHGFI_USEFILEATTRIBUTES | SHGFI_TYPENAME))
        M.types[L"/"] = fi.szTypeName;
}

int file_icon(const std::wstring &name) {
    std::wstring ext = ext_of(name);
    auto it = M.icons.find(ext);
    if (it != M.icons.end()) return it->second;
    SHFILEINFOW fi{};
    int idx = 0;
    if (SHGetFileInfoW((L"x" + ext).c_str(), FILE_ATTRIBUTE_NORMAL, &fi, sizeof fi, SHGFI_USEFILEATTRIBUTES | SHGFI_SYSICONINDEX | SHGFI_SMALLICON))
        idx = fi.iIcon;
    M.icons[ext] = idx;
    return idx;
}

const std::wstring &type_name(const std::wstring &name, bool dir) {
    std::wstring key = dir ? L"/" : ext_of(name);
    auto it = M.types.find(key);
    if (it != M.types.end()) return it->second;
    SHFILEINFOW fi{};
    std::wstring t;
    if (SHGetFileInfoW((L"x" + key).c_str(), FILE_ATTRIBUTE_NORMAL, &fi, sizeof fi, SHGFI_USEFILEATTRIBUTES | SHGFI_TYPENAME)) t = fi.szTypeName;
    if (t.empty()) t = key.size() > 1 ? key.substr(1) : L"";
    return M.types[key] = t;
}

// ---- tree pane

HTREEITEM insert_node(HTREEITEM parent, int id) {
    Node &n = M.nodes[(size_t)id];
    TVINSERTSTRUCTW ins{};
    ins.hParent = parent;
    ins.hInsertAfter = TVI_LAST;
    ins.item.mask = TVIF_TEXT | TVIF_PARAM | TVIF_IMAGE | TVIF_SELECTEDIMAGE | TVIF_CHILDREN;
    ins.item.pszText = n.name.data();
    ins.item.lParam = id;
    ins.item.iImage = M.folder_icon;
    ins.item.iSelectedImage = M.folder_open_icon >= 0 ? M.folder_open_icon : M.folder_icon;
    ins.item.cChildren = n.dirs.empty() ? 0 : 1;
    n.item = (HTREEITEM)SendMessageW(M.tree, TVM_INSERTITEMW, 0, (LPARAM)&ins);
    return n.item;
}

void fill_node(int id) {
    Node &n = M.nodes[(size_t)id];
    if (n.filled) return;
    n.filled = true;
    for (int c : n.dirs) insert_node(n.item, c);
}

// Selects the folder in the tree, expanding its parents, without navigating again.
void select_in_tree(int id) {
    std::vector<int> chain;
    for (int x = id; x >= 0; x = M.nodes[(size_t)x].parent) chain.push_back(x);
    M.tree_sync = true;
    for (size_t i = chain.size(); i-- > 1;) {
        fill_node(chain[i]);
        TreeView_Expand(M.tree, M.nodes[(size_t)chain[i]].item, TVE_EXPAND);
    }
    if (M.nodes[(size_t)id].item) {
        TreeView_SelectItem(M.tree, M.nodes[(size_t)id].item);
        TreeView_EnsureVisible(M.tree, M.nodes[(size_t)id].item);
    }
    M.tree_sync = false;
}

// ---- list pane

int64_t row_mtime(const Row &r) {
    if (!r.dir) return M.ar->entries[r.idx].mtime;
    int e = M.nodes[r.idx].entry;
    return e >= 0 ? M.ar->entries[(size_t)e].mtime : 0;
}

std::wstring row_name(const Row &r) { return r.dir ? M.nodes[r.idx].name : name_of(M.ar->entries[r.idx]); }

void sort_rows() {
    auto less = [](const Row &a, const Row &b) {
        if (a.dir != b.dir) return a.dir;  // folders first, as in Explorer
        int c = 0;
        switch (M.sort_col) {
        case 1: if (!a.dir) { uint64_t x = M.ar->entries[a.idx].size, y = M.ar->entries[b.idx].size; c = x < y ? -1 : x > y; } break;
        case 2: {
            const std::wstring &x = type_name(row_name(a), a.dir), &y = type_name(row_name(b), b.dir);
            c = name_less(x, y) ? -1 : name_less(y, x) ? 1 : 0;
            break;
        }
        case 3: { int64_t x = row_mtime(a), y = row_mtime(b); c = x < y ? -1 : x > y; break; }
        case 4: if (!a.dir) c = (int)M.ar->entries[a.idx].group - (int)M.ar->entries[b.idx].group; break;
        }
        if (c == 0) {
            std::wstring x = row_name(a), y = row_name(b);
            c = name_less(x, y) ? -1 : name_less(y, x) ? 1 : 0;
            if (M.sort_col != 0) return c < 0;  // ties by name, always ascending
        }
        return M.sort_desc ? c > 0 : c < 0;
    };
    std::stable_sort(M.rows.begin(), M.rows.end(), less);
    // The sort arrow on the header.
    HWND hdr = ListView_GetHeader(M.list);
    for (int i = 0; i < Header_GetItemCount(hdr); i++) {
        HDITEMW it{};
        it.mask = HDI_FORMAT;
        Header_GetItem(hdr, i, &it);
        it.fmt &= ~(HDF_SORTUP | HDF_SORTDOWN);
        if (i == M.sort_col) it.fmt |= M.sort_desc ? HDF_SORTDOWN : HDF_SORTUP;
        Header_SetItem(hdr, i, &it);
    }
}

std::wstring address_of(int id) {
    std::wstring a = M.nodes[0].name;
    if (id > 0) {
        std::wstring s = wide(M.nodes[(size_t)id].stored);
        std::replace(s.begin(), s.end(), L'/', L'\\');
        a += L"\\" + s;
    }
    return a;
}

void update_nav() {
    EnableWindow(M.back, !M.job && !M.history.empty());
    EnableWindow(M.up, !M.job && M.cur > 0);
}

void navigate(int id, bool remember = true) {
    if (!M.ar || id < 0 || (size_t)id >= M.nodes.size()) return;
    if (remember && M.cur >= 0 && M.cur != id) M.history.push_back(M.cur);
    M.cur = id;
    const Node &n = M.nodes[(size_t)id];
    M.rows.clear();
    for (int d : n.dirs) M.rows.push_back({true, (size_t)d});
    for (size_t f : n.files) M.rows.push_back({false, f});
    sort_rows();
    ListView_SetItemState(M.list, -1, 0, LVIS_SELECTED | LVIS_FOCUSED);
    ListView_SetItemCountEx(M.list, (int)M.rows.size(), 0);
    if (!M.rows.empty()) ListView_SetItemState(M.list, 0, LVIS_FOCUSED, LVIS_FOCUSED);
    ListView_EnsureVisible(M.list, 0, FALSE);
    InvalidateRect(M.list, nullptr, TRUE);
    SetWindowTextW(M.addr, address_of(id).c_str());
    select_in_tree(id);
    update_nav();
    EnableWindow(M.buttons[B_EXTRACT_SEL], FALSE);
    EnableWindow(M.buttons[B_DELETE], FALSE);
}

// Opens a folder by its stored path ("a/b"), for /folder on the command line.
void navigate_to(const std::string &stored) {
    for (size_t i = 0; i < M.nodes.size(); i++)
        if (M.nodes[i].stored == stored) { navigate((int)i); return; }
}

void go_back() {
    if (M.history.empty()) return;
    int id = M.history.back();
    M.history.pop_back();
    navigate(id, false);
}

void go_up() {
    if (M.cur > 0) navigate(M.nodes[(size_t)M.cur].parent);
}

// ---- layout

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
    int ay = pad + bh + scale(6, M.dpi), ah = scale(24, M.dpi), nb = scale(30, M.dpi);
    MoveWindow(M.back, pad, ay, nb, ah, TRUE);
    MoveWindow(M.up, pad + nb + scale(4, M.dpi), ay, nb, ah, TRUE);
    int ax = pad + 2 * nb + scale(10, M.dpi);
    MoveWindow(M.addr, ax, ay, w - ax - pad, ah, TRUE);
    int top = ay + ah + scale(6, M.dpi), bottom_h = scale(30, M.dpi), body_h = h - top - bottom_h;
    int tw = std::min(std::max(scale(M.split, M.dpi), scale(120, M.dpi)), std::max(w - scale(200, M.dpi), scale(120, M.dpi)));
    int gap = scale(5, M.dpi);
    MoveWindow(M.tree, 0, top, tw, body_h, TRUE);
    MoveWindow(M.list, tw + gap, top, w - tw - gap, body_h, TRUE);
    // The Name column takes the width the others leave, as in Explorer: no horizontal scroll bar.
    int cols = Header_GetItemCount(ListView_GetHeader(M.list)), others = 0;
    for (int i = 1; i < cols; i++) others += ListView_GetColumnWidth(M.list, i);
    RECT lc;
    GetClientRect(M.list, &lc);
    int vs = (GetWindowLongPtrW(M.list, GWL_STYLE) & WS_VSCROLL) ? 0 : GetSystemMetricsForDpi(SM_CXVSCROLL, M.dpi);
    if (cols > 0) ListView_SetColumnWidth(M.list, 0, std::max(scale(140, M.dpi), (int)lc.right - others - vs));
    MoveWindow(M.empty, pad, top + body_h / 2 - scale(12, M.dpi), w - 2 * pad, scale(24, M.dpi), TRUE);
    int by = top + body_h + (bottom_h - scale(24, M.dpi)) / 2, cw = scale(90, M.dpi), pw = scale(220, M.dpi);
    MoveWindow(M.cancel, w - pad - cw, by, cw, scale(24, M.dpi), TRUE);
    MoveWindow(M.progress, w - pad - cw - scale(8, M.dpi) - pw, by + scale(4, M.dpi), pw, scale(16, M.dpi), TRUE);
    bool busy = M.job != nullptr;
    int sw = busy ? w - 3 * pad - cw - pw - scale(8, M.dpi) : w - 2 * pad;
    MoveWindow(M.status, pad, by + scale(4, M.dpi), sw, scale(20, M.dpi), TRUE);
}

// The vertical strip between the tree and the list, dragged to resize the tree.
bool on_splitter(int x, int y) {
    if (!M.ar) return false;
    RECT t, l;
    GetWindowRect(M.tree, &t);
    GetWindowRect(M.list, &l);
    MapWindowPoints(nullptr, M.wnd, reinterpret_cast<POINT *>(&t), 2);
    MapWindowPoints(nullptr, M.wnd, reinterpret_cast<POINT *>(&l), 2);
    return x >= t.right && x < l.left && y >= t.top && y < t.bottom;
}

// Appending and removing go through libxiz's writer: plain or password archives without a directory
// (no groups, keys, custodians, signatures) and without a second factor.
bool can_modify() {
    return M.ar && !M.ar->info.has_directory && M.creds.factors.empty() && M.creds.identities.empty() &&
           M.creds.pq_identities.empty() && !(M.ar->info.required_features & XIZ_FEATURE_FORENSIC);
}

void set_busy(bool busy, const wchar_t *what) {
    for (HWND b : M.buttons) EnableWindow(b, !busy && M.ar);
    EnableWindow(M.buttons[B_NEW], !busy);
    EnableWindow(M.buttons[B_OPEN], !busy);
    bool sel = M.ar && ListView_GetSelectedCount(M.list) > 0;
    EnableWindow(M.buttons[B_EXTRACT_SEL], !busy && sel);
    EnableWindow(M.buttons[B_ADD], !busy && can_modify());
    EnableWindow(M.buttons[B_DELETE], !busy && sel && can_modify());
    HMENU menu = GetMenu(M.wnd);
    for (int id : {ID_OPEN, ID_EXTRACT, ID_EXTRACT_SEL, ID_VERIFY, ID_PROPS, ID_PROOF, ID_NEW})
        EnableMenuItem(menu, (UINT)id, MF_BYCOMMAND | ((!busy && (M.ar || id == ID_OPEN || id == ID_PROOF || id == ID_NEW)) ? MF_ENABLED : MF_GRAYED));
    for (int id : {ID_ADD, ID_ADDDIR}) EnableMenuItem(menu, (UINT)id, MF_BYCOMMAND | (!busy && can_modify() ? MF_ENABLED : MF_GRAYED));
    EnableMenuItem(menu, ID_DELETE, MF_BYCOMMAND | (!busy && sel && can_modify() ? MF_ENABLED : MF_GRAYED));
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
    update_nav();
    layout();
}

void show_archive() {
    bool has = M.ar != nullptr;
    for (HWND c : {M.tree, M.list, M.addr, M.back, M.up}) ShowWindow(c, has ? SW_SHOW : SW_HIDE);
    ShowWindow(M.empty, has ? SW_HIDE : SW_SHOW);
    bool want_group = has && M.ar->info.has_directory && xiz_group_count(M.ar->a) > 1;
    if (want_group != M.group_col) {
        if (want_group) {
            LVCOLUMNW c{};
            c.mask = LVCF_TEXT | LVCF_WIDTH;
            c.pszText = const_cast<wchar_t *>(T(S::ColGroup));
            c.cx = scale(140, M.dpi);
            ListView_InsertColumn(M.list, 4, &c);
        } else {
            ListView_DeleteColumn(M.list, 4);
            if (M.sort_col == 4) M.sort_col = 0;
        }
        M.group_col = want_group;
    }
    TreeView_DeleteAllItems(M.tree);
    ListView_SetItemCountEx(M.list, 0, 0);
    build_nodes();
    if (has) {
        const xiz_info &i = M.ar->info;
        M.idle_status = fmt(S::Summary, (unsigned long long)M.ar->entries.size(), byte_size(M.ar->bytes).c_str());
        if (i.encrypted) M.idle_status += std::wstring(L" \x2022 ") + T(S::Encrypted);
        M.idle_status += vfmt(L" \x2022 XIZ %u.%u", (unsigned)i.version_major, (unsigned)i.version_minor);
        if (i.hidden_groups) M.idle_status += L" \x2022 " + fmt(S::HiddenGroups, (unsigned)i.hidden_groups);
        SetWindowTextW(M.wnd, (file_name(M.ar->path) + L" \x2014 " + T(S::AppName)).c_str());
        load_folder_icons();
        insert_node(TVI_ROOT, 0);
        // Straight into the only folder when the archive holds just one (Xipper's usual layout).
        int start = 0;
        fill_node(0);
        TreeView_Expand(M.tree, M.nodes[0].item, TVE_EXPAND);
        if (M.nodes[0].dirs.size() == 1 && M.nodes[0].files.empty()) start = M.nodes[0].dirs[0];
        navigate(start, false);
        fill_node(start);
        TreeView_Expand(M.tree, M.nodes[(size_t)start].item, TVE_EXPAND);
    } else {
        M.idle_status.clear();
        SetWindowTextW(M.wnd, T(S::AppName));
    }
    set_busy(false, nullptr);
}

// While an update rewrites the archive: the panes stay, empty; the title and folder are kept.
std::string g_reopen_folder;
std::wstring g_reopen_path;

void show_archive_busy() {
    g_reopen_folder = M.cur > 0 && (size_t)M.cur < M.nodes.size() ? M.nodes[(size_t)M.cur].stored : "";
    ListView_SetItemCountEx(M.list, 0, 0);
    TreeView_DeleteAllItems(M.tree);
    M.rows.clear();
    M.nodes.clear();
    M.cur = -1;
}

// After an update: the same archive with the same credentials, at the same folder.
void reopen(const std::wstring &path) {
    auto ar = std::make_unique<Archive>();
    xiz_error err{};
    int rc = open_archive(path, M.creds, *ar, &err);
    if (rc != XIZ_OK) {
        show_archive();
        task_dialog(M.wnd, TD_ERROR_ICON, T(S::FailTitle), open_error(path, rc, err));
        return;
    }
    M.ar = std::move(ar);
    show_archive();
    if (!g_reopen_folder.empty()) navigate_to(g_reopen_folder);
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

std::string row_stored(const Row &r) { return r.dir ? M.nodes[r.idx].stored : M.ar->entries[r.idx].stored; }

std::vector<std::string> selected_paths() {
    std::vector<std::string> sel;
    for (int i = -1; (i = ListView_GetNextItem(M.list, i, LVNI_SELECTED)) >= 0;)
        if ((size_t)i < M.rows.size()) sel.push_back(row_stored(M.rows[(size_t)i]));
    return sel;
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
            j->select = selected_paths();
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

void start_create(const std::vector<std::wstring> &sources) {
    if (M.job) return;
    auto j = std::make_unique<Job>();
    if (!ask_new(M.wnd, sources, *j)) return;
    j->notify = M.wnd;
    M.job = std::move(j);
    set_busy(true, T(S::Creating));
    start_job(*M.job);
}

// Adds files and folders into the open folder, or removes entries: an appended segment (§11).
void start_update(const std::vector<std::wstring> &sources, const std::vector<std::string> &remove) {
    if (M.job || !can_modify() || (sources.empty() && remove.empty())) return;
    auto j = std::make_unique<Job>();
    j->kind = Job::Update;
    j->notify = M.wnd;
    j->path = M.ar->path;
    j->sources = sources;
    j->remove = remove;
    j->prefix = M.cur > 0 ? M.nodes[(size_t)M.cur].stored : "";
    if (!M.creds.passwords.empty()) j->password = M.creds.passwords[0];
    M.job = std::move(j);
    // The archive is rewritten: its handle (and the list) wait until it is open again.
    M.ar.reset();
    show_archive_busy();
    set_busy(true, T(S::Updating));
    start_job(*M.job);
}

void delete_selection() {
    if (!can_modify() || M.job) return;
    std::vector<std::string> sel = selected_paths();
    if (sel.empty()) return;
    TASKDIALOG_BUTTON b[] = {{600, T(S::DeleteBtn)}};
    if (task_dialog(M.wnd, TD_WARNING_ICON, fmt(S::DeleteConfirm, (unsigned long long)sel.size(), file_name(M.ar->path).c_str()),
                    T(S::DeleteNote), {}, b, 1, TDCBF_CANCEL_BUTTON) != 600)
        return;
    start_update({}, sel);
}

void add_columns() {
    LVCOLUMNW c{};
    c.mask = LVCF_TEXT | LVCF_WIDTH | LVCF_FMT;
    const S names[] = {S::ColName, S::ColSize, S::ColType, S::ColModified};
    const int widths[] = {300, 90, 150, 140};
    for (int i = 0; i < 4; i++) {
        c.pszText = const_cast<wchar_t *>(T(names[i]));
        c.cx = scale(widths[i], M.dpi);
        c.fmt = i == 1 ? LVCFMT_RIGHT : LVCFMT_LEFT;
        ListView_InsertColumn(M.list, i, &c);
    }
}

// Double-click or Enter: a folder opens in the window; a file is extracted to a temporary folder
// and opened with its program.
void open_item(int index) {
    if (index < 0 || (size_t)index >= M.rows.size()) return;
    const Row r = M.rows[(size_t)index];
    if (r.dir) { navigate((int)r.idx); return; }
    const Entry &e = M.ar->entries[r.idx];
    if (e.type != XIZ_TYPE_FILE) return;
    SetCursor(LoadCursorW(nullptr, IDC_WAIT));
    SetWindowTextW(M.status, T(S::Preparing));
    UpdateWindow(M.status);
    std::wstring dir, error;
    std::vector<std::wstring> paths;
    bool ok = extract_temp(M.ar->a, M.ar->zone, {e.stored}, dir, paths, error);
    SetWindowTextW(M.status, M.idle_status.c_str());
    SetCursor(LoadCursorW(nullptr, IDC_ARROW));
    if (!ok) { task_dialog(M.wnd, TD_ERROR_ICON, T(S::FailTitle), error); return; }
    ShellExecuteW(M.wnd, nullptr, paths[0].c_str(), nullptr, dir.c_str(), SW_SHOWNORMAL);
}

HMENU build_menu() {
    HMENU bar = CreateMenu(), file = CreatePopupMenu(), help = CreatePopupMenu();
    AppendMenuW(file, MF_STRING, ID_NEW, T(S::MenuNew));
    AppendMenuW(file, MF_STRING, ID_OPEN, T(S::MenuOpen));
    AppendMenuW(file, MF_STRING, ID_EXTRACT, T(S::MenuExtract));
    AppendMenuW(file, MF_STRING, ID_EXTRACT_SEL, T(S::MenuExtractSel));
    AppendMenuW(file, MF_STRING, ID_VERIFY, T(S::MenuVerify));
    AppendMenuW(file, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(file, MF_STRING, ID_ADD, T(S::MenuAddFiles));
    AppendMenuW(file, MF_STRING, ID_ADDDIR, T(S::MenuAddFolder));
    AppendMenuW(file, MF_STRING, ID_DELETE, T(S::MenuDelete));
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
    case ID_BACK: if (!M.job) go_back(); break;
    case ID_NEW: start_create({}); break;
    case ID_ADD:
    case ID_ADDDIR: {
        if (!can_modify()) {
            if (M.ar) task_dialog(M.wnd, TD_INFORMATION_ICON, T(S::CantModify), L"");
            break;
        }
        std::vector<std::wstring> more;
        if (pick_many(M.wnd, id == ID_ADDDIR, more)) start_update(more, {});
        break;
    }
    case ID_DELETE: delete_selection(); break;
    case ID_UP: if (!M.job) go_up(); break;
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

void add_tip(HWND control, S text) {
    TTTOOLINFOW ti{};
    ti.cbSize = sizeof ti;
    ti.uFlags = TTF_IDISHWND | TTF_SUBCLASS;
    ti.hwnd = M.wnd;
    ti.uId = (UINT_PTR)control;
    ti.lpszText = const_cast<wchar_t *>(T(text));
    SendMessageW(M.tips, TTM_ADDTOOLW, 0, (LPARAM)&ti);
}

LRESULT CALLBACK main_proc(HWND w, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE: {
        M.wnd = w;
        M.dpi = dpi_of(w);
        M.font = make_font(M.dpi);
        const S labels[] = {S::NewArchive, S::Open, S::ExtractAll, S::ExtractSel, S::Verify, S::AddBtn, S::DeleteBtn};
        const int ids[] = {ID_NEW, ID_OPEN, ID_EXTRACT, ID_EXTRACT_SEL, ID_VERIFY, ID_ADD, ID_DELETE};
        for (int i = 0; i < 7; i++)
            M.buttons[i] = CreateWindowW(L"BUTTON", T(labels[i]), WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 0, 0, w,
                                         (HMENU)(INT_PTR)ids[i], g_inst, nullptr);
        M.back = CreateWindowW(L"BUTTON", L"\x2190", WS_CHILD | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 0, 0, w, (HMENU)(INT_PTR)ID_BACK, g_inst, nullptr);
        M.up = CreateWindowW(L"BUTTON", L"\x2191", WS_CHILD | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 0, 0, w, (HMENU)(INT_PTR)ID_UP, g_inst, nullptr);
        M.addr = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"", WS_CHILD | ES_READONLY | ES_AUTOHSCROLL, 0, 0, 0, 0, w, nullptr, g_inst, nullptr);
        M.tree = CreateWindowExW(0, WC_TREEVIEWW, L"", WS_CHILD | WS_TABSTOP | WS_BORDER | TVS_HASBUTTONS | TVS_LINESATROOT | TVS_SHOWSELALWAYS |
                                 TVS_TRACKSELECT | TVS_FULLROWSELECT, 0, 0, 0, 0, w, (HMENU)(INT_PTR)ID_TREE, g_inst, nullptr);
        SetWindowTheme(M.tree, L"Explorer", nullptr);
        M.list = CreateWindowExW(0, WC_LISTVIEWW, L"", WS_CHILD | WS_TABSTOP | WS_BORDER | LVS_REPORT | LVS_OWNERDATA | LVS_SHOWSELALWAYS |
                                 LVS_SHAREIMAGELISTS, 0, 0, 0, 0, w, (HMENU)(INT_PTR)ID_LIST, g_inst, nullptr);
        SetWindowTheme(M.list, L"Explorer", nullptr);
        ListView_SetExtendedListViewStyle(M.list, LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER);
        SHFILEINFOW fi{};
        auto sys = (HIMAGELIST)SHGetFileInfoW(L"", 0, &fi, sizeof fi, SHGFI_SYSICONINDEX | SHGFI_SMALLICON);
        if (sys) {
            ListView_SetImageList(M.list, sys, LVSIL_SMALL);
            TreeView_SetImageList(M.tree, sys, TVSIL_NORMAL);
        }
        add_columns();
        M.empty = CreateWindowW(L"STATIC", T(S::Empty), WS_CHILD | WS_VISIBLE | SS_CENTER, 0, 0, 0, 0, w, nullptr, g_inst, nullptr);
        M.status = CreateWindowW(L"STATIC", L"", WS_CHILD | WS_VISIBLE | SS_LEFT | SS_ENDELLIPSIS | SS_NOPREFIX, 0, 0, 0, 0, w, nullptr, g_inst, nullptr);
        M.progress = CreateWindowW(PROGRESS_CLASSW, L"", WS_CHILD, 0, 0, 0, 0, w, nullptr, g_inst, nullptr);
        SendMessageW(M.progress, PBM_SETRANGE32, 0, 1000);
        M.cancel = CreateWindowW(L"BUTTON", T(S::Cancel), WS_CHILD | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 0, 0, w,
                                 (HMENU)(INT_PTR)ID_CANCEL, g_inst, nullptr);
        M.tips = CreateWindowExW(WS_EX_TOPMOST, TOOLTIPS_CLASSW, nullptr, WS_POPUP | TTS_ALWAYSTIP, 0, 0, 0, 0, w, nullptr, g_inst, nullptr);
        add_tip(M.back, S::Back);
        add_tip(M.up, S::Up);
        set_font_all(w, M.font);
        DragAcceptFiles(w, TRUE);
        show_archive();
        return 0;
    }
    case WM_SIZE: layout(); return 0;
    case WM_GETMINMAXINFO: {
        auto *mm = reinterpret_cast<MINMAXINFO *>(lp);
        mm->ptMinTrackSize = {scale(560, M.dpi), scale(340, M.dpi)};
        return 0;
    }
    case WM_DPICHANGED: {
        UINT old = M.dpi;
        M.dpi = HIWORD(wp);
        HFONT f = make_font(M.dpi);
        set_font_all(w, f);
        if (M.font) DeleteObject(M.font);
        M.font = f;
        int cols = Header_GetItemCount(ListView_GetHeader(M.list));
        for (int i = 0; i < cols; i++) ListView_SetColumnWidth(M.list, i, MulDiv(ListView_GetColumnWidth(M.list, i), (int)M.dpi, (int)old));
        auto *r = reinterpret_cast<RECT *>(lp);
        SetWindowPos(w, nullptr, r->left, r->top, r->right - r->left, r->bottom - r->top, SWP_NOZORDER | SWP_NOACTIVATE);
        layout();
        return 0;
    }
    case WM_SETCURSOR: {
        POINT p;
        GetCursorPos(&p);
        ScreenToClient(w, &p);
        if ((HWND)wp == w && on_splitter(p.x, p.y)) { SetCursor(LoadCursorW(nullptr, IDC_SIZEWE)); return TRUE; }
        break;
    }
    case WM_LBUTTONDOWN:
        if (on_splitter((short)LOWORD(lp), (short)HIWORD(lp))) { M.splitting = true; SetCapture(w); }
        return 0;
    case WM_MOUSEMOVE:
        if (M.splitting) {
            M.split = std::max(80, MulDiv((short)LOWORD(lp), 96, (int)M.dpi));
            layout();
        }
        return 0;
    case WM_LBUTTONUP:
        if (M.splitting) { M.splitting = false; ReleaseCapture(); }
        return 0;
    case WM_COMMAND: command(LOWORD(wp)); return 0;
    case WM_DROPFILES: {
        // One .xiz: open it. Other files on an open archive: add them to the open folder.
        // Otherwise: a new archive with them.
        auto drop = (HDROP)wp;
        std::vector<std::wstring> files;
        UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
        for (UINT i = 0; i < count; i++) {
            UINT n = DragQueryFileW(drop, i, nullptr, 0);
            std::wstring p((size_t)n + 1, L'\0');
            DragQueryFileW(drop, i, p.data(), n + 1);
            p.resize(n);
            files.push_back(p);
        }
        DragFinish(drop);
        if (files.empty() || M.job) return 0;
        bool one_xiz = files.size() == 1 && files[0].size() > 4 && _wcsicmp(files[0].c_str() + files[0].size() - 4, L".xiz") == 0;
        if (one_xiz) open_path(files[0]);
        else if (can_modify()) start_update(files, {});
        else start_create(files);
        return 0;
    }
    case WM_NOTIFY: {
        auto *h = reinterpret_cast<NMHDR *>(lp);
        if (h->idFrom == ID_TREE && M.ar) {
            if (h->code == TVN_ITEMEXPANDINGW) {
                auto *t = reinterpret_cast<NMTREEVIEWW *>(lp);
                if (t->action & TVE_EXPAND) fill_node((int)t->itemNew.lParam);
                return 0;
            }
            if (h->code == TVN_SELCHANGEDW && !M.tree_sync && !M.job) {
                auto *t = reinterpret_cast<NMTREEVIEWW *>(lp);
                if ((int)t->itemNew.lParam != M.cur) navigate((int)t->itemNew.lParam);
                return 0;
            }
            break;
        }
        if (h->idFrom == ID_LIST && h->code == LVN_GETDISPINFOW && M.ar) {
            auto *d = reinterpret_cast<NMLVDISPINFOW *>(lp);
            if (d->item.iItem < 0 || (size_t)d->item.iItem >= M.rows.size()) return 0;
            const Row &r = M.rows[(size_t)d->item.iItem];
            std::wstring name = row_name(r);
            if (d->item.mask & LVIF_IMAGE) d->item.iImage = r.dir ? M.folder_icon : file_icon(name);
            if (d->item.mask & LVIF_TEXT) {
                static std::wstring text;
                switch (d->item.iSubItem) {
                case 0: text = name; break;
                case 1: text = r.dir ? L"" : byte_size(M.ar->entries[r.idx].size); break;
                case 2: text = type_name(name, r.dir); break;
                case 3: { int64_t t = row_mtime(r); text = t ? date_time(t) : L""; break; }
                default: {
                    int e = r.dir ? M.nodes[r.idx].entry : (int)r.idx;
                    text = e >= 0 ? group_name(M.ar->a, M.ar->entries[(size_t)e].group) : L"";
                }
                }
                lstrcpynW(d->item.pszText, text.c_str(), d->item.cchTextMax);
            }
            return 0;
        }
        if (h->idFrom == ID_LIST && h->code == LVN_COLUMNCLICK && M.ar) {
            int col = reinterpret_cast<NMLISTVIEW *>(lp)->iSubItem;
            M.sort_desc = col == M.sort_col ? !M.sort_desc : false;
            M.sort_col = col;
            sort_rows();
            ListView_SetItemState(M.list, -1, 0, LVIS_SELECTED);
            InvalidateRect(M.list, nullptr, TRUE);
            return 0;
        }
        if (h->idFrom == ID_LIST && h->code == LVN_ITEMACTIVATE && M.ar && !M.job) {
            open_item(ListView_GetNextItem(M.list, -1, LVNI_FOCUSED));
            return 0;
        }
        if (h->idFrom == ID_LIST && h->code == LVN_KEYDOWN && M.ar && !M.job) {
            WORD key = reinterpret_cast<NMLVKEYDOWN *>(lp)->wVKey;
            if (key == VK_BACK) go_up();
            else if (key == VK_DELETE) command(ID_DELETE);
            return 0;
        }
        if (h->idFrom == ID_LIST && h->code == LVN_BEGINDRAG && M.ar && !M.job) {
            std::vector<std::string> sel = selected_paths();
            if (!sel.empty())
                drag_out(M.ar->a, M.ar->zone, sel, [](bool b) {
                    SetCursor(LoadCursorW(nullptr, b ? IDC_WAIT : IDC_ARROW));
                    SetWindowTextW(M.status, b ? T(S::Preparing) : M.idle_status.c_str());
                    UpdateWindow(M.status);
                });
            return 0;
        }
        if (h->idFrom == ID_LIST && h->code == LVN_ITEMCHANGED) {
            bool sel = !M.job && ListView_GetSelectedCount(M.list) > 0;
            EnableWindow(M.buttons[B_EXTRACT_SEL], sel);
            EnableWindow(M.buttons[B_DELETE], sel && can_modify());
            EnableMenuItem(GetMenu(M.wnd), ID_DELETE, MF_BYCOMMAND | (sel && can_modify() ? MF_ENABLED : MF_GRAYED));
        }
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
        else if (next == NEXT_OPEN_CREATED) open_path(j->path);
        else if (j->kind == Job::Update) reopen(j->path);  // also after an error: the append was undone
        return 0;
    }
    case WM_CLOSE:
        if (M.job) { M.job->cancel = true; M.close_when_done = true; return 0; }
        DestroyWindow(w);
        return 0;
    case WM_DESTROY:
        M.ar.reset();
        clean_temp();
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
    std::wstring mode, archive, dest, log, folder;
    std::vector<std::wstring> sources, entries;  // /src, /entry (repeatable)
    int level = 9;
    bool strong = false, recovery = false;
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

// Runs a job: quietly, or in the small progress window (the command-line modes, Explorer's verbs).
int run_progress(Job &j, bool interactive, const std::wstring &archive, bool open_after) {
    int code;
    if (!interactive) {
        run_job(j);
        return exit_code(j);
    }
    P.job = &j;
    P.open_after = open_after;
    UINT dpi = GetDpiForSystem();
    RECT r{0, 0, scale(420, dpi), scale(120, dpi)};
    AdjustWindowRectExForDpi(&r, WS_CAPTION | WS_SYSMENU, FALSE, 0, dpi);
    HWND w = CreateWindowExW(0, kProgressClass, T(S::AppName), WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX, CW_USEDEFAULT, CW_USEDEFAULT,
                             r.right - r.left, r.bottom - r.top, nullptr, nullptr, g_inst, nullptr);
    S what = j.kind == Job::Test ? S::Verifying : j.kind == Job::Repair ? S::Repairing : j.kind == Job::Create ? S::Creating
             : j.kind == Job::Update ? S::Updating : S::Working;
    SetWindowTextW(P.label, (std::wstring(T(what)) + L" " + file_name(archive)).c_str());
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
    return code;
}

// /create (Explorer's "Add to an XIZ archive…"), /new, /append, /remove.
int run_write(const Args &a, Credentials &c, bool interactive) {
    Job j;
    if (a.mode == L"/create") {
        if (!ask_new(nullptr, a.sources, j)) return EXIT_CANCELLED;
    } else if (a.mode == L"/new") {
        j.kind = Job::Create;
        j.path = a.archive;
        j.sources = a.sources;
        j.level = a.level;
        if (!c.passwords.empty()) j.password = c.passwords[0];
        j.strong = a.strong;
        j.recovery = a.recovery;
    } else {
        j.kind = Job::Update;
        j.path = a.archive;
        j.sources = a.sources;
        j.prefix = utf8(a.folder);
        for (auto &e : a.entries) j.remove.push_back(utf8(e));
        if (!c.passwords.empty()) j.password = c.passwords[0];
    }
    c.wipe();
    int code = run_progress(j, interactive, j.path, false);
    write_log(a.log, job_log(j, code));
    return code;
}

int run_command(const Args &a) {
    bool interactive = !a.quiet;
    if (a.mode == L"/register" || a.mode == L"/unregister") {
        bool ok = a.mode == L"/register" ? register_association() : unregister_association();
        if (interactive) task_dialog(nullptr, TD_INFORMATION_ICON, T(a.mode == L"/register" ? S::Associated : S::Unassociated), L"");
        return ok ? EXIT_OK : EXIT_ERROR;
    }
    if (a.archive.empty() && a.mode != L"/create") {
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
    if (a.mode == L"/create" || a.mode == L"/new" || a.mode == L"/append" || a.mode == L"/remove") {
        Credentials cw = c;
        c.wipe();
        return run_write(a, cw, interactive);
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
    if (a.mode == L"/temp-extract") {  // tests: what a double-click or a drag would produce
        std::wstring dir, error;
        std::vector<std::wstring> paths;
        bool ok = extract_temp(ar.a, ar.zone, {utf8(a.dest)}, dir, paths, error);
        std::string log = std::string("exit ") + (ok ? "0" : "1") + "\n";
        for (auto &p : paths) log += "path " + utf8(p) + "\n";
        if (!ok) log += "error " + utf8(error) + "\n";
        write_log(a.log, log);
        clean_temp();
        log = "";
        for (auto &p : paths) log += GetFileAttributesW(p.c_str()) == INVALID_FILE_ATTRIBUTES ? "" : "left " + utf8(p) + "\n";
        if (!log.empty()) write_log(a.log + L".left", log);
        return ok ? EXIT_OK : EXIT_ERROR;
    }
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
    int code = run_progress(j, interactive, a.archive, open_after);
    write_log(a.log, job_log(j, code));
    return code;
}

// Explorer starts one process per selected item for a static verb ("Add to an XIZ archive…"):
// the first one waits half a second for the others, which hand it their paths and exit.
std::vector<std::wstring> g_collected;

LRESULT CALLBACK collect_proc(HWND w, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_COPYDATA) {
        auto *cd = reinterpret_cast<COPYDATASTRUCT *>(lp);
        if (cd->dwData == 1 && cd->cbData >= sizeof(wchar_t))
            g_collected.emplace_back(static_cast<const wchar_t *>(cd->lpData), cd->cbData / sizeof(wchar_t) - 1);
        return TRUE;
    }
    return DefWindowProcW(w, msg, wp, lp);
}

// True when this process should go on (it collected the others' paths into `sources`).
bool collect_sources(std::vector<std::wstring> &sources) {
    HANDLE mx = CreateMutexW(nullptr, FALSE, L"Local\\XipperXIZ.create");
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        for (int i = 0; i < 30; i++) {
            HWND c = FindWindowExW(HWND_MESSAGE, nullptr, kCollectClass, nullptr);
            if (c) {
                for (auto &p : sources) {
                    COPYDATASTRUCT cd{1, (DWORD)((p.size() + 1) * sizeof(wchar_t)), const_cast<wchar_t *>(p.c_str())};
                    SendMessageW(c, WM_COPYDATA, 0, (LPARAM)&cd);
                }
                CloseHandle(mx);
                return false;
            }
            Sleep(100);
        }
        CloseHandle(mx);
        return true;  // nobody collecting: go on alone
    }
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof wc;
    wc.hInstance = g_inst;
    wc.lpfnWndProc = collect_proc;
    wc.lpszClassName = kCollectClass;
    RegisterClassExW(&wc);
    HWND w = CreateWindowExW(0, kCollectClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, g_inst, nullptr);
    ULONGLONG until = GetTickCount64() + 600;
    MSG m;
    while (GetTickCount64() < until) {
        MsgWaitForMultipleObjects(0, nullptr, FALSE, 50, QS_ALLINPUT);
        while (PeekMessageW(&m, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&m);
    }
    DestroyWindow(w);
    CloseHandle(mx);  // later selections start a new group
    for (auto &p : g_collected)
        if (std::find(sources.begin(), sources.end(), p) == sources.end()) sources.push_back(p);
    return true;
}

}  // namespace

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int show) {
    g_inst = inst;
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    OleInitialize(nullptr);  // COM, plus OLE drag and drop
    INITCOMMONCONTROLSEX icc{sizeof icc, ICC_LISTVIEW_CLASSES | ICC_TREEVIEW_CLASSES | ICC_PROGRESS_CLASS | ICC_STANDARD_CLASSES | ICC_BAR_CLASSES};
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
        if (s == L"/x" || s == L"/xto" || s == L"/t" || s == L"/repair" || s == L"/info" || s == L"/temp-extract") { a.mode = s; next(a.archive); }
        else if (s == L"/register" || s == L"/unregister") a.mode = s;
        else if (s == L"/d") next(a.dest);
        else if (s == L"/passenv") { std::wstring v; next(v); a.passenv.push_back(v); }
        else if (s == L"/factor" || s == L"/identity") { std::wstring v; next(v); a.keys.push_back(v); }
        else if (s == L"/log") next(a.log);
        else if (s == L"/folder") next(a.folder);
        else if (s == L"/src") { std::wstring v; next(v); a.sources.push_back(v); }
        else if (s == L"/entry") { std::wstring v; next(v); a.entries.push_back(v); }
        else if (s == L"/level") { std::wstring v; next(v); a.level = _wtoi(v.c_str()); }
        else if (s == L"/strong") a.strong = true;
        else if (s == L"/recovery") a.recovery = true;
        else if (s == L"/new" || s == L"/append" || s == L"/remove") { a.mode = s; next(a.archive); }
        else if (s == L"/create") { a.mode = s; std::wstring v; next(v); if (!v.empty()) a.sources.push_back(v); }
        else if (s == L"/quiet") a.quiet = true;
        else if (s == L"/keep-both") a.keep_both = true;
        else if (s == L"/?" || s == L"/help") a.mode = L"/help";
        else if (first.empty()) first = s;
    }
    LocalFree(argv);
    if (a.mode == L"/create" && !a.quiet && !collect_sources(a.sources)) {
        OleUninitialize();
        return EXIT_OK;
    }
    if (!a.mode.empty()) {
        int code = run_command(a);
        OleUninitialize();
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
    if (!a.folder.empty()) navigate_to(utf8(a.folder));

    ACCEL acc[] = {{FCONTROL | FVIRTKEY, 'O', ID_OPEN}, {FCONTROL | FVIRTKEY, 'E', ID_EXTRACT}, {FCONTROL | FVIRTKEY, 'T', ID_VERIFY},
                   {FALT | FVIRTKEY, VK_RETURN, ID_PROPS}, {FALT | FVIRTKEY, VK_LEFT, ID_BACK}, {FALT | FVIRTKEY, VK_UP, ID_UP},
                   {FCONTROL | FVIRTKEY, 'N', ID_NEW}};
    HACCEL accel = CreateAcceleratorTableW(acc, 7);
    MSG m;
    while (GetMessageW(&m, nullptr, 0, 0) > 0) {
        if (!TranslateAcceleratorW(w, accel, &m)) {
            TranslateMessage(&m);
            DispatchMessageW(&m);
        }
    }
    DestroyAcceleratorTable(accel);
    if (M.taskbar) M.taskbar->Release();
    OleUninitialize();
    return 0;
}
