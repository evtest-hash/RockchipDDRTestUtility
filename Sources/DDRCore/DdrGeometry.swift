import Foundation

/// DDR geometry decoded from the PMU_GRF OS_REG (SYS_REG) words that the rkbin
/// DDR bin writes after auto-detecting the DRAM. The probe item (`osregdump`)
/// dumps the raw words over USB; this file parses and decodes them host-side.
///
/// Bit layout follows Rockchip's public SYS_REG encoding (U-Boot
/// `arch/arm/include/asm/arch-rockchip/sdram_common.h`), which is shared across
/// RK356x/RK3588. It is the SAME geometry the DDR bin prints as
/// "BW/Col/Bk/ CS Row / CS / Die BW / Size" — see the reverse-engineered
/// print function in the spike notes.
///
/// SPIKE STATUS: decode constants are best-effort until confirmed against a real
/// board. The raw words are always printed alongside the decode so ground truth
/// is never lost; if a field is off, correct the constant here (or reverse the
/// DDR bin's OS_REG *encode* function for the authoritative layout).

/// DRAM type codes — VERBATIM from Rockchip U-Boot
/// `arch/arm/include/asm/arch-rockchip/sdram.h` (`enum { DDR4 = 0, DDR2 = 2, ... }`).
/// NOTE `DDR4 == 0` (not 4). These are the values the SYS_REG DDRTYPE field holds.
public enum DramType: Int, Sendable, CaseIterable {
    case ddr4 = 0
    case ddr2 = 2
    case ddr3 = 3
    case lpddr2 = 5
    case lpddr3 = 6
    case lpddr4 = 7
    case lpddr4x = 8
    case lpddr5 = 9
    case ddr5 = 10

    public var displayName: String {
        switch self {
        case .ddr4: return "DDR4"
        case .ddr2: return "DDR2"
        case .ddr3: return "DDR3"
        case .lpddr2: return "LPDDR2"
        case .lpddr3: return "LPDDR3"
        case .lpddr4: return "LPDDR4"
        case .lpddr4x: return "LPDDR4X"
        case .lpddr5: return "LPDDR5"
        case .ddr5: return "DDR5"
        }
    }
}

/// Per-channel geometry decoded from one 16-bit lane of SYS_REG2 (+ SYS_REG3
/// extension bits).
public struct ChannelGeometry: Sendable, Equatable {
    public let rank: Int          // number of CS in this channel (1 or 2)
    public let col: Int           // column address bits
    public let bank: Int          // bank address bits (3 → 8 banks)
    public let cs0Row: Int        // CS0 row address bits
    public let cs1Row: Int        // CS1 row address bits (valid when rank==2)
    public let busWidthBits: Int  // 8/16/32 — channel bus width
    public let dieWidthBits: Int  // 8/16/32 — per-die width
}

public struct DetectedGeometry: Sendable {
    public let rawOsReg: [UInt32]         // OS_REG0..OS_REG(N)
    public let sysRegVersion: Int
    public let dramType: DramType?
    public let numChannels: Int
    public let channels: [ChannelGeometry]
    public let totalSizeMB: Int

    /// Total chip-selects across all channels (= number of ranks). Used to
    /// disambiguate cfgs that share type+size but differ in CS layout.
    public var totalCS: Int { channels.reduce(0) { $0 + $1.rank } }

    /// Human-readable one-liner, mirroring the DDR bin's own print format.
    public func summary() -> String {
        let t = dramType?.displayName ?? "type?"
        var parts = ["\(t)", "\(totalSizeMB)MB", "\(numChannels)ch"]
        for (i, c) in channels.enumerated() {
            let cs = c.rank == 2 ? "CS0row=\(c.cs0Row) CS1row=\(c.cs1Row)" : "CS0row=\(c.cs0Row)"
            parts.append("ch\(i)[rank=\(c.rank) bw=\(c.busWidthBits) dbw=\(c.dieWidthBits) col=\(c.col) bank=\(c.bank) \(cs)]")
        }
        return parts.joined(separator: " ")
    }
}

public enum OsRegDecoder {
    // MARK: - Parse the probe's USB printf block

    /// Extract the OS_REG words from the probe output between the
    /// `OSREG_BEGIN` / `OSREG_END` markers. The probe prints each word as an
    /// 8-digit hex, one per line, but the USB printf channel arrives in chunks
    /// that can split a marker or token across `readPrintf` calls (and the host
    /// re-joins them with newlines). So we strip ALL whitespace first — that
    /// re-fuses any split marker/token — then read the body as a run of hex
    /// digits chunked 8 at a time (the probe zero-pads, verified on hardware).
    /// Returns nil if the begin marker is absent.
    public static func parseProbeOutput(_ text: String) -> [UInt32]? {
        let compact = String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        guard let begin = compact.range(of: "OSREG_BEGIN") else { return nil }
        let afterBegin = compact[begin.upperBound...]
        let bodyStr: Substring
        if let end = afterBegin.range(of: "OSREG_END") {
            bodyStr = afterBegin[..<end.lowerBound]
        } else {
            bodyStr = afterBegin
        }
        let hexRun = bodyStr.prefix { $0.isHexDigit }
        var words: [UInt32] = []
        var i = hexRun.startIndex
        while i < hexRun.endIndex, let next = hexRun.index(i, offsetBy: 8, limitedBy: hexRun.endIndex) {
            if let v = UInt32(hexRun[i..<next], radix: 16) {
                words.append(v)
            }
            i = next
        }
        return words.isEmpty ? nil : words
    }

