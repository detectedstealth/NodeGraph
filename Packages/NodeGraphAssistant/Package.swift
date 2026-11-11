// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "NodeGraphAssistant",
    platforms: [.macOS(.v27), .iOS(.v27)],
    products: [.library(name: "NodeGraphAssistant", targets: ["NodeGraphAssistant"])],
    dependencies: [
        .package(path: "../NodeGraphCore"),
        .package(path: "../NodeGraphNodes"),  // tests only: the example graphs use every pack
        .package(path: "../NodeGraphRobotics"),
        .package(path: "../NodeGraphVideo"),
    ],
    targets: [
        .target(
            name: "NodeGraphAssistant",
            dependencies: [.product(name: "NodeGraphCore", package: "NodeGraphCore")]
        ),
        .testTarget(name: "NodeGraphAssistantTests", dependencies: [
            "NodeGraphAssistant",
            .product(name: "NodeGraphNodes", package: "NodeGraphNodes"),
            .product(name: "NodeGraphRobotics", package: "NodeGraphRobotics"),
            .product(name: "NodeGraphVideo", package: "NodeGraphVideo"),
        ]),
    ]
)
