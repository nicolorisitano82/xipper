// swift-tools-version: 6.0
import PackageDescription

// Spike only: links the static libdeflate built by spike/build (see spike/README.md).
let vendor = "/Users/nicolo/Work/zipper/spike"

let package = Package(
    name: "xipzip",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "CCodecs",
            cSettings: [.unsafeFlags(["-I\(vendor)/Vendor/libdeflate", "-O3", "-mcpu=apple-m1"])],
            linkerSettings: [
                .unsafeFlags(["-L\(vendor)/build/libdeflate"]),
                .linkedLibrary("deflate"),
                .linkedLibrary("z"),
            ]
        ),
        .executableTarget(
            name: "xipzip",
            dependencies: ["CCodecs"],
            swiftSettings: [.unsafeFlags(["-Ounchecked"])]
        ),
    ],
    swiftLanguageModes: [.v5]
)
