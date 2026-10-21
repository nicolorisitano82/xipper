// swift-tools-version: 6.2
import PackageDescription

// Spike (docs/FSKIT.md, option C): a read-only WebDAV server on 127.0.0.1 that serves the content
// of an archive through XipperKit, mounted with macOS's own mount_webdav. No entitlements needed.
let package = Package(
    name: "xipdav",
    platforms: [.macOS(.v26)],
    dependencies: [.package(name: "Xipper", path: "../..")],
    targets: [
        .executableTarget(name: "xipdav", dependencies: [.product(name: "XipperKit", package: "Xipper")]),
    ],
    swiftLanguageModes: [.v5]
)
