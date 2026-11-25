// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sync",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Sync", targets: ["Sync"]),
    ],
    dependencies: [
        .package(path: "../Core"),
    ],
    targets: [
        .target(name: "Sync", dependencies: ["Core"]),
        .testTarget(name: "SyncTests", dependencies: ["Sync"]),
    ]
)
