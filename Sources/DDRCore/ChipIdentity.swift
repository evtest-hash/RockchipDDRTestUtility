// Sources/DDRCore/ChipIdentity.swift
import Foundation

/// One otpdump capture, decoded to raw OTP bytes plus the OTP byte offset the
/// dump starts at. Everything downstream addresses OTP by its ABSOLUTE offset
/// (the offsets the vendor dtsi uses), so a probe that moves its starting word
/// changes only `baseByte`.
public struct OtpDump: Sendable, Equatable {
    /// OTP byte offset of `bytes[0]`.
    public let baseByte: Int
    public let bytes: [UInt8]

    public init(baseByte: Int, bytes: [UInt8]) {
        self.baseByte = baseByte
        self.bytes = bytes
    }

    /// The OTP byte at an absolute offset, or nil when this dump doesn't reach it.
    public func byte(at offset: Int) -> UInt8? {
        let i = offset - baseByte
        guard i >= 0, i < bytes.count else { return nil }
        return bytes[i]
    }

    /// `count` OTP bytes from an absolute offset, or nil when the dump doesn't
    /// cover the whole range — a short read must never masquerade as data.
    public func slice(at offset: Int, count: Int) -> [UInt8]? {
        let start = offset - baseByte
        guard count >= 0, start >= 0, start + count <= bytes.count else { return nil }
        return Array(bytes[start ..< start + count])
    }
}

/// Per-chip identity from OTP. serial# derivation mirrors `rockchip_set_serialno()`
/// in Rockchip U-Boot (arch/arm/mach-rockchip/board.c).
public enum ChipIdentity {

    /// Length of the CPUID, matching U-Boot's `CPUID_LEN`.
    public static let cpuidLength = 16

    /// Decode an otpdump capture into raw OTP bytes.
    ///
    /// Two framings are accepted:
    ///   v2 — the probe prints `OTP_DUMP` and then the OTP byte offset its first
    ///        data word came from, so the dump describes itself.
    ///   v1 — the words after `OTP_ALIVE` are the dump and nothing states where
    ///        it starts; `fallbackBaseByte` supplies the offset that SoC's shipped
    ///        payload used. Without it, decoding is refused rather than guessed:
    ///        a wrong base yields a wrong (but plausible) serial.
    public static func parseOtpDump(_ text: String, fallbackBaseByte: Int?) -> OtpDump? {
        guard var body = probeBody(text) else { return nil }

        if body.hasPrefix(selfDescribingMarker) {
            body = body.dropFirst(selfDescribingMarker.count)
            let words = hexWords(body)
            guard let first = words.first else { return nil }
            return OtpDump(baseByte: Int(first), bytes: littleEndianBytes(words.dropFirst()))
        }

        guard let fallbackBaseByte else { return nil }
        return OtpDump(baseByte: fallbackBaseByte, bytes: littleEndianBytes(hexWords(body)))
    }

    /// The serial# U-Boot derives from this CPUID, rendered as it renders it —
    /// `%016llx`, i.e. zero-padded to the firmware's fixed 64-bit width.
    public static func serial(fromCpuid cpuid: [UInt8]) -> String? {
        guard cpuid.count == cpuidLength else { return nil }
        var low = [UInt8](), high = [UInt8]()
        for i in 0 ..< 8 {
            low.append(cpuid[1 + (i << 1)])
            high.append(cpuid[i << 1])
        }
        let lo = crc32NoComp(0, low)
        let hi = crc32NoComp(lo, high)
        // ZERO-PADDED to 16 digits, matching the firmware's fixed 64-bit field.
        // This string is the only bridge between two device domains: the tool
        // reads it from OTP while the board is in maskrom, the booted board
        // reports the same value, and `adb -s <serial>` matches them as STRINGS.
        // `String(_:radix:)` drops leading zeros, so a chip whose folded value
        // starts with a zero nibble printed 15 digits here and 16 on the board —
        // the claim then failed, and failed misleadingly: the flash succeeded and
        // the board was up, but the software reported "flashed, won't boot".
        // Measured on an AZ07 (RK3566): 883265bf7fee7c8 vs 0883265bf7fee7c8.
        return String(format: "%016llx", UInt64(lo) | (UInt64(hi) << 32))
    }

    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - framing

    private static let selfDescribingMarker = "OTP_DUMP"

    /// The probe's payload region: everything between OTP_ALIVE and OTP_END.
    /// Anchoring on OTP_ALIVE is what keeps the pre-OTP diagnostic words (gate
    /// register, INT_ST) out of the data.
    private static func probeBody(_ text: String) -> Substring? {
        let compact = String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        if compact.contains("OTP_TIMEOUT") { return nil }
        guard let alive = compact.range(of: "OTP_ALIVE") else { return nil }
        let afterAlive = compact[alive.upperBound...]
        guard let end = afterAlive.range(of: "OTP_END") else { return afterAlive }
        return afterAlive[..<end.lowerBound]
    }

    private static func hexWords(_ body: Substring) -> [UInt32] {
        let hexRun = body.prefix { $0.isHexDigit }
        var words: [UInt32] = []
        var i = hexRun.startIndex
        while i < hexRun.endIndex, let next = hexRun.index(i, offsetBy: 8, limitedBy: hexRun.endIndex) {
            guard let word = UInt32(hexRun[i..<next], radix: 16) else { break }
            words.append(word)
            i = next
        }
        return words
    }

    private static func littleEndianBytes<S: Sequence>(_ words: S) -> [UInt8] where S.Element == UInt32 {
        var bytes: [UInt8] = []
        for word in words {
            bytes.append(UInt8(truncatingIfNeeded: word))
            bytes.append(UInt8(truncatingIfNeeded: word >> 8))
            bytes.append(UInt8(truncatingIfNeeded: word >> 16))
            bytes.append(UInt8(truncatingIfNeeded: word >> 24))
        }
        return bytes
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
