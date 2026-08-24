import Foundation

public actor TestExecutionEngine {
    public typealias LogHandler = @Sendable (ExecutionLogEntry) async -> Void

    private final class RunContext {
        let startedAt: Date
        var logs: [ExecutionLogEntry] = []
        var state: ExecutionState = .idle
        var selectedDevice: UsbDevice?
        var bootSucceeded = false

        init(startedAt: Date) {
            self.startedAt = startedAt
        }
    }

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

    /// `bootSettleMs` overrides the post-boot settle delay for this run only
    /// (default `nil` → `defaultBootSettleDelayMs`, 1000ms — the value the real
    /// soldering test relies on). DDR auto-detect passes a shorter value because
    /// the DDR Test Tool Boot comes up fast and a missed drain is retried anyway.
    public func run(cfgPath: String, selectedDeviceID: String? = nil, skipBoot: Bool = false, keepTransportOpen: Bool = false, bootSettleMs: UInt64? = nil) async -> ExecutionResult {
        let context = RunContext(startedAt: Date())

        do {
            context.state = .initializing
            await append(context, .info, "INFO_INIT", "Loading cfg: \(cfgPath)")
            let plan = try parser.parse(url: URL(fileURLWithPath: cfgPath))

            let devices = try transport.discoverDevices()
            if devices.isEmpty {
                throw DDRToolError.noDevice
            }

            if let selectedDeviceID,
               let matched = devices.first(where: { $0.deviceID == selectedDeviceID }) {
                context.selectedDevice = matched
            } else {
                context.selectedDevice = devices.first
            }

            guard let selectedDevice = context.selectedDevice else {
                throw DDRToolError.noDevice
            }

            await append(context, .info, "INFO_DEVICE", "Using device \(selectedDevice.productName)")
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
                    await append(context, .info, "INFO_DOWNLOADBOOT_START", "Skip boot: device already booted")
                    await append(context, .info, "INFO_DOWNLOADBOOT_OK", "Boot skipped (device already booted)")
                } else {
                    let bootPayload = plan.embeddedBins[bootItem.name] ?? Data()
                    context.state = .downloading
                    await append(context, .info, "INFO_DOWNLOADBOOT_START", "Start to download boot...")
                    do {
                        try transport.downloadBoot(item: bootItem, payload: bootPayload)
                        await append(context, .info, "INFO_DOWNLOADBOOT_OK", "Download boot ok")
                        context.bootSucceeded = true
                    } catch {
                        return await fail(
                            context,
                            "ERROR_DOWNLOADBOOT_FAIL",
                            "Download boot failed: \(error.localizedDescription)",
                            device: selectedDevice,
                            keepTransportOpen: keepTransportOpen,
                            failure: .transport
                        )
                    }

                    try await Task.sleep(nanoseconds: (bootSettleMs ?? defaultBootSettleDelayMs) * 1_000_000)

                    // Post-boot handshake: send a single opcode-0 poll to verify
                    // the booted firmware is responding to US (not another process).
                    // `testDeviceReady()` validates the token echo, so a mismatch
                    // or timeout here catches contention before we invest in bulk
                    // payload downloads (downloadItem can be 64KiB+).
                    do {
                        _ = try transport.testDeviceReady()
                    } catch {
                        return await fail(
                            context,
                            "ERROR_DOWNLOADBOOT_FAIL",
                            "Boot handshake failed: \(error.localizedDescription)",
                            device: selectedDevice,
                            keepTransportOpen: keepTransportOpen,
                            failure: .transport
                        )
                    }
                }
            }

            // ── Stage 2+: Test items (forceinit, connect, ...) ──
            let testItems = plan.items.filter { $0.name.caseInsensitiveCompare(ItemName.boot) != .orderedSame }

            for item in testItems {
                let payload = plan.embeddedBins[item.name] ?? Data()

                // Download item — equivalent to RKU_WriteMemory
                context.state = .downloading
                await append(context, .info, "INFO_DOWNLOADITEM_START", "Start to download test item \(item.name)...", itemName: item.name)
                do {
                    try transport.downloadItem(item: item, payload: payload, address: plan.downloadBaseAddress)
                    await append(context, .info, "INFO_DOWNLOADITEM_OK", "Download test item \(item.name) ok", itemName: item.name)
                } catch {
                    return await fail(
                        context,
                        "ERROR_DOWNLOADITEM_FAIL",
                        "Download test item \(item.name) failed: \(error.localizedDescription)",
                        device: selectedDevice,
                        keepTransportOpen: keepTransportOpen,
                        failure: .transport,
                        itemName: item.name
                    )
                }

                if let preParamPrintf = try transport.readPrintf(), !preParamPrintf.isEmpty {
                    await append(context, .info, "INFO_PRINTF", preParamPrintf)
                }

                // Download params — equivalent to RKU_WriteMemory
                if shouldDownloadParam(for: item) {
                    await append(context, .info, "INFO_DOWNLOADITEMPARAM_START", "Start to download parameter of \(item.name)", itemName: item.name)
                    do {
                        try transport.downloadParam(item: item, address: item.paramAddress ?? plan.address, params: item.params)
                    } catch {
                        return await fail(
                            context,
                            "ERROR_DOWNLOADITEMPARAM_FAIL",
                            "Download parameter failed: \(error.localizedDescription)",
                            device: selectedDevice,
                            keepTransportOpen: keepTransportOpen,
                            failure: .transport,
                            itemName: item.name
                        )
                    }

                    if let preRunPrintf = try transport.readPrintf(), !preRunPrintf.isEmpty {
                        await append(context, .info, "INFO_PRINTF", preRunPrintf)
                    }
                }

                // Run item — equivalent to RKU_RunMemory (opcode 3)
                context.state = .running
                await append(context, .info, "INFO_RUNITEM_START", "Start to run test item \(item.name)", itemName: item.name)
                do {
                    try transport.runItem(item: item, address: plan.downloadBaseAddress)
                } catch {
                    return await fail(
                        context,
                        "ERROR_RUNITEM_FAIL",
                        "Run test item \(item.name) failed: \(error.localizedDescription)",
                        device: selectedDevice,
                        keepTransportOpen: keepTransportOpen,
                        failure: .transport,
                        itemName: item.name
                    )
                }

                // Wait for the item to finish — equivalent to Windows' RKU_TestDeviceReady
                // loop in sub_406420. Pass/fail is taken from the device's status/result
                // words (testDeviceReady), NOT from printf text. Printf is drained via the
                // callback purely so the UI shows live device output.
                context.state = .collectingLog
                let completion: ItemCompletion
                do {
                    completion = try await waitForItemCompletion(item: item) { printf in
                        await self.append(context, .info, "INFO_PRINTF", printf, itemName: item.name)
                    }
                } catch {
                    return await fail(
                        context,
                        "ERROR_RUNITEM_FAIL",
                        "Polling test item \(item.name) failed: \(error.localizedDescription)",
                        device: selectedDevice,
                        keepTransportOpen: keepTransportOpen,
                        failure: .transport,
                        itemName: item.name
                    )
                }

                switch completion {
                case .passed:
                    await append(context, .info, "INFO_RUNITEM_OK", "Running test item \(item.name) ok", itemName: item.name)
                case .failed(let reason):
                    return await fail(
                        context,
                        "ERROR_RUNITEM_FAIL",
                        "Run test item \(item.name) failed: \(reason)",
                        device: selectedDevice,
                        keepTransportOpen: keepTransportOpen,
                        // The device polled done with resultCode != 0 — the ONLY
                        // path that means the DDR itself is bad (CLI exit 2).
                        failure: .deviceVerdict,
                        itemName: item.name
                    )
                }
            }

            // Hold the handle open across runs when asked (keepTransportOpen), so a
            // repeat "start test" reuses the same claimed interface instead of
            // re-opening → no SET_CONFIGURATION between runs. Mirrors Windows.
            if !keepTransportOpen {
                try transport.close()
            }
            context.state = .completed
            await append(context, .info, "INFO_TESTDDR_OK", "Testing DDR Success.")
            return ExecutionResult(
                outcome: .passed,
                state: context.state,
                selectedDevice: selectedDevice,
                logs: context.logs,
                startedAt: context.startedAt,
                finishedAt: Date(),
                bootSucceeded: context.bootSucceeded
            )
        } catch {
            return await fail(
                context,
                "ERROR",
                error.localizedDescription,
                device: context.selectedDevice,
                keepTransportOpen: keepTransportOpen,
                failure: FailureKind.classify(error)
            )
        }
    }

    // MARK: - Private

    private func append(
        _ context: RunContext,
        _ level: LogLevel,
        _ code: String,
        _ message: String,
        itemName: String? = nil
    ) async {
        let entry = ExecutionLogEntry(level: level, code: code, message: message, itemName: itemName)
        context.logs.append(entry)
        await logHandler?(entry)
    }

    private func fail(
        _ context: RunContext,
        _ code: String,
        _ message: String,
        device: UsbDevice?,
        keepTransportOpen: Bool,
        failure: FailureKind,
        itemName: String? = nil
    ) async -> ExecutionResult {
        context.state = .failed
        await append(context, .error, code, message, itemName: itemName)
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
            state: context.state,
            selectedDevice: device,
            logs: context.logs,
            startedAt: context.startedAt,
            finishedAt: Date(),
            bootSucceeded: context.bootSucceeded,
            failure: failure
        )
    }

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
        onPrintf: @Sendable (String) async -> Void
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
                    await onPrintf(printf)
                }
                return status.resultCode == 0
                    ? .passed
                    : .failed("device returned result \(status.resultCode)")
            case .running:
                // Display-only drain while the device works; never affects the
                // verdict.
                if let printf = try transport.readPrintf(), !printf.isEmpty {
                    await onPrintf(printf)
                }
                try await Task.sleep(nanoseconds: statusPollDelayMs * 1_000_000)
            }
        }
    }
}
