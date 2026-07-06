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
    /// How many times to run the full cfg in one process. >1 exercises the
    /// repeat-test / boot-skip path: the first run boots, and subsequent runs
    /// pass `skipBoot: true` (mirroring MainViewModel's `deviceNeedsBoot`
    /// latch, cleared only after `bootSucceeded`), exactly like clicking
    /// "start test" repeatedly in the GUI without re-plugging.
    var repeatCount: Int = 1

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

            if args.detect {
                try await runDetect(args: args)
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

    /// DDR auto-detect spike (approach A): drive the whole sequence over USB via
    /// cfg + the existing engine — no xrock.
    ///   ① download the auto-probing rkbin DDR bin (control-transfer 0x471) →
    ///      SoC detects DRAM and writes geometry into PMU_GRF OS_REG (survives).
    ///   ② run the osregdump cfg through the normal engine → downloads the DDR
    ///      Test Tool Boot (0x471) + the probe item (bulk 0x02 / RunMemory 0x03).
    ///   ③ the probe reads OS_REG and prints it over the 0x80 printf channel.
    ///   ④ decode SYS_REG → geometry, shortlist the matching soldering-test cfg.
    /// Thin CLI wrapper around `DdrDetector`: pick a device, discover the SoC's
    /// candidate soldering-test cfgs, hand off to the detector for the full
    /// probe → decode → rank → reboot-to-maskrom flow, then print the result.
    /// All retry/orchestration logic now lives in `DdrDetector` (Task 4) — this
    /// is the single call site, replacing the old inline spike.
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
