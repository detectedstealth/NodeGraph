// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "NodeGraphUI",
    platforms: [.macOS(.v27), .iOS(.v27)],
    products: [.library(name: "NodeGraphUI", targets: ["NodeGraphUI"])],
    dependencies: [
        .package(path: "../NodeGraphCore"),
        .package(url: "https://github.com/apple/swift-log", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "NodeGraphUI",
            dependencies: [
                .product(name: "NodeGraphCore", package: "NodeGraphCore"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(name: "NodeGraphUITests", dependencies: ["NodeGraphUI"]),
    ]
)
