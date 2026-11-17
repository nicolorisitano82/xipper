#!/bin/zsh
# Xipper XIZ for Windows under Barrique: the native Apple Silicon Wine of ~/Work/wine (Windows code in
# a Hypervisor.framework VM, x86-64 translated by FEX). Both builds of the app: aarch64 (native) and
# x86_64 (FEX, ARM64EC). Command-line modes only (no windows on screen); references come from the
# macOS xiz. Own prefix in .build/windows-app/barrique-prefix: the Wine project's prefixes stay as they are.
#   windows/test-barrique.sh [aarch64|x86_64 ...]
set -u
zmodload zsh/datetime
cd "$(dirname "$0")/.."
ROOT=$PWD
W=$HOME/Work/wine
WINE=$W/build-arm64ec/wine
[[ -x $WINE ]] || { echo "SKIP: no Barrique build at $WINE"; exit 77; }
XIZ=$ROOT/libxiz/build/xiz
[[ -x $XIZ ]] || { echo "libxiz/build/xiz missing (cmake --build libxiz/build)"; exit 2; }
export WINEPREFIX=$ROOT/.build/windows-app/barrique-prefix WINE_HVF=1 WINEDLLPATH=$W/fex-dlls
export WINEDLLOVERRIDES="mscoree=d;mshtml=d" WINEDEBUG=${WINEDEBUG:--all}
F=$ROOT/libxiz/tests/fixtures
T=$(mktemp -d)
trap 'rm -rf $T; $W/build-arm64ec/server/wineserver -k 2> /dev/null' EXIT
export PW='correct horse battery staple' WRONG='not the password'
export XIZ_PW_A='alpha secret' XIZ_PW_B='beta secret' XIZ_PW_C1='custodian one' XIZ_PW_C2='custodian two' XIZ_PW_C3='custodian three'
winpath() { print -r -- "Z:${1//\//\\}"; }
# Regular files and their SHA-256. Symbolic links are left out: Barrique keeps a Windows symlink as an
# empty host file named "<name>?" with the reparse data in the xattr user.WINEREPARSE.
tree() { (cd "$1" && find . -type f ! -name '*\?' -exec shasum -a 256 {} + | sort); }
code() { [[ "$(sed -n 's/^exit //p' "$1")" == "$2" ]]; }
[[ -d $WINEPREFIX/drive_c ]] || { echo "creating the prefix (wineboot)…"; timeout 600 $WINE wineboot -i > $T/boot.log 2>&1; }

# References from the macOS xiz.
mkdir -p $T/ref
$XIZ extract -d $T/ref/plain $F/plain.xiz > /dev/null
$XIZ extract -d $T/ref/pw --password-env PW $F/password.xiz > /dev/null
$XIZ extract -d $T/ref/all --password-env XIZ_PW_A $F/access.xiz > /dev/null
$XIZ extract -d $T/ref/g1 --identity $F/identity.key $F/access.xiz > /dev/null
$XIZ extract -d $T/ref/pq --identity $F/identity-pq.key $F/access-pq.xiz > /dev/null
mkdir -p $T/src && echo x > $T/src/f.txt
export NFC=$(printf 'p\303\244ssw\303\266rd') NFD=$(printf 'pa\314\210sswo\314\210rd')
XIZ_TEST_FAST_KDF=1 $XIZ create --password-env NFC $T/nfc.xiz $T/src > /dev/null
cp $F/plain.xiz $T/rec.xiz && $XIZ recovery add --redundancy 10 $T/rec.xiz > /dev/null
printf '\377\377\377\377\377\377\377\377' | dd of=$T/rec.xiz bs=1 seek=300 conv=notrunc 2> /dev/null

