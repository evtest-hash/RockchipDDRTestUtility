import DDRCore
import DDRUSB
import Foundation

@MainActor
final class MainViewModel: ObservableObject {
    @Published var testFiles: [TestFileEntry] = []
    @Published var selectedFileID: String?
    @Published var devices: [UsbDevice] = []
    @Published var selectedDeviceID: String?
    @Published var isRunning = false
    @Published var statusMessage: String = ""
    @Published var testSteps: [TestStep] = []
    /// Monotonic count of messages appended across all steps. Bumped at every
    /// `messages.append` site, so it changes for both new steps (always created
    /// with a first message) and printf appended to an existing step. The UI
    /// observes this single O(1) value to auto-scroll — cheaper than recomputing
    /// a reduce on every body evaluation, and it doesn't thrash the main thread
    /// on the streaming printf path.
    @Published var totalMessageCount = 0

    @Published var overallOutcome: TestOutcome?
    @Published var selectedSoc: String?
    @Published var autoTestEnabled = false
    private var hasRunAutoTestForCurrentDevice = false
    private var initialDeviceIDs: Set<String>?
    /// True until a boot download succeeds on the current device connection.
    /// Mirrors DDR_UserTool's `this+0x4B8` flag: set whenever the device set
    /// changes (device (re)connected), cleared after the first successful boot,
    /// so repeated "start test" runs skip boot and just re-run the bulk test —
    /// exactly how Windows lets you keep clicking start.
    private var deviceNeedsBoot = true
    /// Persistent USB transport held open across "start test" clicks for the
    /// selected device — mirrors Windows' persistent device handle. The engine
    /// is told `keepTransportOpen`, so repeat tests reuse the same claimed
    /// interface instead of re-opening (which re-issues SET_CONFIGURATION and
    /// stalls the booted device's bulk endpoint). Torn down on device-set change
    /// or device-selection change.
    private var activeTransport: RkUsbTransportLibusb?
    private var activeTransportDeviceID: String?
    /// Idle keep-alive for the held transport. Mirrors DDR_UserTool's permanent
    /// printf-reader thread (PrintfReaderThreadProc / sub_405C30): while a device
    /// is connected and no test is running, poll `readPrintf()` (opcode 0x80 on
    /// ep 0x81) every ~300ms. The perpetual in-flight transfer keeps the USB
    /// pipe "active" so macOS never selectively suspends the device — which is
    /// what otherwise kills the held handle after a few seconds idle and breaks
    /// repeat "start test". Cancelled at the start of every test (the engine
    /// owns the transport while `isRunning`) and on teardown. The transport's
    /// `ioLock` serializes any residual overlap with the engine.
    private var keepAliveTask: Task<Void, Never>?

    private var settings: ConfigSettings = .default
    private let parser = CfgBinaryParser()
    private let logWriter = ResultLogWriter()
    private(set) var lastResult: ExecutionResult?
    private var deviceMonitorTimer: Timer?

