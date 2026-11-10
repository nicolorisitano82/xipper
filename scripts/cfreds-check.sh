#!/bin/bash
# xipper-forensic against NIST CFReDS reference images: the MD5 and SHA-1 it computes while acquiring
# must be the ones NIST publishes, and the image read back from the archive (xipper and libxiz) must
# hash the same. Hashes below are copied from the CFReDS pages (answers PDFs for the Data Leakage Case).
#
# Usage: scripts/cfreds-check.sh DOWNLOADS [WORK]
#   DOWNLOADS holds the files as downloaded from cfreds-archive.nist.gov:
#     DFRWS2005-RODEO.zip                          (Rhino Hunt, dfrws/Rhino_Hunt.html)
#     macwd.bz2                                    (Basic Mac Image, v2/Basic_Mac_Image.html)
#     cfreds_2015_data_leakage_rm#3_type2.7z       (Data Leakage Case, RM#3 CD-R as dd)
#     cfreds_2015_data_leakage_rm#2.7z             (Data Leakage Case, RM#2 USB, about 4 GB unpacked)
#   Images are unpacked into WORK (default: a temporary folder) and never into the repository.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DL=$(cd "${1:?downloads folder}" && pwd)
W=${2:-$(mktemp -d "${TMPDIR:-/tmp}/xipper-cfreds.XXXXXX")}
mkdir -p "$W"
XF="$ROOT/.build/release/xipper-forensic"; X="$ROOT/.build/release/xipper"; XZ="$ROOT/libxiz/build/xiz"
for b in "$XF" "$X" "$XZ"; do [ -x "$b" ] || { echo "missing $b (build it first)"; exit 2; }; done
command -v 7zz > /dev/null || { echo "7zz (7-Zip) is needed to unpack the Data Leakage images"; exit 2; }
"$X" keygen --signing -o "$W/k" > /dev/null 2>&1 || true

lower() { tr 'A-F' 'a-f'; }
fails=0
run() {  # NAME IMAGE MD5 SHA1(or -)
    local name=$1 img=$2 md5=$(lower <<< "$3") sha1=$(lower <<< "$4") out="$W/$1.xiz"
    rm -f "$out"
    local t0=$SECONDS log
    log=$("$XF" acquire --image "$img" -o "$out" --sign "$W/k" --signer CFReDS --case CFReDS --evidence "$name")
    local secs=$((SECONDS - t0))
    local got_md5 got_sha1 got_256
    got_md5=$(sed -n 's/^MD5 *//p' <<< "$log"); got_sha1=$(sed -n 's/^SHA-1 *//p' <<< "$log"); got_256=$(sed -n 's/^SHA-256 *//p' <<< "$log")
    local back_md5 ok=1 why=""
    back_md5=$("$XZ" cat "$out" image.dd | md5 -q)
    [ "$got_md5" = "$md5" ] || { ok=0; why="$why MD5 $got_md5≠$md5"; }
    [ "$sha1" = "-" ] || [ "$got_sha1" = "$sha1" ] || { ok=0; why="$why SHA-1 $got_sha1≠$sha1"; }
    [ "$back_md5" = "$md5" ] || { ok=0; why="$why libxiz read-back MD5 $back_md5"; }
    "$XF" verify "$out" --expect-sha256 "$got_256" > /dev/null || { ok=0; why="$why xipper-forensic verify"; }
    "$XZ" forensic "$out" > /dev/null || { ok=0; why="$why xiz forensic"; }
    local isz osz
    isz=$(stat -f %z "$img"); osz=$(stat -f %z "$out")
    if [ $ok = 1 ]; then
        printf "ok    %-14s %13d → %12d bytes in %3ds  MD5 %s%s\n" "$name" "$isz" "$osz" "$secs" "$md5" "$([ "$sha1" = - ] || echo "  SHA-1 $sha1")"
    else
        printf "FAIL  %-14s%s\n" "$name" "$why"; fails=$((fails + 1))
    fi
    rm -f "$out"
}

if [ -f "$DL/DFRWS2005-RODEO.zip" ]; then
    [ -f "$W/RHINOUSB.dd" ] || unzip -q -o "$DL/DFRWS2005-RODEO.zip" RHINOUSB.dd -d "$W"
    run rhino "$W/RHINOUSB.dd" 80348c58eec4c328ef1f7709adc56a54 -
fi
if [ -f "$DL/macwd.bz2" ]; then
    [ -f "$W/macwd.dd" ] || bzip2 -dc "$DL/macwd.bz2" > "$W/macwd.dd"
    run basic-mac "$W/macwd.dd" 98116DC10E4B090B62321F1E4464973A cb86d7677eda9baa2e2d99f09810c46ea635e3ce
fi
unpack7z() {  # ARCHIVE DIR → the single largest file inside
    [ -d "$2" ] || { mkdir -p "$2"; 7zz x -y -bso0 -bsp0 -o"$2" "$1"; }
    find "$2" -type f -exec stat -f '%z %N' {} + | sort -n | tail -1 | cut -d' ' -f2-
}
if [ -f "$DL/cfreds_2015_data_leakage_rm#3_type2.7z" ]; then
    run leakage-rm3 "$(unpack7z "$DL/cfreds_2015_data_leakage_rm#3_type2.7z" "$W/rm3")" 858C7250183A44DD83EB706F3F178990 471D3EEDCA9ADD872FC0708297284E1960FF44F8
fi
if [ -f "$DL/cfreds_2015_data_leakage_rm#2.7z" ]; then
    run leakage-rm2 "$(unpack7z "$DL/cfreds_2015_data_leakage_rm#2.7z" "$W/rm2")" B4644902ACAB4583A1D0F9F1A08FAA77 048961A85CA3ECED8CC73F1517442D31D4DCA0A3
fi
[ $fails = 0 ] && echo "CFReDS: all hashes match NIST's" || { echo "CFReDS: $fails failed"; exit 1; }
