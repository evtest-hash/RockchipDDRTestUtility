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
    /// How many times to run the full cfg in one process. >1 exercises the
    /// repeat-test / boot-skip path: the first run boots, and subsequent runs
    /// pass `skipBoot: true` (mirroring MainViewModel's `deviceNeedsBoot`
    /// latch, cleared only after `bootSucceeded`), exactly like clicking
    /// "start test" repeatedly in the GUI without re-plugging.
    var repeatCount: Int = 1
    /// EYE-SCAN: 3-step capture. The train-only eye-scan bin (path here) trains
    /// the PHY and DETECTS geometry on-device; then the DDR Test Tool (resident
    /// 0x80 service); then the relocated eye-scan item. No host geometry params.
    var eyescanDdrBin: String?
    // Defaults are RK3568's shipped-equivalent bins (fast DTT + return-status item); every SoC
    // overrides via --eye-dtt/--eye-item. (Pre-reorg paths tools/ddr-eyescan/{re,reloc}/ are gone.)
    var eyescanItemPath = "tools/ddr-eyescan/rk3568/out/eyescan_item.bin"
    var eyescanDttPath = "tools/ddr-eyescan/rk3568/out/dtt_fast.bin"
    var eyescanOut = "/tmp/eyescan.txt"
    /// Item download base + end-marker — per-SoC. RK3568=0xFDCC4000; RK3576=0x3FF84000; RK3588=0xFF004000.
    /// Overridable so the same 3-step driver runs other SoCs' items / diagnostic probes.
    var eyescanItemBase: UInt32 = 0xFDCC_4000
    var eyescanMarker = "all dq eye scan done"
    /// Optional reboot payload run after the scan → device auto-returns to maskrom (no replug).
    var eyescanReboot: String?

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
                idx += 1
                guard idx < argv.count else {
                    throw DDRToolError.invalidFormat("Missing value for --eyescan (standard DDR bin path)")
                }
                args.eyescanDdrBin = argv[idx]
            case "--eye-item":
                idx += 1; guard idx < argv.count else { throw DDRToolError.invalidFormat("Missing value for --eye-item") }
                args.eyescanItemPath = argv[idx]
            case "--eye-dtt":
                idx += 1; guard idx < argv.count else { throw DDRToolError.invalidFormat("Missing value for --eye-dtt") }
                args.eyescanDttPath = argv[idx]
            case "--eye-out":
                idx += 1; guard idx < argv.count else { throw DDRToolError.invalidFormat("Missing value for --eye-out") }
                args.eyescanOut = argv[idx]
            case "--eye-item-base":
                idx += 1
                guard idx < argv.count,
                      let v = UInt32(argv[idx].replacingOccurrences(of: "0x", with: ""), radix: 16)
                else { throw DDRToolError.invalidFormat("Missing/invalid --eye-item-base (hex)") }
                args.eyescanItemBase = v
            case "--eye-marker":
                idx += 1; guard idx < argv.count else { throw DDRToolError.invalidFormat("Missing value for --eye-marker") }
                args.eyescanMarker = argv[idx]
            case "--eye-reboot":
                idx += 1; guard idx < argv.count else { throw DDRToolError.invalidFormat("Missing value for --eye-reboot") }
                args.eyescanReboot = argv[idx]
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

func printUsageAndExit() -> Never {
    let usage = """
    Rockchip DDR Test Utility CLI
      --list
      --probe-bulk [--device-id <id>]
      --cfg <cfg_path> [--device-id <id>] [--output-log <txt_path>] [--repeat N]
      --detect [--detect-cfg <detect.cfg>] [--device-id <id>]
      --detect-then-test [--device-id <id>]   (experiment: detect→test, no reboot)
      --eyescan <train_only_bin> [--eye-item <bin> --eye-dtt <bin> --eye-out <txt>]
                          (3-step eye-scan capture over USB 0x80;
                           geometry auto-detected on-device, no host params)

    Examples:
      swift run RockchipDDRTestUtilityCLI --list
      swift run RockchipDDRTestUtilityCLI --probe-bulk
      swift run RockchipDDRTestUtilityCLI --cfg "/path/to/test.cfg"
      swift run RockchipDDRTestUtilityCLI --detect   # RK3568 DDR auto-detect spike
      swift run RockchipDDRTestUtilityCLI --cfg "/path/to/test.cfg" --output-log "/tmp/ddr_result.txt"
      swift run RockchipDDRTestUtilityCLI --cfg "/path/to/test.cfg" --repeat 3   # boot once, then re-test
    """
    print(usage)
    Foundation.exit(0)
}

