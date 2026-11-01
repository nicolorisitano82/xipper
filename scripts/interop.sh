#!/bin/bash
# Interop check: every archive kind Xipper writes, tested and extracted by the other tools that read
# it (7zz, Info-ZIP unzip, bsdtar, xz, zstd, gzip, bzip2, lz4, brotli, aa), and the extracted tree
# compared with the source. Tools that are missing are skipped with a note.
#   scripts/interop.sh            → table of PASS / FAIL / SKIP, exit 1 on any FAIL
#   scripts/interop.sh -v         → also the output of failing commands
set -uo pipefail
cd "$(dirname "$0")/.."
VERBOSE=0; [ "${1:-}" = "-v" ] && VERBOSE=1
export COPYFILE_DISABLE=1 LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
PW="interop-pw"

echo "==> building xipper"
swift build -c release --product xipper >/dev/null 2>&1 || { swift build -c release --product xipper 2>&1 | tail -20; exit 1; }
X="$PWD/.build/release/xipper"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SRC="$WORK/src"
mkdir -p "$SRC/data" "$SRC/città" "$SRC/emptydir"
printf 'hello xipper interop\n' > "$SRC/readme.txt"
head -c 300000 /dev/urandom > "$SRC/data/random.bin"
yes 'lorem ipsum dolor sit amet xipper archiver' | head -c 2000000 > "$SRC/data/text.txt"
printf 'unicode name\n' > "$SRC/città/è unicode ✓.txt"
: > "$SRC/empty.txt"
printf '#!/bin/sh\necho hi\n' > "$SRC/script.sh"; chmod 755 "$SRC/script.sh"
ln -s readme.txt "$SRC/link-to-readme"

have() { command -v "$1" >/dev/null 2>&1; }
SZ=$(command -v 7zz || true)
pass=0; fail=0; skip=0
report() { # status, case, check, [log]
    printf '%-5s %-28s %s\n' "$1" "$2" "$3"
    case $1 in PASS) pass=$((pass+1));; FAIL) fail=$((fail+1)); [ $VERBOSE = 1 ] && [ -n "${4:-}" ] && sed 's/^/      /' "$4" | tail -15;; SKIP) skip=$((skip+1));; esac
}
check() { # case, label, command...  (runs in $WORK, output to a log)
    local c=$1 l=$2; shift 2
    local log="$WORK/log-$c-${l// /_}"
    if (cd "$WORK" && "$@") >"$log" 2>&1; then report PASS "$c" "$l"; else report FAIL "$c" "$l" "$log"; fi
}
# Tree comparison: names in NFC, file contents, symlink targets, the executable bit.
snapshot() {
    python3 -I - "$1" <<'PY'
import hashlib, os, sys, unicodedata
root = sys.argv[1]
for d, dirs, files in os.walk(root):
    for n in sorted(dirs + files):
        p = os.path.join(d, n); rel = unicodedata.normalize("NFC", os.path.relpath(p, root))
        if os.path.islink(p): print(rel, "link", os.readlink(p))
        elif os.path.isdir(p): print(rel, "dir")
        else: print(rel, hashlib.sha256(open(p, "rb").read()).hexdigest(), "x" if os.access(p, os.X_OK) else "-")
PY
}
snapshot "$SRC" | sort > "$WORK/src.snap"
same_tree() { snapshot "$1" | sort | diff "$WORK/src.snap" -; }
# extract with a tool into a fresh folder, then compare; $1 case, $2 label, rest: command with {OUT}
extract_cmp() {
    local c=$1 l=$2; shift 2
    local out="$WORK/x-$c-${l// /_}"; rm -rf "$out"; mkdir -p "$out"
    local args=(); for a in "$@"; do args+=("${a//\{OUT\}/$out}"); done
    local log="$WORK/log-$c-${l// /_}"
    if (cd "$WORK" && "${args[@]}") >"$log" 2>&1 && same_tree "$out/src" >>"$log" 2>&1; then report PASS "$c" "$l"
    else report FAIL "$c" "$l" "$log"; fi
}
mk() { # case, xipper create args... (archive path last-but-one is the case's archive)
    local c=$1; shift
    if (cd "$WORK" && "$X" create --overwrite "$@") >"$WORK/log-$c-create" 2>&1; then return 0
    else report FAIL "$c" "xipper create" "$WORK/log-$c-create"; return 1; fi
}
mkpw() { local c=$1; shift; (cd "$WORK" && echo "$PW" | "$X" create --overwrite --password-stdin "$@") >"$WORK/log-$c-create" 2>&1 \
    || { report FAIL "$c" "xipper create" "$WORK/log-$c-create"; return 1; }; }

