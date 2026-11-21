// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "HermesStudio",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "StudioCore"),
        .executableTarget(name: "HermesStudio", dependencies: ["StudioCore"],
            exclude: ["Resources/desk-at-dusk.jpg"],
            resources: [.copy("Resources/app-logo.png"), .copy("Resources/Avatars")]),
        .testTarget(name: "StudioCoreTests", dependencies: ["StudioCore"]),
        .testTarget(name: "HermesStudioTests", dependencies: ["HermesStudio"])
    ]
)
