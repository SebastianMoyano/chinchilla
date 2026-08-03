// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "cleanmacseba",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Chinchilla",
            dependencies: ["CleanCore", "DiskScanKit", "SystemKit"]
        ),
        .target(name: "CleanCore", dependencies: ["SystemKit", "DiskScanKit"]),
        .target(name: "DiskScanKit"),
        .target(name: "SystemKit"),
        .testTarget(name: "CleanCoreTests", dependencies: ["CleanCore"]),
        .testTarget(name: "DiskScanKitTests", dependencies: ["DiskScanKit"]),
        .testTarget(name: "SystemKitTests", dependencies: ["SystemKit"]),
    ]
)
