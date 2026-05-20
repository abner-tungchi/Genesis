// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Genesis",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "genesis", targets: ["Genesis"]),
        .library(name: "GenesisCore", targets: ["GenesisCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "Genesis",
            dependencies: [
                "GenesisCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "GenesisCore",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
            ],
            resources: [
                .copy("Resources/Templates"),
            ]
        ),
        .testTarget(
            name: "GenesisCoreTests",
            dependencies: ["GenesisCore"]
        ),
        .testTarget(
            name: "GenesisIntegrationTests",
            dependencies: ["GenesisCore"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
