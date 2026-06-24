# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Rockchip DDR Test Utility** — a macOS native tool for testing DDR memory soldering quality on Rockchip SoCs (RK3588, RK3568, etc.) via USB. Ported from Rockchip's original DDR_UserTool.

## Build & Run

```bash
brew install libusb          # required dependency
swift build                  # debug build
swift build -c release       # release build

# Run GUI app (requires USB device plugged in for real testing)
swift run RockchipDDRTestUtility

# Run CLI
swift run RockchipDDRTestUtilityCLI --list
swift run RockchipDDRTestUtilityCLI --cfg "/path/to/test.cfg"

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
- **RockchipDDRTestUtility** — SwiftUI desktop app. `MainViewModel` orchestrates the workflow: load config → discover test files → discover USB devices → run test → save result.
- **RockchipDDRTestUtilityCLI** — Command-line interface with `--list`, `--probe-bulk`, `--reset-usb`, `--cfg` modes.

### Key Data Flow

1. `CfgRepository` discovers `.cfg` test files from `DDRTestFiles/` directory. Each SoC has its own subdirectory (e.g., `DDRTestFiles/RK3588/4GB LPDDR4.cfg`). The SoC name is extracted as `components[0]` from the relative path (SoC directory / filename).
2. `CfgBinaryParser` parses binary `.cfg` files by extracting UTF-16LE ASCII tokens, identifying test items (Boot, forceinit, connect), and loading payloads from embedded binary data (RC4-encrypted, except Boot).
3. `TestExecutionEngine` (actor) drives the test: for each item — download boot via USB control transfer, settle delay, download item via bulk write/read, optionally download parameters, run item, then poll `RKU_TestDeviceReady` until the device reports done. Pass/fail comes from the status/result words in the response (printf is drained only for live display, never the verdict).
4. `ResultLogWriter` renders the final pass/fail result.

### Resource Discovery

`CfgRepository.makeDefaultRootURL()` probes three locations in order:
1. **Bundled app**: `Bundle.main.resourceURL/DDRTestFiles` (inside `.app/Contents/Resources/`)
2. **CLI / development**: DDRTestFiles sibling to the executable
3. **Fallback**: `./DDRTestFiles` relative to CWD

The DMG build script (`scripts/package.sh`) copies `DDRTestFiles/` to `Contents/Resources/DDRTestFiles` in the app bundle.

### Failure Detection

Each test item's pass/fail is taken from the device's `RKU_TestDeviceReady`
(opcode 0) status response, mirroring DDR_UserTool `sub_406420`/`sub_416B70`:
the 16-byte response carries status in word1 (0=done, 1=error, 2=running) and
the test result code in word2. After `runItem` (RKU_RunMemory, opcode 3), the
engine polls `testDeviceReady()` every 200ms until `phase == .finished`, then
passes only when `resultCode == 0`. Device printf output is **display-only**
and never influences the verdict — Windows reads printf in a separate thread
for the same purpose. Each stage (boot → forceinit → connect) must pass before
the next begins.

### Repeat Testing

The tool mirrors Windows DDR_UserTool so "start test" can be clicked repeatedly
without re-plugging. Two mechanisms (both required, hardware-verified on RK3568):

1. **Boot-skip latch** — `MainViewModel.deviceNeedsBoot` (the `this+0x4B8`
   equivalent), set on any device-set change in `pollDevices`, cleared only after
   a real boot succeeds. Passed as `skipBoot` to `engine.run`; when true the
   engine emits the boot log codes but skips the control-transfer download.
   `ExecutionResult.bootSucceeded` reports whether a real boot ran.
2. **Persistent transport** — the USB handle must stay claimed across clicks.
   `UsbTransport.isOpen` + `engine.run(..., keepTransportOpen:)`: the engine
   opens only when `!isOpen` and closes only when `!keepTransportOpen`.
   `MainViewModel.activeTransport` (bound to the selected device) is held open
   via `keepTransportOpen: true` and torn down on device-set change. **Why:**
   re-opening re-issues `libusb_set_configuration(1)`, which the already-booted
   test firmware can't service → the first bulk OUT stalls
   (`LIBUSB_ERROR_TIMEOUT`). Windows holds its device handle open across every
   click (its 3-repeat capture has zero control transfers between clicks).
   The CLI `--repeat N` mode exercises this path (boot once, then skip-boot +
   reuse the handle for runs 2..N).

Re-booting an already-booted device fails (`expected 512 got -1`), so run 1 of a
fresh connection needs a real bootrom (physical replug after the prior session).

### USB Protocol

`RkUsbTransportLibusb` implements Rockchip's proprietary USB protocol:
- Boot: vendor-specific control transfer (request=0x0C, index=0x0471), 4096-byte chunks with CRC-CCITT. On SoCs NOT in CLOSE_RC4_LIST (config.ini: 350A|350B|350C|350D|350E|110F), the whole boot blob is RC4-encrypted before chunking (mirrors `sub_40A3C0` flag a4).
- Bulk commands: 32-byte packets (opcode + address + length + token + padding)
- Token generation: LCG pseudo-random (seed 0x13572468)
- Parameter payloads are hardcoded for known SoCs (RK3588: 38 params, RK3568: 18 params)

## CI/CD

GitHub Actions builds a universal (arm64 + x86_64) DMG on:
- Push of `v*` tags (auto-creates GitHub Release)
- Manual workflow dispatch
