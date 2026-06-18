import Foundation

public actor TestExecutionEngine {
    public typealias LogHandler = (ExecutionLogEntry) -> Void

    private enum ItemName {
        static let boot = "Boot"
        static let forceinit = "forceinit"
        static let connect = "connect"
    }

    private let defaultBootSettleDelayMs: UInt64 = 800
    private let statusPollDelayMs: UInt64 = 200

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

        func append(_ level: LogLevel, _ code: String, _ message: String, itemName: String? = nil) {
            let entry = ExecutionLogEntry(level: level, code: code, message: message, itemName: itemName)
            logs.append(entry)
            logHandler?(entry)
        }

        func fail(_ code: String, _ message: String, device: UsbDevice?, itemName: String? = nil) -> ExecutionResult {
            state = .failed
            append(.error, code, message, itemName: itemName)
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
                append(.info, "INFO_DOWNLOADITEM_START", "Start to download test item \(item.name)...", itemName: item.name)
                do {
                    try transport.downloadItem(item: item, payload: payload, address: plan.downloadBaseAddress)
                    append(.info, "INFO_DOWNLOADITEM_OK", "Download test item \(item.name) ok", itemName: item.name)
                } catch {
                    return fail("ERROR_DOWNLOADITEM_FAIL", "Download test item \(item.name) failed: \(error.localizedDescription)", device: selectedDevice, itemName: item.name)
                }

                if let preParamPrintf = try transport.readPrintf(), !preParamPrintf.isEmpty {
                    append(.info, "INFO_PRINTF", preParamPrintf)
                }

                // Download params — equivalent to RKU_WriteMemory
                if shouldDownloadParam(for: item) {
                    append(.info, "INFO_DOWNLOADITEMPARAM_START", "Start to download parameter of \(item.name)", itemName: item.name)
                    do {
                        try transport.downloadParam(item: item, address: plan.address, params: plan.params)
                    } catch {
                        return fail("ERROR_DOWNLOADITEMPARAM_FAIL", "Download parameter failed: \(error.localizedDescription)", device: selectedDevice, itemName: item.name)
                    }

                    if let preRunPrintf = try transport.readPrintf(), !preRunPrintf.isEmpty {
                        append(.info, "INFO_PRINTF", preRunPrintf)
                    }
                }

                // Run item — equivalent to RKU_RunMemory (opcode 3)
                state = .running
                append(.info, "INFO_RUNITEM_START", "Start to run test item \(item.name)", itemName: item.name)
                do {
                    try transport.runItem(item: item, address: plan.downloadBaseAddress)
                } catch {
                    return fail("ERROR_RUNITEM_FAIL", "Run test item \(item.name) failed: \(error.localizedDescription)", device: selectedDevice, itemName: item.name)
                }

                // Wait for the item to finish — equivalent to Windows' RKU_TestDeviceReady
                // loop in sub_406420. Pass/fail is taken from the device's status/result
                // words (testDeviceReady), NOT from printf text. Printf is drained via the
                // callback purely so the UI shows live device output.
                state = .collectingLog
                let completion: ItemCompletion
                do {
                    completion = try await waitForItemCompletion(item: item) { printf in
                        append(.info, "INFO_PRINTF", printf, itemName: item.name)
                    }
                } catch {
                    return fail("ERROR_RUNITEM_FAIL", "Polling test item \(item.name) failed: \(error.localizedDescription)", device: selectedDevice, itemName: item.name)
                }

                switch completion {
                case .passed:
                    append(.info, "INFO_RUNITEM_OK", "Running test item \(item.name) ok", itemName: item.name)
                case .failed(let reason):
                    return fail("ERROR_RUNITEM_FAIL", "Run test item \(item.name) failed: \(reason)", device: selectedDevice, itemName: item.name)
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

    /// Per-item completion verdict, derived from `RKU_TestDeviceReady`.
    private enum ItemCompletion {
        case passed
        case failed(String)
    }

    /// Poll `RKU_TestDeviceReady` (opcode 0) until the item finishes, mirroring
    /// DDR_UserTool `sub_406420`: the device's status/result words decide the
    /// verdict; printf is drained only for live display (Windows drains printf
    /// on a separate thread for the same purpose). Windows loops with a 200ms
    /// cadence and NO iteration cap — it trusts the device to eventually report
    /// done/error — so we do the same; a device that stops responding is caught
    /// by `testDeviceReady`'s USB transfer timeout rather than a poll counter.
    private func waitForItemCompletion(
        item: CfgItem,
        onPrintf: (String) -> Void
    ) async throws -> ItemCompletion {
        while true {
            // Status first: the verdict never waits on printf (mirrors Windows,
            // whose loop body is just TestDeviceReady + Sleep(0xC8)).
            let status = try transport.testDeviceReady()
            switch status.phase {
            case .error:
                return .failed("device reported error (status=1)")
            case .finished:
                // One last display drain for the trailing summary line, then
                // decide on the result code (word2) — exactly as Windows checks
                // the result word after TestDeviceReady returns 'done'.
                if let printf = try transport.readPrintf(), !printf.isEmpty {
                    onPrintf(printf)
                }
                return status.resultCode == 0
                    ? .passed
                    : .failed("device returned result \(status.resultCode)")
            case .running:
                // Display-only drain while the device works; never affects the
                // verdict.
                if let printf = try transport.readPrintf(), !printf.isEmpty {
                    onPrintf(printf)
                }
                try await Task.sleep(nanoseconds: statusPollDelayMs * 1_000_000)
            }
        }
    }
}
