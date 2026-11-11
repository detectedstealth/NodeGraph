// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "NodeGraphAI",
    platforms: [.macOS(.v27), .iOS(.v27)],
    products: [.library(name: "NodeGraphAI", targets: ["NodeGraphAI"])],
    dependencies: [
        .package(path: "../NodeGraphCore"),
        .package(path: "../NodeGraphAssistant"),
        .package(path: "../NodeGraphNodes"),  // tests only
    ],
    targets: [
        .target(
            name: "NodeGraphAI",
            dependencies: [
                .product(name: "NodeGraphCore", package: "NodeGraphCore"),
                .product(name: "NodeGraphAssistant", package: "NodeGraphAssistant"),
            ]
        ),
        .testTarget(name: "NodeGraphAITests", dependencies: [
            "NodeGraphAI",
            .product(name: "NodeGraphNodes", package: "NodeGraphNodes"),
        ]),
    ]
)
