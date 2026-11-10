#!/bin/sh
# Regenerates tests/fixtures with the reference writer (Xipper's Swift CLI, macOS only).
# Content is synthetic. Usage: tests/make_fixtures.sh [path/to/xipper] [path/to/xiz_manifest]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
X=${1:-$root/.build/release/xipper}
M=${2:-$here/../build/xiz_manifest}
out=$here/fixtures
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
[ -x "$X" ] || { echo "build xipper first: swift build -c release --product xipper" >&2; exit 2; }
[ -x "$M" ] || { echo "build xiz_manifest first (cmake)" >&2; exit 2; }
mkdir -p "$out"
rm -f "$out"/*.xiz "$out"/*.manifest "$out"/*.json "$out"/*.key "$out"/*.txt

# ---------------------------------------------------------------- the synthetic tree
t=$work/in/tree
mkdir -p "$t/docs" "$t/data" "$t/emptydir" "$t/referti/2026" "$t/città" "$t/bin"
printf 'XIZ test tree. Synthetic content only.\n' > "$t/readme.txt"
i=0
while [ $i -lt 200 ]; do printf 'Line %d of a document about nothing in particular.\n' $i; i=$((i+1)); done > "$t/docs/a.md"
sed 's/nothing/everything/' "$t/docs/a.md" > "$t/docs/b.md"
head -c 8192 /dev/urandom > "$t/data/random.bin"
head -c 4096 /dev/urandom > "$t/data/dup1.bin"
cp "$t/data/dup1.bin" "$t/data/dup2.bin"
: > "$t/empty.txt"
printf '#!/bin/sh\necho hello\n' > "$t/run.sh"; chmod 755 "$t/run.sh"
printf 'read only\n' > "$t/ro.txt"; chmod 444 "$t/ro.txt"
printf 'unicode name\n' > "$t/città/è.txt"
printf 'referto 1\n' > "$t/referti/2026/r1.txt"
printf 'referto 2\n' > "$t/referti/r2.txt"
ln -s docs/a.md "$t/link-to-a"
ln -s ../readme.txt "$t/docs/up-link"
# 9 MiB of low-entropy data: several 4 MiB frames, a few KB compressed.
awk 'BEGIN { for (i = 0; i < 9 * 1024; i++) { s = sprintf("block %08d ", i); while (length(s) < 1024) s = s "abcdefghijklmnop"; print substr(s, 1, 1023) } }' > "$t/data/big.txt"
cat > "$work/hello.c" <<'EOF'
#include <stdio.h>
int main(void) { puts("hello from an arm64 binary"); return 0; }
EOF
clang -O2 -arch arm64 -o "$t/bin/hello" "$work/hello.c"
find "$t" -exec touch -h -t 202601020304.05 {} +
"$M" "$work/in" > "$out/tree.manifest"

pw='correct horse battery staple'
export XIZ_PW_A='alpha secret' XIZ_PW_B='beta secret' XIZ_PW_C1='custodian one' XIZ_PW_C2='custodian two' XIZ_PW_C3='custodian three'

# ---------------------------------------------------------------- 1.0 / 1.2 / 1.4
"$X" create -q -f xiz "$out/plain.xiz" "$t"
"$X" create -q -f xiz -l 19 --no-dictionary "$out/level19.xiz" "$t"
"$X" create -q -f xiz --lzma2 "$out/lzma2.xiz" "$t"
mkdir -p "$work/arm/exe"; cp "$t/bin/hello" "$work/arm/exe/hello"
cp "$t/bin/hello" "$work/arm/exe/hello2"; printf '\001' >> "$work/arm/exe/hello2"
"$X" create -q -f xiz --lzma2 "$out/lzma2-arm64.xiz" "$work/arm/exe"
"$M" "$work/arm" > "$out/arm64.manifest"
printf '%s\n' "$pw" | "$X" create -q -f xiz --password-stdin "$out/password.xiz" "$t"
printf '%s\n' "$pw" | "$X" create -q -f xiz --lzma2 --password-stdin "$out/password-lzma2.xiz" "$t"

# Dictionaries (§12): level ≥ 9 and ≥ 32 MiB of files under 128 KiB.
d=$work/dict/small
mkdir -p "$d"
awk -v dir="$d" 'BEGIN { for (f = 0; f < 560; f++) { file = sprintf("%s/f%04d.json", dir, f);
  printf("{\"file\": %d}\n", f) > file;
  for (l = 0; l < 1100; l++) printf("{\"id\": %d, \"name\": \"item-%d\", \"tag\": \"t%d\", \"v\": %d}\n", l, l, l % 17, (l * 7919 + f % 3) % 1000) > file; close(file) } }'
"$X" create -q -f xiz -l 12 "$out/dict.xiz" "$d"
(cd "$work/dict" && "$M" "$work/dict") > "$out/dict.manifest"

# ---------------------------------------------------------------- 1.1 appended segments
cp "$out/plain.xiz" "$out/appended.xiz"
printf 'added later\n' > "$work/added.txt"
"$X" edit -q "$out/appended.xiz" --add "$work/added.txt:tree/added.txt" --delete tree/docs/b.md --rename tree/readme.txt:tree/README.txt
"$X" edit -q "$out/appended.xiz" --mkdir tree/newdir
cp -Rp "$work/in" "$work/app"
cp -p "$work/added.txt" "$work/app/tree/added.txt"; rm "$work/app/tree/docs/b.md"
mv "$work/app/tree/readme.txt" "$work/app/tree/README.txt"; mkdir "$work/app/tree/newdir"
"$M" --no-mtime "$work/app" > "$out/appended.manifest"
cp "$out/password.xiz" "$out/password-appended.xiz"
printf '%s\n' "$pw" | "$X" edit -q --password-stdin "$out/password-appended.xiz" --add "$work/added.txt:tree/added.txt"
cp -Rp "$work/in" "$work/app2"; cp -p "$work/added.txt" "$work/app2/tree/added.txt"
"$M" --no-mtime "$work/app2" > "$out/password-appended.manifest"
# Group 0 only (recipient "Ricerca"): everything but tree/referti; group 1 only: tree/referti.
cp -Rp "$work/in" "$work/g0"; rm -rf "$work/g0/tree/referti"; touch -h -t 202601020304.05 "$work/g0/tree"
"$M" "$work/g0" > "$out/group0.manifest"
mkdir -p "$work/g1/tree"; cp -Rp "$t/referti" "$work/g1/tree/"
"$M" "$work/g1" | grep -v '^tree	' > "$out/group1.manifest"

# ---------------------------------------------------------------- 1.3
"$X" keygen -o "$out/identity.key" > /dev/null
"$X" keygen --signing -o "$out/signing.key" > /dev/null
pub=$(grep -o 'xizpk1[A-Za-z0-9_-]*' "$out/identity.key" | head -1)
cat > "$work/access.json" <<EOF
{ "groups": [ { "name": "referti", "folders": ["tree/referti"] } ],
  "recipients": [ { "label": "Laboratorio", "password_env": "XIZ_PW_A" },
                  { "label": "Ricerca", "password_env": "XIZ_PW_B", "groups": [""] },
                  { "label": "Chiave", "public_key": "$pub", "groups": ["referti"] } ],
  "thresholds": [ { "label": "Comitato", "k": 2, "groups": ["referti"],
                    "custodians": [ { "label": "C1", "password_env": "XIZ_PW_C1" },
                                    { "label": "C2", "password_env": "XIZ_PW_C2" },
                                    { "label": "C3", "password_env": "XIZ_PW_C3" } ] } ] }
EOF
"$X" create -q -f xiz --access "$work/access.json" "$out/access.xiz" "$t"
"$X" create -q -f xiz --sign "$out/signing.key" --signer "Test Signer" "$out/signed.xiz" "$t"
"$X" edit -q --sign "$out/signing.key" --signer "Second" "$out/signed.xiz" --add "$work/added.txt:tree/added.txt"
"$X" prove "$out/signed.xiz" tree/docs/a.md -o "$out/proof-a.json" > /dev/null
cat > "$work/erasable.json" <<EOF
{ "erasable": true, "recipients": [ { "label": "Owner", "password_env": "XIZ_PW_A" } ] }
EOF
"$X" create -q -f xiz --access "$work/erasable.json" --sign "$out/signing.key" --signer "Eraser" "$out/erasable.xiz" "$t"
cp "$out/erasable.xiz" "$out/erased.xiz"
printf '%s\n' "$XIZ_PW_A" | "$X" erase -q --password-stdin "$out/erased.xiz" tree/docs/b.md > /dev/null

# ---------------------------------------------------------------- 1.6 JPEG (brunsli, §16)
# Synthetic photos: a gradient with noise as BMP, made JPEG by sips (baseline and a second seed).
mkdir -p "$work/jpeg/photos"
for seed in 1 2; do
  python3 -I - "$work/jpeg/p$seed.bmp" "$seed" <<'PY'
import struct, sys, random
w, h = 320, 240
random.seed(int(sys.argv[2]))
row = (w * 3 + 3) & ~3
px = bytearray()
for y in range(h):
    r = bytearray()
    for x in range(w):
        n = random.randrange(16)
        r += bytes(((x * 255 // w + n) & 255, (y * 255 // h + n) & 255, ((x + y) * 128 // (w + h) + 40 * int(sys.argv[2])) & 255))
    px += r + bytes(row - len(r))
hdr = struct.pack('<2sIHHI', b'BM', 54 + len(px), 0, 0, 54) + struct.pack('<IiiHHIIiiII', 40, w, h, 1, 24, 0, len(px), 2835, 2835, 0, 0)
open(sys.argv[1], 'wb').write(hdr + px)
PY
  sips -s format jpeg -s formatOptions 85 "$work/jpeg/p$seed.bmp" --out "$work/jpeg/photos/photo$seed.jpg" > /dev/null
done
cp "$work/jpeg/photos/photo1.jpg" "$work/jpeg/photos/copy.jpg"
printf 'not a jpeg\n' > "$work/jpeg/photos/fake.jpg"
printf 'notes\n' > "$work/jpeg/photos/notes.txt"
find "$work/jpeg/photos" -exec touch -h -t 202601020304.05 {} +
(cd "$work/jpeg" && "$M" "$work/jpeg" | grep -v '\.bmp	') > "$out/jpeg.manifest"
"$X" create -q -f xiz --jpeg "$out/jpeg.xiz" "$work/jpeg/photos"
printf '%s\n' "$pw" | "$X" create -q -f xiz --jpeg --password-stdin "$out/password-jpeg.xiz" "$work/jpeg/photos"

# ---------------------------------------------------------------- 1.9 documents (preflate, §19)
# A PNG made by sips (zlib), a PDF with zlib content streams (python's zlib), a DOCX-like ZIP by zip.
mkdir -p "$work/docs/docs/word"
sips -s format png "$work/jpeg/p1.bmp" --out "$work/docs/docs/image.png" > /dev/null
python3 -I - "$work/docs/docs/report.pdf" <<'PY'
import sys, zlib, random
random.seed(7)
words = "archivio flusso Xipper documento pagina immagine dati ricostruzione byte identico compressione".split()
out = b"%PDF-1.4\n"
for p in range(6):
    text = "\n".join("BT /F1 10 Tf 40 %d Td (%s) Tj ET" % (800 - l * 11, " ".join(random.choice(words) for _ in range(12))) for l in range(70))
    s = zlib.compress(text.encode(), 6)
    out += b"%d 0 obj\n<< /Length %d /Filter /FlateDecode >>\nstream\n" % (p + 1, len(s)) + s + b"\nendstream\nendobj\n"
open(sys.argv[1], "wb").write(out + b"trailer\n<< >>\n%%EOF\n")
PY
python3 -I - "$work/docs/docs/word" <<'PY'
import sys, random
random.seed(8)
words = "paragrafo testo tabella cartella file versione riga numero valore colonna rapporto misura".split()
for i in range(4):
    body = "".join("<w:p><w:r><w:t>%s</w:t></w:r></w:p>" % " ".join(random.choice(words) for _ in range(15)) for _ in range(400))
    open("%s/part%d.xml" % (sys.argv[1], i), "w").write('<?xml version="1.0"?><w:document>' + body + "</w:document>")
PY
(cd "$work/docs/docs" && zip -q -r -X letter.docx word && rm -r word)
find "$work/docs/docs" -exec touch -h -t 202601020304.05 {} +
"$M" "$work/docs" > "$out/docs.manifest"
"$X" create -q -f xiz -l 12 --documents "$out/docs.xiz" "$work/docs/docs"

ls -l "$out"
