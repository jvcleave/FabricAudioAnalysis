// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FabricAudioSourceProcessorVerification",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../Fabric")],
    targets: [
        .executableTarget(
            name: "VerifyPluginDiscovery",
            dependencies: [.product(name: "Fabric", package: "Fabric")]
        ),
    ]
)
