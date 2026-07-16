# tools/ — DDR dev tooling (gitignored). Lessons learned.

Dev-only payload/cfg builders for DDR auto-detect (`ddr-autodetect/`) and eye-scan over USB
(`ddr-eyescan/`). Everything here is gitignored; only the generated `.cfg` ships in `DDRTestFiles/`.
Full running state: `ddr-eyescan/rk3568/artifacts/STATE.md`.

## Process (read this FIRST) — analyze the binary fully before touching HW

**The #1 lesson from the RK3576 work: FULLY analyze and understand the binary up front — do
NOT flail with small-change → HW-test → repeat.** Each HW run needs a manual power-cycle and is
slow; trial-and-error burns the user's time and degrades the board. Most of the pain here was
self-inflicted by guessing instead of measuring:
- Buffer placement was GUESSED (0x3FFB0000 → 0x3FFC0000 → 0x3FF98000 → 0x3FFA0000…) across ~10 HW
  runs, all failing, because I hadn't first determined the eyescan's SRAM footprint, the maskrom SP,
  and the free region. A single up-front **map probe (0x00-fill → run → largest untouched run)** +
  **SP dump** answered it definitively. Do the measurement FIRST, then place the buffer ONCE.
- I assumed the putc slot was 256B and wrote a 228B filter — it was 92B (next fn is the itoa
  helper). A 2-minute disasm of the function boundary would have caught it before building.
- I assumed training printed to UART (not putc); the raw-capture count proved it goes through putc.

Discipline: before editing/patching a bin, statically nail down every address and assumption it
depends on (via IDA/capstone/probes), write them down (STATE.md), and design the change to be
right the first time. Reserve HW runs for hypotheses you've already validated on paper. When a
question is HW-only (does state survive? where's free SRAM?), answer it with ONE purpose-built
probe, not by mutating the real artifact and hoping.

## Eye-scan over pure USB 0x80 (no serial) — RK3576 lessons

Goal: get a Rockchip eyescan bin's report over USB opcode 0x80 (not UART). Two working
architectures, each fitting the SoC's constraints — they are COMPLEMENTARY, not one-better:

- **RK3568 (small SRAM ~64KB, separable measurement core): small-core live-stream.**
  train-only bin → resident DTT → extract+relocate a small measurement core, run as a DTT
  item, stream LIVE via the DTT ring. Complex (core extraction, relocation, a1/DRAM-info rebuild).
- **RK3576/RK3588 (512KB SRAM, MONOLITHIC eyescan that self-trains): capture-then-relay (PATH ②).**
  Run the WHOLE eyescan as a fresh maskrom boot; patch putc to capture output to free SRAM;
  then a native DTT + a tiny "relay" item filters that buffer and streams it over 0x80. No
  eyescan relocation, no core extraction, no re-init — much simpler when SRAM allows.

### Why NOT to relocate/run the monolithic eyescan as an item (dead ends, don't repeat)
- **Relocating the DTT** (to free 0x…1000 for the eyescan): the DTT header verify-spins at its
  link base and maskrom loads 0x471 boots to a FIXED address → byte-patching the base can't move
  it. Its SMP-bringup routine also hard-calls the link base. DEAD.
- **Running the eyescan as a DTT item (RK3568 model)**: the eyescan's init reads DDR/PHY expecting
  the FRESH post-maskrom state. Run 3rd-stage (after a train + resident DTT) → it reads
  `0xFFFFFFFF` (DDR/PHY not in expected state) → garbage geometry → "soldering abnormality" +
  hang. The eyescan is COUPLED to being the first DDR bin after maskrom. Its measurement closure
  is ~the whole bin (per-freq retrain) — not a separable small core like RK3568. DEAD.
  → Conclusion: for a monolithic self-training eyescan, run it fresh; capture, don't relocate.

### Capture-then-relay: the non-obvious gotchas (all cost HW cycles to find)
1. **putc→memory removes the real bottleneck.** The eyescan's putc polls UART-TX-ready AND writes
   an 8KB log-ring per char (~9s stock). Overwriting putc with a plain memory `strb` → the whole
   scan runs in ~1s. Bottleneck is per-char overhead, NOT baud.
2. **downloadBoot REJECTS any file-size change.** Appending bytes to the eyescan bin → boot
   control transfer fails ("4096 got -99" / "512 got -1"). Keep the patched bin EXACTLY the stock
   size: overwrite in place. The putc slot is only that function's own bytes (RK3576 sub_3FF90D40 =
   0x5C before the next fn `sub_3FF90D9C` itoa, which is NEEDED). Fold the init-stub into the
   freed slot; don't append.
