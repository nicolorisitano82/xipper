#pragma once

#include <functional>
#include <string>
#include <vector>

#include "core.h"

// Extracts `select` (stored paths) into a new private temporary folder; `paths` gets the top-level
// items on disk. False with `error` when nothing could be extracted.
bool extract_temp(xiz_archive *a, const std::string &zone, const std::vector<std::string> &select, std::wstring &dir,
                  std::vector<std::wstring> &paths, std::wstring &error);
// Drags the selection to another window (Explorer); extracts on the drop. `busy` is called with
// true before extracting and false after (wait cursor, status text).
void drag_out(xiz_archive *a, const std::string &zone, const std::vector<std::string> &select, std::function<void(bool)> busy);
// Removes this process's temporary folders (those still open in another program stay).
void clean_temp();
