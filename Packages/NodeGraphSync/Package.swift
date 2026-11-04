// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NodeGraphSync",
    platforms: [.macOS(.v14), .iOS(.v17)],
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
