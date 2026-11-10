#!/bin/bash
# xipper-forensic: the hashes it reports must be the ones standard tools compute on the source, and
# the image read back from the archive (by xipper and by libxiz) must be the source byte for byte.
# Sizes around the 4 MiB block boundary, empty, all zeros, random. Synthetic data only.
#
# Usage: scripts/forensic-hashes.sh   (uses .build/release/xipper-forensic, xipper, libxiz/build/xiz)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
XF="$ROOT/.build/release/xipper-forensic"
X="$ROOT/.build/release/xipper"
XZ="$ROOT/libxiz/build/xiz"
for b in "$XF" "$X"; do [ -x "$b" ] || { echo "build first: swift build -c release --product $(basename "$b")"; exit 2; }; done
[ -x "$XZ" ] || { echo "build libxiz first: cmake -S libxiz -B libxiz/build && cmake --build libxiz/build"; exit 2; }
W=$(mktemp -d "${TMPDIR:-/tmp}/xipper-forensic-hashes.XXXXXX")
trap 'rm -rf "$W"' EXIT
"$X" keygen --signing -o "$W/k" > /dev/null

B=4194304
make() {  # NAME KIND SIZE
    case $2 in
        random) head -c "$3" /dev/urandom > "$W/$1" ;;
        zero) if [ "$3" = 0 ]; then : > "$W/$1"; else head -c "$3" /dev/zero > "$W/$1"; fi ;;
        mixed) { head -c "$B" /dev/urandom; head -c "$B" /dev/zero; head -c $(( $3 - 2 * B )) /dev/urandom; } > "$W/$1" ;;
    esac
}
fails=0
check() {  # NAME KIND SIZE
    make "$1" "$2" "$3"
    local src="$W/$1" out="$W/$1.xiz"
    local want256 want1 wantmd5
    want256=$(shasum -a 256 "$src" | cut -d' ' -f1)
    want1=$(shasum -a 1 "$src" | cut -d' ' -f1)
    wantmd5=$(md5 -q "$src")
    local log
    log=$("$XF" acquire --image "$src" -o "$out" --sign "$W/k" --case T --evidence "$1")
    local got256 got1 gotmd5
    got256=$(sed -n 's/^SHA-256 *//p' <<< "$log"); got1=$(sed -n 's/^SHA-1 *//p' <<< "$log"); gotmd5=$(sed -n 's/^MD5 *//p' <<< "$log")
    local xiz256 xip256
    xiz256=$("$XZ" cat "$out" image.dd | shasum -a 256 | cut -d' ' -f1)
    rm -rf "$W/x"; mkdir "$W/x"; "$X" extract -q -d "$W/x" --into "$out" > /dev/null
    xip256=$(shasum -a 256 "$W/x/image.dd" | cut -d' ' -f1)
    if [ "$got256" = "$want256" ] && [ "$got1" = "$want1" ] && [ "$gotmd5" = "$wantmd5" ] && [ "$xiz256" = "$want256" ] && [ "$xip256" = "$want256" ] \
        && "$XF" verify "$out" --expect-sha256 "$want256" > /dev/null && "$XZ" forensic "$out" > /dev/null; then
        printf "ok    %-12s %10d bytes  %s\n" "$1" "$3" "$want256"
    else
        printf "FAIL  %-12s %10d bytes: reported %s/%s/%s, xiz %s, xipper %s\n" "$1" "$3" "$got256" "$got1" "$gotmd5" "$xiz256" "$xip256"
        fails=$((fails + 1))
    fi
}
check empty zero 0
check one random 1
check sector random 512
check block-1 random $((B - 1))
check block random $B
check block+1 random $((B + 1))
check zeros zero $((2 * B + 12345))
check mixed mixed $((3 * B + 777))
check big random $((13 * 1024 * 1024 + 3))
[ $fails = 0 ] && echo "forensic hashes: all match" || { echo "forensic hashes: $fails failed"; exit 1; }
