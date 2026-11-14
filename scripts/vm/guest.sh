#!/bin/bash
# Runs inside the test VM (copied there by powercut.sh): the «Cambia formato» with little space
# that the host switches off at random. Works in ~/pc on the guest's own disk.
#   guest.sh setup    about 1.5 GB of files and their checksums (once)
#   guest.sh time     seconds one whole conversion takes (to place the cuts)
#   guest.sh reset    a fresh a.zip, no a.xiz
#   guest.sh start    starts the conversion in the background and returns
#   guest.sh finish   after a reboot: runs the conversion again until it is done, then checks it
#   guest.sh state    what is on disk (for the log)
set -uo pipefail
W=$HOME/pc
X=$W/xipper
cd "$W" || exit 1
export XIPPER_LOWSPACE_BATCH=$((16 << 20))

# F_FULLFSYNC (51): the file and its folder really on the disk (sync(1) only starts the writes).
fullsync() { perl -e 'for (@ARGV) { open(my $f, "<", $_) or die "$_: $!"; fcntl($f, 51, 0) or die "F_FULLFSYNC $_: $!" }' "$@"; }

convert() { "$X" convert -q --to xiz -l 1 --little-space "$W/a.zip" -o "$W/a.xiz"; }

case ${1:-} in
setup)
    rm -rf src expected.sha; mkdir -p src/dir src/empty
    for i in $(seq 1 40); do head -c $((36 * 1024 * 1024 + i * 4096)) /dev/urandom > "src/dir/r$i.bin"; done
    for i in $(seq 1 200); do echo "text $i" > "src/dir/t$i.txt"; done
    (cd src && find . -type f -print0 | sort -z | xargs -0 shasum -a 256) > expected.sha
    echo "setup ok"
    ;;
reset)
    rm -rf a.zip a.xiz .*.xipper-partial *.xipper-resume .xipper-convert-* out 2>/dev/null
    (cd src && /usr/bin/zip -q -r -0 "$W/a.zip" .)
    fullsync a.zip .
    echo "reset ok"
    ;;
start)
    nohup bash -c "$(declare -f convert); X=$X W=$W XIPPER_LOWSPACE_BATCH=$XIPPER_LOWSPACE_BATCH convert" > start.log 2>&1 < /dev/null &
    echo "started $!"
    ;;
time)
    "$W/guest.sh" reset > /dev/null
    s=$(perl -MTime::HiRes=time -e 'print time'); convert > /dev/null 2>&1
    perl -MTime::HiRes=time -e "printf '%.2f', time - $s"; echo
    ;;
state)
    ls -la "$W" | grep -vE " src$| expected.sha$| xipper$| guest.sh$" | tail -n +2
    ;;
finish)
    tries=0
    until [ -e a.xiz ] && [ ! -e a.zip ] && ! ls *.xipper-resume > /dev/null 2>&1; do
        tries=$((tries + 1))
        [ $tries -le 5 ] || { echo "FAIL: not done after 5 runs"; exit 1; }
        if [ ! -e a.zip ] && [ ! -e a.xiz ]; then echo "FAIL: neither the original nor the new archive"; exit 1; fi
        convert 2> err.log || echo "run $tries: $(tail -1 err.log)"
    done
    [ ! -e a.zip ] || { echo "FAIL: original still there"; exit 1; }
    rm -rf out; mkdir out
    "$X" extract -q --into -d out a.xiz > /dev/null || { echo "FAIL: extract"; exit 1; }
    (cd out && find . -type f -print0 | sort -z | xargs -0 shasum -a 256) > got.sha
    cmp -s expected.sha got.sha || { echo "FAIL: contents differ"; diff expected.sha got.sha | head -5; exit 1; }
    echo "OK after $tries runs"
    ;;
*)
    echo "usage: guest.sh setup|reset|start|state|finish"; exit 2
    ;;
esac
