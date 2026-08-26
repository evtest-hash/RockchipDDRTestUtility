# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 语言

用中文回复。

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
swift run RockchipDDRTestUtilityCLI --solder --json

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

- **DDRCore** — Shared library: config/INI parsing, binary `.cfg` parser, test execution engine, result log writer, models. Also the DDR auto-detect logic: `DetectProfile` (per-SoC parameter table keyed by USB PID), `OsRegDecoder` (SYS_REG V1/V3 geometry decode), `CfgAutoSelect` (exact type+capacity+per-die-CS cfg ranking).
- **DDRUSB** — USB transport layer: `RkUsbTransportLibusb` implements `UsbTransport` protocol using libusb. Handles control transfers (boot download), bulk transfers (command/data), ACK validation, and printf polling. Also `DdrDetector` (actor) — the dedicated DDR auto-detect driver (NOT the test engine).
- **RockchipDDRTestUtility** — SwiftUI desktop app. `MainViewModel` orchestrates the workflow: load config → discover test files → discover USB devices → auto-detect DDR + preselect cfg → run test → save result.
- **RockchipDDRTestUtilityCLI** — Command-line interface. FOUR production commands, all inside the `--json` contract: `--list`, `--detect`, `--solder`, `--eyescan`. The diagnostic modes that existed while the USB layer was being brought up (`--probe-bulk`, `--cfg`, `--repeat`) are gone — the link is settled, and they were the only modes outside the JSON contract.

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

### DDR Auto-Detect

`DdrDetector` (DDRUSB) identifies a board's DRAM geometry **over pure USB** (no serial) and detect+test now run as ONE atomic operation (`MainViewModel.performDetectThenTest`), never detect alone. Trigger is decided by `autoTestEnabled`: OFF (default) — plugging in a device does not probe/drive it; the operator clicks 「开始测试」, which `startTest()` orchestrates into a detect-then-test call when the device is unprobed and supported, else runs the already-selected cfg. ON (batch) — `pollDevices` fires that same `startTest()` path automatically on plug-in. A cfg is set only by a unique detect hit (`uniqueByCoarse`/`uniqueByTieBreak`) or manual selection — there is no default-first-file fallback; `.ambiguous`/`.none` stop and leave `selectedFileID` unset for the operator to pick. This replaced the old always-probe-on-plug-in model (`runDetectThenMaybeTest`/`maybeAutoTest`/`maybeLaunchAutoDetect`). Supported SoCs: RK3568/3566 (0x350A), RK3588 (0x350B), RK3576 (0x350E), RK3288 (0x320A) — see `DetectProfiles`. Detect flow:

1. `DetectProfile` (by USB PID) provides per-SoC addresses; `DdrDetector` loads the SoC's single packaged `DDR自动探测.cfg` and pulls its four payloads.
2. Downloads the rkbin auto-probing DDR bin (0x471) → SoC writes geometry to PMU `OS_REG`; downloads the DDR Test Tool Boot; runs the `osregdump` probe which dumps `OS_REG` back over USB.
3. `OsRegDecoder` decodes — SYS_REG **V3** (RK356x/3576/3588, `os_reg2`+`os_reg3`, multi-group) or **V1** (RK3288, single `os_reg2`). `CfgAutoSelect.rank` matches EXACTLY on (DRAM type + total capacity + per-die CS); an empty result = detection failed (never runs a wrong cfg). Two-level matching: this L1 pass (filename: type+capacity+per-die-CS, unchanged) can still return >1 candidate for discrete-DRAM boards sharing a filename; `CfgAutoSelect.tieBreak` then narrows within that group using each candidate's `forceinit` param geometry (`CfgParamGeometry.widthKey`, resolving combo params via `inputRangeValue[index]` — the same die/bus-width resolution `RkUsbTransportLibusb.resolveParamValue` uses when writing to hardware) against the decoded `ChannelGeometry`. A unique tie-break hit is `MatchTier.uniqueByTieBreak`; `performDetectThenTest` treats it identically to `MatchTier.uniqueByCoarse` — both preselect the cfg and proceed straight into the test. RK3288's `cha`/`chb` param schema has no geometry mapping this round, so its ambiguous groups fall back to `MatchTier.ambiguous` (manual pick, no auto-test).
4. The detect cfg packages Boot + ddrbin + osregdump + otpdump + reboot; `DdrDetector` drives them itself (NOT via `TestExecutionEngine`). `CfgRepository.discoverTestFiles()` EXCLUDES any `…自动探测.cfg` so it's never user-selectable / run as a test.

