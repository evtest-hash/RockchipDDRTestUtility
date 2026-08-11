import DDRCore
import DDRUSB
import Foundation

struct CLIArguments {
    var cfgPath: String?
    var selectedDeviceID: String?
    var listOnly = false
    var probeBulk = false
    /// DDR auto-detect spike: download the auto-probing rkbin DDR bin (0x471),
    /// run the osregdump probe cfg, read OS_REG over USB, decode + shortlist cfg.
    var detect = false
    var detectCfgPath: String?
    /// SOLDER: detect → soldering test on ONE transport, no reboot between.
    /// detect(reboot:false) leaves the DDR Test Tool Boot resident + transport
    /// open; the matched cfg then runs with skipBoot:true on that same Boot, then
    /// reboots to maskrom. The device USB printf is embedded in the JSON result.
    var solder = false
    /// How many times to run the full cfg in one process. >1 exercises the
    /// repeat-test / boot-skip path: the first run boots, and subsequent runs
    /// pass `skipBoot: true` (mirroring MainViewModel's `deviceNeedsBoot`
    /// latch, cleared only after `bootSucceeded`), exactly like clicking
    /// "start test" repeatedly in the GUI without re-plugging.
    var repeatCount: Int = 1
    /// EYE-SCAN mode: like --detect / --cfg, driven by the SoC's packaged `DDR眼图.cfg` (auto-located
    /// by the connected device's PID → SoC). All payloads (DTT/item/trainonly/reboot) + the item base
    /// come from that cfg — no per-bin flags. `--eye-timeout` is a run option.
    /// The full transcript is embedded in the JSON result (no side file).
    var eyescan = false
    var eyescanTimeout: TimeInterval = 120
    /// Emit a single machine-readable JSON object on stdout; route all human
    /// progress/log lines to stderr so stdout carries ONLY the JSON.
    var json = false
    /// Suppress step-by-step progress lines (final human summary still shown,
    /// unless --json). Independent of --json.
    var quiet = false

    static func parse(_ argv: [String]) throws -> CLIArguments {
        var args = CLIArguments()
        var idx = 1

        while idx < argv.count {
            let token = argv[idx]
            switch token {
            case "--cfg":
                idx += 1
                guard idx < argv.count else {
                    throw DDRToolError.invalidFormat("Missing value for --cfg")
                }
                args.cfgPath = argv[idx]
            case "--device-id":
                idx += 1
                guard idx < argv.count else {
                    throw DDRToolError.invalidFormat("Missing value for --device-id")
                }
                args.selectedDeviceID = argv[idx]
            case "--list":
                args.listOnly = true
            case "--probe-bulk":
                args.probeBulk = true
            case "--detect":
                args.detect = true
            case "--solder":
                args.solder = true
            case "--detect-cfg":
                idx += 1
                guard idx < argv.count else {
                    throw DDRToolError.invalidFormat("Missing value for --detect-cfg")
                }
                args.detectCfgPath = argv[idx]
            case "--repeat":
                idx += 1
                guard idx < argv.count, let n = Int(argv[idx]), n >= 1 else {
                    throw DDRToolError.invalidFormat("Missing/invalid value for --repeat (expect int >= 1)")
                }
                args.repeatCount = n
            case "--eyescan":
                args.eyescan = true
            case "--eye-timeout":
                idx += 1
                guard idx < argv.count, let n = Double(argv[idx]), n >= 1 else {
                    throw DDRToolError.invalidFormat("Missing/invalid --eye-timeout (seconds)")
                }
                args.eyescanTimeout = n
            case "--json":
                args.json = true
            case "--quiet":
                args.quiet = true
            case "--help", "-h":
                printUsageAndExit()
            default:
                throw DDRToolError.invalidFormat("Unknown argument: \(token)")
            }
            idx += 1
        }

        return args
    }
}

/// Output router. In `--json` mode stdout carries ONLY the final JSON object;
/// every human/progress line is diverted to stderr. In `--quiet` mode progress
/// lines are dropped entirely. This keeps the CLI pipeline-native: a script can
/// read structured results off stdout without scraping log text.
enum CLIOut {
    static var json = false
    static var quiet = false

