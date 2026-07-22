// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CombCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CombCore", targets: ["CombCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.23.2"),
    ],
    targets: [
        .target(
            name: "CombCore",
            dependencies: [
                .product(name: "P256K", package: "swift-secp256k1"),
            ]
        ),
        .testTarget(
            name: "CombCoreTests",
            dependencies: ["CombCore"],
            // The official NIP-44 vector suite, slimmed. Interop with every
            // other Nostr client rests on these.
            resources: [.process("Fixtures-nip44-vectors.json")]
        ),
    ]
)
