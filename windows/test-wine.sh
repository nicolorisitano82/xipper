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
IMAGE=xipper-wine-gui:trixie-cjk
if ! docker image inspect "$IMAGE" > /dev/null 2>&1; then
    printf 'FROM debian:trixie\nRUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends wine wine64 xvfb imagemagick xdotool fonts-dejavu-core fonts-wqy-microhei && rm -rf /var/lib/apt/lists/*\n' |
        docker build --platform linux/amd64 -t "$IMAGE" - > /dev/null 2>&1 || { echo "cannot build $IMAGE"; exit 1; }
fi

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/in"
cp "$APP/XipperXIZ.exe" "$APP/xiz.exe" "$W/bin/"
cp libxiz/tests/fixtures/{plain,password,factor,password-114,access,access-pq,age-pq,signed,signed-pq,signed-pq-tampered,signed-se}.xiz \
   libxiz/tests/fixtures/{factor.xizfactor,identity.key,identity-pq.key,custodian-pq.key,age-pq.key} "$W/in/"
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
export XIZ_PW_A='alpha secret' XIZ_PW_B='beta secret' XIZ_PW_C1='custodian one' XIZ_PW_C2='custodian two' XIZ_PW_C3='custodian three'

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

# Phase 2: groups, keys, custodians, signatures, recovery record.
$X extract -d ref/all --password-env XIZ_PW_A in/access.xiz > /dev/null 2>&1
$X extract -d ref/g1 --identity in/identity.key in/access.xiz > /dev/null 2>&1
$A /x in/access.xiz /d out/all /passenv XIZ_PW_A /quiet /log all.log; wineserver -w
code all.log 0 && [ "$(tree out/all)" = "$(tree ref/all)" ] && ok groups-all || { cat all.log; no groups-all; }
$A /x in/access.xiz /d out/key /identity in/identity.key /quiet /log key.log; wineserver -w
code key.log 0 && [ "$(tree out/key)" = "$(tree ref/g1)" ] && ok recipient-key || { cat key.log; no recipient-key; }
$A /x in/access.xiz /d out/thr /passenv XIZ_PW_C1 /passenv XIZ_PW_C3 /quiet /log thr.log; wineserver -w
code thr.log 0 && [ "$(tree out/thr)" = "$(tree ref/g1)" ] && ok custodians-2-of-3 || { cat thr.log; no custodians-2-of-3; }
$A /x in/access.xiz /d out/one /passenv XIZ_PW_C2 /quiet /log one.log; wineserver -w
code one.log 3 && ok one-custodian-refused || { cat one.log; no one-custodian-refused; }
$A /info in/access.xiz /passenv XIZ_PW_B /quiet /log partial.log; wineserver -w
grep -q '(locked)' partial.log && grep -q 'custodians of 3' partial.log && ok locked-group-and-access || { cat partial.log; no locked-group-and-access; }
$X extract -d ref/pq --identity in/identity-pq.key in/access-pq.xiz > /dev/null 2>&1
$A /x in/access-pq.xiz /d out/pq /identity in/identity-pq.key /quiet /log pq.log; wineserver -w
code pq.log 0 && [ "$(tree out/pq)" = "$(tree ref/pq)" ] && ok post-quantum-key || { cat pq.log; no post-quantum-key; }
$A /x in/access-pq.xiz /d out/pqc /identity in/custodian-pq.key /passenv XIZ_PW_C2 /quiet /log pqc.log; wineserver -w
code pqc.log 0 && ok post-quantum-custodians || { cat pqc.log; no post-quantum-custodians; }
$A /x in/age-pq.xiz /d out/age /identity in/age-pq.key /quiet /log age.log; wineserver -w
code age.log 0 && [ "$(cat out/age/referti/r2.txt 2> /dev/null)" = "referto 2" ] && ok age-identity || { cat age.log; no age-identity; }
$A /info in/signed.xiz /quiet /log sig.log; wineserver -w
grep -q 'Ed25519  valid' sig.log && ok signatures-ed25519 || { cat sig.log; no signatures-ed25519; }
$A /info in/signed-pq.xiz /quiet /log sigpq.log; wineserver -w
grep -q 'ML-DSA-65 (post-quantum)  valid' sigpq.log && ok signatures-hybrid || { cat sigpq.log; no signatures-hybrid; }
$A /info in/signed-pq-tampered.xiz /quiet /log sigt.log; wineserver -w
grep -q 'INVALID' sigt.log && ok signatures-tampered || { cat sigt.log; no signatures-tampered; }
$A /info in/signed-se.xiz /quiet /log sigse.log; wineserver -w
grep -q 'Secure Enclave P-256 + ML-DSA-65  valid' sigse.log && ok signatures-enclave || { cat sigse.log; no signatures-enclave; }
cp in/plain.xiz in/rec.xiz
$X recovery add --redundancy 10 in/rec.xiz > /dev/null 2>&1
$A /t in/rec.xiz /quiet /log rec.log; wineserver -w
code rec.log 0 && grep -q '^record-damage 0' rec.log && ok record-intact || { cat rec.log; no record-intact; }
printf '\377\377\377\377\377\377\377\377' | dd of=in/rec.xiz bs=1 seek=300 conv=notrunc 2> /dev/null
cp in/rec.xiz in/rec-damaged-copy.xiz
$A /t in/rec.xiz /quiet /log recd.log; wineserver -w
code recd.log 1 && grep -q '^repairable 1' recd.log && ok record-damage-found || { cat recd.log; no record-damage-found; }
$A /repair in/rec.xiz /quiet /log rep.log; wineserver -w
code rep.log 0 && [ -f 'in/rec (repaired).xiz' ] && $X test 'in/rec (repaired).xiz' > /dev/null 2>&1 && cmp -s in/rec.xiz in/rec-damaged-copy.xiz \
    && ok repaired-copy-original-untouched || { cat rep.log; no repaired-copy-original-untouched; }
