#!/usr/bin/env python3
"""Compares two folder trees as Xipper's tests do (TestSupport.treesEqual): names in NFC (APFS
keeps whatever form a tool wrote), file contents, symlink targets, the executable bit.
Usage: compare_trees.py EXPECTED ACTUAL   → exit 0 when equal, else the first differences."""
import hashlib, os, stat, sys, unicodedata


def snapshot(root):
    out = {}
    for d, dirs, files in os.walk(root, followlinks=False):
        for n in dirs + files:
            p = os.path.join(d, n)
            rel = unicodedata.normalize("NFC", os.path.relpath(p, root))
            st = os.lstat(p)
            if stat.S_ISLNK(st.st_mode):
                out[rel] = "link:" + os.readlink(p)
            elif stat.S_ISDIR(st.st_mode):
                out[rel] = "dir"
            else:
                with open(p, "rb") as f:
                    h = hashlib.sha256(f.read()).hexdigest()
                out[rel] = f"file:{st.st_size}:{h}:x{bool(st.st_mode & 0o100)}"
    return out


a, b = snapshot(sys.argv[1]), snapshot(sys.argv[2])
diff = sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))
for k in diff[:10]:
    print(f"{k}: {a.get(k, 'missing')} vs {b.get(k, 'missing')}")
sys.exit(1 if diff else 0)
