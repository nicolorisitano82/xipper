#!/usr/bin/env python3
"""Every translation of windows/src/strings_i18n.cpp (and the Italian of strings.h) must have the
English text's printf placeholders, in the same order: vswprintf has no positional arguments."""
import re, sys, pathlib

src = pathlib.Path(__file__).resolve().parent / "src"
spec = re.compile(r"%(?:ls|llu|u|d|%)")
lit = r'L"((?:[^"\\]|\\.)*)"'
english, bad = {}, 0
for m in re.finditer(r"X\((\w+), " + lit + ", " + lit + r"\)", (src / "strings.h").read_text()):
    english[m.group(1)] = spec.findall(m.group(3))
    if spec.findall(m.group(2)) != english[m.group(1)]:
        print(f"it {m.group(1)}: {spec.findall(m.group(2))} != {english[m.group(1)]}"); bad += 1
text = (src / "strings_i18n.cpp").read_text()
for table in re.finditer(r"const Tr tr_(\w+)\[\] = \{(.*?)\n\};", text, re.S):
    seen = set()
    for m in re.finditer(r"E\((\w+), " + lit + r"\)", table.group(2)):
        sid = m.group(1)
        if sid not in english: print(f"{table.group(1)} {sid}: unknown id"); bad += 1; continue
        if sid in seen: print(f"{table.group(1)} {sid}: twice"); bad += 1
        seen.add(sid)
        if spec.findall(m.group(2)) != english[sid]:
            print(f"{table.group(1)} {sid}: {spec.findall(m.group(2))} != {english[sid]}"); bad += 1
    missing = [k for k in english if k not in seen and not k.startswith(("Alg", "AppName", "AccOpened"))]
    if missing: print(f"{table.group(1)}: {len(missing)} missing (English used): {', '.join(missing)}")
sys.exit(1 if bad else 0)
