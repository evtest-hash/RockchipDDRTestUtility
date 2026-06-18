import Foundation

public protocol UsbTransport {
    func discoverDevices() throws -> [UsbDevice]
    func open(device: UsbDevice) throws
    func downloadBoot(item: CfgItem, payload: Data) throws
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
