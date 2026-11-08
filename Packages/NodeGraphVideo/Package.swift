// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "NodeGraphVideo",
    platforms: [.macOS(.v27), .iOS(.v27)],
    products: [.library(name: "NodeGraphVideo", targets: ["NodeGraphVideo"])],
    dependencies: [
        .package(path: "../NodeGraphCore"),
        .package(path: "../NodeGraphNodes"),
    ],
    targets: [
        .target(
            name: "NodeGraphVideo",
            dependencies: [
                .product(name: "NodeGraphCore", package: "NodeGraphCore"),
                .product(name: "NodeGraphNodes", package: "NodeGraphNodes"),
            ]
        ),
        .testTarget(name: "NodeGraphVideoTests", dependencies: ["NodeGraphVideo"]),
    ]
)
