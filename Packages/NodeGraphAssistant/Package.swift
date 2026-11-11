// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "NodeGraphAssistant",
    platforms: [.macOS(.v27), .iOS(.v27)],
    products: [.library(name: "NodeGraphAssistant", targets: ["NodeGraphAssistant"])],
    dependencies: [
        .package(path: "../NodeGraphCore"),
    ],
    targets: [
        .target(
            name: "NodeGraphAssistant",
            dependencies: [.product(name: "NodeGraphCore", package: "NodeGraphCore")]
        ),
        .testTarget(name: "NodeGraphAssistantTests", dependencies: ["NodeGraphAssistant"]),
    ]
)