$A /info in/rec.xiz /quiet /log recinfo.log; wineserver -w
grep -q 'Recovery record: repairs up to' recinfo.log && ok properties-record || { cat recinfo.log; no properties-record; }

# Phase 3: what a double-click or a drag extracts (private temporary folder, cleaned after), languages.
$A /temp-extract in/plain.xiz /d tree/docs/a.md /quiet /log tmp1.log; wineserver -w
code tmp1.log 0 && grep -q '^path .*XipperXIZ.*\\tree\\docs\\a.md$' tmp1.log && [ ! -f tmp1.log.left ] && ok temp-extract-file || { cat tmp1.log tmp1.log.left 2> /dev/null; no temp-extract-file; }
$A /temp-extract in/plain.xiz /d tree/docs /quiet /log tmp2.log; wineserver -w
code tmp2.log 0 && grep -q '^path .*\\tree\\docs$' tmp2.log && ok temp-extract-folder || { cat tmp2.log; no temp-extract-folder; }
for l in de:geöffnet es:abrir fr:ouvrir ja:開けません zh:无法打开 it:aprire; do
    XIZW_LANG=${l%%:*} $A /x in/missing.xiz /quiet /log lang.log; wineserver -w
    grep -q "^message .*${l#*:}" lang.log && ok "language-${l%%:*}" || { cat lang.log; no "language-${l%%:*}"; }
done

# C1: creating, appending, removing (read back by xiz.exe).
mkdir -p mk/src/sub && printf 'uno\n' > mk/src/a.txt && head -c 300000 /dev/urandom > mk/src/sub/b.bin && printf 'x' > mk/src/desktop.ini
printf 'nuovo\n' > mk/extra.txt
$A /new mk/new.xiz /src mk/src /quiet /log new.log; wineserver -w
$X extract -d mk/out mk/new.xiz > /dev/null 2>&1
code new.log 0 && [ "$(cd mk/out/src && find . -type f | sort)" = "$(printf './a.txt\n./sub/b.bin')" ] && cmp -s mk/out/src/sub/b.bin mk/src/sub/b.bin \
    && ok create || { cat new.log; no create; }
$A /new mk/pw.xiz /src mk/src /passenv NFD /recovery /level 19 /quiet /log newpw.log; wineserver -w
code newpw.log 0 && $X test --password-env NFC mk/pw.xiz > /dev/null 2>&1 && $X info --password-env NFC mk/pw.xiz | grep -q 'XIZ 1.14' \
    && $X recovery info mk/pw.xiz > /dev/null 2>&1 && ok create-password-nfc-commitment-record || { cat newpw.log; $X info --password-env NFC mk/pw.xiz; no create-password-nfc-commitment-record; }
$A /append mk/new.xiz /src mk/extra.txt /folder src/sub /quiet /log app.log; wineserver -w
code app.log 0 && $X list mk/new.xiz | tr -d '\r' | grep -qx 'src/sub/extra.txt' && ok append || { cat app.log; no append; }
$A /remove mk/new.xiz /entry src/a.txt /quiet /log rm.log; wineserver -w
code rm.log 0 && ! $X list mk/new.xiz | tr -d '\r' | grep -qx 'src/a.txt' && $X test mk/new.xiz > /dev/null 2>&1 && ok remove || { cat rm.log; no remove; }
$A /append mk/pw.xiz /src mk/extra.txt /passenv NFD /quiet /log apppw.log; wineserver -w
code apppw.log 0 && $X list --password-env NFC mk/pw.xiz | tr -d '\r' | grep -qx 'extra.txt' && $X recovery info mk/pw.xiz > /dev/null 2>&1 \
    && ok append-password-keeps-record || { cat apppw.log; no append-password-keeps-record; }

