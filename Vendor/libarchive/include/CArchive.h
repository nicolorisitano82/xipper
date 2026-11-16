#pragma once
// libarchive 3.8.11 (BSD-2-Clause), reduced to its RAR (4.x), RAR5 and ISO 9660 readers: RAR archives
// and ISO images are read-only in Xipper (STUDIO.md §4.2). Seen by Swift only through this header.
#include "../libarchive/archive.h"
#include "../libarchive/archive_entry.h"
#include "../libarchive/archive_blake2.h"
