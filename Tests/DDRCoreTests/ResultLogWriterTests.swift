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

    /// A run the DEVICE judged bad. Predates `FailureKind`, so it used to pass a
    /// bare `.failed` — which now (correctly) renders as NO VERDICT, since a
    /// failure naming no reason must never be archived as a bad board.
    func testRenderDeviceVerdictFailure() throws {
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
            finishedAt: finished,
            failure: .deviceVerdict
        )

        let writer = ResultLogWriter()
        let output = writer.render(result: result, sourceCfgPath: "/tmp/test.cfg")

        XCTAssertTrue(output.contains("Result: FAIL"))
        XCTAssertTrue(output.contains("DQS0 错误!"))
    }

    // MARK: - three-state result line

    /// The archived file is what an operator files away and what a later dispute
    /// is settled from. It used to print `Result: FAIL` for a USB timeout — the
    /// same conflation the GUI badge had, just hidden in a file nobody re-reads.
    func testATransportFailureIsNotArchivedAsFAIL() throws {
        let out = render(.failed, failure: .transport)
        XCTAssertFalse(out.contains("Result: FAIL"), out)
        XCTAssertTrue(out.contains("Result: NO VERDICT"), out)
        XCTAssertTrue(out.contains("transport"), "the reason must be in the file too")
    }

    func testOnlyADeviceVerdictIsArchivedAsFAIL() throws {
        XCTAssertTrue(render(.failed, failure: .deviceVerdict).contains("Result: FAIL"))
    }

    func testAMissingCfgIsNotADeviceVerdict() throws {
        XCTAssertTrue(render(.failed, failure: .cfg).contains("Result: NO VERDICT"))
    }

    /// Conservative, like every other classifier here: a failure that names no
    /// reason must not be archived as a bad board.
    func testAFailureWithoutAReasonIsNotArchivedAsFAIL() throws {
        XCTAssertTrue(render(.failed, failure: nil).contains("Result: NO VERDICT"))
    }

    func testPassIsStillPass() throws {
        XCTAssertTrue(render(.passed, failure: nil).contains("Result: PASS"))
    }

    private func render(_ outcome: TestOutcome, failure: FailureKind?) -> String {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let result = ExecutionResult(outcome: outcome, state: outcome == .passed ? .completed : .failed,
                                     selectedDevice: nil, logs: [], startedAt: t, finishedAt: t,
                                     failure: failure)
        return ResultLogWriter().render(result: result, sourceCfgPath: "/tmp/x.cfg")
    }
}
