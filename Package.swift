// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "AlbumVisualiser",
    platforms: [.macOS("14.2")],
    targets: [
        .target(name: "VisualiserCore"),
        .executableTarget(
            name: "AlbumVisualiser",
            dependencies: ["VisualiserCore"],
            // Core Audio and Carbon callbacks are C function pointers; Swift 5 mode
            // keeps the AppKit glue free of strict-concurrency boilerplate.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VisualiserCoreTests",
            dependencies: ["VisualiserCore"]
        ),
    ]
)
