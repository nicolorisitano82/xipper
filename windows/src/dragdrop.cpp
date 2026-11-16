// Files out of the archive: double-click opens one with its program, dragging copies the selection
// to Explorer. Both extract to a private temporary folder first (with the archive's Mark of the
// Web), as Explorer's own ZIP folders do; a drag extracts only when it is dropped (CF_HDROP
// rendered on demand).

#include "dragdrop.h"

#include <shellapi.h>
#include <shlobj.h>
#include <shlwapi.h>

#include <algorithm>
#include <atomic>
#include <set>

namespace {

std::wstring temp_root() {
    wchar_t t[MAX_PATH + 1];
    DWORD n = GetTempPathW(MAX_PATH + 1, t);
    std::wstring r = n ? std::wstring(t, n) : L".\\";
    return r + L"XipperXIZ";
}

std::wstring new_temp_dir() {
    static std::atomic<unsigned> counter{0};
    std::wstring d = temp_root() + L"\\" + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(++counter);
    SHCreateDirectoryExW(nullptr, d.c_str(), nullptr);
    return d;
}

// The selected entries without those already inside a selected folder.
std::vector<std::string> top_level(std::vector<std::string> sel) {
    std::sort(sel.begin(), sel.end());
    std::vector<std::string> out;
    for (auto &s : sel) {
        bool inside = false;
        for (auto &o : out)
            if (s.size() > o.size() && s.compare(0, o.size(), o) == 0 && s[o.size()] == '/') { inside = true; break; }
        if (!inside) out.push_back(s);
    }
    return out;
}

std::wstring on_disk(const std::string &stored) {
    std::wstring w = wide(stored);
    std::replace(w.begin(), w.end(), L'/', L'\\');
    // As libxiz names it on Windows (invalid characters, device names).
    std::wstring out;
    size_t start = 0;
    while (start <= w.size()) {
        size_t end = w.find(L'\\', start);
        if (end == std::wstring::npos) end = w.size();
        std::string comp = utf8(w.substr(start, end - start));
        if (!comp.empty()) {
            char nm[1024];
            size_t l = xiz_windows_name(comp.c_str(), comp.size(), nm, sizeof nm);
            if (!out.empty()) out += L"\\";
            out += wide(nm, l);
        }
        start = end + 1;
    }
    return out;
}

}  // namespace

bool extract_temp(xiz_archive *a, const std::string &zone, const std::vector<std::string> &select, std::wstring &dir,
                  std::vector<std::wstring> &paths, std::wstring &error) {
    Job j;
    j.kind = Job::Extract;
    j.a = a;
    j.zone = zone;
    j.dest = new_temp_dir();
    j.select = select;
    run_job(j);
    dir = j.dest;
    if (j.rc != XIZ_OK) {
        error = wide(j.err.message, strlen(j.err.message));
        return false;
    }
    paths.clear();
    for (auto &s : top_level(select)) {
        std::wstring p = dir + L"\\" + on_disk(s);
        if (GetFileAttributesW(p.c_str()) != INVALID_FILE_ATTRIBUTES) paths.push_back(p);
    }
    if (paths.empty() && !j.problems.empty()) error = j.problems.front();
    return !paths.empty();
}

