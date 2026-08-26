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
        // Embeds the entire DDRTestFiles/ cfg library (LZMA-compressed, ~2MB) via
        // .incbin so the CLI can ship as ONE self-contained file. Regenerate the
        // blob with `bash scripts/embed_cfgs.sh`.
        .target(
            name: "CDDRBlob"
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
                "CDDRBlob",
            ],
            path: "Sources/RockchipDDRTestUtilityCLI"
        ),
        .testTarget(
            name: "DDRCoreTests",
            dependencies: ["DDRCore", "DDRUSB"]
        ),
        // The CLI's machine contract (exit codes, errorCode enum, argv parsing,
        // JSON shape) is what automation depends on, and it had no tests at all.
        // Depending on the executable target directly avoids splitting a library
        // out of it just to make it reachable.
        // The GUI's step pipeline: which card an engine log entry lands on, and
        // what happens when one goes missing. Reachable the same way the CLI's
        // contract tests are — by depending on the app target directly.
        .testTarget(
            name: "GUITests",
            dependencies: ["RockchipDDRTestUtility", "DDRCore", "DDRUSB"]
        ),
        .testTarget(
            name: "CLIContractTests",
            dependencies: ["RockchipDDRTestUtilityCLI", "DDRCore", "DDRUSB"]
        ),
    ]
)
