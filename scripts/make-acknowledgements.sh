#!/bin/zsh
# Builds App/Xipper/Acknowledgements.txt from the licenses of the vendored code (Vendor/README.md):
# the BSD/MIT licenses require their notices to travel with the binary (the DMG).
# Run it after updating anything in Vendor/.
set -euo pipefail
cd "$(dirname "$0")/.."
out=App/Xipper/Acknowledgements.txt
section() {  # title, source, license file
    print -r -- "================================================================================"
    print -r -- "$1"
    print -r -- "$2"
    print -r -- "================================================================================"
    print
    cat "$3"
    print
    print
}
{
    print -r -- "Xipper includes the following open-source software, compiled into the app."
    print -r -- "Thank you to their authors."
    print
    section "Xipper" "https://github.com/nicolorisitano82/xipper" LICENSE
    section "zstd 1.5.7" "https://github.com/facebook/zstd" Vendor/zstd/LICENSE
    section "libdeflate 1.24" "https://github.com/ebiggers/libdeflate" Vendor/libdeflate/COPYING
    section "XZ Utils / liblzma 5.8.1" "https://github.com/tukaani-project/xz" Vendor/xz/COPYING.0BSD
    section "htscodecs 1.6.7 (Genome Research Ltd; rANS by Fabian Giesen, range coder by Eugene Shelwien)" "https://github.com/samtools/htscodecs" Vendor/htscodecs/LICENSE.md
    section "libarchive 3.8.10 (RAR and RAR5 readers)" "https://github.com/libarchive/libarchive" Vendor/libarchive/COPYING
    section "Argon2 (reference implementation, used under CC0 1.0)" "https://github.com/P-H-C/phc-winner-argon2" Vendor/argon2/LICENSE
    print -r -- "================================================================================"
    print -r -- "LZMA SDK 26.05 (Igor Pavlov; PPMd by Dmitry Shkarin)"
    print -r -- "https://www.7-zip.org/sdk.html"
    print -r -- "================================================================================"
    print
    print -r -- "The LZMA SDK files used by Xipper (LZMA/LZMA2 decoder, its ARM64 assembly loop and the"
    print -r -- "PPMd variant H decoder) are placed in the public domain by their authors."
} > "$out"
print "wrote $out ($(wc -c < "$out" | tr -d ' ') bytes)"
