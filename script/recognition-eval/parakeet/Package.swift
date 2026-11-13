// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ParakeetRunner",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.0", traits: []),
    ],
    targets: [
        .executableTarget(
            name: "ParakeetRunner",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
    ]
)
