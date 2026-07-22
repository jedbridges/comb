// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CombNet",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CombNet", targets: ["CombNet"]),
    ],
    dependencies: [
        .package(path: "../CombCore"),
    ],
    targets: [
        .target(name: "CombNet", dependencies: ["CombCore"]),
        .testTarget(name: "CombNetTests", dependencies: ["CombNet", "CombCore"]),
    ]
)