    /// Verbose / progress line. stderr under --json, dropped under --quiet, else stdout.
    static func log(_ s: String) {
        if json { FileHandle.standardError.write(Data((s + "\n").utf8)); return }
        if quiet { return }
        print(s)
    }

    /// Final human summary. Shown on stdout unless --json (which prints JSON instead).
    static func summary(_ s: String) {
        if json { return }
        print(s)
    }

    /// The single machine-readable result. Only emitted (to stdout) under --json.
    static func result<T: Encodable>(_ value: T) {
        guard json else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) {
            print(s)
        }
    }
}

// MARK: - Machine-readable result model

/// Per-channel decoded geometry — the fields the DDR bin itself prints
/// (`BW=.. Col=.. Bk=.. Row=.. CS=.. Die BW=..`), surfaced so callers can do
/// spec verification straight from JSON instead of scraping printf/stderr.
struct ChannelJSON: Encodable {
    let rank: Int          // CS count in this channel (1 or 2)
    let col: Int           // column address bits
    let bank: Int          // bank address bits (3 → 8 banks)
    let cs0Row: Int        // CS0 row address bits
    let cs1Row: Int        // CS1 row address bits (valid when rank==2)
    let busWidthBits: Int  // channel bus width (8/16/32)
    let dieWidthBits: Int  // per-die width (8/16/32)

    init(from c: ChannelGeometry) {
        rank = c.rank; col = c.col; bank = c.bank
        cs0Row = c.cs0Row; cs1Row = c.cs1Row
        busWidthBits = c.busWidthBits; dieWidthBits = c.dieWidthBits
    }
}

struct DetectJSON: Encodable {
    let type: String?
    let capacityMB: Int
    let channels: Int
    let sysRegVersion: Int
    let csPerDie: Int
    let geometry: [ChannelJSON]
    let cfg: String?
    let tier: String
    let candidates: Int

    /// Build from a `DetectOutcome`; `cfg` is the matched soldering cfg name (or nil).
    static func from(_ out: DetectOutcome, cfg: String?) -> DetectJSON {
        DetectJSON(type: out.geometry.dramType?.displayName,
                   capacityMB: out.geometry.totalSizeMB,
                   channels: out.geometry.numChannels,
                   sysRegVersion: out.geometry.sysRegVersion,
                   csPerDie: out.geometry.csPerDie,
                   geometry: out.geometry.channels.map(ChannelJSON.init(from:)),
                   cfg: cfg,
                   tier: tierString(out.matchTier),
                   candidates: out.candidates.count)
    }
}

struct SolderJSON: Encodable {
    let pass: Bool
    let outcome: String
    let state: String
    let cfg: String
    let bootSucceeded: Bool
    /// Device USB printf (INFO_PRINTF, framing stripped), embedded so the JSON
    /// is self-contained (逐项 DQS/DQ/DM/CA/CS/ZQ 检查过程 + 结果).
    let log: String?
}

struct EyescanJSON: Encodable {
    let go: Bool
    let bytes: Int
    /// Full eye-scan transcript captured over USB, embedded so the JSON is self-contained.
    let transcript: String
}

struct CLIResult: Encodable {
    var soc: String
    var pid: String
    var device: String
    var detect: DetectJSON?
    var solder: SolderJSON?
    var eyescan: EyescanJSON?
    var rebootedToMaskrom: Bool?
    var ok: Bool
    var error: String?
    var elapsedMs: Int
}

func tierString(_ t: CfgAutoSelect.MatchTier) -> String {
    switch t {
    case .uniqueByCoarse: return "uniqueByCoarse"
    case .uniqueByTieBreak: return "uniqueByTieBreak"
    case .ambiguous: return "ambiguous"
    case .none: return "none"
    }
}

