// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NodeGraphCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "NodeGraphCore", targets: ["NodeGraphCore"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "NodeGraphCore",
            dependencies: [
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(name: "NodeGraphCoreTests", dependencies: ["NodeGraphCore"]),
    ]
)
