import DDRCore
import Foundation
import XCTest
@testable import DDRUSB

/// `DdrDetector` drives its probe items (osregdump, otpdump) itself rather than
/// through `TestExecutionEngine`. It used to decide an item was over by looking
/// at the CAPTURED TEXT — but completion is a device STATE, so it could return
/// while the item was still running and the next `downloadItem` would then hit a
/// firmware that isn't back in its command loop.
///
/// The polling rule is transcribed from `EyescanRunner`, where it was measured:
/// opcode 0 contends with a producing item on the same device-side service loop,
/// so status is probed ONLY when the printf ring has gone quiet.
final class ProbeItemTests: XCTestCase {

    func testWaitsForTheDeviceToReportTheItemFinished() async throws {
        let t = ScriptedTransport(printf: ["OTP_ALIVE", "OTP_DUMP 0"], runningPolls: 3)
        let run = try await DdrDetector.runProbeItem(
            transport: t, item: probeItem(), payload: Data([1, 2, 3]), base: 0, timeout: 5)

        XCTAssertTrue(run.returned, "must not return before the device says finished")
        XCTAssertTrue(run.captured.contains("OTP_ALIVE"))
        XCTAssertTrue(run.captured.contains("OTP_DUMP 0"))
    }

    /// The hot-path rule: while printf is handing back data the item is still
    /// producing, and an opcode-0 in that window throttles the device.
    func testDoesNotPollStatusWhilePrintfIsStillReturningData() async throws {
        let t = ScriptedTransport(printf: ["a", "b", "c"], runningPolls: 0)
        _ = try await DdrDetector.runProbeItem(
            transport: t, item: probeItem(), payload: Data([1]), base: 0, timeout: 5)

        let firstStatus = t.calls.firstIndex(of: "testDeviceReady") ?? t.calls.count
        let lastData = t.calls.lastIndex(of: "readPrintf:data") ?? -1
        XCTAssertGreaterThan(firstStatus, lastData,
                             "status was polled while data was still flowing: \(t.calls)")
    }

    /// Degrade to today's behaviour rather than inventing a new failure mode:
    /// a device that never reports finished still yields what was captured.
    func testTimeoutReturnsTheCaptureInsteadOfThrowing() async throws {
        let t = ScriptedTransport(printf: ["partial"], runningPolls: .max)
        let run = try await DdrDetector.runProbeItem(
            transport: t, item: probeItem(), payload: Data([1]), base: 0, timeout: 0.3)

        XCTAssertFalse(run.returned)
        XCTAssertTrue(run.captured.contains("partial"))
    }

    /// A transient status failure must not abort a run whose output is already
    /// captured — the item returns, then the loader stays briefly busy.
    func testTransientStatusErrorsAreToleratedAndPollingContinues() async throws {
        let t = ScriptedTransport(printf: ["x"], runningPolls: 0, statusThrows: 2)
        let run = try await DdrDetector.runProbeItem(
            transport: t, item: probeItem(), payload: Data([1]), base: 0, timeout: 5)

        XCTAssertTrue(run.returned)
        XCTAssertEqual(t.statusFailures, 2)
    }

    func testDownloadsAndRunsTheItemBeforeReadingAnything() async throws {
        let t = ScriptedTransport(printf: ["x"], runningPolls: 0)
        _ = try await DdrDetector.runProbeItem(
            transport: t, item: probeItem(), payload: Data([1]), base: 0, timeout: 5)

        XCTAssertEqual(Array(t.calls.prefix(2)), ["downloadItem", "runItem"])
    }

    private func probeItem() -> CfgItem {
        CfgItem(name: "osregdump", payloadOffset: 0, payloadLength: 3)
    }
}

/// Transport whose printf and status responses are scripted, recording the call
/// order so a test can assert WHEN status was polled, not just how often.
final class ScriptedTransport: UsbTransport, @unchecked Sendable {
    private var printfQueue: [String]
    private var runningPolls: Int
    private var statusThrows: Int
    private(set) var calls: [String] = []
    private(set) var statusFailures = 0

    init(printf: [String], runningPolls: Int, statusThrows: Int = 0) {
        self.printfQueue = printf
        self.runningPolls = runningPolls
        self.statusThrows = statusThrows
    }

    var isOpen: Bool { true }
    func discoverDevices() throws -> [UsbDevice] { [] }
    func open(device: UsbDevice) throws {}
    func downloadBoot(item: CfgItem, payload: Data, lenientFinalChunk: Bool) throws {}
    func downloadItem(item: CfgItem, payload: Data, address: UInt32) throws { calls.append("downloadItem") }
    func downloadParam(item: CfgItem, address: UInt32?, params: [CfgParameter]) throws {}
    func runItem(item: CfgItem, address: UInt32) throws { calls.append("runItem") }
    func close() throws {}

    func readPrintf() throws -> String? {
        if printfQueue.isEmpty {
            calls.append("readPrintf:empty")
            return nil
        }
        calls.append("readPrintf:data")
        return printfQueue.removeFirst()
    }

    func testDeviceReady() throws -> DeviceReadyStatus {
        calls.append("testDeviceReady")
        if statusThrows > 0 {
            statusThrows -= 1
            statusFailures += 1
            throw DDRToolError.transportError("scripted status failure")
        }
        if runningPolls > 0 {
            runningPolls -= 1
            return DeviceReadyStatus(phase: .running, resultCode: 0)
        }
        return DeviceReadyStatus(phase: .finished, resultCode: 0)
    }
}
