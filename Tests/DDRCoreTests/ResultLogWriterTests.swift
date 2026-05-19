import DDRCore
import Foundation
import XCTest

final class ResultLogWriterTests: XCTestCase {
    func testRenderContainsKeyFields() throws {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let finished = Date(timeIntervalSince1970: 1_700_000_010)
        let logs = [
            ExecutionLogEntry(timestamp: started, level: .info, code: "INFO_PRINTF", message: "DDR Test Tool v1.0"),
            ExecutionLogEntry(timestamp: started, level: .info, code: "INFO_PRINTF", message: "Force init DDR pass."),
            ExecutionLogEntry(timestamp: finished, level: .info, code: "INFO_TESTDDR_OK", message: "Testing DDR Success."),
        ]
        let result = ExecutionResult(
            outcome: .passed,
            state: .completed,
            selectedDevice: UsbDevice(deviceID: "1", vendorID: 0x2207, productID: 0x0001, productName: "RK3588", serialNumber: "S1"),
            logs: logs,
            startedAt: started,
            finishedAt: finished
        )

        let writer = ResultLogWriter()
        let output = writer.render(result: result, sourceCfgPath: "/tmp/demo.cfg")

        XCTAssertTrue(output.contains("Result: PASS"))
        XCTAssertTrue(output.contains("Cfg: demo.cfg"))
        XCTAssertTrue(output.contains("Device: RK3588"))
        XCTAssertTrue(output.contains("DDR Test Tool v1.0"))
        XCTAssertTrue(output.contains("Force init DDR pass."))
    }

    func testRenderFailure() throws {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let finished = Date(timeIntervalSince1970: 1_700_000_010)
        let logs = [
            ExecutionLogEntry(timestamp: started, level: .info, code: "INFO_PRINTF", message: "DQS0 错误!"),
        ]
        let result = ExecutionResult(
            outcome: .failed,
            state: .failed,
            selectedDevice: nil,
            logs: logs,
            startedAt: started,
            finishedAt: finished
        )

        let writer = ResultLogWriter()
        let output = writer.render(result: result, sourceCfgPath: "/tmp/test.cfg")

        XCTAssertTrue(output.contains("Result: FAIL"))
        XCTAssertTrue(output.contains("DQS0 错误!"))
    }
}
