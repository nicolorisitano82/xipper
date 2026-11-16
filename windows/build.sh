#!/bin/bash
# Xipper XIZ for Windows (docs/STUDIO_WINDOWS_XIZ.md): cross-built on the Mac with zig, x86_64 and
# ARM64, libxiz linked statically. Output: .build/windows-app/<arch>/XipperXIZ.exe; with --pack also
# dist/XipperXIZ-VERSION-windows-<arch>.zip (exe, xiz.exe, licenses) and their SHA-256.
#   windows/build.sh [--pack] [x86_64|aarch64 ...]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
VERSION=$(cat windows/VERSION)
WORK="$ROOT/.build/windows-app"
PACK=0
ARCHS=()
for a in "$@"; do
    case $a in
        --pack) PACK=1 ;;
        x86_64|aarch64) ARCHS+=("$a") ;;
        *) echo "usage: windows/build.sh [--pack] [x86_64|aarch64 ...]"; exit 2 ;;
    esac
done
[ ${#ARCHS[@]} -gt 0 ] || ARCHS=(x86_64 aarch64)
command -v zig > /dev/null || { echo "zig is needed: brew install zig"; exit 2; }
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexec zig ar "$@"\n' > "$WORK/bin/zig-ar"
printf '#!/bin/sh\nexec zig ranlib "$@"\n' > "$WORK/bin/zig-ranlib"
chmod +x "$WORK/bin/"*

python3 -I windows/check-strings.py || { echo "translations: placeholders differ from English"; exit 1; }
IFS=. read -r V1 V2 V3 <<< "$VERSION"
for arch in "${ARCHS[@]}"; do
    target=$arch-windows-gnu
    lib="$WORK/$arch/libxiz"
    mkdir -p "$WORK/$arch"
    # libxiz (and xiz.exe for the package), Release, no tests.
    env -u LDFLAGS -u CPPFLAGS -u CFLAGS -u CXXFLAGS cmake -S libxiz -B "$lib" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_C_COMPILER="zig;cc;-target;$target" -DCMAKE_CXX_COMPILER="zig;c++;-target;$target" \
        -DCMAKE_AR="$WORK/bin/zig-ar" -DCMAKE_RANLIB="$WORK/bin/zig-ranlib" \
        -DXIZ_TESTS=OFF -DXIZ_SANITIZE=OFF -DCMAKE_DEPENDS_USE_COMPILER=OFF -DCMAKE_LINK_DEPENDS_USE_LINKER=OFF \
        -DCMAKE_EXE_LINKER_FLAGS=-s > "$lib.log" 2>&1
    env -u LDFLAGS cmake --build "$lib" -j --target xiz_cli >> "$lib.log" 2>&1 || { tail -20 "$lib.log"; echo "libxiz build failed: $arch"; exit 1; }
    # The resources, with the version and absolute paths (zig's resource compiler takes no -D).
    sed -e "s|XIZW_VERSION_COMMAS|$V1,$V2,$V3,0|g" -e "s|XIZW_VERSION_STRING|\"$VERSION\"|g" \
        -e "s|\"app.ico\"|\"$ROOT/windows/res/app.ico\"|" -e "s|\"xiz.ico\"|\"$ROOT/windows/res/xiz.ico\"|" \
        -e "s|\"app.manifest\"|\"$ROOT/windows/res/app.manifest\"|" -e "s|\"../src/resource.h\"|\"$ROOT/windows/src/resource.h\"|" \
        windows/res/app.rc > "$WORK/$arch/app.rc"
    rcarch=$([ "$arch" = aarch64 ] && echo arm64 || echo x64)
    zig rc /:target "$rcarch" /:auto-includes gnu /fo "$WORK/$arch/app.res" "$WORK/$arch/app.rc"
    # zxcvbn (password strength, the same as the Mac app's), as C.
    # zxcvbn.c includes "stdafx.h" on Windows (Visual Studio's precompiled header): an empty one.
    mkdir -p "$WORK/$arch/inc" && : > "$WORK/$arch/inc/stdafx.h"
    zig cc -target "$target" -O2 -c -I"$WORK/$arch/inc" -IVendor/zxcvbn/include Vendor/zxcvbn/src/zxcvbn.c -o "$WORK/$arch/zxcvbn.o"
    # The app.
    zig c++ -target "$target" -std=c++17 -O2 -municode -Wall -Wextra -Werror -Wno-missing-field-initializers \
        -DUNICODE -D_UNICODE \
        -DXIZW_VERSION="\"$VERSION\"" \
        -Ilibxiz/include -IVendor/zxcvbn/include windows/src/main.cpp windows/src/core.cpp windows/src/strings.cpp windows/src/strings_i18n.cpp windows/src/dragdrop.cpp "$WORK/$arch/app.res" "$WORK/$arch/zxcvbn.o" \
        "$lib/libxiz.a" -lcomctl32 -lshell32 -lshlwapi -lole32 -luuid -luxtheme -lnormaliz -lbcrypt -ladvapi32 -lgdi32 -luser32 \
        -Wl,--subsystem,windows -s -o "$WORK/$arch/XipperXIZ.exe"
    cp "$lib/xiz.exe" "$WORK/$arch/xiz.exe"
    ls -l "$WORK/$arch/XipperXIZ.exe" | awk -v a="$arch" '{print a": XipperXIZ.exe", $5, "bytes"}'
done

if [ $PACK = 1 ]; then
    mkdir -p dist
    for arch in "${ARCHS[@]}"; do
        name="XipperXIZ-$VERSION-windows-$arch"
        stage="$WORK/stage/$name"
        rm -rf "$stage" && mkdir -p "$stage/licenses"
        cp "$WORK/$arch/XipperXIZ.exe" "$WORK/$arch/xiz.exe" "$stage/"
        cp LICENSE "$stage/LICENSE.txt"
        cp windows/LEGGIMI.txt windows/README.txt "$stage/"
        for f in libxiz/third_party/*/LICEN* Vendor/zstd/LICENSE Vendor/xz/COPYING* Vendor/argon2/LICENSE Vendor/brunsli/LICENSE \
                 Vendor/brotli/LICENSE Vendor/preflate/LICENSE* Vendor/openzl/LICENSE; do
            [ -f "$f" ] && cp "$f" "$stage/licenses/$(echo "$f" | tr '/' '_')"
        done
        rm -f "dist/$name.zip"
        (cd "$WORK/stage" && zip -qr "$ROOT/dist/$name.zip" "$name")
        (cd dist && shasum -a 256 "$name.zip" > "$name.zip.sha256")
        ls -l "dist/$name.zip"
    done
fi
