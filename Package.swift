// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RockchipDDRTestUtility",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "DDRCore",
            targets: ["DDRCore"]
        ),
        .library(
            name: "DDRUSB",
            targets: ["DDRUSB"]
        ),
        .executable(
            name: "RockchipDDRTestUtility",
            targets: ["RockchipDDRTestUtility"]
        ),
        .executable(
            name: "RockchipDDRTestUtilityCLI",
            targets: ["RockchipDDRTestUtilityCLI"]
        ),
    ],
    targets: [
        .systemLibrary(
            name: "CLibusb",
            path: "Sources/CLibusb",
            pkgConfig: "libusb-1.0",
            providers: [
                .brew(["libusb"]),
            ]
        ),
        .target(
            name: "DDRCore"
        ),
        .target(
            name: "DDRUSB",
            dependencies: [
                "DDRCore",
                "CLibusb",
            ]
        ),
        .executableTarget(
            name: "RockchipDDRTestUtility",
            dependencies: [
                "DDRCore",
                "DDRUSB",
            ],
            path: "Sources/RockchipDDRTestUtility"
        ),
        .executableTarget(
            name: "RockchipDDRTestUtilityCLI",
            dependencies: [
                "DDRCore",
                "DDRUSB",
            ],
            path: "Sources/RockchipDDRTestUtilityCLI"
        ),
        .testTarget(
            name: "DDRCoreTests",
            dependencies: ["DDRCore"]
        ),
    ]
)
