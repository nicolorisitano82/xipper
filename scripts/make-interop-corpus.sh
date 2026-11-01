#!/bin/bash
# Builds the interop corpus: small archives written by other tools from one synthetic tree, read
# back by InteropCorpusTests. Run it again only to add cases; the output is committed so the tests
# do not need the tools. Synthetic content only, never real data.
#   scripts/make-interop-corpus.sh   → Tests/XipperKitTests/Fixtures/interop/
# Tools: 7zz (Homebrew), xz, zstd, lz4, brotli (Homebrew); zip, ditto, bsdtar, gzip, bzip2, aa (macOS).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="Tests/XipperKitTests/Fixtures/interop"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export COPYFILE_DISABLE=1 LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
PW="interop-pw"

need() { command -v "$1" >/dev/null || { echo "missing tool: $1" >&2; exit 1; }; }
for t in 7zz zip ditto bsdtar gzip bzip2 xz zstd lz4 brotli aa python3; do need "$t"; done

# The tree: text, a mixed 48 KB binary, a Unicode name, an empty file, an empty folder, an
# executable script and a relative symlink.
SRC="$WORK/src"
python3 -I - "$SRC" <<'PY'
import os, sys
root = sys.argv[1]
def w(rel, data, mode=0o644):
    p = os.path.join(root, rel); os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "wb").write(data); os.chmod(p, mode)
x = 0x9E3779B97F4A7C15
words = b"lorem ipsum dolor sit amet xipper archiver apple silicon "
out = bytearray()
while len(out) < 48 * 1024:
    x ^= (x << 13) & 0xFFFFFFFFFFFFFFFF; x ^= x >> 7; x ^= (x << 17) & 0xFFFFFFFFFFFFFFFF
    if x % 4 == 0: out += x.to_bytes(8, "little") * 4
    else: s = x % len(words); out += (words[s:] + words[:s])[:48]
w("readme.txt", b"hello xipper interop\n")
w("data/sample.bin", bytes(out[:48 * 1024]))
w("città/è unicode ✓.txt", "unicode name\n".encode())
w("empty.txt", b"")
w("script.sh", b"#!/bin/sh\necho hi\n", 0o755)
os.makedirs(os.path.join(root, "emptydir"))
os.symlink("readme.txt", os.path.join(root, "link-to-readme"))
PY

rm -rf "$OUT" && mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
cd "$SRC"
ALL=(readme.txt data "città" empty.txt script.sh emptydir link-to-readme)

# Info-ZIP 3.0 (macOS)
zip -q -r -y -X "$OUT/infozip-deflate.zip" "${ALL[@]}"
zip -q -r -y -X -0 "$OUT/infozip-store.zip" "${ALL[@]}"
zip -q -r -y -X -P "$PW" "$OUT/infozip-zipcrypto.zip" "${ALL[@]}"
zip -q -r -y -X -fz "$OUT/infozip-zip64.zip" "${ALL[@]}"
zip -q -r -y -X - "${ALL[@]}" > "$OUT/infozip-stream.zip"   # to a pipe: data descriptors
# Archive Utility / Finder "Compress": ditto with AppleDouble in __MACOSX
ditto -c -k --sequesterRsrc --keepParent "$SRC" "$OUT/ditto-finder.zip"

# 7-Zip: ZIP methods
for m in Deflate Deflate64 BZip2 LZMA PPMd; do
    7zz a -bso0 -bsp0 -tzip -mm=$m "$OUT/7zz-zip-$(echo $m | tr A-Z a-z).zip" "${ALL[@]}" -snl
