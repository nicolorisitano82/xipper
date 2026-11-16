#!/bin/bash
# The full test campaign of Xipper: every automatic suite, the exhaustive ones and the checks with
# other tools, one after the other, with a PASS / FAIL / SKIP line each and the logs, in
# dist/test-campaign-DATE/ (RESULTS.md). Synthetic data only; nothing outside the repository and
# temporary folders is touched (disk images are attached by the suites that need them).
#
#   scripts/full-test.sh            everything (about an hour on an M3 Max)
#   scripts/full-test.sh --quick    without the slow steps (kill -9 rounds, forensic validation,
#                                   portable builds, long fuzzing)
#   STEPS="libxiz cross-read" MATRIX=dist/test-campaign-…/matrix scripts/full-test.sh
#                                   only some steps (MATRIX: reuse the archives of an earlier run)
#
# Steps:
#   build        release build of xipper and xipper-forensic
#   unit         swift test: every suite (debug, sanitizers off)
#   exhaustive   XIPPER_EXHAUSTIVE=1, release: the XIZ option matrix (codec × recompression ×
#                password/signature × recovery, with an edit and a repair each), the table dialects,
#                OpenZL fuzzing, forensic archives in Xipper
#   fuzz         every reader under XIPPER_FUZZ_ITERATIONS mutations (default 2000; quick 300)
#   libxiz       libxiz in Debug with AddressSanitizer and UBSan: unit, fixtures, hostile input
#   cross-read   libxiz reads back every archive of the matrix and of the dialects: test,
#                extract, identical to the expected tree, signatures
#   interop      scripts/interop.sh: archives written by Xipper read by 7zz, unzip, bsdtar…
#   lowspace     scripts/lowspace-crash.sh: «Cambia formato» with little space killed at random
#   forensic     scripts/forensic-validation.sh: V01–V13 (disks, E01, custody…)
#   portable     xiz cross-built for Linux and Windows with zig
#   linux        the Linux xiz run in a container (needs a running Docker daemon)
#   windows      scripts/windows-wine.sh: the Windows xiz under Wine in a Debian container, the
#                whole fixture suite plus Windows-only cases (needs a running Docker daemon)
#   windows-app  windows/test-wine.sh: Xipper XIZ for Windows (built for x86_64 and ARM64) under
#                Wine: extraction, passwords, factor, NFC, conflicts, verification, association;
#                also windows/test-barrique.sh when ~/Work/wine has a Barrique build
#   powercut     scripts/vm/powercut.sh: the little-space conversion in a macOS VM switched off
#                at random (needs the VM of scripts/vm, set up once; skipped by --quick)
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1
STAMP=$(date +%Y%m%d-%H%M)
OUT="$ROOT/dist/test-campaign-$STAMP"
LOGS="$OUT/logs"
MATRIX="${MATRIX:-$OUT/matrix}"
case $MATRIX in /*) ;; *) MATRIX="$ROOT/$MATRIX" ;; esac
mkdir -p "$LOGS" "$MATRIX"
RESULTS=()
FAILS=0

step() {  # id description command...
    local id=$1 what=$2; shift 2
    if [ -n "${STEPS:-}" ] && [[ " $STEPS " != *" $id "* ]]; then return; fi
    local t0=$SECONDS
    printf '==> %-11s %s\n' "$id" "$what"
    if "$@" > "$LOGS/$id.log" 2>&1; then
        RESULTS+=("| $id | PASS | $((SECONDS - t0)) s | $what |")
    else
        local code=$?
        if [ $code -eq 77 ]; then
            RESULTS+=("| $id | SKIP | — | $what: $(tail -1 "$LOGS/$id.log") |")
        else
            RESULTS+=("| $id | **FAIL** | $((SECONDS - t0)) s | $what (log: logs/$id.log) |")
            FAILS=$((FAILS + 1))
            tail -15 "$LOGS/$id.log"
        fi
    fi
}
skip() { echo "$1"; }

# ---------------------------------------------------------------- steps

build() {
    swift build -c release --product xipper && swift build -c release --product xipper-forensic
}

unit() {
    swift test 2>&1 | tee /dev/stderr | grep -q "Test run with .* passed"
}

exhaustive() {
    XIPPER_EXHAUSTIVE=1 XIPPER_MATRIX_OUT="$MATRIX" XIPPER_FUZZ_ITERATIONS=$([ $QUICK = 1 ] && echo 1000 || echo 6000) \
        swift test -c release -Xswiftc -enable-testing --filter Exhaustive 2>&1 | tee /dev/stderr | grep -q "Test run with .* passed"
}

fuzz() {
    XIPPER_FUZZ_ITERATIONS=$([ $QUICK = 1 ] && echo 300 || echo 2000) \
        swift test -c release -Xswiftc -enable-testing --filter "Fuzz|Hostile|Security|Robustness" 2>&1 | tee /dev/stderr | grep -q "Test run with .* passed"
}

LIBXIZ_BUILD="$ROOT/.build/libxiz-campaign"
libxiz() {
    cmake -S libxiz -B "$LIBXIZ_BUILD" -DCMAKE_BUILD_TYPE=Debug -DXIZ_SANITIZE=ON > /dev/null &&
    cmake --build "$LIBXIZ_BUILD" -j > /dev/null &&
    (cd "$LIBXIZ_BUILD" && ctest --output-on-failure)
}

cross_read() {
    local xiz="$LIBXIZ_BUILD/xiz" n=0 bad=0
    [ -x "$xiz" ] || { echo "libxiz not built"; return 1; }
    ls "$MATRIX"/*.case > /dev/null 2>&1 || { echo "no matrix archives (exhaustive step failed?)"; return 1; }
    export XIZ_MATRIX_PW='matrix password ✓'
    for c in "$MATRIX"/*.case; do
        local base=${c%.case} name; name=$(basename "$base")
        local pwopt=()
        grep -q '^password=1' "$c" && pwopt=(--password-env XIZ_MATRIX_PW)
        local dest; dest=$(mktemp -d)
        n=$((n + 1))
        if ! "$xiz" test ${pwopt[@]+"${pwopt[@]}"} "$base.xiz" > "$dest.log" 2>&1; then
            echo "FAIL test $name: $(tail -1 "$dest.log")"; bad=$((bad + 1)); rm -rf "$dest" "$dest.log"; continue
        fi
        if ! "$xiz" extract ${pwopt[@]+"${pwopt[@]}"} -d "$dest" "$base.xiz" > "$dest.log" 2>&1; then
            echo "FAIL extract $name: $(tail -1 "$dest.log")"; bad=$((bad + 1)); rm -rf "$dest" "$dest.log"; continue
        fi
        if ! python3 -I scripts/lib/compare_trees.py "$base.expected" "$dest/src" > "$dest.log" 2>&1; then
            echo "FAIL tree $name: $(head -3 "$dest.log")"; bad=$((bad + 1)); rm -rf "$dest" "$dest.log"; continue
        fi
        if grep -q '^signed=1' "$c" && ! "$xiz" history "$base.xiz" > "$dest.log" 2>&1; then
            echo "FAIL history $name: $(tail -1 "$dest.log")"; bad=$((bad + 1))
        fi
        echo "ok   $name"
        rm -rf "$dest" "$dest.log"
    done
    echo "$n archives, $bad failed"
    [ $bad -eq 0 ]
}

interop() { bash scripts/interop.sh; }
lowspace() { [ $QUICK = 1 ] && { skip "skipped by --quick"; return 77; }; bash scripts/lowspace-crash.sh 30 && FORMAT=tar bash scripts/lowspace-crash.sh 15; }
forensic() { [ $QUICK = 1 ] && { skip "skipped by --quick"; return 77; }; bash scripts/forensic-validation.sh; }

portable() {
    [ $QUICK = 1 ] && { skip "skipped by --quick"; return 77; }
    command -v zig > /dev/null || { skip "zig not installed"; return 77; }
    bash scripts/build-xiz-portable.sh campaign && ls "$ROOT/dist/xiz-campaign"
}

linux() {
    command -v docker > /dev/null || { skip "docker not installed"; return 77; }
    docker info > /dev/null 2>&1 || { skip "Docker daemon not running"; return 77; }
    local pkg="$ROOT/dist/xiz-campaign/xiz-campaign-linux-arm64.tar.gz"
    [ -f "$pkg" ] || { skip "no Linux build (portable step skipped)"; return 77; }
    local w; w=$(mktemp -d)
    local F="$ROOT/libxiz/tests/fixtures"
    tar -xzf "$pkg" -C "$w" && cp "$F/signed-pq.xiz" "$F/signed-pq-tampered.xiz" "$F/tables.xiz" "$F/docs.xiz" "$F/forensic.xiz" \
        "$F/access-pq.xiz" "$F/identity-pq.key" "$F/custodian-pq.key" "$w"/ &&
    docker run --rm -e XIZ_PW_C2='custodian two' -v "$w:/w" alpine:3.20 sh -c 'cd /w && X=$(find . -name xiz -type f | head -1) &&
        $X extract -d pq1 --identity identity-pq.key access-pq.xiz > /dev/null && test -f pq1/tree/referti/r2.txt &&
        $X extract -d pq2 --identity custodian-pq.key --password-env XIZ_PW_C2 access-pq.xiz > /dev/null &&
        $X history signed-pq.xiz | grep -c "ML-DSA-65)  signature valid, chain ok" | grep -qx 2 &&
        ! $X history signed-pq-tampered.xiz > /dev/null &&
        $X test tables.xiz && $X test docs.xiz && $X forensic forensic.xiz > /dev/null && $X extract -d out tables.xiz &&
        echo "linux ok: X-Wing recipients, hybrid signatures, tampering, OpenZL tables, documents, forensic"'
}

windows() {
    [ -f "$ROOT/.build/xiz-portable/windows-x86_64/xiz.exe" ] || { skip "no Windows build (portable step skipped)"; return 77; }
    bash scripts/windows-wine.sh
}

windows_app() {
    command -v zig > /dev/null || { skip "zig not installed"; return 77; }
    windows/build.sh x86_64 aarch64 > /dev/null || return 1
    windows/test-wine.sh --no-build --no-shots || return 1
    # Also under Barrique (~/Work/wine), the native Apple Silicon Wine, when it is built.
    if [ -x "$HOME/Work/wine/build-arm64ec/wine" ]; then windows/test-barrique.sh || return 1; fi
}

powercut() {
    [ $QUICK = 1 ] && { skip "skipped by --quick"; return 77; }
    [ -f "$HOME/XipperVM/macos/Disk.img" ] || { skip "no test VM (scripts/vm/xipper-vm install)"; return 77; }
    bash scripts/vm/build.sh > /dev/null && bash scripts/vm/powercut.sh 20
}

# ---------------------------------------------------------------- run

T0=$SECONDS
step build      "Release build of xipper and xipper-forensic" build
step unit       "All automatic suites (swift test)" unit
step exhaustive "Exhaustive: XIZ matrix, table dialects, OpenZL fuzzing, forensic archives" exhaustive
step fuzz       "Readers under mutation (release)" fuzz
step libxiz     "libxiz with AddressSanitizer and UBSan (ctest)" libxiz
step cross-read "libxiz reads back the matrix and the dialects" cross_read
step interop    "Xipper's archives read by the other tools" interop
step lowspace   "Little-space conversion killed at random (30 ZIP + 15 tar rounds)" lowspace
step forensic   "Forensic validation V01–V13" forensic
step portable   "xiz cross-built for Linux and Windows" portable
step linux      "Linux xiz in a container" linux
step windows    "Windows xiz under Wine in a container" windows
step windows-app "Xipper XIZ for Windows under Wine" windows_app
step powercut   "Little-space conversion in a VM switched off at random (20 rounds)" powercut

{
    echo "# Test campaign — Xipper $(grep -m1 'MARKETING_VERSION' App/Xipper.xcodeproj/project.pbxproj | sed -E 's/.*= ([^;]+);/\1/')"
    echo
    echo "- Date: $(date -u +%Y-%m-%dT%H:%M:%SZ), $((SECONDS - T0)) s$([ $QUICK = 1 ] && echo ', --quick')"
    echo "- Commit: $(git rev-parse --short HEAD)$(git diff --quiet || echo ' (with local changes)')"
    echo "- Mac: $(sysctl -n hw.model), $(sysctl -n machdep.cpu.brand_string), macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    echo "- Swift: $(swift --version 2>&1 | head -1)"
    echo
    echo "| Step | Result | Time | What |"
    echo "|---|---|---|---|"
    printf '%s\n' "${RESULTS[@]}"
    echo
    echo "**$FAILS failed.** Logs in \`logs/\`; the matrix archives in \`matrix/\`."
} > "$OUT/RESULTS.md"
cat "$OUT/RESULTS.md"
# The matrix takes about 2 GB: kept only when something failed, to look at it.
[ $FAILS -eq 0 ] && [ -z "${STEPS:-}" ] && rm -rf "$MATRIX" "$ROOT/dist/xiz-campaign"
[ $FAILS -eq 0 ]
