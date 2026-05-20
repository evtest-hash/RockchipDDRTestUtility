import DDRCore
import DDRUSB
import Foundation

struct CLIArguments {
    var cfgPath: String?
    var selectedDeviceID: String?
    var outputLogPath: String?
    var listOnly = false
    var probeBulk = false
    var resetUSB = false

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
            case "--reset-usb":
                args.resetUSB = true
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
      --reset-usb [--device-id <id>]
      --cfg <cfg_path> [--device-id <id>] [--output-log <txt_path>]

    Examples:
      swift run RockchipDDRTestUtilityCLI --list
      swift run RockchipDDRTestUtilityCLI --probe-bulk
      swift run RockchipDDRTestUtilityCLI --reset-usb
      swift run RockchipDDRTestUtilityCLI --cfg "/path/to/test.cfg"
      swift run RockchipDDRTestUtilityCLI --cfg "/path/to/test.cfg" --output-log "/tmp/ddr_result.txt"
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
            let needsManualDeviceSelection = args.listOnly || args.probeBulk || args.resetUSB
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

            if args.resetUSB {
                guard let device = chooseDevice(from: devices, selectedDeviceID: args.selectedDeviceID) else {
                    throw DDRToolError.noDevice
                }
                try transport.reset(device: device)
                print("USB device reset: OK")
                return
            }

            guard let cfgPath = args.cfgPath else {
                throw DDRToolError.invalidFormat("--cfg is required unless --list is used")
            }

            let parser = CfgBinaryParser()
            let writer = ResultLogWriter()
            let engine = TestExecutionEngine(parser: parser, transport: transport) { entry in
                print("[\(entry.level.rawValue)] \(entry.code) \(entry.message)")
            }

            print("Running cfg: \(cfgPath)")
            let result = await engine.run(cfgPath: cfgPath, selectedDeviceID: args.selectedDeviceID)
            print("Final outcome: \(result.outcome.rawValue), state: \(result.state.rawValue)")

            if let out = args.outputLogPath {
                let url = URL(fileURLWithPath: out)
                _ = try writer.write(result: result, sourceCfgPath: cfgPath, outputURL: url)
                print("Saved log: \(out)")
            }

            if result.outcome == .failed {
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
