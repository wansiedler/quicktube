// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuickTube",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "QuickTubeCore", targets: ["QuickTubeCore"]),
        .executable(name: "QuickTube", targets: ["QuickTube"]),
    ],
    dependencies: [
        // Auto-updates for the app only; QuickTubeCore stays dependency-free.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0")
    ],
    targets: [
        .target(name: "QuickTubeCore"),
        .executableTarget(
            name: "QuickTube",
            dependencies: [
                "QuickTubeCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            exclude: ["Info.plist"],
            // `make app` puts Sparkle.framework in Contents/Frameworks.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]),
        .testTarget(name: "QuickTubeCoreTests", dependencies: ["QuickTubeCore"]),
    ]
)
