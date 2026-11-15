// swift-tools-version: 6.4
import PackageDescription

// A node pack in its own package. It needs only NodeGraphCore. Here the dependency is a local
// path inside the NodeGraph repository; in your own package, depend on the repository by URL.
let package = Package(
    name: "TemperaturePack",
    platforms: [.macOS(.v27), .iOS(.v27)],
    products: [.library(name: "TemperaturePack", targets: ["TemperaturePack"])],
    dependencies: [
        .package(path: "../../Packages/NodeGraphCore"),
    ],
    targets: [
        .target(
            name: "TemperaturePack",
            dependencies: [.product(name: "NodeGraphCore", package: "NodeGraphCore")]
        ),
        .testTarget(name: "TemperaturePackTests", dependencies: ["TemperaturePack"]),
    ]
)
