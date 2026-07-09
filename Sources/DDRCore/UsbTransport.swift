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
    func close() throws
}

/// Extension providing default parameter values for protocol methods.
public extension UsbTransport {
    func downloadBoot(item: CfgItem, payload: Data) throws {
        try downloadBoot(item: item, payload: payload, lenientFinalChunk: false)
    }
}
