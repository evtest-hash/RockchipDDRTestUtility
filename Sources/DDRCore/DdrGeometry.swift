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

public enum DramType: Int, Sendable, CaseIterable {
    case ddr2 = 2
    case ddr3 = 3
    case ddr4 = 4
    case lpddr2 = 5
    case lpddr3 = 6
    case lpddr4 = 7
    case lpddr4x = 8
    case lpddr5 = 9

    public var displayName: String {
        switch self {
        case .ddr2: return "DDR2"
        case .ddr3: return "DDR3"
        case .ddr4: return "DDR4"
        case .lpddr2: return "LPDDR2"
        case .lpddr3: return "LPDDR3"
        case .lpddr4: return "LPDDR4"
        case .lpddr4x: return "LPDDR4X"
        case .lpddr5: return "LPDDR5"
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

    /// Decode OS_REG words into geometry. `osreg[2]` = SYS_REG2, `osreg[3]` =
    /// SYS_REG3 (extension). Requires at least OS_REG0..OS_REG3.
    public static func decode(_ osreg: [UInt32]) -> DetectedGeometry {
        let reg2 = osreg.count > 2 ? osreg[2] : 0
        let reg3 = osreg.count > 3 ? osreg[3] : 0

        // SYS_REG version lives in SYS_REG3[31:28] (observed = 3 on RK3568 v1.25).
        let version = bits(reg3, 28, 0xf)
        var dramType = DramType(rawValue: bits(reg2, 13, 0x7))
        // LPDDR4 (type 7) vs LPDDR4X: the 3-bit type field can't hold 8, so the
        // distinction rides an extension bit in SYS_REG3. HYPOTHESIS (confirm
        // against a known LPDDR4X board): SYS_REG3 bit0 set → LPDDR4X. The raw
        // OS_REG words are always printed, and the candidate list shows both
        // LPDDR4/LPDDR4X, so a wrong guess here is recoverable.
        if dramType == .lpddr4, (reg3 & 0x1) != 0 {
            dramType = .lpddr4x
        }
        let numCh = 1 + bits(reg2, 12, 0x1)

        var channels: [ChannelGeometry] = []
        var totalBytes: UInt64 = 0
        for ch in 0..<numCh {
            let s = ch * 16
            let rank = 1 + bits(reg2, 11 + s, 0x1)
            let col = 9 + bits(reg2, 9 + s, 0x3)
            let bank = 3 - bits(reg2, 8 + s, 0x1)
            var cs0Row = 13 + bits(reg2, 6 + s, 0x3)
            var cs1Row = 13 + bits(reg2, 4 + s, 0x3)
            // SYS_REG3 extension: high row bit (+1) for large parts (version >= 2)
            if version >= 2 {
                cs0Row += bits(reg3, 5 + s, 0x1) << 2      // row_3_4 / high bit
                cs1Row += bits(reg3, 4 + s, 0x1) << 2
            }
            let bwCode = bits(reg2, 2 + s, 0x3)   // 2→32b, 1→16b, 0→8b
            let dbwCode = bits(reg2, 0 + s, 0x3)
            let busWidthBits = 8 << (2 - min(bwCode, 2))    // code2→32, 1→16, 0→8  (approx; validate)
            let dieWidthBits = 8 << (2 - min(dbwCode, 2))

            channels.append(ChannelGeometry(
                rank: rank, col: col, bank: bank,
                cs0Row: cs0Row, cs1Row: cs1Row,
                busWidthBits: busWidthBits, dieWidthBits: dieWidthBits))

            // Capacity per CS: 2^(row + col + bank) addresses * (busWidth/8) bytes.
            let busBytes = UInt64(busWidthBits / 8)
            let cs0 = (UInt64(1) << UInt64(cs0Row + col + bank)) * busBytes
            totalBytes += cs0
            if rank == 2 {
                let cs1 = (UInt64(1) << UInt64(cs1Row + col + bank)) * busBytes
                totalBytes += cs1
            }
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
