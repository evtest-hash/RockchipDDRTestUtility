import DDRCore
import Foundation
import XCTest

final class TestExecutionEngineTests: XCTestCase {
    func testNoDeviceFails() async {
        let transport = MockUsbTransport(devices: [])
        let parser = CfgBinaryParser()
        let engine = TestExecutionEngine(parser: parser, transport: transport)

        let result = await engine.run(cfgPath: rk3588Fixture())

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.state, .failed)
        XCTAssertTrue(result.logs.contains(where: { $0.message.contains("No device") }))
    }

    func testSuccessPath() async {
        let devices = [
            UsbDevice(deviceID: "A", vendorID: 0x2207, productID: 0x0001, productName: "RK-A", serialNumber: nil),
        ]
        let transport = MockUsbTransport(devices: devices)
        let engine = TestExecutionEngine(parser: CfgBinaryParser(), transport: transport)

        let result = await engine.run(cfgPath: rk3588Fixture())

        XCTAssertEqual(result.outcome, .passed)
        XCTAssertEqual(result.state, .completed)
        XCTAssertTrue(transport.calledPhases.contains("downloadBoot"))
        XCTAssertTrue(transport.calledPhases.contains("runItem"))
        XCTAssertTrue(result.bootSucceeded)
    }

    func testDownloadFailure() async {
        let devices = [
            UsbDevice(deviceID: "A", vendorID: 0x2207, productID: 0x0001, productName: "RK-A", serialNumber: nil),
        ]
        let transport = MockUsbTransport(devices: devices, failPhase: "downloadItem")
        let engine = TestExecutionEngine(parser: CfgBinaryParser(), transport: transport)

        let result = await engine.run(cfgPath: rk3588Fixture())

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.state, .failed)
        XCTAssertTrue(result.logs.contains(where: { $0.message.contains("downloadItem failure") }))
    }

    func testDeviceFailureStopsExecution() async {
        let devices = [
            UsbDevice(deviceID: "A", vendorID: 0x2207, productID: 0x0001, productName: "RK-A", serialNumber: nil),
        ]
        // The device reports failure through the RKU_TestDeviceReady result code
        // (mirrors Windows sub_406420), not via printf text.
        let transport = MockUsbTransport(devices: devices, failRunResult: true)
        let engine = TestExecutionEngine(parser: CfgBinaryParser(), transport: transport)

        let result = await engine.run(cfgPath: rk3588Fixture())

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.logs.contains(where: { $0.code == "ERROR_RUNITEM_FAIL" }))
    }

    func testRunningPhaseThenPasses() async {
        let devices = [
            UsbDevice(deviceID: "A", vendorID: 0x2207, productID: 0x0001, productName: "RK-A", serialNumber: nil),
        ]
        // Device reports .running for a few polls then .finished with result 0 —
        // exercises the polling loop's running→finished transition (previously
        // untested because the mock short-circuited to .finished on poll 1).
        let transport = MockUsbTransport(devices: devices, runningPollsBeforeFinish: 3)
        let engine = TestExecutionEngine(parser: CfgBinaryParser(), transport: transport)

        let result = await engine.run(cfgPath: rk3588Fixture())

        XCTAssertEqual(result.outcome, .passed)
        // The item-scoped OK entry carries the structured item name (not re-parsed
        // from prose).
        XCTAssertTrue(result.logs.contains(where: {
            $0.code == "INFO_RUNITEM_OK" && $0.itemName == "forceinit"
        }))
    }

    func testDeviceErrorStatusFails() async {
        let devices = [
            UsbDevice(deviceID: "A", vendorID: 0x2207, productID: 0x0001, productName: "RK-A", serialNumber: nil),
        ]
        // Device reports status 1 (error) on every poll — mirrors Windows
        // sub_406420 treating a TestDeviceReady error as ERROR_RUNITEM_FAIL.
        let transport = MockUsbTransport(devices: devices, reportError: true)
        let engine = TestExecutionEngine(parser: CfgBinaryParser(), transport: transport)

        let result = await engine.run(cfgPath: rk3588Fixture())

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.logs.contains(where: { $0.code == "ERROR_RUNITEM_FAIL" }))
    }

    func testSkipBootSkipsBootDownload() async {
        let devices = [
            UsbDevice(deviceID: "A", vendorID: 0x2207, productID: 0x0001, productName: "RK-A", serialNumber: nil),
        ]
        // Caller signals the device is already booted (skipBoot=true) → the engine
        // must SKIP the control-transfer downloadBoot and go straight to bulk test
        // items, without reporting boot success. Mirrors DDR_UserTool's `this+0x4B8`
        // flag, which is cleared after the first boot so repeated "start test" runs
        // skip boot — that's what lets Windows keep clicking start.
        let transport = MockUsbTransport(devices: devices)
        let engine = TestExecutionEngine(parser: CfgBinaryParser(), transport: transport)

        let result = await engine.run(cfgPath: rk3588Fixture(), skipBoot: true)

        XCTAssertEqual(result.outcome, .passed)
        XCTAssertFalse(transport.calledPhases.contains("downloadBoot"))
        XCTAssertTrue(transport.calledPhases.contains("runItem"))
        XCTAssertFalse(result.bootSucceeded)
    }

    func testKeepTransportOpenHoldsHandleAcrossRuns() async {
        let devices = [
            UsbDevice(deviceID: "A", vendorID: 0x2207, productID: 0x0001, productName: "RK-A", serialNumber: nil),
        ]
        let transport = MockUsbTransport(devices: devices)
        let engine = TestExecutionEngine(parser: CfgBinaryParser(), transport: transport)

        // Run 1: device needs boot → opens the transport (once), boots, and —
        // because keepTransportOpen is set — LEAVES it open. This mirrors Windows,
        // which opens its device handle once when the device is detected and holds
        // it across every "start test" click (the 3-repeat Windows capture has zero
        // SET_CONFIGURATION / SET_INTERFACE between clicks).
        let r1 = await engine.run(cfgPath: rk3588Fixture(), keepTransportOpen: true)
        XCTAssertEqual(r1.outcome, .passed)
        XCTAssertEqual(transport.openCount, 1, "run 1 should open exactly once")
        XCTAssertEqual(transport.closeCount, 0, "run 1 should leave the handle open")
        XCTAssertTrue(transport.isOpen)

        // Run 2: device already booted → must NOT re-open (a re-open would reissue
        // SET_CONFIGURATION, which stalls the running test firmware's bulk endpoint).
        // Reuse the held handle and go straight to bulk.
        let r2 = await engine.run(cfgPath: rk3588Fixture(), skipBoot: true, keepTransportOpen: true)
        XCTAssertEqual(r2.outcome, .passed)
        XCTAssertEqual(transport.openCount, 1, "run 2 must not re-open the already-open transport")
        XCTAssertEqual(transport.closeCount, 0)
        XCTAssertTrue(transport.isOpen)

        // Run 3: final run (keepTransportOpen defaults to false) → closes the handle.
        let r3 = await engine.run(cfgPath: rk3588Fixture(), skipBoot: true)
        XCTAssertEqual(r3.outcome, .passed)
        XCTAssertEqual(transport.openCount, 1, "run 3 must not re-open")
        XCTAssertEqual(transport.closeCount, 1, "run 3 should close the handle")
        XCTAssertFalse(transport.isOpen)
    }

    func testKeepTransportOpenKeepsHandleOnFailure() async {
        let devices = [
            UsbDevice(deviceID: "A", vendorID: 0x2207, productID: 0x0001, productName: "RK-A", serialNumber: nil),
        ]
        // A test-item failure (e.g. DDR result != 0) leaves the USB pipe healthy —
        // the device is still booted and its bulk endpoint still alive. With
        // keepTransportOpen the engine must NOT close the handle on failure, so the
        // next "start test" reuses the same claimed interface (skip boot + bulk)
        // instead of reopening (SET_CONFIGURATION) and stalling. Mirrors Windows,
        // which never closes its device handle between clicks.
        let transport = MockUsbTransport(devices: devices, failPhase: "downloadItem")
        let engine = TestExecutionEngine(parser: CfgBinaryParser(), transport: transport)

        let result = await engine.run(cfgPath: rk3588Fixture(), keepTransportOpen: true)

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(transport.isOpen, "keepTransportOpen should hold the handle even on failure")
        XCTAssertEqual(transport.closeCount, 0)
    }

    func testBootSuccessSurvivesLaterFailure() async {
        let devices = [
            UsbDevice(deviceID: "A", vendorID: 0x2207, productID: 0x0001, productName: "RK-A", serialNumber: nil),
        ]
        // Mirrors the GUI repro: the control-transfer boot succeeds, then a later
        // bulk stage fails. The caller must still learn that the device is now
        // booted so the next click can skip boot and reuse the held handle.
        let transport = MockUsbTransport(devices: devices, failPhase: "downloadItem")
        let engine = TestExecutionEngine(parser: CfgBinaryParser(), transport: transport)

        let result = await engine.run(cfgPath: rk3588Fixture(), keepTransportOpen: true)

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.bootSucceeded, "post-boot failures must preserve the boot-succeeded latch")
    }

    private func rk3588Fixture() -> String {
        let repoRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repoRoot.appendingPathComponent("DDRTestFiles/RK3588/16GB LPDDR5(用2片颗粒 每片颗粒2个CS 每个CS有32Gb)焊接检测.cfg").path
    }
}

