#!/bin/bash
# xipper-forensic validation run (docs/forensic/VALIDAZIONE.md): every test case of the validation plan,
# run on this Mac, with a PASS/FAIL line per assertion and the logs, in dist/validation-VERSION/.
# Synthetic data only, plus the NIST CFReDS images when their downloads are given.
#
#   scripts/forensic-validation.sh [CFREDS_DOWNLOADS]
# Needs: swift, cmake, libewf and sleuthkit (brew install libewf sleuthkit), hdiutil (attaches small
# disk images, nothing else is touched).
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
VERSION=$(sed -nE 's/.*toolVersion = "([0-9.]+).*/\1/p' Sources/ForensicKit/ForensicReport.swift)
OUT="$ROOT/dist/validation-$VERSION"
rm -rf "$OUT" && mkdir -p "$OUT/logs"
W=$(mktemp -d "${TMPDIR:-/tmp}/xf-validation.XXXXXX")
trap 'for d in $(hdiutil info | awk "/^\/dev\/disk/ && /$(basename "$W")/ {print \$1}"); do hdiutil detach -force "$d" >/dev/null 2>&1; done; rm -rf "$W"' EXIT
RES="$OUT/RESULTS.md"
pass=0; fail=0
result() {  # ID STATUS TEXT
    printf '| %s | %s | %s |\n' "$1" "$2" "$3" >> "$RES"
    [ "$2" = PASS ] && pass=$((pass + 1)) || fail=$((fail + 1))
    printf '%-6s %-4s %s\n' "$1" "$2" "$3"
}
check() {  # ID TEXT command...
    local id=$1 text=$2; shift 2
    if "$@" > "$OUT/logs/$id.log" 2>&1; then result "$id" PASS "$text"; else result "$id" FAIL "$text (logs/$id.log)"; fi
}

echo "building (release)…"
swift build -c release --product xipper-forensic > "$OUT/logs/build.log" 2>&1 && swift build -c release --product xipper >> "$OUT/logs/build.log" 2>&1 \
    || { echo "build failed: $OUT/logs/build.log"; exit 1; }
cmake -S libxiz -B libxiz/build -DCMAKE_BUILD_TYPE=Release >> "$OUT/logs/build.log" 2>&1 && cmake --build libxiz/build -j >> "$OUT/logs/build.log" 2>&1 \
    || { echo "libxiz build failed"; exit 1; }
XF="$ROOT/.build/release/xipper-forensic"; X="$ROOT/.build/release/xipper"; XZ="$ROOT/libxiz/build/xiz"
"$X" keygen --signing -o "$W/key" > /dev/null

{
    echo "# Validation run — xipper-forensic $VERSION"
    echo
    echo "- Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "- Commit: $(git rev-parse --short HEAD)$(git diff --quiet || echo ' (with local changes)')"
    echo "- Mac: $(sysctl -n hw.model), $(sysctl -n machdep.cpu.brand_string), macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    echo "- Tools: $(swift --version 2>&1 | head -1); $(ewfverify -V 2>&1 | head -1); fls $(fls -V 2>&1 | head -1)"
    echo
    echo "| ID | Result | Assertion |"
    echo "|---|---|---|"
} > "$RES"

# V01 Hashes equal to shasum/md5 at the block boundaries; image read back by xipper and libxiz.
check V01 "SHA-256, SHA-1, MD5 of the source equal to shasum/md5 (0 B–13 MiB, block boundaries); image read back identical by xipper and libxiz" \
    scripts/forensic-hashes.sh

