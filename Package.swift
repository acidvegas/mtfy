// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mtfy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Mtfy", path: "Sources/Mtfy")
    ]
)