/// Mock transport that simulates device responses.
/// Per-item pass/fail is driven by `testDeviceReady()`'s result code, mirroring
/// Windows' RKU_TestDeviceReady loop. `readPrintf` returns nothing — device
/// printf is display-only and never affects the verdict.
private final class MockUsbTransport: UsbTransport {
    let devices: [UsbDevice]
    let failPhase: String?
    let failRunResult: Bool
    /// Number of `.running` responses before the device reports `.finished`.
    let runningPollsBeforeFinish: Int
    /// When true, `testDeviceReady` reports `.error` (status word 1) forever.
    let reportError: Bool
    var calledPhases: [String] = []
    private(set) var openCount = 0
    private(set) var closeCount = 0
    private var opened = false
    var isOpen: Bool { opened }
    private var readyCallCount = 0

    init(devices: [UsbDevice], failPhase: String? = nil, failRunResult: Bool = false,
         runningPollsBeforeFinish: Int = 0, reportError: Bool = false) {
        self.devices = devices
        self.failPhase = failPhase
        self.failRunResult = failRunResult
        self.runningPollsBeforeFinish = runningPollsBeforeFinish
        self.reportError = reportError
    }

    func discoverDevices() throws -> [UsbDevice] {
        devices
    }

    func open(device: UsbDevice) throws {
        opened = true
        openCount += 1
    }

