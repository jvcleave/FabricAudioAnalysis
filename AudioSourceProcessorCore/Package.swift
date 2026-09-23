// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioSourceProcessorCore",
    platforms: [.macOS("15.0")],
    products: [
        .library(
            name: "AudioSourceProcessorCore",
            targets: ["AudioSourceProcessorCore"]
        ),
    ],
    targets: [
        .target(name: "AudioSourceProcessorCore"),
        .testTarget(
            name: "AudioSourceProcessorCoreTests",
            dependencies: ["AudioSourceProcessorCore"]
        ),
    ]
)
