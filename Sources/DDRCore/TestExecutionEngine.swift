import Foundation

public actor TestExecutionEngine {
    public typealias LogHandler = (ExecutionLogEntry) -> Void

    private enum ItemName {
        static let boot = "Boot"
        static let forceinit = "forceinit"
        static let connect = "connect"
    }

    private let defaultBootSettleDelayMs: UInt64 = 1000
    private let statusPollDelayMs: UInt64 = 200

    private let parser: CfgBinaryParser
    private let transport: UsbTransport
    private let logHandler: LogHandler?

    public init(parser: CfgBinaryParser, transport: UsbTransport, logHandler: LogHandler? = nil) {
        self.parser = parser
        self.transport = transport
        self.logHandler = logHandler
    }

    public func run(cfgPath: String, selectedDeviceID: String? = nil, skipBoot: Bool = false, keepTransportOpen: Bool = false) async -> ExecutionResult {
        let startedAt = Date()
        var logs: [ExecutionLogEntry] = []
        var state: ExecutionState = .idle
        var selectedDevice: UsbDevice?
        /// Set true only after a real boot download succeeds this run; surfaced
        /// via ExecutionResult so the caller can clear its "needs boot" latch.
        /// Mirrors DDR_UserTool `this+0x4B8`, cleared solely after a good boot.
        var bootSucceeded = false

        func append(_ level: LogLevel, _ code: String, _ message: String, itemName: String? = nil) {
            let entry = ExecutionLogEntry(level: level, code: code, message: message, itemName: itemName)
            logs.append(entry)
            logHandler?(entry)
        }

        func fail(_ code: String, _ message: String, device: UsbDevice?, itemName: String? = nil) -> ExecutionResult {
            state = .failed
            append(.error, code, message, itemName: itemName)
            // Hold the handle on failure too when keepTransportOpen is set: a
            // DDR-result failure leaves the pipe healthy, so the next run should
            // reuse it (Windows never closes its handle). A genuine USB error
            // leaves a dead handle, but that self-heals when the caller tears the
            // transport down on device change.
            if !keepTransportOpen {
                try? transport.close()
            }
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
            // Only open (which reissues SET_CONFIGURATION + claim) when a handle
            // isn't already held open — mirroring Windows, which opens its device
            // handle once and reuses it for every "start test" click. Re-opening
            // after the device is booted reconfigures the pipe, which the running
            // test firmware can't service → the first bulk OUT stalls
            // (LIBUSB_ERROR_TIMEOUT). See keepTransportOpen / UsbTransport.isOpen.
            if !transport.isOpen {
                try transport.open(device: selectedDevice)
            }

            guard !plan.items.isEmpty else {
                throw DDRToolError.parseFailure("No test items found in cfg")
            }

            // ── Stage 1: Boot ──
            // `skipBoot` mirrors DDR_UserTool's `this+0x4B8` flag: the caller
            // sets it once the current device connection has already been booted,
            // so repeated "start test" runs skip the control-transfer boot and go
            // straight to bulk test items. The flag is cleared by the caller only
            // after a real boot succeeds (see ExecutionResult.bootSucceeded),
            // matching Windows which clears 0x4B8 solely after a good boot.
            let bootItem = plan.items.first { $0.name.caseInsensitiveCompare(ItemName.boot) == .orderedSame }
            if let bootItem {
                if skipBoot {
                    append(.info, "INFO_DOWNLOADBOOT_START", "Skip boot: device already booted")
                    append(.info, "INFO_DOWNLOADBOOT_OK", "Boot skipped (device already booted)")
                } else {
                    let bootPayload = plan.embeddedBins[bootItem.name] ?? Data()
                    state = .downloading
                    append(.info, "INFO_DOWNLOADBOOT_START", "Start to download boot...")
                    do {
                        try transport.downloadBoot(item: bootItem, payload: bootPayload)
                        append(.info, "INFO_DOWNLOADBOOT_OK", "Download boot ok")
                        bootSucceeded = true
                    } catch {
                        return fail("ERROR_DOWNLOADBOOT_FAIL", "Download boot failed: \(error.localizedDescription)", device: selectedDevice)
                    }

                    try await Task.sleep(nanoseconds: defaultBootSettleDelayMs * 1_000_000)

                    // Post-boot handshake: send a single opcode-0 poll to verify
                    // the booted firmware is responding to US (not another process).
                    // `testDeviceReady()` validates the token echo, so a mismatch
                    // or timeout here catches contention before we invest in bulk
                    // payload downloads (downloadItem can be 64KiB+).
                    do {
                        _ = try transport.testDeviceReady()
                    } catch {
                        return fail("ERROR_DOWNLOADBOOT_FAIL",
                            "Boot handshake failed: \(error.localizedDescription)",
                            device: selectedDevice)
                    }
                }
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
                        try transport.downloadParam(item: item, address: item.paramAddress ?? plan.address, params: item.params)
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

            // Hold the handle open across runs when asked (keepTransportOpen), so a
            // repeat "start test" reuses the same claimed interface instead of
            // re-opening → no SET_CONFIGURATION between runs. Mirrors Windows.
            if !keepTransportOpen {
                try transport.close()
            }
            state = .completed
            append(.info, "INFO_TESTDDR_OK", "Testing DDR Success.")
            return ExecutionResult(
                outcome: .passed,
                state: state,
                selectedDevice: selectedDevice,
                logs: logs,
                startedAt: startedAt,
                finishedAt: Date(),
                bootSucceeded: bootSucceeded
            )
        } catch {
            return fail("ERROR", error.localizedDescription, device: selectedDevice)
        }
    }

    // MARK: - Private

    /// Returns `true` when `item` carries a non-empty parameter block — matching
    /// Windows DDR_UserTool's per-item param guard (`sub_460E30` + `sub_40B260`),
    /// which checks whether this specific item has associated parameters to
    /// download, rather than hardcoding a particular item name.
    private func shouldDownloadParam(for item: CfgItem) -> Bool {
        !item.params.isEmpty
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
