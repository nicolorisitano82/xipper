#pragma once
#include <cstddef>

#include "strings.h"

struct Tr {
    S id;
    const wchar_t *text;
};

extern const Tr tr_de[], tr_es[], tr_fr[], tr_ja[], tr_zh[];
extern const size_t tr_de_n, tr_es_n, tr_fr_n, tr_ja_n, tr_zh_n;