# V02–V05 A real device: a FAT32 disk image attached without mounting (raw device owned by the user).
mkdev() {
    hdiutil create -size 48m -fs "MS-DOS FAT32" -volname XFVAL -layout MBRSPUD "$W/dev.dmg" -quiet || return 1
    local v; v=$(hdiutil attach -nobrowse "$W/dev.dmg" 2>/dev/null | tail -1 | awk -F'\t' '{print $NF}')
    cp -R docs/forensic "$v/"; echo "validazione" > "$v/nota.txt"
    hdiutil detach "$v" -quiet
    DEV=$(hdiutil attach -nomount "$W/dev.dmg" 2>/dev/null | head -1 | awk '{print $1}' | sed 's|/dev/||')
    [ -n "$DEV" ]
}
if mkdev; then
    "$XF" case new "$W/V.xfcase" --case VALIDAZIONE --examiner Validazione --sign "$W/key" > "$OUT/logs/V02.log" 2>&1
    check V02 "Whole disk read raw: archive image SHA-256 = shasum of /dev/rdisk; libxiz verifies the archive" bash -c "
        set -e
        want=\$(shasum -a 256 /dev/r$DEV | cut -d' ' -f1)
        '$XF' acquire --device $DEV --in '$W/V.xfcase' --evidence-id R01 --sign '$W/key' | tee /dev/stderr | grep -q \"SHA-256  \$want\"
        '$XZ' forensic '$W/V.xfcase/evidence/R01/R01.xiz'
        '$XF' export '$W/V.xfcase/evidence/R01/R01.xiz' --raw - | shasum -a 256 | grep -q \$want"
    check V03 "One partition read raw (volume, offset recorded): SHA-256 = shasum of /dev/rdiskNs1" bash -c "
        set -e
        want=\$(shasum -a 256 /dev/r${DEV}s1 | cut -d' ' -f1)
        '$XF' acquire --device ${DEV}s1 -o '$W/part.xiz' --sign '$W/key' | grep -q \"SHA-256  \$want\"
        '$XF' info '$W/part.xiz' | grep -q 'partition_offset='"
    check V04 "Mounted volumes refused unless --unmount (then unmounted and acquired); a destination on the source disk and the startup disk refused" bash -c "
        set -e
        hdiutil detach $DEV -quiet; D2=\$(hdiutil attach -nobrowse '$W/dev.dmg' 2>/dev/null | head -1 | awk '{print \$1}' | sed 's|/dev/||')
        ! '$XF' acquire --device \$D2 -o '$W/m.xiz' --sign '$W/key'
        vol=\$(mount | awk -v d="/dev/\${D2}s1" '\$1 == d {print \$3}')
        '$XF' acquire --device \$D2 -o "\$vol/dentro.xiz" --sign '$W/key' --unmount 2>&1 | grep -q 'destination is on the source disk'
        '$XF' acquire --device \$D2 -o '$W/m.xiz' --sign '$W/key' --unmount
        ! mount | grep -q \"/dev/\${D2}s1 \"
        boot=\$('$XF' disks | awk '/STARTUP DISK/ {print \$1}')
        ! '$XF' acquire --device \$boot -o '$W/b.xiz' --sign '$W/key'
        hdiutil detach \$D2 -quiet"
    check V05 "Mounts of the evidence disk refused while it is read (Disk Arbitration), allowed after" \
        env XIPPER_DISK_TESTS=1 swift test --filter DisksTests
else
    result V02 FAIL "could not attach a test disk image"
fi

# V06 Read errors: retries, sector granularity, zeros, map; vanished source stops.
check V06 "Unreadable sectors: retried, narrowed to the sector, zero-filled, mapped with errno; a vanished source stops the acquisition" \
    swift test --filter XizImageSourceTests

# V07 Logical acquisition with unreadable and special items.
check V07 "Logical: every item in the signed inventory (also unreadable files and FIFOs); content verified by xipper and libxiz" bash -c "
    set -e
    mkdir -p '$W/L/sub'; echo uno > '$W/L/a.txt'; head -c 5000000 /dev/urandom > '$W/L/sub/b.bin'; ln -s a.txt '$W/L/link'
    mkfifo '$W/L/fifo'; echo segreto > '$W/L/locked.txt'; chmod 000 '$W/L/locked.txt'
    '$XF' acquire --logical '$W/L' -o '$W/L.xiz' --sign '$W/key' | tee /dev/stderr | grep -q 'not acquired: 2'
    '$XF' verify '$W/L.xiz' | tail -1 | grep -q verified
    '$XZ' forensic '$W/L.xiz'
    chmod 600 '$W/L/locked.txt'"