/// Eye-scan PASS verdict — mirrors the GUI's `eyescanVerdict` (MainViewModel).
/// Completion alone is NOT pass: the firmware prints one `all result:` summary
/// line per channel (pass / `  fail`) after scanning every DQ. Pass requires the
/// done marker AND at least one `all result:` line AND every such line == pass.
/// (The old check only looked for the done marker, so a failed eye still "GO"ed.)
func eyescanGo(_ transcript: String) -> Bool {
    guard transcript.contains("all dq eye scan done") else { return false }
    let resultLines = transcript
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.contains("all result:") }
    return !resultLines.isEmpty && resultLines.allSatisfy { $0.contains("pass") }
}

func printUsageAndExit() -> Never {
    let usage = """
    Rockchip DDR Test Utility CLI

    Three DDR checks (run each on a board in Maskrom; each returns to maskrom when done).
    Pass --json for one machine-readable object on stdout (verdict + full device output embedded):
      --detect  [--device-id <id>] [--detect-cfg <detect.cfg>]
                          DDR 自动探测 — probe DDR geometry (type/capacity/channels/CS +
                          per-channel rank/col/bank/row/busWidth/dieWidth) and match a cfg.
      --solder  [--device-id <id>]
                          焊接检测 — detect→soldering test on one transport, then reboot.
                          Device USB printf embedded in JSON as solder.log.
      --eyescan [--device-id <id>] [--eye-timeout <s>]
                          DQ 眼图 — eye-scan via the SoC's packaged DDR眼图.cfg.
                          Verdict = scan completed AND all `all result:` lines pass.
                          Full transcript embedded in JSON as eyescan.transcript.

    Other:
      --list                          list connected Rockchip devices
      --cfg <cfg_path> [--repeat N]   run a specific cfg (diagnostic)
      --probe-bulk                    bulk-transfer probe (diagnostic)

    Global options:
      --json          emit one JSON object on stdout; all human logs go to stderr
      --quiet         suppress progress lines (final summary still shown unless --json)
      --help, -h      show this help

    Exit codes:
      0  success — the requested check passed
      1  error   — no device / parse / transport / unsupported SoC
      2  fail    — soldering FAILED, eye-scan not PASS, or detect found no unique cfg

    Examples:
      RockchipDDRTestUtilityCLI --list
      RockchipDDRTestUtilityCLI --detect  --json
      RockchipDDRTestUtilityCLI --solder  --json
      RockchipDDRTestUtilityCLI --eyescan --json
    """
    print(usage)
    Foundation.exit(0)
}