done
7zz a -bso0 -bsp0 -tzip -mem=AES256 -p"$PW" "$OUT/7zz-zip-aes256.zip" "${ALL[@]}" -snl
# 7-Zip: 7z
7zz a -bso0 -bsp0 -t7z -m0=LZMA2 -ms=on "$OUT/7zz-lzma2-solid.7z" "${ALL[@]}" -snl
7zz a -bso0 -bsp0 -t7z -m0=LZMA2 -ms=off "$OUT/7zz-lzma2-nonsolid.7z" "${ALL[@]}" -snl
7zz a -bso0 -bsp0 -t7z -m0=LZMA "$OUT/7zz-lzma.7z" "${ALL[@]}" -snl
7zz a -bso0 -bsp0 -t7z -m0=PPMd "$OUT/7zz-ppmd.7z" "${ALL[@]}" -snl
7zz a -bso0 -bsp0 -t7z -m0=BZip2 "$OUT/7zz-bzip2.7z" "${ALL[@]}" -snl
7zz a -bso0 -bsp0 -t7z -m0=Deflate "$OUT/7zz-deflate.7z" "${ALL[@]}" -snl
7zz a -bso0 -bsp0 -t7z -m0=Copy "$OUT/7zz-copy.7z" "${ALL[@]}" -snl
7zz a -bso0 -bsp0 -t7z -mf=ARM64 "$OUT/7zz-arm64filter.7z" "${ALL[@]}" -snl
7zz a -bso0 -bsp0 -t7z -mhe=on -p"$PW" "$OUT/7zz-aes-encnames.7z" "${ALL[@]}" -snl
7zz a -bso0 -bsp0 -t7z -mhe=off -p"$PW" "$OUT/7zz-aes-plainnames.7z" "${ALL[@]}" -snl
7zz a -bso0 -bsp0 -t7z -m0=Copy -v16k "$OUT/7zz-volumes.7z" "${ALL[@]}" -snl
# libarchive (bsdtar 3.x on macOS)
bsdtar -cf "$OUT/bsdtar-pax.tar" --format pax "${ALL[@]}"
bsdtar -cf "$OUT/bsdtar-ustar.tar" --format ustar "${ALL[@]}"
bsdtar -cf "$OUT/bsdtar-gnutar.tar" --format gnutar "${ALL[@]}"
bsdtar -czf "$OUT/bsdtar.tar.gz" "${ALL[@]}"
bsdtar -cjf "$OUT/bsdtar.tar.bz2" "${ALL[@]}"
bsdtar -cJf "$OUT/bsdtar.tar.xz" "${ALL[@]}"
bsdtar -cf "$OUT/bsdtar-newc.cpio" --format newc "${ALL[@]}"
bsdtar -cf "$OUT/bsdtar-odc.cpio" --format odc "${ALL[@]}"
bsdtar -cf "$OUT/bsdtar-zip.zip" --format zip "${ALL[@]}"
bsdtar -cf "$OUT/bsdtar-7zip.7z" --format 7zip "${ALL[@]}"
# Command-line compressors on a tar: zstd with several frames and a long window, xz with blocks
bsdtar -cf "$WORK/plain.tar" "${ALL[@]}"
zstd -q -19 --long=27 "$WORK/plain.tar" -o "$OUT/zstd-long.tar.zst"
lz4 -q -9 "$WORK/plain.tar" "$OUT/lz4.tar.lz4"
brotli -q 9 "$WORK/plain.tar" -o "$OUT/brotli.tar.br"
# Single files, the edge cases of each stream format
S=data/sample.bin
head -c 20000 "$S" | gzip -9n > "$OUT/gzip-multimember.bin.gz"; tail -c +20001 "$S" | gzip -1n >> "$OUT/gzip-multimember.bin.gz"
head -c 20000 "$S" | bzip2 -9 > "$OUT/bzip2-multistream.bin.bz2"; tail -c +20001 "$S" | bzip2 -1 >> "$OUT/bzip2-multistream.bin.bz2"
xz -q -T2 --block-size=8KiB -c "$S" > "$OUT/xz-multiblock.bin.xz"
head -c 20000 "$S" | xz -q -c > "$OUT/xz-multistream.bin.xz"; tail -c +20001 "$S" | xz -q -c >> "$OUT/xz-multistream.bin.xz"
head -c 20000 "$S" | zstd -q -c > "$OUT/zstd-multiframe.bin.zst"; tail -c +20001 "$S" | zstd -q -3 -c >> "$OUT/zstd-multiframe.bin.zst"
# Apple Archive (aa)
for a in lzfse lzma zlib raw; do aa archive -d . -o "$OUT/aa-$a.aar" -a $a; done
# Names in a legacy code page without the UTF-8 flag, made on MS-DOS (what Windows tools write):
# zipfile would store them as UTF-8 with the flag, so its name encoder is replaced.
python3 -I - "$OUT" <<'PY'
import sys, zipfile
class Legacy(zipfile.ZipInfo):
    __slots__ = ("page",)
    def _encodeFilenameFlags(self): return self.filename.encode(self.page), self.flag_bits & ~0x800
for name, page, names in [("py-cp437-name.zip", "cp437", ["Café ñ.txt"]),
                          ("py-cp866-names.zip", "cp866", ["Документы/отчёт.txt", "Фото/отпуск.txt"])]:
    with zipfile.ZipFile(sys.argv[1] + "/" + name, "w", zipfile.ZIP_DEFLATED) as z:
        for n in names:
            zi = Legacy(n, (2024, 1, 2, 3, 4, 6))
            zi.page = page
            zi.create_system = 0
            z.writestr(zi, b"legacy name\n")
PY

# Expected content: SHA-256 of every file, folder and link target of the tree.
python3 -I - "$SRC" "$OUT/expected.json" <<'PY'
import hashlib, json, os, sys, unicodedata
root, out = sys.argv[1], sys.argv[2]
entries = {}
for d, dirs, files in os.walk(root):
    for n in dirs + files:
        p = os.path.join(d, n); rel = unicodedata.normalize("NFC", os.path.relpath(p, root))
        if os.path.islink(p): entries[rel] = "link:" + os.readlink(p)
        elif os.path.isdir(p): entries[rel] = "dir"
        else: entries[rel] = "file:" + hashlib.sha256(open(p, "rb").read()).hexdigest() + (":x" if os.access(p, os.X_OK) else "")
json.dump({"password": "interop-pw", "entries": dict(sorted(entries.items()))}, open(out, "w"), indent=1, ensure_ascii=False)
PY
du -sh "$OUT"; ls "$OUT" | wc -l
