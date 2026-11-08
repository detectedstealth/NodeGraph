// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "NodeGraphCLI",
    platforms: [.macOS(.v27)],
    products: [.executable(name: "ng-run", targets: ["ng-run"])],
    dependencies: [
        .package(path: "../NodeGraphCore"),
        .package(path: "../NodeGraphNodes"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // The logic of `ng-run`, apart from argument parsing so tests can call it.
        .target(
            name: "NodeGraphRunKit",
            dependencies: [
                .product(name: "NodeGraphCore", package: "NodeGraphCore"),
                .product(name: "NodeGraphNodes", package: "NodeGraphNodes"),
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
