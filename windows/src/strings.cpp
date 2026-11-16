#include "strings.h"
#include "strings_i18n.h"

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

enum Lang { IT, EN, DE, ES, FR, JA, ZH };

Lang pick_language() {
    wchar_t env[16];
    DWORD n = GetEnvironmentVariableW(L"XIZW_LANG", env, 16);
    if (n > 0 && n < 16) {
        std::wstring e(env, n);
        if (e == L"it") return IT;
        if (e == L"de") return DE;
        if (e == L"es") return ES;
        if (e == L"fr") return FR;
        if (e == L"ja") return JA;
        if (e.rfind(L"zh", 0) == 0) return ZH;
        return EN;
    }
    LANGID id = GetUserDefaultUILanguage();
    switch (PRIMARYLANGID(id)) {
    case LANG_ITALIAN: return IT;
    case LANG_GERMAN: return DE;
    case LANG_SPANISH: return ES;
    case LANG_FRENCH: return FR;
    case LANG_JAPANESE: return JA;
    case LANG_CHINESE:  // Simplified only: Traditional readers get English rather than the wrong script
        return SUBLANGID(id) == SUBLANG_CHINESE_SIMPLIFIED || SUBLANGID(id) == SUBLANG_CHINESE_SINGAPORE ? ZH : EN;
    default: return EN;
    }
}

Lang lang() {
    static const Lang l = pick_language();
    return l;
}

// One table per language, indexed by S; missing texts are English. Built once (thread-safe static).
struct Tables {
    const wchar_t *t[7][(int)S::Count];
    Tables() {
        for (int i = 0; i < (int)S::Count; i++) {
            t[IT][i] = it_strings[i];
            for (int l = EN; l <= ZH; l++) t[l][i] = en_strings[i];
        }
        struct { Lang l; const Tr *tr; size_t n; } more[] = {
            {DE, tr_de, tr_de_n}, {ES, tr_es, tr_es_n}, {FR, tr_fr, tr_fr_n}, {JA, tr_ja, tr_ja_n}, {ZH, tr_zh, tr_zh_n}};
        for (auto &m : more)
            for (size_t i = 0; i < m.n; i++) t[m.l][(int)m.tr[i].id] = m.tr[i].text;
    }
};

const wchar_t *const *table(Lang l) {
    static const Tables tables;
    return tables.t[l];
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

const wchar_t *T(S id) { return table(lang())[(int)id]; }

const char *language() {
    static const char *names[] = {"it", "en", "de", "es", "fr", "ja", "zh-Hans"};
    return names[lang()];
}

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
