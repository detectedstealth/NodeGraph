// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "NodeGraphRobotics",
    platforms: [.macOS(.v27), .iOS(.v27)],
    products: [.library(name: "NodeGraphRobotics", targets: ["NodeGraphRobotics"])],
    dependencies: [
        .package(path: "../NodeGraphCore"),
        .package(path: "../NodeGraphNodes"),
        .package(path: "../NodeGraphVideo"),  // tests only: the showcase graph uses every pack
    ],
    targets: [
        .target(
            name: "NodeGraphRobotics",
            dependencies: [
                .product(name: "NodeGraphCore", package: "NodeGraphCore"),
                .product(name: "NodeGraphNodes", package: "NodeGraphNodes"),
            ]
        ),
        .testTarget(name: "NodeGraphRoboticsTests", dependencies: [
            "NodeGraphRobotics",
            .product(name: "NodeGraphVideo", package: "NodeGraphVideo"),
        ]),
    ]
)
