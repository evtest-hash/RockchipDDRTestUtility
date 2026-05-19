# Rockchip DDR Test Utility for macOS

A macOS native tool for testing DDR memory soldering quality on Rockchip SoCs via USB.

## Supported SoCs

| SoC | USB PID |
|-----|---------|
| RK3588 | 0x350B |
| RK3576 | 0x350E |
| RK3568 / RK3566 | 0x350A |
| RK3562 | 0x350C |
| RK3506 | 0x350F |
| RK3399 | 0x330C |
| RK3368 | 0x330A |
| RK3288 | 0x320A |
| RK3326 / PX30 | 0x330D |
| RK3328 | 0x320C |
| RK322X | 0x320B |
| RK3128 | 0x310C |
| RK3036 | 0x301A |
| RV1126 | 0x110C |

## Requirements

- macOS 12.0 (Monterey) or later
- Apple Silicon (arm64) or Intel (x86_64)
- Rockchip device connected in USB download mode (VID 0x2207)

## Download

Download the latest `DDRUserToolMac.dmg` from [Releases](../../releases).

1. Open the DMG
2. Drag **DDRUserToolMac.app** to **Applications**
3. Launch the app — test configuration files are bundled inside the app

## Build from Source

```bash
brew install libusb
swift build -c release
```

### Run GUI (development)

```bash
swift run DDRUserToolMacApp
```

### Run CLI

```bash
swift run DDRUserToolCLI --list
swift run DDRUserToolCLI --cfg "/path/to/test.cfg"
```

### Build Universal DMG

```bash
bash scripts/package.sh
```

### Run Tests

```bash
swift test
```

## Test File Structure

The app bundles test configuration files in `DDRTestFiles/` with one subdirectory per SoC:

```
DDRTestFiles/
  RK3588/
    4GB LPDDR4.cfg
    8GB LPDDR4X.cfg
  RK3568&RK3566/
    2GB DDR4.cfg
  ...
```

At runtime, `CfgRepository` discovers files from:
1. App bundle: `Contents/Resources/DDRTestFiles/` (DMG install)
2. Executable directory: `DDRTestFiles/` next to the binary (CLI / development)
3. Current working directory: `./DDRTestFiles/` (fallback)

## Usage

1. Connect a Rockchip device via USB (device must be in download mode)
2. The app auto-detects the SoC and selects the correct test configuration
3. Click **开始测试** (Start Test) or enable **自动测试** (Auto Test) for automatic testing on device insertion
4. View results in the log area
5. Click **保存测试结果** (Save Result) to export a test report

## Architecture

| Module | Description |
|--------|-------------|
| `DDRCore` | Config parsing, binary `.cfg` parser, test execution engine, result writer |
| `DDRUSB` | USB transport via libusb (Rockchip protocol) |
| `DDRUserToolMacApp` | SwiftUI GUI application |
| `DDRUserToolCLI` | Command-line interface |

### Test Flow

```
Boot → forceinit → connect
  ↓        ↓          ↓
Download Download  Download
  ↓        ↓          ↓
  Run      Run        Run
  ↓        ↓          ↓
Printf   Printf     Printf → PASS/FAIL
```

Each stage must pass before the next begins. Failure at any stage stops the test.