**Chip identity + model variant (`otpdump`).** OPT-IN (`detect(readIdentity:)`) — the CLI reads it, the GUI deliberately does NOT (no extra USB item on the production test path). The probe dumps raw OTP from byte 0 and the dump is **self-describing**: after `OTP_ALIVE` it prints `OTP_DUMP` and the OTP byte offset its first word came from, so a stale cfg can never be misread at an assumed base (`ChipIdentity.parseOtpDump`; `IdProbe.legacyBaseByte` is only the fallback for pre-self-describing payloads). `OtpDump` is then addressed by ABSOLUTE OTP offsets — the same ones the vendor dtsi uses.

`ChipVariant.resolve(family:dump:)` names the variant, with every rule transcribed from the vendor kernel (linux-6.1 rkr7) and `nil` whenever the captured bytes don't justify a conclusion — it never guesses:

| family | fields (OTP offset) | resolves to |
| --- | --- | --- |
| RK3588 | spec `0x06` bits[0:5]; package = (`0x05` bit0 << 3) \| `0x06` bits[5:3] | spec 0x13 → package 0x2 = **RK3588S2**, else RK3588S; 0xd = M; 0xa = J; else RK3588 |
| RK3576 | spec `0x08`; test_version `0x07` bits[0:4] | 0xd = M; 0xa = J; 0x13 = S. test_version ≠ 0 marks a test/pilot revision and is REPORTED but does not change the name — the kernel's gate on it (`rockchip-cpufreq.c` rk3576_cpu_get_soc_info + its GPU twin) selects the OPP bin, and a board silkscreened RK3576S reads spec 0x13 with test_version 1 |
| RK356x | cpu_code `0x02` (2B, big-endian); spec `0x07` | 0x3566/0x3567/0x3568 → RK3566/RK3567/RK3568; RK3566 + spec 0x1b = **RK3566PRO** |

Every rule above is pinned by a real-silicon capture in `ChipVariantTests` (RK3588, RK3588S2, RK3568, RK3566, RK3576S). RK3288 reports CPUID + serial but NO variant: it has no OTP block at all — its CPUID comes from the 32-byte **eFuse** (`efuse@ffb40000`, `cpu_id@0x07` = CFG_CPUID_OFFSET 0x7, gate CRU `0xFF76018C` bit 10 PCLK_EFUSE256), read by its own arm32 probe (`arm32/efuseprobe.S.in`) whose byte-at-a-time strobe protocol mirrors `rockchip_rk3288_efuse_read`; the record is still named "otpdump" and still emits the OTP_* framing, so the host side has no special case. Its RK3288W variant lives in the HDMI PHY revision register, not the eFuse, so `family` stays nil and no variant is reported. The RK3288 CPUID/serial is board-confirmed like the others (adb reported our derived `7f35c361c64395de`), but ONLY after the firmware was given an eFuse driver: stock `rk3288_defconfig` sets neither `CONFIG_MISC`/`CONFIG_ROCKCHIP_EFUSE` nor an enabled efuse DT node, so `rockchip_set_serialno()` takes its `#else` branch and builds the CPUID from an unseeded `rand()` — every such board then advertises the same constant. A board's serial disagreeing with ours means that, not a bad read. `specification_serial_number` is a GRADE marker (M/J/S/PRO), NOT the model class: the class comes from `cpu_code` and packaging differences need `package_serial_number` on top. Byte→word mapping is per-controller (`drivers/nvmem/rockchip-otp.c`): RK3588/RK3576 read `byte/4 + ns_offset` (0x300 / 0x1C0), RK356x reads `byte/2` with no ns_offset, and RK3288's eFuse (`rockchip-efuse.c`) is addressed by the byte — the reason each SoC's `OTP_WORD`/count in `build.sh` differs.

