// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioAnalysisCore",
    platforms: [.macOS("15.0")],
    products: [
        .library(
            name: "AudioAnalysisCore",
            targets: ["AudioAnalysisCore"]
        ),
    ],
    targets: [
        .target(name: "AudioAnalysisCore"),
        .testTarget(
            name: "AudioAnalysisCoreTests",
            dependencies: ["AudioAnalysisCore"]
        ),
    ]
)
