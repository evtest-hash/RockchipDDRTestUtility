// Sources/DDRCore/ChipIdentity.swift
import Foundation

/// Per-chip identity from OTP. serial# derivation mirrors `rockchip_set_serialno()`
/// in Rockchip U-Boot (arch/arm/mach-rockchip/board.c).
public enum ChipIdentity {

    /// Length of the CPUID, matching U-Boot's `CPUID_LEN`.
    public static let cpuidLength = 16

    /// Raw CPUID bytes from the otpdump probe's output.
    /// - Parameter cpuidByteOffset: U-Boot's `CFG_CPUID_OFFSET % 4`.
    public static func parseOtpProbeOutput(_ text: String, cpuidByteOffset: Int) -> [UInt8]? {
        let compact = String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        if compact.contains("OTP_TIMEOUT") { return nil }
        // Anchored on OTP_ALIVE: the words before it are the probe's diagnostics.
        guard let alive = compact.range(of: "OTP_ALIVE") else { return nil }
        let afterAlive = compact[alive.upperBound...]
        let body: Substring
        if let end = afterAlive.range(of: "OTP_END") {
            body = afterAlive[..<end.lowerBound]
        } else {
            body = afterAlive
        }

        let hexRun = body.prefix { $0.isHexDigit }
        var bytes: [UInt8] = []
        var i = hexRun.startIndex
        while i < hexRun.endIndex, let next = hexRun.index(i, offsetBy: 8, limitedBy: hexRun.endIndex) {
            guard let word = UInt32(hexRun[i..<next], radix: 16) else { return nil }
            bytes.append(UInt8(truncatingIfNeeded: word))
            bytes.append(UInt8(truncatingIfNeeded: word >> 8))
            bytes.append(UInt8(truncatingIfNeeded: word >> 16))
            bytes.append(UInt8(truncatingIfNeeded: word >> 24))
            i = next
        }

        guard cpuidByteOffset >= 0, bytes.count >= cpuidByteOffset + cpuidLength else { return nil }
        return Array(bytes[cpuidByteOffset ..< cpuidByteOffset + cpuidLength])
    }

    /// The serial# U-Boot derives from this CPUID, rendered as it renders it (`%llx`).
    public static func serial(fromCpuid cpuid: [UInt8]) -> String? {
        guard cpuid.count == cpuidLength else { return nil }
        var low = [UInt8](), high = [UInt8]()
        for i in 0 ..< 8 {
            low.append(cpuid[1 + (i << 1)])
            high.append(cpuid[i << 1])
        }
        let lo = crc32NoComp(0, low)
        let hi = crc32NoComp(lo, high)
        return String(UInt64(lo) | (UInt64(hi) << 32), radix: 16)
    }

    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// U-Boot's `crc32_no_comp`: the CRC-32 body with neither complement.
    private static func crc32NoComp(_ seed: UInt32, _ data: [UInt8]) -> UInt32 {
        var crc = seed
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xEDB8_8320 : 0)
            }
        }
        return crc
    }
}
