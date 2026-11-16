#!/bin/bash
# Xipper XIZ for Windows under Wine, in a throwaway Debian container (as scripts/windows-wine.sh).
# The command-line modes are checked against xiz.exe's own extraction; then the windows are shown on a
# virtual display and photographed into .build/windows-app/shots/ (to look at, not checked).
# Wine is not Windows: no NTFS streams (Mark of the Web), case-sensitive files, approximate themes.
#   windows/test-wine.sh [--no-build] [--no-shots]
# Exit 0 = all passed, 77 = skipped (no Docker), anything else = failure.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
BUILD=1 SHOTS=1
for a in "$@"; do
    case $a in --no-build) BUILD=0 ;; --no-shots) SHOTS=0 ;; *) echo "usage: windows/test-wine.sh [--no-build] [--no-shots]"; exit 2 ;; esac
done
command -v docker > /dev/null || { echo "SKIP: docker not installed"; exit 77; }
docker info > /dev/null 2>&1 || { echo "SKIP: Docker daemon not running"; exit 77; }
[ $BUILD = 1 ] && { windows/build.sh x86_64 || exit 1; }
APP="$ROOT/.build/windows-app/x86_64"
IMAGE=xipper-wine-gui:trixie
if ! docker image inspect "$IMAGE" > /dev/null 2>&1; then
    printf 'FROM debian:trixie\nRUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends wine wine64 xvfb imagemagick xdotool fonts-dejavu-core && rm -rf /var/lib/apt/lists/*\n' |
        docker build --platform linux/amd64 -t "$IMAGE" - > /dev/null 2>&1 || { echo "cannot build $IMAGE"; exit 1; }
fi

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/in"
cp "$APP/XipperXIZ.exe" "$APP/xiz.exe" "$W/bin/"
cp libxiz/tests/fixtures/{plain,password,factor,password-114}.xiz libxiz/tests/fixtures/factor.xizfactor "$W/in/"
# An archive with Apple's LZRAVEN frames, which no Windows build can read (made here, macOS 27).
if [ -x .build/release/xipper ]; then
    mkdir -p "$W/src/d" && echo hi > "$W/src/d/a.txt"
    .build/release/xipper create --lzraven "$W/in/lzraven.xiz" "$W/src/d" > /dev/null 2>&1 || rm -f "$W/in/lzraven.xiz"
fi

cat > "$W/inner.sh" <<'EOF'
set -u
cd /w
A="wine /w/bin/XipperXIZ.exe" X="wine /w/bin/xiz.exe"
pass=0 bad=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
no() { echo "FAIL $1"; bad=$((bad + 1)); }
code() { [ "$(sed -n 's/^exit //p' "$1")" = "$2" ]; }
tree() { (cd "$1" && find . -type f -exec sha256sum {} + | sort); }
wineboot -i > /dev/null 2>&1; wineserver -w
mkdir -p ref out
export PW='correct horse battery staple' WRONG='not the password'

$X extract -d ref/plain in/plain.xiz > /dev/null 2>&1
$A /x in/plain.xiz /d out/plain /quiet /log plain.log; wineserver -w
code plain.log 0 && [ "$(tree out/plain)" = "$(tree ref/plain)" ] && ok extract-plain || { cat plain.log; no extract-plain; }
$A /x in/plain.xiz /d out/plain /quiet /log again.log; wineserver -w
code again.log 4 && grep -q '^skipped [1-9]' again.log && ok existing-skipped || { cat again.log; no existing-skipped; }
$A /x in/plain.xiz /d out/plain /quiet /keep-both /log both.log; wineserver -w
code both.log 0 && grep -q '^renamed [1-9]' both.log && [ "$(find out/plain -name '* (2)*' | wc -l)" -gt 0 ] && ok keep-both || { cat both.log; no keep-both; }
cp in/plain.xiz 'in/città è.xiz'
$A /x 'in/città è.xiz' /quiet /log here.log; wineserver -w
code here.log 0 && [ "$(tree 'in/città è')" = "$(tree ref/plain)" ] && ok extract-here-non-ascii || { cat here.log; no extract-here-non-ascii; }

