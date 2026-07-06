# DDR Auto-Detect — RK3568 Feasibility Spike (approach A)

Detect a board's DDR geometry **over pure USB, driven by a cfg** (no xrock, no
UART), and shortlist the matching soldering-test cfg. This is a spike to verify
the mechanism end-to-end before productizing it into the GUI.

## STATUS: verified on hardware (2026-07-06)

Ran on a real RK3568 board (in maskrom). The probe read OS_REG over the USB 0x80
channel; decode → **LPDDR4X 4096MB, dual-CS (rank=2), 32-bit bus, x16 die** —
**matches the board's real spec** — and auto-selected
`4GB LPDDR4X(用2个CS且每个CS为16Gb组成)焊接检测.cfg`.

    OS_REG2 = 0x1000EAF1   OS_REG3 = 0x30000001   (stable across runs)

### Critical gotcha — two output channels (this cost the most debugging)
The DDR Test Tool has TWO printf paths, and the host's 0x80 reader only sees one:
  - `0xFDCC1010`  puts → putc → **UART** (serial only; 0x80 never sees it)
  - `0xFDCC1004`  puts → **RAM ring buffer @0xFDCC38B8** → what 0x80 returns  ← USB
The probe MUST emit via `0xFDCC1004`. Using `0xFDCC1010` printed to the serial
port and looked like a flaky/racy USB failure for many runs.

## Mechanism

```
① rkbin DDR bin  ──0x471 (control)──►  SoC auto-detects DRAM, writes geometry
                                        into PMU_GRF OS_REG (0xFDC20200, survives)
② DDR Test Tool Boot ──0x471──►  (= the cfg's Boot record) brings up USB bulk,
                                  the 0x80 printf channel, and the service vectors
③ osregdump item ──0x02 → 0xFDCC4000, 0x03 run──►  reads OS_REG, prints hex via 0x80
④ host  ── reads 0x80 printf ──►  decode SYS_REG → geometry → rank cfgs
```

`②③④` are the tool's existing engine. `①` is the only added step (`--detect`
downloads the rkbin bin via the existing control-0x471 path first). The rkbin bin
and the Test Tool Boot both link at 0xFDCC1000 but run **sequentially**, so they
never coexist — the detected geometry lives in the OS_REG hardware register,
which survives the second download.

## Files

| File | What |
|------|------|
| `probe.S` | OS_REG probe, ARM64, runs in place at `0xFDCC4000`; reads `0xFDC20200`+ (OS_REG0..11), prints each hex via service vector `*(0xFDCC1018)`, returns 0. Calls the resident Boot's puts vector `*(0xFDCC1010)`. |
| `extract_text.py` | Pull raw `.text` out of the assembled ELF (no objcopy). |
| `build_detect_cfg.py` | Pack `Boot (DDR Test Tool, raw) + osregdump (probe, RC4)` into a valid cfg the shipping `CfgBinaryParser` reads unchanged. |
| `probe.bin` | Pre-built probe (147 B). |
| `rk3568_osregdump.cfg` | Pre-built detect cfg. |

## Rebuild the probe + cfg (only if you change probe.S)

```bash
clang --target=aarch64-linux-gnu -ffreestanding -nostdlib -c probe.S -o /tmp/probe.o
python3 extract_text.py /tmp/probe.o probe.bin
python3 build_detect_cfg.py \
  "../../DDRTestFiles/RK3568&RK3566/8GB LPDDR4X(用4个CS且每个CS为16Gb组成)焊接检测.cfg" \
  --from-template probe.bin rk3568_osregdump.cfg
```
(`--from-template` reuses the RK3568 DDR Test Tool Boot from that cfg.)

## Run on hardware (RK3568 in maskrom, USB connected)

From the package root:

```bash
swift run RockchipDDRTestUtilityCLI --detect \
  --ddr-bin ../rkbin/bin/rk35/rk3568_ddr_1560MHz_v1.25.bin \
  --detect-cfg tools/ddr-autodetect/rk3568_osregdump.cfg
```

### What success looks like
- The rkbin DDR bin downloads and runs (`①`), then the probe cfg runs (`②③`).
- Output contains an `OS_REG (raw)` block with 12 non-trivial words (OS_REG2/3
  non-zero), a decoded geometry line, and a ranked candidate list.
- The decoded type + size (and the top candidate) match the board's real DDR.

### Risk points this run is meant to confirm
1. **OS_REG survives step ②** — the Test Tool Boot download must not clobber the
   geometry the rkbin bin wrote. (Boot doesn't touch DDR; verify empirically.)
2. **OS_REG holds correct geometry** — compare the raw words / decode to the
   board's known spec.
3. **Match is unique** — if several cfgs tie, we add a preselect+list step.

## Caveats (spike)
- **SYS_REG decode: confirmed on one RK3568 board** (LPDDR4X 4GB dual-CS),
  including the `SYS_REG3 bit0 → LPDDR4X` rule. Other geometries/SoCs are still
  unvalidated; the **raw OS_REG words are always printed**, so correct the
  bitfield constants in `DdrGeometry.swift` if a field is ever off.
- **Each detect run leaves the device booted** — the initial rkbin + Boot
  downloads need fresh maskrom, so a second `--detect` must be preceded by a
  maskrom reset. (In-session probe retries reuse the resident Boot and need no
  reset; only re-running the whole flow does.)
- Uses `rk3568_ddr_1560MHz_v1.25.bin`. Any auto-probing RK3568 DDR bin works;
  swap via `--ddr-bin`.
- Fallback by design: if detect fails (DDR won't init, OS_REG empty, no unique
  match), the operator selects the cfg manually — detect never blocks testing.