# C2: recipients, folders, second factor, custodians, the user's own key (DPAPI).
export PA='alpha pass' PB='beta pass' PC1='cust one' PC2='cust two'
$A /keygen mine /pq /quiet /log kg.log; wineserver -w
sed -n 's/^public //p' kg.log | tr -d '\r' > mine.pub
code kg.log 0 && grep -q '^xizpq1' mine.pub && ok keygen-dpapi || { cat kg.log; no keygen-dpapi; }
mkdir -p c2/src/lab c2/src/doc && echo r1 > c2/src/lab/r1.txt && echo d1 > c2/src/doc/d1.txt
$A /new c2/a.xiz /src c2/src /to-pass PA /to-key mine.pub /only src/lab /to-factor PB c2/b.xizfactor \
   /custodians 2 /cust-pass PC1 /cust-pass PC2 /only src/lab /quiet /log c2new.log; wineserver -w
code c2new.log 0 && $X info --password-env PA c2/a.xiz | tr -d '\r' | grep -q 'XIZ 1.14' && ok c2-create || { cat c2new.log; no c2-create; }
[ "$($X list --password-env PA c2/a.xiz | tr -d '\r' | grep -c 'txt$')" = 2 ] && ok c2-password-all || no c2-password-all
[ "$($X list --password-env PB --factor c2/b.xizfactor c2/a.xiz | tr -d '\r' | grep -c 'txt$')" = 2 ] && ok c2-factor || no c2-factor
$X list --password-env PB c2/a.xiz > /dev/null 2>&1; [ $? = 3 ] && ok c2-factor-required || no c2-factor-required
L=$($X list --password-env PC1 --password-env PC2 c2/a.xiz | tr -d '\r')
echo "$L" | grep -q 'src/lab/r1.txt' && ! echo "$L" | grep -q 'src/doc/d1.txt' && ok c2-custodians-lab-only || { echo "$L"; no c2-custodians-lab-only; }
$A /x c2/a.xiz /d c2/out /quiet /log c2x.log; wineserver -w
code c2x.log 0 && [ -f c2/out/src/lab/r1.txt ] && [ ! -f c2/out/src/doc/d1.txt ] && ok c2-stored-key-opens-lab || { cat c2x.log; no c2-stored-key-opens-lab; }
$A /info c2/a.xiz /passenv PA /quiet /log c2i.log; wineserver -w
grep -q 'src/lab' c2i.log && grep -q 'custodians' c2i.log && ok c2-properties || { cat c2i.log; no c2-properties; }

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
    $A in/plain.xiz /folder tree/docs & sleep 8; shot folder 1
    wineserver -k; sleep 1
    $A in/plain.xiz & sleep 8; shot main 1
    xdotool key ctrl+e 2> /dev/null; shot extract-dialog 3
    xdotool key Escape 2> /dev/null; sleep 1
    xdotool key ctrl+t 2> /dev/null; shot verify-result 6
    wineserver -k; sleep 1
    $A in/password.xiz & shot password 8
    wineserver -k; sleep 1
    $A in/access.xiz & shot credentials 8
    xdotool type --delay 50 'beta secret' 2> /dev/null; xdotool key Return 2> /dev/null; shot partial 5
    xdotool key alt+Return 2> /dev/null; shot properties 3
    wineserver -k; sleep 1
    $A in/signed-pq.xiz & sleep 8
    xdotool key alt+f 2> /dev/null; sleep 1; xdotool key g 2> /dev/null; shot signatures 3
    wineserver -k; sleep 1
    $A & shot empty 8
    xdotool key ctrl+n 2> /dev/null; sleep 3
    xdotool key Tab Tab Tab Tab Tab Tab Tab space 2> /dev/null; sleep 1
    xdotool type --delay 40 'correct horse' 2> /dev/null; shot new-dialog 2
    wineserver -k; sleep 1
    # Windows links a CJK font to the UI fonts; under Wine the UI fonts are replaced by WenQuanYi (from
    # the image) for these shots, which has Latin, kana and Han.
    for f in Tahoma 'Segoe UI' 'MS Shell Dlg' 'MS Shell Dlg 2'; do
        wine reg add 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes' /v "$f" /t REG_SZ \
            /d 'WenQuanYi Micro Hei' /f > /dev/null 2>&1
    done
    wineserver -w
    $A /ui-access /to-pass PA /label Ufficio /to-key mine.pub /only src/lab /label Laboratorio /to-factor PB /tmp/f.xizfactor \
       /custodians 2 /cust-pass PC1 /cust-pass PC2 /label 'Custodi DPO' & shot access 8
    wineserver -k; sleep 1
    $A /ui-keys & shot keys 8
    wineserver -k; sleep 1
    for l in de ja zh-Hans; do XIZW_LANG=$l $A in/plain.xiz & shot "main-$l" 8; wineserver -k; sleep 1; done
    XIZW_LANG=fr $A in/access.xiz & shot credentials-fr 8
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
