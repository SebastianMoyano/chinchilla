// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "cleanmacseba",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Chinchilla",
            dependencies: [
                "CleanCore", "DiskScanKit", "SystemKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                // The bundled app carries Sparkle.framework in Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .target(name: "CleanCore", dependencies: ["SystemKit", "DiskScanKit"]),
        .target(name: "DiskScanKit"),
        .target(name: "SystemKit"),
        .testTarget(name: "CleanCoreTests", dependencies: ["CleanCore"]),
        .testTarget(name: "DiskScanKitTests", dependencies: ["DiskScanKit"]),
    ]
)
