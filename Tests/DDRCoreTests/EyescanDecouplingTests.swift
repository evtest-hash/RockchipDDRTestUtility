import XCTest
import DDRCore
@testable import DDRUSB

/// Stress tests for the CORE guarantee the user demanded: a slow (or hung) UI must NEVER be able to
/// stall or starve the USB drain link, and it must never lose scan data. These drive the real
/// `EyescanRunner.run` drain loop with a mock transport that produces at full speed and a
/// deliberately SLOW `onProgress`, then assert on timing + integrity.
final class EyescanDecouplingTests: XCTestCase {

    private static let dev = UsbDevice(deviceID: "stress", vendorID: 0x2207, productID: 0x350B,
                                       productName: "RK3588 (stress)", serialNumber: nil)

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
        private(set) var readTimestamps: [Date] = []
        private var produced = 0
        private var opened = false
        var isOpen: Bool { opened }

        init(device: UsbDevice, chunk: String, totalChunks: Int) {
            self.device = device; self.chunk = chunk; self.totalChunks = totalChunks
        }
        func discoverDevices() throws -> [UsbDevice] { [device] }
        func open(device: UsbDevice) throws { opened = true }
        func downloadBoot(item: CfgItem, payload: Data, lenientFinalChunk: Bool) throws {}
        func downloadItem(item: CfgItem, payload: Data, address: UInt32) throws {}
        func downloadParam(item: CfgItem, address: UInt32?, params: [CfgParameter]) throws {}
        func runItem(item: CfgItem, address: UInt32) throws {}
        func testDeviceReady() throws -> DeviceReadyStatus {
            DeviceReadyStatus(phase: produced >= totalChunks ? .finished : .running, resultCode: 0)
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

    private func runScan(chunks: Int, uiDelayMs: UInt64, timeout: TimeInterval = 60)
        async throws -> (transcript: String, delivered: Int, mock: StreamingMockTransport) {
        let mock = StreamingMockTransport(device: Self.dev, chunk: Self.chunk, totalChunks: chunks)
        let counter = Counter()
        let onProgress: @Sendable (String) async -> Void = { _ in
            if uiDelayMs > 0 { try? await Task.sleep(nanoseconds: uiDelayMs * 1_000_000) }
            await counter.inc()
        }
        let transcript = try await EyescanRunner().run(
            transport: mock, device: Self.dev,
            ddrBin: Data(), ddrTestTool: Data([0]), itemBin: Data(count: 16),
            itemBase: 0xFF00_4000, timeout: timeout, rebootBin: nil, onProgress: onProgress)
        return (transcript, await counter.value, mock)
    }

    /// A slow UI must NOT slow the USB drain: the drain reads every chunk in a tight window even
    /// though delivering them to onProgress would take N × delay. And no byte is lost.
    func testSlowUIDoesNotStallDrain() async throws {
        let n = 500
        let uiDelayMs: UInt64 = 10        // coupled ⇒ drain would take 500×10ms = 5s
        let (transcript, delivered, mock) = try await runScan(chunks: n, uiDelayMs: uiDelayMs)

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
        let (transcript, delivered, mock) = try await runScan(chunks: n, uiDelayMs: 1)

        XCTAssertEqual(mock.readTimestamps.count, n)
        XCTAssertEqual(transcript.utf8.count, n * Self.chunkBytes, "data must be COMPLETE regardless of UI")
        XCTAssertGreaterThan(delivered, 0)
        XCTAssertLessThan(delivered, n, "an overloaded display must drop chunks (bounded buffer), not the data")
    }

    /// Fast UI, large scan: everything is delivered and captured (no spurious drops when UI keeps up).
    func testFastUIDeliversEverything() async throws {
        let n = 1500
        let (transcript, delivered, _) = try await runScan(chunks: n, uiDelayMs: 0)
        XCTAssertEqual(transcript.utf8.count, n * Self.chunkBytes)
        XCTAssertEqual(delivered, n)
    }
}