$X extract -d ref/pw --password-env PW in/password.xiz > /dev/null 2>&1
$A /x in/password.xiz /d out/pw /passenv PW /quiet /log pw.log; wineserver -w
code pw.log 0 && [ "$(tree out/pw)" = "$(tree ref/pw)" ] && ok password || { cat pw.log; no password; }
$A /x in/password.xiz /d out/nopw /quiet /log nopw.log; wineserver -w
code nopw.log 3 && ok password-missing || { cat nopw.log; no password-missing; }
$A /x in/password.xiz /d out/wrong /passenv WRONG /quiet /log wrong.log; wineserver -w
code wrong.log 3 && ok password-wrong || { cat wrong.log; no password-wrong; }
$A /x in/factor.xiz /d out/factor /passenv PW /factor in/factor.xizfactor /quiet /log factor.log; wineserver -w
code factor.log 0 && [ "$(tree out/factor)" = "$(tree ref/pw)" ] && ok factor || { cat factor.log; no factor; }
$A /x in/factor.xiz /d out/nofactor /passenv PW /quiet /log nofactor.log; wineserver -w
code nofactor.log 3 && grep -q '^status -19' nofactor.log && ok factor-missing || { cat nofactor.log; no factor-missing; }
# NFC (§24.2): xiz.exe writes the password's bytes as given (NFC here); the app gets it decomposed.
export NFC="$(printf 'p\303\244ssw\303\266rd')" NFD="$(printf 'pa\314\210sswo\314\210rd')"
mkdir -p src && echo x > src/f.txt
XIZ_TEST_FAST_KDF=1 $X create --password-env NFC in/nfc.xiz src > /dev/null 2>&1
$A /t in/nfc.xiz /passenv NFD /quiet /log nfd.log; wineserver -w
code nfd.log 0 && ok password-normalized-nfc || { cat nfd.log; no password-normalized-nfc; }

$A /t in/plain.xiz /quiet /log test.log; wineserver -w
code test.log 0 && grep -q '^checked [1-9]' test.log && ok verify || { cat test.log; no verify; }
cp in/plain.xiz in/damaged.xiz
printf '\377\377\377\377' | dd of=in/damaged.xiz bs=1 seek=200 conv=notrunc 2> /dev/null
$A /t in/damaged.xiz /quiet /log dmg.log; wineserver -w
code dmg.log 1 && ok verify-damaged || { cat dmg.log; no verify-damaged; }
if [ -f in/lzraven.xiz ]; then
    $A /x in/lzraven.xiz /d out/raven /quiet /log raven.log; wineserver -w
    code raven.log 1 && grep -q 'LZRAVEN' raven.log && ok apple-codec-explained || { cat raven.log; no apple-codec-explained; }
fi
$A /x in/missing.xiz /quiet /log missing.log; wineserver -w
code missing.log 1 && ok missing-archive || { cat missing.log; no missing-archive; }

$A /register /quiet; wineserver -w
wine reg query 'HKCU\Software\Classes\.xiz' 2> /dev/null | grep -q XipperXIZ.Archive &&
    wine reg query 'HKCU\Software\Classes\XipperXIZ.Archive\shell\extracthere\command' 2> /dev/null | grep -q '/x' && ok register || no register
$A /unregister /quiet; wineserver -w
wine reg query 'HKCU\Software\Classes\XipperXIZ.Archive' > /dev/null 2>&1 && no unregister || ok unregister
echo "app: $pass passed, $bad failed"

if [ "${SHOTS:-1}" = 1 ]; then
    mkdir -p /w/shots
    Xvfb :9 -screen 0 1280x800x24 > /dev/null 2>&1 &
    export DISPLAY=:9
    sleep 2
    shot() { sleep "$2"; import -window root "/w/shots/$1.png" 2> /dev/null; }
    $A in/plain.xiz & sleep 8; shot main 1
    xdotool key ctrl+e 2> /dev/null; shot extract-dialog 3
    xdotool key Escape 2> /dev/null; sleep 1
    xdotool key ctrl+t 2> /dev/null; shot verify-result 6
    wineserver -k; sleep 1
    $A in/password.xiz & shot password 8
    wineserver -k; sleep 1
    $A & shot empty 8
    wineserver -k
fi
[ $bad = 0 ]
EOF

docker run --rm --platform linux/amd64 -e LANG=it_IT.UTF-8 -e LC_ALL=C.UTF-8 -e WINEDEBUG=-all -e SHOTS=$SHOTS \
    -v "$W:/w" "$IMAGE" sh /w/inner.sh > "$W/run.log" 2>&1
rc=$?
grep -E '^(ok|FAIL|app:)|^(exit|status|error|message|problem) ' "$W/run.log"
if [ $SHOTS = 1 ] && [ -d "$W/shots" ]; then
    mkdir -p .build/windows-app/shots && cp "$W"/shots/*.png .build/windows-app/shots/ 2> /dev/null
    ls .build/windows-app/shots
fi
[ $rc = 0 ] || { tail -30 "$W/run.log"; echo "windows app FAILED"; exit 1; }
echo "windows app ok under Wine"