@main
struct RockchipDDRTestUtilityCLI {
    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffer so piped progress shows live
        do {
            let args = try CLIArguments.parse(CommandLine.arguments)
            let transport = try RkUsbTransportLibusb()
            let needsManualDeviceSelection = args.listOnly || args.probeBulk
            let devices: [UsbDevice]
            if needsManualDeviceSelection {
                devices = try transport.discoverDevices()
                print("Discovered \(devices.count) Rockchip device(s)")
                for (idx, d) in devices.enumerated() {
                    print("[\(idx)] id=\(d.deviceID) vid=0x\(hex16(d.vendorID)) pid=0x\(hex16(d.productID)) name=\(d.productName)")
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
                print("Probe bulk transfer: OK")
                return
            }

            if args.eyescanDdrBin != nil {
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
                print("[\(entry.level.rawValue)] \(entry.code) \(entry.message)")
            }
            var deviceNeedsBoot = true
            var anyFailed = false
            for run in 1...args.repeatCount {
                let isLast = (run == args.repeatCount)
                let keepOpen = args.repeatCount > 1 && !isLast
                print("\n=== Run \(run)/\(args.repeatCount) — skipBoot: \(!deviceNeedsBoot)  keepTransportOpen: \(keepOpen) ===")
                let result = await engine.run(
                    cfgPath: cfgPath,
                    selectedDeviceID: args.selectedDeviceID,
                    skipBoot: !deviceNeedsBoot,
                    keepTransportOpen: keepOpen
                )
                if result.bootSucceeded {
                    deviceNeedsBoot = false
                }
                print("Run \(run) → outcome: \(result.outcome.rawValue), state: \(result.state.rawValue), bootSucceeded: \(result.bootSucceeded)")
                if result.outcome == .failed {
                    anyFailed = true
                }

                if let out = args.outputLogPath {
                    let suffix = args.repeatCount > 1 ? ".run\(run)" : ""
                    let url = URL(fileURLWithPath: out + suffix)
                    let writer = ResultLogWriter()
                    _ = try writer.write(result: result, sourceCfgPath: cfgPath, outputURL: url)
                    print("Saved log: \(url.path)")
                }
            }

            print("\n=== Summary: \(anyFailed ? "SOME RUNS FAILED" : "ALL \(args.repeatCount) RUNS PASSED") ===")
            if anyFailed {
                Foundation.exit(2)
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    /// EYE-SCAN: 3-step capture streaming the eye-scan report over USB 0x80.
    /// The exact stage semantics are PER-SoC (the download mechanics are identical):
    ///   • RK3568  (3-part model): ① train-only bin (trains DDR + detects geometry) →
    ///     ② DDR Test Tool (resident 2-core USB svc) → ③ relocated measurement core.
    ///   • RK3576/RK3588 (PATH ②, monolithic-bin family): ① the WHOLE eyescan bin runs
    ///     as a fresh boot (self-trains + scans) with its putc redirected to capture the
    ///     output into free SRAM → ② native DDR Test Tool → ③ a small item that reads the
    ///     captured buffer, filters it, and relays the kept lines over the DTT ring.
    /// Either way: NO host geometry — rank/type/width/freq/margins are all decided
    /// on-device; the item reads NOTHING from the host.
    static func runEyescan(args: CLIArguments) async throws {
        guard let ddrBinPath = args.eyescanDdrBin else { throw DDRToolError.invalidFormat("--eyescan needs a DDR bin") }
        // "none" → skip stage① (used by an eyescan-item that self-trains: DTT + item only).
        let ddrBin = ddrBinPath == "none" ? Data() : try Data(contentsOf: URL(fileURLWithPath: ddrBinPath))
        let dtt = try Data(contentsOf: URL(fileURLWithPath: args.eyescanDttPath))
        let itemBin = try Data(contentsOf: URL(fileURLWithPath: args.eyescanItemPath))
        print("Eye-scan 3-step over USB 0x80 (geometry auto-detected on-device, no host params):")
        print("  ① stage-1 0x471 bin (on-device DDR init/train/scan): \(ddrBinPath) (\(ddrBin.count) B)")
        print("  ② DDR Test Tool     (resident 2-core USB 0x80 svc) : \(args.eyescanDttPath) (\(dtt.count) B)")
        print("  ③ stage-3 item      (bulk-run; streams 0x80 report): \(args.eyescanItemPath) (\(itemBin.count) B)")

        let transport = try RkUsbTransportLibusb()
        let devices = try transport.discoverDevices()
        guard let device = chooseDevice(from: devices, selectedDeviceID: args.selectedDeviceID) else {
            throw DDRToolError.noDevice
        }
        print("Device: \(device.productName) pid=0x\(hex16(device.productID)) id=\(device.deviceID)")

        let runner = EyescanRunner()
        let start = Date()
        let box = ProgressBox()
        let transcript = try await runner.run(
            transport: transport, device: device,
            ddrBin: ddrBin, ddrTestTool: dtt, itemBin: itemBin,
            itemBase: args.eyescanItemBase,
            timeout: 120,
            rebootBin: args.eyescanReboot.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) },
            onProgress: { chunk in box.note(chunk, since: start) })
        try? transport.close()
        try? transcript.write(toFile: args.eyescanOut, atomically: true, encoding: .utf8)

        let done = transcript.contains(args.eyescanMarker)
        print("\n=== EYE-SCAN SUMMARY ===")
        print("  bytes captured : \(transcript.utf8.count)")
        print("  lines          : \(transcript.split(separator: "\n", omittingEmptySubsequences: false).count)")
        print("  saw done marker: \(done)")
        print("  output written : \(args.eyescanOut)")
        print("  VERDICT: \(done ? "GO — full eye-scan log captured over USB 0x80" : "incomplete — inspect \(args.eyescanOut)")")
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
                print("    [\(Int(el))s] \(bytes) B captured")
                nextBeat += 5.0
            }
        }
    }

    static func runDetect(args: CLIArguments) async throws {
        let transport = try RkUsbTransportLibusb()
        let devices = try transport.discoverDevices()
        guard let device = chooseDevice(from: devices, selectedDeviceID: args.selectedDeviceID) else {
            throw DDRToolError.noDevice
        }
        print("Device: \(device.productName) soc=\(device.socName ?? "?") pid=0x\(hex16(device.productID))")

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

        print("\n=== OS_REG (raw) ===")
        for (i, w) in out.rawOsReg.enumerated() {
            print(String(format: "  OS_REG%-2d = 0x%08X", i, w))
        }
        print("\n=== Detected geometry ===")
        print("  \(out.geometry.summary())  rebootedToMaskrom: \(out.rebootedToMaskrom)")

        // Detection succeeds ONLY on an exact (type + capacity + CS) match. Empty
        // ⇒ no cfg matches the geometry (config not in library, or DDR init failed
        // and the geometry is garbage) ⇒ NOT a successful detection.
        let cands = out.candidates
        print("\n=== Exact-match soldering-test cfgs (\(device.socName ?? "?")) ===")
        if cands.isEmpty {
            print("  (none)\n\nDetection FAILED: no cfg exactly matches the detected geometry.")
            print("DDR may be uninitialized/defective, or this config isn't in the library — select a cfg manually.")
        } else {
            for c in cands.prefix(6) {
                let t = c.dramType?.displayName ?? "?"
                print(String(format: "  %@  (%@ %dMB %dCS)", c.entry.displayName, t, c.sizeMB, c.csCount))
            }
            if cands.count == 1 {
                print("\nAuto-select: \(cands[0].entry.relativePath)")
            } else {
                print("\nTop: \(cands[0].entry.relativePath)")
                print("Multiple cfgs share this exact (type + capacity + CS) — they differ only in die composition — confirm from the list.")
            }
        }
    }

    /// EXPERIMENT (Step 2): detect → test on ONE transport, no reboot.
    static func runDetectThenTest(args: CLIArguments) async throws {
        let transport = try RkUsbTransportLibusb()
        let devices = try transport.discoverDevices()
        guard let device = chooseDevice(from: devices, selectedDeviceID: args.selectedDeviceID) else {
            throw DDRToolError.noDevice
        }
        print("Device: \(device.productName) soc=\(device.socName ?? "?") pid=0x\(hex16(device.productID))")

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
        print("\n=== Detected: \(out.geometry.summary()) ===")
        guard let matched = CfgAutoSelect.firstAvailable(out.candidates, in: socFiles) else {
            print("No exact-match cfg — cannot run test. Candidates: \(out.candidates.count)")
            try? transport.close()
            return
        }
        print("Matched cfg: \(matched.relativePath)")

        // ── test on the SAME transport with skipBoot: reuse the resident Boot
        //    (no downloadBoot, no reboot). This is the crux the experiment tests.
        print("\n=== Running test with skipBoot on the resident Boot (no reboot) ===")
        let engine = TestExecutionEngine(parser: CfgBinaryParser(), transport: transport) { entry in
            print("[\(entry.level.rawValue)] \(entry.code) \(entry.message)")
        }
        let result = await engine.run(
            cfgPath: matched.absolutePath,
            selectedDeviceID: args.selectedDeviceID,
            skipBoot: true,
            keepTransportOpen: false
        )
        print("\n=== detect→test result: outcome=\(result.outcome.rawValue) state=\(result.state.rawValue) bootSucceeded=\(result.bootSucceeded) ===")
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
