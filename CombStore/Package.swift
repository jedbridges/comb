// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CombStore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CombStore", targets: ["CombStore"]),
    ],
    dependencies: [
        .package(path: "../CombCore"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "CombStore",
            dependencies: [
                "CombCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "CombStoreTests",
            dependencies: ["CombStore", "CombCore"]
        ),
    ]
)
