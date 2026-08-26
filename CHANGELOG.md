# Changelog

## 3.0

The release is a major one for one reason: **two of the GUI's three verdict paths
were giving wrong answers**, and fixing them changed how a verdict is produced,
displayed and archived throughout the tool.

### Verdicts

- **The eye-scan reported a bad board as PASS.** The verdict logic existed twice
  — once in the GUI, once in the CLI — and the copies drifted. The GUI's split
  the transcript on the Character `"\n"`, but the device speaks CRLF and `"\r\n"`
  is a single Swift Character, so the whole transcript came back as one "line".
  That blob contains `pass` (the per-channel summaries), so a scan whose firmware
  printed `all result: err` read as passing. Reproduced on an RK3566, fixed, and
  pinned by a golden fixture captured from that board.
- **A USB timeout looked exactly like a bad board.** The engine had classified
  failures for a while (`FailureKind`), but only the CLI read it; the GUI
  collapsed everything into a red 测试失败. Runs are three-state now — passed /
  device-failed / **no verdict** — across the GUI row, the CLI exit code and the
  saved file (`Result: NO VERDICT (<reason>)`). A pulled cable can no longer
  scrap a good board.
- Every pass/fail decision now lives in `DDRCore/Verdict.swift`, with tests. The
  app targets are only allowed to display what it returns.

### Chip identity

- **The serial was not zero-padded.** It is rendered `%016llx` now, matching the
  firmware's fixed 64-bit field. That string is the only bridge between two
  device domains — the tool reads it from OTP in maskrom, the booted board
  reports the same value, and `adb -s <serial>` matches them as strings — so a
  chip whose folded value starts with a zero nibble broke device claiming, and
  broke it misleadingly: the flash succeeded, the board came up, and the software
  reported "flashed, won't boot". Measured on an AZ07 (RK3566):
  `883265bf7fee7c8` (15) where the firmware prints `0883265bf7fee7c8` (16).
  Present since the first release; the boards seen until now all happened to
  start with a nonzero nibble.

### Detection

- **Probe items now wait for the device to say they finished**, not for their
  output to look complete. Measured on both an RK3566 and an RK3576: after
  otpdump's text is complete the loader takes ~560 ms more to return, and
  `detect` was returning inside that window — with `--solder`'s next act being a
  download to a firmware not yet back in its command loop.
- Detection got faster as a side effect: osregdump 3.83 s → 1.46 s, whole detect
  7.4 s → 5.6 s (RK3566), 8.5 s → 6.7 s (RK3576).
- Both probes report `item returned` / `DID NOT return` in their timing line, so
  a stall can be told from a slow run.

### GUI

- The log gets the window. The 300 pt config column is gone — with auto-detect on
  nobody touched it, and the config it chose was a list row that could scroll out
  of sight. It is a toolbar pop-up now, always visible.
- The verdict has a fixed row of its own instead of a badge floating over the log
  it was summarising.
- **A device picker**, when more than one board is on the bus, labelling each by
  the socket it sits in. Every path already honoured the choice; nothing could
  set it.
- Fixed: with two boards, unplugging the probed one handed the selection to the
  survivor while its latches stayed — the next run skipped both boot and detect
  against a different board.
- Fixed: an eye-scan's card appeared in the soldering pane, green PASS and all,
  where it reads as a verdict about the wrong test.
- Fixed: log entries are routed by the item the engine names. The old code
  attached errors to whichever card was live, so a failure in `forceinit` could
  redden `connect`.
- 开始 is disabled when it would do nothing (no config, no detect to supply one).
  It used to be clickable and silently do nothing.
- **自动测试 removed.** It ran a test on plug-in, and it targeted whatever was
  *selected* — so with a board already on the bus, plugging the next one re-ran
  the previous. Once the operator can say which board to test, "which board did
  this arrival mean" has no good answer. Plugging a board in now never starts
  anything; `startTest()` has exactly one caller, the button.
- 自动探测 → **自动探测配置**: the label now names what it does for you.
- Step cards gloss the firmware's item names (`forceinit · 强制初始化`).

### CLI

- The bring-up diagnostics (`--cfg`, `--repeat`, `--probe-bulk`) are gone. Four
  commands remain, all inside the JSON contract, so `--json` always prints
  exactly one object.
- The machine contract — exit codes, `errorCode`, argv parsing, JSON shape — has
  tests for the first time, each area mutation-checked.

### Packaging

- **libusb is linked statically.** The standalone CLI is now ONE file (it already
  embedded the whole config library), and the app bundle has no `Frameworks/`
  dylib, no rpath and no `install_name_tool`. The build fails if any shipped
  binary still references libusb dynamically — such a binary dies on a machine
  without Homebrew, and nothing checked for it before. See
  [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for the LGPL consequence.

### Core cleanup

- The saved result file was archiving a cable pull as `Result: FAIL` — the same
  conflation as the GUI badge, in the artifact an operator keeps.
- The Windows tool's `config.ini` + language subsystem was ported faithfully and
  consumed by nobody; ~90 lines removed, including a default-config fallback that
  contradicted the rule that a cfg only runs on a unique match.
- `TestStep`/`StepState` moved out of the core: they are the GUI's card model and
  nothing else referenced them.

### Tests

112 → 177, in three targets: `DDRCoreTests`, `GUITests` (new — the GUI's session
and step pipeline, driven by a fake transport) and `CLIContractTests` (new).
