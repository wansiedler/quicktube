// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuickTube",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "QuickTubeCore", targets: ["QuickTubeCore"])
    ],
    targets: [
        .target(name: "QuickTubeCore"),
        .testTarget(name: "QuickTubeCoreTests", dependencies: ["QuickTubeCore"]),
    ]
)
