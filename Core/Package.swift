// swift-tools-version: 6.0
import PackageDescription

// ScoutCore holds everything that can be reasoned about without a window: what a scope
// means, which paths are noise, how a result is scored. Keeping it a package rather than
// app source is what lets the ranking be tested — and the ranking is the whole product.
let package = Package(
    name: "ScoutCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ScoutCore", targets: ["ScoutCore"])
    ],
    targets: [
        .target(name: "ScoutCore"),
        .testTarget(name: "ScoutCoreTests", dependencies: ["ScoutCore"]),
    ]
)
