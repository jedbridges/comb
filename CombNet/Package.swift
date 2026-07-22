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
        .testTarget(
            name: "CombNetTests",
            dependencies: ["CombNet", "CombCore"],
            // A real relay's NIP-11 document, captured verbatim, so the parser
            // is tested against what the service sends rather than what the
            // source suggested it would.
            resources: [.process("Fixtures-buzz-relay-nip11.json")]
        ),
    ]
)