void clean_temp() {
    std::wstring prefix = std::to_wstring(GetCurrentProcessId()) + L"-";
    std::wstring root = temp_root();
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW((root + L"\\" + prefix + L"*").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do {
        std::wstring p = root + L"\\" + fd.cFileName;
        p.push_back(L'\0');  // SHFileOperation wants a double NUL
        SHFILEOPSTRUCTW op{};
        op.wFunc = FO_DELETE;
        op.pFrom = p.c_str();
        op.fFlags = FOF_NO_UI;
        SHFileOperationW(&op);  // files still open in another program stay
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    RemoveDirectoryW(root.c_str());  // only when empty
}

// ---------------------------------------------------------------- drag source

namespace {

class DropSource final : public IDropSource {
    LONG refs_ = 1;
public:
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **out) override {
        if (riid == IID_IUnknown || riid == IID_IDropSource) { *out = this; AddRef(); return S_OK; }
        *out = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return (ULONG)InterlockedIncrement(&refs_); }
    ULONG STDMETHODCALLTYPE Release() override {
        LONG r = InterlockedDecrement(&refs_);
        if (!r) delete this;
        return (ULONG)r;
    }
    HRESULT STDMETHODCALLTYPE QueryContinueDrag(BOOL escape, DWORD keys) override {
        if (escape) return DRAGDROP_S_CANCEL;
        if (!(keys & (MK_LBUTTON | MK_RBUTTON))) return DRAGDROP_S_DROP;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GiveFeedback(DWORD) override { return DRAGDROP_S_USEDEFAULTCURSORS; }
};

// Offers CF_HDROP; the files are extracted the first time it is asked for (on the drop).
class LazyFiles final : public IDataObject {
    LONG refs_ = 1;
    xiz_archive *a_;
    std::string zone_;
    std::vector<std::string> select_;
    std::function<void(bool)> busy_;
    bool done_ = false, ok_ = false;
    std::vector<std::wstring> paths_;

    static bool is_hdrop(const FORMATETC *f) {
        return f->cfFormat == CF_HDROP && (f->tymed & TYMED_HGLOBAL) && f->dwAspect == DVASPECT_CONTENT;
    }
    bool render() {
        if (done_) return ok_;
        done_ = true;
        std::wstring dir, error;
        if (busy_) busy_(true);
        ok_ = extract_temp(a_, zone_, select_, dir, paths_, error);
        if (busy_) busy_(false);
        return ok_;
    }
public:
    LazyFiles(xiz_archive *a, std::string zone, std::vector<std::string> select, std::function<void(bool)> busy)
        : a_(a), zone_(std::move(zone)), select_(std::move(select)), busy_(std::move(busy)) {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **out) override {
        if (riid == IID_IUnknown || riid == IID_IDataObject) { *out = this; AddRef(); return S_OK; }
        *out = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return (ULONG)InterlockedIncrement(&refs_); }
    ULONG STDMETHODCALLTYPE Release() override {
        LONG r = InterlockedDecrement(&refs_);
        if (!r) delete this;
        return (ULONG)r;
    }
    HRESULT STDMETHODCALLTYPE GetData(FORMATETC *f, STGMEDIUM *m) override {
        if (!is_hdrop(f)) return DV_E_FORMATETC;
        if (!render()) return E_FAIL;
        size_t chars = 1;
        for (auto &p : paths_) chars += p.size() + 1;
        HGLOBAL g = GlobalAlloc(GHND, sizeof(DROPFILES) + chars * sizeof(wchar_t));
        if (!g) return E_OUTOFMEMORY;
        auto *df = static_cast<DROPFILES *>(GlobalLock(g));
        df->pFiles = sizeof(DROPFILES);
        df->fWide = TRUE;
        auto *w = reinterpret_cast<wchar_t *>(df + 1);
        for (auto &p : paths_) { memcpy(w, p.c_str(), (p.size() + 1) * sizeof(wchar_t)); w += p.size() + 1; }
        *w = 0;
        GlobalUnlock(g);
        m->tymed = TYMED_HGLOBAL;
        m->hGlobal = g;
        m->pUnkForRelease = nullptr;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetDataHere(FORMATETC *, STGMEDIUM *) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE QueryGetData(FORMATETC *f) override { return is_hdrop(f) ? S_OK : DV_E_FORMATETC; }
    HRESULT STDMETHODCALLTYPE GetCanonicalFormatEtc(FORMATETC *, FORMATETC *out) override {
        out->ptd = nullptr;
        return E_NOTIMPL;
    }
    HRESULT STDMETHODCALLTYPE SetData(FORMATETC *, STGMEDIUM *, BOOL) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE EnumFormatEtc(DWORD dir, IEnumFORMATETC **out) override {
        if (dir != DATADIR_GET) return E_NOTIMPL;
        FORMATETC f = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
        return SHCreateStdEnumFmtEtc(1, &f, out);
    }
    HRESULT STDMETHODCALLTYPE DAdvise(FORMATETC *, DWORD, IAdviseSink *, DWORD *) override { return OLE_E_ADVISENOTSUPPORTED; }
    HRESULT STDMETHODCALLTYPE DUnadvise(DWORD) override { return OLE_E_ADVISENOTSUPPORTED; }
    HRESULT STDMETHODCALLTYPE EnumDAdvise(IEnumSTATDATA **) override { return OLE_E_ADVISENOTSUPPORTED; }
};

}  // namespace

void drag_out(xiz_archive *a, const std::string &zone, const std::vector<std::string> &select, std::function<void(bool)> busy) {
    auto *data = new LazyFiles(a, zone, select, std::move(busy));
    auto *src = new DropSource();
    DWORD effect = 0;
    DoDragDrop(data, src, DROPEFFECT_COPY, &effect);
    src->Release();
    data->Release();
}
