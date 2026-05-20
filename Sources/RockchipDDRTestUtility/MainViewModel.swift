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
    @Published var overallOutcome: TestOutcome?
    @Published var selectedSoc: String?
    @Published var autoTestEnabled = false
    private var hasRunAutoTestForCurrentDevice = false
    private var initialDeviceIDs: Set<String>?

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
        overallOutcome = nil

        do {
            let transport = try makeTransport()
            let engine = TestExecutionEngine(parser: parser, transport: transport) { [weak self] entry in
                Task { @MainActor in
                    self?.updateStepsFromLog(entry)
                }
            }

            let result = await engine.run(cfgPath: selected.absolutePath, selectedDeviceID: selectedDeviceID)
            lastResult = result

            // Device printf may report FAIL even if the engine completes without error
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
            if let name = extractItemName(from: message) {
                ensureStep(name)
                setStepState(name, .downloading)
                appendStepMessage(name, message)
            }

        case "INFO_DOWNLOADITEM_OK":
            if let name = extractItemName(from: message) {
                appendStepMessage(name, message)
            }

        case "INFO_DOWNLOADITEMPARAM_START":
            if let name = extractItemName(from: message) {
                appendStepMessage(name, message)
            }

        case "INFO_RUNITEM_START":
            if let name = extractItemName(from: message) {
                setStepState(name, .running)
                appendStepMessage(name, message)
            }

        case "INFO_RUNITEM_OK":
            if let name = extractItemName(from: message) {
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
        }
    }

    private func extractItemName(from message: String) -> String? {
        // "Start to download test item forceinit..." → "forceinit"
        // "Start to run test item connect" → "connect"
        guard let range = message.range(of: "test item ") else { return nil }
        let rest = message[range.upperBound...]
        let name = rest.replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func handlePrintf(_ message: String) {
        let upper = message.uppercased()
        // Prefer running step, then downloading step, then last step
        let idx = testSteps.lastIndex(where: { $0.state == .running })
            ?? testSteps.lastIndex(where: { $0.state == .downloading })
            ?? testSteps.indices.last
        guard let idx else { return }

        // Detect failure indicators first (higher priority than pass)
        if upper.contains("FAIL") || message.contains("错误!") || message.contains("Force init DDR fail") {
            testSteps[idx].state = .failed
        } else if upper.contains("PASS") || upper.contains("SUCCESS") || message.contains("通过") {
            if testSteps[idx].state != .failed {
                testSteps[idx].state = .passed
            }
        }

        // Strip protocol tags and display all lines
        let cleaned = message
            .replacingOccurrences(of: "<>", with: "")
            .replacingOccurrences(of: "</N>", with: "")
        for line in cleaned.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            testSteps[idx].messages.append(trimmed)
        }
    }


    private func markCurrentRunningStepFailed(_ message: String) {
        if let idx = testSteps.lastIndex(where: { $0.state == .downloading || $0.state == .running }) {
            testSteps[idx].state = .failed
            testSteps[idx].messages.append(message)
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
        do {
            let transport = try makeTransport()
            let newDevices = try transport.discoverDevices()
            let changed = newDevices.map(\.deviceID).sorted() != devices.map(\.deviceID).sorted()

            if changed {
                let deviceRemoved = !devices.isEmpty && newDevices.isEmpty
                devices = newDevices

                if deviceRemoved {
                    selectedDeviceID = nil
                    hasRunAutoTestForCurrentDevice = false
                } else {
                    // Clear previous test results when new device detected
                    testSteps = []
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
                        Task { await startTest() }
                    }
                }
            }
        } catch {
            // Silently ignore — device enumeration can fail transiently
        }
    }
}
