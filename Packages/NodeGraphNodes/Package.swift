// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "NodeGraphNodes",
    platforms: [.macOS(.v27), .iOS(.v27)],
    products: [.library(name: "NodeGraphNodes", targets: ["NodeGraphNodes"])],
    dependencies: [
        .package(path: "../NodeGraphCore"),
    ],
    targets: [
        .target(
            name: "NodeGraphNodes",
            dependencies: [.product(name: "NodeGraphCore", package: "NodeGraphCore")]
        ),
        .testTarget(name: "NodeGraphNodesTests", dependencies: ["NodeGraphNodes"]),
    ]
)
