// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "cleanmacseba",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Chinchilla",
            dependencies: ["CleanCore", "DiskScanKit", "SystemKit", "CastKit", "StreamHostKit"]
        ),
        .target(name: "CleanCore", dependencies: ["SystemKit", "DiskScanKit"]),
        .target(name: "DiskScanKit"),
        .target(name: "SystemKit"),
        .target(name: "CastKit", dependencies: ["DiskScanKit"]),
        .target(name: "StreamHostKit"),
        .testTarget(name: "CleanCoreTests", dependencies: ["CleanCore"]),
        .testTarget(name: "DiskScanKitTests", dependencies: ["DiskScanKit"]),
        .testTarget(name: "SystemKitTests", dependencies: ["SystemKit"]),
        .testTarget(name: "CastKitTests", dependencies: ["CastKit"]),
        .testTarget(name: "StreamHostKitTests", dependencies: ["StreamHostKit"]),
    ]
)
