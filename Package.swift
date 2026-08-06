// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "cleanmacseba",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Chinchilla",
            dependencies: ["CleanCore", "DiskScanKit", "SystemKit", "CastKit", "StreamHostKit"]
        ),
        .target(name: "CleanCore", dependencies: ["SystemKit", "DiskScanKit"]),
        .target(name: "DiskScanKit"),
        .target(name: "SystemKit", dependencies: ["DiskScanKit"]),
        .target(name: "VirtualDisplayKit"),
        .target(name: "CastKit", dependencies: ["DiskScanKit", "VirtualDisplayKit"]),
        .target(name: "StreamHostKit", dependencies: ["DiskScanKit"]),
        .testTarget(name: "CleanCoreTests", dependencies: ["CleanCore"]),
        .testTarget(name: "DiskScanKitTests", dependencies: ["DiskScanKit"]),
        .testTarget(name: "SystemKitTests", dependencies: ["SystemKit"]),
        .testTarget(name: "CastKitTests", dependencies: ["CastKit", "DiskScanKit"]),
        .testTarget(name: "StreamHostKitTests", dependencies: ["StreamHostKit", "DiskScanKit"]),
    ]
)
