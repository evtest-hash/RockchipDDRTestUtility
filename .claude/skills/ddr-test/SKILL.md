---
name: ddr-test
description: >-
  Test a Rockchip board's DDR over USB (auto-detect config, soldering test, eye-scan)
  using the standalone RockchipDDRTestUtility CLI. Use when asked to test/detect/probe
  a plugged-in Rockchip board (RK3568/RK3566/RK3576/RK3588/RK3288) or to run the DDR
  soldering / eye-scan check. Fetches the CLI from the GitHub release — no build needed.
---

# Rockchip DDR test (CLI)

Drive the DDR test tool over pure USB and report a machine-readable verdict. The CLI
is a self-contained macOS binary: the whole cfg library is embedded, so it needs no
`DDRTestFiles/` directory, and `libusb` ships beside it — nothing to `brew install`.

## 1. Get the CLI

The release ships `RockchipDDRTestUtilityCLI-macos.tar.gz` (universal arm64+x86_64,
macOS 12+) containing `RockchipDDRTestUtilityCLI` + `libusb-1.0.0.dylib`. Cache it
under `~/.cache/ddrtest/`; only re-download if the binary is missing.

```bash
DDR_DIR="$HOME/.cache/ddrtest"
if [ ! -x "$DDR_DIR/RockchipDDRTestUtilityCLI" ]; then
  mkdir -p "$DDR_DIR"
  gh release download --repo evtest-hash/RockchipDDRTestUtility \
    --pattern 'RockchipDDRTestUtilityCLI-macos.tar.gz' -O "$DDR_DIR/cli.tar.gz" --clobber
  tar -xzf "$DDR_DIR/cli.tar.gz" -C "$DDR_DIR"
fi
DDRTEST="$DDR_DIR/RockchipDDRTestUtilityCLI"
```

If `gh` is unavailable, download the same asset with `curl -L` from
`https://github.com/evtest-hash/RockchipDDRTestUtility/releases/latest`. Keep
`RockchipDDRTestUtilityCLI` and `libusb-1.0.0.dylib` in the SAME directory (the
binary loads libusb via `@loader_path`).

## 2. Run

The board must be in maskrom/loader (plugged in, powered). Confirm with `"$DDRTEST" --list`.

| Goal | Command |
|------|---------|
| List connected Rockchip devices | `"$DDRTEST" --list` |
| **Full board test** (detect → soldering → eye-scan → reboot) | `"$DDRTEST" --auto --json` |
| Auto-detect DDR geometry + matching cfg only | `"$DDRTEST" --detect --json` |
| Detect + soldering test only (no eye-scan) | `"$DDRTEST" --detect-then-test --json` |
| Eye-scan only | `"$DDRTEST" --eyescan --json` |

Always pass `--json`: stdout is then exactly ONE JSON object; all progress/log lines go
to stderr. Add `--quiet` to drop progress. Multiple boards: `--device-id <id>` (from `--list`).

## 3. Read the result

Parse the JSON on **stdout**; decide from it, not from log text. Exit code is authoritative:

- `0` — success (every requested check passed)
- `1` — error (no device / parse / transport / unsupported SoC) — see stderr / `error` field
- `2` — a soldering test FAILED, an eye-scan was not GO, or detect found no unique cfg

`--auto` JSON shape:

```json
{
  "soc": "RK3576", "pid": "0x350E", "device": "Rockchip RK3576 (0x350E)",
  "detect":  {"type":"LPDDR4X","capacityMB":2048,"channels":2,"sysRegVersion":3,
              "cfg":"2GB LPDDR4X....cfg","tier":"uniqueByCoarse","candidates":1},
  "solder":  {"pass":true,"outcome":"PASS","state":"Completed","cfg":"...","bootSucceeded":false},
  "eyescan": {"go":true,"bytes":6115,"out":"/tmp/eyescan.txt"},
  "rebootedToMaskrom": true, "ok": true, "elapsedMs": 21840
}
```

Report `ok`, then the three stages: `detect.type`/`capacityMB`/`channels` + matched `cfg`
(and `tier` — `uniqueByCoarse`/`uniqueByTieBreak` = matched, `ambiguous`/`none` = no unique
cfg so no test ran), `solder.outcome`, `eyescan.go`. The full eye-scan transcript is at
`eyescan.out` (default `/tmp/eyescan.txt`). `solder.bootSucceeded:false` is normal for
`--auto` (it reuses the resident detect boot via skip-boot).

## Notes

- One board per USB plug; each test returns the device to maskrom at the end.
- Supported for detect/auto: RK3568/RK3566 (0x350A), RK3588 (0x350B), RK3576 (0x350E),
  RK3288 (0x320A, detect only). Eye-scan: RK3568/RK3576/RK3588.
- `"$DDRTEST" --help` lists every flag and the exit-code contract.
