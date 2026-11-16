#!/bin/bash
# Regenerates Vendor/zxcvbn/src/dict-src.h (zxcvbn's compiled-in dictionary) from the word lists
# of zxcvbn-c 2.7 kept in Vendor/zxcvbn/words, with its own generator (dict-generate.cpp), built in
# a temporary folder. Run after changing the word lists; then python3 -I scripts/make-vendor-manifest.py.
set -euo pipefail
cd "$(dirname "$0")/.."
W=Vendor/zxcvbn/words
T=$(mktemp -d "${TMPDIR:-/tmp}/zxcvbn.XXXXXX")
trap 'rm -f "$T/dictgen"; rmdir "$T"' EXIT
clang++ -std=c++17 -O2 -w -o "$T/dictgen" "$W/dict-generate.cpp"
"$T/dictgen" -o Vendor/zxcvbn/src/dict-src.h "$W/words-eng_wiki.txt" "$W/words-female.txt" "$W/words-male.txt" \
    "$W/words-passwd.txt" "$W/words-surname.txt" "$W/words-tv_film.txt"
echo "Vendor/zxcvbn/src/dict-src.h regenerated"