    func downloadBoot(item: CfgItem, payload: Data) throws {
        try phase("downloadBoot")
    }

    func downloadItem(item: CfgItem, payload: Data, address: UInt32) throws {
        try phase("downloadItem")
    }

    func downloadParam(item: CfgItem, address: UInt32?, params: [CfgParameter]) throws {
        try phase("downloadParam")
    }

    func runItem(item: CfgItem, address: UInt32) throws {
        try phase("runItem")
    }

    func testDeviceReady() throws -> DeviceReadyStatus {
        // Mirrors Windows sub_416B70 status mapping: status 1 → error,
        // status 2 → running, else → finished (result code in word2).
        if reportError {
            return DeviceReadyStatus(phase: .error, resultCode: 0)
        }
        readyCallCount += 1
        if readyCallCount <= runningPollsBeforeFinish {
            return DeviceReadyStatus(phase: .running, resultCode: 0)
        }
        return DeviceReadyStatus(phase: .finished, resultCode: failRunResult ? 1 : 0)
    }

    func readPrintf() throws -> String? {
        // Device printf is display-only; the mock emits nothing. Pass/fail
        // comes entirely from testDeviceReady() above.
        nil
    }

    func close() throws {
        opened = false
        closeCount += 1
    }

    private func phase(_ name: String) throws {
        guard opened else {
            throw DDRToolError.transportError("device not open")
        }
        calledPhases.append(name)
        if failPhase == name {
            throw DDRToolError.transportError("\(name) failure")
        }
    }
}
