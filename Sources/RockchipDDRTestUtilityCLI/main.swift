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
    var ddrBinPath: String?
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
            case "--ddr-bin":
                idx += 1
                guard idx < argv.count else {
                    throw DDRToolError.invalidFormat("Missing value for --ddr-bin")
                }
                args.ddrBinPath = argv[idx]
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
      --detect [--ddr-bin <rkbin_ddr.bin>] [--detect-cfg <probe.cfg>] [--device-id <id>]

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
    static func runDetect(args: CLIArguments) async throws {
        let ddrBin = args.ddrBinPath ?? "../rkbin/bin/rk35/rk3568_ddr_1560MHz_v1.25.bin"
        let detectCfg = args.detectCfgPath ?? "tools/ddr-autodetect/rk3568_osregdump.cfg"
        let ddrBinData = try Data(contentsOf: URL(fileURLWithPath: ddrBin))

        let transport = try RkUsbTransportLibusb()
        let devices = try transport.discoverDevices()
        guard let device = chooseDevice(from: devices, selectedDeviceID: args.selectedDeviceID) else {
            throw DDRToolError.noDevice
        }
        print("Device: \(device.productName) soc=\(device.socName ?? "?") pid=0x\(hex16(device.productID))")

        // ① rkbin DDR bin via 0x471 (RC4 auto-decided by PID; RK3568 0x350A skips RC4)
        try transport.open(device: device)
        let ddrItem = CfgItem(name: "ddrbin", payloadOffset: 0, payloadLength: ddrBinData.count)
        print("① download rkbin DDR bin \(ddrBinData.count)B via 0x471: \(ddrBin)")
        try transport.downloadBoot(item: ddrItem, payload: ddrBinData)
        try await Task.sleep(nanoseconds: 1_500_000_000)   // settle: auto-detect + OS_REG write

        // ②③ run the probe cfg on the same open handle (engine won't re-open)
        print("②③ run probe cfg: \(detectCfg)")
        let engine = TestExecutionEngine(parser: CfgBinaryParser(), transport: transport) { entry in
            print("[\(entry.level.rawValue)] \(entry.code) \(entry.message)")
        }
        let result = await engine.run(
            cfgPath: detectCfg,
            selectedDeviceID: device.deviceID,
            skipBoot: false,
            keepTransportOpen: true            // keep handle open to drain trailing printf
        )

        // The probe returns in microseconds, so the engine's single end-of-item
        // drain can race the probe's OS_REG output landing in Boot's printf
        // buffer. The output is buffered, so poll the 0x80 channel a few more
        // times after the run to collect whatever the engine's drain missed.
        var drained = ""
        var emptyStreak = 0
        for _ in 0..<25 {
            if let s = try? transport.readPrintf(), !s.isEmpty {
                drained += "\n" + s
                emptyStreak = 0
            } else {
                emptyStreak += 1
                if emptyStreak >= 5 { break }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        var captured = result.logs.filter { $0.code == "INFO_PRINTF" }.map { $0.message }.joined(separator: "\n") + drained
        var words = OsRegDecoder.parseProbeOutput(captured)

        // The probe's printf races Boot's buffer flush/clear, so a single run can
        // miss it. Re-run the osregdump item — the resident Boot is reused, so no
        // maskrom reset is needed between retries — until the OS_REG block lands.
        let plan = try CfgBinaryParser().parse(url: URL(fileURLWithPath: detectCfg))
        let probeItem = plan.items.first { $0.name.caseInsensitiveCompare("osregdump") == .orderedSame }
        let probePayload = plan.embeddedBins["osregdump"]
        var tries = 0
        while words == nil, tries < 20, let item = probeItem, let pay = probePayload {
            tries += 1
            do {
                try transport.downloadItem(item: item, payload: pay, address: plan.downloadBaseAddress)
                try transport.runItem(item: item, address: plan.downloadBaseAddress)
            } catch { break }
            for _ in 0..<12 {
                if let s = try? transport.readPrintf(), !s.isEmpty { captured += "\n" + s }
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            words = OsRegDecoder.parseProbeOutput(captured)
        }
        if tries > 0 { print("(OS_REG captured after \(tries) retr\(tries == 1 ? "y" : "ies"))") }
        try? transport.close()

        guard let words else {
            fputs("No OSREG block after \(tries) retries. Raw printf:\n\(captured)\n", stderr)
            Foundation.exit(2)
        }

        // ④ decode + shortlist
        print("\n=== OS_REG (raw) ===")
        for (i, w) in words.enumerated() {
            print(String(format: "  OS_REG%-2d = 0x%08X", i, w))
        }
        let geo = OsRegDecoder.decode(words)
        print("\n=== Detected geometry (best-effort — validate vs board) ===")
        print("  \(geo.summary())")

        let root = CfgRepository.makeDefaultRootURL()
        let files = (try? CfgRepository(rootURL: root).discoverTestFiles()) ?? []
        let socFiles = files.filter { $0.socName == (device.socName ?? "") }
        let cands = CfgAutoSelect.rank(geometry: geo, socFiles: socFiles)
        print("\n=== Candidate soldering-test cfgs (\(device.socName ?? "?")), best first ===")
        for c in cands.prefix(6) {
            let t = c.dramType?.displayName ?? "?"
            let cs = c.csCount != 0 ? "\(c.csCount)CS" : "?CS"
            print(String(format: "  [score %3d] %@  (%@ %dMB %@)", c.score, c.entry.displayName, t, c.sizeMB, cs))
        }
        // Auto-select only on a clear, unique winner (type+size+CS all matched and
        // strictly ahead of the runner-up). Otherwise shortlist for confirmation —
        // detect assists, it never silently runs the wrong cfg.
        let lead = cands.count >= 2 ? cands[0].score - cands[1].score : (cands.first?.score ?? 0)
        if let best = cands.first, best.score >= 250, lead >= 20 {
            print("\nAuto-select: \(best.entry.relativePath)")
        } else if let best = cands.first, best.score >= 150 {
            print("\nTop candidate: \(best.entry.relativePath)")
            print("Ambiguous (e.g. LPDDR4 vs LPDDR4X, or CS layout) — confirm from the list above.")
        } else {
            print("\nNo confident match — fall back to manual selection.")
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
