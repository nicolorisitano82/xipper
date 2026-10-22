// swift-tools-version: 6.2
import PackageDescription

// Defines that the xz CMake build uses on macOS arm64 (see Vendor/README.md).
let lzmaDefines: [CSetting] = [
    "HAVE_ARM64_CRC32", "HAVE_CHECK_CRC32", "HAVE_CHECK_CRC64", "HAVE_CHECK_SHA256",
    "HAVE_CLOCK_GETTIME", "HAVE_CLOCK_MONOTONIC",
    "HAVE_DECODERS", "HAVE_DECODER_ARM", "HAVE_DECODER_ARM64", "HAVE_DECODER_ARMTHUMB",
    "HAVE_DECODER_DELTA", "HAVE_DECODER_IA64", "HAVE_DECODER_LZMA1", "HAVE_DECODER_LZMA2",
    "HAVE_DECODER_POWERPC", "HAVE_DECODER_RISCV", "HAVE_DECODER_SPARC", "HAVE_DECODER_X86",
    "HAVE_ENCODERS", "HAVE_ENCODER_ARM", "HAVE_ENCODER_ARM64", "HAVE_ENCODER_ARMTHUMB",
    "HAVE_ENCODER_DELTA", "HAVE_ENCODER_IA64", "HAVE_ENCODER_LZMA1", "HAVE_ENCODER_LZMA2",
    "HAVE_ENCODER_POWERPC", "HAVE_ENCODER_RISCV", "HAVE_ENCODER_SPARC", "HAVE_ENCODER_X86",
    "HAVE_FUNC_ATTRIBUTE_CONSTRUCTOR", "HAVE_INTTYPES_H", "HAVE_LZIP_DECODER",
    "HAVE_MF_BT2", "HAVE_MF_BT3", "HAVE_MF_BT4", "HAVE_MF_HC3", "HAVE_MF_HC4",
    "HAVE_PARAM_H", "HAVE_STDBOOL_H", "HAVE_STDINT_H", "HAVE_SYSCTLBYNAME", "HAVE__BOOL",
    "HAVE___BUILTIN_ASSUME_ALIGNED", "HAVE___BUILTIN_BSWAPXX", "MYTHREAD_POSIX",
    "TUKLIB_CPUCORES_SYSCTL", "TUKLIB_FAST_UNALIGNED_ACCESS", "TUKLIB_PHYSMEM_SYSCONF",
    "_DARWIN_C_SOURCE",
].map { .define($0) } + [
    .define("HAVE_VISIBILITY", to: "0"),
    .define("TUKLIB_SYMBOL_PREFIX", to: "lzma_"),
    .define("PACKAGE_NAME", to: "\"XZ Utils\""),
    .define("PACKAGE_BUGREPORT", to: "\"xz@tukaani.org\""),
    .define("PACKAGE_URL", to: "\"https://tukaani.org/xz/\""),
    .define("NDEBUG", .when(configuration: .release)),
] + ["liblzma/api", "liblzma/common", "liblzma/check", "liblzma/lz", "liblzma/rangecoder",
     "liblzma/lzma", "liblzma/delta", "liblzma/simple", "common"].map { .headerSearchPath($0) }

let package = Package(
    name: "Xipper",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "XipperKit", targets: ["XipperKit"]),
        .library(name: "XipperMCP", targets: ["XipperMCP"]),
        .executable(name: "xipper", targets: ["xipper"]),
    ],
    targets: [
        // MARK: vendored codecs (permissive licenses, compiled in; see Vendor/README.md)
        .target(
            name: "CZstd",
            path: "Vendor/zstd",
            sources: ["common", "compress", "decompress", "dictBuilder"],
            cSettings: [
                .define("ZSTD_MULTITHREAD"),
                .define("ZSTD_DISABLE_ASM"),
                .define("XXH_NAMESPACE", to: "ZSTD_"),
                .define("NDEBUG", .when(configuration: .release)),
            ],
            linkerSettings: [.linkedLibrary("pthread")]
        ),
        .target(
            name: "CDeflate",
            path: "Vendor/libdeflate",
            sources: ["lib"],
            cSettings: [.define("NDEBUG", .when(configuration: .release))]
        ),
        .target(
            name: "CLZMA",
            path: "Vendor/xz/src",
            sources: ["liblzma", "common/tuklib_cpucores.c", "common/tuklib_physmem.c"],
            publicHeadersPath: "liblzma/api",
            cSettings: lzmaDefines
        ),
        // LZMA SDK (public domain): PPMd, and LZMA/LZMA2 decoding with 7-Zip's ARM64 assembly loop.
        .target(
            name: "CLzmaSDK",
            path: "Vendor/lzma-sdk",
            sources: ["C/Ppmd7.c", "C/Ppmd7Dec.c", "C/LzmaDec.c", "C/Lzma2Dec.c", "Asm/arm64/LzmaDecOpt.S",
                      "shim/xs_ppmd.c", "shim/xs_lzdec.c"],
            publicHeadersPath: "include",
            cSettings: [
                .define("Z7_LZMA_DEC_OPT"),
                .define("NDEBUG", .when(configuration: .release)),
            ]
        ),
        // Argon2id (password KDF of encrypted XIZ archives): P-H-C reference code, portable C, CC0/Apache-2.0.
        .target(
            name: "CArgon2",
            path: "Vendor/argon2",
            sources: ["src/argon2.c", "src/core.c", "src/encoding.c", "src/ref.c", "src/thread.c", "src/blake2/blake2b.c"],
            publicHeadersPath: "include",
            cSettings: [.define("NDEBUG", .when(configuration: .release))]
        ),
        // MARK: thin C helpers over system zlib / bzip2
        .target(
            name: "CXipShims",
            linkerSettings: [.linkedLibrary("z"), .linkedLibrary("bz2")]
        ),
        // MARK: Swift
        .target(
            name: "XipperKit",
            dependencies: ["CZstd", "CDeflate", "CLZMA", "CLzmaSDK", "CXipShims", "CArgon2"],
            linkerSettings: [.linkedFramework("NetFS")]  // mounting archives (Mount/)
        ),
        // MCP server (STUDIO.md §6-ter): JSON-RPC over stdio, Foundation only.
        .target(
            name: "XipperMCP",
            dependencies: ["XipperKit"]
        ),
        .executableTarget(
            name: "xipper",
            dependencies: ["XipperKit", "XipperMCP"]
        ),
        .testTarget(
            name: "XipperKitTests",
            dependencies: ["XipperKit", "XipperMCP", "CLZMA"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
