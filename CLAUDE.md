# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

macOS Swift port of Rockchip's DDR_UserTool — a utility for testing DDR memory soldering quality on Rockchip SoCs (RK3588, RK3568, etc.) via USB.

## Build & Run

```bash
brew install libusb          # required dependency
swift build                  # debug build
swift build -c release       # release build

# Run GUI app (requires USB device plugged in for real testing)
swift run DDRUserToolMacApp

# Run CLI
swift run DDRUserToolCLI --list
swift run DDRUserToolCLI --cfg "/path/to/test.cfg"

# Build universal DMG
bash scripts/package.sh
```

## Tests

```bash
swift test                              # run all tests
swift test --filter CfgBinaryParserTests # run single test suite
swift test --filter CfgRepositoryTests   # test SoC discovery
```

Tests cover CfgBinaryParser, CfgRepository (SoC name extraction), TestExecutionEngine state transitions, and ResultLogWriter. No USB hardware required for unit tests.

## Architecture

**Swift Package Manager project** (swift-tools-version: 5.9, macOS 12+). Four targets:

- **DDRCore** — Shared library: config/INI parsing, binary `.cfg` parser, test execution engine, result log writer, models.
- **DDRUSB** — USB transport layer: `RkUsbTransportLibusb` implements `UsbTransport` protocol using libusb. Handles control transfers (boot download), bulk transfers (command/data), ACK validation, and printf polling.
- **DDRUserToolMacApp** — SwiftUI desktop app. `MainViewModel` orchestrates the workflow: load config → discover test files → discover USB devices → run test → save result.
- **DDRUserToolCLI** — Command-line interface with `--list`, `--probe-bulk`, `--reset-usb`, `--cfg` modes.

### Key Data Flow

1. `CfgRepository` discovers `.cfg` test files from `DDRTestFiles/` directory. Each SoC has its own subdirectory (e.g., `DDRTestFiles/RK3588/4GB LPDDR4.cfg`). The SoC name is extracted as `components[0]` from the relative path (SoC directory / filename).
2. `CfgBinaryParser` parses binary `.cfg` files by extracting UTF-16LE ASCII tokens, identifying test items (Boot, forceinit, connect), and loading payloads from embedded binary data (RC4-encrypted, except Boot).
3. `TestExecutionEngine` (actor) drives the test: for each item — download boot via USB control transfer, settle delay, download item via bulk write/read, optionally download parameters, run item, poll printf output until completion markers appear.
4. `ResultLogWriter` renders the final pass/fail result.

### Resource Discovery

`CfgRepository.makeDefaultRootURL()` probes three locations in order:
1. **Bundled app**: `Bundle.main.resourceURL/DDRTestFiles` (inside `.app/Contents/Resources/`)
2. **CLI / development**: DDRTestFiles sibling to the executable
3. **Fallback**: `./DDRTestFiles` relative to CWD

The DMG build script (`scripts/package.sh`) copies `DDRTestFiles/` to `Contents/Resources/DDRTestFiles` in the app bundle.

### Failure Detection

The engine detects device-side failures from printf output:
- English: "FAIL" keyword, "Force init DDR fail"
- Chinese: "错误!" (error!) — matches "强制初始化 DDR 错误!", "DQS0 错误!", "Training 错误!", etc.
- Each stage (boot → forceinit → connect) must pass before the next begins.

### USB Protocol

`RkUsbTransportLibusb` implements Rockchip's proprietary USB protocol:
- Boot: vendor-specific control transfer (request=0x0C, index=0x0471), 4096-byte chunks with CRC-CCITT
- Bulk commands: 32-byte packets (opcode + address + length + token + padding)
- Token generation: LCG pseudo-random (seed 0x13572468)
- Parameter payloads are hardcoded for known SoCs (RK3588: 38 params, RK3568: 18 params)

## CI/CD

GitHub Actions builds a universal (arm64 + x86_64) DMG on:
- Push of `v*` tags (auto-creates GitHub Release)
- Manual workflow dispatch