@main
struct RockchipDDRTestUtilityCLI {
    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffer so piped progress shows live
        // Single-file fallback: if no DDRTestFiles/ is found on disk, extract the
        // compiled-in cfg library. Consulted only after makeDefaultRootURL's disk
        // probes, so a real on-disk directory still wins (see EmbeddedCfgs).
        CfgRepository.embeddedRootProvider = { EmbeddedCfgs.rootURL() }
        var jsonMode = false
        do {
            let args = try CLIArguments.parse(CommandLine.arguments)
            CLIOut.json = args.json
            CLIOut.quiet = args.quiet
            jsonMode = args.json
            let transport = try RkUsbTransportLibusb()
            let needsManualDeviceSelection = args.listOnly || args.probeBulk
            let devices: [UsbDevice]
            if needsManualDeviceSelection {
                devices = try transport.discoverDevices()
                CLIOut.log("Discovered \(devices.count) Rockchip device(s)")
                for (idx, d) in devices.enumerated() {
                    CLIOut.log("[\(idx)] id=\(d.deviceID) vid=0x\(hex16(d.vendorID)) pid=0x\(hex16(d.productID)) name=\(d.productName)")
                }
            } else {
                devices = []
            }

            if args.listOnly {
                return
            }

            if args.probeBulk {
                guard let device = chooseDevice(from: devices, selectedDeviceID: args.selectedDeviceID) else {
                    throw DDRToolError.noDevice
                }
                try transport.open(device: device)
                let dummy = CfgItem(name: "probe", pathHint: nil, nameOffset: 0, payloadOffset: 0, payloadLength: 16)
                let payload = Data(repeating: 0, count: 16)
                try transport.downloadItem(item: dummy, payload: payload, address: 0)
                try transport.close()
                CLIOut.log("Probe bulk transfer: OK")
                return
            }

            if args.eyescan {
                try await runEyescan(args: args)
                return
            }

            if args.detect {
                try await runDetect(args: args)
                return
            }

            if args.solder {
                try await runSolder(args: args)
                return
            }

            guard let cfgPath = args.cfgPath else {
                throw DDRToolError.invalidFormat("--cfg is required unless --list is used")
            }

            // Repeat-test harness mirroring MainViewModel.startTest: one
            // persistent transport + engine across all runs, held open via
            // keepTransportOpen (re-opening after boot re-issues
            // SET_CONFIGURATION and stalls the booted firmware's bulk endpoint).
            // `deviceNeedsBoot` clears only after run 1's real boot, so runs
            // 2..N pass skipBoot=true — the exact path of repeated GUI clicks.
            // (No idle keep-alive is needed here: --repeat runs are immediate,
            // with no gap between runs for macOS to suspend the pipe.)
            let runTransport = try RkUsbTransportLibusb()
            let engine = TestExecutionEngine(parser: CfgBinaryParser(), transport: runTransport) { entry in
                CLIOut.log("[\(entry.level.rawValue)] \(entry.code) \(entry.message)")
            }
            var deviceNeedsBoot = true
            var anyFailed = false
            var lastResult: ExecutionResult?
            let lastCfgDisplay = (cfgPath as NSString).lastPathComponent
            for run in 1...args.repeatCount {
                let isLast = (run == args.repeatCount)
                let keepOpen = args.repeatCount > 1 && !isLast
                CLIOut.log("\n=== Run \(run)/\(args.repeatCount) — skipBoot: \(!deviceNeedsBoot)  keepTransportOpen: \(keepOpen) ===")
                let result = await engine.run(
                    cfgPath: cfgPath,
                    selectedDeviceID: args.selectedDeviceID,
                    skipBoot: !deviceNeedsBoot,
                    keepTransportOpen: keepOpen
                )
                if result.bootSucceeded {
                    deviceNeedsBoot = false
                }
                lastResult = result
                CLIOut.log("Run \(run) → outcome: \(result.outcome.rawValue), state: \(result.state.rawValue), bootSucceeded: \(result.bootSucceeded)")
                if result.outcome == .failed {
                    anyFailed = true
                }
            }

            CLIOut.summary("\n=== Summary: \(anyFailed ? "SOME RUNS FAILED" : "ALL \(args.repeatCount) RUNS PASSED") ===")
            if args.json, let r = lastResult {
                let dev = r.selectedDevice
                let soc = dev.flatMap { DetectProfiles.forPID($0.productID)?.soc } ?? dev?.socName ?? ""
                var out = CLIResult(soc: soc,
                                    pid: dev.map { "0x" + hex16($0.productID) } ?? "",
                                    device: dev?.productName ?? "",
                                    detect: nil,
                                    solder: SolderJSON(pass: !anyFailed, outcome: r.outcome.rawValue,
                                                       state: r.state.rawValue, cfg: lastCfgDisplay,
                                                       bootSucceeded: r.bootSucceeded,
                                                       log: ResultLogWriter().render(result: r, sourceCfgPath: lastCfgDisplay)),
                                    eyescan: nil, rebootedToMaskrom: nil,
                                    ok: !anyFailed, error: nil, elapsedMs: 0)
                out.elapsedMs = 0
                CLIOut.result(out)
            }
            if anyFailed {
                Foundation.exit(2)
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            if jsonMode {
                CLIOut.result(CLIResult(soc: "", pid: "", device: "", detect: nil, solder: nil,
                                        eyescan: nil, rebootedToMaskrom: nil, ok: false,
                                        error: error.localizedDescription, elapsedMs: 0))
            }
            Foundation.exit(1)
        }
    }

