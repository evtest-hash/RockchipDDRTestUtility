// Sources/DDRCore/DetectProfile.swift
import Foundation

/// Per-SoC parameters for DDR auto-detect. Add a SoC by adding one entry here
/// (and generating its detect cfg + probes via the build script). SoCs absent
/// from `all` are simply not auto-detected (caller falls back to manual).
public struct DetectProfile: Sendable {
    public let soc: String            // must match CfgRepository socName / DDRTestFiles dir
    /// Single self-contained detect cfg (basename). Packages every payload the
    /// detect flow needs — Boot + ddrbin + osregdump + otpdump + reboot — which DdrDetector
    /// reads out of `plan.embeddedBins` and drives itself (NOT via the test
    /// engine). Built by tools/ddr-autodetect/build.sh and stored in this SoC's
    /// `DDRTestFiles/<soc>/` dir (so it ships with the real test cfgs). The name
    /// must NOT contain "焊接" so CfgAutoSelect never treats it as a match candidate.
    public let detectCfgName: String
    public let downloadBase: UInt32   // item download/run base
    public let usbPutsVector: UInt32  // Boot service vector: puts -> USB ring (0x80-readable)
    public let osRegBase: UInt32      // PMU_GRF OS_REG0 address
    /// reboot-to-maskrom: register where the BROM_DOWNLOAD magic goes. This is the
    /// SoC's CONFIG_ROCKCHIP_BOOT_MODE_REG — the register the NEXT-STAGE loader
    /// (eMMC/SD U-Boot TPL/SPL) reads early to decide `back_to_bootrom()`. The
    /// BootROM itself never checks it (see U-Boot bootrom.c), so on a board with
    /// bootable media the magic MUST land in this exact register or the loader
    /// boots the OS instead of returning to maskrom. NOT necessarily os_reg0:
    /// RK3568 0xFDC20200 (==os_reg0), RK3576 0x26024040, RK3588 0xFD588080.
    public let bootModeReg: UInt32
    public let maskromMagic: UInt32   // reboot-to-maskrom: magic written to bootModeReg
    public let cruResetReg: UInt32    // CRU global soft-reset register
    public let cruResetValue: UInt32  // value that triggers the reset
    /// U-Boot's `CFG_CPUID_OFFSET % 4`; nil means this SoC ships no otpdump payload.
    public let otpCpuidByteOffset: Int?
}

