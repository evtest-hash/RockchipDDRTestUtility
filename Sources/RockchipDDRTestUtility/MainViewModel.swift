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
    /// User switch for DDR auto-detect (preselecting the cfg on plug-in). ON by
    /// default. Deliberately NOT persisted — its lifetime is this app run only,
    /// so every launch starts with auto-detect on. When OFF, a profiled device is
    /// treated like any other: no probe, no reboot, the user picks the cfg
    /// manually (their choice is never overwritten). Auto-detect only ever
    /// *preselects*; this switch lets the operator opt out entirely.
    @Published var autoDetectEnabled = true
    /// True while a DDR auto-detect probe (DdrDetector.detect) is in flight for
    /// a newly-arrived device. UI can use this to show a "detecting..." state
    /// distinct from `isRunning` (which covers the actual test execution).
    @Published var isDetecting = false
    private var hasRunAutoTestForCurrentDevice = false
    /// Name of the DDR auto-detect card shown in the central log area (so detect
    /// and the subsequent test read as one timeline).
    static let detectStepName = "DDR 自动探测"
    /// Set when a detect card has been placed in `testSteps`; tells the next
    /// `startTest` to APPEND its steps after it (one timeline) instead of clearing.
    /// Consumed by that `startTest`; a fresh detect re-arms it, an unplug clears it.
    private var carryDetectStepIntoTest = false
    /// Mirrors `hasRunAutoTestForCurrentDevice` for the DDR auto-detect probe:
    /// set the moment `runDetectThenMaybeTest` is launched for the current
    /// device, so a subsequent `pollDevices` tick (the 1s timer) can't launch a
    /// second, overlapping detect for the same connection — detect's own
    /// reboot-to-maskrom step drops the device off USB and re-enumerates for up
    /// to ~6s, during which two racing detects (or a reboot-induced re-enum
    /// re-triggering detect) would otherwise loop. Cleared in
    /// `resetConnectionState()` alongside `hasRunAutoTestForCurrentDevice` so a
    /// genuine unplug re-arms it.
    private var hasDetectedForCurrentDevice = false
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

            // A device already connected when the app launched is invisible to
            // `pollDevices`' change-detection: `refreshDevices` just populated
            // `devices`, so every poll sees `newDevices == devices` (no change)
            // and the auto-detect trigger there never fires. Launch it here so
            // the connected board's DRAM is probed and the matching cfg is
            // preselected — otherwise it silently keeps the first cfg in the
            // list and the soldering test runs with the wrong config.
            //
            // Suppress auto-*test* for a launch-present device (the intent
            // behind `initialDeviceIDs` — don't drive a full test on a board the
            // user opened the app onto): the unified detect path gates auto-test
            // only on `hasRunAutoTestForCurrentDevice`, so pre-latch it. A later
            // unplug/replug clears it (`resetConnectionState`) and re-arms.
            if maybeLaunchAutoDetect() {
                hasRunAutoTestForCurrentDevice = true
            }

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
        // Keep the detect card + start a continuous timeline when this test
        // follows an auto-detect; otherwise start fresh. (Consume the flag so a
        // second, standalone test run resets normally.)
        if carryDetectStepIntoTest {
            carryDetectStepIntoTest = false
        } else {
            testSteps = []
            totalMessageCount = 0
        }
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
            let skipBoot = !deviceNeedsBoot
            let engine = TestExecutionEngine(parser: parser, transport: activeTransport!) { [weak self] entry in
                // Preserve engine log order in the UI. A detached Task per entry
                // can reorder Boot / forceinit / connect updates under load.
                guard let self else { return }
                await self.handleExecutionLog(entry)
            }

            let result = await engine.run(
                cfgPath: selected.absolutePath,
                selectedDeviceID: selectedDeviceID,
                skipBoot: skipBoot,
                keepTransportOpen: true
            )
            lastResult = result
            // Clear the latch only after a real boot succeeds — a failed boot
            // leaves it set so the next run retries (matches Windows, which
            // clears 0x4B8 solely after a good boot).
            if result.bootSucceeded {
                setDeviceNeedsBoot(false)
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

    /// Applies DDR auto-detect results to selection state: preselects the
    /// highest-ranked candidate that actually exists among the loaded
    /// `testFiles` (a candidate can be ranked from a stale/partial file list),
    /// setting both `selectedFileID` and `selectedSoc`. Returns the chosen file
    /// id, or nil if none of the candidates are present (caller keeps the
    /// current selection / falls back to manual).
    ///
    /// The actual "does this candidate exist" decision is delegated to
    /// `CfgAutoSelect.firstAvailable` (DDRCore, pure, unit-tested) — this
    /// wrapper only exists to apply the result to `@Published` state, since
    /// this app target itself isn't unit-testable (executable, not a library).
    func applyDetectCandidates(_ candidates: [CfgAutoSelect.Candidate]) -> String? {
        guard let entry = CfgAutoSelect.firstAvailable(candidates, in: testFiles) else { return nil }
        selectedFileID = entry.id
        selectedSoc = entry.socName
        return entry.id
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

    private func handleExecutionLog(_ entry: ExecutionLogEntry) {
        updateStepsFromLog(entry)
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
        setDeviceNeedsBoot(true)
        selectedDeviceID = nil
        hasRunAutoTestForCurrentDevice = false
        hasDetectedForCurrentDevice = false
        carryDetectStepIntoTest = false
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
        guard !isDetecting else { return }
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
                    setDeviceNeedsBoot(true)
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

                    // Devices with a DDR auto-detect profile (RK3568&RK3566 today —
                    // see DetectProfiles) get probed for DRAM geometry before any
                    // auto-test: runDetectThenMaybeTest preselects the best-matching
                    // cfg (or falls back to the first one) and only calls
                    // maybeAutoTest() itself when the device actually made it back
                    // to MASKROM. SoCs without a profile keep the original
                    // immediate auto-test trigger.
                    if !maybeLaunchAutoDetect() {
                        maybeAutoTest()
                    }
                }
            }
        } catch {
            // Silently ignore — device enumeration can fail transiently
        }
    }

    private func setDeviceNeedsBoot(_ newValue: Bool) {
        deviceNeedsBoot = newValue
    }

    /// Launches DDR auto-detect (`runDetectThenMaybeTest`) for the currently
    /// selected device when it has a `DetectProfile` and detect hasn't already
    /// run for this connection. Shared by the runtime plug-in path
    /// (`pollDevices`) and the launch path (`load`, for a device already
    /// connected when the app opened — which `pollDevices`' change-detection
    /// never treats as "arrived", so without this its cfg would never be
    /// probed). Guarded by `hasDetectedForCurrentDevice` so the 1s timer can't
    /// launch a second, overlapping detect while one is already in flight for
    /// this connection (detect's own reboot-to-maskrom step drops the device off
    /// USB and re-enumerates for up to ~6s).
    ///
    /// Returns true when the selected device is profiled (detect launched, or
    /// already ran) so the caller skips its non-detect `maybeAutoTest()`
    /// fallback; false for SoCs without a profile / when auto-detect is off.
    @discardableResult
    private func maybeLaunchAutoDetect() -> Bool {
        guard autoDetectEnabled,
              let device = devices.first(where: { $0.deviceID == selectedDeviceID }),
              DetectProfiles.forPID(device.productID) != nil else {
            return false
        }
        if !hasDetectedForCurrentDevice {
            hasDetectedForCurrentDevice = true
            Self.dlog("profiled device (pid=0x\(String(format: "%04X", device.productID))) → launch auto-detect")
            Task { await runDetectThenMaybeTest(device) }
        }
        return true
    }

    // MARK: - Auto-Test Trigger

    /// Fires the settle-then-`startTest` auto-test flow for a newly-arrived
    /// device, exactly once per connection (guarded by
    /// `hasRunAutoTestForCurrentDevice` / `initialDeviceIDs`). Extracted out of
    /// `pollDevices` so both the plain (non-detect) path and the tail of
    /// `runDetectThenMaybeTest` share the identical latch/settle logic instead
    /// of risking drift between two copies.
    private func maybeAutoTest() {
        let newIDs = Set(devices.map(\.deviceID)).subtracting(initialDeviceIDs ?? [])
        if autoTestEnabled && !hasRunAutoTestForCurrentDevice && !newIDs.isEmpty {
            hasRunAutoTestForCurrentDevice = true
            initialDeviceIDs = nil
            // Settle: a freshly-(re)plugged bootrom needs a moment before it
            // reliably accepts the vendor control-transfer boot. Without this,
            // auto-test can fire within tens of ms of detection, the boot
            // stalls, and the device resets.
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await startTest()
            }
        }
    }

    // MARK: - DDR Auto-Detect

    /// Runs DDR auto-detect (`DdrDetector.detect`) on a newly-arrived device
    /// whose PID has a `DetectProfile`: downloads the auto-probing rkbin DDR
    /// bin, dumps OS_REG over the probe cfg's printf channel, decodes the DRAM
    /// geometry, and preselects the best-matching soldering-test cfg via
    /// `applyDetectCandidates`. On any failure (unsupported SoC, missing
    /// resource files, no OS_REG captured, USB error, etc.) or when detect
    /// succeeds but ranks no cfg present in the loaded file set, falls back to
    /// the first cfg for the SoC so the user can still test manually — detect
    /// only ever assists selection, it never blocks the flow.
    ///
    /// `DdrDetector.detect`'s `rebootedToMaskrom` flag tells us whether the
    /// device actually made it back to MASKROM after the probe. If it didn't
    /// (reboot payload failed, or re-enumeration timed out) — or if `detect`
    /// threw before ever attempting the reboot (e.g. `.noOsReg`) — the device
    /// is still running the probe firmware, NOT sitting in MASKROM. Booting it
    /// again (auto-test or a manual Start click) would hit the same
    /// already-booted-device failure this repo documents elsewhere
    /// ("expected 512 got -1"). So `maybeAutoTest()` is only ever called when
    /// `rebootedToMaskrom == true`; every other outcome (no match, reboot
    /// failed, or detect threw) preselects/falls back a cfg, re-arms the boot
    /// latch so the *next* successful boot is a real one, and leaves the user
    /// to replug + retry manually.
    @MainActor
    private func runDetectThenMaybeTest(_ device: UsbDevice) async {
        isDetecting = true
        statusMessage = "正在检测 DDR…"
        stopKeepAlive()
        defer { isDetecting = false }
        Self.dlog("detect start: device=\(device.deviceID) pid=0x\(String(format: "%04X", device.productID))")
        // Start a fresh timeline in the central log area with the detect card;
        // the following test appends after it (carryDetectStepIntoTest).
        testSteps = []
        totalMessageCount = 0
        overallOutcome = nil
        ensureStep(Self.detectStepName)
        setStepState(Self.detectStepName, .running)
        appendStepMessage(Self.detectStepName, "开始探测…")
        carryDetectStepIntoTest = true
        do {
            // Unified detect→test (no reboot): run detect on the PERSISTENT
            // transport with reboot:false, so the DDR Test Tool Boot stays
            // resident and the handle stays open. The subsequent test — auto or a
            // later manual "开始测试" — reuses this exact session with skipBoot
            // (never re-downloads Boot, never resets). This sidesteps the RK3288
            // populated-eMMC reboot limitation entirely (no reset → the eMMC boot
            // chain never runs) and is faster (no reboot + re-enum wait).
            // HW-validated (RK3288 --detect-then-test: PASS, bootSucceeded=false).
            if activeTransport == nil || activeTransportDeviceID != selectedDeviceID {
                tearDownActiveTransport()
                activeTransport = try makeTransport()
                activeTransportDeviceID = selectedDeviceID
            }
            let socName = DetectProfiles.forPID(device.productID)?.soc ?? device.socName ?? ""
            let det = DdrDetector(resourcesDir: detectResourcesDir(soc: socName))
            let out = try await det.detect(transport: activeTransport!, device: device,
                                           socFiles: filesForSelectedSoc, reboot: false)
            // Detection succeeds ONLY on an exact (type + capacity + CS) match.
            // `out.candidates` is already the exact-match set (empty ⇒ no match).
            // `out.matchTier` further grades HOW that match was reached — only
            // .uniqueByCoarse (a clean, unambiguous hit) is allowed to auto-test.
            Self.dlog("detect done: \(out.geometry.summary()) matches=\(out.candidates.count) tier=\(out.matchTier) selected=\(selectedFileID ?? "nil")")
            let selected = applyDetectCandidates(out.candidates)
            setDeviceNeedsBoot(false)   // Boot 常驻，测试跳过 boot

            switch out.matchTier {
            case .none:
                // 零命中：交回手动，不测。
                setStepState(Self.detectStepName, .failed)
                appendStepMessage(Self.detectStepName, "未匹配到 cfg(\(out.geometry.summary()))")
                appendStepMessage(Self.detectStepName, "可能未初始化/坏板,或不在库中 — 请手动选择配置文件")
                selectedFileID = filesForSelectedSoc.first?.id
                statusMessage = "DDR 探测未匹配到 cfg(\(out.geometry.summary()))— 请手动选择"
                startKeepAlive()

            case .ambiguous:
                // L1>1 且 tie-break 未能唯一：预选第一个但不自动测，可改选。
                let cfgName = out.candidates.first?.entry.displayName ?? "(cfg)"
                setStepState(Self.detectStepName, .passed)
                appendStepMessage(Self.detectStepName, "检测到 \(out.geometry.summary())")
                appendStepMessage(Self.detectStepName, "多个同规格 cfg,已预选: \(cfgName)(可改选后手动开始测试)")
                statusMessage = "检测到 \(out.geometry.summary()) — 多个同规格 cfg,请确认/改选后开始测试"
                startKeepAlive()

            case .uniqueByTieBreak:
                // 参数几何收敛到唯一，但离散颗粒未经硬件验证：预选 + 待确认,不自动测。
                let cfgName = out.candidates.first?.entry.displayName ?? "(cfg)"
                setStepState(Self.detectStepName, .passed)
                appendStepMessage(Self.detectStepName, "检测到 \(out.geometry.summary())")
                appendStepMessage(Self.detectStepName, "已按几何预选: \(cfgName)(离散颗粒,未经硬件验证,请确认后开始测试)")
                statusMessage = "检测到 \(out.geometry.summary()) — 已按几何预选 cfg,请确认后开始测试"
                startKeepAlive()

            case .uniqueByCoarse:
                // 干净唯一命中：维持现状,允许自动测试。
                guard selected != nil else {
                    setStepState(Self.detectStepName, .failed)
                    appendStepMessage(Self.detectStepName, "匹配到 cfg 但不在已加载列表 — 请手动选择")
                    selectedFileID = filesForSelectedSoc.first?.id
                    statusMessage = "DDR 探测匹配到 cfg 但不在列表 — 请手动选择"
                    startKeepAlive()
                    break
                }
                let cfgName = out.candidates.first?.entry.displayName ?? "(cfg)"
                setStepState(Self.detectStepName, .passed)
                appendStepMessage(Self.detectStepName, "检测到 \(out.geometry.summary())")
                appendStepMessage(Self.detectStepName, "预选 cfg: \(cfgName)")
                statusMessage = "检测到 \(out.geometry.summary()) — 已预选 cfg,可开始测试"
                if autoTestEnabled && !hasRunAutoTestForCurrentDevice {
                    // Trigger the test DIRECTLY — not via maybeAutoTest(), whose
                    // `newIDs` (device-just-enumerated) guard was satisfied by the
                    // old reboot re-enumeration. The unified flow never reboots, so
                    // the deviceID is unchanged and that guard would never fire.
                    // We already know a device just detected + a cfg matched; the
                    // `hasRunAutoTestForCurrentDevice` latch (cleared on replug)
                    // prevents repeats.
                    //
                    // WAIT for the resident Boot to return to its idle command loop
                    // before letting startTest download the test's forceinit: right
                    // after the osregdump probe the Boot can still be busy, and a
                    // fixed short delay raced it → intermittent "bulk IN timeout" on
                    // the first downloadItem. probeAlive() succeeds only once the
                    // Boot services commands again, so poll it (this is exactly what
                    // makes the manual path — keep-alive running until the user
                    // clicks — reliable). Deterministic, not a guessed delay.
                    hasRunAutoTestForCurrentDevice = true
                    Self.dlog("uniqueByCoarse; autoTest on → wait for Boot idle, then startTest()")
                    let t = activeTransport
                    // Detached so the blocking probeAlive() bulk call runs OFF the
                    // main thread (the keep-alive does the same); startTest is
                    // @MainActor, so the final await hops back to main.
                    Task.detached { [weak self] in
                        for _ in 0..<30 {                       // up to ~3s
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            if t?.probeAlive() == true { break }
                        }
                        await self?.startTest()
                    }
                } else {
                    // Hold the session open until the user clicks 开始测试
                    // (that run also skip-boots on the resident Boot).
                    Self.dlog("matched; autoTest off (or already ran) → hold transport for manual test")
                    startKeepAlive()
                }
            }
        } catch {
            // Detect failed → the device's state is uncertain; drop the handle so
            // the next attempt re-opens fresh, and require a real boot next time.
            setStepState(Self.detectStepName, .failed)
            appendStepMessage(Self.detectStepName, "探测失败:\(error)")
            appendStepMessage(Self.detectStepName, "设备可能需重新插拔;或手动选择 cfg")
            tearDownActiveTransport()
            selectedFileID = filesForSelectedSoc.first?.id
            setDeviceNeedsBoot(true)
            statusMessage = "DDR 自动检测失败(\(error)),设备可能需重新插拔;或手动选择 cfg"
            Self.dlog("detect FAILED: \(error) — fell back to manual selection")
        }
    }

    /// Diagnostic log to stderr for the DDR auto-detect flow (mirrors
    /// CfgRepository's stderr logging). Visible when the GUI is launched from a
    /// terminal; keeps the detect path observable without a UI console.
    private static func dlog(_ message: String) {
        fputs("[DDRDetect] \(message)\n", stderr)
    }

    /// Directory holding the single self-contained DDR auto-detect cfg
    /// (`DetectProfile.detectCfgName`, e.g. `DDR自动探测.cfg`), which packages
    /// every payload the detect flow needs (rkbin DDR bin, Boot, osregdump,
    /// reboot). It lives in the SoC's `DDRTestFiles/<soc>/` dir alongside the
    /// real test cfgs, so it is discovered and bundled by the exact same path as
    /// every other cfg (`CfgRepository.makeDefaultRootURL()` → bundle or dev CWD,
    /// and `scripts/package.sh` already copies `DDRTestFiles/` into the `.app`).
    private func detectResourcesDir(soc: String) -> URL {
        CfgRepository.makeDefaultRootURL().appendingPathComponent(soc)
    }
}