    /// EYE-SCAN, driven by the SoC's packaged `DDR眼图.cfg` — same shape as `--detect` / `--cfg`.
    /// Discover the device → PID→SoC → locate the cfg → extract payloads (DTT/item/trainonly/reboot +
    /// item base) → run. No per-bin flags: everything comes from the packaged cfg.
    static func runEyescan(args: CLIArguments) async throws {
        let transport = try RkUsbTransportLibusb()
        let devices = try transport.discoverDevices()
        guard let device = chooseDevice(from: devices, selectedDeviceID: args.selectedDeviceID) else {
            throw DDRToolError.noDevice
        }
        let soc = DetectProfiles.forPID(device.productID)?.soc ?? device.socName ?? ""
        CLIOut.log("Device: \(device.productName) soc=\(soc) pid=0x\(hex16(device.productID))")

        let root = CfgRepository.makeDefaultRootURL()
        guard let cfgURL = CfgRepository(rootURL: root).eyescanCfgURL(forSoc: soc) else {
            throw DDRToolError.transportError("no eye-scan cfg (…眼图.cfg) found for \(soc) under \(root.path)")
        }
        let plan = try CfgBinaryParser().parse(url: cfgURL)
        guard let p = plan.eyescanPayloads() else {
            throw DDRToolError.transportError("\(cfgURL.lastPathComponent) is not an eye-scan cfg (missing Boot/eyescan)")
        }
        CLIOut.log("Eye-scan cfg: \(cfgURL.lastPathComponent)")
        CLIOut.log("  DTT \(p.dtt.count)B + item \(p.item.count)B"
            + (p.trainOnly.isEmpty ? "" : " + trainonly \(p.trainOnly.count)B")
            + (p.reboot.map { " + reboot \($0.count)B" } ?? "")
            + " @0x\(String(p.itemBase, radix: 16))")

        let start = Date()
        let box = ProgressBox()
        let transcript = try await EyescanRunner().run(
            transport: transport, device: device,
            ddrBin: p.trainOnly, ddrTestTool: p.dtt, itemBin: p.item,
            itemBase: p.itemBase, timeout: args.eyescanTimeout, rebootBin: p.reboot,
            onProgress: { chunk in box.note(chunk, since: start) })
        try? transport.close()

        let pass = eyescanGo(transcript)
        CLIOut.summary("\n=== EYE-SCAN SUMMARY ===")
        CLIOut.summary("  bytes captured : \(transcript.utf8.count)")
        CLIOut.summary("  verdict        : \(pass ? "PASS — all DQ eye margins pass" : "FAIL — a DQ eye failed or the scan did not complete")  (done + all result: pass)")

        if args.json {
            let soc2 = DetectProfiles.forPID(device.productID)?.soc ?? soc
            CLIOut.result(CLIResult(soc: soc2, pid: "0x" + hex16(device.productID),
                                    device: device.productName, detect: nil, solder: nil,
                                    eyescan: EyescanJSON(go: pass, bytes: transcript.utf8.count, transcript: transcript),
                                    rebootedToMaskrom: nil, ok: pass, error: nil,
                                    elapsedMs: Int(Date().timeIntervalSince(start) * 1000)))
        }
        if !pass { Foundation.exit(2) }
    }

