// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DDRUserToolMac",
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
            name: "DDRUserToolMacApp",
            targets: ["DDRUserToolMacApp"]
        ),
        .executable(
            name: "DDRUserToolCLI",
            targets: ["DDRUserToolCLI"]
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
            name: "DDRUserToolMacApp",
            dependencies: [
                "DDRCore",
                "DDRUSB",
            ],
            path: "Sources/DDRUserToolMacApp"
        ),
        .executableTarget(
            name: "DDRUserToolCLI",
            dependencies: [
                "DDRCore",
                "DDRUSB",
            ],
            path: "Sources/DDRUserToolCLI"
        ),
        .testTarget(
            name: "DDRCoreTests",
            dependencies: ["DDRCore"]
        ),
    ]
)