    var socNames: [String] {
        let set = Set(testFiles.map(\.socName))
        return set.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var filesForSelectedSoc: [TestFileEntry] {
        guard let soc = selectedSoc else { return [] }
        return testFiles.filter { $0.socName == soc }
    }

    func load() async {
        do {
            let repo = CfgRepository(rootURL: defaultRootURL())

            let loaded = try repo.loadSettings()
            settings = loaded.settings

            testFiles = try repo.discoverTestFiles()

            try await refreshDevices()
            initialDeviceIDs = Set(devices.map(\.deviceID))

            // Fallback: if no device detected, pick first SoC
            if selectedSoc == nil {
                selectedSoc = socNames.first
            }
            if selectedFileID == nil {
                selectedFileID = repo.resolveDefaultTestFile(settings, allFiles: testFiles)?.id ?? filesForSelectedSoc.first?.id
            }

        } catch {
            statusMessage = error.localizedDescription
        }

        startDeviceMonitor()
    }

    func refreshDevices() async throws {
        let transport = try makeTransport()
        devices = try transport.discoverDevices()

        // If previously selected device is gone, reset to first available
        if let currentID = selectedDeviceID,
           !devices.contains(where: { $0.deviceID == currentID }) {
            selectedDeviceID = devices.first?.deviceID
        }
        if selectedDeviceID == nil {
            selectedDeviceID = devices.first?.deviceID
        }

        // Auto-select SoC from detected device
        if let device = devices.first(where: { $0.deviceID == selectedDeviceID }),
           let soc = device.socName, !soc.isEmpty {
            if selectedSoc != soc {
                selectedSoc = soc
                selectedFileID = filesForSelectedSoc.first?.id
            }
        }
    }

    func startTest() async {
        guard let selected = testFiles.first(where: { $0.id == selectedFileID }) else {
            statusMessage = "No cfg selected"
            return
        }

        isRunning = true
        testSteps = []
        totalMessageCount = 0
        overallOutcome = nil
        // The engine owns the transport while a test runs — stop the idle
        // keep-alive so the two never contend (the engine's own 200ms
        // testDeviceReady polling keeps the pipe active mid-test). Restarted
        // below once the test finishes.
        stopKeepAlive()

        do {
            // Bind the persistent transport to the selected device: if the
            // selection changed, drop the old handle first. Held open via
            // keepTransportOpen so repeat tests reuse the same claimed interface
            // — exactly how Windows holds its device handle across "start test"
            // clicks (re-opening re-issues SET_CONFIGURATION and stalls the
            // booted device's bulk endpoint; verified on RK3568 hardware).
            if activeTransport == nil || activeTransportDeviceID != selectedDeviceID {
                tearDownActiveTransport()
                activeTransport = try makeTransport()
                activeTransportDeviceID = selectedDeviceID
            }
            let engine = TestExecutionEngine(parser: parser, transport: activeTransport!) { [weak self] entry in
                Task { @MainActor in
                    self?.updateStepsFromLog(entry)
                }
            }

            let result = await engine.run(
                cfgPath: selected.absolutePath,
                selectedDeviceID: selectedDeviceID,
                skipBoot: !deviceNeedsBoot,
                keepTransportOpen: true
            )
            lastResult = result
            // Clear the latch only after a real boot succeeds — a failed boot
            // leaves it set so the next run retries (matches Windows, which
            // clears 0x4B8 solely after a good boot).
            if result.bootSucceeded {
                deviceNeedsBoot = false
            }

            // If any step ended in failure, the overall outcome is failure
            // regardless (its verdict came from the device's status/result).
            if testSteps.contains(where: { $0.state == .failed }) {
                overallOutcome = .failed
            } else {
                overallOutcome = result.outcome
            }
            statusMessage = overallOutcome == .passed ? "Test finished: PASS" : "Test finished: FAIL"
        } catch {
            overallOutcome = .failed
            statusMessage = error.localizedDescription
        }

        isRunning = false
        // Transport is still held (keepTransportOpen); resume the idle
        // keep-alive so the device doesn't get suspended before the next click.
        startKeepAlive()
    }

    func saveResult(to outputURL: URL) {
        guard let lastResult,
              let selected = testFiles.first(where: { $0.id == selectedFileID }) else {
            statusMessage = "No result to save"
            return
        }

        do {
            _ = try logWriter.write(result: lastResult, sourceCfgPath: selected.absolutePath, outputURL: outputURL, outcome: overallOutcome)
            statusMessage = "Saved result: \(outputURL.lastPathComponent)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func onDeviceSelectionChanged() {
        guard let deviceID = selectedDeviceID,
              let device = devices.first(where: { $0.deviceID == deviceID }),
              let soc = device.socName else { return }
        if selectedSoc != soc {
            selectedSoc = soc
            selectedFileID = filesForSelectedSoc.first?.id
        }
    }

    // MARK: - Step Tracking

    private func updateStepsFromLog(_ entry: ExecutionLogEntry) {
        let code = entry.code
        let message = entry.message

        switch code {
        case "INFO_DOWNLOADBOOT_START":
            ensureStep("Boot")
            setStepState("Boot", .downloading)
            appendStepMessage("Boot", message)

        case "INFO_DOWNLOADBOOT_OK":
            setStepState("Boot", .passed)
            appendStepMessage("Boot", message)

        case "ERROR_DOWNLOADBOOT_FAIL":
            setStepState("Boot", .failed)
            appendStepMessage("Boot", message)

        case "INFO_DOWNLOADITEM_START":
            if let name = entry.itemName ?? extractItemName(from: message) {
                ensureStep(name)
                setStepState(name, .downloading)
                appendStepMessage(name, message)
            }

        case "INFO_DOWNLOADITEM_OK":
            if let name = entry.itemName ?? extractItemName(from: message) {
                appendStepMessage(name, message)
            }

        case "INFO_DOWNLOADITEMPARAM_START":
            if let name = entry.itemName ?? extractItemName(from: message) {
                appendStepMessage(name, message)
            }

        case "INFO_RUNITEM_START":
            if let name = entry.itemName ?? extractItemName(from: message) {
                setStepState(name, .running)
                appendStepMessage(name, message)
            }

        case "INFO_RUNITEM_OK":
            if let name = entry.itemName ?? extractItemName(from: message) {
                setStepState(name, .passed)
                appendStepMessage(name, message)
            }

        case "ERROR_DOWNLOADITEM_FAIL", "ERROR_DOWNLOADITEMPARAM_FAIL", "ERROR_RUNITEM_FAIL":
            markCurrentRunningStepFailed(message)

        case "INFO_PRINTF":
            handlePrintf(message)

        case "INFO_TESTDDR_OK":
            markAllPendingStepsPassed()

        default:
            break
        }
    }

    private func ensureStep(_ name: String) {
        if !testSteps.contains(where: { $0.name == name }) {
            testSteps.append(TestStep(name: name))
        }
    }

    private func setStepState(_ name: String, _ state: StepState) {
        if let idx = testSteps.firstIndex(where: { $0.name == name }) {
            testSteps[idx].state = state
        }
    }

    private func appendStepMessage(_ name: String, _ message: String) {
        if let idx = testSteps.firstIndex(where: { $0.name == name }) {
            testSteps[idx].messages.append(message)
            totalMessageCount += 1
        }
    }

    /// Fallback item-name recovery from log prose. Prefer the structured
    /// `entry.itemName` (set by the engine for item-scoped codes); this is kept
    /// only as a safety net for entries without it.
    private func extractItemName(from message: String) -> String? {
        // "Start to download test item forceinit..." → "forceinit"
        // "Start to run test item connect"          → "connect"
        // "Running test item forceinit ok"          → "forceinit"
        guard let range = message.range(of: "test item ") else { return nil }
        let rest = message[range.upperBound...]
        // Item name = the leading run of non-space, non-dot characters, so both
        // "forceinit ok" and "forceinit..." resolve to "forceinit".
        let name = rest.prefix { !$0.isWhitespace && $0 != "." }
        let trimmed = String(name).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func handlePrintf(_ message: String) {
        // Printf is display-only. Step pass/fail is driven by the engine's
        // INFO_RUNITEM_OK / ERROR_RUNITEM_FAIL / INFO_TESTDDR_OK codes (which
        // come from the device's RKU_TestDeviceReady status/result), not from
        // scanning this text — matching DDR_UserTool's failure detection.
        let idx = testSteps.lastIndex(where: { $0.state == .running })
            ?? testSteps.lastIndex(where: { $0.state == .downloading })
            ?? testSteps.indices.last
        guard let idx else { return }

        // Strip protocol tags and display all lines
        let cleaned = message
            .replacingOccurrences(of: "<>", with: "")
            .replacingOccurrences(of: "</N>", with: "")
        for line in cleaned.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            testSteps[idx].messages.append(trimmed)
            totalMessageCount += 1
        }
    }


    private func markCurrentRunningStepFailed(_ message: String) {
        if let idx = testSteps.lastIndex(where: { $0.state == .downloading || $0.state == .running }) {
            testSteps[idx].state = .failed
            testSteps[idx].messages.append(message)
            totalMessageCount += 1
        }
    }

    private func markAllPendingStepsPassed() {
        for i in testSteps.indices {
            if testSteps[i].state == .running || testSteps[i].state == .downloading {
                testSteps[i].state = .passed
            }
        }
    }

    // MARK: - Private

    private func defaultRootURL() -> URL {
        CfgRepository.makeDefaultRootURL()
    }

    private func makeTransport() throws -> RkUsbTransportLibusb {
        return try RkUsbTransportLibusb()
    }

    /// Release the persistent test transport. Called on device-set change
    /// (unplug/replug) and device-selection change so the next test re-opens a
    /// fresh handle bound to the current device — never reusing a stale handle
    /// for a device that's gone.
    private func tearDownActiveTransport() {
        stopKeepAlive()
        try? activeTransport?.close()
        activeTransport = nil
        activeTransportDeviceID = nil
    }

    // MARK: - Idle Keep-Alive

    /// Start the idle keep-alive reader on the currently held transport. No-op
    /// if no transport is held or it isn't open. Idempotent — restarts cleanly.
    private func startKeepAlive() {
        stopKeepAlive()
        guard let transport = activeTransport, transport.isOpen else { return }
        keepAliveTask = Task.detached { [weak self] in
            var consecutiveFails = 0
            while !Task.isCancelled {
                guard self != nil else { return }
                let alive = transport.probeAlive()
                if alive {
                    consecutiveFails = 0
                } else {
                    consecutiveFails += 1
                    // ~1s of sustained no-response => device gone/unplugged.
                    // Tear down so the device monitor resumes enumeration and
                    // catches the replug; re-arms the boot-needed latch.
                    if consecutiveFails >= 3 {
                        await self?.handleDeviceLost()
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func stopKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

    /// Reset all connection-scoped latches after the current device goes away,
    /// so a replug is treated as a fresh connection: drop the held handle,
    /// require a boot, clear selection, and re-arm auto-test. Shared by both
    /// loss-detection paths (the keep-alive reader's `handleDeviceLost` and
    /// `pollDevices`' device-removal branch) so the two can't drift.
    private func resetConnectionState() {
        tearDownActiveTransport()
        deviceNeedsBoot = true
        selectedDeviceID = nil
        hasRunAutoTestForCurrentDevice = false
        // Launch-suppression ("don't auto-test devices present at launch") ends
        // once the user unplugs — a replug, even of the same deviceID, should
        // count as newly arrived and re-trigger auto-test.
        initialDeviceIDs = nil
    }

    /// Called from the keep-alive reader when the device stops responding
    /// (unplugged or wedged). Resets connection state and refreshes the device
    /// list so the monitor detects the removal immediately and catches the replug.
    @MainActor
    private func handleDeviceLost() {
        resetConnectionState()
        Task { try? await refreshDevices() }
    }

    // MARK: - Device Monitoring

    private func startDeviceMonitor() {
        deviceMonitorTimer?.invalidate()
        deviceMonitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.pollDevices()
            }
        }
    }

    private func pollDevices() {
        guard !isRunning else { return }
        guard activeTransport == nil else { return }
        do {
            let transport = try makeTransport()
            let newDevices = try transport.discoverDevices()
            let changed = newDevices.map(\.deviceID).sorted() != devices.map(\.deviceID).sorted()

            if changed {
                let deviceRemoved = !devices.isEmpty && newDevices.isEmpty
                devices = newDevices

                if deviceRemoved {
                    // Current device gone → fresh-connection reset so a replug
                    // re-boots and re-runs auto-test.
                    resetConnectionState()
                } else {
                    // New device arrived → it needs boot. (The transport is
                    // already released — pollDevices only runs while none is
                    // held — so just arm the boot latch and select it.)
                    deviceNeedsBoot = true
                    // Clear previous test results when new device detected
                    testSteps = []
                    totalMessageCount = 0
                    overallOutcome = nil
                    lastResult = nil
                    statusMessage = ""

                    if let currentID = selectedDeviceID,
                       !devices.contains(where: { $0.deviceID == currentID }) {
                        selectedDeviceID = devices.first?.deviceID
                    }
                    if selectedDeviceID == nil {
                        selectedDeviceID = devices.first?.deviceID
                    }
                    // Auto-set SoC from current device
                    if let device = devices.first(where: { $0.deviceID == selectedDeviceID }),
                       let soc = device.socName {
                        if selectedSoc != soc {
                            selectedSoc = soc
                            selectedFileID = filesForSelectedSoc.first?.id
                        }
                    }

                    // Auto-test: trigger only for newly arrived devices (not at launch)
                    let newIDs = Set(devices.map(\.deviceID)).subtracting(initialDeviceIDs ?? [])
                    if autoTestEnabled && !hasRunAutoTestForCurrentDevice && !newIDs.isEmpty {
                        hasRunAutoTestForCurrentDevice = true
                        initialDeviceIDs = nil
                        // Settle: a freshly-(re)plugged bootrom needs a moment
                        // before it reliably accepts the vendor control-transfer
                        // boot. Without this, auto-test can fire within tens of
                        // ms of detection, the boot stalls, and the device resets.
                        Task {
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            await startTest()
                        }
                    }
                }
            }
        } catch {
            // Silently ignore — device enumeration can fail transiently
        }
    }
}