**Unified detect→test (no reboot):** `DdrDetector.detect(reboot: false)` keeps the transport open and the Boot resident; the test then runs with `skipBoot: true` on that same session (`MainViewModel`; CLI `--detect-then-test`). This avoids the reboot-to-maskrom step entirely — faster, and it sidesteps the RK3288-with-populated-eMMC limitation (see below). Before auto-running the test, `MainViewModel` polls `probeAlive()` until the resident Boot is idle (else the first `downloadItem` can intermittently `bulk IN timeout`).

**reboot-to-maskrom is loader-dependent** (only used when NOT unifying). The BootROM never checks the flag; the next-stage loader/ddrbin does (`CONFIG_ROCKCHIP_BOOT_MODE_REG` = magic `0xEF08A53C`, then a CRU soft-reset). Works on empty-eMMC boards (BROM falls to maskrom) and cooperative loaders; a populated eMMC with a non-cooperative loader needs the hardware maskrom key. No pure-software, loader-independent, non-destructive maskrom exists on these SoCs — hence the unified no-reboot flow is preferred.

**GUI toggles** (`MainViewModel`, in-memory, not persisted): `autoDetectEnabled` (default ON — gates whether `startTest()` attempts a detect at all for an unprobed, supported device; off ⇒ `startTest()` just runs the manually selected cfg), `autoTestEnabled` (default OFF — gates whether `pollDevices` calls `startTest()` automatically on plug-in; off ⇒ plug-in is passive and the operator must click 「开始测试」).

**Detect-cfg build tooling** lives in `tools/ddr-autodetect/` (**gitignored, dev-only**): `build.sh` cross-assembles the arm64/arm32 `probe.S.in`/`reboot.S.in` payloads (clang) and packs each SoC's `DDR自动探测.cfg`. A full rebuild needs the vendor rkbin DDR bin (not in this repo, per-machine path); `OTP_ONLY=1 bash build.sh` instead rebuilds ONLY the otpdump payload and swaps it into the shipped cfg (`lib/repack_otpprobe.py`), carrying every other record over still-RC4-encrypted so it cannot drift. Only the generated cfg ships in `DDRTestFiles/<soc>/`; regenerate via `bash tools/ddr-autodetect/build.sh` when payloads/addresses change. arm32 payloads must never use `bl` — the raw `.text` extractor doesn't resolve the R_ARM_CALL it leaves behind, so a forward `bl` ships as branch-to-self and hangs; call through a register (`blx rN`) instead. Plain forward `b`/`bne` ARE resolved at assembly time and are fine, as is a long-range `adr` (it fails the build loudly rather than misaddressing) — both verified on this toolchain.

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

**A failed run says WHY** — `ExecutionResult.failure: FailureKind?`. Only
`.deviceVerdict` (resultCode != 0) means the DDR itself is bad; `.transport`,
`.cfg` and `.noDevice` mean the test never produced a verdict at all. The engine
used to collapse both into `outcome: .failed`, so a single bulk timeout was
indistinguishable from a genuine soldering failure — and the CLI reported it as
FAIL, which on a production line scraps a good board. `FailureKind.classify` maps
a thrown error conservatively: anything unrecognised becomes `.transport`, never
a device verdict. `ResultLogWriter.render` now appends host-side ERROR entries
after the device printf, because the CLI embeds that render as the sole failure
evidence in its JSON.

### Verdict layer — every pass/fail decision, in ONE place

