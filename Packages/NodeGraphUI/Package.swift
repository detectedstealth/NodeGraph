// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NodeGraphUI",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "NodeGraphUI", targets: ["NodeGraphUI"])],
    dependencies: [
        .package(path: "../NodeGraphCore"),
    ],
    targets: [
        .target(
            name: "NodeGraphUI",
            dependencies: [.product(name: "NodeGraphCore", package: "NodeGraphCore")]
        ),
        .testTarget(name: "NodeGraphUITests", dependencies: ["NodeGraphUI"]),
    ]
)
