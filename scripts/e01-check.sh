#!/bin/bash
# E01 interoperability (docs/FORENSE_3.1.md §6, F6): Xipper's E01 read by libewf and The Sleuth Kit,
# libewf's E01 imported by Xipper, same hashes and the same file listing everywhere.
# Needs: brew install libewf sleuthkit.   scripts/e01-check.sh [WORKDIR]
set -euo pipefail
cd "$(dirname "$0")/.."
for t in ewfverify ewfinfo ewfacquirestream fls; do command -v $t >/dev/null || { echo "missing $t (brew install libewf sleuthkit)"; exit 2; }; done
swift build --product xipper-forensic 2>&1 | grep -E "error" || true
B="$(swift build --show-bin-path)/xipper-forensic"
W="${1:-$(mktemp -d)}"; mkdir -p "$W"; cd "$W"; rm -rf ./*
xipper_keygen() { "$(dirname "$B")/xipper" keygen --signing -o key.txt >/dev/null; }
xipper_keygen
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; exit 1; }

# 1. A FAT32 disk image with files (MBR, partition at sector 1), an unreadable range declared.
hdiutil create -size 40m -fs "MS-DOS FAT32" -volname PROVA -layout MBRSPUD fat.dmg -quiet
V=$(hdiutil attach -nobrowse fat.dmg 2>/dev/null | tail -1 | awk -F'\t' '{print $NF}')
cp -R "$OLDPWD/docs/forensic" "$V/"; echo prova > "$V/nota.txt"
hdiutil detach "$V" -quiet
hdiutil convert fat.dmg -format UDTO -o fat -quiet && mv fat.cdr fat.raw
head -c 20971520 /dev/urandom > noise.raw
"$B" acquire --image fat.raw -o fat.xiz --sign key.txt --case E01-CHECK --evidence R01 --unreadable 1048576:4096 >/dev/null
"$B" acquire --image noise.raw -o noise.xiz --sign key.txt --case E01-CHECK --evidence R02 >/dev/null

# 2. Xipper → E01 → libewf, Sleuth Kit.
"$B" export fat.xiz --e01 fat >/dev/null
"$B" export noise.xiz --e01 noise --segment-size 8 >/dev/null
for e in fat noise; do ewfverify -q $e.E01 | grep -q SUCCESS && ok "ewfverify $e.E01 ($(ls $e.E0* | wc -l | tr -d ' ') segments)" || bad "ewfverify $e.E01"; done
ewfinfo fat.E01 | grep -q "2048 - 2055" && ok "error2 read by libewf" || bad "error2"
"$B" export fat.xiz --raw back.raw >/dev/null
[ "$(fls -o 1 -r fat.E01 | shasum)" = "$(fls -o 1 -r back.raw | shasum)" ] && ok "fls: same listing on E01 and raw" || bad "fls listing"

# 3. libewf → Xipper.
ewfacquirestream -q -t "$PWD/lib" -C LIB -E E7 -e Altro -S 8MiB -c deflate:fast -f encase6 -d sha1 < noise.raw >/dev/null 2>&1
"$B" acquire --e01 lib.E01 -o lib.xiz --sign key.txt | grep -q "E01 hashes match" && ok "libewf E01 imported, MD5 and SHA-1 match" || bad "import"
[ "$(shasum -a 256 < noise.raw | cut -d' ' -f1)" = "$("$B" export lib.xiz --raw - | shasum -a 256 | cut -d' ' -f1)" ] && ok "imported image = source" || bad "imported image"
"$B" verify lib.xiz | tail -1 | grep -q verified && ok "imported archive verifies" || bad "verify"
echo "all E01 checks passed ($W)"