# V08 Tampering and truncation.
check V08 "A changed byte anywhere is detected (xipper and libxiz); truncation to an earlier segment is detected with the SHA-256 from the record" bash -c "
    set -e
    head -c 9000000 /dev/urandom > '$W/t.img'
    '$XF' acquire --image '$W/t.img' -o '$W/t.xiz' --sign '$W/key' > /dev/null
    size=\$(stat -f %z '$W/t.xiz'); cp '$W/t.xiz' '$W/t0.xiz'
    '$XF' custody '$W/t.xiz' --from A --to B --sign '$W/key' > /dev/null
    full=\$(shasum -a 256 '$W/t.xiz' | cut -d' ' -f1)
    for off in 5000 4500000 \$((size - 200)); do
        cp '$W/t.xiz' '$W/x.xiz'; printf '\\x55' | dd of='$W/x.xiz' bs=1 seek=\$off conv=notrunc 2>/dev/null
        ! '$XF' verify '$W/x.xiz' > /dev/null; ! '$XZ' forensic '$W/x.xiz' > /dev/null 2>&1
    done
    ! '$XF' verify '$W/t0.xiz' --expect-sha256 \$full > /dev/null
    '$XF' verify '$W/t.xiz' --expect-sha256 \$full | tail -1 | grep -q verified"

# V09 Custody chain: five hand-overs, all signed and chained, content keys not needed.
check V09 "Five hand-overs appended to an encrypted archive without its password; chain of six signatures verified by xipper and libxiz" bash -c "
    set -e
    head -c 3000000 /dev/urandom > '$W/c.img'
    XFPW=segretissima '$XF' acquire --image '$W/c.img' -o '$W/c.xiz' --sign '$W/key' --password-env XFPW > /dev/null
    for i in 1 2 3 4 5; do '$XF' custody '$W/c.xiz' --from P\$i --to P\$((i + 1)) --sign '$W/key' > /dev/null; done
    '$XF' verify '$W/c.xiz' | grep -q '6 segments, 5 of custody'
    test \$('$XZ' history '$W/c.xiz' | grep -c 'signature valid, chain ok') -eq 6"

# V10 Case log and reports.
check V10 "Case log chained and signed; reports (JSON, PDF) signed; a changed log line or a replaced report is detected" bash -c "
    set -e
    '$XF' case verify '$W/V.xfcase' | tail -1 | grep -q 'case verified'
    cp -R '$W/V.xfcase' '$W/V2.xfcase'
    sed -i '' '2s/R01/R99/' '$W/V2.xfcase/case.log'
    ! '$XF' case verify '$W/V2.xfcase' > /dev/null
    cp -R '$W/V.xfcase' '$W/V3.xfcase'; echo x >> '$W/V3.xfcase/evidence/R01/R01.report.pdf'
    ! '$XF' case verify '$W/V3.xfcase' > /dev/null
    '$XF' report --check '$W/V.xfcase/evidence/R01/R01.report.pdf' | grep -q 'signature valid'"

# V11 E01 with libewf and The Sleuth Kit.
check V11 "E01 written by Xipper verified by ewfverify (also in segments, with error2); same fls listing as raw; libewf's E01 imported with equal hashes" \
    scripts/e01-check.sh "$W/e01"

# V12 Certificates, trusted lists, delivery, unit and integration tests of the forensic code.
check V12 "Certificate signatures (EC, RSA; libxiz too), trusted list status in time, delivery copies, case and report tests" \
    swift test --filter "XizForensicTests|ForensicCaseTests|XizCertificateTests|TrustedListTests|EWFTests|DeliveryTests"

# V13 libxiz's own tests (fixtures written by Swift, hostile inputs).
check V13 "libxiz unit, fixture and hostile-input tests" ctest --test-dir libxiz/build --output-on-failure

# V14 NIST CFReDS reference images (MD5/SHA-1 published by NIST), when the downloads are given.
if [ -n "${1:-}" ]; then
    check V14 "NIST CFReDS images: MD5 and SHA-1 equal to NIST's; image read back identical" scripts/cfreds-check.sh "$1" "$W/cfreds"
else
    printf '| V14 | not run | NIST CFReDS images (give the downloads folder; last run 2026-11-10, P2: 4 images, all equal) |\n' >> "$RES"
fi

{
    echo
    echo "**$pass passed, $fail failed.**"
} >> "$RES"
echo
echo "$pass passed, $fail failed — $RES"
[ $fail -eq 0 ]
