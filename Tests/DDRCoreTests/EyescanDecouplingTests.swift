import XCTest
import DDRCore
@testable import DDRUSB

/// Stress tests for the CORE guarantee the user demanded: a slow (or hung) UI must NEVER be able to
/// stall or starve the USB drain link, and it must never lose scan data. These drive the real
/// `EyescanRunner.run` drain loop with a mock transport that produces at full speed and a
/// deliberately SLOW `onProgress`, then assert on timing + integrity.
final class EyescanDecouplingTests: XCTestCase {

    private static let dev = UsbDevice(deviceID: "stress", vendorID: 0x2207, productID: 0x350B,
                                       productName: "RK3588 (stress)", serialNumber: nil,
                                       usbAddress: 4)
    /// The same socket after the board reset: identical id (it names the port), new USB address.
    private static let devReenumerated = UsbDevice(deviceID: "stress", vendorID: 0x2207, productID: 0x350B,
                                                   productName: "RK3588 (stress)", serialNumber: nil,
                                                   usbAddress: 7)

    /// One synthetic printf chunk (a realistic eyescan line) + its byte length.
    private static let chunk = "vref 42.1%:----********----[7 ~ -4 ~ -16(23)] dq0 12 34 56 78\n"
    private static let chunkBytes = chunk.utf8.count

    /// Thread-safe tally of onProgress deliveries (onProgress is @Sendable, called off the uiTask).
    private actor Counter { var value = 0; func inc() { value += 1 } }

    /// Mock transport: `readPrintf` hands back `chunk` `totalChunks` times (recording each return
    /// time), then returns empty; `testDeviceReady` reports `.finished` once the ring is drained.
    private final class StreamingMockTransport: UsbTransport {
        let device: UsbDevice
        let chunk: String
        let totalChunks: Int
        /// When false, `testDeviceReady` reports `.running` forever — the wedged board:
        /// the item never returns, so the device never signals done.
        let everFinishes: Bool
        /// Successive `discoverDevices` answers once the reboot item has been RUN. Simulates the
        /// board dropping off the bus and coming back. Empty ⇒ the device never disappears.
        let afterRebootEnumerations: [[UsbDevice]]
        private(set) var readTimestamps: [Date] = []
        private(set) var itemsDownloaded: [String] = []
        private(set) var itemsRun: [String] = []
        private var produced = 0
        private var opened = false
        private var rebootRan = false
        private var enumIndex = 0
        var isOpen: Bool { opened }

        init(device: UsbDevice, chunk: String, totalChunks: Int,
             everFinishes: Bool = true, afterRebootEnumerations: [[UsbDevice]] = []) {
            self.device = device; self.chunk = chunk; self.totalChunks = totalChunks
            self.everFinishes = everFinishes; self.afterRebootEnumerations = afterRebootEnumerations
        }
        func discoverDevices() throws -> [UsbDevice] {
            guard rebootRan, !afterRebootEnumerations.isEmpty else { return [device] }
            let list = afterRebootEnumerations[min(enumIndex, afterRebootEnumerations.count - 1)]
            enumIndex += 1
            return list
        }
        func open(device: UsbDevice) throws { opened = true }
        func downloadBoot(item: CfgItem, payload: Data, lenientFinalChunk: Bool) throws {}
        func downloadItem(item: CfgItem, payload: Data, address: UInt32) throws {
            itemsDownloaded.append(item.name)
        }
        func downloadParam(item: CfgItem, address: UInt32?, params: [CfgParameter]) throws {}
        func runItem(item: CfgItem, address: UInt32) throws {
            itemsRun.append(item.name)
            if item.name == "reboot" { rebootRan = true }
        }
        func testDeviceReady() throws -> DeviceReadyStatus {
            DeviceReadyStatus(phase: (everFinishes && produced >= totalChunks) ? .finished : .running,
                              resultCode: 0)
        }
        func readPrintf() throws -> String? { try readPrintf(acknowledge: true) }
        func readPrintf(acknowledge: Bool) throws -> String? {
            guard produced < totalChunks else { return nil }
            produced += 1
            readTimestamps.append(Date())
            return chunk
        }
        func close() throws { opened = false }
    }

