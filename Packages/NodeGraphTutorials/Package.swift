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
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0"),
    ],
    targets: [
        .target(
            name: "NodeGraphTutorials",
            dependencies: [
                .product(name: "NodeGraphCore", package: "NodeGraphCore"),
                .product(name: "NodeGraphNodes", package: "NodeGraphNodes"),
            ]
        ),
        .testTarget(name: "NodeGraphTutorialsTests", dependencies: ["NodeGraphTutorials"]),
    ]
)