    /// Thread-safe progress heartbeat for the streaming drain.
    final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = 0
        private var nextBeat = 5.0
        private let ph: FileHandle?
        init(partialPath: String = "/tmp/eyescan_partial.txt") {
            FileManager.default.createFile(atPath: partialPath, contents: nil)
            ph = try? FileHandle(forWritingTo: URL(fileURLWithPath: partialPath))
        }
        func note(_ chunk: String, since start: Date) {
            lock.lock(); defer { lock.unlock() }
            bytes += chunk.utf8.count
            if let d = chunk.data(using: .utf8) { ph?.write(d) }   // incremental capture (survives a kill)
            let el = Date().timeIntervalSince(start)
            if el >= nextBeat {
                CLIOut.log("    [\(Int(el))s] \(bytes) B captured")
                nextBeat += 5.0
            }
        }
    }

    static func runDetect(args: CLIArguments) async throws {
        let start = Date()
        let transport = try RkUsbTransportLibusb()
        let devices = try transport.discoverDevices()
        guard let device = chooseDevice(from: devices, selectedDeviceID: args.selectedDeviceID) else {
            throw DDRToolError.noDevice
        }
        CLIOut.log("Device: \(device.productName) soc=\(device.socName ?? "?") pid=0x\(hex16(device.productID))")

        let root = CfgRepository.makeDefaultRootURL()
        let socName = DetectProfiles.forPID(device.productID)?.soc ?? device.socName ?? ""
        let socFiles = ((try? CfgRepository(rootURL: root).discoverTestFiles()) ?? [])
            .filter { $0.socName == socName }

        // The self-contained detect cfg (rkbin DDR bin + Boot + osregdump +
        // reboot) now lives in the SoC's DDRTestFiles dir alongside the real
        // test cfgs. Default there; --detect-cfg overrides the directory.
        let resourcesDir = args.detectCfgPath.map { URL(fileURLWithPath: ($0 as NSString).deletingLastPathComponent) }
            ?? root.appendingPathComponent(socName)

        let detector = DdrDetector(resourcesDir: resourcesDir)
        let out = try await detector.detect(transport: transport, device: device, socFiles: socFiles)

        CLIOut.log("\n=== OS_REG (raw) ===")
        for (i, w) in out.rawOsReg.enumerated() {
            CLIOut.log(String(format: "  OS_REG%-2d = 0x%08X", i, w))
        }
        CLIOut.summary("\n=== Detected geometry ===")
        CLIOut.summary("  \(out.geometry.summary())  rebootedToMaskrom: \(out.rebootedToMaskrom)")

        // Detection succeeds ONLY on an exact (type + capacity + CS) match. Empty
        // ⇒ no cfg matches the geometry (config not in library, or DDR init failed
        // and the geometry is garbage) ⇒ NOT a successful detection.
        let cands = out.candidates
        CLIOut.summary("\n=== Exact-match soldering-test cfgs (\(device.socName ?? "?")) ===")
        if cands.isEmpty {
            CLIOut.summary("  (none)\n\nDetection FAILED: no cfg exactly matches the detected geometry.")
            CLIOut.summary("DDR may be uninitialized/defective, or this config isn't in the library — select a cfg manually.")
        } else {
            for c in cands.prefix(6) {
                let t = c.dramType?.displayName ?? "?"
                CLIOut.summary(String(format: "  %@  (%@ %dMB %dCS)", c.entry.displayName, t, c.sizeMB, c.csCount))
            }
            if cands.count == 1 {
                CLIOut.summary("\nAuto-select: \(cands[0].entry.relativePath)")
            } else {
                CLIOut.summary("\nTop: \(cands[0].entry.relativePath)")
                CLIOut.summary("Multiple cfgs share this exact (type + capacity + CS) — they differ only in die composition — confirm from the list.")
            }
        }

        if args.json {
            let matched = CfgAutoSelect.firstAvailable(out.candidates, in: socFiles)
            CLIOut.result(CLIResult(soc: socName, pid: "0x" + hex16(device.productID),
                                    device: device.productName,
                                    detect: DetectJSON.from(out, cfg: matched?.displayName),
                                    solder: nil, eyescan: nil,
                                    rebootedToMaskrom: out.rebootedToMaskrom,
                                    ok: matched != nil, error: nil,
                                    elapsedMs: Int(Date().timeIntervalSince(start) * 1000)))
        }
    }

    /// detect → test on ONE transport, then reboot to bootrom.
    static func runSolder(args: CLIArguments) async throws {
        let transport = try RkUsbTransportLibusb()
        let devices = try transport.discoverDevices()
        guard let device = chooseDevice(from: devices, selectedDeviceID: args.selectedDeviceID) else {
            throw DDRToolError.noDevice
        }
        CLIOut.log("Device: \(device.productName) soc=\(device.socName ?? "?") pid=0x\(hex16(device.productID))")

        let root = CfgRepository.makeDefaultRootURL()
        let socName = DetectProfiles.forPID(device.productID)?.soc ?? device.socName ?? ""
        let socFiles = ((try? CfgRepository(rootURL: root).discoverTestFiles()) ?? [])
            .filter { $0.socName == socName }
        let resourcesDir = args.detectCfgPath.map { URL(fileURLWithPath: ($0 as NSString).deletingLastPathComponent) }
            ?? root.appendingPathComponent(socName)

        // ── detect WITHOUT reboot: keeps the DDR Test Tool Boot resident + the
        //    transport open. Steps unchanged; only the ④ reboot is skipped.
        let detector = DdrDetector(resourcesDir: resourcesDir)
        let out = try await detector.detect(transport: transport, device: device,
                                            socFiles: socFiles, reboot: false)
        CLIOut.log("\n=== Detected: \(out.geometry.summary()) ===")
        guard let matched = CfgAutoSelect.firstAvailable(out.candidates, in: socFiles) else {
            CLIOut.summary("No exact-match cfg — cannot run test. Candidates: \(out.candidates.count)")
            try? transport.close()
            if args.json {
                CLIOut.result(CLIResult(soc: socName, pid: "0x" + hex16(device.productID),
                                        device: device.productName,
                                        detect: DetectJSON.from(out, cfg: nil),
                                        solder: nil, eyescan: nil, rebootedToMaskrom: nil,
                                        ok: false, error: "detect-no-unique-cfg", elapsedMs: 0))
            }
            Foundation.exit(2)
        }
        CLIOut.log("Matched cfg: \(matched.relativePath)")

        // ── test on the SAME transport with skipBoot: reuse the resident Boot
        //    (no downloadBoot, no reboot). This is the crux the experiment tests.
        CLIOut.log("\n=== Running test with skipBoot on the resident Boot (no reboot) ===")
        let engine = TestExecutionEngine(parser: CfgBinaryParser(), transport: transport) { entry in
            CLIOut.log("[\(entry.level.rawValue)] \(entry.code) \(entry.message)")
        }
        let result = await engine.run(
            cfgPath: matched.absolutePath,
            selectedDeviceID: args.selectedDeviceID,
            skipBoot: true,
            keepTransportOpen: true   // keep open so we can reboot to bootrom below
        )
        CLIOut.summary("\n=== detect→test result: outcome=\(result.outcome.rawValue) state=\(result.state.rawValue) bootSucceeded=\(result.bootSucceeded) ===")

        // Return the device to a clean bootrom. The CLI is one-shot with no persistent keep-alive
        // handle (unlike the GUI), so leaving it in the resident test-firmware state is fragile —
        // reboot so the next operation starts from maskrom. Runs the SoC's detect-cfg reboot payload.
        let rebooted = await detector.rebootToMaskrom(transport: transport, device: device)
        CLIOut.summary("=== reboot to bootrom: \(rebooted ? "OK (re-enumerated in maskrom)" : "sent") ===")

        let solderPass = (result.outcome == .passed)
        if args.json {
            CLIOut.result(CLIResult(soc: socName, pid: "0x" + hex16(device.productID),
                                    device: device.productName,
                                    detect: DetectJSON.from(out, cfg: matched.displayName),
                                    solder: SolderJSON(pass: solderPass, outcome: result.outcome.rawValue,
                                                       state: result.state.rawValue, cfg: matched.displayName,
                                                       bootSucceeded: result.bootSucceeded,
                                                       log: ResultLogWriter().render(result: result, sourceCfgPath: matched.absolutePath)),
                                    eyescan: nil, rebootedToMaskrom: rebooted,
                                    ok: solderPass, error: nil, elapsedMs: 0))
        }
        if !solderPass { Foundation.exit(2) }
    }

    private static func hex16(_ value: UInt16) -> String {
        String(format: "%04X", value)
    }

    private static func chooseDevice(from devices: [UsbDevice], selectedDeviceID: String?) -> UsbDevice? {
        if devices.isEmpty {
            return nil
        }
        if let selectedDeviceID {
            return devices.first(where: { $0.deviceID == selectedDeviceID })
        }
        return devices.first
    }
}
