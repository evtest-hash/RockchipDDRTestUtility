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

    /// Chip-selects per die/channel (= a channel's rank). Rockchip's cfg
    /// filenames label CS PER DIE ("每片颗粒M个CS" / "用M个CS"), NOT the total
    /// across channels, so this — not the sum — is the field to match on. All
    /// channels of a part are identical here, so the first channel's rank is
    /// representative (falls back to the max if a mixed config ever appears).
    public var csPerDie: Int { channels.map { $0.rank }.max() ?? 0 }

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

    /// Decode OS_REG words into geometry, dispatching on the SYS_REG encoding
    /// version. The version nibble lives in SYS_REG3[31:28] (`osreg[3]`):
    ///   • version 3 → the V3 layout below (RK356x/RK3576/RK3588, arm64).
    ///   • otherwise → the classic single-register V1 layout (`decodeV1`), used by
    ///     pre-V3 SoCs like RK3288. These parts populate ONLY os_reg[2]; os_reg[3]
    ///     is untouched, so the nibble reads back 0 → V1 path. (SYS_REG V2, used by
    ///     some Tier-2 SoCs, is not yet implemented — add a `version == 2` branch
    ///     when one is brought up.)
    public static func decode(_ osreg: [UInt32]) -> DetectedGeometry {
        let reg3_0 = osreg.count > 3 ? osreg[3] : 0
        let version = bits(reg3_0, 28, 0xf)
        if version == 3 {
            return decodeV3(osreg, version: version)
        }
        let reg2_0 = osreg.count > 2 ? osreg[2] : 0
        return decodeV1(osreg, reg2: reg2_0, version: version)
    }

    /// Decode OS_REG words using Rockchip's SYS_REG **version-3** layout
    /// (RK356x/RK3588), ported from the `_V3` macros in U-Boot
    /// `arch/arm/include/asm/arch-rockchip/sdram_common.h`. `osreg[2]` = SYS_REG2,
    /// `osreg[3]` = SYS_REG3. The DDR type is a 5-bit field split across both
    /// registers; rank and CS row also draw high bits from SYS_REG3.
    ///
    /// DDRTYPE is the authoritative 5-bit code from `sdram.h`: LPDDR4 (7) and
    /// LPDDR4X (8) are DISTINCT values, carried by reg2[15:13] (low 3 bits) and
    /// reg3[13:12] (high 2 bits) exactly as `SYS_REG_ENC/DEC_DDRTYPE_V3` define.
    /// We decode the full field and report the exact type; `CfgAutoSelect` matches
    /// it exactly (no LP4/LP4X folding). Note `sdram.h` has no LPDDR5X code — both
    /// LPDDR5 and LPDDR5X are 9, so an LPDDR5X part simply reads back as LPDDR5.
    private static func decodeV3(_ osreg: [UInt32], version: Int) -> DetectedGeometry {
        // A single SYS_REG descriptor (one reg2/reg3 pair) covers at most 2
        // channels (NUM_CH is 1 bit). SoCs with more physical channels write
        // additional descriptors in consecutive os_reg pairs: RK356x uses one
        // group at (os_reg2, os_reg3); RK3588 (64-bit bus = 4×16-bit channels)
        // uses TWO — (os_reg2,os_reg3) for ch0/1 and (os_reg4,os_reg5) for ch2/3
        // — so total capacity is the SUM across groups (confirmed on hardware:
        // an RK3588 8GB board reports reg2/3 == reg4/5, each decoding to 4GB).
        // Version + DRAM type come from the first (primary) group.
        let reg3_0 = osreg.count > 3 ? osreg[3] : 0
        let reg2_0 = osreg.count > 2 ? osreg[2] : 0
        let typeRaw = bits(reg2_0, 13, 0x7) | (bits(reg3_0, 12, 0x3) << 3)   // DDRTYPE_V3
        let dramType = DramType(rawValue: typeRaw)

        var channels: [ChannelGeometry] = []
        var totalBytes: UInt64 = 0
        // Groups live at (os_reg2,3), (os_reg4,5), … The first is always decoded;
        // each later pair counts only if it's a valid same-version descriptor
        // (non-zero reg2, matching version nibble) — RK356x's zeroed reg4/5 stop
        // the loop, so its single-group result is unchanged.
        var group = 0
        while true {
            let i2 = 2 + 2 * group, i3 = 3 + 2 * group
            guard osreg.count > i3 else { break }
            let reg2 = osreg[i2], reg3 = osreg[i3]
            if group > 0 {
                guard reg2 != 0, bits(reg3, 28, 0xf) == version else { break }
            }
            let (chs, bytes) = decodeGroup(reg2: reg2, reg3: reg3, dramType: dramType)
            channels.append(contentsOf: chs)
            totalBytes += bytes
            group += 1
            if group >= 5 { break }   // 12 os_reg words → at most 5 pairs from index 2
        }

        return DetectedGeometry(
            rawOsReg: osreg,
            sysRegVersion: version,
            dramType: dramType,
            numChannels: channels.count,
            channels: channels,
            totalSizeMB: Int(totalBytes >> 20))
    }

    /// Decodes one SYS_REG descriptor (a reg2/reg3 pair) into its channels and
    /// byte capacity, per the Rockchip `_V3` macros. NUM_CH (reg2[12]) selects 1
    /// or 2 channels within this group.
    private static func decodeGroup(reg2: UInt32, reg3: UInt32, dramType: DramType?) -> ([ChannelGeometry], UInt64) {
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
            // BW/DBW_V3: DEC = 2 >> code; width bits = 8 << (that). dbwCode is also
            // the `cap_info->dbw` U-Boot uses for its DDR4 bank-group term.
            let busWidthBits = 8 << (2 >> bits(reg2, 2 + s, 0x3))
            let dbwCode = bits(reg2, 0 + s, 0x3)
            let dieWidthBits = 8 << (2 >> dbwCode)
            // Total BANK address bits, matching the rkbin DDR bin's own capacity
            // routine (RE'd from rk3576 v1.12, get_cs_cap @0xde8:
            // `cap = 1 << (bw + col + bg + bk + row)`).
            //
            // SYS_REG_ENC_BK is 1-bit — `(bk==3)?0:1` — so the wire only tells us
            // "bk==3" vs "bk≠3"; it can't say WHICH non-3 value. We must NOT hard-
            // code a bank count (RK3576 cfgs parameterise by die_cap, not bank, and
            // different LPDDR5 die densities decompose to different bank counts, so
            // "LPDDR5 ⇒ 16 banks" would be wrong for an 8-bank LPDDR5 die). Instead
            // read reg2[8] and disambiguate ONLY the lossy `≠3` case by type:
            //   reg2[8]=0 ⟹ bk=3 (8 banks) for every type — faithful, untouched.
            //   reg2[8]=1 ⟹ LPDDR5/DDR5: 16 banks (bk=4); others: 4 banks (bk=2).
            // HW-confirmed on RK3576 (reg2[8]=1, LPDDR5 → bk=4 → 8 GB, matching the
            // bin's "Bk=16 / Size=4096MB/channel").
            let bkBit = bits(reg2, 8 + s, 0x1)
            let bk = (dramType == .lpddr5 || dramType == .ddr5) ? (3 + bkBit) : (3 - bkBit)
            // bg (bank-group bits): the bin adds these ONLY for DDR4 (it gates on
            // `dram_type == 0`), derived from die width: bg = (dbw==0)?2:1.
            let bg = (dramType == .ddr4) ? ((2 >> dbwCode == 0) ? 2 : 1) : 0
            let bank = bk + bg
            // CS0/CS1 ROW_V3: 2 low bits in reg2 + 1 high bit in reg3.
            let cs0Row = (((bits(reg2, 6 + s, 0x3) | (bits(reg3, 5 + 2 * ch, 0x1) << 2)) + 1) & 0x7) + 12
            let cs1Row = (((bits(reg2, 4 + s, 0x3) | (bits(reg3, 4 + 2 * ch, 0x1) << 2)) + 1) & 0x7) + 12
            let cs1Col = 9 + bits(reg3, 2 * ch, 0x3)     // CS1_COL_V3 (reg3[1:0] for ch0)
            let row34 = bits(reg2, 30 + ch, 0x1) != 0    // ROW_3_4: only 3/4 of rows populated

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
        return (channels, totalBytes)
    }

    /// Decode the classic single-register SYS_REG (**version 1**) used by pre-V3
    /// SoCs (RK3288 et al.), ported from the non-`_V2`/`_V3` `SYS_REG_DEC_*` macros
    /// in older U-Boot `sdram_common.h`. All geometry lives in `osreg[2]`, split
    /// into two 16-bit channel lanes (ch1 at +16); there is NO os_reg3 (DDRTYPE is
    /// 3-bit, no high bits) and NO multi-group extension. These parts predate
    /// LPDDR4/5, so DDRTYPE is DDR2/DDR3/LPDDR2/LPDDR3-era: bank is always
    /// `3 - bkBit` (8 or 4 banks) and there is no DDR4 bank-group term.
    ///
    /// HW-confirmed on RK3288 (os_reg[2] = 0x32817281 → DDR3, 2ch × 32-bit,
    /// col=10, 8 banks, cs0_row=15, 2048 MB), matching the DDR bin's UART print.
    private static func decodeV1(_ osreg: [UInt32], reg2: UInt32, version: Int) -> DetectedGeometry {
        let typeRaw = bits(reg2, 13, 0x7)             // 3-bit DDRTYPE (no reg3 high bits)
        let dramType = DramType(rawValue: typeRaw)
        let numCh = 1 + bits(reg2, 12, 0x1)           // NUM_CH: reg2[12]
        var channels: [ChannelGeometry] = []
        var totalBytes: UInt64 = 0
        for ch in 0..<numCh {
            let s = ch * 16
            let rank = 1 + bits(reg2, 11 + s, 0x1)
            let col = 9 + bits(reg2, 9 + s, 0x3)
            let bk = 3 - bits(reg2, 8 + s, 0x1)                    // 8 or 4 banks
            let cs0Row = 13 + bits(reg2, 6 + s, 0x3)               // 2-bit field, no wrap
            let cs1Row = 13 + bits(reg2, 4 + s, 0x3)
            let busWidthBits = 8 << (2 >> bits(reg2, 2 + s, 0x3))  // BW: same enc as V3
            let dieWidthBits = 8 << (2 >> bits(reg2, 0 + s, 0x3))  // DBW
            let row34 = bits(reg2, 30 + ch, 0x1) != 0             // ROW_3_4

            channels.append(ChannelGeometry(
                rank: rank, col: col, bank: bk,
                cs0Row: cs0Row, cs1Row: cs1Row,
                busWidthBits: busWidthBits, dieWidthBits: dieWidthBits))

            // Capacity per CS = 2^(row + col + bank) addresses × bus bytes. V1 has
            // no separate CS1 column field, so CS1 reuses CS0's column count.
            let busBytes = UInt64(busWidthBits / 8)
            var chBytes = (UInt64(1) << UInt64(cs0Row + col + bk)) * busBytes
            if rank >= 2 {
                chBytes += (UInt64(1) << UInt64(cs1Row + col + bk)) * busBytes
            }
            if row34 { chBytes = chBytes / 4 * 3 }
            totalBytes += chBytes
        }
        return DetectedGeometry(
            rawOsReg: osreg,
            sysRegVersion: version,
            dramType: dramType,
            numChannels: channels.count,
            channels: channels,
            totalSizeMB: Int(totalBytes >> 20))
    }
}
