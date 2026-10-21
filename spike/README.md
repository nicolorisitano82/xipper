# Spike fase 0

Codice usa e getta per misurare codec e prototipare lo ZIP parallelo. Report: [../SPIKE_FASE0.md](../SPIKE_FASE0.md).

## Layout
- `Vendor/`: zstd v1.5.7 (BSD), libdeflate v1.24 (MIT), xz v5.8.1 (si usa solo liblzma, 0BSD)
- `build/`: librerie statiche arm64 (CMake, `-O3 -mcpu=apple-m1`) e il binario `bench`
- `bench/bench.c`: benchmark di codec, checksum e crittografia
- `xipzip/`: prototipo Swift di writer e tester ZIP parallelo
- `corpus/`: corpus di test generato da file locali (non versionare)
- `results/`: output grezzo dei benchmark

## Ricostruire
```bash
cd spike
CF="-O3 -mcpu=apple-m1 -DNDEBUG"
cmake -S Vendor/zstd/build/cmake -B build/zstd -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS="$CF" -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_SHARED=OFF && cmake --build build/zstd -j
cmake -S Vendor/libdeflate -B build/libdeflate -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS="$CF" -DLIBDEFLATE_BUILD_SHARED_LIB=OFF -DLIBDEFLATE_BUILD_GZIP=OFF && cmake --build build/libdeflate -j
cmake -S Vendor/xz -B build/xz -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS="$CF" -DBUILD_SHARED_LIBS=OFF -DXZ_TOOL_XZ=OFF -DXZ_TOOL_XZDEC=OFF -DXZ_TOOL_LZMADEC=OFF -DXZ_TOOL_LZMAINFO=OFF -DXZ_TOOL_SCRIPTS=OFF -DXZ_DOC=OFF -DXZ_NLS=OFF && cmake --build build/xz -j
clang -O3 -mcpu=apple-m1 -o build/bench bench/bench.c -IVendor/libdeflate -IVendor/zstd/lib -IVendor/xz/src/liblzma/api \
  build/libdeflate/libdeflate.a build/zstd/lib/libzstd.a build/xz/liblzma.a -lz -lbz2 -lcompression
(cd xipzip && swift build -c release)
```

## Eseguire
```bash
./build/bench corpus/mix.tar 64 all
xipzip/.build/release/xipzip create out.zip corpus/tree -l 6 [-j N] [--engine libdeflate|zlib]
xipzip/.build/release/xipzip test out.zip [-j N]
```
