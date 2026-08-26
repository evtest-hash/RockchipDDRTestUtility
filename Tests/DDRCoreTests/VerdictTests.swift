import XCTest
@testable import DDRCore

/// The verdict layer: every pass/fail decision the GUI and the CLI make.
/// Both used to carry their own copy — they drifted, and the GUI's copy
/// reported PASS on a board the firmware had judged bad. These pin the
/// single shared implementation.
final class VerdictTests: XCTestCase {

    // MARK: - eye-scan

    /// Golden regression, captured from an RK3566 whose cs0 WR eye failed.
    /// The device speaks CRLF, and `"\r\n"` is ONE Swift Character — so
    /// `split(separator: "\n")` never splits it, the whole transcript comes
    /// back as a single "line", and any `contains("pass")` test on it passes
    /// because the earlier per-channel `pass` lines are in that same blob.
    /// That is exactly how a bad board was reported PASS.
    func testCRLFTranscriptDoesNotMaskAFailingResultLine() throws {
        let url = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/eyescan_rk3566_cs0wr_fail_crlf.txt")
        let transcript = try String(contentsOf: url, encoding: .utf8)

        let report = EyescanVerdict.parse(transcript)

        XCTAssertTrue(report.scanCompleted, "the fixture ends with the done marker")
        XCTAssertEqual(report.resultLines, ["all result: err"],
                       "one summary line — not the whole transcript as one blob")
        XCTAssertFalse(report.pass, "the firmware said err; this board must not read as PASS")
        XCTAssertEqual(report.displayLine, "all result: err")
    }

    func testPassRequiresEveryChannelSummaryToPass() {
        let t = "cs0 result:\r\npass\r\nall result: pass\r\nall result: pass\r\nall dq eye scan done\r\n"
        XCTAssertTrue(EyescanVerdict.parse(t).pass)
    }

    /// Multi-channel SoCs (RK3576 dual, RK3588 quad) print one summary per
    /// channel. A later channel's pass must never bury an earlier failure.
    func testOneFailingChannelFailsTheWholeScan() {
        let t = "all result:   fail\r\nall result: pass\r\nall dq eye scan done\r\n"
        let report = EyescanVerdict.parse(t)
        XCTAssertFalse(report.pass)
        XCTAssertEqual(report.displayLine, "all result:   fail", "show the channel that failed")
    }

    /// No done marker → the scan never finished, so there is no verdict to give.
    func testMissingDoneMarkerIsNotAPass() {
        let t = "all result: pass\r\n"
        let report = EyescanVerdict.parse(t)
        XCTAssertFalse(report.scanCompleted)
        XCTAssertFalse(report.pass)
    }

    func testNoSummaryLineIsNotAPass() {
        XCTAssertFalse(EyescanVerdict.parse("all dq eye scan done\r\n").pass)
    }

    func testBareLFTranscriptStillParses() {
        let t = "all result: pass\nall dq eye scan done\n"
        XCTAssertTrue(EyescanVerdict.parse(t).pass)
    }

    // MARK: - run conclusion (solder)

    private func solderResult(_ outcome: TestOutcome, _ failure: FailureKind?) -> ExecutionResult {
        ExecutionResult(outcome: outcome, state: outcome == .passed ? .completed : .failed,
                        selectedDevice: nil, logs: [], startedAt: Date(), finishedAt: Date(),
                        failure: failure)
    }

    /// A bulk timeout means the board was never tested. Reporting it as
    /// "测试失败" scraps a good board — the mistake the CLI's exit 1 vs 2
    /// split already fixed on its side.
    func testTransportFailureIsInconclusiveNotABadBoard() {
        let c = RunConclusion.solder(solderResult(.failed, .transport))
        XCTAssertEqual(c, .inconclusive(.transport))
        XCTAssertFalse(c.isDeviceVerdict, "nothing about the DDR was decided")
    }

    func testDeviceVerdictIsABadBoard() {
        let c = RunConclusion.solder(solderResult(.failed, .deviceVerdict))
        XCTAssertEqual(c, .deviceFailed)
        XCTAssertTrue(c.isDeviceVerdict)
    }

    func testMissingCfgIsInconclusive() {
        XCTAssertEqual(RunConclusion.solder(solderResult(.failed, .cfg)), .inconclusive(.cfg))
    }

    func testPassIsPass() {
        XCTAssertEqual(RunConclusion.solder(solderResult(.passed, nil)), .passed)
    }

    /// Defensive: a failed run that names no reason must not read as a device
    /// verdict — `FailureKind.classify` is conservative for the same reason.
    func testFailureWithoutAReasonIsInconclusive() {
        XCTAssertEqual(RunConclusion.solder(solderResult(.failed, nil)), .inconclusive(.transport))
    }

    // MARK: - run conclusion (eye-scan)

    func testWedgedDeviceIsInconclusive() {
        let report = EyescanVerdict.parse("all result: pass\r\nall dq eye scan done\r\n")
        let c = RunConclusion.eyescan(report: report, wedged: true, completedViaStatus: false)
        XCTAssertEqual(c, .inconclusive(.deviceWedged))
    }

    /// Still streaming at the deadline: the board is fine, the timeout was short.
    func testScanStillStreamingAtDeadlineIsInconclusive() {
        let report = EyescanVerdict.parse("all result: pass\r\nall dq eye scan done\r\n")
        let c = RunConclusion.eyescan(report: report, wedged: false, completedViaStatus: false)
        XCTAssertEqual(c, .inconclusive(.scanIncomplete))
    }

    func testCompletedFailingScanIsABadBoard() {
        let report = EyescanVerdict.parse("all result: err\r\nall dq eye scan done\r\n")
        let c = RunConclusion.eyescan(report: report, wedged: false, completedViaStatus: true)
        XCTAssertEqual(c, .deviceFailed)
    }

    func testCompletedPassingScanPasses() {
        let report = EyescanVerdict.parse("all result: pass\r\nall dq eye scan done\r\n")
        let c = RunConclusion.eyescan(report: report, wedged: false, completedViaStatus: true)
        XCTAssertEqual(c, .passed)
    }

    /// Device reported done, transport was fine, but the output carries no done
    /// marker — the scan itself misbehaved, so there is no verdict.
    func testCompletedStatusWithoutDoneMarkerIsInconclusive() {
        let report = EyescanVerdict.parse("all result: pass\r\n")
        let c = RunConclusion.eyescan(report: report, wedged: false, completedViaStatus: true)
        XCTAssertEqual(c, .inconclusive(.scanIncomplete))
    }

    // MARK: - detect adoption

    func testUniqueMatchIsAdopted() {
        XCTAssertEqual(DetectVerdict.decide(.uniqueByCoarse), .adopt)
        XCTAssertEqual(DetectVerdict.decide(.uniqueByTieBreak), .adopt)
    }

    /// The iron rule: never run a cfg the geometry did not uniquely pick.
    func testAmbiguousAndNoMatchGoToTheOperator() {
        XCTAssertEqual(DetectVerdict.decide(.ambiguous), .manual)
        XCTAssertEqual(DetectVerdict.decide(.none), .manual)
    }
}
