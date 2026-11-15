// swift-tools-version: 6.4
import PackageDescription

// Docs-only package: the tutorials for every NodeGraph package live here so they can link across
// packages without Core depending on UI. Each tutorial step is real code in `TutorialSnippets`
// (compiled and tested); see docs/TUTORIALS.md.
let package = Package(
    name: "NodeGraphTutorials",
    platforms: [.macOS(.v27), .iOS(.v27)],
    products: [.library(name: "NodeGraphTutorials", targets: ["NodeGraphTutorials"])],
    dependencies: [
        .package(path: "../NodeGraphCore"),
        .package(path: "../NodeGraphNodes"),
        .package(path: "../NodeGraphSync"),
        .package(path: "../NodeGraphUI"),
        .package(path: "../NodeGraphRobotics"),
        .package(path: "../NodeGraphVideo"),
        .package(path: "../NodeGraphAssistant"),
        .package(path: "../NodeGraphCLI"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0"),
    ],
    targets: [
        .target(
            name: "NodeGraphTutorials",
            dependencies: [
                .product(name: "NodeGraphCore", package: "NodeGraphCore"),
                .product(name: "NodeGraphNodes", package: "NodeGraphNodes"),
                .product(name: "NodeGraphSync", package: "NodeGraphSync"),
                .product(name: "NodeGraphUI", package: "NodeGraphUI"),
                .product(name: "NodeGraphRobotics", package: "NodeGraphRobotics"),
                .product(name: "NodeGraphVideo", package: "NodeGraphVideo"),
                .product(name: "NodeGraphAssistant", package: "NodeGraphAssistant"),
                .product(name: "NodeGraphRunKit", package: "NodeGraphCLI"),
            ]
        ),
        .testTarget(name: "NodeGraphTutorialsTests", dependencies: ["NodeGraphTutorials"]),
    ]
)
