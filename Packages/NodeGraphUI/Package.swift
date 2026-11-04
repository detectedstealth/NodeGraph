// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "NodeGraphUI",
    platforms: [.macOS(.v27), .iOS(.v27)],
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
