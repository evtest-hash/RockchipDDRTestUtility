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

    private func rk3588Fixture() -> String {
        let repoRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repoRoot.appendingPathComponent("DDRTestFiles/RK3588/16GB LPDDR5(用2片颗粒 每片颗粒2个CS 每个CS有32Gb).cfg").path
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
    private var opened = false
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
