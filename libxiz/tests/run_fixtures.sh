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

# 1.6: brunsli JPEG frames (two JPEG frames, the copy deduplicated, fake.jpg in an ordinary frame)
if "$XIZ" info "$F/jpeg.xiz" > "$W/jpeg-info.log" 2>&1; then
    extract_cmp jpeg jpeg.xiz jpeg.manifest
    extract_cmp password-jpeg password-jpeg.xiz jpeg.manifest -- --password-env PW
    expect_code test-jpeg 0 "$XIZ" test "$F/jpeg.xiz"
    grep -q 'JPEG 2,' "$W/jpeg-info.log" && pass codec-jpeg || fail codec-jpeg
    "$XIZ" cat "$F/jpeg.xiz" photos/photo2.jpg > "$W/photo2.jpg" && cmp -s "$W/photo2.jpg" "$W/jpeg/photos/photo2.jpg" && pass cat-jpeg || fail cat-jpeg
else
    grep -q 'built without brunsli' "$W/jpeg-info.log" && pass jpeg-refused-cleanly || fail "jpeg: $(tail -1 "$W/jpeg-info.log")"
fi

# 1.9: documents with their Deflate streams split by preflate (PNG, PDF, DOCX: three preflate frames)
if "$XIZ" info "$F/docs.xiz" > "$W/docs-info.log" 2>&1; then
    extract_cmp docs docs.xiz docs.manifest
    expect_code test-docs 0 "$XIZ" test "$F/docs.xiz"
    grep -q 'preflate 3,' "$W/docs-info.log" && pass codec-preflate || fail "codec-preflate: $(grep frames "$W/docs-info.log")"
else
    grep -q 'built without preflate' "$W/docs-info.log" && pass docs-refused-cleanly || fail "docs: $(tail -1 "$W/docs-info.log")"
fi

# 1.11: delimited tables in OpenZL frames (a CSV and a BED: two OpenZL frames)
if "$XIZ" info "$F/tables.xiz" > "$W/tables-info.log" 2>&1; then
    extract_cmp tables tables.xiz tables.manifest
    expect_code test-tables 0 "$XIZ" test "$F/tables.xiz"
    grep -q 'OpenZL 2)' "$W/tables-info.log" && pass codec-openzl || fail "codec-openzl: $(grep frames "$W/tables-info.log")"
else
    grep -q 'built without OpenZL' "$W/tables-info.log" && pass tables-refused-cleanly || fail "tables: $(tail -1 "$W/tables-info.log")"
fi

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
# 1.12: hybrid Ed25519 + ML-DSA-65 signatures (§22), written by Xipper with CryptoKit, checked with
# mldsa-native; one bit of the ML-DSA half flipped; an algorithm this reader does not know.
"$XIZ" history "$F/signed-pq.xiz" > "$W/hpq.log" 2>&1
[ "$(grep -c 'xizsigpq1:.*(Ed25519 + ML-DSA-65)  signature valid, chain ok' "$W/hpq.log")" = 2 ] && pass history-hybrid || fail "history-hybrid: $(cat "$W/hpq.log")"
expect_code test-hybrid 0 "$XIZ" test "$F/signed-pq.xiz"
"$XIZ" history "$F/signed-pq-tampered.xiz" > "$W/hpqt.log" 2>&1
grep -q '^#0 .*signature INVALID' "$W/hpqt.log" && grep -q '^#1 .*signature valid, chain BROKEN' "$W/hpqt.log" && pass history-hybrid-tampered || fail "history-hybrid-tampered: $(cat "$W/hpqt.log")"
expect_code history-hybrid-tampered-exit 1 "$XIZ" history "$F/signed-pq-tampered.xiz"
"$XIZ" history "$F/signed-pq-unknown.xiz" > "$W/hpqu.log" 2>&1
grep -q '^#0  signed with algorithm 9, unknown to this xiz: not verified' "$W/hpqu.log" && pass history-unknown-algorithm || fail "history-unknown-algorithm: $(cat "$W/hpqu.log")"
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

