// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuickTube",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "QuickTubeCore", targets: ["QuickTubeCore"]),
        .executable(name: "QuickTube", targets: ["QuickTube"]),
    ],
    targets: [
        .target(name: "QuickTubeCore"),
        .executableTarget(
            name: "QuickTube",
            dependencies: ["QuickTubeCore"],
            exclude: ["Info.plist"]),
        .testTarget(name: "QuickTubeCoreTests", dependencies: ["QuickTubeCore"]),
    ]
)
