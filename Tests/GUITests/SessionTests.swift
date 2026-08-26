import DDRCore
import DDRUSB
import XCTest
@testable import RockchipDDRTestUtility

/// The session state the GUI keeps about the board in front of it. None of this
/// was reachable from a test before: the view model built its own
/// `RkUsbTransportLibusb`, so every path through it needed real hardware.
@MainActor
final class SessionTests: XCTestCase {

    func testTheFirstBoardOnTheBusIsSelected() async throws {
        let vm = MainViewModel()
        let bus = FakeBus(devices: [board("a"), board("b")])
        vm.transportFactory = { bus.makeTransport() }

        try await vm.refreshDevices()

        XCTAssertEqual(vm.devices.count, 2)
        XCTAssertEqual(vm.selectedDeviceID, "a")
    }

    func testAnEmptyBusClearsTheSelection() async throws {
        let vm = MainViewModel()
        let bus = FakeBus(devices: [board("a")])
        vm.transportFactory = { bus.makeTransport() }
        try await vm.refreshDevices()
        XCTAssertEqual(vm.selectedDeviceID, "a")

        bus.devices = []
        try await vm.refreshDevices()

        XCTAssertNil(vm.selectedDeviceID)
    }

    /// `isRunning` and `isDetecting` used to be two independent booleans, so
    /// "detecting AND testing" was representable — and every guard that cared had
    /// to check both. One phase makes the combination unspeakable.
    func testDetectingAndTestingAreMutuallyExclusiveByConstruction() {
        let vm = MainViewModel()
        for phase in [MainViewModel.Phase.idle, .detecting, .testing] {
            vm.phase = phase
            XCTAssertFalse(vm.isRunning && vm.isDetecting, "\(phase)")
        }
        vm.phase = .detecting
        XCTAssertTrue(vm.isDetecting)
        vm.phase = .testing
        XCTAssertTrue(vm.isRunning)
        vm.phase = .idle
        XCTAssertFalse(vm.isRunning || vm.isDetecting)
    }

    private func board(_ id: String) -> UsbDevice {
        UsbDevice(deviceID: id, vendorID: 0x2207, productID: 0x350E,
                  productName: "RK3576", serialNumber: nil, socName: "RK3576")
    }
}

/// A bus whose contents the test controls. `makeTransport()` hands out a fresh
/// transport each call, like the real factory does.
final class FakeBus: @unchecked Sendable {
    var devices: [UsbDevice]
    private(set) var opened = 0
    private(set) var closed = 0

    init(devices: [UsbDevice]) { self.devices = devices }

    func makeTransport() -> UsbTransport { FakeTransport(bus: self) }

    fileprivate func noteOpen() { opened += 1 }
    fileprivate func noteClose() { closed += 1 }
}

private final class FakeTransport: UsbTransport, @unchecked Sendable {
    private let bus: FakeBus
    private var open = false
    init(bus: FakeBus) { self.bus = bus }

    var isOpen: Bool { open }
    func discoverDevices() throws -> [UsbDevice] { bus.devices }
    func open(device: UsbDevice) throws { open = true; bus.noteOpen() }
    func downloadBoot(item: CfgItem, payload: Data, lenientFinalChunk: Bool) throws {}
    func downloadItem(item: CfgItem, payload: Data, address: UInt32) throws {}
    func downloadParam(item: CfgItem, address: UInt32?, params: [CfgParameter]) throws {}
    func runItem(item: CfgItem, address: UInt32) throws {}
    func testDeviceReady() throws -> DeviceReadyStatus { .init(phase: .finished, resultCode: 0) }
    func readPrintf() throws -> String? { nil }
    func close() throws { open = false; bus.noteClose() }
}

@MainActor
extension SessionTests {

    /// Losing the board must drop EVERY latch that described it, not just the
    /// handle: a stale "already booted" or "already probed" would make the next
    /// board skip its boot or its detect.
    func testLosingTheBoardDropsTheHandleAndEveryLatchWithIt() async throws {
        let vm = MainViewModel()
        let bus = FakeBus(devices: [UsbDevice(deviceID: "a", vendorID: 0x2207, productID: 0x350E,
                                              productName: "RK3576", serialNumber: nil, socName: "RK3576")])
        vm.transportFactory = { bus.makeTransport() }
        try await vm.refreshDevices()

        // Stand in for a completed run: handle held, boot done, detect done.
        let held = bus.makeTransport()
        try held.open(device: vm.devices[0])
        vm.connection = MainViewModel.Connection(deviceID: "a", transport: held,
                                                 needsBoot: false, probed: true)

        bus.devices = []
        try await vm.refreshDevices()
        vm.handleDeviceLost()

        XCTAssertEqual(bus.closed, 1, "the held handle must be closed, not leaked")
        XCTAssertNil(vm.connection.transport)
        XCTAssertNil(vm.connection.deviceID)
        XCTAssertTrue(vm.connection.needsBoot, "a replug must boot again")
        XCTAssertFalse(vm.connection.probed, "a replug must detect again")
    }
}