3. **Capture RAW, filter in the RELAY.** A line filter doesn't fit the ~92B putc slot (my
   filter-in-capture was buggy). Do a raw append in putc; filter in the relay item (@item-base,
   has room). Filter by LINE LENGTH: eye grids + training hex tables are ~90 chars (92% of output);
   keep lines ≤ ~72 (geometry + per-DQ `max_eye vref:%[..]` margins + `all result: pass` +
   `Channel N result`). 119KB → ~4.6KB over USB.
4. **Find free SRAM by MEASURING, not guessing.** The eyescan uses SRAM broadly; guessing buffer
   addresses wasted ~10 HW runs. Map probe: fill high SRAM with a marker → run the scan → report
   the largest untouched run. Fill with **0x00** (BSS default) — 0xAA breaks the scan (it reads a
   buffer expecting 0) → invalid map. RK3576 free gap: 0x3FF98000+. maskrom SP was LOW (0x3FF80ED0)
   — don't assume a high stack.
5. **step① download = lenient ONCE.** The bin launches + runs long; strict-then-lenient
   re-download hits the now-busy device → error. Download once, treat final-chunk-no-ACK as launched.
6. **step② must RE-DISCOVER + re-open the device.** The fresh-boot bin RE-ENUMERATES (new USB
   address) when it finishes; reusing the step① handle → NO_DEVICE (-4). Re-discover by PID each
   attempt, poll ~90s (scan takes tens of s). (Both in `EyescanRunner`.)
7. **Relay must THROTTLE its PUTS.** Bursting the buffer through the DTT ring outruns the host's
   0x80 drain → early data lost, host gets only the tail. ~1ms spin per line so the host keeps up.
8. **Relay loop vars in CALLEE-SAVED regs (x21-x25).** The DTT PUTS is a function → clobbers
   x0-x18; loop pointers in caller-saved regs corrupt after the first PUTS (symptom: only 1 line
   emitted).

### Packaging / GUI
- Pack the 3 bins into `DDRTestFiles/<soc>/DDR眼图.cfg` via `common/build_eyescan_cfg.py`:
  Boot=dtt, trainonly=capture-bin, eyescan=relay-item, `--download-base <item-base>`.
- GUI lights up automatically: "眼图" is in `CfgRepository.containerCfgMarkers` (excluded from the
  solder list); `MainViewModel.locateEyescanCfg` finds the cfg → `canEyescan`. **itemBase flows
  from the cfg's download-base** (`plan.downloadBaseAddress` → `EyescanRunner.itemBase`), so each
  SoC's item base is carried by its cfg (RK3568 0xFDCC4000, RK3576 0x3FF84000).
- Verdict uses `all result: pass` (precedes the end-marker), so clipping at the marker is cosmetic.

### Debugging on HW
- **Debug output → a FILE, not print().** GUI stdout is block-buffered when redirected and NOT
  flushed on SIGTERM → print() is lost. Write to a file (e.g. `x.write(toFile:…)`). The CLI flushes
  on clean exit, so CLI-redirect works.
- **Power-cycle for clean runs.** Many back-to-back runs without a full power cycle degrade the
  board (dirty state → downloadBoot fails, inconsistent scan size). A software CRU-reboot does NOT
  reliably re-enter a downloadBoot-able maskrom; physical power cycle does.

### Per-SoC RE checklist (to port PATH ② to a new SoC, e.g. RK3588)
Load base (verify-spin literal @ header) · putc fn + its slot size · main + main's first BL (+ the
sub it calls, for the init-stub trampoline) · a free-SRAM buffer region (map-probe it) · item base =
DTT downloadBaseAddress · DTT PUTS vector + ring unread halfword · reboot regs (boot-mode + CRU).
RK3588: **NOT DONE (2026-07-15)** — addresses RE'd + artifacts build + 3-step runs, but the
streamed transcript is CORRUPT (host 0x80 byte-loss → spliced/missing lines) and slow (~62s).
Do NOT mark done without USER confirmation. Addresses (verified): eyescan load base 0xFF001000, item
base 0xFF004000, putc sub_FF011088 (file 0x101D8, 88B slot), main-BL 0xFF0116F8→sub_FF0116D8,
buffer 0xFF020000/0xFF020100 (footprint top ≈0xFF017308), DTT PUTS 0xFF001004, ring unread
0xFF0034E6, reboot boot-mode 0xFD588080 / CRU 0xFD7C0C08. Full status: rk3568/artifacts/STATE.md.
Open issues: (1) per-line throttle (0x00100010, from RK3576) likely too short for RK3588's faster
cores → host drops bytes; (2) ~62s (step② latency + drain stalls). NOTE: EyescanRunner's
`rawEnd`-truncation is RK3568-only — for a SoC with itemBase ≥ rawEnd (RK3588: 0xFF004000 >
0xFDCCF510) it underflows UInt32 (SIGTRAP); the guard is in place.