    // MARK: - SYS_REG bitfield decode (Rockchip sdram_common.h)

    private static func bits(_ v: UInt32, _ shift: Int, _ mask: UInt32) -> Int {
        Int((v >> UInt32(shift)) & mask)
    }

    /// Decode OS_REG words into geometry using Rockchip's SYS_REG **version-3**
    /// layout (RK356x/RK3588), ported from the `_V3` macros in U-Boot
    /// `arch/arm/include/asm/arch-rockchip/sdram_common.h`. `osreg[2]` = SYS_REG2,
    /// `osreg[3]` = SYS_REG3. The DDR type is a 5-bit field split across both
    /// registers; rank and CS row also draw high bits from SYS_REG3.
    ///
    /// LPDDR4 vs LPDDR4X: the SYS_REG DDRTYPE field distinguishes them ONLY if the
    /// DDR bin encodes the high type bits (reg3[13:12]); many bins store LPDDR4 (7)
    /// for both and distinguish LP4X via head-info elsewhere. So LP4/LP4X may not
    /// be separable from OS_REG readback — CfgAutoSelect treats them as one family.
    public static func decode(_ osreg: [UInt32]) -> DetectedGeometry {
        let reg2 = osreg.count > 2 ? osreg[2] : 0
        let reg3 = osreg.count > 3 ? osreg[3] : 0

        // VERSION: SYS_REG3[31:28].  DDRTYPE_V3: reg2[15:13] low3 | reg3[13:12] high2.
        let version = bits(reg3, 28, 0xf)
        let typeRaw = bits(reg2, 13, 0x7) | (bits(reg3, 12, 0x3) << 3)
        let dramType = DramType(rawValue: typeRaw)
        let numCh = 1 + bits(reg2, 12, 0x1)   // NUM_CH: reg2[12]

        var channels: [ChannelGeometry] = []
        var totalBytes: UInt64 = 0
        for ch in 0..<numCh {
            let s = ch * 16
            // RANK: ch0/2 take a high bit from reg3[14] (→ up to 4 ranks, V3);
            // ch1/3 use the base 1-bit field.
            let rank = ch == 0
                ? (1 << (bits(reg2, 11, 0x1) | (bits(reg3, 14, 0x1) << 1)))
                : (1 + bits(reg2, 11 + s, 0x1))
            let col = 9 + bits(reg2, 9 + s, 0x3)
            let bank = 3 - bits(reg2, 8 + s, 0x1)
            // CS0/CS1 ROW_V3: 2 low bits in reg2 + 1 high bit in reg3.
            let cs0Row = (((bits(reg2, 6 + s, 0x3) | (bits(reg3, 5 + 2 * ch, 0x1) << 2)) + 1) & 0x7) + 12
            let cs1Row = (((bits(reg2, 4 + s, 0x3) | (bits(reg3, 4 + 2 * ch, 0x1) << 2)) + 1) & 0x7) + 12
            let cs1Col = 9 + bits(reg3, 2 * ch, 0x3)     // CS1_COL_V3 (reg3[1:0] for ch0)
            let row34 = bits(reg2, 30 + ch, 0x1) != 0    // ROW_3_4: only 3/4 of rows populated
            // BW/DBW_V3: DEC = 2 >> code; bus width bits = 8 << (that).
            let busWidthBits = 8 << (2 >> bits(reg2, 2 + s, 0x3))
            let dieWidthBits = 8 << (2 >> bits(reg2, 0 + s, 0x3))

            channels.append(ChannelGeometry(
                rank: rank, col: col, bank: bank,
                cs0Row: cs0Row, cs1Row: cs1Row,
                busWidthBits: busWidthBits, dieWidthBits: dieWidthBits))

            // Capacity: each CS = 2^(row + col + bank) addresses * (bus bytes).
            // CS1 uses its own column count; row_3_4 parts populate only 3/4.
            let busBytes = UInt64(busWidthBits / 8)
            var chBytes = (UInt64(1) << UInt64(cs0Row + col + bank)) * busBytes
            if rank >= 2 {
                chBytes += (UInt64(1) << UInt64(cs1Row + cs1Col + bank)) * busBytes
            }
            if row34 { chBytes = chBytes / 4 * 3 }
            totalBytes += chBytes
        }

        return DetectedGeometry(
            rawOsReg: osreg,
            sysRegVersion: version,
            dramType: dramType,
            numChannels: numCh,
            channels: channels,
            totalSizeMB: Int(totalBytes >> 20))
    }
}
