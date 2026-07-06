// Sources/DDRCore/DetectProfile.swift
import Foundation

/// Per-SoC parameters for DDR auto-detect. Add a SoC by adding one entry here
/// (and generating its detect cfg + probes via the build script). SoCs absent
/// from `all` are simply not auto-detected (caller falls back to manual).
public struct DetectProfile: Sendable {
    public let soc: String            // must match CfgRepository socName / DDRTestFiles dir
    public let ddrBinName: String     // auto-probing rkbin DDR bin (basename)
    public let detectCfgName: String  // generated detect cfg (basename)
    public let downloadBase: UInt32   // item download/run base
    public let usbPutsVector: UInt32  // Boot service vector: puts -> USB ring (0x80-readable)
    public let osRegBase: UInt32      // PMU_GRF OS_REG0 address
    public let bootModeReg: UInt32    // reboot-to-maskrom: boot-mode register
    public let maskromMagic: UInt32   // reboot-to-maskrom: magic written to bootModeReg
    public let cruResetReg: UInt32    // CRU global soft-reset register
    public let cruResetValue: UInt32  // value that triggers the reset
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
            ddrBinName: "rk3568_ddr_1560MHz_v1.25.bin",
            detectCfgName: "rk3568_osregdump.cfg",
            downloadBase: 0xFDCC_4000,
            usbPutsVector: 0xFDCC_1004,
            osRegBase: 0xFDC2_0200,
            bootModeReg: 0xFDC2_0200,
            maskromMagic: 0xEF08_A53C,
            cruResetReg: 0xFDD2_00D4,
            cruResetValue: 0x0000_FDB9),
    ]
    public static func forPID(_ pid: UInt16) -> DetectProfile? { all[pid] }
}
