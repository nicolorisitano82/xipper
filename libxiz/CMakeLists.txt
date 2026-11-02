cmake_minimum_required(VERSION 3.16)
project(libxiz VERSION 0.1.0 LANGUAGES C)

# libxiz: an independent C99 implementation of XIZ (docs/XIZ_SPEC.md). Codecs come from the
# sources Xipper vendors in ../Vendor (zstd, liblzma, Argon2); crypto from third_party/.

option(XIZ_WERROR "Treat warnings as errors in libxiz's own sources" OFF)
option(XIZ_SANITIZE "Address and undefined-behaviour sanitizers (default in Debug)" ON)
option(XIZ_FUZZ "Build the libFuzzer targets (clang)" OFF)
option(XIZ_TESTS "Build and register the tests" ON)
set(XIZ_VENDOR_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../Vendor" CACHE PATH "Xipper's Vendor directory")

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

# ---------------------------------------------------------------- dependencies (not our code)

set(ZSTD_DIR "${XIZ_VENDOR_DIR}/zstd")
file(GLOB ZSTD_SOURCES "${ZSTD_DIR}/common/*.c" "${ZSTD_DIR}/compress/*.c" "${ZSTD_DIR}/decompress/*.c")
add_library(xiz_zstd OBJECT ${ZSTD_SOURCES})
target_include_directories(xiz_zstd SYSTEM PUBLIC "${ZSTD_DIR}")
target_compile_definitions(xiz_zstd PUBLIC ZSTD_DISABLE_ASM XXH_NAMESPACE=ZSTD_ PRIVATE ZSTD_LEGACY_SUPPORT=0)

set(XZ_DIR "${XIZ_VENDOR_DIR}/xz/src")
add_library(xiz_lzma OBJECT
  "${XZ_DIR}/liblzma/common/common.c"
  "${XZ_DIR}/liblzma/common/filter_common.c"
  "${XZ_DIR}/liblzma/common/filter_decoder.c"
  "${XZ_DIR}/liblzma/lz/lz_decoder.c"
  "${XZ_DIR}/liblzma/lzma/lzma_decoder.c"
  "${XZ_DIR}/liblzma/lzma/lzma2_decoder.c"
  "${XZ_DIR}/liblzma/simple/arm64.c"
  "${XZ_DIR}/liblzma/simple/simple_coder.c"
  "${XZ_DIR}/liblzma/simple/simple_decoder.c")
target_include_directories(xiz_lzma SYSTEM PUBLIC "${XZ_DIR}/liblzma/api"
  PRIVATE "${XZ_DIR}/liblzma/common" "${XZ_DIR}/liblzma/check" "${XZ_DIR}/liblzma/lz" "${XZ_DIR}/liblzma/rangecoder"
          "${XZ_DIR}/liblzma/lzma" "${XZ_DIR}/liblzma/delta" "${XZ_DIR}/liblzma/simple" "${XZ_DIR}/common")
# Decoder-only, single-threaded liblzma: LZMA2 raw frames and the ARM64 branch filter (§14).
target_compile_definitions(xiz_lzma PUBLIC LZMA_API_STATIC PRIVATE
  HAVE_STDINT_H HAVE_STDBOOL_H HAVE_INTTYPES_H HAVE__BOOL
  HAVE_DECODER_LZMA1 HAVE_DECODER_LZMA2 HAVE_DECODER_ARM64
  HAVE_VISIBILITY=0 TUKLIB_SYMBOL_PREFIX=lzma_)

set(ARGON2_DIR "${XIZ_VENDOR_DIR}/argon2")
add_library(xiz_argon2 OBJECT
  "${ARGON2_DIR}/src/argon2.c" "${ARGON2_DIR}/src/core.c" "${ARGON2_DIR}/src/encoding.c"
  "${ARGON2_DIR}/src/ref.c" "${ARGON2_DIR}/src/thread.c" "${ARGON2_DIR}/src/blake2/blake2b.c")
target_include_directories(xiz_argon2 SYSTEM PUBLIC "${ARGON2_DIR}/include")

file(GLOB BEARSSL_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/third_party/bearssl/src/*.c")
add_library(xiz_crypto OBJECT ${BEARSSL_SOURCES}
  third_party/monocypher/monocypher.c third_party/monocypher/monocypher-ed25519.c)
target_include_directories(xiz_crypto SYSTEM PUBLIC third_party/bearssl/inc third_party/monocypher
  PRIVATE third_party/bearssl/src)

foreach(dep xiz_zstd xiz_lzma xiz_argon2 xiz_crypto)
  set_target_properties(${dep} PROPERTIES POSITION_INDEPENDENT_CODE ON C_STANDARD 99 C_EXTENSIONS ON)
  if(MSVC)
    target_compile_options(${dep} PRIVATE /W0)
  else()
    target_compile_options(${dep} PRIVATE -w)
  endif()
endforeach()

# ---------------------------------------------------------------- warnings and sanitizers

set(XIZ_WARNINGS)
if(MSVC)
  set(XIZ_WARNINGS /W4 /wd4996)
  if(XIZ_WERROR)
    list(APPEND XIZ_WARNINGS /WX)
  endif()
else()
  set(XIZ_WARNINGS -Wall -Wextra -Wpedantic -Wshadow -Wformat=2 -Wstrict-prototypes -Wmissing-prototypes
      -Wvla -Wundef -Wcast-align -Wpointer-arith -Wwrite-strings -Wnull-dereference -Wdouble-promotion)
  if(XIZ_WERROR)
    list(APPEND XIZ_WARNINGS -Werror)
  endif()
endif()

set(XIZ_SAN_FLAGS)
if(XIZ_SANITIZE AND CMAKE_BUILD_TYPE STREQUAL "Debug" AND NOT MSVC AND NOT WIN32)
  set(XIZ_SAN_FLAGS -fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=undefined)
endif()

# ---------------------------------------------------------------- the library

add_library(xiz STATIC
  src/util.c src/crypto.c src/format.c src/codec.c src/keys.c src/reader.c src/data.c
  src/io.c src/extract.c src/sign.c src/writer.c
  $<TARGET_OBJECTS:xiz_zstd> $<TARGET_OBJECTS:xiz_lzma> $<TARGET_OBJECTS:xiz_argon2> $<TARGET_OBJECTS:xiz_crypto>)
target_include_directories(xiz PUBLIC include PRIVATE src)
target_link_libraries(xiz PRIVATE xiz_zstd xiz_lzma xiz_argon2 xiz_crypto)
target_compile_options(xiz PRIVATE ${XIZ_WARNINGS} ${XIZ_SAN_FLAGS})
target_link_options(xiz PUBLIC ${XIZ_SAN_FLAGS})
if(WIN32)
  target_link_libraries(xiz PUBLIC bcrypt)
  target_compile_definitions(xiz PRIVATE WIN32_LEAN_AND_MEAN _CRT_SECURE_NO_WARNINGS UNICODE _UNICODE)
else()
  target_compile_definitions(xiz PRIVATE _POSIX_C_SOURCE=200809L _DARWIN_C_SOURCE _DEFAULT_SOURCE)
  find_package(Threads REQUIRED)
  target_link_libraries(xiz PUBLIC Threads::Threads)
endif()
set_target_properties(xiz PROPERTIES POSITION_INDEPENDENT_CODE ON OUTPUT_NAME xiz)

add_executable(xiz_cli tools/xiz.c)
set_target_properties(xiz_cli PROPERTIES OUTPUT_NAME xiz)
target_link_libraries(xiz_cli PRIVATE xiz)
target_compile_options(xiz_cli PRIVATE ${XIZ_WARNINGS} ${XIZ_SAN_FLAGS})
if(NOT WIN32)
  target_compile_definitions(xiz_cli PRIVATE _POSIX_C_SOURCE=200809L _DARWIN_C_SOURCE _DEFAULT_SOURCE)
endif()

install(TARGETS xiz xiz_cli ARCHIVE DESTINATION lib RUNTIME DESTINATION bin)
install(FILES include/xiz.h DESTINATION include)

# ---------------------------------------------------------------- tests and fuzzing

if(XIZ_TESTS)
  enable_testing()
  add_executable(xiz_unit tests/unit.c)
  target_link_libraries(xiz_unit PRIVATE xiz xiz_crypto)
  target_include_directories(xiz_unit PRIVATE src)
  target_compile_options(xiz_unit PRIVATE ${XIZ_WARNINGS} ${XIZ_SAN_FLAGS})
  if(NOT WIN32)
    target_compile_definitions(xiz_unit PRIVATE _POSIX_C_SOURCE=200809L _DARWIN_C_SOURCE _DEFAULT_SOURCE)
  endif()
  add_test(NAME unit COMMAND xiz_unit)
  find_program(SH_PROGRAM sh)
  if(SH_PROGRAM AND NOT WIN32)
    add_test(NAME fixtures COMMAND ${SH_PROGRAM} "${CMAKE_CURRENT_SOURCE_DIR}/tests/run_fixtures.sh"
             $<TARGET_FILE:xiz_cli> "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures")
  endif()
endif()

if(XIZ_FUZZ)
  foreach(f fuzz_open fuzz_catalog)
    add_executable(${f} fuzz/${f}.c)
    target_link_libraries(${f} PRIVATE xiz)
    target_include_directories(${f} PRIVATE src)
    target_compile_options(${f} PRIVATE -fsanitize=fuzzer,address,undefined -g)
    target_link_options(${f} PRIVATE -fsanitize=fuzzer,address,undefined)
  endforeach()
endif()

if(XIZ_TESTS AND NOT WIN32)
  add_executable(xiz_security tests/security.c)
  target_link_libraries(xiz_security PRIVATE xiz xiz_crypto)
  target_include_directories(xiz_security PRIVATE src)
  target_compile_options(xiz_security PRIVATE ${XIZ_WARNINGS} ${XIZ_SAN_FLAGS})
  target_compile_definitions(xiz_security PRIVATE _POSIX_C_SOURCE=200809L _DARWIN_C_SOURCE _DEFAULT_SOURCE)
  add_test(NAME security COMMAND xiz_security "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures"
           "${CMAKE_CURRENT_BINARY_DIR}/scratch")
  add_executable(xiz_manifest tests/manifest.c)
  target_link_libraries(xiz_manifest PRIVATE xiz xiz_crypto)
  target_include_directories(xiz_manifest PRIVATE src)
endif()
