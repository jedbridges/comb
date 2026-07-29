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
        // A scripted relay, shipped rather than kept inside the test target.
        // The app's own session is the layer nothing could test, and this is
        // what a test of it has to be handed. Its `@testable import` was never
        // load-bearing: everything it touches is public API.
        .library(name: "CombNetTesting", targets: ["CombNetTesting"]),
    ],
    dependencies: [
        .package(path: "../CombCore"),
    ],
    targets: [
        .target(name: "CombNet", dependencies: ["CombCore"]),
        .target(name: "CombNetTesting", dependencies: ["CombNet", "CombCore"]),
        .testTarget(
            name: "CombNetTests",
            dependencies: ["CombNet", "CombNetTesting", "CombCore"],
            // A real relay's NIP-11 document, captured verbatim, so the parser
            // is tested against what the service sends rather than what the
            // source suggested it would.
            resources: [.process("Fixtures-buzz-relay-nip11.json")]
        ),
    ]
)
