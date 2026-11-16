#!/bin/bash
# The Windows xiz (x86_64, cross-built with zig) run under Wine in a throwaway Debian container:
# the whole libxiz fixture suite (libxiz/tests/run_fixtures.sh with XIZ_WINDOWS=1) plus the
# Windows-only cases (non-ASCII arguments, UTF-8 passwords from the environment, drive-letter
# paths, CRLF key files), and the archives xiz.exe writes read back by the Linux xiz.
# No Windows VM: Wine comes from the Debian repositories (image xipper-wine:trixie, built once from
# debian:trixie); amd64 is emulated on Apple Silicon. Wine is not Windows (see the end of this file).
#   scripts/windows-wine.sh [--build]     --build: rebuild the portable xiz even when up to date
# Exit 0 = "windows ok: …", 77 = skipped (no Docker), anything else = failure.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
P="$ROOT/.build/xiz-portable"
IMAGE=xipper-wine:trixie

command -v docker > /dev/null || { echo "SKIP: docker not installed"; exit 77; }
docker info > /dev/null 2>&1 || { echo "SKIP: Docker daemon not running"; exit 77; }

# The portable builds (scripts/build-xiz-portable.sh): rebuilt when missing or older than libxiz.
exe="$P/windows-x86_64/xiz.exe"
if [ "${1:-}" = --build ] || [ ! -f "$exe" ] || [ ! -f "$P/linux-x86_64/libxiz.a" ] ||
   [ -n "$(find libxiz/src libxiz/tools libxiz/include libxiz/CMakeLists.txt -newer "$exe" -print -quit)" ]; then
    command -v zig > /dev/null || { echo "SKIP: zig not installed (brew install zig)"; exit 77; }
    bash scripts/build-xiz-portable.sh campaign > /dev/null || { echo "portable build failed"; exit 1; }
fi

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
cp "$exe" "$W/bin/xiz.exe"
cp "$P/linux-x86_64/xiz" "$W/bin/xiz-linux"
# The tree describer of the fixture suite, as a Linux binary for the container.
zig cc -target x86_64-linux-musl -O2 -Ilibxiz/src -Ilibxiz/include -Ilibxiz/third_party/bearssl/inc libxiz/tests/manifest.c \
    "$P/linux-x86_64/libxiz.a" -o "$W/bin/xiz_manifest" 2> "$W/manifest.log" || { cat "$W/manifest.log"; exit 1; }

if ! docker image inspect "$IMAGE" > /dev/null 2>&1; then
    printf 'FROM debian:trixie\nRUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends wine wine64 && rm -rf /var/lib/apt/lists/*\n' |
        docker build --platform linux/amd64 -t "$IMAGE" - > "$W/image.log" 2>&1 || { tail -20 "$W/image.log"; echo "cannot build $IMAGE"; exit 1; }
fi

# xiz under Wine for run_fixtures.sh: Windows text-mode stdout ends lines with CRLF, stripped here
# (not for `cat`, whose stdout is binary) so the POSIX checks compare lines.
cat > "$W/bin/xiz" <<'EOF'
#!/bin/sh
[ "${1:-}" = cat ] && exec wine /w/bin/xiz.exe "$@"
o=$(mktemp)
wine /w/bin/xiz.exe "$@" > "$o"
rc=$?
tr -d '\r' < "$o"
rm -f "$o"
exit $rc
EOF

chmod +x "$W/bin/xiz"

