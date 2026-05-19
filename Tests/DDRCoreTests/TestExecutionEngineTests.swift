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
        let transport = MockUsbTransport(devices: devices, failPrintf: "DQS0 错误!")
        let engine = TestExecutionEngine(parser: CfgBinaryParser(), transport: transport)

        let result = await engine.run(cfgPath: rk3588Fixture())

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.logs.contains(where: { $0.code == "ERROR_ITEM_FAILED" }))
    }

    private func rk3588Fixture() -> String {
        let base = ProcessInfo.processInfo.environment["DDR_USERTOOL_ROOT"]
            ?? "/Users/kevin.zhuang/DDR_UserTool/DDR_UserTool_v1.41"
        return "\(base)/TestFiles/RK3588/16GB LPDDR5(用2片颗粒 每片颗粒2个CS 每个CS有32Gb).cfg"
    }
}

/// Mock transport that simulates device printf responses.
/// For each item, the engine calls readPrintf before run (pre-param) and after run (polling loop).
/// We return the completion marker in the polling loop phase so `deviceReportedFailure`
/// and `isItemLogComplete` see it in `itemLogText`.
private final class MockUsbTransport: UsbTransport {
    let devices: [UsbDevice]
    let failPhase: String?
    let failPrintf: String?
    var calledPhases: [String] = []
    private var opened = false
    private var currentItemName: String?
    // Track whether we've returned the "run" printf for each item
    private var returnedRunPrintf: [String: Bool] = [:]

    init(devices: [UsbDevice], failPhase: String? = nil, failPrintf: String? = nil) {
        self.devices = devices
        self.failPhase = failPhase
        self.failPrintf = failPrintf
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
        currentItemName = item.name
        try phase("downloadItem")
    }

    func downloadParam(item: CfgItem, address: UInt32?, params: [CfgParameter]) throws {
        try phase("downloadParam")
    }

    func runItem(item: CfgItem, address: UInt32) throws {
        try phase("runItem")
    }

    func readPrintf() throws -> String? {
        guard let name = currentItemName else { return nil }

        // Pre-run readPrintf calls (before runItem) return nil
        // Post-run calls return the completion text
        if returnedRunPrintf[name] == nil {
            // First call for this item = pre-run, return nil
            returnedRunPrintf[name] = false
            return nil
        }

        if returnedRunPrintf[name] == false {
            // Second call phase = post-run, return completion text
            returnedRunPrintf[name] = true

            if let failPrintf {
                return failPrintf
            }
            if name.caseInsensitiveCompare("forceinit") == .orderedSame {
                return "Force init DDR pass."
            }
            if name.caseInsensitiveCompare("connect") == .orderedSame {
                return "Summary: PASS."
            }
            return nil
        }

        // Already returned completion, return nil
        return nil
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
