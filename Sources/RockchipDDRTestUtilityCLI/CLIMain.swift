import DDRCore
import DDRUSB
import Foundation

struct CLIArguments {
    var cfgPath: String?
    var selectedDeviceID: String?
    var outputLogPath: String?
    var listOnly = false
    var probeBulk = false
    /// DDR auto-detect spike: download the auto-probing rkbin DDR bin (0x471),
    /// run the osregdump probe cfg, read OS_REG over USB, decode + shortlist cfg.
    var detect = false
    var detectCfgPath: String?
    /// EXPERIMENT (Step 2): unified detect→test on ONE transport, no reboot.
    /// detect(reboot:false) leaves the DDR Test Tool Boot resident + transport
    /// open; the matched cfg then runs with skipBoot:true on that same Boot.
    /// Validates that the reboot-to-maskrom step is avoidable (→ dodges the
    /// RK3288 populated-eMMC reboot limitation). Reuses both executors' existing
    /// steps unchanged — only the sequencing differs.
    var detectThenTest = false
    /// AUTO: one-shot factory-line composite — detect → soldering test → eye-scan
    /// → reboot to maskrom, all on the auto-selected cfg. Exits 0 only if the
    /// unique cfg matched AND soldering passed AND the eye-scan reported GO. This
    /// is the automation entry point; pair with `--json` for a machine-readable
    /// result on stdout.
    var auto = false
    /// How many times to run the full cfg in one process. >1 exercises the
    /// repeat-test / boot-skip path: the first run boots, and subsequent runs
    /// pass `skipBoot: true` (mirroring MainViewModel's `deviceNeedsBoot`
    /// latch, cleared only after `bootSucceeded`), exactly like clicking
    /// "start test" repeatedly in the GUI without re-plugging.
    var repeatCount: Int = 1
    /// EYE-SCAN mode: like --detect / --cfg, driven by the SoC's packaged `DDR眼图.cfg` (auto-located
    /// by the connected device's PID → SoC). All payloads (DTT/item/trainonly/reboot) + the item base
    /// come from that cfg — no per-bin flags. `--eye-out`/`--eye-timeout` are run options.
    var eyescan = false
    var eyescanOut = "/tmp/eyescan.txt"
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
            case "--output-log":
                idx += 1
                guard idx < argv.count else {
                    throw DDRToolError.invalidFormat("Missing value for --output-log")
                }
                args.outputLogPath = argv[idx]
            case "--list":
                args.listOnly = true
            case "--probe-bulk":
                args.probeBulk = true
            case "--detect":
                args.detect = true
            case "--detect-then-test":
                args.detectThenTest = true
            case "--auto":
                args.auto = true
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
            case "--eye-out":
                idx += 1; guard idx < argv.count else { throw DDRToolError.invalidFormat("Missing value for --eye-out") }
                args.eyescanOut = argv[idx]
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

struct DetectJSON: Encodable {
    let type: String?
    let capacityMB: Int
    let channels: Int
    let sysRegVersion: Int
    let cfg: String?
    let tier: String
    let candidates: Int
}

struct SolderJSON: Encodable {
    let pass: Bool
    let outcome: String
    let state: String
    let cfg: String
    let bootSucceeded: Bool
}

struct EyescanJSON: Encodable {
    let go: Bool
    let bytes: Int
    let out: String
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

/// Eye-scan GO verdict — the done marker, matching the CLI's shipped check.
func eyescanGo(_ transcript: String) -> Bool {
    transcript.contains("all dq eye scan done")
}

func printUsageAndExit() -> Never {
    let usage = """
    Rockchip DDR Test Utility CLI
      --list
      --probe-bulk [--device-id <id>]
      --cfg <cfg_path> [--device-id <id>] [--output-log <txt_path>] [--repeat N]
      --detect [--detect-cfg <detect.cfg>] [--device-id <id>]
      --detect-then-test [--device-id <id>]   (detect→test on one transport, then reboot)
      --eyescan [--device-id <id>] [--eye-out <txt>] [--eye-timeout <s>]
                          (eye-scan driven by the SoC's packaged DDR眼图.cfg,
                           auto-located by the connected device — like --detect)
      --auto [--device-id <id>] [--eye-out <txt>] [--eye-timeout <s>]
                          (factory one-shot: detect → soldering → eye-scan → reboot)

    Global options:
      --json    emit one JSON object on stdout; all human logs go to stderr
      --quiet   suppress progress lines (final summary still shown unless --json)

    Exit codes:
      0  success — all requested checks passed
      1  error   — no device / parse / transport / unsupported SoC
      2  fail    — a soldering test FAILED or an eye-scan was not GO / no unique cfg

    Examples:
      RockchipDDRTestUtilityCLI --list
      RockchipDDRTestUtilityCLI --detect --json
      RockchipDDRTestUtilityCLI --auto --json --quiet        # factory line, machine output
      RockchipDDRTestUtilityCLI --cfg "/path/to/test.cfg" --output-log "/tmp/ddr_result.txt"
      RockchipDDRTestUtilityCLI --cfg "/path/to/test.cfg" --repeat 3   # boot once, then re-test
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

            if args.auto {
                try await runAuto(args: args)
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

            if args.detectThenTest {
                try await runDetectThenTest(args: args)
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

                if let out = args.outputLogPath {
                    let suffix = args.repeatCount > 1 ? ".run\(run)" : ""
                    let url = URL(fileURLWithPath: out + suffix)
                    let writer = ResultLogWriter()
                    _ = try writer.write(result: result, sourceCfgPath: cfgPath, outputURL: url)
                    CLIOut.log("Saved log: \(url.path)")
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
                                                       bootSucceeded: r.bootSucceeded),
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

    /// AUTO: factory-line one-shot. detect (no reboot, resident Boot) → soldering
    /// test on that Boot → reboot to maskrom → eye-scan on a fresh boot → reboot
    /// to a clean maskrom. Exit 0 only if a unique cfg matched AND soldering
    /// passed AND the eye-scan reported GO; else exit 2. This is exactly the
    /// no-replug chain validated across RK3568/RK3576/RK3588 (2026-07-20).
    static func runAuto(args: CLIArguments) async throws {
        let start = Date()
        let transport = try RkUsbTransportLibusb()
        let devices = try transport.discoverDevices()
        guard let device = chooseDevice(from: devices, selectedDeviceID: args.selectedDeviceID) else {
            throw DDRToolError.noDevice
        }
        let soc = DetectProfiles.forPID(device.productID)?.soc ?? device.socName ?? ""
        let pid = "0x" + hex16(device.productID)
        CLIOut.log("Device: \(device.productName) soc=\(soc) pid=\(pid)")

        let root = CfgRepository.makeDefaultRootURL()
        let socFiles = ((try? CfgRepository(rootURL: root).discoverTestFiles()) ?? [])
            .filter { $0.socName == soc }
        let resourcesDir = args.detectCfgPath.map { URL(fileURLWithPath: ($0 as NSString).deletingLastPathComponent) }
            ?? root.appendingPathComponent(soc)
        let detector = DdrDetector(resourcesDir: resourcesDir)

        var result = CLIResult(soc: soc, pid: pid, device: device.productName,
                               detect: nil, solder: nil, eyescan: nil,
                               rebootedToMaskrom: nil, ok: false, error: nil, elapsedMs: 0)
        func finish(exit code: Int32) -> Never {
            result.elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            CLIOut.result(result)
            Foundation.exit(code)
        }

        // ① detect WITHOUT reboot — keep the Test Tool Boot resident + transport open.
        let out = try await detector.detect(transport: transport, device: device,
                                            socFiles: socFiles, reboot: false)
        let matched = CfgAutoSelect.firstAvailable(out.candidates, in: socFiles)
        result.detect = DetectJSON(type: out.geometry.dramType?.displayName,
                                   capacityMB: out.geometry.totalSizeMB,
                                   channels: out.geometry.numChannels,
                                   sysRegVersion: out.geometry.sysRegVersion,
                                   cfg: matched?.displayName,
                                   tier: tierString(out.matchTier),
                                   candidates: out.candidates.count)
        CLIOut.log("Detected: \(out.geometry.summary()) tier=\(tierString(out.matchTier)) cfg=\(matched?.displayName ?? "none")")

        guard let matched else {
            CLIOut.summary("\n=== AUTO: detect produced no unique cfg (tier=\(tierString(out.matchTier))) — STOP ===")
            try? transport.close()
            result.error = "detect-no-unique-cfg"
            finish(exit: 2)
        }

        // ② soldering test on the resident Boot (skipBoot), keep open for reboot.
        let engine = TestExecutionEngine(parser: CfgBinaryParser(), transport: transport) { entry in
            CLIOut.log("[\(entry.level.rawValue)] \(entry.code) \(entry.message)")
        }
        let solder = await engine.run(cfgPath: matched.absolutePath,
                                      selectedDeviceID: args.selectedDeviceID,
                                      skipBoot: true, keepTransportOpen: true)
        let solderPass = (solder.outcome == .passed)
        result.solder = SolderJSON(pass: solderPass, outcome: solder.outcome.rawValue,
                                   state: solder.state.rawValue, cfg: matched.displayName,
                                   bootSucceeded: solder.bootSucceeded)
        CLIOut.log("Solder: \(solder.outcome.rawValue) (state=\(solder.state.rawValue))")

        // ③ reboot to maskrom so the eye-scan can fresh-boot its own DTT.
        let rebooted = await detector.rebootToMaskrom(transport: transport, device: device)
        result.rebootedToMaskrom = rebooted
        CLIOut.log("reboot to maskrom (post-solder): \(rebooted ? "OK" : "sent")")

        // ④ eye-scan on a fresh transport + re-enumerated device. The post-solder
        //    reboot drops the device and it reappears in maskrom; unlike the
        //    validated two-invocation chain (process teardown gives a natural gap),
        //    here we chain in-process, so POLL for the device to reappear (fresh
        //    libusb context per probe) + settle before the eye-scan boots its DTT.
        var eyeGo = false
        var eyeBytes = 0
        if let eyeCfg = CfgRepository(rootURL: root).eyescanCfgURL(forSoc: soc) {
            var dev2: UsbDevice? = nil
            for _ in 0..<50 {   // up to ~10s
                if let probe = try? RkUsbTransportLibusb(),
                   let d = (try? probe.discoverDevices())?.first(where: { $0.productID == device.productID }) {
                    dev2 = d; break
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if let dev2 {
                try? await Task.sleep(nanoseconds: 500_000_000)   // settle before downloadBoot
                let eyeTransport = try RkUsbTransportLibusb()
                let plan = try CfgBinaryParser().parse(url: eyeCfg)
                if let p = plan.eyescanPayloads() {
                    let box = ProgressBox()
                    let est = Date()
                    let transcript = try await EyescanRunner().run(
                        transport: eyeTransport, device: dev2,
                        ddrBin: p.trainOnly, ddrTestTool: p.dtt, itemBin: p.item,
                        itemBase: p.itemBase, timeout: args.eyescanTimeout, rebootBin: p.reboot,
                        onProgress: { chunk in box.note(chunk, since: est) })
                    try? transcript.write(toFile: args.eyescanOut, atomically: true, encoding: .utf8)
                    eyeGo = eyescanGo(transcript)
                    eyeBytes = transcript.utf8.count
                    _ = await detector.rebootToMaskrom(transport: eyeTransport, device: dev2)
                }
                try? eyeTransport.close()
            } else {
                CLIOut.log("eye-scan: device did not re-enumerate after reboot — skipping")
            }
        } else {
            CLIOut.log("eye-scan: no …眼图.cfg for \(soc) — skipping")
        }
        result.eyescan = EyescanJSON(go: eyeGo, bytes: eyeBytes, out: args.eyescanOut)

        let ok = solderPass && eyeGo
        result.ok = ok
        CLIOut.summary("\n=== AUTO: soc=\(soc)  detect=\(matched.displayName)  solder=\(solder.outcome.rawValue)  eyescan=\(eyeGo ? "GO" : "NO-GO")  →  \(ok ? "OK" : "FAIL") ===")
        finish(exit: ok ? 0 : 2)
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
        try? transcript.write(toFile: args.eyescanOut, atomically: true, encoding: .utf8)

        let done = eyescanGo(transcript)
        CLIOut.summary("\n=== EYE-SCAN SUMMARY ===")
        CLIOut.summary("  bytes captured : \(transcript.utf8.count)")
        CLIOut.summary("  saw done marker: \(done)")
        CLIOut.summary("  output written : \(args.eyescanOut)")
        CLIOut.summary("  VERDICT: \(done ? "GO — full eye-scan log captured over USB 0x80" : "incomplete — inspect \(args.eyescanOut)")")

        if args.json {
            let soc2 = DetectProfiles.forPID(device.productID)?.soc ?? soc
            CLIOut.result(CLIResult(soc: soc2, pid: "0x" + hex16(device.productID),
                                    device: device.productName, detect: nil, solder: nil,
                                    eyescan: EyescanJSON(go: done, bytes: transcript.utf8.count, out: args.eyescanOut),
                                    rebootedToMaskrom: nil, ok: done, error: nil,
                                    elapsedMs: Int(Date().timeIntervalSince(start) * 1000)))
        }
        if !done { Foundation.exit(2) }
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
                                    detect: DetectJSON(type: out.geometry.dramType?.displayName,
                                                       capacityMB: out.geometry.totalSizeMB,
                                                       channels: out.geometry.numChannels,
                                                       sysRegVersion: out.geometry.sysRegVersion,
                                                       cfg: matched?.displayName,
                                                       tier: tierString(out.matchTier),
                                                       candidates: out.candidates.count),
                                    solder: nil, eyescan: nil,
                                    rebootedToMaskrom: out.rebootedToMaskrom,
                                    ok: matched != nil, error: nil,
                                    elapsedMs: Int(Date().timeIntervalSince(start) * 1000)))
        }
    }

    /// detect → test on ONE transport, then reboot to bootrom.
    static func runDetectThenTest(args: CLIArguments) async throws {
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
                                        detect: DetectJSON(type: out.geometry.dramType?.displayName,
                                                           capacityMB: out.geometry.totalSizeMB,
                                                           channels: out.geometry.numChannels,
                                                           sysRegVersion: out.geometry.sysRegVersion,
                                                           cfg: nil, tier: tierString(out.matchTier),
                                                           candidates: out.candidates.count),
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
                                    detect: DetectJSON(type: out.geometry.dramType?.displayName,
                                                       capacityMB: out.geometry.totalSizeMB,
                                                       channels: out.geometry.numChannels,
                                                       sysRegVersion: out.geometry.sysRegVersion,
                                                       cfg: matched.displayName, tier: tierString(out.matchTier),
                                                       candidates: out.candidates.count),
                                    solder: SolderJSON(pass: solderPass, outcome: result.outcome.rawValue,
                                                       state: result.state.rawValue, cfg: matched.displayName,
                                                       bootSucceeded: result.bootSucceeded),
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
