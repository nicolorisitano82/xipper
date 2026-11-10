#!/usr/bin/env python3
"""Xipper Forensic: lists the localizable strings of App/XipperForensic/Sources and checks that
it.lproj/Localizable.strings translates every one of them (exit 1 and the missing keys otherwise).
  scripts/forensic-strings.py            check
  scripts/forensic-strings.py --missing  print the missing keys as .strings lines to fill in"""
import pathlib, re, sys

root = pathlib.Path(__file__).resolve().parent.parent
src = root / "App/XipperForensic/Sources"
it = root / "App/XipperForensic/Resources/it.lproj/Localizable.strings"

calls = r'(?:String\(localized:|Text\(|Button\(|Label\(|Section\(|TextField\(|SecureField\(|Toggle\(|Picker\(|TableColumn\(|GroupBox\(|LabeledContent\(|\.help\(|\.alert\(|row\(|hash\(|LocalizedStringKey\()'
lit = r'"((?:[^"\\]|\\.)*)"'
keys = set()
for f in sorted(src.glob("*.swift")):
    text = f.read_text()
    for m in re.finditer(calls + r'\s*' + lit, text):
        keys.add(m.group(1))
    # Ternaries of literals passed to the same calls: Button(x ? "A" : "B")
    for m in re.finditer(calls + r'[^"\n()]*\?\s*' + lit + r'\s*:\s*' + lit, text):
        keys.update([m.group(1), m.group(2)])
    # Any ternary of two capitalised literals: Text(x == "a" ? "Inventory SHA-256" : "Source SHA-256")
    for m in re.finditer(r'\?\s*"([A-Z][^"\n]*)"\s*:\s*"([A-Z][^"\n]*)"', text):
        keys.update([m.group(1), m.group(2)])
keys = {k for k in keys if "\\(" not in k and re.search(r'[A-Za-z]{2}', k) and k not in {"SHA-256", "MD5", "SHA-1", "Xipper Forensic"}}

have = {}
if it.exists():
    for m in re.finditer(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', it.read_text(), re.M):
        have[m.group(1)] = m.group(2)
missing = sorted(keys - have.keys())
unused = sorted(have.keys() - keys)
if "--missing" in sys.argv:
    for k in missing: print(f'"{k}" = "";')
    sys.exit(0)
for k in unused: print(f"unused: {k}")
for k in missing: print(f"missing: {k}")
print(f"{len(keys)} strings, {len(missing)} missing in Italian")
sys.exit(1 if missing else 0)
