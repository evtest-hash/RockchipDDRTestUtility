import DDRCore
import XCTest
@testable import RockchipDDRTestUtility

/// The step cards the operator watches are built from the engine's log stream.
/// This pipeline used to re-derive what the engine already states: the item name
/// was scraped out of message prose with a regex, and printf / failure entries
/// were attached to "whichever card is currently running" rather than to the
/// card the entry names.
@MainActor
final class StepPipelineTests: XCTestCase {

    func testPrintfLandsOnTheCardTheEntryNamesNotTheLastRunningOne() {
        let vm = MainViewModel()
        begin("forceinit").forEach(vm.handleExecutionLog)
        vm.handleExecutionLog(ok("forceinit"))
        begin("connect").forEach(vm.handleExecutionLog)

        // Late output from forceinit while connect is the live card.
        vm.handleExecutionLog(printf("forceinit tail", item: "forceinit"))

        XCTAssertTrue(messages(vm, "forceinit").contains("forceinit tail"))
        XCTAssertFalse(messages(vm, "connect").contains("forceinit tail"))
    }

    func testAFailureMarksTheCardTheEntryNamesFailed() {
        let vm = MainViewModel()
        begin("forceinit").forEach(vm.handleExecutionLog)
        begin("connect").forEach(vm.handleExecutionLog)
        vm.handleExecutionLog(ExecutionLogEntry(level: .error, code: "ERROR_RUNITEM_FAIL",
                                                message: "boom", itemName: "forceinit"))

        XCTAssertEqual(state(vm, "forceinit"), .failed)
        XCTAssertNotEqual(state(vm, "connect"), .failed)
    }

    /// Entries that genuinely carry no item (device/init lines) still have to go
    /// somewhere — the live card.
    func testAnEntryWithoutAnItemFallsBackToTheLiveCard() {
        let vm = MainViewModel()
        begin("connect").forEach(vm.handleExecutionLog)
        vm.handleExecutionLog(printf("anonymous", item: nil))

        XCTAssertTrue(messages(vm, "connect").contains("anonymous"))
    }

    /// The engine emits INFO_RUNITEM_OK per item, so a card still running when
    /// the whole test passes means an entry went missing. Backfilling is right —
    /// doing it silently is not, because that hides the anomaly.
    func testBackfillingAMissingCompletionSaysSo() {
        let vm = MainViewModel()
        begin("connect").forEach(vm.handleExecutionLog)
        vm.handleExecutionLog(ExecutionLogEntry(level: .info, code: "INFO_TESTDDR_OK",
                                                message: "Testing DDR Success."))

        XCTAssertEqual(state(vm, "connect"), .passed)
        XCTAssertTrue(messages(vm, "connect").contains { $0.contains("推定") },
                      "the backfill must be visible: \(messages(vm, "connect"))")
    }

    func testACompletedCardIsNotAnnotated() {
        let vm = MainViewModel()
        begin("connect").forEach(vm.handleExecutionLog)
        vm.handleExecutionLog(ok("connect"))
        vm.handleExecutionLog(ExecutionLogEntry(level: .info, code: "INFO_TESTDDR_OK",
                                                message: "Testing DDR Success."))

        XCTAssertEqual(state(vm, "connect"), .passed)
        XCTAssertFalse(messages(vm, "connect").contains { $0.contains("推定") })
    }

    // MARK: - helpers

    /// The real sequence: the card is created by the download-start entry, then
    /// the run-start entry moves it to running.
    private func begin(_ item: String) -> [ExecutionLogEntry] {
        [ExecutionLogEntry(level: .info, code: "INFO_DOWNLOADITEM_START",
                           message: "Start to download test item \(item)...", itemName: item),
         ExecutionLogEntry(level: .info, code: "INFO_RUNITEM_START",
                           message: "Start to run test item \(item)", itemName: item)]
    }
    private func ok(_ item: String) -> ExecutionLogEntry {
        ExecutionLogEntry(level: .info, code: "INFO_RUNITEM_OK",
                          message: "Running test item \(item) ok", itemName: item)
    }
    private func printf(_ text: String, item: String?) -> ExecutionLogEntry {
        ExecutionLogEntry(level: .info, code: "INFO_PRINTF", message: text, itemName: item)
    }
    private func messages(_ vm: MainViewModel, _ name: String) -> [String] {
        vm.testSteps.first { $0.name == name }?.messages ?? []
    }
    private func state(_ vm: MainViewModel, _ name: String) -> StepState? {
        vm.testSteps.first { $0.name == name }?.state
    }
}

/// 焊接 and 眼图 are separate tools with separate lifecycles. Their results used
/// to share one `testSteps` array and one `overallConclusion`, so a finished
/// eye-scan card — green PASS and all — showed up in the soldering log pane.
/// An operator reading that card reads a verdict about the wrong test.
@MainActor
final class ToolIsolationTests: XCTestCase {

    func testOneToolsCardsDoNotAppearInTheOthersPane() {
        let vm = MainViewModel()
        vm.mode = .eyescan
        vm.handleExecutionLog(.init(level: .info, code: "INFO_DOWNLOADITEM_START",
                                    message: "…", itemName: "眼图测试"))
        XCTAssertEqual(vm.testSteps.count, 1)

        vm.mode = .solder

        XCTAssertTrue(vm.testSteps.isEmpty, "leaked: \(vm.testSteps.map(\.name))")
    }

    func testAVerdictDoesNotFollowTheOperatorToTheOtherTool() {
        let vm = MainViewModel()
        vm.mode = .eyescan
        vm.overallConclusion = .passed

        vm.mode = .solder

        XCTAssertNil(vm.overallConclusion, "the other tool's PASS must not show here")
    }

    /// Switching away and back must not throw the result away either — the
    /// operator peeks at the other tool and comes back to the same screen.
    func testSwitchingBackRestoresThatToolsResult() {
        let vm = MainViewModel()
        vm.mode = .solder
        vm.handleExecutionLog(.init(level: .info, code: "INFO_DOWNLOADITEM_START",
                                    message: "…", itemName: "forceinit"))
        vm.overallConclusion = .deviceFailed

        vm.mode = .eyescan
        vm.mode = .solder

        XCTAssertEqual(vm.testSteps.map(\.name), ["forceinit"])
        XCTAssertEqual(vm.overallConclusion, .deviceFailed)
    }
}
