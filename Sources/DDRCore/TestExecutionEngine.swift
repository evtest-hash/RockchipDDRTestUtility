import Foundation

public actor TestExecutionEngine {
    public typealias LogHandler = (ExecutionLogEntry) -> Void

    private enum ItemName {
        static let boot = "Boot"
        static let forceinit = "forceinit"
        static let connect = "connect"
    }

    private let maxPrintfReadsPerItem = 256
    private let maxConsecutiveEmptyPrintfReads = 8
    private let defaultBootSettleDelayMs: UInt64 = 800
    private let printfPollDelayMs: UInt64 = 20

    private let parser: CfgBinaryParser
    private let transport: UsbTransport
    private let logHandler: LogHandler?

    public init(parser: CfgBinaryParser, transport: UsbTransport, logHandler: LogHandler? = nil) {
        self.parser = parser
        self.transport = transport
        self.logHandler = logHandler
    }

    public func run(cfgPath: String, selectedDeviceID: String? = nil) async -> ExecutionResult {
        let startedAt = Date()
        var logs: [ExecutionLogEntry] = []
        var state: ExecutionState = .idle
        var selectedDevice: UsbDevice?

        func append(_ level: LogLevel, _ code: String, _ message: String) {
            let entry = ExecutionLogEntry(level: level, code: code, message: message)
            logs.append(entry)
            logHandler?(entry)
        }

        func fail(_ code: String, _ message: String, device: UsbDevice?) -> ExecutionResult {
            state = .failed
            append(.error, code, message)
            try? transport.close()
            return ExecutionResult(
                outcome: .failed,
                state: state,
                selectedDevice: device,
                logs: logs,
                startedAt: startedAt,
                finishedAt: Date()
            )
        }

        do {
            state = .initializing
            append(.info, "INFO_INIT", "Loading cfg: \(cfgPath)")
            let plan = try parser.parse(url: URL(fileURLWithPath: cfgPath))

            let devices = try transport.discoverDevices()
            if devices.isEmpty {
                throw DDRToolError.noDevice
            }

            if let selectedDeviceID,
               let matched = devices.first(where: { $0.deviceID == selectedDeviceID }) {
                selectedDevice = matched
            } else {
                selectedDevice = devices.first
            }

            guard let selectedDevice else {
                throw DDRToolError.noDevice
            }

            append(.info, "INFO_DEVICE", "Using device \(selectedDevice.productName)")
            try transport.open(device: selectedDevice)

            guard !plan.items.isEmpty else {
                throw DDRToolError.parseFailure("No test items found in cfg")
            }

            // ── Stage 1: Boot ──
            let bootItem = plan.items.first { $0.name.caseInsensitiveCompare(ItemName.boot) == .orderedSame }
            if let bootItem {
                let bootPayload = plan.embeddedBins[bootItem.name] ?? Data()
                state = .downloading
                append(.info, "INFO_DOWNLOADBOOT_START", "Start to download boot...")
                do {
                    try transport.downloadBoot(item: bootItem, payload: bootPayload)
                    append(.info, "INFO_DOWNLOADBOOT_OK", "Download boot ok")
                } catch {
                    return fail("ERROR_DOWNLOADBOOT_FAIL", "Download boot failed: \(error.localizedDescription)", device: selectedDevice)
                }

                try await Task.sleep(nanoseconds: defaultBootSettleDelayMs * 1_000_000)
            }

            // ── Stage 2+: Test items (forceinit, connect, ...) ──
            let testItems = plan.items.filter { $0.name.caseInsensitiveCompare(ItemName.boot) != .orderedSame }

            for item in testItems {
                let payload = plan.embeddedBins[item.name] ?? Data()

                // Download item — equivalent to RKU_WriteMemory
                state = .downloading
                append(.info, "INFO_DOWNLOADITEM_START", "Start to download test item \(item.name)...")
                do {
                    try transport.downloadItem(item: item, payload: payload, address: plan.downloadBaseAddress)
                    append(.info, "INFO_DOWNLOADITEM_OK", "Download test item \(item.name) ok")
                } catch {
                    return fail("ERROR_DOWNLOADITEM_FAIL", "Download test item \(item.name) failed: \(error.localizedDescription)", device: selectedDevice)
                }

                if let preParamPrintf = try transport.readPrintf(), !preParamPrintf.isEmpty {
                    append(.info, "INFO_PRINTF", preParamPrintf)
                }

                // Download params — equivalent to RKU_WriteMemory
                if shouldDownloadParam(for: item) {
                    append(.info, "INFO_DOWNLOADITEMPARAM_START", "Start to download parameter of \(item.name)")
                    do {
                        try transport.downloadParam(item: item, address: plan.address, params: plan.params)
                    } catch {
                        return fail("ERROR_DOWNLOADITEMPARAM_FAIL", "Download parameter failed: \(error.localizedDescription)", device: selectedDevice)
                    }

                    if let preRunPrintf = try transport.readPrintf(), !preRunPrintf.isEmpty {
                        append(.info, "INFO_PRINTF", preRunPrintf)
                    }
                }

                // Run item — equivalent to RKU_RunMemory
                state = .running
                append(.info, "INFO_RUNITEM_START", "Start to run test item \(item.name)")
                do {
                    try transport.runItem(item: item, address: plan.downloadBaseAddress)
                    append(.info, "INFO_RUNITEM_OK", "Running test item \(item.name) ok")
                } catch {
                    return fail("ERROR_RUNITEM_FAIL", "Run test item \(item.name) failed: \(error.localizedDescription)", device: selectedDevice)
                }

                // Poll printf — equivalent to RKU_TestDeviceReady + RKU_Printf
                // Collect device output; abort if device reports failure
                state = .collectingLog
                var printfReadCount = 0
                var emptyReadCount = 0
                var itemLogText = ""
                var itemFailed = false
                while printfReadCount < maxPrintfReadsPerItem,
                      emptyReadCount < maxConsecutiveEmptyPrintfReads {
                    let printf = try transport.readPrintf()
                    if let printf, !printf.isEmpty {
                        emptyReadCount = 0
                        itemLogText += printf
                        append(.info, "INFO_PRINTF", printf)
                        printfReadCount += 1

                        if deviceReportedFailure(item: item, text: printf) {
                            itemFailed = true
                            break
                        }
                        if isItemLogComplete(item: item, text: itemLogText) {
                            break
                        }
                    } else {
                        emptyReadCount += 1
                        printfReadCount += 1
                    }
                    try await Task.sleep(nanoseconds: printfPollDelayMs * 1_000_000)
                }

                if itemFailed {
                    return fail("ERROR_ITEM_FAILED", "Test item \(item.name) failed, aborting.", device: selectedDevice)
                }
            }

            try transport.close()
            state = .completed
            append(.info, "INFO_TESTDDR_OK", "Testing DDR Success.")
            return ExecutionResult(
                outcome: .passed,
                state: state,
                selectedDevice: selectedDevice,
                logs: logs,
                startedAt: startedAt,
                finishedAt: Date()
            )
        } catch {
            return fail("ERROR", error.localizedDescription, device: selectedDevice)
        }
    }

    // MARK: - Private

    private func shouldDownloadParam(for item: CfgItem) -> Bool {
        item.name.caseInsensitiveCompare(ItemName.forceinit) == .orderedSame
    }

    /// Check if the device's printf output indicates the current stage completed.
    private func isItemLogComplete(item: CfgItem, text: String) -> Bool {
        if item.name.caseInsensitiveCompare(ItemName.forceinit) == .orderedSame {
            return text.contains("Force init DDR pass.")
                || text.contains("Force init DDR fail")
                || text.contains("sdram_init_all_channel end.")
        }
        if item.name.caseInsensitiveCompare(ItemName.connect) == .orderedSame {
            let upper = text.uppercased()
            return upper.contains("RESULT: PASS")
                || upper.contains("RESULT: FAIL")
                || text.contains("Summary: PASS")
                || text.contains("Summary: FAIL")
                || text.contains("汇总:")
                || text.contains("汇总：")
        }
        return false
    }

    /// Check if the device explicitly reported failure — equivalent to RKU_TestDeviceReady returning FALSE.
    /// Uses specific patterns from the DDR firmware output to avoid false positives.
    private func deviceReportedFailure(item: CfgItem, text: String) -> Bool {
        let upper = text.uppercased()

        // English "FAIL" keyword — appears in "Result: FAIL!", "Check X fail", etc.
        if upper.contains("FAIL") { return true }

        // Chinese error with exclamation mark — "DQS0 错误!", "Training 错误!", "强制初始化 DDR 错误!", etc.
        // The "!" distinguishes real errors from "no error" messages like "未检测到错误状态。"
        if text.contains("错误!") { return true }

        // English forceinit explicit failure
        if text.contains("Force init DDR fail") { return true }

        return false
    }
}
