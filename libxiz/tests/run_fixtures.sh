#!/bin/sh
# End-to-end tests of the xiz CLI on archives written by Xipper (tests/fixtures, see
# make_fixtures.sh). Usage: run_fixtures.sh path/to/xiz path/to/fixtures
set -u
XIZ=$1
F=$2
M=$(dirname "$XIZ")/xiz_manifest
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

export PW='correct horse battery staple' WRONG='not the password'
export XIZ_PW_A='alpha secret' XIZ_PW_B='beta secret' XIZ_PW_C1='custodian one' XIZ_PW_C2='custodian two' XIZ_PW_C3='custodian three'

# extract_cmp NAME ARCHIVE MANIFEST [manifest options] -- [xiz options]
extract_cmp() {
    name=$1 archive=$2 manifest=$3; shift 3
    mopt="" skiproot=""
    if [ "${1:-}" = "--no-mtime" ]; then mopt=--no-mtime; shift; fi
    if [ "${1:-}" = "--skip-root" ]; then skiproot=1; shift; fi  # "tree" is created implicitly
    [ "${1:-}" = "--" ] && shift
    d=$W/$name
    rm -rf "$d"; mkdir -p "$d"
    if ! "$XIZ" extract -d "$d" "$@" "$F/$archive" > "$W/$name.log" 2>&1; then
        fail "$name: extract failed: $(tail -2 "$W/$name.log")"; return
    fi
    "$M" $mopt "$d" > "$W/$name.m"
    if [ -n "$skiproot" ]; then grep -v "^tree	" "$W/$name.m" > "$W/$name.m2"; mv "$W/$name.m2" "$W/$name.m"; fi
    if diff "$W/$name.m" "$F/$manifest" > "$W/$name.diff"; then pass "$name"; else fail "$name: tree differs"; head -5 "$W/$name.diff"; fi
}

expect_code() {  # NAME CODE command...
    name=$1 want=$2; shift 2
    "$@" > "$W/out.log" 2>&1
    got=$?
    if [ "$got" = "$want" ]; then pass "$name"; else fail "$name: exit $got, expected $want ($(tail -1 "$W/out.log"))"; fi
}

# ---------------------------------------------------------------- 1.0, 1.2, 1.4, passwords
extract_cmp plain plain.xiz tree.manifest
extract_cmp level19 level19.xiz tree.manifest
extract_cmp lzma2 lzma2.xiz tree.manifest
extract_cmp lzma2-arm64 lzma2-arm64.xiz arm64.manifest
extract_cmp dictionaries dict.xiz dict.manifest
extract_cmp password password.xiz tree.manifest -- --password-env PW
extract_cmp password-lzma2 password-lzma2.xiz tree.manifest -- --password-env PW
expect_code no-password 3 "$XIZ" list "$F/password.xiz"
expect_code wrong-password 3 "$XIZ" list --password-env WRONG "$F/password.xiz"
for a in plain level19 lzma2 lzma2-arm64 dict appended signed; do expect_code "test-$a" 0 "$XIZ" test "$F/$a.xiz"; done
expect_code test-password 0 "$XIZ" test --password-env PW "$F/password.xiz"
"$XIZ" info "$F/lzma2-arm64.xiz" | grep -q 'ARM64+LZMA2 1' && pass codec-arm64 || fail codec-arm64
"$XIZ" info "$F/dict.xiz" | grep -q 'dictionaries    1' && pass dictionary-frame || fail dictionary-frame

# cat
"$XIZ" cat "$F/plain.xiz" tree/docs/a.md > "$W/a.md" && grep -q 'Line 199 of a document about nothing' "$W/a.md" && pass cat || fail cat
"$XIZ" cat --password-env PW "$F/password.xiz" tree/link-to-a | grep -qx 'docs/a.md' && pass cat-symlink || fail cat-symlink

# ---------------------------------------------------------------- 1.1 appended segments
extract_cmp appended appended.xiz appended.manifest --no-mtime
extract_cmp password-appended password-appended.xiz password-appended.manifest --no-mtime -- --password-env PW
"$XIZ" info "$F/appended.xiz" | grep -q 'segments        3' && pass segments-3 || fail segments-3
# An interrupted append: junk after the last footer is ignored (§11).
cp "$F/appended.xiz" "$W/torn.xiz"; printf 'XFR1 partial frame of an interrupted append' >> "$W/torn.xiz"
expect_code interrupted-append 0 "$XIZ" test "$W/torn.xiz"

# ---------------------------------------------------------------- 1.3 access groups
extract_cmp access-all access.xiz tree.manifest -- --password-env XIZ_PW_A
extract_cmp access-group0 access.xiz group0.manifest -- --password-env XIZ_PW_B
extract_cmp access-identity access.xiz group1.manifest --skip-root -- --identity "$F/identity.key"
extract_cmp access-threshold access.xiz group1.manifest --skip-root -- --password-env XIZ_PW_C1 --password-env XIZ_PW_C3
expect_code access-one-custodian 3 "$XIZ" list --password-env XIZ_PW_C2 "$F/access.xiz"
grep -q 'needs 2 custodians' "$W/out.log" && pass threshold-message || fail threshold-message
expect_code access-wrong 3 "$XIZ" list --password-env WRONG "$F/access.xiz"
"$XIZ" info --password-env XIZ_PW_B "$F/access.xiz" | grep -q '(1 hidden)' && pass hidden-group || fail hidden-group

# ---------------------------------------------------------------- 1.3 signatures, proofs, erasure
"$XIZ" history "$F/signed.xiz" > "$W/h.log" 2>&1
if [ "$(grep -c 'signature valid, chain ok' "$W/h.log")" = 2 ] && grep -q 'inclusion tree  ok' "$W/h.log"; then pass history; else fail history; cat "$W/h.log"; fi
"$XIZ" extract -d "$W/signed" "$F/signed.xiz" > /dev/null 2>&1
expect_code proof-valid 0 "$XIZ" verify-proof "$F/proof-a.json" "$W/signed/tree/docs/a.md"
printf 'tampered\n' >> "$W/signed/tree/docs/a.md"
expect_code proof-tampered 1 "$XIZ" verify-proof "$F/proof-a.json" "$W/signed/tree/docs/a.md"
extract_cmp erasable erasable.xiz tree.manifest -- --password-env XIZ_PW_A
"$XIZ" info --password-env XIZ_PW_A "$F/erased.xiz" | grep -q 'entries         23 (23 visible)' && pass erased-removed || fail erased-removed
"$XIZ" list --password-env XIZ_PW_A "$F/erased.xiz" | grep -q 'docs/b.md' && fail erased-hidden || pass erased-hidden
expect_code erased-test 0 "$XIZ" test --password-env XIZ_PW_A "$F/erased.xiz"
"$XIZ" history "$F/erased.xiz" | grep -q 'signature valid' && pass erased-signature-holds || fail erased-signature-holds

# ---------------------------------------------------------------- damage
cp "$F/plain.xiz" "$W/flip.xiz"
printf '\377' | dd of="$W/flip.xiz" bs=1 seek=200 conv=notrunc 2> /dev/null
expect_code flipped-frame-byte 1 "$XIZ" test "$W/flip.xiz"
head -c 20000 "$F/plain.xiz" > "$W/trunc.xiz"
expect_code truncated 1 "$XIZ" list "$W/trunc.xiz"

[ $fails = 0 ] && echo "fixtures: all passed" || echo "fixtures: $fails failed"
[ $fails = 0 ]