archs=("$@"); (( $#archs )) || archs=(aarch64 x86_64)
total_bad=0
for arch in $archs; do
    EXE=$ROOT/.build/windows-app/$arch/XipperXIZ.exe
    [[ -f $EXE ]] || { echo "$arch: no build (windows/build.sh $arch)"; total_bad=$((total_bad + 1)); continue; }
    O=$T/$arch; mkdir -p $O
    pass=0 bad=0
    ok() { print "ok   $arch $1"; pass=$((pass + 1)); }
    no() { print "FAIL $arch $1"; bad=$((bad + 1)); }
    A() { XIZW_LANG=${XIZW_LANG:-en} timeout 300 $WINE $(winpath $EXE) "$@" > /dev/null 2>&1; }
    t0=$EPOCHREALTIME

    A /x $(winpath $F/plain.xiz) /d $(winpath $O/plain) /quiet /log $(winpath $O/plain.log)
    code $O/plain.log 0 && [[ "$(tree $O/plain)" == "$(tree $T/ref/plain)" ]] && ok extract || { cat $O/plain.log; no extract; }
    A /x $(winpath $F/plain.xiz) /d $(winpath $O/plain) /quiet /keep-both /log $(winpath $O/both.log)
    code $O/both.log 0 && grep -q '^renamed [1-9]' $O/both.log && ok keep-both || { cat $O/both.log; no keep-both; }
    A /x $(winpath $F/password.xiz) /d $(winpath $O/pw) /passenv PW /quiet /log $(winpath $O/pw.log)
    code $O/pw.log 0 && [[ "$(tree $O/pw)" == "$(tree $T/ref/pw)" ]] && ok password || { cat $O/pw.log; no password; }
    A /x $(winpath $F/password.xiz) /d $(winpath $O/wrong) /passenv WRONG /quiet /log $(winpath $O/wrong.log)
    code $O/wrong.log 3 && ok password-wrong || { cat $O/wrong.log; no password-wrong; }
    A /x $(winpath $F/factor.xiz) /d $(winpath $O/factor) /passenv PW /factor $(winpath $F/factor.xizfactor) /quiet /log $(winpath $O/factor.log)
    code $O/factor.log 0 && [[ "$(tree $O/factor)" == "$(tree $T/ref/pw)" ]] && ok factor || { cat $O/factor.log; no factor; }
    A /t $(winpath $T/nfc.xiz) /passenv NFD /quiet /log $(winpath $O/nfd.log)
    code $O/nfd.log 0 && ok password-nfc || { cat $O/nfd.log; no password-nfc; }
    A /x $(winpath $F/access.xiz) /d $(winpath $O/all) /passenv XIZ_PW_A /quiet /log $(winpath $O/all.log)
    code $O/all.log 0 && [[ "$(tree $O/all)" == "$(tree $T/ref/all)" ]] && ok groups-all || { cat $O/all.log; no groups-all; }
    A /x $(winpath $F/access.xiz) /d $(winpath $O/key) /identity $(winpath $F/identity.key) /quiet /log $(winpath $O/key.log)
    code $O/key.log 0 && [[ "$(tree $O/key)" == "$(tree $T/ref/g1)" ]] && ok recipient-key || { cat $O/key.log; no recipient-key; }
    A /x $(winpath $F/access.xiz) /d $(winpath $O/thr) /passenv XIZ_PW_C1 /passenv XIZ_PW_C3 /quiet /log $(winpath $O/thr.log)
    code $O/thr.log 0 && [[ "$(tree $O/thr)" == "$(tree $T/ref/g1)" ]] && ok custodians || { cat $O/thr.log; no custodians; }
    A /x $(winpath $F/access-pq.xiz) /d $(winpath $O/pq) /identity $(winpath $F/identity-pq.key) /quiet /log $(winpath $O/pq.log)
    code $O/pq.log 0 && [[ "$(tree $O/pq)" == "$(tree $T/ref/pq)" ]] && ok post-quantum || { cat $O/pq.log; no post-quantum; }
    A /info $(winpath $F/signed-pq.xiz) /quiet /log $(winpath $O/sig.log)
    grep -q 'ML-DSA-65 (post-quantum)  valid' $O/sig.log && ok signatures || { cat $O/sig.log; no signatures; }
    A /info $(winpath $F/signed-pq-tampered.xiz) /quiet /log $(winpath $O/sigt.log)
    grep -q 'INVALID' $O/sigt.log && ok signatures-tampered || { cat $O/sigt.log; no signatures-tampered; }
    cp $T/rec.xiz $O/rec.xiz
    A /repair $(winpath $O/rec.xiz) /quiet /log $(winpath $O/rep.log)
    code $O/rep.log 0 && $XIZ test "$O/rec (repaired).xiz" > /dev/null 2>&1 && cmp -s $O/rec.xiz $T/rec.xiz && ok repair-copy || { cat $O/rep.log; no repair-copy; }
    A /temp-extract $(winpath $F/plain.xiz) /d tree/docs/a.md /quiet /log $(winpath $O/tmp.log)
    code $O/tmp.log 0 && grep -q 'a.md$' $O/tmp.log && [[ ! -f $O/tmp.log.left ]] && ok temp-extract || { cat $O/tmp.log; no temp-extract; }
    XIZW_LANG=ja A /x $(winpath $T/missing.xiz) /quiet /log $(winpath $O/ja.log)
    grep -q '開けません' $O/ja.log && ok language-ja || { cat $O/ja.log; no language-ja; }
    # C1: archives written on "Windows", checked by Xipper for Mac.
    mkdir -p $O/src/sub && echo uno > $O/src/a.txt && head -c 300000 /dev/urandom > $O/src/sub/b.bin
    A /new $(winpath $O/new.xiz) /src $(winpath $O/src) /passenv NFD /recovery /quiet /log $(winpath $O/new.log)
    if code $O/new.log 0 && [[ -x $ROOT/.build/release/xipper ]]; then
        print -r -- "$NFC" | $ROOT/.build/release/xipper test --password-stdin $O/new.xiz > $O/mac.log 2>&1 && ok create-read-by-xipper-mac || { cat $O/new.log $O/mac.log; no create-read-by-xipper-mac; }
    else
        code $O/new.log 0 && ok create || { cat $O/new.log; no create; }
    fi
    # C2: groups, keys, factor, custodians written on "Windows", read by Xipper for Mac.
    if [[ -x $ROOT/.build/release/xipper ]]; then
        XM=$ROOT/.build/release/xipper
        $XM keygen --pq -o $O/mac.key > $O/kg.log 2>&1
        grep -o 'xizpq1[A-Za-z0-9_-]*' $O/kg.log | head -1 > $O/mac.pub
        [[ -s $O/mac.pub ]] || $XM keygen --help > /dev/null 2>&1
        mkdir -p $O/c2/lab $O/c2/doc && echo r1 > $O/c2/lab/r1.txt && echo d1 > $O/c2/doc/d1.txt
        export PA='alpha pass' PB='beta pass' PC1='cust one' PC2='cust two'
        A /new $(winpath $O/c2.xiz) /src $(winpath $O/c2) /to-pass PA /to-key $(winpath $O/mac.pub) /only c2/lab \
          /to-factor PB $(winpath $O/b.xizfactor) /custodians 2 /cust-pass PC1 /cust-pass PC2 /quiet /log $(winpath $O/c2.log)
        print -r -- "$PA" | $XM test --password-stdin $O/c2.xiz > $O/m1.log 2>&1 && ok c2-mac-password || { cat $O/c2.log $O/m1.log; no c2-mac-password; }
        $XM list --identity $O/mac.key $O/c2.xiz > $O/m2.log 2>&1
        grep -q 'c2/lab/r1.txt' $O/m2.log && ! grep -q 'c2/doc/d1.txt' $O/m2.log && ok c2-mac-key-lab-only || { cat $O/kg.log $O/m2.log; no c2-mac-key-lab-only; }
        print -r -- "$PB" | $XM test --factor $O/b.xizfactor --password-stdin $O/c2.xiz > $O/m3.log 2>&1 && ok c2-mac-factor || { cat $O/m3.log; no c2-mac-factor; }
        printf '%s\n%s\n' "$PC1" "$PC2" | $XM test --password-stdin $O/c2.xiz > $O/m4.log 2>&1 && ok c2-mac-custodians || { cat $O/m4.log; no c2-mac-custodians; }
        echo nuovo > $O/extra.txt
        A /append $(winpath $O/c2.xiz) /src $(winpath $O/extra.txt) /folder c2/lab /passenv PA /quiet /log $(winpath $O/c2a.log)
        $XM list --identity $O/mac.key $O/c2.xiz > $O/m5.log 2>&1
        grep -q 'c2/lab/extra.txt' $O/m5.log && print -r -- "$PA" | $XM test --password-stdin $O/c2.xiz > $O/m6.log 2>&1 \
            && ok c2-mac-reads-append || { cat $O/c2a.log $O/m5.log $O/m6.log; no c2-mac-reads-append; }
    fi
    printf "%s: %d passed, %d failed, %.0f s\n" $arch $pass $bad $(( EPOCHREALTIME - t0 ))
    total_bad=$((total_bad + bad))
done
(( total_bad == 0 )) && print "barrique ok" || { print "barrique: $total_bad failures"; exit 1; }