cat > "$W/inner.sh" <<'EOF'
set -u
X=/w/bin/xiz L=/w/bin/xiz-linux F=/t/fixtures
wine --version
wineboot -i > /dev/null 2>&1; wineserver -w
XIZ_WINDOWS=1 sh /t/run_fixtures.sh $X $F > /w/fixtures.log 2>&1
fx=$?
cat /w/fixtures.log
extra=0 bad=0
ok() { echo "ok   $1"; extra=$((extra + 1)); }
no() { echo "FAIL $1"; bad=$((bad + 1)); }
cd /tmp
mkdir -p 'dé/sub' e
printf 'ciao\n' > 'dé/ü.txt'; printf 'x\n' > 'dé/sub/ro.txt'; chmod 444 'dé/sub/ro.txt'
printf 'new\n' > e/n.txt
cp $F/plain.xiz città.xiz
$X info città.xiz | grep -q '^archive id' && ok non-ascii-archive-name || no non-ascii-archive-name
$X create c.xiz dé > /dev/null && [ "$($X list c.xiz | tr '\n' ' ')" = "dé dé/sub dé/sub/ro.txt dé/ü.txt " ] && ok non-ascii-create || no non-ascii-create
$L test c.xiz > /dev/null && $L extract -d lc c.xiz > /dev/null && [ "$(cat lc/dé/ü.txt)" = ciao ] && ok linux-reads-windows-create || no linux-reads-windows-create
$L list -l c.xiz | grep -q '^-0444 .*dé/sub/ro.txt' && ok read-only-recorded || no read-only-recorded
$L list -l c.xiz > cl.txt && [ -s cl.txt ] && ! grep -q ' 1970-' cl.txt && ok mtime-recorded || no mtime-recorded
export PWU='pässwörd'
XIZ_TEST_FAST_KDF=1 $X create --password-env PWU p.xiz dé > /dev/null && $L test --password-env PWU p.xiz > /dev/null && ok utf8-password-env || no utf8-password-env
cp $F/lzma2.xiz l.xiz
$X append l.xiz --add 'Z:\tmp\e\n.txt' > /dev/null && $L list l.xiz | grep -qx n.txt && ok drive-letter-add || no drive-letter-add
$X append l.xiz --add 'Z:\tmp\e\n.txt:tree/again.txt' > /dev/null && $L test l.xiz > /dev/null && $L list l.xiz | grep -qx tree/again.txt && ok drive-letter-add-path || no drive-letter-add-path
sed 's/$/\r/' $F/identity-pq.key > 'clé.key'
$X extract -d pq --identity 'clé.key' $F/access-pq.xiz > /dev/null && [ -f pq/tree/referti/r2.txt ] && ok crlf-non-ascii-key-file || no crlf-non-ascii-key-file
$X list $F/plain.xiz > raw.txt; wine /w/bin/xiz.exe list $F/plain.xiz > crlf.txt 2> /dev/null
[ "$(grep -c "$(printf '\r')\$" crlf.txt)" = "$(wc -l < crlf.txt)" ] && ok text-stdout-crlf || no text-stdout-crlf
wine /w/bin/xiz.exe cat $F/plain.xiz tree/data/random.bin 2> /dev/null > r.bin; $L cat $F/plain.xiz tree/data/random.bin > r2.bin
cmp -s r.bin r2.bin && ok cat-binary-stdout || no cat-binary-stdout
echo "windows extras: $extra passed, $bad failed"
[ $fx = 0 ] && [ $bad = 0 ]
EOF

docker run --rm --platform linux/amd64 -e LANG=C.UTF-8 -e WINEDEBUG=-all \
    -v "$ROOT/libxiz/tests:/t:ro" -v "$W:/w" "$IMAGE" sh /w/inner.sh > "$W/run.log" 2>&1
rc=$?
grep -v 'rosetta error\|XDG_RUNTIME_DIR\|rundll32\|configuration directory' "$W/run.log"
if [ $rc -ne 0 ]; then echo "windows FAILED (exit $rc)"; exit 1; fi
n=$(grep -c '^ok' "$W/run.log")
echo "windows ok: xiz.exe (x86_64) under $(head -1 "$W/run.log"), $n checks: fixtures (extract and trees, passwords," \
     "X25519 and X-Wing identities, age, signatures, OpenZL tables, documents, tampering, writer, forensic)," \
     "non-ASCII names and passwords, drive-letter paths, CRLF key files, read back by the Linux xiz"

# Wine is not Windows: no NTFS ACLs or alternate streams, file names live on the container's ext4/
# overlay (case-sensitive), CreateSymbolicLinkW does nothing (links are skipped by the comparison),
# no console (output is a pipe), and the code page follows LANG (C.UTF-8 here; with LANG=C Wine
# cannot store non-ASCII names at all).
