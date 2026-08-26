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

@MainActor
extension SessionTests {

    /// With two boards on the bus, unplugging the one that was probed hands the
    /// selection to the OTHER board — but the latches describing the first one
    /// stayed put. The next 开始 would then skip both the boot and the detect,
    /// and run the first board's cfg against the second board.
    ///
    /// (`deviceRemoved` only fires when the bus goes empty, so the fresh-connection
    /// reset never ran for this case.)
    func testHandingTheSelectionToAnotherBoardDoesNotInheritItsPredecessorsLatches() async throws {
        let vm = MainViewModel()
        let bus = FakeBus(devices: [board("a"), board("b")])
        vm.transportFactory = { bus.makeTransport() }
        try await vm.refreshDevices()
        XCTAssertEqual(vm.selectedDeviceID, "a")

        // Board "a" has been booted and probed, and its handle is held.
        let held = bus.makeTransport()
        try held.open(device: vm.devices[0])
        vm.connection = MainViewModel.Connection(deviceID: "a", transport: held,
                                                 needsBoot: false, probed: true)

        // "a" goes away; "b" is still there, so the bus never goes empty.
        bus.devices = [board("b")]
        try await vm.refreshDevices()

        XCTAssertEqual(vm.selectedDeviceID, "b")
        XCTAssertTrue(vm.connection.needsBoot, "board b must be booted, not assumed booted")
        XCTAssertFalse(vm.connection.probed, "board b must be detected, not assumed detected")
        XCTAssertNil(vm.connection.transport, "board a's handle must not be reused for b")
        XCTAssertEqual(bus.closed, 1, "board a's handle must be closed")
    }
}

@MainActor
extension SessionTests {

    /// The CLI has always been able to target one board (`--device-id`), and the
    /// view model honours `selectedDeviceID` on every path — but nothing in the
    /// UI could set it, and `onDeviceSelectionChanged` had no callers at all.
    func testPickingAnotherBoardRetargetsTheToolToThatChip() async throws {
        let vm = MainViewModel()
        let bus = FakeBus(devices: [board("a", soc: "RK3576"), board("b", soc: "RK3568&RK3566")])
        vm.transportFactory = { bus.makeTransport() }
        try await vm.refreshDevices()
        vm.selectedFileID = "some-cfg"
        XCTAssertEqual(vm.selectedSoc, "RK3576")

        vm.selectedDeviceID = "002-1.1-2207-350E-b"
        vm.onDeviceSelectionChanged()

        XCTAssertEqual(vm.selectedSoc, "RK3568&RK3566")
        XCTAssertNil(vm.selectedFileID, "the other chip's cfg must not stay selected")
    }

    /// Two boards of the SAME model are told apart by the socket they sit in —
    /// which is why deviceID's second field is the port chain and not the USB
    /// address (that one is reassigned on every re-enumeration).
    func testTwoIdenticalBoardsAreLabelledByTheirSocket() {
        let vm = MainViewModel()
        let a = UsbDevice(deviceID: "002-1.1-2207-350A-NA", vendorID: 0x2207, productID: 0x350A,
                          productName: "Rockchip RK3568&RK3566 (0x350A)", serialNumber: nil,
                          socName: "RK3568&RK3566")
        let b = UsbDevice(deviceID: "002-1.4-2207-350A-NA", vendorID: 0x2207, productID: 0x350A,
                          productName: "Rockchip RK3568&RK3566 (0x350A)", serialNumber: nil,
                          socName: "RK3568&RK3566")

        XCTAssertNotEqual(vm.deviceLabel(a), vm.deviceLabel(b))
        XCTAssertTrue(vm.deviceLabel(a).contains("RK3568&RK3566"))
        XCTAssertTrue(vm.deviceLabel(a).contains("1.1"), vm.deviceLabel(a))
        XCTAssertTrue(vm.deviceLabel(b).contains("1.4"), vm.deviceLabel(b))
    }

    private func board(_ id: String, soc: String) -> UsbDevice {
        UsbDevice(deviceID: "002-1.1-2207-350E-\(id)", vendorID: 0x2207, productID: 0x350E,
                  productName: soc, serialNumber: nil, socName: soc)
    }
}

@MainActor
extension SessionTests {

    /// An arrival is bookkeeping, not a command: it must not take the selection
    /// away from the board the operator picked. (This used to be conditional on
    /// an 自动测试 switch, which also STARTED a test on arrival — removed, because
    /// once you can say which board to test, "which board did this arrival mean"
    /// has no good answer.)
    func testAnArrivalDoesNotTakeTheSelection() {
        let vm = MainViewModel()
        vm.devices = [board("a")]
        vm.selectedDeviceID = "a"

        vm.applyDeviceSet([board("a"), board("b")])

        XCTAssertEqual(vm.selectedDeviceID, "a")
        XCTAssertEqual(vm.devices.count, 2)
    }

    func testTheFirstBoardIsSelectedBecauseThereIsNothingElseToPick() {
        let vm = MainViewModel()
        vm.applyDeviceSet([board("a")])
        XCTAssertEqual(vm.selectedDeviceID, "a")
    }

    /// The selection has to be repaired when the board it named goes away.
    func testLosingTheSelectedBoardFallsBackToASurvivor() {
        let vm = MainViewModel()
        vm.devices = [board("a"), board("b")]
        vm.selectedDeviceID = "a"

        vm.applyDeviceSet([board("b")])

        XCTAssertEqual(vm.selectedDeviceID, "b")
    }

    func testAnEmptyBusResetsTheConnection() {
        let vm = MainViewModel()
        vm.devices = [board("a")]
        vm.selectedDeviceID = "a"

        vm.applyDeviceSet([])

        XCTAssertNil(vm.selectedDeviceID)
        XCTAssertTrue(vm.connection.needsBoot)
    }
}
