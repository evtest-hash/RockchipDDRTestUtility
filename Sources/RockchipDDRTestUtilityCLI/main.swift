import DDRCore
import DDRUSB
import Foundation

struct CLIArguments {
    var cfgPath: String?
    var selectedDeviceID: String?
    var outputLogPath: String?
    var listOnly = false
    var probeBulk = false
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

    Examples:
      swift run RockchipDDRTestUtilityCLI --list
      swift run RockchipDDRTestUtilityCLI --probe-bulk
      swift run RockchipDDRTestUtilityCLI --cfg "/path/to/test.cfg"
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
