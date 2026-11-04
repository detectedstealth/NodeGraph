// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "NodeGraphSync",
    platforms: [.macOS(.v27), .iOS(.v27)],
    products: [.library(name: "NodeGraphSync", targets: ["NodeGraphSync"])],
    dependencies: [
        .package(path: "../NodeGraphCore"),
    ],
    targets: [
        .target(
            name: "NodeGraphSync",
            dependencies: [.product(name: "NodeGraphCore", package: "NodeGraphCore")]
        ),
        .testTarget(name: "NodeGraphSyncTests", dependencies: ["NodeGraphSync"]),
    ]
)