`DDRCore/Verdict.swift` owns every judgement this tool makes; the GUI and the CLI
are only allowed to DISPLAY what it returns (and, for the CLI, map it onto exit
codes). **Any new threshold, tier→action mapping, or pass/fail rule goes here and
comes with a test. Never in an app target — neither is unit-testable.**

This rule exists because it was broken. The eye-scan verdict had a copy in
`MainViewModel` and another in `CLIMain`; they drifted, and the GUI's copy
reported PASS on a board whose firmware had printed `all result: err`. The device
speaks CRLF, `"\r\n"` is ONE Swift Character, so `split(separator: "\n")` never
split it — the whole transcript came back as a single "line", which of course
"contains pass" because of the earlier per-channel `pass` lines. `EyescanVerdict`
splits on `\.isNewline` instead, and a golden fixture captured from the failing
RK3566 (`Tests/DDRCoreTests/Fixtures/eyescan_rk3566_cs0wr_fail_crlf.txt`) pins it.

- `EyescanVerdict.parse` → `EyescanReport` (firmware's own `all result:` summaries
  + the `all dq eye scan done` marker). The host adds NO thresholds of its own.
- `RunConclusion` — **three** states, not two: `.passed` / `.deviceFailed` /
  `.inconclusive(InconclusiveReason)`. `.solder(_:)` maps an `ExecutionResult`,
  `.eyescan(report:wedged:completedViaStatus:)` maps a scan. Only `.deviceFailed`
  means scrap the board.
- `DetectVerdict.decide(_ tier:)` → `.adopt` / `.manual` — the iron rule that a
  cfg is run only on a unique match. Tier still selects the operator-facing
  wording; it no longer selects the DECISION in two places.

The GUI renders `RunConclusion` directly (`overallConclusion`): green 测试通过 /
red 测试失败 / **orange 未测出结论**. Before this it collapsed every host-side
error into red 测试失败 — `FailureKind` was produced by the engine and consumed
only by the CLI — so a bulk timeout looked exactly like a bad-DDR verdict and a
production line would scrap a good board. The GUI also no longer forces FAIL when
any step logged an error; the verdict is the engine's, taken from the device's
status/result words.

### CLI exit codes & JSON contract

Both are derived in ONE place (`CLIExit.from` in `CLIMain.swift`) from the two
fields every mode fills — `pass` and `errorCode`:

    errorCode != nil → 1 (ERROR: no verdict — fix the setup, board untested)
    pass == true     → 0 (PASS)
    else             → 2 (FAIL: the device judged the DDR bad — scrap it)

So `exit 2 ⟺ errorCode == nil && pass == false`, which is what makes 2
trustworthy. Every runner returns a `CLIResult` instead of exiting itself; there
is exactly one `Foundation.exit` on the result path (`finish`), and `elapsedMs`
is stamped there too.

