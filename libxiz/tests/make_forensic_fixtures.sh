#!/bin/sh
# Forensic profile (XIZ 1.10, §20) test vectors, written by xipper-forensic (macOS only).
# Content is synthetic. Usage: tests/make_forensic_fixtures.sh [xipper] [xipper-forensic] [xiz_manifest]
# Needs fixtures/signing.key (from make_fixtures.sh, which calls this script at the end).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
X=${1:-$root/.build/release/xipper}
XF=${2:-$root/.build/release/xipper-forensic}
M=${3:-$here/../build/xiz_manifest}
out=$here/fixtures
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
[ -x "$X" ] && [ -x "$XF" ] || { echo "build first: swift build -c release --product xipper --product xipper-forensic" >&2; exit 2; }
[ -x "$M" ] || { echo "build xiz_manifest first (cmake)" >&2; exit 2; }
[ -f "$out/signing.key" ] || "$X" keygen --signing -o "$out/signing.key" > /dev/null
rm -f "$out"/forensic*

# A synthetic 9.7 MB "disk": 4 MiB of text, a 4 MiB block of zeros, 1 MiB of noise, a short zero tail.
img=$work/disk.img
awk 'BEGIN { for (i = 0; i < 4 * 1024 * 16; i++) printf("sector %08d of a synthetic disk..........................\n", i) }' > "$img"
head -c 4194304 /dev/zero >> "$img"
LC_ALL=C awk 'BEGIN { srand(7); for (i = 0; i < 1048576; i++) printf("%c", int(rand() * 255) + 1) }' >> "$img"
head -c 300000 /dev/zero >> "$img"

common="--sign $out/signing.key --signer Esaminatore --case 2026-117 --evidence R01 --examiner Esaminatore
        --organization Laboratorio --device-model SyntheticDisk --device-serial SN-0001 --time 2026-11-10T09:00:00Z"
# shellcheck disable=SC2086
"$XF" acquire --image "$img" -o "$out/forensic.xiz" --unreadable 1000:512 $common | sed -n 's/^SHA-256 *//p' > "$out/forensic.sha256"
"$XF" custody "$out/forensic.xiz" --from Esaminatore --to Laboratorio --seals "sigillo 4471" \
    --sign "$out/signing.key" --signer Corriere --time 2026-11-10T12:00:00Z > /dev/null
mkdir -p "$work/x"
"$X" extract -q -d "$work/x" --into "$out/forensic.xiz" > /dev/null
"$M" "$work/x" > "$out/forensic.manifest"

pw='correct horse battery staple'
# shellcheck disable=SC2086
printf '%s\n' "$pw" | "$XF" acquire --image "$img" -o "$out/forensic-password.xiz" --password-stdin $common > /dev/null
"$XF" custody "$out/forensic-password.xiz" --from Esaminatore --to Corriere \
    --sign "$out/signing.key" --signer Corriere --time 2026-11-10T12:00:00Z > /dev/null

# A logical acquisition (folders): the inventory lists every item, the unreadable and special ones too.
lt=$work/logical/Utente
mkdir -p "$lt/Mail/INBOX" "$lt/Documenti/città"
for i in 1 2 3; do printf 'Messaggio %d, sintetico.\n' "$i" > "$lt/Mail/INBOX/$i.eml"; done
printf 'documento\n' > "$lt/Documenti/città/è.txt"
head -c 300000 "$img" > "$lt/Documenti/dati.bin"
ln -s ../Mail "$lt/Documenti/posta"
printf 'non leggibile\n' > "$lt/Documenti/chiuso.txt"; chmod 000 "$lt/Documenti/chiuso.txt"
mkfifo "$lt/Documenti/pipe"
find "$lt" -exec touch -h -t 202601020304.05 {} +
"$XF" acquire --logical "$lt" -o "$out/forensic-logical.xiz" $common > "$work/logical.log"
chmod 600 "$lt/Documenti/chiuso.txt"
mkdir -p "$work/xl"
"$X" extract -q -d "$work/xl" --into "$out/forensic-logical.xiz" > /dev/null
"$M" "$work/xl" > "$out/forensic-logical.manifest"

# One byte of the first frame's payload flipped (the frame's CRC and its signed hash no longer match).
cp "$out/forensic.xiz" "$out/forensic-damaged.xiz"
printf '\377' | dd of="$out/forensic-damaged.xiz" bs=1 seek=196 conv=notrunc 2> /dev/null

"$XF" verify "$out/forensic.xiz" > /dev/null
echo "forensic fixtures written"
