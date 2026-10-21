#!/bin/zsh
# Repeatable benchmark (STUDIO.md §5.4): Xipper against the tools on this Mac, on a generated
# mixed corpus (source code, text, already-compressed data, many small files, one big file).
# Usage: scripts/benchmark.sh [corpus-size-MB, default 600] [runs, default 3]
# Writes a Markdown table to stdout; the corpus and archives live in a temporary folder.
set -euo pipefail
setopt null_glob
cd "$(dirname "$0")/.."
SIZE_MB=${1:-600}
RUNS=${2:-3}
swift build -c release --product xipper-cli >/dev/null 2>&1 || swift build -c release >/dev/null
BIN=$(swift build -c release --show-bin-path 2>/dev/null)
X=$BIN/xipper
[ -x "$X" ] || X=$BIN/xipper-cli
SEVEN=$(command -v 7zz || true)
ZSTD=$(command -v zstd || true)
W=$(mktemp -d "${TMPDIR:-/tmp}/xipper-bench.XXXX")
trap 'rm -rf "$W"' EXIT

# Corpus: deterministic (seeded) so runs on different Macs are comparable.
python3 -I - "$W/corpus" "$SIZE_MB" <<'PY'
import os, random, sys, zlib
root, total = sys.argv[1], int(sys.argv[2]) << 20
rnd = random.Random(42)
os.makedirs(root, exist_ok=True)
words = [bytes(rnd.choice(b"abcdefghijklmnopqrstuvwxyz") for _ in range(rnd.randint(2, 9))) for _ in range(4000)]
def text(n):
    out = bytearray()
    while len(out) < n:
        out += b" ".join(rnd.choice(words) for _ in range(12)) + b"\n"
    return bytes(out[:n])
budget = {"src": .30, "docs": .20, "media": .30, "big": .20}
# Many small "source" files.
d, used, i = os.path.join(root, "src"), 0, 0
while used < total * budget["src"]:
    sub = os.path.join(d, f"pkg{i % 40}")
    os.makedirs(sub, exist_ok=True)
    n = rnd.randint(2_000, 40_000)
    open(os.path.join(sub, f"file{i}.swift"), "wb").write(text(n)); used += n; i += 1
# Medium text documents.
d, used, i = os.path.join(root, "docs"), 0, 0
os.makedirs(d, exist_ok=True)
while used < total * budget["docs"]:
    n = rnd.randint(200_000, 2_000_000)
    open(os.path.join(d, f"doc{i}.txt"), "wb").write(text(n)); used += n; i += 1
# Incompressible "media" (already compressed).
d, used, i = os.path.join(root, "media"), 0, 0
os.makedirs(d, exist_ok=True)
while used < total * budget["media"]:
    n = rnd.randint(1_000_000, 8_000_000)
    open(os.path.join(d, f"photo{i}.jpg"), "wb").write(rnd.randbytes(n)); used += n; i += 1
# One big, partly compressible file.
with open(os.path.join(root, "big.log"), "wb") as f:
    left = int(total * budget["big"])
    while left > 0:
        chunk = text(min(left, 4 << 20)) if rnd.random() < .7 else rnd.randbytes(min(left, 4 << 20))
        f.write(chunk); left -= len(chunk)
PY

INPUT=$(du -sk "$W/corpus" | cut -f1)
FILES=$(find "$W/corpus" -type f | wc -l | tr -d ' ')
best() {  # best wall time of RUNS runs of "$@", in seconds
  python3 -I - "$RUNS" "$W" "$@" <<'PY'
import glob, os, subprocess, sys, time
runs, work, cmd = int(sys.argv[1]), sys.argv[2], sys.argv[3:]
best = float("inf")
for _ in range(runs):
    for f in glob.glob(os.path.join(work, "out.*")): os.remove(f)
    s = time.perf_counter()
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    best = min(best, time.perf_counter() - s)
print(f"{best:.3f}")
PY
}
row() {  # name, output file, command…
  local name=$1 out=$2; shift 2
  local t=$(best "$@")
  python3 -c "
import os
t, inp, out = $t, $INPUT * 1024, '$out'
size = os.path.getsize(out) if os.path.exists(out) else 0
print(f'| $name | {t:.2f} s | {inp / t / 1e6:.0f} MB/s | {size / 1e6:.0f} MB | {size / inp * 100:.1f}% |' if size else f'| $name | {t:.2f} s | — | (non creato) | — |')"
}

echo "## Benchmark Xipper — $(sysctl -n machdep.cpu.brand_string), $(sw_vers -productVersion), $(date +%Y-%m-%d)"
echo
echo "Corpus: $((INPUT / 1024)) MB, $FILES file (sorgenti piccoli, testi, dati già compressi, un file grande). Miglior tempo su $RUNS esecuzioni, cache calda."
echo
echo "### Creazione"
echo
echo "| Strumento | Tempo | Velocità | Archivio | Rapporto |"
echo "|---|---|---|---|---|"
row "Xipper ZIP (deflate, livello 6)" "$W/out.zip" "$X" create -q --overwrite "$W/out.zip" "$W/corpus"
row "ditto -c -k (Utility Archivio)" "$W/out.zip" /usr/bin/ditto -c -k --keepParent "$W/corpus" "$W/out.zip"
row "zip -r -6 (Info-ZIP)" "$W/out.zip" /bin/sh -c "cd '$W' && /usr/bin/zip -q -r -6 out.zip corpus"
row "Xipper tar.zst (livello 3)" "$W/out.tar.zst" "$X" create -q --overwrite "$W/out.tar.zst" "$W/corpus"
[ -n "$ZSTD" ] && row "tar + zstd -3 -T0" "$W/out.tar.zst" /bin/sh -c "tar -cf - -C '$W' corpus | '$ZSTD' -q -3 -T0 -o '$W/out.tar.zst'"
row "Xipper 7z (livello 6)" "$W/out.7z" "$X" create -q --overwrite "$W/out.7z" "$W/corpus"
[ -n "$SEVEN" ] && row "7zz a -mx5" "$W/out.7z" "$SEVEN" a -mx5 "$W/out.7z" "$W/corpus"
echo
echo "### Verifica ed estrazione"
echo
echo "| Operazione | Tempo |"
echo "|---|---|"
"$X" create -q --overwrite "$W/a.zip" "$W/corpus" >/dev/null; "$X" create -q --overwrite "$W/a.tar.zst" "$W/corpus" >/dev/null
printf "| Xipper test ZIP | %.2f s |\n" "$(best "$X" test -q "$W/a.zip")"
printf "| unzip -t | %.2f s |\n" "$(best /usr/bin/unzip -qt "$W/a.zip")"
printf "| Xipper extract ZIP | %.2f s |\n" "$(best /bin/sh -c "rm -rf '$W/x' && mkdir '$W/x' && '$X' extract -q --into -d '$W/x' '$W/a.zip'")"
printf "| ditto -x -k | %.2f s |\n" "$(best /bin/sh -c "rm -rf '$W/x' && /usr/bin/ditto -x -k '$W/a.zip' '$W/x'")"
printf "| Xipper extract tar.zst | %.2f s |\n" "$(best /bin/sh -c "rm -rf '$W/x' && mkdir '$W/x' && '$X' extract -q --into -d '$W/x' '$W/a.tar.zst'")"
[ -n "$ZSTD" ] && printf "| zstd -d + tar -x | %.2f s |\n" "$(best /bin/sh -c "rm -rf '$W/x' && mkdir '$W/x' && '$ZSTD' -q -d -c '$W/a.tar.zst' | tar -xf - -C '$W/x'")"