# ---------------------------------------------------------------- writer (phase 2)
src=$W/wsrc
"$XIZ" extract -d "$src" "$F/plain.xiz" > /dev/null 2>&1
head -c 300000 "$F/dict.xiz" > "$src/tree/data/dupA"; cp -p "$src/tree/data/dupA" "$src/tree/data/dupB"
"$M" "$src" > "$W/src.manifest"
expect_code create 0 "$XIZ" create --frame-size 1 "$W/mine.xiz" "$src/tree"
expect_code create-test 0 "$XIZ" test "$W/mine.xiz"
"$XIZ" info "$W/mine.xiz" | grep -Eq 'frames +1[0-9] ' && pass create-1MiB-frames || fail create-1MiB-frames
size=$(wc -c < "$W/mine.xiz")
[ "$size" -lt 450000 ] && pass create-dedup || fail "create-dedup ($size bytes)"
rm -rf "$W/mout"; "$XIZ" extract -d "$W/mout" "$W/mine.xiz" > /dev/null 2>&1
"$M" "$W/mout" | diff - "$W/src.manifest" > /dev/null && pass create-roundtrip || fail create-roundtrip
expect_code create-exists 1 "$XIZ" create "$W/mine.xiz" "$src/tree"
XIZ_TEST_FAST_KDF=1 "$XIZ" create --password-env PW "$W/enc.xiz" "$src/tree" > /dev/null 2>&1
expect_code create-encrypted 0 "$XIZ" test --password-env PW "$W/enc.xiz"
expect_code create-encrypted-wrong 3 "$XIZ" test --password-env WRONG "$W/enc.xiz"
printf 'appended\n' > "$W/new.txt"
expect_code append 0 "$XIZ" append --password-env PW "$W/enc.xiz" --add "$W/new.txt:tree/new.txt" --delete tree/docs --mkdir tree/e2
"$XIZ" list --password-env PW "$W/enc.xiz" > "$W/l.txt"
grep -qx tree/new.txt "$W/l.txt" && grep -qx tree/e2 "$W/l.txt" && ! grep -q docs "$W/l.txt" && pass append-content || fail append-content
expect_code append-test 0 "$XIZ" test --password-env PW "$W/enc.xiz"
cp "$F/lzma2.xiz" "$W/l2.xiz"
expect_code append-lzma2 0 "$XIZ" append "$W/l2.xiz" --add "$W/new.txt:tree/new.txt"
expect_code append-lzma2-test 0 "$XIZ" test "$W/l2.xiz"
cp "$F/signed.xiz" "$W/s.xiz"
expect_code append-directory-refused 1 "$XIZ" append "$W/s.xiz" --add "$W/new.txt"
cmp -s "$W/s.xiz" "$F/signed.xiz" && pass append-refused-untouched || fail append-refused-untouched
# Interoperability with the reference implementation, when it is available.
if [ -n "${XIPPER:-}" ] && [ -x "$XIPPER" ]; then
    expect_code xipper-reads-create 0 "$XIPPER" test "$W/mine.xiz"
    expect_code xipper-reads-append 0 sh -c "printf '%s\n' \"\$PW\" | \"$XIPPER\" test --password-stdin \"$W/enc.xiz\""
    expect_code xipper-reads-lzma2-append 0 "$XIPPER" test "$W/l2.xiz"
    "$XIPPER" edit -q "$W/l2.xiz" --add "$W/new.txt:tree/again.txt" > /dev/null 2>&1
    expect_code xiz-reads-xipper-append 0 "$XIZ" test "$W/l2.xiz"
fi

# ---------------------------------------------------------------- 1.10 forensic profile (§20)
if [ -f "$F/forensic.xiz" ]; then
    expect_code forensic-verify 0 "$XIZ" forensic "$F/forensic.xiz"
    extract_cmp forensic forensic.xiz forensic.manifest
    "$XIZ" forensic "$F/forensic.xiz" | grep -q "$(cat "$F/forensic.sha256")" && pass forensic-source-sha256 || fail forensic-source-sha256
    "$XIZ" forensic "$F/forensic.xiz" | grep -q 'segments: 2 (1 of custody)' && pass forensic-custody || fail forensic-custody
    [ "$("$XIZ" history "$F/forensic.xiz" | grep -c 'signature valid, chain ok')" = 2 ] && pass forensic-signatures || fail forensic-signatures
    "$XIZ" forensic --records "$F/forensic.xiz" | grep -q '"seals":"sigillo 4471"' && pass forensic-records || fail forensic-records
    expect_code forensic-password-without-key 0 "$XIZ" forensic "$F/forensic-password.xiz"
    expect_code forensic-password 0 "$XIZ" forensic --password-env PW "$F/forensic-password.xiz"
    "$XIZ" forensic --password-env PW "$F/forensic-password.xiz" | grep -q 'images: 1 checked' && pass forensic-password-image || fail forensic-password-image
    expect_code forensic-damaged 1 "$XIZ" forensic "$F/forensic-damaged.xiz"
    expect_code forensic-logical 0 "$XIZ" forensic "$F/forensic-logical.xiz"
    "$XIZ" forensic "$F/forensic-logical.xiz" | grep -q 'files: 5 checked against the signed inventory, 0 problems' && pass forensic-inventory || fail forensic-inventory
    "$XIZ" cat "$F/forensic-logical.xiz" forensic/inventory.jsonl | grep -q '"status":"unreadable"' && pass forensic-inventory-unreadable || fail forensic-inventory-unreadable
    extract_cmp forensic-logical forensic-logical.xiz forensic-logical.manifest
    cp "$F/forensic.xiz" "$W/f.xiz"
    expect_code forensic-append-refused 1 "$XIZ" append "$W/f.xiz" --mkdir x
    cmp -s "$W/f.xiz" "$F/forensic.xiz" && pass forensic-append-untouched || fail forensic-append-untouched
fi

[ $fails = 0 ] && echo "fixtures: all passed" || echo "fixtures: $fails failed"
[ $fails = 0 ]
