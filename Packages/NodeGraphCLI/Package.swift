// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "NodeGraphCLI",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "ng-run", targets: ["ng-run"]),
        // What ng-run does, as a library, so an app or a test can run a document headless too.
        .library(name: "NodeGraphRunKit", targets: ["NodeGraphRunKit"]),
    ],
    dependencies: [
        .package(path: "../NodeGraphCore"),
        .package(path: "../NodeGraphNodes"),
        .package(path: "../NodeGraphRobotics"),
        .package(path: "../NodeGraphVideo"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // The logic of `ng-run`, apart from argument parsing so tests can call it.
        .target(
            name: "NodeGraphRunKit",
            dependencies: [
                .product(name: "NodeGraphCore", package: "NodeGraphCore"),
                .product(name: "NodeGraphNodes", package: "NodeGraphNodes"),
                .product(name: "NodeGraphRobotics", package: "NodeGraphRobotics"),
                .product(name: "NodeGraphVideo", package: "NodeGraphVideo"),
            ]
        ),
        .executableTarget(
            name: "ng-run",
            dependencies: [
                "NodeGraphRunKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "NodeGraphRunKitTests", dependencies: ["NodeGraphRunKit"]),
    ]
)
