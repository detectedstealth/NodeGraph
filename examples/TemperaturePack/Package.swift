// swift-tools-version: 6.3
import PackageDescription

// A node pack in its own package. It needs only NodeGraphCore. Here the dependency is the local
// NodeGraph checkout (its folder must be called NodeGraph); in your own package, depend on the
// repository by URL: .package(url: "https://github.com/<owner>/NodeGraph", from: "0.1.0").
let package = Package(
    name: "TemperaturePack",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.library(name: "TemperaturePack", targets: ["TemperaturePack"])],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .target(
            name: "TemperaturePack",
            dependencies: [.product(name: "NodeGraphCore", package: "NodeGraph")]
        ),
        .testTarget(name: "TemperaturePackTests", dependencies: ["TemperaturePack"]),
    ]
)
