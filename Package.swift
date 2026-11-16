// swift-tools-version: 6.4
import PackageDescription

// One package, many libraries: depend on the repository by URL and pick the products you need.
//
//     .package(url: "https://github.com/<owner>/NodeGraph", from: "0.1.0")
//     .product(name: "NodeGraphCore", package: "NodeGraph")
//
// The sources stay in `Packages/<Name>/` so each module keeps its own folder. Dependencies between
// modules are target dependencies, which keeps the one-way rule in CLAUDE.md: UI, Nodes and Sync
// depend on Core only; Core depends on no other module.

/// A module's sources and tests live in `Packages/<name>/Sources/<name>` and `.../Tests/<name>Tests`.
func module(_ name: String, folder: String? = nil, _ dependencies: [Target.Dependency] = []) -> Target {
    .target(name: name, dependencies: dependencies, path: "Packages/\(folder ?? name)/Sources/\(name)")
}

func tests(_ name: String, _ dependencies: [Target.Dependency] = []) -> Target {
    .testTarget(
        name: "\(name)Tests",
        dependencies: [.target(name: name)] + dependencies,
        path: "Packages/\(name)/Tests/\(name)Tests"
    )
}

// Modules that run anywhere Swift does (macOS, iOS, Linux).
var products: [Product] = [
    .library(name: "NodeGraphCore", targets: ["NodeGraphCore"]),
    .library(name: "NodeGraphNodes", targets: ["NodeGraphNodes"]),
    .library(name: "NodeGraphSync", targets: ["NodeGraphSync"]),
    .library(name: "NodeGraphRobotics", targets: ["NodeGraphRobotics"]),
    .library(name: "NodeGraphVideo", targets: ["NodeGraphVideo"]),
    .library(name: "NodeGraphAssistant", targets: ["NodeGraphAssistant"]),
    // What ng-run does, as a library, so an app or a test can run a document headless too.
    .library(name: "NodeGraphRunKit", targets: ["NodeGraphRunKit"]),
    .executable(name: "ng-run", targets: ["ng-run"]),
]

var targets: [Target] = [
    module("NodeGraphCore", [
        .product(name: "Collections", package: "swift-collections"),
        .product(name: "Logging", package: "swift-log"),
    ]),
    tests("NodeGraphCore"),

    module("NodeGraphNodes", ["NodeGraphCore"]),
    tests("NodeGraphNodes"),

    module("NodeGraphSync", ["NodeGraphCore"]),
    tests("NodeGraphSync"),

    module("NodeGraphVideo", ["NodeGraphCore", "NodeGraphNodes"]),
    tests("NodeGraphVideo"),

    module("NodeGraphRobotics", ["NodeGraphCore", "NodeGraphNodes"]),
    // The showcase graph uses every pack.
    tests("NodeGraphRobotics", ["NodeGraphVideo"]),

    module("NodeGraphAssistant", ["NodeGraphCore"]),
    // The example graphs use every pack.
    tests("NodeGraphAssistant", ["NodeGraphNodes", "NodeGraphRobotics", "NodeGraphVideo"]),

    // The logic of `ng-run`, apart from argument parsing so tests can call it.
    module("NodeGraphRunKit", folder: "NodeGraphCLI", ["NodeGraphCore", "NodeGraphNodes", "NodeGraphRobotics", "NodeGraphVideo"]),
    .testTarget(
        name: "NodeGraphRunKitTests",
        dependencies: ["NodeGraphRunKit"],
        path: "Packages/NodeGraphCLI/Tests/NodeGraphRunKitTests"
    ),
    .executableTarget(
        name: "ng-run",
        dependencies: [
            "NodeGraphRunKit",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ],
        path: "Packages/NodeGraphCLI/Sources/ng-run"
    ),
]

// Modules that need Apple frameworks (SwiftUI, FoundationModels, Security). They are left out on
// Linux so `swift build` and `swift test` work there.
#if !os(Linux)
products += [
    .library(name: "NodeGraphUI", targets: ["NodeGraphUI"]),
    .library(name: "NodeGraphAI", targets: ["NodeGraphAI"]),
]
targets += [
    module("NodeGraphUI", ["NodeGraphCore", .product(name: "Logging", package: "swift-log")]),
    tests("NodeGraphUI"),

    module("NodeGraphAI", ["NodeGraphCore", "NodeGraphAssistant"]),
    tests("NodeGraphAI", ["NodeGraphNodes"]),

    // Docs only, no product: the tutorials link across modules (see docs/TUTORIALS.md). Each
    // step is real code in the target, compiled and tested.
    module("NodeGraphTutorials", [
        "NodeGraphCore", "NodeGraphNodes", "NodeGraphSync", "NodeGraphUI",
        "NodeGraphRobotics", "NodeGraphVideo", "NodeGraphAssistant", "NodeGraphRunKit",
    ]),
    tests("NodeGraphTutorials"),
]
#endif

let package = Package(
    name: "NodeGraph",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0"),
    ],
    targets: targets
)
