#!/bin/bash
# The independent reader for whoever receives an evidence archive (docs/XIPPER_FORENSIC.md §3.1, P6):
# `xiz` from libxiz (C99), built for Linux (x86_64, arm64, static musl), Windows (x86_64) and macOS
# (arm64), packed with a README into dist/xiz-VERSION-PLATFORM.(tar.gz|zip) plus a SHA256SUMS file.
# Cross-compiled with zig (brew install zig); the macOS build uses the system compiler.
#   scripts/build-xiz-portable.sh [VERSION]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
VERSION="${1:-$(sed -nE 's/.*toolVersion = "([0-9.]+).*/\1/p' Sources/ForensicKit/ForensicReport.swift)}"
OUT="$ROOT/dist/xiz-$VERSION"
WORK="$ROOT/.build/xiz-portable"
command -v zig >/dev/null || { echo "zig is needed: brew install zig"; exit 2; }
rm -rf "$OUT" && mkdir -p "$OUT" "$WORK/bin"

# zig as ar/ranlib for the cross builds (CMake wants single executables).
printf '#!/bin/sh\nexec zig ar "$@"\n' > "$WORK/bin/zig-ar"
printf '#!/bin/sh\nexec zig ranlib "$@"\n' > "$WORK/bin/zig-ranlib"
chmod +x "$WORK/bin/"*

build() {  # name zig-target system
    local name=$1 target=$2 system=$3 dir="$WORK/$1"
    rm -rf "$dir"
    env -u LDFLAGS -u CPPFLAGS -u CFLAGS -u CXXFLAGS cmake -S libxiz -B "$dir" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME="$system" -DCMAKE_C_COMPILER="zig;cc;-target;$target" -DCMAKE_CXX_COMPILER="zig;c++;-target;$target" \
        -DCMAKE_AR="$WORK/bin/zig-ar" -DCMAKE_RANLIB="$WORK/bin/zig-ranlib" \
        -DXIZ_TESTS=OFF -DXIZ_SANITIZE=OFF -DCMAKE_DEPENDS_USE_COMPILER=OFF -DCMAKE_LINK_DEPENDS_USE_LINKER=OFF -DCMAKE_EXE_LINKER_FLAGS=-s > "$dir.log" 2>&1
    env -u LDFLAGS cmake --build "$dir" -j --target xiz_cli >> "$dir.log" 2>&1 || { tail -20 "$dir.log"; echo "build failed: $name"; exit 1; }
}

native() {
    local dir="$WORK/macos-arm64"
    rm -rf "$dir"
    cmake -S libxiz -B "$dir" -DCMAKE_BUILD_TYPE=Release -DXIZ_TESTS=OFF -DXIZ_SANITIZE=OFF -DCMAKE_OSX_ARCHITECTURES=arm64 > "$dir.log" 2>&1
    cmake --build "$dir" -j --target xiz_cli >> "$dir.log" 2>&1 || { tail -20 "$dir.log"; echo "build failed: macos"; exit 1; }
}

build linux-x86_64 x86_64-linux-musl Linux
build linux-arm64 aarch64-linux-musl Linux
build windows-x86_64 x86_64-windows-gnu Windows
native

readme() {
cat <<EOF
xiz $VERSION — independent reader of XIZ archives (libxiz, C99, MIT)

Checks a forensic archive (XIZ 1.10) made by Xipper Forensic without Xipper and without a Mac:
structure, frame hashes, signatures and their chain, the image against the source SHA-256,
logical acquisitions against the signed inventory.

  xiz forensic ARCHIVE.xiz            check everything (exit code 0 = verified)
  xiz forensic --records ARCHIVE.xiz  also print the case, device and acquisition records
  xiz history ARCHIVE.xiz             who signed each segment, when (Ed25519 key or certificate)
  xiz cat ARCHIVE.xiz image.dd | sha256sum      the image, to compare with the report
  xiz extract -d DIR ARCHIVE.xiz      extract (an encrypted archive: --password-env VAR)

Certificate signatures are checked with the certificate's key; whether the issuer is trusted
is up to you (xiz prints the certificate's SHA-256). Time-stamps are reported, not verified.
Source: https://github.com/nicolorisitano82/xipper (libxiz/). Specification: docs/XIZ_SPEC.md.
EOF
}

pack() {  # name binary
    local name=$1 bin=$2 stage="$WORK/stage/xiz-$VERSION-$1"
    rm -rf "$stage" && mkdir -p "$stage"
    cp "$bin" "$stage/"
    readme > "$stage/README.txt"
    cp libxiz/third_party/bearssl/LICENSE* "$stage/LICENSE-BearSSL.txt" 2>/dev/null || true
    cp LICENSE "$stage/LICENSE.txt" 2>/dev/null || true
    (cd "$WORK/stage" && if [[ $name == windows-* ]]; then zip -qr "$OUT/xiz-$VERSION-$name.zip" "xiz-$VERSION-$name"; \
        else tar -czf "$OUT/xiz-$VERSION-$name.tar.gz" "xiz-$VERSION-$name"; fi)
}

pack linux-x86_64 "$WORK/linux-x86_64/xiz"
pack linux-arm64 "$WORK/linux-arm64/xiz"
pack windows-x86_64 "$WORK/windows-x86_64/xiz.exe"
pack macos-arm64 "$WORK/macos-arm64/xiz"
(cd "$OUT" && shasum -a 256 xiz-* > SHA256SUMS)
file "$WORK"/*/xiz "$WORK"/*/xiz.exe | sed "s|$WORK/||"
ls -l "$OUT"