public enum DetectProfiles {
    // Reboot-to-maskrom values confirmed against Rockchip U-Boot (linux-6.1-stan-rkr7):
    //   BOOT_BROM_DOWNLOAD = 0xEF08A53C          (boot_mode.h)
    //   PMUGRF_BASE 0xFDC20000, os_reg0 @+0x200  (rk3568.c) -> boot-mode reg 0xFDC20200
    //   CRU_BASE 0xFDD20000, glb_srst_fst @0xD4  (cru_rk3568.h) -> 0xFDD200D4
    //   glb_srst_fst reset value = 0xFDB9        (sysreset_rockchip.c)
    public static let all: [UInt16: DetectProfile] = [
        0x350A: DetectProfile(
            soc: "RK3568&RK3566",
            detectCfgName: "DDR自动探测.cfg",
            downloadBase: 0xFDCC_4000,
            usbPutsVector: 0xFDCC_1004,
            osRegBase: 0xFDC2_0200,
            bootModeReg: 0xFDC2_0200,
            maskromMagic: 0xEF08_A53C,
            cruResetReg: 0xFDD2_00D4,
            cruResetValue: 0x0000_FDB9,
            otpCpuidByteOffset: 0),
        // RK3588 — addresses confirmed against U-Boot + RE of the rkbin DDR bin:
        //   item base 0xFF004000 (cfg @0x5B6); Boot links 0xFF001000 → puts vector +4.
        //   PMU1_GRF_BASE 0xFD58A000, os_reg0 @+0x200 → 0xFD58A200 (DDR bin STRs the
        //   geometry to os_reg2/3 @0x208/0x20C, verified by disasm; matches the
        //   RK3576 reboot-to-maskrom pattern writing BOOT_BROM_DOWNLOAD to os_reg0).
        //   CRU_BASE 0xFD7C0000, GLB_SRST_FST @0xC08 → 0xFD7C0C08, value 0xFDB9.
        0x350B: DetectProfile(
            soc: "RK3588",
            detectCfgName: "DDR自动探测.cfg",
            downloadBase: 0xFF00_4000,
            usbPutsVector: 0xFF00_1004,
            osRegBase: 0xFD58_A200,
            bootModeReg: 0xFD58_8080,   // CONFIG_ROCKCHIP_BOOT_MODE_REG (NOT os_reg0)
            maskromMagic: 0xEF08_A53C,
            cruResetReg: 0xFD7C_0C08,
            cruResetValue: 0x0000_FDB9,
            otpCpuidByteOffset: 3),
        // RK3576 — same AArch64 DDR Test Tool Boot as RK356x/RK3588. Addresses:
        //   item base 0xFF... no — cfg @0x5B6 = 0x3FF84000; Boot links 0x3FF81000
        //   → puts vector +4. PMU1_GRF_BASE 0x26026000, os_reg0 @+0x200 → 0x26026200
        //   (U-Boot rk3576.c; RE-confirmed: DDR bin MOVK #0x2602 + STR os_reg2/3).
        //   reset_misc writes BOOT_BROM_DOWNLOAD to os_reg0. TOP_CRU_BASE 0x27200000
        //   + GLB_SRST_FST 0xC08 → 0x27200C08, value 0xFDB9.
        //   NOTE: geometry decode + reboot pending real-hardware verification.
        0x350E: DetectProfile(
            soc: "RK3576",
            detectCfgName: "DDR自动探测.cfg",
            downloadBase: 0x3FF8_4000,
            usbPutsVector: 0x3FF8_1004,
            osRegBase: 0x2602_6200,
            bootModeReg: 0x2602_4040,   // CONFIG_ROCKCHIP_BOOT_MODE_REG (NOT os_reg0)
            maskromMagic: 0xEF08_A53C,
            cruResetReg: 0x2720_0C08,
            cruResetValue: 0x0000_FDB9,
            otpCpuidByteOffset: 2),
        // RK3288 (arm32 / SYS_REG **V1**). All addresses confirmed against U-Boot
        // (mixtile rk3288 tree) + RE of the ForceInit item:
        //   Boot links 0xFFFF0000; item base 0xFFFF1500; USB puts service 0xFFFF0020
        //   (RE'd from ForceInit: r0=char*, blx; dual UART+USB console — HW-verified
        //   reading os_reg over USB).
        //   PMU sys_reg base 0xFF730090; os_reg0 @+0x04 = 0xFF730094 (geometry the
        //   V1 DDR bin writes lands in os_reg2 = 0xFF73009C). Kconfig
        //   ROCKCHIP_BOOT_MODE_REG = 0xFF730094 (== os_reg0, like RK3568).
        //   CRU_BASE 0xFF760000 (dtsi) + glb_srst_fst @0x1B0 → 0xFF7601B0, value
        //   0xFDB9 (cleanly restarts the BROM boot chain; the PMU boot-mode flag
        //   survives it — the DDR bin re-checks that flag after every reset). The
        //   companion boot_id stamp (reboot payload) is what makes maskrom actually
        //   fire: our detect arrives over USB and fst leaves IRAM's boot-source id
        //   as stale-USB, which the DDR bin's guard treats as "skip maskrom".
        //   Magic BOOT_BROM_DOWNLOAD 0xEF08A53C.
        0x320A: DetectProfile(
            soc: "RK3288",
            detectCfgName: "DDR自动探测.cfg",
            downloadBase: 0xFFFF_1500,
            usbPutsVector: 0xFFFF_0020,
            osRegBase: 0xFF73_0094,
            bootModeReg: 0xFF73_0094,   // CONFIG_ROCKCHIP_BOOT_MODE_REG (== os_reg0)
            maskromMagic: 0xEF08_A53C,
            cruResetReg: 0xFF76_01B0,   // glb_srst_fst (clean restart; flag survives)
            cruResetValue: 0x0000_FDB9,
            otpCpuidByteOffset: nil),
    ]
    public static func forPID(_ pid: UInt16) -> DetectProfile? { all[pid] }
}
