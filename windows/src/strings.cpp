#include "strings.h"

#include <windows.h>

#include <cstdarg>
#include <cwchar>
#include <vector>

namespace {

const wchar_t *const it_strings[] = {
#define XIZW_IT(id, it, en) it,
    XIZW_STRINGS(XIZW_IT)
#undef XIZW_IT
};

const wchar_t *const en_strings[] = {
#define XIZW_EN(id, it, en) en,
    XIZW_STRINGS(XIZW_EN)
#undef XIZW_EN
};

bool italian() {
    static const bool it = PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_ITALIAN;
    return it;
}

std::wstring vformat(const wchar_t *f, va_list ap) {
    std::vector<wchar_t> buf(512);
    for (;;) {
        va_list cp;
        va_copy(cp, ap);
        int n = vswprintf(buf.data(), buf.size(), f, cp);
        va_end(cp);
        if (n >= 0 && (size_t)n < buf.size()) return std::wstring(buf.data(), (size_t)n);
        buf.resize(buf.size() * 2);
        if (buf.size() > (1u << 20)) return f;
    }
}

}  // namespace

const wchar_t *T(S id) { return (italian() ? it_strings : en_strings)[(int)id]; }

std::wstring fmt(S id, ...) {
    va_list ap;
    va_start(ap, id);
    std::wstring s = vformat(T(id), ap);
    va_end(ap);
    return s;
}

std::wstring vfmt(const wchar_t *f, ...) {
    va_list ap;
    va_start(ap, f);
    std::wstring s = vformat(f, ap);
    va_end(ap);
    return s;
}
