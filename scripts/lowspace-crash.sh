#!/bin/bash
# «Cambia formato» with little free space: tests on a small APFS volume (disk image).
#
#   1. a ZIP that fills more than half the volume: the usual conversion cannot fit, the
#      --little-space one must;
#   2. the same conversion killed (SIGKILL) at random moments, then run again, ROUNDS times:
#      it must always end with a XIZ that extracts to the original files, and no original left.
#
# A SIGKILL loses nothing the process already handed to the kernel, so this tests the order of
# writes, journal and releases, not a power cut (which can also lose what the disk had not
# flushed): that needs a VM, see docs/ROADMAP.md (3.0, F).
#
# Usage: scripts/lowspace-crash.sh [ROUNDS]   (default 30; uses .build/release/xipper)
set -euo pipefail
ROUNDS=${1:-30}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
X="$ROOT/.build/release/xipper"
[ -x "$X" ] || (cd "$ROOT" && swift build -c release --product xipper >/dev/null)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/xipper-lowspace.XXXXXX")
MNT="$WORK/mnt"
cleanup() { hdiutil detach -quiet -force "$MNT" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

# 160 MB of files that do not compress (the worst case: the new archive is as big as the old).
mkdir -p "$WORK/src/dir" "$WORK/src/empty"
for i in $(seq 1 40); do head -c $((3 * 1024 * 1024 + i * 4096)) /dev/urandom > "$WORK/src/dir/r$i.bin"; done
for i in $(seq 1 200); do echo "text $i $(date)" > "$WORK/src/dir/t$i.txt"; done
(cd "$WORK/src" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256) > "$WORK/expected.sha"

hdiutil create -quiet -size 300m -fs APFS -volname XLS -type SPARSE "$WORK/vol" >/dev/null
hdiutil attach -quiet -nobrowse -mountpoint "$MNT" "$WORK/vol.sparseimage"

make_zip() {
    rm -rf "$MNT"/*.zip "$MNT"/*.xiz "$MNT"/.*.xipper-partial "$MNT"/*.xipper-resume "$MNT"/.xipper-convert-* 2>/dev/null || true
    (cd "$WORK/src" && /usr/bin/zip -q -r -0 "$MNT/a.zip" .)
}

check_result() {
    local out="$WORK/out"
    rm -rf "$out"; mkdir -p "$out"
    [ ! -e "$MNT/a.zip" ] || { echo "FAIL: original still there"; exit 1; }
    "$X" extract -q --into -d "$out" "$MNT/a.xiz" >/dev/null
    (cd "$out" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256) > "$WORK/got.sha"
    cmp -s "$WORK/expected.sha" "$WORK/got.sha" || { echo "FAIL: contents differ"; diff "$WORK/expected.sha" "$WORK/got.sha" | head; exit 1; }
}

free_mb() { df -m "$MNT" | awk 'NR==2 {print $4}'; }

echo "== 1. little space"
make_zip
echo "   ZIP $(du -m "$MNT/a.zip" | cut -f1) MB, free $(free_mb) MB"
if "$X" convert -q --to xiz -l 1 "$MNT/a.zip" -o "$MNT/plain.xiz" 2>/dev/null; then
    echo "   (the usual conversion fit anyway)"; rm -f "$MNT/plain.xiz"
else
    echo "   usual conversion: refused for lack of space, as expected"
fi
XIPPER_LOWSPACE_BATCH=$((16 << 20)) "$X" convert -q --to xiz -l 1 --little-space "$MNT/a.zip" -o "$MNT/a.xiz" >/dev/null
check_result
echo "   --little-space: ok, XIZ $(du -m "$MNT/a.xiz" | cut -f1) MB, free $(free_mb) MB"

echo "== 2. $ROUNDS rounds killed at random"
kills=0
for r in $(seq 1 "$ROUNDS"); do
    make_zip
    tries=0
    while :; do
        tries=$((tries + 1))
        XIPPER_LOWSPACE_BATCH=$((16 << 20)) "$X" convert -q --to xiz -l 1 --little-space "$MNT/a.zip" -o "$MNT/a.xiz" >/dev/null 2>"$WORK/err" &
        pid=$!
        # Kill within 0–1.2 s, except every fourth try (and after 12) let it finish.
        if [ $((tries % 4)) -ne 0 ] && [ $tries -lt 12 ]; then
            sleep "$(awk -v s=$RANDOM 'BEGIN{srand(s); printf "%.2f", rand()*1.2}')"
            kill -9 $pid 2>/dev/null && kills=$((kills + 1)) || true
        fi
        if wait $pid 2>/dev/null; then break; fi
        if [ -s "$WORK/err" ] && ! grep -q "Killed" "$WORK/err"; then
            # A real error (not our kill) fails the test, unless the conversion is just done.
            if ! [ -e "$MNT/a.xiz" ]; then echo "FAIL round $r: $(cat "$WORK/err")"; exit 1; fi
            break
        fi
        if [ -e "$MNT/a.xiz" ] && [ ! -e "$MNT/a.zip.xipper-resume" ]; then break; fi
    done
    check_result
    printf "   round %d: ok after %d runs\n" "$r" "$tries"
done
echo "== all good: $ROUNDS rounds, $kills kills"