    private func runScan(chunks: Int, uiDelayMs: UInt64, timeout: TimeInterval = 60,
                         rebootBin: Data? = nil, everFinishes: Bool = true,
                         afterRebootEnumerations: [[UsbDevice]] = [],
                         stallSilence: TimeInterval = 5)
        async throws -> (outcome: EyescanRunner.Outcome, delivered: Int, mock: StreamingMockTransport) {
        let mock = StreamingMockTransport(device: Self.dev, chunk: Self.chunk, totalChunks: chunks,
                                          everFinishes: everFinishes,
                                          afterRebootEnumerations: afterRebootEnumerations)
        let counter = Counter()
        let onProgress: @Sendable (String) async -> Void = { _ in
            if uiDelayMs > 0 { try? await Task.sleep(nanoseconds: uiDelayMs * 1_000_000) }
            await counter.inc()
        }
        let outcome = try await EyescanRunner().run(
            transport: mock, device: Self.dev,
            ddrBin: Data(), ddrTestTool: Data([0]), itemBin: Data(count: 16),
            itemBase: 0xFF00_4000, timeout: timeout, rebootBin: rebootBin,
            stallSilence: stallSilence, onProgress: onProgress)
        return (outcome, await counter.value, mock)
    }

    /// A slow UI must NOT slow the USB drain: the drain reads every chunk in a tight window even
    /// though delivering them to onProgress would take N × delay. And no byte is lost.
    func testSlowUIDoesNotStallDrain() async throws {
        let n = 500
        let uiDelayMs: UInt64 = 10        // coupled ⇒ drain would take 500×10ms = 5s
        let (outcome, delivered, mock) = try await runScan(chunks: n, uiDelayMs: uiDelayMs)
        let transcript = outcome.transcript

        // Data integrity: the transcript captured EVERY produced byte, in order.
        XCTAssertEqual(transcript.utf8.count, n * Self.chunkBytes)
        XCTAssertEqual(mock.readTimestamps.count, n)

        // Decoupling: the drain finished reading all n chunks in far less than the UI would take.
        let drainWindow = mock.readTimestamps.last!.timeIntervalSince(mock.readTimestamps.first!)
        let uiTotal = Double(n) * Double(uiDelayMs) / 1000.0    // 5.0s if the UI gated the drain
        XCTAssertLessThan(drainWindow, uiTotal * 0.5,
                          "drain window \(drainWindow)s must be << UI total \(uiTotal)s (UI must not gate the drain)")

        // Buffer big enough for 500 ⇒ the display got everything too.
        XCTAssertEqual(delivered, n)
    }

    /// Under UI OVERLOAD (far more chunks than the hand-off buffer, slow consumer) the DISPLAY drops
    /// its oldest queued chunks — but the transcript (verdict/save data) stays complete.
    func testUIOverloadDropsDisplayNeverData() async throws {
        let n = 6000                       // > the 2048 bounded hand-off buffer
        let (outcome, delivered, mock) = try await runScan(chunks: n, uiDelayMs: 1)

        XCTAssertEqual(mock.readTimestamps.count, n)
        XCTAssertEqual(outcome.transcript.utf8.count, n * Self.chunkBytes, "data must be COMPLETE regardless of UI")
        XCTAssertGreaterThan(delivered, 0)
        XCTAssertLessThan(delivered, n, "an overloaded display must drop chunks (bounded buffer), not the data")
    }

