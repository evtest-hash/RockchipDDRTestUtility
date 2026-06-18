import Foundation

/// RC4 stream cipher — the symmetric primitive Rockchip uses both for cfg
/// payload storage (see `CfgBinaryParser`) and for boot transfer on SoCs that
/// are NOT in `CLOSE_RC4_LIST` (see `RkUsbTransportLibusb.downloadBoot`).
/// Encrypting and decrypting are the same operation.
public enum RC4 {
    /// Rockchip's hardcoded RC4 key (assembled byte-by-byte in DDR_UserTool
    /// `sub_4015C0`). Shared by cfg-storage and boot-transfer encryption.
    public static let rockchipKey = Data([
        0x7C, 0x4E, 0x03, 0x04, 0x55, 0x05, 0x09, 0x07,
        0x2D, 0x2C, 0x7B, 0x38, 0x17, 0x0D, 0x17, 0x11,
    ])

    public static func cipher(key: Data, data: Data) -> Data {
        var s = [UInt8](0...255)
        var j: UInt8 = 0
        for i in 0..<256 {
            j = j &+ s[i] &+ key[i % key.count]
            s.swapAt(i, Int(j))
        }

        var out = [UInt8](repeating: 0, count: data.count)
        var ii: UInt8 = 0
        var jj: UInt8 = 0
        for k in 0..<data.count {
            ii = ii &+ 1
            jj = jj &+ s[Int(ii)]
            s.swapAt(Int(ii), Int(jj))
            out[k] = data[k] ^ s[Int(s[Int(ii)] &+ s[Int(jj)])]
        }
        return Data(out)
    }
}