Per-mode verdicts: `--detect` passes only on a UNIQUE match — `.none` is a board
verdict (exit 2, because the cfg library covers every shipped DRAM combination,
so a zero-match means the geometry isn't a real part) while `.ambiguous` is
`errorCode: ambiguousCfg` (exit 1, needs a human). `uniqueCfg()` enforces the
GUI's iron rule; plain `CfgAutoSelect.firstAvailable` returns `candidates[0]`
even for an ambiguous group, which is how `--solder` used to test a board
against a cfg the GUI would have refused. `--eyescan` derives its verdict from
`RunConclusion.eyescan`, which maps `wedged` / `!completedViaStatus` to
`deviceWedged` / `scanIncomplete` (exit 1) — both were previously printed only to
the human summary, so automation could not tell "replug the fixture" from "this
board's eye failed". A scan whose status says done but whose transcript carries
no `all dq eye scan done` marker is now ALSO exit 1 (it used to be exit 2): the
scan misbehaved, so no verdict about the DDR exists, and only a device verdict
may scrap a board. The human summary says `NO VERDICT — <reason>` there, never
FAIL.

The JSON contract covers every command (`--detect`, `--solder`, `--eyescan`,
`--list`) plus every error path — there is no longer any mode outside it, so
`--json` always prints exactly one object. `CLIOut.json` is set by pre-scanning argv BEFORE `parse`, so an
argument error still emits JSON. One verdict field named `pass` everywhere (the
old `ok` / `solder.outcome` / `solder.state` / `eyescan.go` are gone), `mode`
identifies the command (`--cfg` used to report itself under the `solder` key),
and `errorCode` is a closed enum — the old free-text `error` carried
`DDRToolError.errorDescription`, which drops the case discriminator.

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
   Verify this path by clicking 「开始」 twice in the GUI without re-plugging
   (the CLI's `--repeat N` used to exercise it; the CLI is one-shot now).

Re-booting an already-booted device fails (`expected 512 got -1`), so run 1 of a
fresh connection needs a real bootrom (physical replug after the prior session).

### Device admission (Maskrom only)

`discoverDevices` admits a device only when ALL of these hold — the rule is
transcribed from `upgrade_tool`, not invented:

    idVendor  == 0x2207
    idProduct >= 0x0100        (upgrade_tool sub_100003544)
    bcdUSB & 1 == 0            (upgrade_tool sub_1000035D0 / sub_100003994)

`upgrade_tool` admits a rockusb device when (vid, pid) is in its built-in legacy
chip table OR when the VID is Rockchip's and the PID is >= 0x0100. That table
holds only pre-RK3288 parts (VID 0x071B: 0x3201/0x3226/0x3228; VID 0x2207:
0x261A/0x273A/0x281A/0x282B/0x290A/0x292A/0x2C26/0x300A/0x300B/0x310B/0x320A),
so **no modern PID appears in it** and every SoC here is admitted by the
`>= 0x0100` rule alone — which is why this code carries the rule and not a table.
A second vendor table (0x2207 PIDs 0x0000/0x0010/0x0016 plus legacy) marks
mass-storage "Msc" devices; we want none of them, so it is not transcribed.

`bcdUSB` bit 0 is Maskrom (clear) vs Loader (set) — both advertise the SAME PID,
so it is the only discriminator. This tool keeps ONLY Maskrom: the DDR bin goes
down over control transfer 0x0C/0x0471 into SRAM, which no other personality can
accept. A Loader- or ADB-mode board is therefore not a candidate but invisible,
and the CLI reports `noDevice` for it — same as `upgrade_tool ld`, which prints
`connected(0)` for an ADB device.

Measured on one RK3576 board, same PID in both personalities:

| mode | idProduct | bcdUSB | bit 0 | product string |
| --- | --- | --- | --- | --- |
| Maskrom | 0x350A (RK3566) | **0x0200** | 0 | — (no serial) |
| Loader | 0x350E | **0x0301** | 1 | "USB download gadget" |
| ADB | 0x0006 | 0x0320 | 0 | "rk3xxx" |

Note the Loader reads **0x0301**, not 0x0201 — so `bcdUSB == 0x0201` would MISS
this loader and admit it as Maskrom. Test the bit, as the vendor does.

**Both gates are required, and neither substitutes for the other.** The ADB row
above has bit 0 clear, so the bcdUSB gate alone would call it Maskrom; the PID
gate rejects it. Conversely the Loader row has a perfectly valid PID, so the PID
gate alone would admit it.

Before this existed only the VID was checked, so an ADB-mode board entered the
candidate list — and since `chooseDevice` takes `devices.first`, it could be
selected over a real Maskrom board and then have rockusb command packets pushed
at it. `resolveInterfaceAndEndpoints` also no longer falls back to a hardcoded
`(0, 0, 0x02, 0x81)`: claiming endpoints the descriptor never advertised only
deferred the failure to the first transfer.

Because `discoverDevices` returns Maskrom devices exclusively, `UsbDevice` needs
no mode field and the GUI needs no change beyond seeing fewer candidates.

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