    /// Fast UI, large scan: everything is delivered and captured (no spurious drops when UI keeps up).
    func testFastUIDeliversEverything() async throws {
        let n = 1500
        let (outcome, delivered, _) = try await runScan(chunks: n, uiDelayMs: 0)
        XCTAssertEqual(outcome.transcript.utf8.count, n * Self.chunkBytes)
        XCTAssertEqual(delivered, n)
    }

    // MARK: - Auto-return to maskrom

    /// A stalled run must STILL be sent the reboot. Skipping it was measured to be wrong: a
    /// stalled board recovered on the next run precisely because the reboot was sent anyway. A
    /// deadline means we never saw the completion signal, not that the device stopped answering,
    /// and the asymmetry is stark — attempting costs seconds, skipping costs a physical replug.
    func testWedgedRunStillAttemptsReboot() async throws {
        // The device goes silent immediately and never reports done ⇒ the item stopped.
        let (outcome, _, mock) = try await runScan(chunks: 3, uiDelayMs: 0, timeout: 0.6,
                                                   rebootBin: Data([0xAA]), everFinishes: false,
                                                   stallSilence: 0.2)
        XCTAssertFalse(outcome.completedViaStatus)
        XCTAssertTrue(outcome.wedged, "silent device at the deadline ⇒ wedged")
        XCTAssertTrue(mock.itemsDownloaded.contains("reboot"), "a stalled board must still be offered the reboot")
        XCTAssertTrue(mock.itemsRun.contains("reboot"))
    }

    /// HW-observed on RK3576: a stress item streaming steadily at ~1 KB/s simply outlasts the
    /// timeout, with data still arriving as it fires. That board is HEALTHY — it must not be
    /// called wedged, and the reboot must still be sent.
    func testSlowButLiveItemIsNotWedgedAndStillReboots() async throws {
        let (outcome, _, mock) = try await runScan(chunks: 100_000, uiDelayMs: 0, timeout: 0.6,
                                                   rebootBin: Data([0xAA]), everFinishes: false,
                                                   afterRebootEnumerations: [[], [Self.devReenumerated]],
                                                   stallSilence: 5)
        XCTAssertFalse(outcome.completedViaStatus, "deadline hit before the item finished")
        XCTAssertFalse(outcome.wedged, "data was still flowing ⇒ NOT wedged")
        XCTAssertTrue(mock.itemsRun.contains("reboot"), "a live board must still be rebooted")
        XCTAssertEqual(outcome.returnedToMaskrom, true)
    }

    /// A completed run sends the reboot and confirms the board actually reset: the pre-reboot
    /// identity disappears from the bus and the PID comes back.
    func testCompletedRunRebootsAndConfirmsReset() async throws {
        let (outcome, _, mock) = try await runScan(chunks: 3, uiDelayMs: 0, rebootBin: Data([0xAA]),
                                                   afterRebootEnumerations: [[], [Self.devReenumerated]])
        XCTAssertTrue(outcome.completedViaStatus)
        XCTAssertTrue(mock.itemsRun.contains("reboot"))
        XCTAssertEqual(outcome.returnedToMaskrom, true, "same socket, new USB address ⇒ reset fired")
    }

    /// A reset that is never observed must be reported as UNKNOWN, not as failure. The absence
    /// window can be shorter than any poll and the host may reassign the same address, so both
    /// signals give false negatives on boards that did reboot — measured on RK3576. Asserting
    /// failure here is what sent an earlier investigation chasing a device fault that did not exist.
    func testUnobservedResetIsReportedAsUnknownNotFailure() async throws {
        let (outcome, _, mock) = try await runScan(chunks: 3, uiDelayMs: 0, timeout: 20,
                                                   rebootBin: Data([0xAA]),
                                                   afterRebootEnumerations: [[Self.dev]])
        XCTAssertTrue(outcome.completedViaStatus)
        XCTAssertTrue(mock.itemsRun.contains("reboot"))
        XCTAssertNil(outcome.returnedToMaskrom, "not observed ⇒ unknown, never a claim that it did not reset")
    }
}
