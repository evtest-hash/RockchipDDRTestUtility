import Foundation

public protocol UsbTransport {
    /// True while a device handle is held open. Used by the engine to decide
    /// whether `run()` needs to open the device (which reissues
    /// SET_CONFIGURATION) or can reuse an already-open handle — mirroring
    /// Windows, which opens its device handle once and holds it across every
    /// "start test" click so repeated bulk tests never re-configure the pipe.
    var isOpen: Bool { get }
    func discoverDevices() throws -> [UsbDevice]
    func open(device: UsbDevice) throws
    func downloadBoot(item: CfgItem, payload: Data, lenientFinalChunk: Bool) throws
    func downloadItem(item: CfgItem, payload: Data, address: UInt32) throws
    func downloadParam(item: CfgItem, address: UInt32?, params: [CfgParameter]) throws
    func runItem(item: CfgItem, address: UInt32) throws
    /// Poll device status via `RKU_TestDeviceReady` (opcode 0). This is the
    /// Windows failure-detection path: pass/fail comes from the status word and
    /// result code in the 16-byte response, not from printf text. See
    /// `DeviceReadyStatus` and DDR_UserTool `sub_416B70` / `sub_406420`.
    func testDeviceReady() throws -> DeviceReadyStatus
    func readPrintf() throws -> String?
    /// Like `readPrintf()`, but `acknowledge:false` skips the post-read
    /// `RKU_TestDeviceReady` handshake. That handshake is what the resident
    /// firmware is slow to answer during heavy streaming (~500ms/read on the
    /// eye-scan), yet the DDR Test Tool's printf ring advances on the read
    /// itself (drain fn `sub_FDCC1904`), so the ack is redundant there. High-rate
    /// drains (eye-scan) pass false; other flows keep true.
    func readPrintf(acknowledge: Bool) throws -> String?
    /// Cheap "is the device still answering us" probe, used by the GUI's idle
    /// keep-alive (macOS suspends an idle handle otherwise) and as the readiness
    /// gate between detect and the first test item. Never throws: liveness is the
    /// answer, so a failed transfer IS the answer (false).
    func probeAlive() -> Bool
    func close() throws
}

/// Extension providing default parameter values for protocol methods.
public extension UsbTransport {
    func downloadBoot(item: CfgItem, payload: Data) throws {
        try downloadBoot(item: item, payload: payload, lenientFinalChunk: false)
    }
    /// Default: conformers that only implement `readPrintf()` (e.g. test mocks)
    /// ignore the flag.
    /// A transport that doesn't model liveness is treated as alive — the neutral
    /// answer for test doubles, which have no device to lose.
    func probeAlive() -> Bool { true }

    func readPrintf(acknowledge: Bool) throws -> String? {
        try readPrintf()
    }
}
