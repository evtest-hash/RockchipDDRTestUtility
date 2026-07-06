import DDRCore
import Foundation
import XCTest
@testable import DDRUSB

final class DdrDetectorTests: XCTestCase {
    func testUnsupportedSocThrows() async {
        let det = DdrDetector(resourcesDir: URL(fileURLWithPath: "/tmp"),
                              rkbinDir: URL(fileURLWithPath: "/tmp"))
        let dev = UsbDevice(deviceID: "x", vendorID: 0x2207, productID: 0x350B,
                            productName: "RK3588", serialNumber: nil, socName: "RK3588")
        do {
            _ = try await det.detect(transport: MockTransport(), device: dev, socFiles: [])
            XCTFail("expected unsupportedSoc")
        } catch DetectError.unsupportedSoc { /* ok */ }
        catch { XCTFail("wrong error: \(error)") }
    }
}

/// Minimal `UsbTransport` stub for tests that never actually drive the
/// transport (e.g. the unsupportedSoc guard fires before any transport use).
/// Not reused from `TestExecutionEngineTests.swift` because that file's
/// `MockUsbTransport` is `private` (file-scoped) and also lives in target
/// `DDRCore`'s test dependency only — this one needs to satisfy `UsbTransport`
/// for `DDRUSB` call sites too.
final class MockTransport: UsbTransport {
    var isOpen: Bool { false }
    func discoverDevices() throws -> [UsbDevice] { [] }
    func open(device: UsbDevice) throws {}
    func downloadBoot(item: CfgItem, payload: Data) throws {}
    func downloadItem(item: CfgItem, payload: Data, address: UInt32) throws {}
    func downloadParam(item: CfgItem, address: UInt32?, params: [CfgParameter]) throws {}
    func runItem(item: CfgItem, address: UInt32) throws {}
    func testDeviceReady() throws -> DeviceReadyStatus {
        DeviceReadyStatus(phase: .finished, resultCode: 0)
    }
    func readPrintf() throws -> String? { nil }
    func close() throws {}
}