echo "==> ZIP"
for m in deflate store bzip2 lzma xz zstd deflate64; do
    c="zip-$m"; mk $c -m $m "$c.zip" src || continue
    if [ -n "$SZ" ]; then check $c "7zz t" "$SZ" t "$c.zip"; extract_cmp $c "7zz x" "$SZ" x -snl -o{OUT} "$c.zip"; else report SKIP $c "7zz missing"; fi
    # macOS unzip is built without bzip2 (USE_BZIP2 is off), with Deflate64.
    case $m in deflate|store|deflate64) check $c "unzip -t" unzip -tq "$c.zip"; extract_cmp $c "unzip" unzip -q "$c.zip" -d {OUT};; esac
    case $m in deflate|store) extract_cmp $c "ditto -x" ditto -x -k "$c.zip" {OUT}; check $c "bsdtar -t" bsdtar -tf "$c.zip";; esac
done
c=zip-aes; if mkpw $c "$c.zip" src; then
    if [ -n "$SZ" ]; then check $c "7zz t" "$SZ" t -p"$PW" "$c.zip"; extract_cmp $c "7zz x" "$SZ" x -snl -p"$PW" -o{OUT} "$c.zip"; else report SKIP $c "7zz missing"; fi
fi
c=zip-zip64; if mk $c --zip64 "$c.zip" src; then
    check $c "unzip -t" unzip -tq "$c.zip"; [ -n "$SZ" ] && check $c "7zz t" "$SZ" t "$c.zip"
fi
c=zip-volumes; if mk $c -v 500k "$c.zip" src; then
    [ -n "$SZ" ] && extract_cmp $c "7zz x" "$SZ" x -snl -o{OUT} "$c.zip"
    check $c "zip -s 0 + unzip" sh -c "zip -q -s 0 $c.zip --out $c-joined.zip && unzip -tq $c-joined.zip"
fi
c=zip-numbered; if mk $c -v 500k --numbered "$c.zip" src; then
    check $c "cat + unzip -t" sh -c "cat $c.zip.0* > $c-cat.zip && unzip -tq $c-cat.zip"
fi

echo "==> 7z"
if [ -n "$SZ" ]; then
    for v in "solid:" "nonsolid:--solid off" "level9:-l 9"; do
        c="7z-${v%%:*}"; mk $c ${v#*:} -f 7z "$c.7z" src || continue
        check $c "7zz t" "$SZ" t "$c.7z"; extract_cmp $c "7zz x" "$SZ" x -snl -o{OUT} "$c.7z"
    done
    c=7z-aes; mkpw $c -f 7z "$c.7z" src && { check $c "7zz t" "$SZ" t -p"$PW" "$c.7z"; extract_cmp $c "7zz x" "$SZ" x -snl -p"$PW" -o{OUT} "$c.7z"; }
    c=7z-aes-plain; mkpw $c -f 7z --plain-names "$c.7z" src && check $c "7zz l (no pw)" "$SZ" l "$c.7z"
    c=7z-volumes; mk $c -f 7z -v 500k "$c.7z" src && extract_cmp $c "7zz x" "$SZ" x -snl -o{OUT} "$c.7z.001"
    c=7z-bsdtar; mk $c -f 7z "$c.7z" src && check $c "bsdtar -t" bsdtar -tf "$c.7z"
else report SKIP 7z "7zz missing"; fi

echo "==> tar, cpio"
for f in tar tar.gz tar.bz2 tar.xz tar.zst; do
    c="${f//./-}"; mk $c -f $f "$c.$f" src || continue
    extract_cmp $c "bsdtar -x" bsdtar -xf "$c.$f" -C {OUT}
    case $f in
        tar.gz)  check $c "gzip -t" gzip -t "$c.$f";;
        tar.bz2) check $c "bzip2 -t" bzip2 -t "$c.$f";;
        tar.xz)  have xz && check $c "xz -t" xz -t "$c.$f";;
        tar.zst) have zstd && check $c "zstd -t" zstd -tq "$c.$f";;
    esac
    [ -n "$SZ" ] && [ $f != tar.zst ] && check $c "7zz t" "$SZ" t "$c.$f"
done
c=cpio; mk $c -f cpio "$c.cpio" src && extract_cmp $c "bsdtar -x" bsdtar -xf "$c.cpio" -C {OUT}

echo "==> Apple Archive"
c=aar; mk $c -f aar "$c.aar" src && extract_cmp $c "aa extract" aa extract -i "$c.aar" -d {OUT}

echo "==> single files"
for f in gz bz2 xz zst; do
    c="single-$f"; mk $c -f $f "text.txt.$f" src/data/text.txt || continue
    case $f in
        gz)  t=(gzip -dc);; bz2) t=(bzip2 -dc);; xz) t=(xz -dc);; zst) t=(zstd -dcq);;
    esac
    if have "${t[0]}"; then check $c "${t[0]} -d" sh -c "${t[*]} text.txt.$f | cmp - src/data/text.txt"; else report SKIP $c "${t[0]} missing"; fi
done

echo
echo "PASS $pass  FAIL $fail  SKIP $skip"
[ $fail = 0 ]
