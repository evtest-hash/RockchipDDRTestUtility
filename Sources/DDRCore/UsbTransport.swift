import Foundation

public protocol UsbTransport {
    func discoverDevices() throws -> [UsbDevice]
    func open(device: UsbDevice) throws
    func downloadBoot(item: CfgItem, payload: Data) throws
    func downloadItem(item: CfgItem, payload: Data, address: UInt32) throws
    func downloadParam(item: CfgItem, address: UInt32?, params: [CfgParameter]) throws
    func runItem(item: CfgItem, address: UInt32) throws
    func readPrintf() throws -> String?
    func close() throws
}
